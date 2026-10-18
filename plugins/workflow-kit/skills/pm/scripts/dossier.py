#!/usr/bin/env python3
"""Deterministic storage and git operations for a pm dossier."""

from __future__ import annotations

import argparse
import datetime as dt
import difflib
import json
import os
from pathlib import Path
import subprocess
import sys
from typing import Any, Iterable, Sequence


PROJECT_DIR = "_project"
PROJECT_LABEL = "project"
STAGES = ("idea", "design", "plan", "implement", "pr", "review", "merged", "done", "dropped")
STATUSES = ("none", "queued", "blocked", "running", "paused", "stuck", "idle")
ITEM_KEYS = (
    "slug", "title", "stage", "status", "origin", "worker", "sessionId", "workerKind",
    "worktree", "branch", "pr", "plan", "design", "blockedBy", "files", "modules",
    "notified", "round", "reviewSeen", "question", "unplanned", "updated",
)
LIST_KEYS = frozenset(("blockedBy", "files", "modules", "notified"))
UNION_LINES = ("decisions.md merge=union", "log.md merge=union", "ignored.md merge=union")


class UsageError(ValueError):
    """An error caused by invalid command input."""


def feature_label(feature_dir_name: str) -> str:
    return PROJECT_LABEL if feature_dir_name == PROJECT_DIR else feature_dir_name


def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def today() -> str:
    return dt.date.today().isoformat()


def read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return value if isinstance(value, dict) else {}


def pm_config(project_dir: Path) -> dict[str, Any]:
    """Merge user then project pm config, one key deep."""
    merged: dict[str, Any] = {}
    for path in (
        Path.home() / ".claude" / "workflow-kit.json",
        project_dir / ".claude" / "workflow-kit.json",
    ):
        document = read_json(path)
        pm = document.get("pm")
        if not isinstance(pm, dict):
            pm = document.get("lead", {})
        if isinstance(pm, dict):
            merged.update(pm)
    return merged


def resolve_vault(project_dir: Path) -> dict[str, Any]:
    project_dir = project_dir.expanduser().resolve()
    configured = pm_config(project_dir).get("vault")
    source = "none"
    vault: Path | None = None
    if isinstance(configured, str) and configured.strip():
        vault = Path(os.path.expandvars(configured)).expanduser()
        if not vault.is_absolute():
            vault = project_dir / vault
        vault = vault.resolve()
        source = "config"
    else:
        candidate = Path.home() / "Workspace" / "Obsidian" / f"{project_dir.name.lower()}-vault"
        if candidate.is_dir():
            vault = candidate.resolve()
            source = "convention"
    return {
        "vault": str(vault) if vault else None,
        "source": source,
        "featuresDir": str(vault / "Features") if vault else None,
    }


def config(project_dir: Path) -> dict[str, Any]:
    pm = pm_config(project_dir.expanduser().resolve())
    max_workers = pm.get("maxWorkers", 2)
    if not isinstance(max_workers, int) or isinstance(max_workers, bool) or max_workers < 1:
        max_workers = 2
    herdr = pm.get("herdr", True)
    resolved = resolve_vault(project_dir)
    result = {"maxWorkers": max_workers, "vault": resolved["vault"], "herdr": herdr}
    if not isinstance(herdr, bool):
        result.update(herdr=True, warnings=["pm.herdr must be a boolean; using true"])
    return result


def split_list(text: str) -> list[str]:
    inner = text[1:-1].strip()
    if not inner:
        return []
    # JSON is the canonical writer format; accept the unquoted restricted-YAML form too.
    try:
        parsed = json.loads(text)
        if isinstance(parsed, list) and all(not isinstance(v, (dict, list)) for v in parsed):
            return [str(v) for v in parsed]
    except json.JSONDecodeError:
        pass
    return [part.strip().strip('"\'') for part in inner.split(",")]


def parse_value(text: str) -> str | list[str]:
    text = text.strip()
    if text.startswith("[") and text.endswith("]"):
        return split_list(text)
    if len(text) >= 2 and text[0] == text[-1] == '"':
        try:
            value = json.loads(text)
            return value if isinstance(value, str) else str(value)
        except json.JSONDecodeError:
            pass
    return text


def parse_item(path: str | Path) -> tuple[dict[str, str | list[str]], str]:
    path = Path(path)
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise UsageError(str(exc)) from exc
    lines = text.splitlines(keepends=True)
    if not lines or lines[0].rstrip("\r\n") != "---":
        raise UsageError(f"{path}: missing frontmatter")
    data: dict[str, str | list[str]] = {}
    end = None
    for index, line in enumerate(lines[1:], start=1):
        bare = line.rstrip("\r\n")
        if bare == "---":
            end = index
            break
        if not bare or ":" not in bare:
            raise UsageError(f"{path}: invalid frontmatter line {index + 1}")
        key, value = bare.split(":", 1)
        if key not in ITEM_KEYS:
            raise UsageError(f"unknown item key: {key}")
        data[key] = parse_value(value)
    if end is None:
        raise UsageError(f"{path}: unterminated frontmatter")
    body = "".join(lines[end + 1 :])
    validate_item(data)
    return data, body


def validate_item(data: dict[str, str | list[str]]) -> None:
    unknown = set(data) - set(ITEM_KEYS)
    if unknown:
        raise UsageError(f"unknown item key: {sorted(unknown)[0]}")
    if "stage" in data and data["stage"] not in STAGES:
        raise UsageError(f"invalid stage: {data['stage']}")
    if "status" in data and data["status"] not in STATUSES:
        raise UsageError(f"invalid status: {data['status']}")
    for key in LIST_KEYS:
        if key in data and not isinstance(data[key], list):
            raise UsageError(f"{key} must be a list")


def format_scalar(value: str) -> str:
    if value == "":
        return ""
    if value != value.strip() or any(ch in value for ch in "\n\r[],:#\"'"):
        return json.dumps(value, ensure_ascii=False)
    return value


def format_value(value: str | list[str]) -> str:
    if isinstance(value, list):
        return json.dumps(value, ensure_ascii=False, separators=(", ", ": "))
    return format_scalar(str(value))


def write_item(path: str | Path, data: dict[str, str | list[str]], body: str) -> None:
    path = Path(path)
    data["updated"] = now_iso()
    validate_item(data)
    ordered = [key for key in ITEM_KEYS if key in data]
    content = ["---\n"]
    for key in ordered:
        rendered = format_value(data[key])
        content.append(f"{key}: {rendered}\n" if rendered else f"{key}:\n")
    content.append("---\n")
    content.append(body)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(content), encoding="utf-8")


def parse_assignment(text: str) -> tuple[str, str | list[str]]:
    if "=" not in text:
        raise UsageError(f"expected k=v, got: {text}")
    key, raw = text.split("=", 1)
    if key not in ITEM_KEYS:
        raise UsageError(f"unknown item key: {key}")
    value = parse_value(raw)
    if key in LIST_KEYS and not isinstance(value, list):
        # --add uses scalars, and is validated by its caller.
        return key, value
    return key, value


def item_result(path: Path, data: dict[str, str | list[str]], body: str) -> dict[str, Any]:
    return {"file": str(path.resolve()), "item": data, "body": body}


def item_new(feature_dir: Path, slug: str, title: str, assignments: Sequence[str]) -> dict[str, Any]:
    path = feature_dir / "items" / f"{slug}.md"
    if path.exists():
        raise UsageError(f"item already exists: {path}")
    data: dict[str, str | list[str]] = {
        "slug": slug,
        "title": title,
        "stage": "idea",
        "status": "none",
    }
    for assignment in assignments:
        key, value = parse_assignment(assignment)
        data[key] = value
    write_item(path, data, "")
    data, body = parse_item(path)
    return item_result(path, data, body)


def item_set(path: Path, assignments: Sequence[str], adds: Sequence[str], note: str | None) -> dict[str, Any]:
    data, body = parse_item(path)
    for assignment in assignments:
        key, value = parse_assignment(assignment)
        data[key] = value
    for assignment in adds:
        key, value = parse_assignment(assignment)
        if key not in LIST_KEYS:
            raise UsageError(f"--add requires a list key: {key}")
        if isinstance(value, list):
            additions = value
        else:
            additions = [value]
        current = data.get(key, [])
        if not isinstance(current, list):
            raise UsageError(f"{key} must be a list")
        for addition in additions:
            if addition not in current:
                current.append(addition)
        data[key] = current
    if note is not None:
        if body and not body.endswith("\n"):
            body += "\n"
        body += f"- {today()} {note}\n"
    write_item(path, data, body)
    data, body = parse_item(path)
    return item_result(path, data, body)


def item_get(path: Path) -> dict[str, Any]:
    data, body = parse_item(path)
    return item_result(path, data, body)


def append_missing_lines(path: Path, wanted: Iterable[str]) -> None:
    existing = path.read_text(encoding="utf-8").splitlines() if path.exists() else []
    additions = [line for line in wanted if line not in existing]
    if not additions:
        return
    text = path.read_text(encoding="utf-8") if path.exists() else ""
    if text and not text.endswith("\n"):
        text += "\n"
    text += "".join(f"{line}\n" for line in additions)
    path.write_text(text, encoding="utf-8")


def init_project(vault: Path) -> dict[str, Any]:
    project_dir = vault / "Features" / PROJECT_DIR
    (project_dir / "items").mkdir(parents=True, exist_ok=True)
    templates = {
        project_dir / "decisions.md": "# Project decisions\n\n",
        project_dir / "log.md": "# Log\n\n",
    }
    created: list[str] = []
    for path, content in templates.items():
        if not path.exists():
            path.write_text(content, encoding="utf-8")
            created.append(str(path))
    append_missing_lines(vault / ".gitattributes", UNION_LINES)
    return {"ok": True, "projectDir": str(project_dir.resolve()), "created": created}


def init_dossier(vault: Path, feature: str) -> dict[str, Any]:
    if feature in (PROJECT_LABEL, PROJECT_DIR):
        raise UsageError(f"reserved feature name: {feature}")
    project = init_project(vault)
    feature_dir = vault / "Features" / feature
    for directory in (feature_dir / "items", feature_dir / "designs", feature_dir / "plans"):
        directory.mkdir(parents=True, exist_ok=True)
    templates = {
        feature_dir / "brief.md": (
            f"# {feature}\n\n## Goal\n\n## Constraints\n\n## Architecture\n\n## Non-goals\n\n"
        ),
        feature_dir / "decisions.md": "# Feature decisions\n\n",
        feature_dir / "log.md": "# Log\n\n",
        feature_dir / "board.md": "# Board\n\n> Generated by dossier.py board; do not edit.\n",
    }
    created = project["created"]
    for path, content in templates.items():
        if not path.exists():
            path.write_text(content, encoding="utf-8")
            created.append(str(path))
    return {"ok": True, "featureDir": str(feature_dir.resolve()), "created": created}


def item_counts(directory: Path) -> dict[str, Any]:
    counts = {stage: 0 for stage in STAGES}
    for path in sorted((directory / "items").glob("*.md")):
        try:
            data, _ = parse_item(path)
        except UsageError:
            continue
        stage = data.get("stage")
        if isinstance(stage, str) and stage in counts:
            counts[stage] += 1
    return {"items": sum(counts.values()), "stages": counts}


def list_features(vault: Path, match: str | None) -> dict[str, Any]:
    root = vault / "Features"
    features: list[dict[str, Any]] = []
    names: list[str] = []
    if root.is_dir():
        for directory in sorted(root.iterdir(), key=lambda p: p.name.casefold()):
            if not directory.is_dir() or directory.name == PROJECT_DIR:
                continue
            names.append(directory.name)
            features.append({"name": directory.name, **item_counts(directory)})
    result: dict[str, Any] = {"features": features, "project": item_counts(root / PROJECT_DIR)}
    if match is not None:
        result["match"] = match
        result["closest"] = difflib.get_close_matches(match, names, n=3)
    return result


def board(feature_dir: Path) -> dict[str, Any]:
    by_stage: dict[str, list[dict[str, str | list[str]]]] = {stage: [] for stage in STAGES}
    for path in sorted((feature_dir / "items").glob("*.md")):
        data, _ = parse_item(path)
        stage = data.get("stage", "idea")
        if isinstance(stage, str) and stage in by_stage:
            by_stage[stage].append(data)
    lines = ["# Board\n", "\n", "> Generated by dossier.py board; do not edit.\n"]
    for stage in STAGES:
        lines.extend(("\n", f"## {stage}\n", "\n", "| Item | Status | PR | Worker | Updated |\n", "|---|---|---|---|---|\n"))
        for item in sorted(by_stage[stage], key=lambda i: str(i.get("slug", ""))):
            slug = str(item.get("slug", ""))
            values = [str(item.get(key, "")).replace("|", "\\|") for key in ("status", "pr", "worker", "updated")]
            lines.append(f"| [[items/{slug}]] | {' | '.join(values)} |\n")
    path = feature_dir / "board.md"
    content = "".join(lines)
    changed = not path.exists() or path.read_text(encoding="utf-8") != content
    if changed:
        path.write_text(content, encoding="utf-8")
    return {"ok": True, "board": str(path.resolve()), "changed": changed, "items": sum(map(len, by_stage.values()))}


def git(repo: Path, *args: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", *args], cwd=repo, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        env=env, check=False,
    )


def staged(repo: Path) -> bool:
    return git(repo, "diff", "--cached", "--quiet").returncode != 0


def commit_if_staged(repo: Path, message: str) -> bool:
    if not staged(repo):
        return False
    result = git(repo, "commit", "-m", message)
    if result.returncode:
        raise RuntimeError((result.stderr or result.stdout).strip())
    return True


def conflict_paths(repo: Path) -> list[str]:
    result = git(repo, "diff", "--name-only", "--diff-filter=U")
    return [line for line in result.stdout.splitlines() if line]


def continue_board_rebase(repo: Path, board_dirs: Sequence[Path]) -> tuple[bool, list[str]]:
    """Resolve generated-board-only conflicts and finish the rebase."""
    while True:
        conflicts = conflict_paths(repo)
        if any(Path(path).name != "board.md" for path in conflicts):
            git(repo, "rebase", "--abort")
            return False, conflicts
        if not conflicts:
            return True, []
        board_paths = {(directory / "board.md").resolve() for directory in board_dirs}
        if not board_paths or any((repo / path).resolve() not in board_paths for path in conflicts):
            git(repo, "rebase", "--abort")
            return False, conflicts
        for directory in board_dirs:
            board(directory)
        for path in conflicts:
            absolute = repo / path
            if absolute.exists():
                git(repo, "add", "--", path)
        env = os.environ.copy()
        env["GIT_EDITOR"] = "true"
        continued = git(repo, "rebase", "--continue", env=env)
        if continued.returncode == 0:
            return True, []
        next_conflicts = conflict_paths(repo)
        if not next_conflicts:
            git(repo, "rebase", "--abort")
            return False, ["rebase --continue failed"]


def sync(vault: Path, message: str, board_dirs: Sequence[Path], paths: Sequence[str]) -> dict[str, Any]:
    repo = vault.resolve()
    add_paths = list(paths) or ["."]
    added = git(repo, "add", "--", *add_paths)
    if added.returncode:
        return {"ok": False, "error": (added.stderr or added.stdout).strip()}
    try:
        committed = commit_if_staged(repo, message)
    except RuntimeError as exc:
        return {"ok": False, "error": str(exc)}
    for attempt in range(1, 4):
        pulled = git(repo, "pull", "--rebase", "--autostash")
        if pulled.returncode:
            conflicts = conflict_paths(repo)
            if conflicts:
                continued, unresolved = continue_board_rebase(repo, board_dirs)
                if not continued:
                    return {"ok": False, "conflict": unresolved, "attempts": attempt}
            else:
                return {"ok": False, "error": (pulled.stderr or pulled.stdout).strip(), "attempts": attempt}
        for directory in board_dirs:
            board(directory)
        if board_dirs:
            relative_boards = [os.path.relpath(directory / "board.md", repo) for directory in board_dirs]
            added_boards = git(repo, "add", "--", *relative_boards)
            if added_boards.returncode:
                return {"ok": False, "error": (added_boards.stderr or added_boards.stdout).strip(), "attempts": attempt}
            try:
                commit_if_staged(repo, f"{message} (board)")
            except RuntimeError as exc:
                return {"ok": False, "error": str(exc), "attempts": attempt}
        pushed = git(repo, "push")
        if pushed.returncode == 0:
            return {"ok": True, "committed": committed, "attempts": attempt}
        output = f"{pushed.stdout}\n{pushed.stderr}".lower()
        rejected = "rejected" in output or "non-fast-forward" in output or "fetch first" in output
        if not rejected:
            return {"ok": False, "error": (pushed.stderr or pushed.stdout).strip(), "attempts": attempt}
    return {"ok": False, "error": "push rejected after 3 attempts", "attempts": 3}


def checks(project_dir: Path) -> dict[str, Any]:
    project_dir = project_dir.expanduser().resolve()
    settings_paths = (
        Path.home() / ".claude" / "settings.json",
        Path.home() / ".claude" / "settings.local.json",
        project_dir / ".claude" / "settings.json",
        project_dir / ".claude" / "settings.local.json",
    )
    documents = [read_json(path) for path in settings_paths]
    rules: list[str] = []
    permission_mode = None
    for document in documents:
        permissions = document.get("permissions", {})
        if not isinstance(permissions, dict):
            continue
        allow = permissions.get("allow", [])
        if isinstance(allow, list):
            rules.extend(rule for rule in allow if isinstance(rule, str))
        # settings_paths runs from lowest to highest precedence, so the last value wins.
        if isinstance(permissions.get("defaultMode"), str):
            permission_mode = permissions["defaultMode"]
    allow_rule = any(rule in ("Bash(claude --bg *)", "Bash(claude --bg:*)") for rule in rules)
    trust = read_json(Path.home() / ".claude.json").get("projects", {})
    trusted = False
    if isinstance(trust, dict):
        candidate = project_dir.parent
        while True:
            entry = trust.get(str(candidate))
            if isinstance(entry, dict) and entry.get("hasTrustDialogAccepted") is True:
                trusted = True
                break
            if candidate.parent == candidate:
                break
            candidate = candidate.parent
    fixes: list[str] = []
    if not allow_rule:
        fixes.append("run /permissions and allow Bash(claude --bg *)")
    if not trusted:
        fixes.append(f"open Claude Code in {project_dir.parent} and accept the trust dialog")
    for path in (
        Path.home() / ".claude" / "workflow-kit.json",
        project_dir / ".claude" / "workflow-kit.json",
    ):
        document = read_json(path)
        if "lead" in document and "pm" not in document:
            fixes.append(f'rename "lead" to "pm" in {path}')
    return {"allowRule": allow_rule, "trusted": trusted, "permissionMode": permission_mode, "fixes": fixes}


def make_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    resolve = sub.add_parser("resolve-vault")
    resolve.add_argument("--project-dir", default=".")
    cfg = sub.add_parser("config")
    cfg.add_argument("--project-dir", default=".")
    listing = sub.add_parser("list")
    listing.add_argument("--vault", required=True)
    listing.add_argument("--match")
    initialize = sub.add_parser("init")
    initialize.add_argument("--vault", required=True)
    initialize.add_argument("--feature", required=True)

    initialize_project = sub.add_parser("init-project")
    initialize_project.add_argument("--vault", required=True)

    item = sub.add_parser("item")
    item_sub = item.add_subparsers(dest="item_command", required=True)
    new = item_sub.add_parser("new")
    new.add_argument("--feature-dir", required=True)
    new.add_argument("--slug", required=True)
    new.add_argument("--title", required=True)
    new.add_argument("--set", action="append", default=[])
    get = item_sub.add_parser("get")
    get.add_argument("file")
    set_item = item_sub.add_parser("set")
    set_item.add_argument("file")
    set_item.add_argument("assignments", nargs="*")
    set_item.add_argument("--add", action="append", default=[])
    set_item.add_argument("--note")

    board_parser = sub.add_parser("board")
    board_parser.add_argument("--feature-dir", required=True)
    sync_parser = sub.add_parser("sync")
    sync_parser.add_argument("--vault", required=True)
    sync_parser.add_argument("-m", "--message", required=True)
    sync_parser.add_argument("--board", action="append", default=[])
    sync_parser.add_argument("paths", nargs="*")
    checks_parser = sub.add_parser("checks")
    checks_parser.add_argument("--project-dir", default=".")
    return parser


def run_cli(args: argparse.Namespace) -> dict[str, Any]:
    if args.command == "resolve-vault":
        return resolve_vault(Path(args.project_dir))
    if args.command == "config":
        return config(Path(args.project_dir))
    if args.command == "list":
        return list_features(Path(args.vault), args.match)
    if args.command == "init-project":
        return init_project(Path(args.vault))
    if args.command == "init":
        return init_dossier(Path(args.vault), args.feature)
    if args.command == "item":
        if args.item_command == "new":
            return item_new(Path(args.feature_dir), args.slug, args.title, args.set)
        if args.item_command == "get":
            return item_get(Path(args.file))
        return item_set(Path(args.file), args.assignments, args.add, args.note)
    if args.command == "board":
        return board(Path(args.feature_dir))
    if args.command == "sync":
        paths = list(args.paths)
        if paths and paths[0] == "--":
            paths.pop(0)
        return sync(Path(args.vault), args.message, [Path(path).resolve() for path in args.board], paths)
    if args.command == "checks":
        return checks(Path(args.project_dir))
    raise AssertionError(args.command)


def main(argv: Sequence[str] | None = None) -> int:
    parser = make_parser()
    args = parser.parse_args(argv)
    try:
        result = run_cli(args)
    except UsageError as exc:
        parser.error(str(exc))
    print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
