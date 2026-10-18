#!/usr/bin/env python3
"""Best-effort herdr mirrors for tech-lead workers."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import sys
import time
from typing import Any, Sequence

import dossier
import launch


POLL_TIMEOUT = 3.0
POLL_INTERVAL = 0.1


class MirrorError(ValueError):
    """A mirror failure that must not block the lead."""


def run_herdr(argv: list[str]) -> dict[str, Any]:
    try:
        process = subprocess.run(["herdr", *argv], capture_output=True, text=True, timeout=10)
        output = process.stderr if process.returncode else process.stdout
        data = json.loads(output) if output.strip() else {}
        if not isinstance(data, dict):
            return {"warning": "herdr returned a non-object response"}
        if process.returncode:
            error = data.get("error", {})
            return {"warning": str(error.get("message", output)), "code": error.get("code")}
        result = data.get("result", {})
        if not isinstance(result, dict):
            return {"warning": "herdr returned a non-object result"}
        return result
    except (OSError, subprocess.TimeoutExpired, ValueError, AttributeError) as exc:
        return {"warning": f"herdr {' '.join(argv)}: {exc}"}


def checked(argv: list[str]) -> dict[str, Any]:
    result = run_herdr(argv)
    if "warning" in result:
        raise MirrorError(result["warning"])
    return result


def available(project_dir: Path) -> dict[str, Any]:
    if os.environ.get("HERDR_ENV") != "1":
        return {"available": False, "reason": "HERDR_ENV is not 1"}
    if shutil.which("herdr") is None:
        return {"available": False, "reason": "herdr is not on PATH"}
    if not dossier.config(project_dir)["herdr"]:
        return {"available": False, "reason": "herdr is disabled in config"}
    return {"available": True, "reason": None}


def agent_name(worker: str) -> str:
    name = re.sub(r"[^a-z0-9_-]", "-", worker.lower())
    if not re.match(r"^[a-z]", name):
        name = "a-" + name
    if len(name) > 32:
        head, separator, kind = name.rpartition("-")
        if separator and kind and len(kind) <= 29:
            name = head[:31 - len(kind)] + "-" + kind
        else:
            name = name[:32]
    return name


def workspace(item_path: Path) -> str | None:
    label = launch.feature_name(item_path)
    return next((row["workspace_id"] for row in checked(["workspace", "list"])["workspaces"] if row.get("label") == label), None)


def tabs(workspace_id: str) -> list[dict[str, Any]]:
    return checked(["tab", "list", "--workspace", workspace_id])["tabs"]


def ownership(item_path: Path, title: str, add: bool = False, remove: bool = False) -> bool:
    # Persist labels only, so restart-safe cleanup never claims a pre-existing tab.
    path = item_path.parent.parent / ".herdr-tabs.json"
    labels = json.loads(path.read_text(encoding="utf-8")) if path.exists() else []
    if not isinstance(labels, list) or not all(isinstance(label, str) for label in labels):
        raise MirrorError(f"invalid ownership ledger: {path}")
    changed = (add and title not in labels) or (remove and title in labels)
    if changed:
        if add:
            labels.append(title)
        else:
            labels.remove(title)
        temporary = path.with_suffix(".tmp")
        temporary.write_text(json.dumps(labels) + "\n", encoding="utf-8")
        temporary.replace(path)
    return title in labels


def process_info(pane: str) -> dict[str, Any]:
    return checked(["pane", "process-info", "--pane", pane])["process_info"]


def shell_free(info: dict[str, Any]) -> bool:
    return info["foreground_process_group_id"] == info["shell_pid"]


def wait_for_shell(pane: str) -> dict[str, Any]:
    deadline = time.monotonic() + POLL_TIMEOUT
    while True:
        info = process_info(pane)
        if shell_free(info) or time.monotonic() >= deadline:
            return info
        time.sleep(POLL_INTERVAL)


def free_pane(pane: str) -> None:
    if shell_free(process_info(pane)):
        return
    checked(["pane", "send-keys", pane, "ctrl+z"])
    info = wait_for_shell(pane)
    if shell_free(info):
        return
    for process in info.get("foreground_processes", []):
        command = shlex.split(process.get("cmdline", ""))
        if command and Path(command[0]).name == "claude" and len(command) > 1 and command[1] in ("attach", "agents"):
            pid = int(process["pid"])
            if pid <= 1 or pid == info["shell_pid"]:
                raise MirrorError("refusing to signal an invalid attach pid")
            state = Path(f"/proc/{pid}/stat").read_text(encoding="utf-8").rsplit(")", 1)[1].split()[0]
            os.kill(pid, signal.SIGKILL if state in ("T", "t") else signal.SIGTERM)
    if not shell_free(wait_for_shell(pane)):
        raise MirrorError(f"pane {pane} is still occupied")


def prepare(item_path: Path, repo: Path) -> dict[str, Any]:
    item = launch.read_item(item_path)
    title = str(item["title"])
    workspace_id = workspace(item_path)
    if workspace_id is None:
        result = checked(["workspace", "create", "--label", launch.feature_name(item_path), "--cwd", str(repo), "--no-focus"])
        workspace_id = result["workspace"]["workspace_id"]
        tab = result["tab"]["tab_id"]
        checked(["tab", "rename", tab, title])
    else:
        tab = next((row["tab_id"] for row in tabs(workspace_id) if row.get("label") == title), None)
        if tab is not None:
            panes = checked(["pane", "list", "--workspace", workspace_id])["panes"]
            pane = next(row["pane_id"] for row in panes if row["tab_id"] == tab)
            free_pane(pane)
            return {"workspace": workspace_id, "tab": tab, "pane": pane, "created": False}
        result = checked(["tab", "create", "--workspace", workspace_id, "--label", title, "--cwd", str(repo), "--no-focus"])
        tab = result["tab"]["tab_id"]
    ownership(item_path, title, add=True)
    return {"workspace": workspace_id, "tab": tab, "pane": result["root_pane"]["pane_id"], "created": True}


def attach(item_path: Path, pane: str) -> dict[str, Any]:
    worker = launch.read_item(item_path).get("worker")
    if not isinstance(worker, str) or not worker:
        raise launch.UsageError("attach requires item worker")
    checked(["pane", "run", pane, "command claude attach " + shlex.quote(worker)])
    deadline = time.monotonic() + POLL_TIMEOUT
    while True:
        result = run_herdr(["agent", "get", pane])
        if result.get("agent"):
            break
        if "warning" in result and result.get("code") != "agent_not_found":
            raise MirrorError(result["warning"])
        if time.monotonic() >= deadline:
            raise MirrorError(f"agent detection timed out for {pane}")
        time.sleep(POLL_INTERVAL)
    name = agent_name(worker)
    checked(["agent", "rename", pane, name])
    return {"pane": pane, "agent": name, "attached": True}


def ensure(item_path: Path, repo: Path) -> dict[str, Any]:
    item = launch.read_item(item_path)
    if not item.get("worker") or item.get("stage") in ("done", "dropped"):
        return {"ensured": False}
    workspace_id = workspace(item_path)
    if workspace_id and any(row.get("label") == item["title"] for row in tabs(workspace_id)):
        return {"ensured": False}
    result = prepare(item_path, repo)
    attach(item_path, result["pane"])
    return {**result, "ensured": True}


def close(item_path: Path) -> dict[str, Any]:
    title = str(launch.read_item(item_path)["title"])
    if not ownership(item_path, title):
        return {"closed": False}
    workspace_id = workspace(item_path)
    if workspace_id is None:
        ownership(item_path, title, remove=True)
        return {"closed": False}
    tab = next((row["tab_id"] for row in tabs(workspace_id) if row.get("label") == title), None)
    if tab is None:
        ownership(item_path, title, remove=True)
        return {"closed": False}
    checked(["tab", "close", tab])
    ownership(item_path, title, remove=True)
    # herdr closes the workspace automatically when its last tab closes.
    return {"closed": True, "workspace": workspace_id, "tab": tab}


def parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    available_parser = sub.add_parser("available"); available_parser.add_argument("--project-dir", default=".")
    for action in ("prepare", "attach", "ensure", "close"):
        cmd = sub.add_parser(action)
        cmd.add_argument("--item", required=True)
        cmd.add_argument("--project-dir", default=".")
        if action in ("prepare", "ensure"):
            cmd.add_argument("--repo", required=True)
        elif action == "attach":
            cmd.add_argument("--pane", required=True)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    try:
        args = parser().parse_args(argv)
        project_dir = Path(args.repo if hasattr(args, "repo") else args.project_dir).expanduser().resolve()
        result = available(project_dir)
        if not result["available"]:
            result = {**(result if args.action == "available" else {}), "skipped": True, "reason": result["reason"]}
        elif args.action != "available":
            item_path = Path(args.item).expanduser().resolve()
            if args.action == "prepare": result = prepare(item_path, project_dir)
            elif args.action == "attach": result = attach(item_path, args.pane)
            elif args.action == "ensure": result = ensure(item_path, project_dir)
            else: result = close(item_path)
    except (launch.UsageError, dossier.UsageError) as exc:
        print(f"herdr.py: {exc}", file=sys.stderr)
        return 2
    except (MirrorError, OSError, ValueError, KeyError, TypeError, StopIteration) as exc:
        result = {"warning": str(exc) or "unexpected herdr response"}
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
