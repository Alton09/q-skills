#!/usr/bin/env python3
"""One herdr workspace per running worker, closed when the worker finishes.

Shared by implement-plan (codex/pi executor workers) and pm (claude --bg workers).
Every call is best-effort: it prints one JSON object and exits 0, so a herdr failure never
blocks a spawn. Only argparse usage errors exit 2.

Commands:
  available [--project-dir D]
  open --label L --cwd D --command CMD [--project-dir D]
  close --label L [--if-idle] [--project-dir D]
  mirror --label L --pid P --file F --format codex|pi [--err E] [--cwd D] [--project-dir D]
  view --pid P --file F --format codex|pi [--err E] [--label L]
  sweep [--project-dir D]   close executor spaces whose viewer has exited
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import time
from typing import Any, Callable, Sequence


EXECUTOR_PREFIXES = ("codex:", "pi:")
HERDR_TIMEOUT = 10
FOLLOW_INTERVAL = 0.25
CLOSE_DELAY = 3.0
OUTPUT_LINES = 4
TEXT_LIMIT = 400


class SpaceError(RuntimeError):
    """A herdr failure that must not block the caller."""


# ---------------------------------------------------------------- herdr calls

def run(argv: list[str]) -> dict[str, Any]:
    try:
        process = subprocess.run(["herdr", *argv], capture_output=True, text=True, timeout=HERDR_TIMEOUT)
        output = process.stderr if process.returncode else process.stdout
        data = json.loads(output) if output.strip() else {}
        if not isinstance(data, dict):
            return {"warning": "herdr returned a non-object response"}
        if process.returncode:
            error = data.get("error", {})
            return {"warning": str(error.get("message", output)), "code": error.get("code")}
        result = data.get("result", {})
        return result if isinstance(result, dict) else {"warning": "herdr returned a non-object result"}
    except (OSError, subprocess.TimeoutExpired, ValueError, AttributeError) as exc:
        return {"warning": f"herdr {' '.join(argv)}: {exc}"}


def checked(argv: list[str]) -> dict[str, Any]:
    result = run(argv)
    if "warning" in result:
        raise SpaceError(result["warning"])
    return result


def _config_module() -> Any:
    path = Path(__file__).with_name("config.py")
    spec = importlib.util.spec_from_file_location("workflow_kit_config", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def available(project_dir: Path) -> dict[str, Any]:
    """Herdr spaces are on inside herdr, or in a pm worker that pm marked with WORKFLOW_KIT_HERDR=1."""
    result: dict[str, Any] = {"available": False, "reason": None}
    if os.environ.get("HERDR_ENV") != "1" and os.environ.get("WORKFLOW_KIT_HERDR") != "1":
        result["reason"] = "not inside herdr (HERDR_ENV and WORKFLOW_KIT_HERDR are not 1)"
        return result
    if shutil.which("herdr") is None:
        result["reason"] = "herdr is not on PATH"
        return result
    try:
        merged, _sources, warnings = _config_module().load(project_dir)
    except Exception as exc:  # a bad config disables spaces; it never blocks a spawn
        result["reason"] = f"config: {exc}"
        return result
    if warnings:
        result["warnings"] = warnings
    if not merged["pm"]["herdr"]:
        result["reason"] = "herdr is disabled in config (pm.herdr: false)"
        return result
    result["available"] = True
    return result


def spaces(label: str | None = None, prefixes: Sequence[str] = ()) -> list[dict[str, Any]]:
    rows = checked(["workspace", "list"]).get("workspaces", [])
    return [
        row for row in rows
        if (label is not None and row.get("label") == label)
        or (prefixes and str(row.get("label", "")).startswith(tuple(prefixes)))
    ]


def panes(workspace_id: str) -> list[dict[str, Any]]:
    return [row for row in checked(["pane", "list", "--workspace", workspace_id]).get("panes", [])
            if row.get("workspace_id", workspace_id) == workspace_id]


def process_info(pane: str) -> dict[str, Any]:
    return checked(["pane", "process-info", "--pane", pane])["process_info"]


def shell_free(info: dict[str, Any]) -> bool:
    return info.get("foreground_process_group_id") == info.get("shell_pid")


def own_process(process: dict[str, Any]) -> bool:
    """A foreground process this helper or pm started: a viewer or a `claude attach`/`agents` client."""
    try:
        argv = shlex.split(str(process.get("cmdline", "")))
    except ValueError:
        return False
    if argv and argv[0] == "command":
        argv = argv[1:]
    names = [Path(arg).name for arg in argv[:3]]
    if "herdr_space.py" in names:
        return True
    if argv and Path(argv[0]).name in ("node", "bun"):
        argv = argv[1:]
    return len(argv) > 1 and Path(argv[0]).name in ("claude", "cli.js") and argv[1] in ("attach", "agents")


def pane_ours(pane: str) -> bool:
    info = process_info(pane)
    return shell_free(info) or all(own_process(p) for p in info.get("foreground_processes", []))


def close_space(row: dict[str, Any], if_idle: bool = False) -> bool:
    """Close one workspace unless a pane runs something the user started there."""
    workspace_id = row["workspace_id"]
    if not all(shell_free(process_info(p["pane_id"])) if if_idle else pane_ours(p["pane_id"])
               for p in panes(workspace_id)):
        return False
    checked(["workspace", "close", workspace_id])
    return True


def close_label(label: str, if_idle: bool = False) -> dict[str, Any]:
    closed, kept = [], []
    for row in spaces(label):
        (closed if close_space(row, if_idle=if_idle) else kept).append(row["workspace_id"])
    result: dict[str, Any] = {"closed": closed}
    if kept:
        result["kept"] = kept
        if not if_idle:
            result["warning"] = f"workspace {', '.join(kept)} runs a process pm did not start; left open"
    return result


def open_space(label: str, cwd: Path, command: str, replace: bool = True) -> dict[str, Any]:
    """Open a space whose only pane runs *command*, first closing same-label spaces when *replace*."""
    if replace:
        close_label(label)
    # Publish executor labels only after the viewer starts, so sweep cannot race creation.
    executor = label.startswith(EXECUTOR_PREFIXES)
    created = checked(["workspace", "create", "--label", "starting:" + label if executor else label, "--cwd", str(cwd), "--no-focus"])
    workspace_id = created["workspace"]["workspace_id"]
    pane = created["root_pane"]["pane_id"]
    try:
        checked(["pane", "run", pane, command])
        if executor:
            checked(["workspace", "rename", workspace_id, label])
    except SpaceError:
        try:
            close_space({"workspace_id": workspace_id})
        except SpaceError:
            pass
        raise
    return {"opened": True, "label": label, "workspace": workspace_id, "pane": pane}


def sweep() -> dict[str, Any]:
    """Close executor spaces whose viewer is gone (the pane is back at its shell)."""
    closed = []
    for row in spaces(prefixes=EXECUTOR_PREFIXES):
        rows = panes(row["workspace_id"])
        if rows and all(shell_free(process_info(p["pane_id"])) for p in rows):
            checked(["workspace", "close", row["workspace_id"]])
            closed.append(row["workspace_id"])
    return {"closed": closed}


# ---------------------------------------------------------------- live viewer

DIM, BOLD, RED, RESET = "\033[2m", "\033[1m", "\033[31m", "\033[0m"


def clip(text: Any, limit: int = TEXT_LIMIT) -> str:
    text = str(text).strip()
    return text if len(text) <= limit else text[:limit] + " …"


def tail_lines(text: Any, count: int = OUTPUT_LINES) -> list[str]:
    lines = [line for line in str(text or "").splitlines() if line.strip()]
    return lines[-count:]


def render_codex(event: dict[str, Any]) -> list[str]:
    kind = event.get("type")
    item = event.get("item") if isinstance(event.get("item"), dict) else {}
    item_type = item.get("type")
    if kind == "thread.started":
        return [f"{DIM}codex thread {event.get('thread_id')}{RESET}"]
    if kind == "turn.completed":
        usage = event.get("usage") or {}
        return [f"{DIM}turn done: in {usage.get('input_tokens')} (cached {usage.get('cached_input_tokens')}) out {usage.get('output_tokens')}{RESET}"]
    if kind in ("turn.failed", "error"):
        error = event.get("error") if isinstance(event.get("error"), dict) else {}
        return [f"{RED}error: {clip(error.get('message') or event.get('message') or event)}{RESET}"]
    if item_type == "command_execution":
        if kind == "item.started":
            return [f"{BOLD}$ {clip(item.get('command'))}{RESET}"]
        if kind == "item.completed":
            code = item.get("exit_code")
            color = RED if code not in (0, None) else DIM
            return [f"  {DIM}{line}{RESET}" for line in tail_lines(item.get("aggregated_output"))] + [f"  {color}exit {code}{RESET}"]
    if kind != "item.completed":
        return []
    if item_type == "agent_message":
        return [clip(item.get("text"), 2000)]
    if item_type == "reasoning":
        return [f"{DIM}· {clip(item.get('text'))}{RESET}"]
    if item_type == "file_change":
        return [f"~ {c.get('kind')} {c.get('path')}" for c in item.get("changes", []) if isinstance(c, dict)]
    if item_type == "mcp_tool_call":
        return [f"→ {item.get('server')}.{item.get('tool')} {item.get('status', '')}".rstrip()]
    if item_type == "todo_list":
        return [f"{'[x]' if t.get('completed') else '[ ]'} {t.get('text')}" for t in item.get("items", []) if isinstance(t, dict)]
    if item_type == "error":
        return [f"{RED}error: {clip(item.get('message'))}{RESET}"]
    return []


def render_pi(event: dict[str, Any]) -> list[str]:
    kind = event.get("type")
    if kind == "message_end":
        message = event.get("message") if isinstance(event.get("message"), dict) else {}
        if message.get("role") != "assistant":
            return []
        lines: list[str] = []
        for block in message.get("content") or []:
            if not isinstance(block, dict):
                continue
            if block.get("type") == "text":
                lines.append(clip(block.get("text"), 2000))
            elif block.get("type") == "thinking":
                lines.append(f"{DIM}· {clip(block.get('thinking'))}{RESET}")
            elif block.get("type") == "toolCall":
                lines.append(f"{BOLD}→ {block.get('name')} {clip(json.dumps(block.get('arguments'), ensure_ascii=False), 300)}{RESET}")
        if message.get("errorMessage"):
            lines.append(f"{RED}error: {clip(message['errorMessage'])}{RESET}")
        return lines
    if kind == "tool_execution_end":
        result = event.get("result")
        text = ""
        if isinstance(result, dict):
            text = "\n".join(b.get("text", "") for b in result.get("content") or [] if isinstance(b, dict))
        elif result is not None:
            text = str(result)
        color = RED if event.get("isError") else DIM
        return [f"  {color}{line}{RESET}" for line in tail_lines(text)]
    if kind == "agent_end":
        return [f"{DIM}agent finished{RESET}"]
    return []


RENDERERS: dict[str, Callable[[dict[str, Any]], list[str]]] = {"codex": render_codex, "pi": render_pi}


def render_line(line: str, fmt: str) -> list[str]:
    line = line.strip()
    if not line:
        return []
    try:
        event = json.loads(line)
    except json.JSONDecodeError:
        return [line]
    return RENDERERS[fmt](event) if isinstance(event, dict) else []


def alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    try:
        state = Path(f"/proc/{pid}/stat").read_text(encoding="utf-8").rsplit(")", 1)[1].split()[0]
        return state != "Z"
    except (OSError, IndexError):
        return True


def follow(pid: int, file: Path, fmt: str, out: Any = sys.stdout) -> None:
    """Print rendered events from *file* until *pid* exits, then drain what is left."""
    handle = None
    buffer = ""
    while True:
        running = alive(pid)
        if handle is None and file.exists():
            handle = file.open("r", encoding="utf-8", errors="replace")
        chunk = handle.read() if handle else ""
        if chunk:
            buffer += chunk
            *complete, buffer = buffer.split("\n")
            for line in complete:
                for rendered in render_line(line, fmt):
                    print(rendered, file=out, flush=True)
            continue
        if not running:
            for rendered in render_line(buffer, fmt):
                print(rendered, file=out, flush=True)
            return
        time.sleep(FOLLOW_INTERVAL)


def view(args: argparse.Namespace) -> int:
    print(f"{BOLD}{args.label or 'worker'}{RESET} {DIM}pid {args.pid} · {args.file}{RESET}")
    print(f"{DIM}Live view only. Closing it does not stop the worker.{RESET}\n", flush=True)
    try:
        follow(args.pid, Path(args.file), args.format)
    except KeyboardInterrupt:
        return 0
    if args.err:
        lines = tail_lines(Path(args.err).read_text(encoding="utf-8", errors="replace") if Path(args.err).exists() else "", 10)
        if lines:
            print(f"\n{DIM}stderr:{RESET}")
            for line in lines:
                print(f"  {DIM}{line}{RESET}")
    print(f"\n{BOLD}worker exited{RESET}; closing this space.", flush=True)
    time.sleep(CLOSE_DELAY)
    workspace_id = os.environ.get("HERDR_WORKSPACE_ID")
    if args.label and workspace_id:
        rows = [row for row in run(["workspace", "list"]).get("workspaces", []) if row.get("workspace_id") == workspace_id]
        if rows and rows[0].get("label") == args.label:
            run(["workspace", "close", workspace_id])
    return 0


def mirror(args: argparse.Namespace) -> dict[str, Any]:
    if not any(args.label.startswith(prefix) for prefix in EXECUTOR_PREFIXES):
        raise SpaceError(f"executor space labels start with one of {', '.join(EXECUTOR_PREFIXES)}")
    command = [sys.executable or "python3", str(Path(__file__).resolve()), "view", "--pid", str(args.pid),
               "--file", str(Path(args.file).resolve()), "--format", args.format, "--label", args.label]
    if args.err:
        command += ["--err", str(Path(args.err).resolve())]
    return open_space(args.label, Path(args.cwd).expanduser().resolve(), shlex.join(command))


# ---------------------------------------------------------------- CLI

def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = root.add_subparsers(dest="action", required=True)
    sub.add_parser("available").add_argument("--project-dir", default=".")
    opener = sub.add_parser("open")
    opener.add_argument("--label", required=True); opener.add_argument("--cwd", required=True)
    opener.add_argument("--command", required=True); opener.add_argument("--project-dir", default=".")
    closer = sub.add_parser("close")
    closer.add_argument("--if-idle", action="store_true")
    closer.add_argument("--label", required=True); closer.add_argument("--project-dir", default=".")
    sub.add_parser("sweep").add_argument("--project-dir", default=".")
    for name in ("mirror", "view"):
        cmd = sub.add_parser(name)
        cmd.add_argument("--pid", required=True, type=int); cmd.add_argument("--file", required=True)
        cmd.add_argument("--format", required=True, choices=sorted(RENDERERS)); cmd.add_argument("--err")
        cmd.add_argument("--label", required=name == "mirror")
        if name == "mirror":
            cmd.add_argument("--cwd", default="."); cmd.add_argument("--project-dir", default=".")
    return root


def main(argv: Sequence[str] | None = None) -> int:
    args = parser().parse_args(argv)
    if args.action == "view":
        return view(args)
    try:
        project_dir = Path(getattr(args, "project_dir", ".")).expanduser().resolve()
        state = available(project_dir)
        if args.action == "available":
            result = state
        elif not state["available"]:
            result = {"skipped": True, "reason": state["reason"]}
        elif args.action == "open":
            result = open_space(args.label, Path(args.cwd).expanduser().resolve(), args.command)
        elif args.action == "mirror":
            result = mirror(args)
        elif args.action == "close":
            result = close_label(args.label, if_idle=args.if_idle)
        else:
            result = sweep()
    except Exception as exc:  # best-effort: report, never fail the caller
        result = {"warning": str(exc) or type(exc).__name__}
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
