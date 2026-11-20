#!/usr/bin/env python3
"""Worker event storage, notification deduplication, and Claude session helpers."""

from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import time
from typing import Any, Sequence

import dossier


class UsageError(ValueError):
    """An error caused by invalid command input."""


STATUS_LINE = re.compile(r"^(?:feature-plan|implement-plan|address-pr): (?:done|stopped|needs input) .+$")
NEEDS_INPUT = re.compile(r"^(feature-plan|implement-plan|address-pr): needs input (\S+)$", re.MULTILINE)


def item_context(path: Path) -> tuple[dict[str, str | list[str]], str, Path, str]:
    data, body = dossier.parse_item(path)
    try:
        feature_dir = path.resolve().parent.parent
        feature = dossier.feature_label(feature_dir.name)
        vault = feature_dir.parent.parent
    except IndexError as exc:
        raise UsageError(f"cannot infer feature directory from {path}") from exc
    return data, body, vault, feature


def add_log(feature_dir: Path, event: str, detail: str) -> None:
    log = feature_dir / "log.md"
    line = f"- {dossier.now_iso()} {event}: {detail}\n"
    with log.open("a", encoding="utf-8") as handle:
        handle.write(line)


def set_item(path: Path, data: dict[str, str | list[str]], body: str, updates: dict[str, str | list[str]], note: str | None) -> None:
    data.update(updates)
    if note:
        if body and not body.endswith("\n"):
            body += "\n"
        body += f"- {dossier.today()} {note}\n"
    dossier.write_item(path, data, body)


def run_json(argv: list[str], cwd: Path | None = None) -> dict[str, Any]:
    result = subprocess.run(argv, cwd=cwd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if result.returncode:
        raise RuntimeError((result.stderr or result.stdout).strip() or f"{' '.join(argv)} failed")
    parsed = json.loads(result.stdout)
    if not isinstance(parsed, dict):
        raise RuntimeError(f"{' '.join(argv)} returned non-object JSON")
    return parsed


def pr_details(url: str, repo: Path) -> tuple[str, str, str, int]:
    view = run_json(["gh", "pr", "view", url, "--json", "headRefName,body"], repo)
    branch = view.get("headRefName")
    if not isinstance(branch, str) or not branch:
        raise RuntimeError("gh pr view returned no headRefName")
    body = view.get("body", "")
    body = body if isinstance(body, str) else ""
    worktrees = subprocess.run(
        ["git", "-C", str(repo), "worktree", "list", "--porcelain"],
        text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
    )
    if worktrees.returncode:
        raise RuntimeError((worktrees.stderr or worktrees.stdout).strip() or "git worktree list failed")
    current = ""
    found = ""
    for line in worktrees.stdout.splitlines() + [""]:
        if line.startswith("worktree "):
            current = line[len("worktree "):]
        elif line == f"branch refs/heads/{branch}":
            found = current
    return branch, found, body, count_unplanned(body)


def count_unplanned(body: str) -> int:
    match = re.search(r"(?mis)^### Unplanned Decisions\s*$\n(.*?)(?=^#{1,3}\s|\Z)", body)
    if not match:
        return 0
    bullets = [line.strip()[2:].strip() for line in match.group(1).splitlines() if re.match(r"^\s*-\s+\S", line)]
    return 0 if bullets == ["None"] else len(bullets)


def attach_target(data: dict[str, str | list[str]]) -> str:
    """The short session id when known: `claude attach` matches names by prefix, so
    `<feature>-<slug>` is ambiguous once `<feature>-<slug>-plan` exists."""
    session = data.get("sessionId")
    if isinstance(session, str) and session.strip():
        return session.strip()[:8]
    return str(data.get("worker", ""))


def event_message(feature: str, event: str, detail: str, worker: str) -> str:
    # Truncate the detail, never the attach command, to stay under 200 characters.
    suffix = f"; claude attach {worker}" if event.startswith("paused-") and worker else ""
    return f"[{feature}] {event} — {detail}"[:199 - len(suffix)] + suffix


def deliver(data: dict[str, str | list[str]], event: str | None, message: str, notify_cmd: str | None) -> tuple[str | None, bool]:
    if not event:
        return None, False
    notified = data.get("notified", [])
    if not isinstance(notified, list):
        notified = []
    if event in notified:
        return None, False
    notified.append(event)
    data["notified"] = notified
    if notify_cmd and os.path.isfile(notify_cmd) and os.access(notify_cmd, os.X_OK):
        subprocess.run([notify_cmd, message, "pm"], check=False)
    return message, True


def parse_worker_line(line: str, data: dict[str, str | list[str]], repo: Path) -> tuple[dict[str, str | list[str]], str | None, str, str]:
    """Return item updates, notification key, log event, and detail."""
    first = line.splitlines()[0] if line.splitlines() else ""
    needs = NEEDS_INPUT.search(line)
    if needs:
        question = re.search(r"(?m)^Question:\s*(.+)$", line)
        if not question:
            raise UsageError("needs input block has no Question: line")
        ident = needs.group(2)
        return {"status": "paused", "question": question.group(1).strip()}, f"paused-{ident}", "paused", question.group(1).strip()
    match = re.fullmatch(r"feature-plan: done (.+)", first)
    if match:
        plan = match.group(1)
        return {"stage": "plan", "status": "idle", "plan": plan}, "plan-done", "plan-done", plan
    match = re.fullmatch(r"implement-plan: done (\S+) (pr-skipped)", first)
    if match:
        return {"status": "stuck"}, "stuck", "stuck", "PR skipped"
    match = re.fullmatch(r"implement-plan: done (\S+) (\S+)", first)
    if match:
        key, url = match.groups()
        branch, worktree, _body, unplanned = pr_details(url, repo)
        return {"stage": "pr", "status": "idle", "pr": url, "branch": branch, "worktree": worktree, "unplanned": str(unplanned)}, None, "impl-done", key
    match = re.fullmatch(r"implement-plan: stopped (\S+) (.+)", first)
    if match:
        _key, phase = match.groups()
        return {"status": "stuck"}, "stuck", "stuck", phase
    match = re.fullmatch(r"address-pr: done #(\d+) (\S+)", first)
    if match:
        number, result = match.groups()
        kind = data.get("workerKind", "")
        if result == "no-push":
            return {"status": "idle"}, None, "no-push", f"#{number}"
        if kind == "comments":
            raw_round = data.get("round", "0")
            try:
                round_no = int(str(raw_round)) + 1
            except ValueError:
                round_no = 1
            return {"status": "idle", "round": str(round_no)}, f"fix-pushed-{round_no}", f"fix-pushed-{round_no}", f"#{number} {result}"
        return {"status": "idle"}, None, "ci-fixed" if kind == "ci" else "synced" if kind == "sync" else "addressed", f"#{number} {result}"
    raise UsageError(f"unrecognized worker final line: {first}")


def read_line(args: argparse.Namespace) -> str:
    """Return --line, or the --line-file text (`-` is stdin) without its trailing newline."""
    if args.line is not None:
        return args.line
    try:
        text = sys.stdin.read() if args.line_file == "-" else Path(args.line_file).read_text(encoding="utf-8")
    except OSError as exc:
        raise UsageError(str(exc)) from exc
    return text.rstrip("\n")


def worker_event(args: argparse.Namespace) -> dict[str, Any]:
    args.line = read_line(args)
    path = Path(args.item).resolve()
    data, body, vault, feature = item_context(path)
    repo = Path(args.repo).resolve() if args.repo else Path.cwd()
    # A truncated idle notice can repeat a pause already recorded by the worker.
    needs = NEEDS_INPUT.fullmatch(args.line.strip())
    if needs and data.get("status") == "paused":
        return {"item": str(path), "event": f"paused-{needs.group(2)}", "push": None, "synced": False}
    updates, event, log_event, detail = parse_worker_line(args.line, data, repo)
    # State, rather than historical notification keys, identifies a repeated pause.
    if updates.get("status") == "paused":
        repeated = data.get("status") == "paused" and data.get("question") == updates["question"]
    else:
        # A new completion follows a running worker. Ignore the computed next round
        # when comparing an already-applied completion with its resulting state.
        repeated = all(data.get(key) == value for key, value in updates.items() if key != "round")
    if repeated:
        if event and event.startswith("fix-pushed-"):
            event = f"fix-pushed-{data.get('round', '0')}"
        return {"item": str(path), "event": event, "push": None, "synced": False}
    # A changed question during the same pause must also be delivered.
    if updates.get("status") == "paused" and data.get("status") == "paused":
        notified = data.get("notified", [])
        if isinstance(notified, list):
            data["notified"] = [key for key in notified if key != event]
    note = None
    if log_event == "stuck":
        note = f"worker stuck: {detail}"
    elif log_event == "no-push":
        note = "address-pr completed without a push"
    message = event_message(feature, event, detail, attach_target(data)) if event else ""
    push, changed_notification = deliver(data, event, message, args.notify_cmd)
    set_item(path, data, body, updates, note)
    add_log(path.parent.parent, log_event, detail)
    sync_result: dict[str, Any] | None = None
    if not args.no_sync:
        relative = os.path.relpath(path, vault)
        feature_dir = path.parent.parent
        project_dir = vault / "Features" / dossier.PROJECT_DIR
        board_dirs = [project_dir] if feature_dir == project_dir else [feature_dir, project_dir]
        sync_result = dossier.sync(vault, f"pm: {log_event}", board_dirs, [relative, os.path.relpath(path.parent.parent / "log.md", vault)])
    return {"item": str(path), "event": event, "push": push, "synced": sync_result if sync_result is not None else False}


def notify(args: argparse.Namespace) -> dict[str, Any]:
    path = Path(args.item).resolve()
    data, body, _vault, _feature = item_context(path)
    push, _changed = deliver(data, args.event, args.message, args.notify_cmd)
    if push is not None:
        dossier.write_item(path, data, body)
    return {"item": str(path), "event": args.event, "push": push}


def assistant_text(value: Any) -> str | None:
    if not isinstance(value, dict):
        return None
    if value.get("type") != "assistant":
        return None
    message = value.get("message", value)
    if not isinstance(message, dict):
        return None
    content = message.get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = [part.get("text", "") for part in content if isinstance(part, dict) and part.get("type", "text") == "text"]
        return "\n".join(part for part in parts if isinstance(part, str)) or None
    return message.get("text") if isinstance(message.get("text"), str) else None


def last_reply(args: argparse.Namespace) -> dict[str, Any]:
    cwd = Path(args.cwd).expanduser().resolve()
    transcript = dossier.transcript_path(cwd, args.session)
    if not transcript.is_file():
        print(f"warning: transcript not found: {transcript}", file=sys.stderr)
        return {"reply": None, "line": None}
    reply: str | None = None
    line: str | None = None
    for raw in transcript.read_text(encoding="utf-8").splitlines():
        try:
            text = assistant_text(json.loads(raw))
        except json.JSONDecodeError:
            continue
        if text:
            reply = text
            lines = text.splitlines()
            for index, candidate in enumerate(lines):
                if STATUS_LINE.fullmatch(candidate.strip()):
                    line = candidate.strip()
                    if NEEDS_INPUT.fullmatch(line):
                        line = "\n".join([line, *lines[index + 1:]])
    return {"reply": reply, "line": line}


def agent_records() -> tuple[list[dict], str | None]:
    try:
        result = subprocess.run(["claude", "agents", "--json", "--all"], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    except OSError as exc:
        return [], f"warning: claude agents failed: {exc}"
    if result.returncode:
        return [], f"warning: claude agents failed: {(result.stderr or result.stdout).strip()}"
    try:
        parsed = json.loads(result.stdout)
    except json.JSONDecodeError:
        return [], "warning: claude agents returned invalid JSON"
    records = parsed.get("agents", []) if isinstance(parsed, dict) else parsed
    if not isinstance(records, list):
        return [], "warning: claude agents returned invalid JSON"
    return [record for record in records if isinstance(record, dict)], None


def agents(_args: argparse.Namespace) -> dict[str, Any]:
    records, warning = agent_records()
    if warning:
        print(warning, file=sys.stderr)
    by_name: dict[str, dict[str, Any]] = {}
    if isinstance(records, list):
        for record in records:
            if isinstance(record, dict) and isinstance(record.get("name"), str):
                by_name[record["name"]] = {key: record.get(key) for key in ("status", "state", "waitingFor")}
    return {"byName": by_name}


def wait(args: argparse.Namespace) -> dict[str, Any]:
    if not math.isfinite(args.interval) or args.interval <= 0:
        raise UsageError("--interval must be > 0 and finite")
    if not math.isfinite(args.timeout) or args.timeout < 0:
        raise UsageError("--timeout must be >= 0 and finite")
    features = Path(args.vault).expanduser().resolve() / "Features"
    if not features.is_dir():
        raise UsageError(f"Features directory not found: {features}")
    deadline = time.monotonic() + args.timeout
    warnings: list[str] = []
    warned_paths: set[Path] = set()

    def result(kind: str, **extra: Any) -> dict[str, Any]:
        return {"wait": kind, **extra, **({"warnings": warnings} if warnings else {})}

    def read_items() -> dict[Path, dict | None]:
        items: dict[Path, dict | None] = {}
        for path in sorted(features.glob("*/items/*.md")):
            try:
                items[path] = dossier.parse_item(path)[0]
            except (dossier.UsageError, OSError, UnicodeError) as exc:
                # Keep the path present: a partial write is neither a change nor deletion.
                items[path] = None
                if path not in warned_paths:
                    warnings.append(f"warning: cannot parse item {path}: {exc}")
                    warned_paths.add(path)
        return items

    def state(data: dict) -> tuple[Any, Any, Any]:
        return tuple(data.get(key) for key in ("status", "stage", "updated"))

    initial = read_items()
    snapshot = {path: state(data) for path, data in initial.items() if data is not None}
    watched = {path for path, values in snapshot.items() if values[0] == "running"}
    if not watched:
        return result("none")
    gone_counts: dict[Path, int] = {}
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return result("timeout")
        time.sleep(min(args.interval, remaining))
        if time.monotonic() >= deadline:
            return result("timeout")
        current = read_items()
        changes = []
        for path in sorted(watched | current.keys()):
            if path in current and current[path] is None:
                gone_counts.pop(path, None)
                continue
            old = snapshot.get(path, (None, None, None))
            new = state(current[path]) if path in current else (None, None, None)
            if (path in watched and old != new) or (old[0] != "running" and new[0] == "running"):
                changes.append({"item": str(path), "oldStatus": old[0], "newStatus": new[0], "oldStage": old[1], "newStage": new[1]})
        if changes:
            return result("changed", items=changes)
        records, warning = agent_records()
        if warning:
            if warning not in warnings:
                warnings.append(warning)
            gone_counts.clear()
            continue
        gone = []
        for path in sorted(watched):
            data = current.get(path)
            if data is None:
                continue
            worker, session = data.get("worker"), data.get("sessionId")
            if not worker and not session:
                continue
            record = next((record for record in records if session and record.get("sessionId") == session), None)
            if record is None and worker:
                record = next((record for record in records if record.get("name") == worker), None)
            if record is not None and "status" in record:
                gone_counts.pop(path, None)
                continue
            gone_counts[path] = gone_counts.get(path, 0) + 1
            if gone_counts[path] >= 2:
                gone.append({"item": str(path), "worker": worker, "sessionId": session, "state": record.get("state") if record else None})
        if gone:
            return result("worker-gone", items=gone)


def make_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    worker = sub.add_parser("worker-event")
    worker.add_argument("--item", required=True)
    line = worker.add_mutually_exclusive_group(required=True)
    line.add_argument("--line")
    line.add_argument("--line-file", help="read the line or block from this file; `-` reads stdin")
    worker.add_argument("--repo")
    worker.add_argument("--notify-cmd")
    worker.add_argument("--no-sync", action="store_true")
    notice = sub.add_parser("notify")
    notice.add_argument("--item", required=True)
    notice.add_argument("--event", required=True)
    notice.add_argument("--message", required=True)
    notice.add_argument("--notify-cmd")
    reply = sub.add_parser("last-reply")
    reply.add_argument("--session", required=True)
    reply.add_argument("--cwd", default=".")
    sub.add_parser("agents")
    waiter = sub.add_parser("wait")
    waiter.add_argument("--vault", required=True)
    waiter.add_argument("--interval", type=float, default=20)
    waiter.add_argument("--timeout", type=float, default=3300)
    return parser


def run_cli(args: argparse.Namespace) -> dict[str, Any]:
    if args.command == "worker-event":
        return worker_event(args)
    if args.command == "notify":
        return notify(args)
    if args.command == "last-reply":
        return last_reply(args)
    if args.command == "wait":
        return wait(args)
    return agents(args)


def main(argv: Sequence[str] | None = None) -> int:
    parser = make_parser()
    args = parser.parse_args(argv)
    try:
        result = run_cli(args)
    except (UsageError, dossier.UsageError, RuntimeError) as exc:
        parser.error(str(exc))
    print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
