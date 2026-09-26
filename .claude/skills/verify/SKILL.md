---
name: verify
description: Verify changes in q-skills before a commit or PR; used by implement-plan's self-verify and gate-verify.
---

# Verify

Run unattended and non-interactively from the repository or worktree root. Run every check;
do not modify repository files. Checks against `origin/main...HEAD` cover committed branch
changes, while the staged and working diff checks cover uncommitted changes.

```bash
verify_tmp=$(mktemp -d)
trap 'rm -rf "$verify_tmp"' EXIT
verify_fail=0
verify_index=0

check() {
  verify_label=$1
  shift
  verify_index=$((verify_index + 1))
  verify_output="$verify_tmp/output-$verify_index"
  if ! "$@" >"$verify_output" 2>&1; then
    verify_fail=1
    printf '%s\t%s\n' "$verify_label" "$verify_output" >>"$verify_tmp/failures"
  fi
}

check diff-committed git diff --check origin/main...HEAD
check diff-staged git diff --cached --check
check diff-uncommitted git diff --check

while IFS= read -r -d '' verify_file; do
  check "bash-n:${verify_file}" bash -n "$verify_file"
done < <(find plugins .claude -type f -name '*.sh' -print0)

check py-compile env PYTHONPYCACHEPREFIX="$verify_tmp/pycache" python3 - <<'PY'
import pathlib
import py_compile

for path in pathlib.Path("plugins").rglob("*.py"):
    py_compile.compile(str(path), doraise=True)
PY

check marketplace-json jq empty .claude-plugin/marketplace.json
while IFS= read -r -d '' verify_file; do
  check "plugin-json:${verify_file}" jq empty "$verify_file"
done < <(find plugins -path '*/.claude-plugin/plugin.json' -type f -print0)

check skill-frontmatter python3 - <<'PY'
import pathlib
import re
import sys

bad = []
for path in list(pathlib.Path("plugins").rglob("SKILL.md")) + list(pathlib.Path(".claude/skills").rglob("SKILL.md")):
    text = path.read_text()
    frontmatter = re.match(r"\A---\s*\n(.*?)\n---\s*(?:\n|\Z)", text, re.S)
    if not frontmatter or not re.search(r"^name:\s*\S", frontmatter.group(1), re.M) or not re.search(r"^description:\s*\S", frontmatter.group(1), re.M):
        bad.append(str(path))
if bad:
    print(*bad, sep="\n")
    sys.exit(1)
PY

check reference-citations python3 - <<'PY'
import pathlib
import re
import subprocess
import sys

changed = subprocess.run(
    ["git", "diff", "--name-only", "origin/main...HEAD"], text=True,
    capture_output=True, check=True
).stdout.splitlines()
changed += subprocess.run(
    ["git", "diff", "--name-only"], text=True, capture_output=True, check=True
).stdout.splitlines()
changed += subprocess.run(
    ["git", "diff", "--cached", "--name-only"], text=True, capture_output=True, check=True
).stdout.splitlines()

def skill_dir(path):
    if path.name == "SKILL.md":
        return path.parent
    if path.parent.name == "references":
        return path.parent.parent
    return None

pattern = re.compile(r"references/[^\s`*_)]+\.md(?:\s+§\s*(?:\"([^\"]+)\"|`([^`]+)`))?")
heading = re.compile(r"^#{1,6}\s+(.+?)\s*#*\s*$")
errors = []
for raw in dict.fromkeys(changed):
    path = pathlib.Path(raw)
    root = skill_dir(path)
    if root is None or not path.exists():
        continue
    for lineno, line in enumerate(path.read_text().splitlines(), 1):
        for match in pattern.finditer(line):
            citation = match.group(0)
            target = root / citation.split(" § ", 1)[0]
            if not target.is_file():
                errors.append(f"{path}:{lineno}: {citation}")
                continue
            requested = match.group(1) or match.group(2)
            if requested:
                headings = [m.group(1) for m in map(heading.match, target.read_text().splitlines()) if m]
                if requested not in headings:
                    errors.append(f"{path}:{lineno}: {citation}")
if errors:
    print(*errors, sep="\n")
    sys.exit(1)
PY

if [ "$verify_fail" -eq 0 ]; then
  printf 'verify: pass\n'
else
  printf 'verify: fail\n'
  while IFS="$(printf '\t')" read -r verify_label verify_output; do
    printf '%s failed\n' "$verify_label"
    cat "$verify_output"
  done < "$verify_tmp/failures"
  exit 1
fi
```

The final block is the contract: `verify: pass` or `verify: fail`, followed by one line per
failed check and its failing output verbatim.
