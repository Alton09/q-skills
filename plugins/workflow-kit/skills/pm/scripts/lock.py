#!/usr/bin/env python3
"""Single-supervisor lock shared by every worktree of a repository."""

from __future__ import annotations

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
from typing import Any, Iterator, Sequence


class UsageError(ValueError):
    """An error caused by invalid lock command input."""


def process(pid: int) -> tuple[int, str] | None:
    result = subprocess.run(
        ["ps", "-o", "ppid=", "-o", "comm=", "-p", str(pid)],
        capture_output=True, text=True,
    )
    fields = result.stdout.strip().split(None, 1)
    if result.returncode or len(fields) != 2:
        return None
    return int(fields[0]), Path(fields[1]).name


def owner_pid() -> int | None:
    override = os.environ.get("PM_LOCK_OWNER_PID")
    if override is not None:
        try:
            pid = int(override)
        except ValueError as exc:
            raise UsageError("PM_LOCK_OWNER_PID must be a positive integer") from exc
        if pid <= 0:
            raise UsageError("PM_LOCK_OWNER_PID must be a positive integer")
        return pid
    pid = os.getppid()
    seen: set[int] = set()
    while pid > 0 and pid not in seen:
        seen.add(pid)
        info = process(pid)
        if info is None:
            break
        parent, name = info
        if name == "claude":
            return pid
        pid = parent
    return None


def lock_path(project: Path) -> Path:
    result = subprocess.run(
        ["git", "rev-parse", "--git-common-dir"], cwd=project,
        capture_output=True, text=True,
    )
    if result.returncode:
        raise UsageError(result.stderr.strip() or "not a git repository")
    return (project / result.stdout.strip()).resolve() / "pm.lock"


def read_holder(path: Path) -> dict[str, Any] | None:
    try:
        holder = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None
    except ValueError as exc:
        raise UsageError(f"invalid lock file: {path}") from exc
    if (not isinstance(holder, dict) or type(holder.get("pid")) is not int
            or holder["pid"] <= 0 or not isinstance(holder.get("host"), str)):
        raise UsageError(f"invalid lock file: {path}")
    return holder


def is_stale(holder: dict[str, Any] | None) -> bool:
    if holder is None or holder["host"] != socket.gethostname():
        # A remote host's process cannot be checked locally; require --force.
        return False
    try:
        os.kill(holder["pid"], 0)
    except ProcessLookupError:
        return True
    except PermissionError:
        return False
    # Test override permits ordinary live processes such as sleep to own locks.
    if "PM_LOCK_OWNER_PID" in os.environ:
        return False
    info = process(holder["pid"])
    return info is None or info[1] != "claude"


@contextmanager
def mutation_guard(path: Path) -> Iterator[None]:
    # Keep this inode: unlinking a flock guard lets contenders lock different files.
    with path.with_name("pm.lock.guard").open("a") as guard:
        fcntl.flock(guard, fcntl.LOCK_EX)
        yield


def write_holder(path: Path, holder: dict[str, Any]) -> None:
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent,
                                         prefix="pm.lock.", delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(json.dumps(holder, ensure_ascii=False) + "\n")
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def command(args: argparse.Namespace) -> dict[str, Any]:
    project = Path(args.project_dir).expanduser().resolve()
    path = lock_path(project)
    if args.action == "status":
        holder = read_holder(path)
        return {"held": holder is not None, "holder": holder, "stale": is_stale(holder)}
    pid = owner_pid()
    if pid is None:
        if args.action == "release":
            return {"ok": True, "released": False}
        holder = read_holder(path)
        return {"ok": False, "lock": str(path), "holder": holder,
                "stale": is_stale(holder), "takenOver": False,
                "reason": "no claude ancestor"}
    with mutation_guard(path):
        holder = read_holder(path)
        own = holder is not None and holder["pid"] == pid and holder["host"] == socket.gethostname()
        if args.action == "release":
            if own:
                path.unlink()
            return {"ok": True, "released": own}
        stale = is_stale(holder)
        result = {"ok": False, "lock": str(path), "holder": holder,
                  "stale": stale, "takenOver": False}
        if holder is not None and not own and not stale and not args.force:
            return result
        new_holder = {"pid": pid, "host": socket.gethostname(), "cwd": str(project),
                      "startedAt": datetime.now(timezone.utc).isoformat()}
        write_holder(path, new_holder)
        result.update(ok=True, holder=new_holder, takenOver=holder is not None and not own)
        return result


def parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    for action in ("acquire", "release", "status"):
        cmd = sub.add_parser(action)
        cmd.add_argument("--project-dir", required=True)
        if action == "acquire":
            cmd.add_argument("--force", action="store_true")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    try:
        result = command(parser().parse_args(argv))
    except (UsageError, OSError) as exc:
        print(f"lock.py: {exc}", file=sys.stderr)
        return 2
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
