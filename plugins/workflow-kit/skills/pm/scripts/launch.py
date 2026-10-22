#!/usr/bin/env python3
"""Capacity, overlap, plan-scope, and worker-command helpers for pm."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import shlex
import sys
from typing import Any, Iterable, Sequence

import dossier


# Specification: references/workers.md § "Worker protocol" (Task 7 must copy this exactly).
WORKER_PROTOCOL = """Worker protocol:
Item file: {item_path}
Repository: {repo_dir}
Worktree: {worktree_path}
Never edit the dossier directly; use python3 {events_path} worker-event for every dossier update.
Before ending with a needs input block, pass the whole block on stdin through this quoted heredoc, so the shell never expands its text:
python3 {events_arg} worker-event --item {item_arg} --line-file -{notify_arg} <<'PM_EVENT'
<whole needs input block>
PM_EVENT
After the skill's final done or stopped line, run the same command with that line as the heredoc body.
After either command, if `push` is non-null, call PushNotification with it."""


class UsageError(ValueError):
    """An error caused by invalid launch command input."""


def as_list(value: str | list[str] | None) -> list[str]:
    return value if isinstance(value, list) else []


def item_files(vault: Path) -> Iterable[Path]:
    """Yield every item in *vault* and in the sibling `*-vault` directories beside it."""
    vault = vault.expanduser().resolve()
    pattern = "Features/*/items/*.md"
    paths = set(vault.glob(pattern)) | set(vault.parent.glob(f"*-vault/{pattern}"))
    yield from sorted(paths)


def read_item(path: Path) -> dict[str, str | list[str]]:
    return dossier.parse_item(path)[0]


def feature_name(path: Path) -> str:
    return dossier.feature_label(path.parent.parent.name)


def plan_scope(path: Path) -> dict[str, list[str]]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        raise UsageError(str(exc)) from exc
    modules: list[str] = []
    files: list[str] = []
    module: str | None = None
    line_re = re.compile(r"^(\s*)[-*]\s+\*\*(Module|Files)\*\*:\s*(.*)$")
    tick_re = re.compile(r"`([^`]+)`")
    for index, line in enumerate(lines):
        match = line_re.match(line)
        if not match:
            continue
        indent, kind, text = match.groups()
        values = tick_re.findall(text)
        if kind == "Module":
            module = values[0] if values else None
            if module and module not in modules:
                modules.append(module)
        else:
            base_indent = len(indent.expandtabs(tabsize=8))
            for continuation in lines[index + 1:]:
                nested = re.match(r"^(\s*)[-*]\s+", continuation)
                if not nested or len(nested.group(1).expandtabs(tabsize=8)) <= base_indent:
                    break
                values.extend(tick_re.findall(continuation))
            for value in values:
                # Task file lists are relative to their Module (including `scripts/foo.py`).
                resolved = str(Path(module) / value) if module and not Path(value).is_absolute() else value
                if resolved not in files:
                    files.append(resolved)
    return {"files": files, "modules": modules}


def capacity(vault: Path, project_dir: Path) -> dict[str, Any]:
    running = 0
    queue: list[tuple[str, str]] = []
    for path in item_files(vault):
        try:
            item = read_item(path)
        except dossier.UsageError:
            continue
        if item.get("status") == "running":
            running += 1
        elif item.get("status") == "queued":
            queue.append((str(item.get("updated", "")), str(path.resolve())))
    maximum = dossier.config(project_dir)["maxWorkers"]
    return {"running": running, "max": maximum, "free": max(0, maximum - running), "queue": [path for _, path in sorted(queue)]}


def path_prefix(left: str, right: str) -> bool:
    left, right = left.rstrip("/"), right.rstrip("/")
    return left == right or right.startswith(left + "/") or left.startswith(right + "/")


def find_blocked_item(vault: Path, current: Path, reference: str) -> Path | None:
    parts = reference.strip("/").split("/", 1)
    feature, slug = (parts if len(parts) == 2 else [feature_name(current), parts[0]])
    for path in item_files(vault):
        if feature_name(path) == feature and path.stem == slug:
            return path
    return None


def overlap(vault: Path, current: Path) -> dict[str, Any]:
    current = current.expanduser().resolve()
    item = read_item(current)
    blockers: list[dict[str, str]] = []
    seen: set[Path] = set()

    def add(path: Path | None, why: str) -> None:
        if path is None or path == current or path in seen:
            return
        seen.add(path)
        blockers.append({"item": str(path.resolve()), "lead": feature_name(path), "why": why})

    for reference in as_list(item.get("blockedBy")):
        blocked = find_blocked_item(vault, current, reference)
        if blocked is None:
            blockers.append({"item": reference, "lead": reference.split("/", 1)[0] if "/" in reference else feature_name(current), "why": "blockedBy"})
        elif read_item(blocked).get("stage") not in ("merged", "done"):
            add(blocked, "blockedBy")

    files = set(as_list(item.get("files")))
    modules = as_list(item.get("modules"))
    for candidate in item_files(vault):
        if candidate.resolve() == current:
            continue
        try:
            other = read_item(candidate)
        except dossier.UsageError:
            continue
        if other.get("stage") not in ("implement", "pr", "review"):
            continue
        shared = sorted(files.intersection(as_list(other.get("files"))))
        if shared:
            add(candidate, "files: " + ", ".join(shared))
        else:
            for left in modules:
                if any(path_prefix(left, right) for right in as_list(other.get("modules"))):
                    add(candidate, f"modules: {left}")
                    break
    return {"ok": not blockers, "blockers": blockers}


def absolute(value: str, base: Path) -> str:
    path = Path(value).expanduser()
    return str((path if path.is_absolute() else base / path).resolve())


def command(args: argparse.Namespace) -> dict[str, Any]:
    item_path = Path(args.item).expanduser().resolve()
    item = read_item(item_path)
    repo = Path(args.repo).expanduser().resolve()
    worktree = Path(args.worktree).expanduser().resolve() if args.worktree else repo
    events = Path(__file__).with_name("events.py").resolve()
    if args.kind == "plan":
        if not args.handoff or not args.out:
            raise UsageError("plan requires --handoff and --out")
        invocation = ["/workflow-kit:feature-plan", "--handoff", absolute(args.handoff, repo)]
        for context in args.context:
            invocation.extend(("--context", absolute(context, repo)))
        invocation.extend(("--out", absolute(args.out, repo), "--worker"))
    elif args.kind == "implement":
        plan = item.get("plan")
        if not isinstance(plan, str) or not plan:
            raise UsageError("implement requires item plan")
        # Item paths are vault-relative (references/dossier.md § "Item format").
        vault = item_path.parent.parent.parent.parent
        invocation = ["/workflow-kit:implement-plan", absolute(plan, vault), "--worker"]
    else:
        if not args.pr:
            raise UsageError(f"{args.kind} requires --pr")
        invocation = ["/workflow-kit:address-pr", str(args.pr)]
        if args.kind == "ci":
            invocation.append("--ci")
        elif args.kind == "sync":
            invocation.append("--sync")
        if args.worktree:
            invocation.extend(("--worktree", str(worktree)))
        else:
            # address-pr Step 3 finds the PR worktree or creates it through /create-worktree.
            worktree = "found or created by address-pr"
        invocation.append("--worker")
    notify_arg = f" --notify-cmd {shlex.quote(str(Path(args.notify_cmd).expanduser().resolve()))}" if args.notify_cmd else ""
    prompt = " ".join(invocation) + "\n\n" + WORKER_PROTOCOL.format(
        item_path=item_path, repo_dir=repo, worktree_path=worktree, events_path=events,
        events_arg=shlex.quote(str(events)), item_arg=shlex.quote(str(item_path)), notify_arg=notify_arg,
    )
    suffix = "" if args.kind == "implement" else f"-{args.kind}"
    name = f"{feature_name(item_path)}-{item_path.stem}{suffix}"
    settings = json.dumps({"env": {"PR_RETRO_NUDGE": "0", "HERDR_ENV": "0"}})
    argv = ["claude", "--bg", "--permission-mode", "auto", "--model", args.model, "-n", name, "--settings", settings, prompt]
    return {"name": name, "argv": argv, "prompt": prompt}


def parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    scope = sub.add_parser("plan-scope"); scope.add_argument("plan")
    cap = sub.add_parser("capacity"); cap.add_argument("--vault", required=True); cap.add_argument("--project-dir", default=".")
    over = sub.add_parser("overlap"); over.add_argument("--vault", required=True); over.add_argument("--item", required=True)
    cmd = sub.add_parser("command")
    cmd.add_argument("--item", required=True); cmd.add_argument("--kind", required=True, choices=("plan", "implement", "ci", "sync", "comments")); cmd.add_argument("--model", required=True); cmd.add_argument("--repo", required=True)
    cmd.add_argument("--handoff"); cmd.add_argument("--context", action="append", default=[]); cmd.add_argument("--out"); cmd.add_argument("--pr"); cmd.add_argument("--worktree"); cmd.add_argument("--notify-cmd")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    try:
        args = parser().parse_args(argv)
        if args.action == "plan-scope": result = plan_scope(Path(args.plan))
        elif args.action == "capacity": result = capacity(Path(args.vault), Path(args.project_dir))
        elif args.action == "overlap": result = overlap(Path(args.vault), Path(args.item))
        else: result = command(args)
    except (UsageError, dossier.UsageError) as exc:
        print(f"launch.py: {exc}", file=sys.stderr)
        return 2
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
