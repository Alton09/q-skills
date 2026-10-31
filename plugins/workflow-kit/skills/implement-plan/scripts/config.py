#!/usr/bin/env python3
"""config.py - read, validate and merge workflow-kit.json (schema v2).

Layers, lowest to highest: shipped DEFAULTS, the user file
(~/.claude/workflow-kit.json), the project file (<project>/.claude/workflow-kit.json).
Objects merge key by key; lists and scalars replace whole.

Usage:
  config.py get <dotted.key> --project-dir D [--user-config F]
  config.py dump --project-dir D [--user-config F] [--with-sources]
  config.py defaults
  config.py legacy-check --project-dir D

Prints one JSON document on stdout. A wrong type or enum in a file exits 1 with
`config.py: <file>: <dotted key>: <problem>` on stderr. Python stdlib only.
"""
from __future__ import annotations

import argparse
import copy
import json
import os
import re
import sys
from pathlib import Path
from typing import Any

TIERS = ("light", "standard", "deep")
ROLES = ("phase", "gateVerify", "review", "prFix", "orchestrator", "prep", "e2e")
EXECUTORS = ("claude", "pi", "codex")

DEFAULTS: dict[str, Any] = {
    "minBudgetPercent": 15,
    "minBudgetPercentByRole": {"review": 25, "orchestrator": 10},
    "routing": {
        "phase": {
            "light": ["claude:haiku"],
            "standard": ["claude:sonnet"],
            "deep": ["claude:opus"],
        },
        "gateVerify": ["claude:sonnet"],
        "review": ["claude:opus"],
        "orchestrator": ["claude:opus"],
        "prep": ["claude:sonnet"],
        "e2e": ["claude:sonnet"],
    },
    "skills": {
        "verify": "/verify",
        "review": "/code-review",
        "e2e": "/e2e",
        "notify": "/notify-me",
        "createPr": "/create-pr",
    },
    "selfVerifyLimit": 2,
    "implementPlan": {
        "orchestratorModel": "opus",
        "maxParallelAgents": 3,
        "phase": {
            "timeBudget": "30m",
            "tokenCeiling": {"light": 80000, "standard": 150000, "deep": 250000},
            "codexTokenCeiling": {"light": 200000, "standard": 250000, "deep": 400000},
        },
        "escalation": {"attempts": 2, "tokenCeiling": 400000, "timeBudget": "30m"},
        "review": {"enabled": True, "autofixSeverity": "high", "maxRounds": 2},
        "e2e": {
            "enabled": True,
            "timeBudget": "45m",
            "tokenCeiling": 150000,
            "codexDeviceMode": "reserved-device",
        },
        "createPr": True,
    },
    "addressPr": {
        "fixTimeBudget": "30m",
        "botAllowlist": [
            "copilot-pull-request-reviewer",
            "copilot-pull-request-reviewer[bot]",
            "coderabbitai",
            "coderabbitai[bot]",
        ],
        "ciFixMaxRounds": 2,
        "ciWaitTimeout": "30m",
        "ciReproCommand": None,
    },
    "pm": {"vault": None, "herdr": True, "maxWorkers": 2},
}

# Leaf types: bool, posint, number, duration, string, nullstring, strlist, targets,
# ("enum", values). A dict is an object with the listed keys.
_tiers = lambda t: {k: t for k in TIERS}  # noqa: E731
SCHEMA: dict[str, Any] = {
    "minBudgetPercent": "number",
    "minBudgetPercentByRole": {r: "number" for r in ROLES},
    "routing": {
        "phase": _tiers("targets"),
        "gateVerify": "targets",
        "review": "targets",
        "prFix": "targets",
        "orchestrator": "claude_targets",
        "prep": "claude_targets",
        "e2e": "targets",
    },
    "skills": {k: "string" for k in ("verify", "review", "e2e", "notify", "createPr")},
    "selfVerifyLimit": "posint",
    "implementPlan": {
        "orchestratorModel": "string",
        "maxParallelAgents": "posint",
        "phase": {
            "timeBudget": "duration",
            "tokenCeiling": _tiers("posint"),
            "codexTokenCeiling": _tiers("posint"),
        },
        "escalation": {"attempts": "posint", "tokenCeiling": "posint", "timeBudget": "duration"},
        "review": {
            "enabled": "bool",
            "autofixSeverity": ("enum", ("critical", "high", "medium", "low")),
            "maxRounds": "posint",
        },
        "e2e": {
            "enabled": "bool",
            "timeBudget": "duration",
            "tokenCeiling": "posint",
            "codexDeviceMode": ("enum", ("reserved-device", "full-access", "off")),
        },
        "createPr": "bool",
    },
    "addressPr": {
        "fixTimeBudget": "duration",
        "botAllowlist": "strlist",
        "ciFixMaxRounds": "posint",
        "ciWaitTimeout": "duration",
        "ciReproCommand": "nullstring",
    },
    "pm": {"vault": "nullstring", "herdr": "bool", "maxWorkers": "posint"},
}

# Code copy of the design note's Migration map: old name -> new dotted key.
LEGACY: dict[str, str] = {
    "PREP_AGENT_MODEL": "routing.prep",
    "VERIFY_SKILL": "skills.verify",
    "VERIFY_AGENT_MODEL": "routing.gateVerify",
    "SELF_VERIFY_LIMIT": "selfVerifyLimit",
    "NOTIFY_SKILL": "skills.notify",
    "ORCHESTRATOR_MODEL": "implementPlan.orchestratorModel",
    "PHASE_TOKEN_CEILING": "implementPlan.phase.tokenCeiling.<tier>",
    "CODEX_PHASE_TOKEN_CEILING": "implementPlan.phase.codexTokenCeiling.<tier>",
    "PHASE_TIME_BUDGET": "implementPlan.phase.timeBudget",
    "ESCALATION_ATTEMPTS": "implementPlan.escalation.attempts",
    "ESCALATION_TOKEN_CEILING": "implementPlan.escalation.tokenCeiling",
    "ESCALATION_TIME_BUDGET": "implementPlan.escalation.timeBudget",
    "MAX_PARALLEL_AGENTS": "implementPlan.maxParallelAgents",
    "RUN_REVIEW": "implementPlan.review.enabled",
    "REVIEW_SKILL": "skills.review",
    "REVIEW_AUTOFIX_SEVERITY": "implementPlan.review.autofixSeverity",
    "REVIEW_MAX_ROUNDS": "implementPlan.review.maxRounds",
    "RUN_E2E": "implementPlan.e2e.enabled",
    "E2E_SKILL": "skills.e2e",
    "E2E_MODEL": "routing.e2e",
    "CODEX_DEVICE_MODE": "implementPlan.e2e.codexDeviceMode",
    "E2E_TIME_BUDGET": "implementPlan.e2e.timeBudget",
    "E2E_TOKEN_CEILING": "implementPlan.e2e.tokenCeiling",
    "CREATE_PR": "implementPlan.createPr",
    "PHASE_MODEL_LIGHT": "routing.phase.light",
    "PHASE_MODEL_STANDARD": "routing.phase.standard",
    "PHASE_MODEL_DEEP": "routing.phase.deep",
    "REVIEW_MODEL": "routing.review",
    "PHASE_EXECUTOR": "routing.phase.<tier>",
    "REVIEW_EXECUTOR": "routing.review",
    "PR_FIX_MODEL": "routing.prFix",
    "PR_FIX_TIME_BUDGET": "addressPr.fixTimeBudget",
    "PR_BOT_ALLOWLIST": "addressPr.botAllowlist",
    "CI_FIX_MAX_ROUNDS": "addressPr.ciFixMaxRounds",
    "CI_WAIT_TIMEOUT": "addressPr.ciWaitTimeout",
    "CI_REPRO_COMMAND": "addressPr.ciReproCommand",
}

DURATION_RE = re.compile(r"^[1-9][0-9]*[smh]$")
LAYER_RANK = {"default": 0, "user": 1, "project": 2}


class ConfigError(Exception):
    """One or more `<file>: <dotted key>: <problem>` lines."""

    def __init__(self, errors: list[str]):
        super().__init__("\n".join(errors))
        self.errors = errors


def duration_seconds(value: str) -> int:
    return int(value[:-1]) * {"s": 1, "m": 60, "h": 3600}[value[-1]]


def _is_int(v: Any) -> bool:
    return isinstance(v, int) and not isinstance(v, bool)


def _check_leaf(spec: Any, value: Any) -> str | None:
    """Return a problem string, or None when value fits spec."""
    if isinstance(spec, tuple):
        if value not in spec[1] or not isinstance(value, str):
            return f"must be one of {'|'.join(spec[1])}"
        return None
    if spec == "bool":
        return None if isinstance(value, bool) else "must be a boolean"
    if spec == "posint":
        return None if _is_int(value) and value > 0 else "must be a positive integer"
    if spec == "number":
        return None if _is_int(value) or (isinstance(value, float) and value == value) else "must be a number"
    if spec == "duration":
        if isinstance(value, str) and DURATION_RE.match(value):
            return None
        return "must be a duration like 30m, 45m, 1h (one unit s, m or h)"
    if spec == "string":
        return None if isinstance(value, str) and value != "" else "must be a non-empty string"
    if spec == "nullstring":
        return None if value is None or isinstance(value, str) else "must be a string or null"
    if spec == "strlist":
        ok = isinstance(value, list) and all(isinstance(x, str) and x for x in value)
        return None if ok else "must be an array of non-empty strings"
    if spec in ("targets", "claude_targets"):
        if not isinstance(value, list) or not value or not all(isinstance(x, str) and x for x in value):
            return "must be a non-empty array of target strings"
        for t in value:
            executor, sep, model = t.partition(":")
            if not sep:
                executor, model = "claude", t
            if executor not in EXECUTORS:
                return f'unknown executor "{executor}" in "{t}" (expected claude|pi|codex)'
            if not model:
                return f'empty model in "{t}"'
            if spec == "claude_targets" and executor != "claude":
                return f'target "{t}" must be claude:* (runs through the Agent tool)'
        return None
    raise AssertionError(f"bad schema spec {spec!r}")


def _validate(schema: Any, doc: Any, path: str, file: str, errors: list[str], warnings: list[str]) -> None:
    if isinstance(schema, dict):
        if not isinstance(doc, dict):
            errors.append(f"{file}: {path}: must be an object")
            return
        for key, val in list(doc.items()):
            dotted = f"{path}.{key}" if path else key
            if key not in schema:
                warnings.append(f"{file}: unknown key {dotted}")
                del doc[key]  # unknown keys never reach the merged config
            else:
                _validate(schema[key], val, dotted, file, errors, warnings)
        return
    problem = _check_leaf(schema, doc)
    if problem:
        errors.append(f"{file}: {path}: {problem}")


def _read_layer(file: Path, errors: list[str], warnings: list[str]) -> dict[str, Any] | None:
    if not file.is_file():
        return None
    try:
        doc = json.loads(file.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        errors.append(f"{file}: file does not parse as JSON: {exc}")
        return None
    if not isinstance(doc, dict):
        errors.append(f"{file}: top level must be an object")
        return None
    doc = dict(doc)
    if "version" in doc:
        v = doc.pop("version")
        if not (_is_int(v) and v in (1, 2)):
            errors.append(f"{file}: version: must be 1 or 2")
    if "lead" in doc and "pm" not in doc:
        doc["pm"] = doc.pop("lead")
        warnings.append(f'rename "lead" to "pm" in {file}')
    _validate(SCHEMA, doc, "", str(file), errors, warnings)
    return doc


def _merge(base: dict[str, Any], over: dict[str, Any], layer: str, sources: dict[str, str], path: str = "") -> None:
    for key, val in over.items():
        dotted = f"{path}.{key}" if path else key
        if isinstance(val, dict):
            if not isinstance(base.get(key), dict):
                base[key] = {}
            _merge(base[key], val, layer, sources, dotted)
        else:
            base[key] = copy.deepcopy(val)
            sources[dotted] = layer


def _leaf_paths(obj: dict[str, Any], path: str = "") -> list[str]:
    out: list[str] = []
    for key, val in obj.items():
        dotted = f"{path}.{key}" if path else key
        if isinstance(val, dict):
            out.extend(_leaf_paths(val, dotted))
        else:
            out.append(dotted)
    return out


def default_user_config() -> Path:
    home = os.environ.get("HOME") or os.path.expanduser("~")
    return Path(home) / ".claude" / "workflow-kit.json"


def load(project_dir: str | Path, user_config: str | Path | None = None) -> tuple[dict[str, Any], dict[str, str], list[str]]:
    """Return (merged config, {dotted leaf: layer}, warnings). Raise ConfigError."""
    errors: list[str] = []
    warnings: list[str] = []
    user_path = Path(user_config) if user_config else default_user_config()
    project_path = Path(project_dir) / ".claude" / "workflow-kit.json"
    config = copy.deepcopy(DEFAULTS)
    sources: dict[str, str] = {p: "default" for p in _leaf_paths(DEFAULTS)}
    for layer, path in (("user", user_path), ("project", project_path)):
        doc = _read_layer(path, errors, warnings)
        if doc and not errors:
            _merge(config, doc, layer, sources)
    if errors:
        raise ConfigError(errors)
    return config, sources, warnings


def _spec_for(key: str) -> Any:
    node: Any = SCHEMA
    for part in key.split("."):
        if not isinstance(node, dict) or part not in node:
            return None
        node = node[part]
    return node


def _lookup(config: dict[str, Any], key: str) -> tuple[bool, Any]:
    node: Any = config
    for part in key.split("."):
        if not isinstance(node, dict) or part not in node:
            return False, None
        node = node[part]
    return True, node


def cmd_get(args: argparse.Namespace) -> int:
    config, sources, warnings = load(args.project_dir, args.user_config)
    found, value = _lookup(config, args.key)
    result: dict[str, Any] = {"key": args.key, "value": value, "source": "none", "warnings": warnings}
    if found:
        if args.key in sources:
            result["source"] = sources[args.key]
        else:
            layers = [s for p, s in sources.items() if p.startswith(args.key + ".")]
            if layers:
                result["source"] = max(layers, key=LAYER_RANK.__getitem__)
        if _spec_for(args.key) == "duration" and isinstance(value, str):
            result["seconds"] = duration_seconds(value)
    print(json.dumps(result))
    return 0


def cmd_dump(args: argparse.Namespace) -> int:
    config, sources, warnings = load(args.project_dir, args.user_config)
    if args.with_sources:
        print(json.dumps({"config": config, "sources": sources, "warnings": warnings}))
    else:
        print(json.dumps(config))
    return 0


def cmd_defaults(_args: argparse.Namespace) -> int:
    print(json.dumps(DEFAULTS))
    return 0


def cmd_legacy_check(args: argparse.Namespace) -> int:
    hits: list[dict[str, str]] = []
    claude_md = ""
    try:
        claude_md = (Path(args.project_dir) / "CLAUDE.md").read_text(encoding="utf-8", errors="replace")
    except OSError:
        pass
    for name, new_key in LEGACY.items():
        if name in os.environ:
            hits.append({"name": name, "where": "env", "newKey": new_key})
        if claude_md and re.search(rf"(?<![A-Za-z0-9_]){re.escape(name)}(?![A-Za-z0-9_])", claude_md):
            hits.append({"name": name, "where": "CLAUDE.md", "newKey": new_key})
    warnings = [
        f"{h['name']} ({h['where']}) is ignored since workflow-kit 4.0.0; set {h['newKey']} in .claude/workflow-kit.json"
        for h in hits
    ]
    print(json.dumps({"legacy": hits, "warnings": warnings}))
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="config.py", description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="cmd", required=True)

    def common(p: argparse.ArgumentParser, user: bool = True) -> None:
        p.add_argument("--project-dir", default=os.getcwd())
        if user:
            p.add_argument("--user-config", default=None)

    p_get = sub.add_parser("get")
    p_get.add_argument("key")
    common(p_get)
    p_get.set_defaults(fn=cmd_get)
    p_dump = sub.add_parser("dump")
    common(p_dump)
    p_dump.add_argument("--with-sources", action="store_true")
    p_dump.set_defaults(fn=cmd_dump)
    sub.add_parser("defaults").set_defaults(fn=cmd_defaults)
    p_leg = sub.add_parser("legacy-check")
    common(p_leg, user=False)
    p_leg.set_defaults(fn=cmd_legacy_check)

    args = parser.parse_args(argv)
    try:
        return args.fn(args)
    except ConfigError as exc:
        for line in exc.errors:
            print(f"config.py: {line}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
