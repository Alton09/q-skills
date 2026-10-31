#!/usr/bin/env bash
# Tests for config.py. Hermetic: fixtures live in a mktemp dir, HOME points at it, and
# every env var named in the LEGACY table is cleared. Prints `ok <n>` per case and exits
# non-zero on the first failure, naming the case.
set -u

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script="$here/config.py"
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
mkdir -p "$HOME/.claude" "$tmp/proj/.claude" "$tmp/empty"
user="$HOME/.claude/workflow-kit.json"
proj="$tmp/proj/.claude/workflow-kit.json"

# Clear every legacy name from the host environment.
for name in $(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import config; print(" ".join(config.LEGACY))' "$here"); do
  unset "$name"
done

n=0
out=""
err=""
rc=0
fail() {
  echo "FAIL case $n: $1" >&2
  [ -n "$out" ] && echo "  output: $out" >&2
  [ -n "$err" ] && echo "  stderr: $err" >&2
  exit 1
}
pass() { echo "ok $n"; }
next() { n=$((n + 1)); }

# run <args...>: capture stdout, stderr and exit code of config.py.
run() {
  out=$(python3 "$script" "$@" 2>"$tmp/err")
  rc=$?
  err=$(cat "$tmp/err")
}
expect() {
  verify_actual=$(jq -c "$1" <<<"$out" 2>/dev/null) || fail "output is not JSON ($1)"
  [ "$verify_actual" = "$2" ] || fail "$1 = $verify_actual, expected $2"
}
expect_rc() { [ "$rc" = "$1" ] || fail "exit $rc, expected $1"; }
expect_err() {
  case "$err" in *"$1"*) ;; *) fail "stderr lacks: $1" ;; esac
}
reset() { rm -f "$user" "$proj" "$tmp/proj/CLAUDE.md"; }

# 1 defaults only
next; reset
run dump --project-dir "$tmp/empty"
expect_rc 0
expect '.implementPlan.review.autofixSeverity' '"high"'
expect '.routing.orchestrator' '["claude:opus"]'
expect '.pm' '{"vault":null,"herdr":true,"maxWorkers":2}'
run defaults
expect_rc 0
expect '.routing.phase.light' '["claude:haiku"]'
run get implementPlan.phase.timeBudget --project-dir "$tmp/empty"
expect '[.value, .seconds, .source]' '["30m",1800,"default"]'
run get nope.key --project-dir "$tmp/empty"
expect '[.value, .source]' '[null,"none"]'
pass

# 2 user only
next; reset
echo '{"version":2,"implementPlan":{"review":{"maxRounds":5}}}' >"$user"
run get implementPlan.review.maxRounds --project-dir "$tmp/empty"
expect '[.value, .source]' '[5,"user"]'
pass

# 3 project over user
next; reset
echo '{"selfVerifyLimit":3}' >"$user"
echo '{"selfVerifyLimit":4}' >"$proj"
run get selfVerifyLimit --project-dir "$tmp/proj"
expect '[.value, .source]' '[4,"project"]'
pass

# 4 list replace
next; reset
echo '{"routing":{"review":["claude:sonnet","codex:gpt-5"]}}' >"$user"
echo '{"routing":{"review":["claude:opus"]}}' >"$proj"
run get routing.review --project-dir "$tmp/proj"
expect '[.value, .source]' '[["claude:opus"],"project"]'
pass

# 5 object merge key by key, object source is the highest layer
next; reset
echo '{"implementPlan":{"review":{"maxRounds":5,"autofixSeverity":"medium"}}}' >"$user"
echo '{"implementPlan":{"review":{"autofixSeverity":"low"}}}' >"$proj"
run get implementPlan.review --project-dir "$tmp/proj"
expect '.value' '{"enabled":true,"autofixSeverity":"low","maxRounds":5}'
expect '.source' '"project"'
run dump --project-dir "$tmp/proj" --with-sources
expect '.sources["implementPlan.review.maxRounds"]' '"user"'
expect '.sources["implementPlan.review.enabled"]' '"default"'
expect '.sources["routing.review"]' '"default"'
expect '.sources["addressPr.botAllowlist"]' '"default"'
expect '.config.implementPlan.review.autofixSeverity' '"low"'
pass

# 6 duration seconds
next; reset
echo '{"addressPr":{"ciWaitTimeout":"1h","fixTimeBudget":"90s"}}' >"$proj"
run get addressPr.ciWaitTimeout --project-dir "$tmp/proj"
expect '[.value, .seconds, .source]' '["1h",3600,"project"]'
run get addressPr.fixTimeBudget --project-dir "$tmp/proj"
expect '.seconds' '90'
echo '{"addressPr":{"ciWaitTimeout":"30 min"}}' >"$proj"
run get addressPr.ciWaitTimeout --project-dir "$tmp/proj"
expect_rc 1
expect_err "addressPr.ciWaitTimeout"
pass

# 7 every enum error
next; reset
for bad in \
  '{"implementPlan":{"review":{"autofixSeverity":"lowest"}}}|implementPlan.review.autofixSeverity' \
  '{"implementPlan":{"e2e":{"codexDeviceMode":"yolo"}}}|implementPlan.e2e.codexDeviceMode' \
  '{"routing":{"review":["gemini:pro"]}}|routing.review'; do
  echo "${bad%%|*}" >"$proj"
  run dump --project-dir "$tmp/proj"
  expect_rc 1
  expect_err "config.py: $proj: ${bad##*|}: "
done
for good in low medium high critical; do
  echo "{\"implementPlan\":{\"review\":{\"autofixSeverity\":\"$good\"}}}" >"$proj"
  run dump --project-dir "$tmp/proj"; expect_rc 0
done
for good in reserved-device full-access off; do
  echo "{\"implementPlan\":{\"e2e\":{\"codexDeviceMode\":\"$good\"}}}" >"$proj"
  run dump --project-dir "$tmp/proj"; expect_rc 0
done
pass

# 8 wrong type names key and file
next; reset
echo '{"implementPlan":{"maxParallelAgents":"three"}}' >"$user"
run dump --project-dir "$tmp/empty"
expect_rc 1
expect_err "$user"
expect_err "implementPlan.maxParallelAgents"
echo '{"pm":{"herdr":"yes"}}' >"$proj"
rm -f "$user"
run dump --project-dir "$tmp/proj"
expect_rc 1
expect_err "pm.herdr"
echo '{"implementPlan":{"createPr":1,"phase":{"tokenCeiling":{"light":0}}}}' >"$proj"
run dump --project-dir "$tmp/proj"
expect_rc 1
expect_err "implementPlan.createPr"
expect_err "implementPlan.phase.tokenCeiling.light"
echo '{not json' >"$proj"
run dump --project-dir "$tmp/proj"
expect_rc 1
expect_err "$proj"
pass

# 9 unknown key warning
next; reset
echo '{"bogus":1,"implementPlan":{"nope":true}}' >"$proj"
run dump --project-dir "$tmp/proj" --with-sources
expect_rc 0
expect '.warnings | length' '2'
expect '.warnings[0] | contains("unknown key bogus")' 'true'
expect '.warnings[1] | contains("unknown key implementPlan.nope")' 'true'
expect '.config | has("bogus")' 'false'
pass

# 10 version handling
next; reset
for v in '"version":1,' '"version":2,' ''; do
  echo "{$v\"selfVerifyLimit\":3}" >"$proj"
  run get selfVerifyLimit --project-dir "$tmp/proj"
  expect_rc 0
  expect '.value' '3'
done
echo '{"version":3}' >"$proj"
run dump --project-dir "$tmp/proj"
expect_rc 1
expect_err "version"
pass

# 11 lead alias
next; reset
echo '{"lead":{"vault":"/v","herdr":false}}' >"$proj"
run get pm --project-dir "$tmp/proj"
expect_rc 0
expect '.value.vault' '"/v"'
expect '.value.herdr' 'false'
expect '.warnings' "[\"rename \\\"lead\\\" to \\\"pm\\\" in $proj\"]"
echo '{"lead":{"vault":"/old"},"pm":{"vault":"/new"}}' >"$proj"
run get pm.vault --project-dir "$tmp/proj"
expect '.value' '"/new"'
pass

# 12 prep and orchestrator accept claude:* only
next; reset
echo '{"routing":{"prep":["haiku"],"orchestrator":["claude:opus","claude:sonnet"]}}' >"$proj"
run dump --project-dir "$tmp/proj"; expect_rc 0
echo '{"routing":{"prep":["codex:gpt-5"]}}' >"$proj"
run dump --project-dir "$tmp/proj"; expect_rc 1; expect_err "routing.prep"
echo '{"routing":{"orchestrator":["pi:x"]}}' >"$proj"
run dump --project-dir "$tmp/proj"; expect_rc 1; expect_err "routing.orchestrator"
echo '{"routing":{"phase":{"deep":["codex:gpt-5","pi:x"]}}}' >"$proj"
run dump --project-dir "$tmp/proj"; expect_rc 0
echo '{"minBudgetPercentByRole":{"review":30,"typo":1}}' >"$proj"
run dump --project-dir "$tmp/proj" --with-sources; expect_rc 0
expect '.warnings[0] | contains("unknown key minBudgetPercentByRole.typo")' 'true'
echo '{"minBudgetPercentByRole":{"review":"x"}}' >"$proj"
run dump --project-dir "$tmp/proj"; expect_rc 1; expect_err "minBudgetPercentByRole.review"
pass

# 13 missing user file is fine; unparsable user file is an error
next; reset
run dump --project-dir "$tmp/empty" --user-config "$tmp/missing.json"
expect_rc 0
echo 'oops' >"$tmp/bad.json"
run dump --project-dir "$tmp/empty" --user-config "$tmp/bad.json"
expect_rc 1
expect_err "$tmp/bad.json"
pass

# 14 legacy-check: env hit, never prints the value
next; reset
out=$(REVIEW_MAX_ROUNDS=3 python3 "$script" legacy-check --project-dir "$tmp/empty"); rc=$?
expect_rc 0
expect '.legacy' '[{"name":"REVIEW_MAX_ROUNDS","where":"env","newKey":"implementPlan.review.maxRounds"}]'
expect '.warnings' '["REVIEW_MAX_ROUNDS (env) is ignored since workflow-kit 4.0.0; set implementPlan.review.maxRounds in .claude/workflow-kit.json"]'
case "$out" in *'"3"'*|*' 3'*|*'=3'*) fail "value leaked" ;; esac
pass

# 15 legacy-check: CLAUDE.md hits by whole word
next; reset
cat >"$tmp/proj/CLAUDE.md" <<'MD'
REVIEW_AUTOFIX_SEVERITY: low
PHASE_EXECUTOR=codex
MY_REVIEW_MODEL_X is not a hit, nor is XRUN_E2E.
`SELF_VERIFY_LIMIT` is.
MD
out=$(python3 "$script" legacy-check --project-dir "$tmp/proj"); rc=$?
expect_rc 0
expect '[.legacy[].name] | sort' '["PHASE_EXECUTOR","REVIEW_AUTOFIX_SEVERITY","SELF_VERIFY_LIMIT"]'
expect '[.legacy[].where] | unique' '["CLAUDE.md"]'
expect '[.legacy[] | select(.name == "PHASE_EXECUTOR") | .newKey]' '["routing.phase.<tier>"]'
expect '.warnings | length' '3'
pass

# 16 legacy-check: clean run
next; reset
out=$(python3 "$script" legacy-check --project-dir "$tmp/proj"); rc=$?
expect_rc 0
expect '.' '{"legacy":[],"warnings":[]}'
out=$(python3 "$script" legacy-check --project-dir "$tmp/does-not-exist"); rc=$?
expect_rc 0
expect '.legacy' '[]'
pass

# 17 LEGACY table targets exist in the schema
next; reset
out=$(python3 - "$here" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import config
bad = []
for name, key in config.LEGACY.items():
    parts = key.replace(".<tier>", "").split(".")
    node = config.SCHEMA
    for p in parts:
        if not isinstance(node, dict) or p not in node:
            bad.append(name); break
        node = node[p]
print(bad)
PY
)
[ "$out" = "[]" ] || fail "LEGACY keys missing from SCHEMA: $out"
pass
