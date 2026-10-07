#!/usr/bin/env bash
# route-target.sh - pick one worker target from the workflow-kit routing config and
# a local quota-axi read. Deterministic, read-only: spawns nothing, writes no files.
#
# Usage:
#   route-target.sh --role phase|gateVerify|review [--tier light|standard|deep]
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
  printf 'usage: route-target.sh --role phase|gateVerify|review [--tier light|standard|deep] [--exclude-executor claude|pi|codex]... [--project-dir DIR] [--user-config FILE] [--quota-json FILE]\n' >&2
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
  phase|gateVerify|review) ;;
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

if [ "$project_dir_set" -eq 0 ]; then
  project_dir=$(git rev-parse --show-toplevel 2>/dev/null || true)
fi
if [ "$user_config_set" -eq 0 ]; then
  user_config="${HOME:-}/.claude/workflow-kit.json"
fi
project_config=""
[ -n "$project_dir" ] && project_config="$project_dir/.claude/workflow-kit.json"

warnings='[]'
warn() {
  warnings=$(jq -c --arg w "$1" '. + [$w]' <<<"$warnings")
}

# emit_null <source> <reason>: caller must use its shipped default.
emit_null() {
  jq -nc --arg source "$1" --arg reason "$2" --argjson warnings "$warnings" \
    '{target:null, source:$source, quota:"ok", percent:null, reason:$reason, skipped:[], warnings:$warnings}'
  exit 0
}

# validate_config <file>: prints the first problem, or nothing when the file is valid.
validate_config() {
  jq -r '
    def num_or_null: . == null or type == "number";
    if type != "object" then "top level is not an object"
    elif .version != 1 then "unsupported version (expected 1)"
    elif (.routing // {}) | type != "object" then "routing is not an object"
    elif ((.routing.phase // {}) | type) != "object" then "routing.phase is not an object"
    else
      (.routing // {}) as $r
      | ($r.phase // {}) as $p
      | ([["routing.phase.light", $p.light], ["routing.phase.standard", $p.standard],
          ["routing.phase.deep", $p.deep], ["routing.gateVerify", $r.gateVerify],
          ["routing.review", $r.review]] | map(select(.[1] != null))) as $ls
      | first(
          ($ls[] | select((.[1] | type) != "array" or (.[1] | any(.[]; type != "string")))
            | "\(.[0]) is not an array of strings"),
          ($ls[] | .[0] as $n | .[1][]
            | (if . == "" then "" else (split(":") | if length > 1 then .[0] else "claude" end) end) as $e
            | select(($e | IN("claude", "pi", "codex")) | not)
            | "\($n) names unknown executor \"\($e)\" in \"\(.)\""),
          (select((.minBudgetPercent | num_or_null) | not) | "minBudgetPercent is not a number"),
          (select((.minBudgetPercentByRole // {}) | type != "object") | "minBudgetPercentByRole is not an object"),
          ((.minBudgetPercentByRole // {}) | select(type == "object" and any(.[]; type != "number"))
            | "minBudgetPercentByRole has a non-number value")
        ) // ""
    end' "$1" 2>/dev/null
}

# load_config <file> <label>: prints nothing; sets config_state to absent|ok|invalid.
config_state=""
load_config() {
  config_state=absent
  [ -n "$1" ] && [ -f "$1" ] || return 0
  if ! jq -e . "$1" >/dev/null 2>&1; then
    warn "$1: file does not parse as JSON"
    config_state=invalid
    return 0
  fi
  verify_problem=$(validate_config "$1")
  if [ -n "$verify_problem" ]; then
    warn "$1: $verify_problem"
    config_state=invalid
    return 0
  fi
  config_state=ok
}

load_config "$user_config"
user_state=$config_state
load_config "$project_config"
project_state=$config_state

if [ "$user_state" = invalid ] || [ "$project_state" = invalid ]; then
  emit_null invalid "invalid routing config, using shipped default"
fi
[ "$user_state" = absent ] && [ "$project_state" = absent ] && emit_null none "no routing config"

# Resolve the list for this call (project replaces user at list level) and thresholds.
list_filter='(.routing // {}) | if $role == "phase" then (.phase // {})[$tier] else .[$role] end'
user_list=null
project_list=null
user_cfg='{}'
project_cfg='{}'
if [ "$user_state" = ok ]; then
  user_cfg=$(jq -c . "$user_config")
  user_list=$(jq -c --arg role "$role" --arg tier "$tier" "$list_filter" <<<"$user_cfg")
fi
if [ "$project_state" = ok ]; then
  project_cfg=$(jq -c . "$project_config")
  project_list=$(jq -c --arg role "$role" --arg tier "$tier" "$list_filter" <<<"$project_cfg")
fi

if [ "$project_list" != null ]; then
  source=project
  list=$project_list
elif [ "$user_list" != null ]; then
  source=user
  list=$user_list
else
  emit_null none "no routing list for $role"
fi

threshold=$(jq -nc --arg role "$role" --argjson u "$user_cfg" --argjson p "$project_cfg" '
  (($u.minBudgetPercentByRole // {}) + ($p.minBudgetPercentByRole // {})) as $byRole
  | $byRole[$role] // $p.minBudgetPercent // $u.minBudgetPercent // (if $role == "review" then 25 else 15 end)')

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
    '{target:null, source:$source, quota:"ok", percent:null, reason:"no targets after exclusions", skipped:[], warnings:$warnings}'
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
       reason: "quota unavailable", skipped: [], warnings: $warnings}'
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
          else {kind: "known", percent: $e.effectivePercentRemaining, runway: ($e.runway.status // "unknown")}
          end
      else
        ([$pr.windows[]? | .percentRemaining | select(type == "number")]) as $w
        | if ($w | length) == 0 then {kind: "unknown", status: "no_windows"}
          else {kind: "known", percent: ($w | min), runway: "unknown"}
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
     warnings: (
       $warnings
       + (if ($quota.schemaVersion // null) != 5 then ["quota-axi schemaVersion \($quota.schemaVersion // "missing") is not the expected 5"] else [] end)
       + (if $fallback then ["all targets below budget; using last target \($c.target)"]
          elif $c.ev.kind == "known" and $c.ev.runway == "projected_exhaustion"
          then ["\($c.provider) projected to exhaust before reset"] else [] end))}'
