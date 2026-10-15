#!/usr/bin/env bash
# Hermetic tests for events.py. Stubs ensure no GitHub, Claude, or notifications run for real.
set -u

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script="$here/events.py"
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
mkdir -p "$HOME" "$tmp/bin" "$tmp/repo" "$tmp/vault/Features/alpha/items"
export PATH="$tmp/bin:$PATH"
export GH_BODY='{"headRefName":"feat/alpha","body":""}'

cat >"$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$GH_BODY"
EOF
cat >"$tmp/bin/git" <<'EOF'
#!/usr/bin/env bash
printf 'worktree %s\nbranch refs/heads/feat/alpha\n\n' "${WORKTREE_FIXTURE:-/tmp/worktree}"
EOF
cat >"$tmp/bin/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${CLAUDE_AGENTS:-[] }"
EOF
chmod +x "$tmp/bin/gh" "$tmp/bin/git" "$tmp/bin/claude"

n=0 out=
fail() { echo "FAIL case $n: $1" >&2; [ -n "$out" ] && echo "  output: $out" >&2; exit 1; }
pass() { echo "ok $n"; }
expect() { actual=$(jq -c "$1" <<<"$out") || fail "not JSON"; [ "$actual" = "$2" ] || fail "$1 = $actual, expected $2"; }
run() { out=$(python3 "$script" "$@"); rc=$?; [ "$rc" -eq 0 ] || fail "exit $rc"; }
new_item() { local slug=$1 kind=${2:-implement}; cat >"$tmp/vault/Features/alpha/items/$slug.md" <<EOF
---
slug: $slug
title: $slug
stage: implement
status: running
worker: alpha-$slug
workerKind: $kind
notified: []
---
EOF
printf '%s\n' "$tmp/vault/Features/alpha/items/$slug.md"; }
item=$(new_item plan)

# 1. feature-plan done mapping.
n=1
run worker-event --item "$item" --line 'feature-plan: done plans/alpha.md' --no-sync
expect .event '"plan-done"'; expect .push '"[alpha] plan-done — plans/alpha.md"'
expect .synced false
grep -Fq 'stage: plan' "$item" || fail 'plan stage'; grep -Fq 'plan: plans/alpha.md' "$item" || fail 'plan path'
pass

# 2. implementation PR mapping, worktree discovery, and two unplanned decisions.
n=2
item=$(new_item impl)
export WORKTREE_FIXTURE="$tmp/wt-alpha"
export GH_BODY='{"headRefName":"feat/alpha","body":"### Unplanned Decisions\n- chose one\n- chose two\n\n### Other\ntext"}'
run worker-event --item "$item" --repo "$tmp/repo" --line 'implement-plan: done alpha https://example.invalid/pr/1' --no-sync
expect .event null; expect .push null
grep -Fq 'stage: pr' "$item" || fail 'pr stage'; grep -Fq 'worktree: '"$tmp/wt-alpha" "$item" || fail 'worktree'
grep -Fq 'unplanned: 2' "$item" || fail 'unplanned two'
pass

# 3. - None counts as zero.
n=3
item=$(new_item none)
export GH_BODY='{"headRefName":"feat/alpha","body":"### Unplanned Decisions\n- None\n"}'
run worker-event --item "$item" --repo "$tmp/repo" --line 'implement-plan: done alpha https://example.invalid/pr/2' --no-sync
grep -Fq 'unplanned: 0' "$item" || fail 'unplanned none'
pass

# 4. pr-skipped maps to stuck and sends stuck.
n=4
item=$(new_item skipped)
run worker-event --item "$item" --line 'implement-plan: done alpha pr-skipped' --no-sync
expect .event '"stuck"'; grep -Fq 'status: stuck' "$item" || fail 'not stuck'
pass

# 5. stopped supports both documented unknown spellings.
n=5
item=$(new_item stopped)
run worker-event --item "$item" --line 'implement-plan: stopped <unknown> pre-flight' --no-sync
expect .event '"stuck"'; grep -Fq 'pre-flight' "$item" || fail 'phase note'
item=$(new_item stoppedliteral)
run worker-event --item "$item" --line 'implement-plan: stopped unknown step-9' --no-sync
expect .event '"stuck"'
pass

# 6. address-pr comments increments a round and notifies.
n=6
item=$(new_item comments comments)
run worker-event --item "$item" --line 'address-pr: done #12 abcdef' --no-sync
expect .event '"fix-pushed-1"'; grep -Fq 'round: 1' "$item" || fail 'round'
pass

# 7. address-pr ci and sync are logged only; no-push records a note.
n=7
item=$(new_item ci ci)
run worker-event --item "$item" --line 'address-pr: done #12 abcdef' --no-sync
expect .event null
item=$(new_item sync sync)
run worker-event --item "$item" --line 'address-pr: done #12 abcdef' --no-sync
expect .event null
item=$(new_item nopush comments)
run worker-event --item "$item" --line 'address-pr: done #12 no-push' --no-sync
expect .event null; grep -Fq 'without a push' "$item" || fail 'no-push note'
pass

# 8. needs input finds Question, includes attach, and deduplicates the same block.
n=8
item=$(new_item pause)
block=$'address-pr: needs input #12\nQuestion: Keep the old API?\nOptions:\n1. Yes'
run worker-event --item "$item" --line "$block" --no-sync
expect .event '"paused-#12"'; expect .push '"[alpha] paused-#12 — Keep the old API?; claude attach alpha-pause"'
run worker-event --item "$item" --line "$block" --no-sync
expect .push null
pass

# 9. last-reply reads the fixture transcript and extracts its final status line.
n=9
slug=$(realpath "$tmp/repo" | sed 's#[/.]#-#g')
mkdir -p "$HOME/.claude/projects/$slug"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"working"}]}}' '{"type":"assistant","message":{"content":[{"type":"text","text":"finished\nfeature-plan: done /plans/a.md"}]}}' >"$HOME/.claude/projects/$slug/s1.jsonl"
run last-reply --session s1 --cwd "$tmp/repo"
expect .line '"feature-plan: done /plans/a.md"'; expect '.reply | contains("feature-plan: done /plans/a.md")' true
pass

# 10. agents preserves status, state, and waitingFor from the Claude stub.
n=10
export CLAUDE_AGENTS='[{"name":"alpha","status":"idle","state":"done","waitingFor":null}]'
run agents
expect '.byName.alpha.status' '"idle"'
pass
