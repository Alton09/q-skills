#!/usr/bin/env python3
"""Digest a Claude Code session JSONL into a readable summary.

Usage:
    digest.py <session.jsonl> [--full]

Default output includes:
  - user messages (truncated to 1500 chars)
  - assistant text blocks (truncated to 800 chars)
  - Skill tool invocations with args
  - AskUserQuestion answers (tool results containing "have been answered")
  - tool results with is_error: true

--full also prints one line per tool call (command, file_path, or description).

Each line is prefixed [HH:MM:SS] from the event timestamp. Parse errors are
silently skipped.
"""
import json
import sys


def ts(event):
    stamp = event.get("timestamp") or ""
    return stamp[11:19] if len(stamp) >= 19 else ""


def text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text":
                parts.append(block["text"])
        return "\n".join(parts)
    return ""


def main():
    args = sys.argv[1:]
    if not args:
        print("usage: digest.py <session.jsonl> [--full]", file=sys.stderr)
        sys.exit(1)

    full = "--full" in args
    path = next((a for a in args if not a.startswith("--")), None)
    if path is None:
        print("usage: digest.py <session.jsonl> [--full]", file=sys.stderr)
        sys.exit(1)

    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            raw = raw.strip()
            if not raw:
                continue
            try:
                event = json.loads(raw)
            except Exception:
                continue

            t = event.get("type")
            msg = event.get("message") or {}
            t_stamp = ts(event)
            content = msg.get("content")

            if t == "user" and not event.get("isMeta"):
                if isinstance(content, str):
                    if content.strip():
                        print(f"\n[{t_stamp}] USER: {content[:1500]}")
                elif isinstance(content, list):
                    for block in content:
                        if not isinstance(block, dict):
                            continue
                        if block.get("type") == "text":
                            text = block.get("text", "").strip()
                            if text:
                                print(f"\n[{t_stamp}] USER: {text[:1500]}")
                        elif block.get("type") == "tool_result":
                            res = block.get("content", "")
                            res_str = res if isinstance(res, str) else json.dumps(res)
                            if block.get("is_error"):
                                print(f"[{t_stamp}]   ERR: {res_str[:400]}")
                            elif "have been answered" in res_str:
                                print(f"[{t_stamp}]   ANSWER: {res_str[:800]}")

            elif t == "assistant" and isinstance(content, list):
                for block in content:
                    if not isinstance(block, dict):
                        continue
                    if block.get("type") == "text":
                        text = block.get("text", "").strip()
                        if text:
                            print(f"[{t_stamp}] ASSIST: {text[:800]}")
                    elif block.get("type") == "tool_use":
                        name = block.get("name", "")
                        inp = block.get("input") or {}
                        if name == "Skill":
                            skill_name = inp.get("skill", "")
                            skill_args = inp.get("args", "")
                            print(f"[{t_stamp}] >>SKILL {skill_name} {skill_args}"[:500])
                        elif full:
                            detail = (
                                inp.get("command")
                                or inp.get("file_path")
                                or inp.get("description")
                                or json.dumps(inp)[:200]
                            )
                            print(f"[{t_stamp}]   {name}: {str(detail)[:200]}")


if __name__ == "__main__":
    main()
