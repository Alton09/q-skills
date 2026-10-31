#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
launch="$script_dir/launch.py"
# Both helpers are also directly executable by documented worker/lead commands.
[ -x "$launch" ]
[ -x "$script_dir/events.py" ]
"$launch" --help >/dev/null
"$script_dir/events.py" --help >/dev/null
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
mkdir -p "$HOME"

check() { python3 -c "import json,sys; $1"; }
item() {
  local path=$1 stage=$2 status=$3 files=${4:-'[]'} blocked=${5:-'[]'} updated=${6:-2026-01-01T00:00:00Z}
  mkdir -p "$(dirname "$path")"
  printf '%s\n' '---' "slug: $(basename "$path" .md)" 'title: test' "stage: $stage" "status: $status" "files: $files" "blockedBy: $blocked" "updated: $updated" '---' >"$path"
}

vault_a="$tmp/alpha-vault"
vault_b="$tmp/beta-vault"
item "$vault_a/Features/alpha/items/current.md" implement queued '["shared.py"]' '["alpha/prereq"]' 2026-01-03T00:00:00Z
item "$vault_a/Features/alpha/items/prereq.md" implement idle
item "$vault_a/Features/alpha/items/paused.md" implement paused
item "$vault_b/Features/beta/items/other.md" pr running '["shared.py"]'
item "$vault_b/Features/beta/items/done.md" done running '["shared.py"]'
mkdir -p "$tmp/project/.claude"
printf '%s\n' '{"pm":{"maxWorkers":3}}' >"$tmp/project/.claude/workflow-kit.json"

capacity=$(python3 "$launch" capacity --vault "$vault_a" --project-dir "$tmp/project")
printf '%s' "$capacity" | check 'x=json.load(sys.stdin); assert (x["running"], x["max"], x["free"], len(x["queue"])) == (2, 3, 1, 1), x'
overlap=$(python3 "$launch" overlap --vault "$vault_a" --item "$vault_a/Features/alpha/items/current.md")
printf '%s' "$overlap" | check 'x=json.load(sys.stdin); assert not x["ok"]; assert any(b["why"] == "blockedBy" for b in x["blockers"]); assert any(b["lead"] == "beta" and b["why"].startswith("files:") for b in x["blockers"]), x'
# A `done` item shares files but is excluded; only active stages block.
printf '%s' "$overlap" | check 'x=json.load(sys.stdin); assert not any(b["item"].endswith("/done.md") for b in x["blockers"]), x'

# A configured vault whose name does not end in -vault still scans its own items.
item "$tmp/notes/Features/gamma/items/solo.md" implement running
capacity=$(python3 "$launch" capacity --vault "$tmp/notes" --project-dir "$tmp/project")
printf '%s' "$capacity" | check 'x=json.load(sys.stdin); assert x["running"] == 3, x'

plan="$tmp/plan.md"
printf '%s\n' '#### Task 4' '- **Module**: `plugins/workflow-kit/skills/pm/`' '- **Files**: `scripts/launch.py`, `scripts/launch.test.sh`' >"$plan"
scope=$(python3 "$launch" plan-scope "$plan")
printf '%s' "$scope" | check 'x=json.load(sys.stdin); assert "plugins/workflow-kit/skills/pm/scripts/launch.py" in x["files"], x'

# New checklist tasks may list Files over nested bullets. Do and Done-when
# commands also use backticks, so only the Files bullet's children are paths.
cat >"$plan" <<'EOF'
## Implementation Checklist
### Phase 1 — Scope
- [ ] **Task 1: Read files**
  - **Module**: `plugins/workflow-kit/skills/pm/`
  - **Files**:
    * `scripts/launch.py`
    * `scripts/launch.test.sh`
  - **Do**:
    - Run `python3 scripts/launch.py plan-scope`
  - **Done when**:
    - [ ] `bash scripts/launch.test.sh` passes.
- [ ] **Task 2: Check scope**
  - **Module**: `plugins/workflow-kit/skills/pm/`
  - **Files**: `scripts/launch.test.sh`
  - **Depends on**: Task 1
  - **Do**:
    - Check `plan-scope` output.
  - **Done when**:
    - [ ] Duplicate paths appear once.
### Phase 2 — Template (depends on Phase 1)
- [ ] **Task 3: Check template**
  - **Module**: `plugins/workflow-kit/skills/feature-plan/`
  - **Files**: `references/plan-template.md`
  - **Do**:
    - Read `references/plan-template.md`.
  - **Done when**:
    - [ ] Fields match the scope fixture.
EOF
scope=$(python3 "$launch" plan-scope "$plan")
printf '%s' "$scope" | check 'x=json.load(sys.stdin); assert x["files"] == ["plugins/workflow-kit/skills/pm/scripts/launch.py", "plugins/workflow-kit/skills/pm/scripts/launch.test.sh", "plugins/workflow-kit/skills/feature-plan/references/plan-template.md"], x'
{ printf '%s\n' '---' 'status: planned' '---'; cat "$plan"; } >"$tmp/plan-frontmatter.md"
frontmatter_scope=$(python3 "$launch" plan-scope "$tmp/plan-frontmatter.md")
[ "$frontmatter_scope" = "$scope" ]

item "$vault_a/Features/alpha/items/implement.md" implement queued
python3 "$script_dir/dossier.py" item set "$vault_a/Features/alpha/items/implement.md" "plan=$plan" >/dev/null
command=$(python3 "$launch" command --item "$vault_a/Features/alpha/items/implement.md" --kind implement --model opus --repo "$tmp/project")
item_path="$vault_a/Features/alpha/items/implement.md"
export item_path
printf '%s' "$command" | check 'import os; x=json.load(sys.stdin); assert x["argv"][:4] == ["claude", "--bg", "--permission-mode", "auto"], x; assert json.loads(x["argv"][x["argv"].index("--settings") + 1])["env"] == {"PR_RETRO_NUDGE": "0", "HERDR_ENV": "0"}, x; assert "--worker" in x["prompt"] and os.path.abspath(os.environ["item_path"]) in x["prompt"], x; assert "--rules" not in x["prompt"], x'
printf '%s' "$command" | check 'x=json.load(sys.stdin); assert "--notify-cmd" not in x["prompt"], x'

# Herdr settings are fixed even when the calling shell has herdr variables.
herdr_command=$(HERDR_ENV=1 HERDR_PANE_ID=lead-pane python3 "$launch" command --item "$item_path" --kind implement --model opus --repo "$tmp/project")
printf '%s' "$herdr_command" | check 'import json,sys; x=json.load(sys.stdin); assert x["argv"][:4] == ["claude", "--bg", "--permission-mode", "auto"], x; assert json.loads(x["argv"][x["argv"].index("--settings") + 1])["env"] == {"PR_RETRO_NUDGE": "0", "HERDR_ENV": "0"}, x'

# A relative item plan is vault-relative, and --notify-cmd fills the protocol command.
python3 "$script_dir/dossier.py" item set "$item_path" "plan=Plans/relative.md" >/dev/null
notify="$tmp/notify me.sh"
command=$(python3 "$launch" command --item "$item_path" --kind implement --model opus --repo "$tmp/project" --notify-cmd "$notify")
export vault_a notify
printf '%s' "$command" | check 'import os, shlex; x=json.load(sys.stdin); p=x["prompt"]; assert "/workflow-kit:implement-plan " + os.environ["vault_a"] + "/Plans/relative.md --worker" in p, p; assert "--notify-cmd " + shlex.quote(os.environ["notify"]) + " <<" in p, p; assert "<notify-cmd>" not in p, p'

python3 - "$launch" "$script_dir/../references/workers.md" <<'PY'
import ast
import re
import sys
from pathlib import Path

launch, workers = map(Path, sys.argv[1:])
tree = ast.parse(launch.read_text(encoding="utf-8"))
constant = next(
    node.value.value
    for node in tree.body
    if isinstance(node, ast.Assign)
    for target in node.targets
    if isinstance(target, ast.Name) and target.id == "WORKER_PROTOCOL"
)
match = re.search(r"^## Worker protocol\n.*?^```text\n(.*?)^```$", workers.read_text(encoding="utf-8"), re.MULTILINE | re.DOTALL)
assert "use python3 {events_path} worker-event" in constant
assert "python3 {events_arg} worker-event --item {item_arg}" in constant
assert "--line-file -{notify_arg} <<'PM_EVENT'" in constant
assert '--line "' not in constant
assert "<notify-cmd>" not in constant
assert "<first line>" not in constant
assert match, "workers.md has no Worker protocol text block"
assert match.group(1).rstrip("\n") == constant, "workers.md protocol differs from launch.py WORKER_PROTOCOL"
PY

# Standalone items share the project label for workers and resolved dependencies.
standalone="$vault_a/Features/_project/items/fix-x.md"
item "$standalone" implement idle
command=$(python3 "$launch" command --item "$standalone" --kind ci --model opus --repo "$tmp/project" --pr 42 --worktree "$tmp/project")
printf '%s' "$command" | check 'x=json.load(sys.stdin); assert x["name"] == "project-fix-x-ci", x; assert x["argv"][x["argv"].index("-n") + 1] == "project-fix-x-ci", x'
item "$vault_a/Features/alpha/items/dependent.md" implement queued '[]' '["project/fix-x"]'
export standalone
overlap=$(python3 "$launch" overlap --vault "$vault_a" --item "$vault_a/Features/alpha/items/dependent.md")
printf '%s' "$overlap" | check 'import os; x=json.load(sys.stdin); assert x == {"ok":False,"blockers":[{"item":os.environ["standalone"],"lead":"project","why":"blockedBy"}]}, x'
# A completed project prerequisite resolves rather than remaining an unknown blocker.
python3 "$script_dir/dossier.py" item set "$standalone" stage=done >/dev/null
python3 "$launch" overlap --vault "$vault_a" --item "$vault_a/Features/alpha/items/dependent.md" | check 'x=json.load(sys.stdin); assert x == {"ok":True,"blockers":[]}, x'

printf 'launch.test.sh: pass\n'
