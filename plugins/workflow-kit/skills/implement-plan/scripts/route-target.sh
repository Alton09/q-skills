#!/usr/bin/env bash
# route-target.sh - pick one worker target from the workflow-kit routing config and
# a local quota-axi read. Deterministic, read-only: spawns nothing, writes no files.
#
# Usage:
#   route-target.sh --role phase|gateVerify|review|prFix|orchestrator|prep|e2e [--tier light|standard|deep]
#                   [--exclude-executor <claude|pi|codex>]...
#                   [--project-dir <dir>] [--user-config <file>] [--quota-json <file>]
#
# Prints exactly one JSON line on stdout and exits 0, except usage errors (exit 2,
# message on stderr). See references/routing.md for the contract.
set -u

QUOTA_TIMEOUT_SECONDS=${QUOTA_TIMEOUT_SECONDS:-20}
# Providers `quota-axi --provider` accepts (quota-axi 0.1.44). An unsupported name
# makes the whole call fail, so anything else is treated as unknown state instead.
QUOTA_PROVIDERS="claude codex cursor copilot grok kimi zai agy alibaba opencode-go"

usage_error() {
  printf 'route-target.sh: %s\n' "$1" >&2
  printf 'usage: route-target.sh --role phase|gateVerify|review|prFix|orchestrator|prep|e2e [--tier light|standard|deep] [--exclude-executor claude|pi|codex]... [--project-dir DIR] [--user-config FILE] [--quota-json FILE]\n' >&2
  exit 2
}

role=""
tier=""
project_dir=""
project_dir_set=0
user_config=""
user_config_set=0
quota_file=""
excludes=()

while [ $# -gt 0 ]; do
  case "$1" in
    --role|--tier|--exclude-executor|--project-dir|--user-config|--quota-json)
      [ $# -ge 2 ] || usage_error "$1 requires a value"
      case "$1" in
        --role) role=$2 ;;
        --tier) tier=$2 ;;
        --exclude-executor) excludes+=("$2") ;;
        --project-dir) project_dir=$2; project_dir_set=1 ;;
        --user-config) user_config=$2; user_config_set=1 ;;
        --quota-json) quota_file=$2 ;;
      esac
      shift 2
      ;;
    *) usage_error "unknown argument: $1" ;;
  esac
done

case "$role" in
  phase|gateVerify|review|prFix|orchestrator|prep|e2e) ;;
  "") usage_error "--role is required" ;;
  *) usage_error "invalid --role: $role" ;;
esac
if [ "$role" = phase ]; then
  case "$tier" in
    light|standard|deep) ;;
    "") usage_error "--tier is required when --role phase" ;;
    *) usage_error "invalid --tier: $tier" ;;
  esac
elif [ -n "$tier" ]; then
  usage_error "--tier is only valid with --role phase"
fi
for verify_ex in ${excludes[@]+"${excludes[@]}"}; do
  case "$verify_ex" in
    claude|pi|codex) ;;
    *) usage_error "invalid --exclude-executor: $verify_ex" ;;
  esac
done

command -v jq >/dev/null 2>&1 || usage_error "jq is required"
command -v python3 >/dev/null 2>&1 || usage_error "python3 is required"

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

if [ "$project_dir_set" -eq 0 ]; then
  project_dir=$(git rev-parse --show-toplevel 2>/dev/null || true)
fi
# Outside a git repo there is no project file: point config.py at a dir that has none.
[ -n "$project_dir" ] || project_dir=/nonexistent-project-dir
config_args=(--project-dir "$project_dir")
[ "$user_config_set" -eq 1 ] && config_args+=(--user-config "$user_config")

warnings='[]'
warn() {
  warnings=$(jq -c --arg w "$1" '. + [$w]' <<<"$warnings")
}

# One reader for validation and merging: config.py (shipped defaults < user < project).
# Success prints nothing on stderr, so 2>&1 only ever carries an error message.
if dump=$(python3 "$here/config.py" dump --with-sources "${config_args[@]}" 2>&1); then
  warnings=$(jq -c '.warnings // []' <<<"$dump")
else
  err_line=$(printf '%s\n' "$dump" | head -n 1)
  err_line=${err_line#config.py: }
  warn "invalid config: $err_line; using shipped defaults"
  defaults=$(python3 "$here/config.py" defaults) || { echo "route-target.sh: config.py defaults failed" >&2; exit 1; }
  dump=$(jq -nc --argjson c "$defaults" '{config: $c, sources: {}, warnings: []}')
fi

# The list for this call and where it came from (project|user|default).
if [ "$role" = phase ]; then
  list_path="routing.phase.$tier"
else
  list_path="routing.$role"
fi
list=$(jq -c --arg p "$list_path" '.config | getpath($p | split(".")) // null' <<<"$dump")
source=$(jq -r --arg p "$list_path" '.sources[$p] // "default"' <<<"$dump")
if [ "$list" = null ] && [ "$role" = prFix ]; then
  # No dedicated prFix list: fall back to the merged phase.standard.
  list=$(jq -c '.config.routing.phase.standard' <<<"$dump")
  source=$(jq -r '.sources["routing.phase.standard"] // "default"' <<<"$dump")
  [ "$source" != default ] && warn "no routing.prFix list; using routing.phase.standard"
fi
[ "$list" = null ] && list='[]'

# Threshold: a file-set byRole value, else a file-set minBudgetPercent, else the
# shipped byRole default, else the shipped minBudgetPercent (built-ins live in config.py).
threshold=$(jq -c --arg role "$role" '
  .config as $c | .sources as $s
  | $c.minBudgetPercentByRole[$role] as $r
  | if $r != null and (($s["minBudgetPercentByRole." + $role] // "default") != "default") then $r
    elif ($s.minBudgetPercent // "default") != "default" then $c.minBudgetPercent
    else $r // $c.minBudgetPercent end' <<<"$dump")

# Normalise targets (unprefixed means claude:<id>), drop excluded executors, map providers.
excludes_json=$(printf '%s\n' ${excludes[@]+"${excludes[@]}"} | jq -Rnc '[inputs | select(. != "")]')
targets=$(jq -c --argjson ex "$excludes_json" '
  map(if contains(":") then . else "claude:" + . end)
  | map(select((split(":")[0]) as $e | ($ex | index($e)) | not))
  | map({target: .,
         executor: split(":")[0],
         provider: (split(":")[0] as $e | .[($e | length) + 1:] as $m
           | if $e == "pi" then (if ($m | contains("/")) then ($m | split("/")[0]) else "pi" end)
             else $e end)})' <<<"$list")

if [ "$(jq 'length' <<<"$targets")" -eq 0 ]; then
  jq -nc --arg source "$source" --argjson warnings "$warnings" \
    '{target:null, source:$source, quota:"ok", percent:null, reason:"no targets after exclusions", skipped:[], warnings:$warnings, usable:null, resetsAt:null}'
  exit 0
fi

# run_limited <seconds> <cmd...>: bounded run that works without GNU timeout (macOS).
run_limited() {
  verify_secs=$1
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$verify_secs" "$@" 2>/dev/null
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$verify_secs" "$@" 2>/dev/null
  else
    (
      "$@" 2>/dev/null &
      verify_pid=$!
      ( sleep "$verify_secs"; kill "$verify_pid" 2>/dev/null ) >/dev/null 2>&1 &
      verify_watch=$!
      wait "$verify_pid"
      verify_rc=$?
      kill "$verify_watch" 2>/dev/null
      [ "$verify_rc" -gt 128 ] && verify_rc=124
      exit "$verify_rc"
    )
  fi
}

# fetch_quota: sets quota (JSON) on success; sets quota_cause and returns 1 on failure.
quota=""
quota_cause=""
fetch_quota() {
  verify_raw=""
  if [ -n "$quota_file" ]; then
    if [ ! -r "$quota_file" ] || [ -d "$quota_file" ]; then
      quota_cause="quota json not readable"
      return 1
    fi
    verify_raw=$(cat "$quota_file")
  else
    verify_list=$(jq -r --arg known "$QUOTA_PROVIDERS" \
      '[.[].provider | select(. as $p | ($known | split(" ") | index($p)))] | unique | join(",")' <<<"$targets")
    if [ -z "$verify_list" ]; then
      quota='{"providers":[]}'
      return 0
    fi
    if ! command -v quota-axi >/dev/null 2>&1; then
      quota_cause="quota-axi not found"
      return 1
    fi
    verify_raw=$(run_limited "$QUOTA_TIMEOUT_SECONDS" quota-axi --json --no-credential-refresh --provider "$verify_list")
    verify_rc=$?
    if [ "$verify_rc" -eq 124 ]; then
      quota_cause="timed out after ${QUOTA_TIMEOUT_SECONDS}s"
      return 1
    elif [ "$verify_rc" -ne 0 ]; then
      quota_cause="exit code $verify_rc"
      return 1
    fi
  fi
  if ! jq -e '.providers | type == "array"' <<<"$verify_raw" >/dev/null 2>&1; then
    quota_cause="unparseable output"
    return 1
  fi
  quota=$verify_raw
  return 0
}

if ! fetch_quota; then
  warn "quota-axi unavailable: $quota_cause; using first target"
  jq -nc --argjson targets "$targets" --arg source "$source" --argjson warnings "$warnings" '
    $targets[0] as $t
    | {target: $t.target, source: $source, quota: "unavailable", percent: null,
       reason: "quota unavailable", skipped: [], warnings: $warnings,
       usable: null, resetsAt: null}'
  exit 0
fi

jq -nc --argjson targets "$targets" --argjson quota "$quota" --argjson threshold "$threshold" \
  --arg source "$source" --argjson warnings "$warnings" '
  def evaluate($t):
    ([$quota.providers[]? | select(.provider == $t.provider)] | .[0]) as $pr
    | if $pr == null then {kind: "unknown", status: "missing"}
      elif ($pr.state.status // "missing") != "fresh" then {kind: "unknown", status: ($pr.state.status // "missing")}
      elif $pr.state.stale == true then {kind: "unknown", status: "stale"}
      elif $pr.quotaSemantics.status == "known" then
        ($pr.quotaSemantics.effectiveAvailability // []) as $ea
        | (([$ea[] | select(.scope == "all_models")] | .[0]) // $ea[0]) as $e
        | if $e == null or ($e.effectivePercentRemaining | type) != "number"
          then {kind: "unknown", status: "no_availability"}
          else (($e.limitingWindowIds // [])[0]) as $lw
            | {kind: "known", percent: $e.effectivePercentRemaining, runway: ($e.runway.status // "unknown"),
               resetsAt: (if $lw == null then null
                          else (([$pr.windows[]? | select(.id == $lw) | .resetsAt] | .[0]) // null) end)}
          end
      else
        ([$pr.windows[]? | .percentRemaining | select(type == "number")]) as $w
        | if ($w | length) == 0 then {kind: "unknown", status: "no_windows"}
          else {kind: "known", percent: ($w | min), runway: "unknown", resetsAt: null}
          end
      end;
  def usable: .kind == "known" and .percent >= $threshold and .runway != "exhausted_now";
  def why($t):
    if .kind == "unknown" then "\($t.provider) state \(.status)"
    elif .runway == "exhausted_now" then "\($t.provider) exhausted_now"
    else "\($t.provider) \(.percent)% < \($threshold)%"
    end;
  ($targets | length) as $n
  | ($targets | map(. + {ev: evaluate(.)})) as $evs
  | ([range(0; $n) | select(. as $i | ($evs[$i].ev | usable) or ($evs[$i].ev.kind == "unknown" and $i == $n - 1))] | .[0]) as $found
  | ($found == null) as $fallback
  | (if $fallback then $n - 1 else $found end) as $idx
  | $evs[$idx] as $c
  | ([range(0; $idx) | $evs[.] as $x | {target: $x.target, why: ($x.ev | why($x))}]) as $skipped
  | {target: $c.target,
     source: $source,
     quota: "ok",
     percent: ($c.ev.percent // null),
     reason: (if $idx > 0 then "preferred \($evs[0].target), skipped: \($skipped[0].why)"
              elif ($c.ev | usable) then "\($c.provider) \($c.ev.percent)%"
              else ($c.ev | why($c)) end),
     skipped: $skipped,
     usable: ($c.ev | usable),
     resetsAt: (if $c.ev.kind == "known" and ($c.executor == "claude" or $c.executor == "codex")
                then ($c.ev.resetsAt // null) else null end),
     warnings: (
       $warnings
       + (if ($quota.schemaVersion // null) != 5 then ["quota-axi schemaVersion \($quota.schemaVersion // "missing") is not the expected 5"] else [] end)
       + (if $fallback then ["all targets below budget; using last target \($c.target)"]
          elif $c.ev.kind == "known" and $c.ev.runway == "projected_exhaustion"
          then ["\($c.provider) projected to exhaust before reset"] else [] end))}'
