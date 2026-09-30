---
name: verify
description: Verify q-skills changes before a commit or PR — whitespace/diff hygiene, shell and Python syntax, plugin/marketplace JSON, SKILL.md frontmatter, and reference-file citations. Use this whenever asked to verify, check, validate, or lint changes in this repo ("run the checks", "does this pass?", "check my skill edits"), before committing or opening a PR, and as implement-plan's self-verify and gate-verify step.
---

# Verify

Run the bundled script from anywhere inside the repository or a worktree:

```bash
bash .claude/skills/verify/scripts/verify.sh
```

The script is read-only and runs every check even after one fails, so a single run shows
all problems at once. It checks:

- `git diff --check` over committed (`origin/main...HEAD`), staged, and unstaged changes
- `bash -n` on every `*.sh` under `plugins/` and `.claude/`
- `py_compile` on every `*.py` under `plugins/`
- `jq empty` on the marketplace and every `plugin.json`
- `name:` and `description:` frontmatter on every `SKILL.md`
- In changed skill files, every cited file under `references/` exists, and any
  `§ "Heading"` suffix matches a real heading in that file

Committed changes are compared against `origin/main`, so fetch first if it may be stale.

## Output contract

The last output is `verify: pass`, or `verify: fail` followed by one `<check> failed` line
per failed check and that check's output verbatim. Report it as-is — callers such as
implement-plan parse this contract, and paraphrasing hides the exact failing line.
