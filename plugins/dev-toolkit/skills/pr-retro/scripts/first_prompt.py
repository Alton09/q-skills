#!/usr/bin/env python3
"""Print the first real user prompt of a Claude Code session JSONL, one line.

Skips meta messages, `/clear` command echoes, local-command output and
`Caveat:` preambles. A slash-command prompt is shown as
`<command-name> <command-args>`.
"""
import json
import re
import sys

SKIP = ("<local-command", "Caveat:")


def text_of(content):
    if isinstance(content, str):
        return content
    return " ".join(
        b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text"
    )


def tag(name, s):
    m = re.search(rf"<{name}>(.*?)</{name}>", s, re.S)
    return m.group(1).strip() if m else ""


def first_prompt(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if d.get("type") != "user" or d.get("isMeta"):
                continue
            t = text_of(d.get("message", {}).get("content", "")).strip()
            if not t or t.startswith(SKIP) or "<command-name>/clear" in t:
                continue
            if "<command-name>" in t:
                t = f"{tag('command-name', t)} {tag('command-args', t)}".strip()
            return " ".join(t.split())[:200]
    return ""


if __name__ == "__main__":
    for p in sys.argv[1:]:
        print(f"{p}\t{first_prompt(p)}")
