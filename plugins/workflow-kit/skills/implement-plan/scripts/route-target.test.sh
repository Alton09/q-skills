#!/usr/bin/env bash
# Tests for route-target.sh. Hermetic: fixtures live in a mktemp dir, HOME points at it,
# and quota-axi is either a --quota-json fixture or a stub on PATH. Prints `ok <n>` per
# case and exits non-zero on the first failure, naming the case.
set -u

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script="$here/route-target.sh"
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
mkdir -p "$HOME" "$tmp/proj/.claude" "$tmp/empty"

n=0
fail() {
  echo "FAIL case $n: $1" >&2
  [ -n "${out:-}" ] && echo "  output: $out" >&2
  exit 1
}
pass() { echo "ok $n"; }

# expect <jq-filter> <expected-json>: assert on the last script output.
expect() {
  verify_actual=$(jq -c "$1" <<<"$out" 2>/dev/null) || fail "output is not JSON ($1)"
  [ "$verify_actual" = "$2" ] || fail "$1 = $verify_actual, expected $2"
}
expect_true() {
  [ "$(jq "$1" <<<"$out" 2>/dev/null)" = true ] || fail "expected true: $1"
}

# --- fixtures: quota-axi 0.1.44 JSON shape (schemaVersion 5) ---------------------------
cat >"$tmp/quota.json" <<'JSON'
{
  "generatedAt": "2026-10-07T05:04:40.411Z",
  "schemaVersion": 5,
  "providers": [
    {
      "provider": "claude",
      "plan": "pro",
      "windows": [
        {"id": "five_hour", "label": "session", "kind": "session", "resetsAt": "2026-10-07T08:39:59.576614+00:00", "percentRemaining": 78,
         "pace": {"status": "behind", "reservePercentPoints": 6.2269, "burnMultiple": 0.7794}},
        {"id": "seven_day", "label": "week", "kind": "weekly", "resetsAt": "2026-10-09T21:59:59.576638+00:00", "percentRemaining": 86,
         "pace": {"status": "behind", "reservePercentPoints": 47.356, "burnMultiple": 0.2282}}
      ],
      "state": {"status": "fresh", "stale": false},
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          {"scope": "all_models", "status": "known", "effectivePercentRemaining": 78,
           "boundedBy": ["five_hour", "seven_day"], "limitingWindowIds": ["five_hour"],
           "pace": {"status": "behind", "worstReservePercentPoints": 6.2269, "worstReserveWindowId": "five_hour"},
           "runway": {"status": "through_reset", "projectionConfidence": "established"},
           "selection": {"status": "known", "spendPriority": 1.9484}}
        ]
      }
    },
    {
      "provider": "codex",
      "plan": "plus",
      "windows": [
        {"id": "five_hour", "label": "session", "kind": "session", "resetsAt": "2026-10-07T10:03:45.000Z", "percentRemaining": 96,
         "pace": {"status": "on_pace", "reservePercentPoints": 0.5, "burnMultiple": 1.0}},
        {"id": "weekly", "label": "week", "kind": "weekly", "resetsAt": "2026-10-14T05:03:45.000Z", "percentRemaining": 99,
         "pace": {"status": "on_pace", "reservePercentPoints": -0.9908, "burnMultiple": 1.0}}
      ],
      "credits": {"remaining": 0, "unlimited": false, "unit": "credits"},
      "state": {"status": "fresh", "stale": false},
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          {"scope": "all_models", "status": "known", "effectivePercentRemaining": 96,
           "boundedBy": ["five_hour", "weekly"], "limitingWindowIds": ["five_hour"],
           "pace": {"status": "on_pace", "worstReservePercentPoints": -0.9908, "worstReserveWindowId": "weekly"},
           "runway": {"status": "through_reset", "projectionConfidence": "established"},
           "selection": {"status": "known", "spendPriority": 1.0}}
        ]
      }
    },
    {
      "provider": "opencode-go",
      "plan": "OpenCode Go",
      "windows": [
        {"id": "rolling", "label": "rolling", "kind": "unknown", "percentRemaining": 100, "resetsAt": "2026-10-07T09:45:13.000Z",
         "pace": {"status": "unknown", "reason": "missing_cycle"}},
        {"id": "weekly", "label": "weekly", "kind": "weekly", "percentRemaining": 100, "resetsAt": "2026-10-12T00:00:00.000Z",
         "pace": {"status": "unknown", "reason": "missing_cycle"}},
        {"id": "monthly", "label": "monthly", "kind": "monthly", "percentRemaining": 54, "resetsAt": "2026-10-15T17:52:01.000Z",
         "pace": {"status": "unknown", "reason": "missing_cycle"}}
      ],
      "state": {"status": "fresh", "stale": false},
      "quotaSemantics": {"status": "unknown", "effectiveAvailability": [], "unresolvedWindowIds": ["rolling", "weekly", "monthly"]}
    }
  ]
}
JSON

# quota_variant <name> <provider> <percent> [runway] [state-status]: copy of the base
# fixture with one provider's effective percent / runway / state changed.
quota_variant() {
  jq --arg p "$2" --argjson pct "$3" --arg runway "${4:-through_reset}" --arg status "${5:-fresh}" '
    (.providers[] | select(.provider == $p)) |= (
      .quotaSemantics.effectiveAvailability[0].effectivePercentRemaining = $pct
      | .quotaSemantics.effectiveAvailability[0].runway.status = $runway
      | .state.status = $status)' "$tmp/quota.json" >"$tmp/$1.json"
}

cat >"$tmp/user.json" <<'JSON'
{
  "version": 1,
  "minBudgetPercent": 15,
  "minBudgetPercentByRole": { "review": 25 },
  "routing": {
    "phase": {
      "light": ["codex:gpt-5.6-luna", "claude:haiku"],
      "standard": ["codex:gpt-5.6-terra", "claude:sonnet"],
      "deep": ["codex:gpt-5.6-sol", "claude:opus"]
    },
    "gateVerify": ["codex:gpt-5.6-luna", "claude:sonnet"],
    "review": ["pi:opencode-go/grok-4.6", "claude:opus"]
  }
}
JSON

# route <args...>: run the script against the fixture user config and a project dir with
# no config, using the base quota fixture unless the caller passes --quota-json.
run() {
  out=$("$script" --user-config "$tmp/user.json" --project-dir "$tmp/empty" "$@")
  verify_rc=$?
  [ "$verify_rc" -eq 0 ] || fail "exit $verify_rc"
  [ "$(printf '%s\n' "$out" | wc -l)" -eq 1 ] || fail "expected exactly one output line"
}

# 1. No config files -> target null, source none.
n=1
out=$("$script" --role phase --tier standard --user-config "$tmp/missing.json" --project-dir "$tmp/empty" --quota-json "$tmp/quota.json")
expect .target null
expect .source '"none"'
pass

# 2. First target has budget -> it wins; reason is "<provider> <p>%".
n=2
run --role phase --tier standard --quota-json "$tmp/quota.json"
expect .target '"codex:gpt-5.6-terra"'
expect .source '"user"'
expect .quota '"ok"'
expect .percent 96
expect .reason '"codex 96%"'
expect .skipped '[]'
expect .warnings '[]'
pass

# 3. Codex at 9%, threshold 15 -> falls to claude:sonnet.
n=3
quota_variant codex9 codex 9
run --role phase --tier standard --quota-json "$tmp/codex9.json"
expect .target '"claude:sonnet"'
expect .percent 78
expect .reason '"preferred codex:gpt-5.6-terra, skipped: codex 9% < 15%"'
expect .skipped '[{"target":"codex:gpt-5.6-terra","why":"codex 9% < 15%"}]'
pass

# 4. Review role uses the 25 default: codex at 20% skipped for review, usable for phase.
n=4
quota_variant codex20 codex 20
cat >"$tmp/review-codex.json" <<'JSON'
{"version": 1, "routing": {"review": ["codex:gpt-5.6-sol", "claude:opus"], "phase": {"standard": ["codex:gpt-5.6-terra", "claude:sonnet"]}}}
JSON
out=$("$script" --role review --user-config "$tmp/review-codex.json" --project-dir "$tmp/empty" --quota-json "$tmp/codex20.json")
expect .target '"claude:opus"'
expect .reason '"preferred codex:gpt-5.6-sol, skipped: codex 20% < 25%"'
out=$("$script" --role phase --tier standard --user-config "$tmp/review-codex.json" --project-dir "$tmp/empty" --quota-json "$tmp/codex20.json")
expect .target '"codex:gpt-5.6-terra"'
expect .percent 20
pass

# 5. exhausted_now above threshold -> skipped.
n=5
quota_variant exhausted codex 96 exhausted_now
run --role phase --tier standard --quota-json "$tmp/exhausted.json"
expect .target '"claude:sonnet"'
expect .skipped '[{"target":"codex:gpt-5.6-terra","why":"codex exhausted_now"}]'
pass

# 6. projected_exhaustion above threshold -> used, with the warning.
n=6
quota_variant projected codex 96 projected_exhaustion
run --role phase --tier standard --quota-json "$tmp/projected.json"
expect .target '"codex:gpt-5.6-terra"'
expect .warnings '["codex projected to exhaust before reset"]'
pass

# 7. All targets below budget -> last target, with the warning.
n=7
quota_variant low codex 9
jq '(.providers[] | select(.provider == "claude")) |= (.quotaSemantics.effectiveAvailability[0].effectivePercentRemaining = 5)' \
  "$tmp/low.json" >"$tmp/alllow.json"
run --role phase --tier standard --quota-json "$tmp/alllow.json"
expect .target '"claude:sonnet"'
expect .percent 5
expect '.warnings | index("all targets below budget; using last target claude:sonnet") != null' true
pass

# 8. opencode-go windows 100/100/54 -> percent 54.
n=8
run --role review --quota-json "$tmp/quota.json"
expect .target '"pi:opencode-go/grok-4.6"'
expect .percent 54
expect .reason '"opencode-go 54%"'
pass

# 9. auth_required provider -> skipped when not last.
n=9
quota_variant auth codex 96 through_reset auth_required
run --role phase --tier standard --quota-json "$tmp/auth.json"
expect .target '"claude:sonnet"'
expect .skipped '[{"target":"codex:gpt-5.6-terra","why":"codex state auth_required"}]'
# ...and picked when it is the last target.
cat >"$tmp/auth-last.json" <<'JSON'
{"version": 1, "routing": {"gateVerify": ["claude:sonnet", "codex:gpt-5.6-luna"]}}
JSON
quota_variant authlow claude 5
jq '(.providers[] | select(.provider == "codex")) |= (.state.status = "auth_required")' "$tmp/authlow.json" >"$tmp/authlast.json"
out=$("$script" --role gateVerify --user-config "$tmp/auth-last.json" --project-dir "$tmp/empty" --quota-json "$tmp/authlast.json")
expect .target '"codex:gpt-5.6-luna"'
expect .percent null
pass

# 10. --quota-json at a missing file -> quota unavailable, first target.
n=10
run --role phase --tier standard --quota-json "$tmp/does-not-exist.json"
expect .quota '"unavailable"'
expect .target '"codex:gpt-5.6-terra"'
expect '.warnings[0] | startswith("quota-axi unavailable: ") and endswith("; using first target")' true
pass

# 11. Project file overrides only routing.review; phase list still comes from the user file.
n=11
cat >"$tmp/proj/.claude/workflow-kit.json" <<'JSON'
{"version": 1, "routing": {"review": ["claude:opus"]}}
JSON
out=$("$script" --role review --user-config "$tmp/user.json" --project-dir "$tmp/proj" --quota-json "$tmp/quota.json")
expect .target '"claude:opus"'
expect .source '"project"'
out=$("$script" --role phase --tier standard --user-config "$tmp/user.json" --project-dir "$tmp/proj" --quota-json "$tmp/quota.json")
expect .target '"codex:gpt-5.6-terra"'
expect .source '"user"'
pass

# 12. Invalid JSON, version 2, unknown executor -> source invalid, target null.
n=12
printf '{ not json' >"$tmp/bad-parse.json"
printf '{"version": 2, "routing": {}}' >"$tmp/bad-version.json"
printf '{"version": 1, "routing": {"review": ["foo:bar"]}}' >"$tmp/bad-executor.json"
for bad in bad-parse bad-version bad-executor; do
  out=$("$script" --role review --user-config "$tmp/$bad.json" --project-dir "$tmp/empty" --quota-json "$tmp/quota.json")
  expect .source '"invalid"'
  expect .target null
  expect '.warnings | length' 1
  expect_true ".warnings[0] | contains(\"$bad.json\")"
done
pass

# 13. --exclude-executor codex on a review list -> claude:opus.
n=13
out=$("$script" --role review --user-config "$tmp/review-codex.json" --project-dir "$tmp/empty" --quota-json "$tmp/quota.json" --exclude-executor codex)
expect .target '"claude:opus"'
expect .reason '"claude 78%"'
pass

# 14. --role phase without --tier -> exit 2.
n=14
"$script" --role phase --user-config "$tmp/user.json" --project-dir "$tmp/empty" --quota-json "$tmp/quota.json" >"$tmp/o14" 2>"$tmp/e14"
verify_rc=$?
[ "$verify_rc" -eq 2 ] || fail "exit $verify_rc, expected 2"
[ ! -s "$tmp/o14" ] || fail "stdout should be empty on a usage error"
[ -s "$tmp/e14" ] || fail "expected a message on stderr"
"$script" --role review --tier deep --user-config "$tmp/user.json" >/dev/null 2>&1
[ $? -eq 2 ] || fail "--tier with --role review should exit 2"
pass

# --- quota-axi stub on PATH: never called without config; called with the safe flag ---
stub_dir="$tmp/stub"
mkdir -p "$stub_dir"
cat >"$stub_dir/quota-axi" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$tmp/quota-axi.calls"
cat "$tmp/quota.json"
STUB
chmod +x "$stub_dir/quota-axi"

# 15. No config and no --quota-json -> target null, quota-axi never invoked.
n=15
out=$(PATH="$stub_dir:$PATH" "$script" --role phase --tier standard --user-config "$tmp/missing.json" --project-dir "$tmp/empty")
expect .target null
[ ! -e "$tmp/quota-axi.calls" ] || fail "quota-axi was called with no config"
pass

# 16. With config and no --quota-json -> exactly one call, with --no-credential-refresh.
n=16
out=$(PATH="$stub_dir:$PATH" "$script" --role phase --tier standard --user-config "$tmp/user.json" --project-dir "$tmp/empty")
expect .target '"codex:gpt-5.6-terra"'
[ "$(wc -l <"$tmp/quota-axi.calls")" -eq 1 ] || fail "expected exactly one quota-axi call"
grep -q -- '--no-credential-refresh' "$tmp/quota-axi.calls" || fail "quota-axi call lacks --no-credential-refresh"
grep -q -- '--json' "$tmp/quota-axi.calls" || fail "quota-axi call lacks --json"
grep -q -- '--provider claude,codex' "$tmp/quota-axi.calls" || fail "quota-axi call has wrong --provider list: $(cat "$tmp/quota-axi.calls")"
pass

# 17. quota-axi failing (non-zero exit / garbage output) -> unavailable, first target.
n=17
printf '#!/usr/bin/env bash\nexit 3\n' >"$stub_dir/quota-axi"
out=$(PATH="$stub_dir:$PATH" "$script" --role phase --tier standard --user-config "$tmp/user.json" --project-dir "$tmp/empty")
expect .quota '"unavailable"'
expect .target '"codex:gpt-5.6-terra"'
printf '#!/usr/bin/env bash\necho "error: unsupported provider: foo"\n' >"$stub_dir/quota-axi"
out=$(PATH="$stub_dir:$PATH" "$script" --role phase --tier standard --user-config "$tmp/user.json" --project-dir "$tmp/empty")
expect .quota '"unavailable"'
pass

# --- prFix role ---------------------------------------------------------------------------
cat >"$tmp/user-prfix.json" <<'JSON'
{"version": 1, "routing": {"prFix": ["codex:gpt-5.6-terra", "claude:sonnet"], "phase": {"standard": ["claude:haiku"]}}}
JSON

# 18. User prFix list picks its first usable target.
n=18
out=$("$script" --role prFix --user-config "$tmp/user-prfix.json" --project-dir "$tmp/empty" --quota-json "$tmp/quota.json")
expect .target '"codex:gpt-5.6-terra"'
expect .source '"user"'
expect .warnings '[]'
pass

# 19. No prFix anywhere -> phase.standard fallback with the warning.
n=19
run --role prFix --quota-json "$tmp/quota.json"
expect .target '"codex:gpt-5.6-terra"'
expect .source '"user"'
expect .warnings '["no routing.prFix list; using routing.phase.standard"]'
pass

# 20. Project prFix overrides user prFix.
n=20
cat >"$tmp/proj/.claude/workflow-kit.json" <<'JSON'
{"version": 1, "routing": {"prFix": ["claude:opus"]}}
JSON
out=$("$script" --role prFix --user-config "$tmp/user-prfix.json" --project-dir "$tmp/proj" --quota-json "$tmp/quota.json")
expect .target '"claude:opus"'
expect .source '"project"'
pass

# 21. User prFix beats project phase.standard.
n=21
cat >"$tmp/proj/.claude/workflow-kit.json" <<'JSON'
{"version": 1, "routing": {"phase": {"standard": ["claude:opus"]}}}
JSON
out=$("$script" --role prFix --user-config "$tmp/user-prfix.json" --project-dir "$tmp/proj" --quota-json "$tmp/quota.json")
expect .target '"codex:gpt-5.6-terra"'
expect .source '"user"'
expect .warnings '[]'
pass

# 22. --role prFix --tier standard -> exit 2.
n=22
"$script" --role prFix --tier standard --user-config "$tmp/user-prfix.json" --project-dir "$tmp/empty" --quota-json "$tmp/quota.json" >"$tmp/o22" 2>"$tmp/e22"
verify_rc=$?
[ "$verify_rc" -eq 2 ] || fail "exit $verify_rc, expected 2"
[ ! -s "$tmp/o22" ] || fail "stdout should be empty on a usage error"
[ -s "$tmp/e22" ] || fail "expected a message on stderr"
pass

# 23. routing.prFix set to a string -> source invalid.
n=23
printf '{"version": 1, "routing": {"prFix": "claude:sonnet"}}' >"$tmp/bad-prfix.json"
out=$("$script" --role prFix --user-config "$tmp/bad-prfix.json" --project-dir "$tmp/empty" --quota-json "$tmp/quota.json")
expect .source '"invalid"'
expect .target null
expect_true '.warnings[0] | contains("routing.prFix is not an array of strings")'
pass

# 24. minBudgetPercentByRole.prFix is applied: codex at 20% skipped with threshold 30.
n=24
quota_variant codex20b codex 20
cat >"$tmp/prfix-thr.json" <<'JSON'
{"version": 1, "minBudgetPercentByRole": {"prFix": 30}, "routing": {"prFix": ["codex:gpt-5.6-terra", "claude:sonnet"]}}
JSON
out=$("$script" --role prFix --user-config "$tmp/prfix-thr.json" --project-dir "$tmp/empty" --quota-json "$tmp/codex20b.json")
expect .target '"claude:sonnet"'
expect .skipped '[{"target":"codex:gpt-5.6-terra","why":"codex 20% < 30%"}]'
pass

# 25. No config at all -> prFix gives target null, source none, exit 0.
n=25
out=$("$script" --role prFix --user-config "$tmp/missing.json" --project-dir "$tmp/empty")
verify_rc=$?
[ "$verify_rc" -eq 0 ] || fail "exit $verify_rc"
expect .target null
expect .source '"none"'
pass
