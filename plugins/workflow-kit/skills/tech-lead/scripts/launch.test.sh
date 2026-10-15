#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
launch="$script_dir/launch.py"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

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
printf '%s\n' '{"lead":{"maxWorkers":3}}' >"$tmp/project/.claude/workflow-kit.json"

capacity=$(python3 "$launch" capacity --vault "$vault_a" --project-dir "$tmp/project")
printf '%s' "$capacity" | check 'x=json.load(sys.stdin); assert (x["running"], x["max"], x["free"], len(x["queue"])) == (2, 3, 1, 1), x'
overlap=$(python3 "$launch" overlap --vault "$vault_a" --item "$vault_a/Features/alpha/items/current.md")
printf '%s' "$overlap" | check 'x=json.load(sys.stdin); assert not x["ok"]; assert any(b["why"] == "blockedBy" for b in x["blockers"]); assert any(b["lead"] == "beta" and b["why"].startswith("files:") for b in x["blockers"]), x'

plan="$tmp/plan.md"
printf '%s\n' '#### Task 4' '- **Module**: `plugins/workflow-kit/skills/tech-lead/`' '- **Files**: `scripts/launch.py`, `scripts/launch.test.sh`' >"$plan"
scope=$(python3 "$launch" plan-scope "$plan")
printf '%s' "$scope" | check 'x=json.load(sys.stdin); assert "plugins/workflow-kit/skills/tech-lead/scripts/launch.py" in x["files"], x'

item "$vault_a/Features/alpha/items/implement.md" implement queued
python3 "$script_dir/dossier.py" item set "$vault_a/Features/alpha/items/implement.md" "plan=$plan" >/dev/null
command=$(python3 "$launch" command --item "$vault_a/Features/alpha/items/implement.md" --kind implement --model opus --repo "$tmp/project")
item_path="$vault_a/Features/alpha/items/implement.md"
export item_path
printf '%s' "$command" | check 'import os; x=json.load(sys.stdin); assert x["argv"][:2] == ["claude", "--bg"], x; assert "--worker" in x["prompt"] and os.path.abspath(os.environ["item_path"]) in x["prompt"], x; assert "--rules" not in x["prompt"], x'

printf 'launch.test.sh: pass\n'
