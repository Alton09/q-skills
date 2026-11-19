#!/usr/bin/env python3
"""Best-effort herdr spaces for pm workers: one workspace per running worker.

Each worker gets a workspace labeled `pm:<worker>` whose pane runs
`claude attach <short id>`. The space closes when the worker finishes. A paused worker
keeps its space so the user can answer there. Low-level herdr calls live in
implement-plan's `herdr_space.py`, which also mirrors codex/pi executor workers.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import time
from typing import Any, Sequence

import dossier
import launch


ATTACH_TIMEOUT = 10.0
POLL_INTERVAL = 0.1
PREFIX = "pm:"
FINISHED = frozenset(("done", "stopped", "failed", "error", "killed", "exited"))


def _space_module() -> Any:
    path = Path(__file__).resolve().parents[2] / "implement-plan" / "scripts" / "herdr_space.py"
    spec = importlib.util.spec_from_file_location("workflow_kit_herdr_space", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


space = _space_module()
MirrorError = space.SpaceError


def available(project_dir: Path) -> dict[str, Any]:
    config = dossier.config(project_dir)
    result: dict[str, Any] = {"available": False, "reason": None}
    if config.get("warnings"):
        result["warnings"] = config["warnings"]
    if os.environ.get("HERDR_ENV") != "1":
        result["reason"] = "HERDR_ENV is not 1"
    elif shutil.which("herdr") is None:
        result["reason"] = "herdr is not on PATH"
    elif not config["herdr"]:
        result["reason"] = "herdr is disabled in config"
    else:
        result["available"] = True
    return result


def agent_name(worker: str) -> str:
    name = re.sub(r"[^a-z0-9_-]", "-", worker.lower())
    if not re.match(r"^[a-z]", name):
        name = "a-" + name
    if len(name) > 32:
        head, separator, kind = name.rpartition("-")
        digest = hashlib.sha1(worker.encode()).hexdigest()[:6]
        if separator and kind and len(kind) <= 23:
            name = head[:24 - len(kind)] + "-" + digest + "-" + kind
        else:
            name = name[:25] + "-" + digest
    return name


def label(worker: str) -> str:
    return PREFIX + worker


# ---------------------------------------------------------------- worker evidence

def agents() -> dict[str, list[dict[str, Any]]]:
    """Every background session from `claude agents --json --all`, grouped by name, newest first."""
    try:
        process = subprocess.run(["claude", "agents", "--json", "--all"], capture_output=True, text=True, timeout=20)
        records = json.loads(process.stdout) if process.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError) as exc:
        raise MirrorError(f"claude agents: {exc}") from exc
    if isinstance(records, dict):
        records = records.get("agents")
    if not isinstance(records, list):
        raise MirrorError("claude agents returned no session list")
    by_name: dict[str, list[dict[str, Any]]] = {}
    for record in records:
        if isinstance(record, dict) and isinstance(record.get("name"), str) and record.get("kind", "background") == "background":
            by_name.setdefault(record["name"], []).append(record)
    for rows in by_name.values():
        rows.sort(key=lambda row: row.get("startedAt") or 0, reverse=True)
    return by_name


def pick(by_name: dict[str, list[dict[str, Any]]], worker: str, session: Any = None) -> dict[str, Any] | None:
    rows = by_name.get(worker, [])
    if isinstance(session, str) and session:
        match = next((row for row in rows if str(row.get("sessionId", "")).startswith(session) or row.get("id") == session), None)
        return match
    return rows[0] if rows else None


def short_id(record: dict[str, Any]) -> str:
    value = record.get("id") or str(record.get("sessionId", ""))[:8]
    if not value:
        raise MirrorError(f"no session id for worker {record.get('name')}")
    return str(value)


def live(record: dict[str, Any] | None) -> bool:
    return record is not None and (record.get("status") == "waiting" or record.get("state") not in FINISHED)


def keep(record: dict[str, Any] | None, item: dict[str, Any] | None) -> bool:
    """A space stays while its worker runs, or while its item is paused on a question."""
    if live(record):
        return True
    return record is not None and record.get("state") != "stopped" and bool(item) and item.get("status") == "paused"


# ---------------------------------------------------------------- spaces

def attach_command(record: dict[str, Any]) -> str:
    return "command claude attach " + shlex.quote(short_id(record))


def attached(pane: str, record: dict[str, Any]) -> bool:
    info = space.process_info(pane)
    want = ["attach", short_id(record)]
    for process in info.get("foreground_processes", []):
        try:
            argv = shlex.split(str(process.get("cmdline", "")))
        except ValueError:
            continue
        if argv and argv[0] == "command":
            argv = argv[1:]
        if argv and Path(argv[0]).name in ("node", "bun"):
            argv = argv[1:]
        if argv and Path(argv[0]).name in ("claude", "cli.js") and argv[1:3] == want:
            return True
    return False


def name_agent(pane: str, worker: str, timeout: float = ATTACH_TIMEOUT) -> dict[str, Any]:
    """Name the attach agent; a zero timeout defers detection lag to the next sync."""
    deadline = time.monotonic() + timeout
    while True:
        result = space.run(["agent", "get", pane])
        agent = result.get("agent")
        if agent:
            name = agent_name(worker)
            if agent.get("name") != name:
                space.checked(["agent", "rename", pane, name])
            return {"agent": name}
        if "warning" in result and result.get("code") != "agent_not_found":
            return {"agentWarning": result["warning"]}
        if timeout == 0 and result.get("code") == "agent_not_found":
            return {}
        if time.monotonic() >= deadline:
            return {"agentWarning": f"agent detection timed out for {pane}"}
        time.sleep(POLL_INTERVAL)


def owned(row: dict[str, Any], repo: Path) -> list[dict[str, Any]] | None:
    """Return the panes of a `pm:` space this repository's pm created, else None."""
    panes = space.panes(row["workspace_id"])
    return panes if panes and all(pane.get("cwd") == str(repo) for pane in panes) else None


def open_worker(worker: str, record: dict[str, Any], repo: Path, name_timeout: float = ATTACH_TIMEOUT) -> dict[str, Any]:
    rows = space.spaces(label(worker))
    for row in rows:
        panes = owned(row, repo)
        if panes and len(panes) == 1:
            pane = panes[0]["pane_id"]
            if attached(pane, record):
                return {"opened": False, "label": label(worker), "workspace": row["workspace_id"], "pane": pane, **name_agent(pane, worker, timeout=name_timeout)}
            info = space.process_info(pane)
            if space.shell_free(info):
                space.checked(["pane", "run", pane, attach_command(record)])
                return {"opened": True, "label": label(worker), "workspace": row["workspace_id"], "pane": pane, **name_agent(pane, worker, timeout=name_timeout)}
    result = space.open_space(label(worker), repo, attach_command(record), replace=False)
    if result.get("warning"):
        return result
    return {**result, **name_agent(result["pane"], worker, timeout=name_timeout)}


def item_worker(item_path: Path) -> tuple[str, dict[str, Any]]:
    item = launch.read_item(item_path)
    worker = item.get("worker")
    if not isinstance(worker, str) or not worker:
        raise launch.UsageError("item has no worker")
    return worker, item


def open_action(args: argparse.Namespace, repo: Path) -> dict[str, Any]:
    if args.item:
        worker, item = item_worker(Path(args.item).expanduser().resolve())
        session = args.session or item.get("sessionId")
    else:
        worker, item, session = args.worker, None, args.session
    record = pick(agents(), worker, session)
    if record is None and session:
        raise MirrorError(f"session not listed yet for worker {worker}: {session}")
    if record is None:
        raise MirrorError(f"no background session named {worker}")
    if not keep(record, item):
        return {"opened": False, "reason": f"worker {worker} has finished", **close_worker(worker, repo)}
    return open_worker(worker, record, repo)


def close_worker(worker: str, repo: Path) -> dict[str, Any]:
    closed, kept = [], []
    for row in space.spaces(label(worker)):
        if owned(row, repo) is None:
            continue
        (closed if space.close_space(row) else kept).append(row["workspace_id"])
    result: dict[str, Any] = {"closed": closed}
    if kept:
        result["warning"] = f"workspace {', '.join(kept)} runs a process pm did not start; left open"
    return result


def active_items(vault: Path) -> list[dict[str, Any]]:
    items = []
    for path in sorted(vault.expanduser().resolve().glob("Features/*/items/*.md")):
        try:
            item = launch.read_item(path)
        except dossier.UsageError:
            continue
        if item.get("stage") not in ("done", "dropped") and isinstance(item.get("worker"), str) and item["worker"]:
            items.append(item)
    return items


def sync(vault: Path, repo: Path) -> dict[str, Any]:
    """Open a space for every running worker of this vault and close every finished one."""
    by_name = agents()
    wanted: dict[str, dict[str, Any]] = {}
    warnings: list[str] = []
    for item in active_items(vault):
        record = pick(by_name, item["worker"], item.get("sessionId"))
        if record is None and item.get("sessionId") and item.get("status") in ("running", "paused"):
            warnings.append(f"session not listed yet for worker {item['worker']}: {item['sessionId']}")
        if keep(record, item):
            wanted[item["worker"]] = record
    result: dict[str, Any] = {"opened": [], "closed": [], "kept": []}
    for row in space.spaces(prefixes=(PREFIX,)):
        worker = str(row["label"])[len(PREFIX):]
        try:
            if owned(row, repo) is None:
                continue
            if worker in wanted or live(pick(by_name, worker)):
                result["kept"].append(worker)
            elif space.close_space(row):
                result["closed"].append(worker)
            else:
                warnings.append(f"workspace {row['workspace_id']} runs a process pm did not start; left open")
        except MirrorError as exc:
            warnings.append(f"{worker}: {exc}")
    for worker, record in wanted.items():
        try:
            opened = open_worker(worker, record, repo, name_timeout=0)
        except MirrorError as exc:
            warnings.append(f"{worker}: {exc}")
            continue
        if opened.get("opened"):
            result["opened"].append(worker)
        if opened.get("agentWarning"):
            warnings.append(f"{worker}: {opened['agentWarning']}")
    result["swept"] = []
    try:
        result["swept"] = space.sweep()["closed"]
    except MirrorError as exc:
        warnings.append(f"sweep: {exc}")
    if warnings:
        result["warning"] = "; ".join(warnings)
    return result


# ---------------------------------------------------------------- CLI

def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    sub = root.add_subparsers(dest="action", required=True)
    sub.add_parser("available").add_argument("--project-dir", default=".")
    for action in ("open", "close"):
        cmd = sub.add_parser(action)
        target = cmd.add_mutually_exclusive_group(required=True)
        target.add_argument("--item"); target.add_argument("--worker")
        cmd.add_argument("--repo", required=True)
        if action == "open":
            cmd.add_argument("--session")
    syncer = sub.add_parser("sync")
    syncer.add_argument("--vault", required=True); syncer.add_argument("--repo", required=True)
    return root


def main(argv: Sequence[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        repo = Path(getattr(args, "repo", None) or args.project_dir).expanduser().resolve()
        result = available(repo)
        if not result["available"]:
            result = {**(result if args.action == "available" else {}), "skipped": True, "reason": result["reason"]}
        elif args.action == "open":
            result = open_action(args, repo)
        elif args.action == "close":
            worker = item_worker(Path(args.item).expanduser().resolve())[0] if args.item else args.worker
            result = close_worker(worker, repo)
        elif args.action == "sync":
            result = sync(Path(args.vault), repo)
    except (launch.UsageError, dossier.UsageError) as exc:
        print(f"herdr.py: {exc}", file=sys.stderr)
        return 2
    except Exception as exc:
        result = {"warning": str(exc) or "unexpected herdr response"}
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
