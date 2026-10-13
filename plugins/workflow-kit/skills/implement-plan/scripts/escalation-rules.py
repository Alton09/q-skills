#!/usr/bin/env python3
"""Merge escalation-rule layers and check changed paths against guardrails."""

import argparse
import fnmatch
import json
import re
import sys
from pathlib import Path


def error(message):
    print(f"escalation-rules.py: {message}", file=sys.stderr)
    raise SystemExit(2)


def blank_fences(text):
    """Blank fenced-code lines so examples cannot become rules."""
    lines, kept, fenced = text.splitlines(), [], False
    for line in lines:
        if re.match(r"^\s*(```|~~~)", line):
            fenced = not fenced
        if not fenced:
            kept.append(line)
        else:
            kept.append("")
    return "\n".join(kept)


def section(text, wanted):
    """Return a level-two section, ignoring headings inside fenced code blocks."""
    kept = blank_fences(text).splitlines()
    heading = re.compile(r"^##\s+(.+?)\s*$", re.I)
    start = None
    for index, line in enumerate(kept):
        match = heading.match(line)
        if match and match.group(1).strip().lower() == wanted.lower():
            start = index + 1
            break
    if start is None:
        return None
    end = len(kept)
    for index in range(start, len(kept)):
        if heading.match(kept[index]):
            end = index
            break
    return "\n".join(kept[start:end])


def parse_rules(text, source, use_escalation):
    selected = section(text, "Escalation") if use_escalation else text
    if selected is None:
        selected = blank_fences(text)
    result = {"ask": [], "guardrails": [], "loosen": [], "warnings": []}
    current = None
    heading = re.compile(r"^###\s+(.+?)\s*$", re.I)
    for raw in selected.splitlines():
        if re.match(r"^#{1,2}\s+", raw):
            current = None
            continue
        match = heading.match(raw)
        if match:
            current = match.group(1).strip().lower()
            if current not in ("ask", "guardrail paths", "loosen"):
                result["warnings"].append(f"{source}: unknown heading: {match.group(1).strip()}")
            continue
        bullet = re.match(r"^\s*-\s+(.+?)\s*$", raw)
        if not bullet:
            continue
        value = bullet.group(1)
        if current == "ask":
            result["ask"].append(value)
        elif current == "guardrail paths":
            pattern = re.match(r"^`([^`]+)`(?:\s.*)?$", value)
            if pattern:
                result["guardrails"].append(pattern.group(1))
            else:
                result["warnings"].append(f"{source}: malformed guardrail bullet: {value}")
        elif current == "loosen":
            parts = re.split(r"\s+(?:—|--)\s+", value, maxsplit=1)
            if len(parts) != 2 or not parts[0] or not parts[1]:
                result["warnings"].append(f"{source}: malformed loosen bullet: {value}")
            else:
                target = parts[0]
                pattern = re.fullmatch(r"`([^`]+)`", target)
                if pattern:
                    result["loosen"].append(("pattern", pattern.group(1), parts[1]))
                else:
                    result["loosen"].append(("rule", target, parts[1]))
        elif current is not None:
            result["warnings"].append(f"{source}: bullet under unknown heading: {value}")
    return result


def path_matches(pattern, path):
    directory = pattern.endswith("/")
    pattern, path = pattern.strip("/"), path.strip("/")
    if not pattern:
        return False
    if directory:
        if "/" not in pattern:
            parts = path.split("/")
            return any(fnmatch.fnmatchcase(part, pattern) for part in parts[:-1])
    if "/" not in pattern:
        return any(fnmatch.fnmatchcase(part, pattern) for part in path.split("/"))
    regex = ""
    index = 0
    while index < len(pattern):
        char = pattern[index]
        if char == "*" and index + 1 < len(pattern) and pattern[index + 1] == "*":
            index += 2
            if index < len(pattern) and pattern[index] == "/":
                regex += "(?:.*/)?"
                index += 1
            else:
                regex += ".*"
            continue
        if char == "*": regex += "[^/]*"
        elif char == "?": regex += "[^/]"
        else: regex += re.escape(char)
        index += 1
    suffix = r"(?:/.*)?" if directory else ""
    return re.fullmatch(regex + suffix, path) is not None


def load_file(path):
    try:
        return Path(path).read_text(encoding="utf-8")
    except OSError:
        error(f"rules file not readable: {path}")


def merged(rule_paths, no_defaults):
    layers, ask, guardrails, loosened, warnings = [], [], [], [], []
    inputs = []
    if not no_defaults:
        default_path = Path(__file__).resolve().parent.parent / "references" / "escalation-rules.md"
        defaults = section(load_file(default_path), "Defaults")
        inputs.append(("default", str(default_path), defaults or "", False))
    for given in rule_paths:
        path = Path(given)
        if not path.is_file():
            error(f"rules file not readable: {given}")
        inputs.append((given, given, load_file(path), True))
    for name, path, text, is_rule_file in inputs:
        layers.append({"name": name, "path": path})
        parsed = parse_rules(text, path, is_rule_file)
        warnings.extend(parsed["warnings"])
        ask.extend({"rule": rule, "layer": name} for rule in parsed["ask"])
        base = Path(path).parent
        for kind, target, note in parsed["loosen"]:
            design = base / note
            if not design.is_file():
                warnings.append(f"{path}: design note not found: {note}")
                continue
            entry = {kind: target, "layer": name, "designNote": note}
            loosened.append(entry)
            if kind == "pattern":
                guardrails[:] = [item for item in guardrails if item["pattern"] != target]
            else:
                ask[:] = [item for item in ask if item["rule"] != target]
        guardrails.extend({"pattern": pattern, "layer": name} for pattern in parsed["guardrails"])
    return {"layers": layers, "ask": ask, "guardrails": guardrails,
            "loosened": loosened, "warnings": warnings}


def read_lines(path, label):
    if path == "-":
        return [line.strip() for line in sys.stdin.read().splitlines() if line.strip()]
    try:
        return [line.strip() for line in Path(path).read_text(encoding="utf-8").splitlines() if line.strip()]
    except OSError:
        error(f"{label} file not readable: {path}")


def is_named(path, named):
    return any(path.startswith(item) if item.endswith("/") else path == item for item in named)


def main():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("command", nargs="?")
    parser.add_argument("--rules", action="append", default=[])
    parser.add_argument("--no-defaults", action="store_true")
    parser.add_argument("--changed")
    parser.add_argument("--named")
    args, extra = parser.parse_known_args()
    if extra or args.command not in ("merge", "check"):
        error("usage: merge or check")
    if args.command == "check" and (args.changed is None or args.named is None):
        error("check requires --changed and --named")
    if args.command == "merge" and (args.changed is not None or args.named is not None):
        error("--changed and --named are only valid with check")
    output = merged(args.rules, args.no_defaults)
    if args.command == "check":
        changed, named, hits = read_lines(args.changed, "changed"), read_lines(args.named, "named"), []
        for path in changed:
            if is_named(path, named):
                continue
            for guardrail in output["guardrails"]:
                if path_matches(guardrail["pattern"], path):
                    hits.append({"path": path, "pattern": guardrail["pattern"], "layer": guardrail["layer"]})
                    break
        output["hits"] = hits
    print(json.dumps(output, separators=(",", ":")))


if __name__ == "__main__":
    main()
