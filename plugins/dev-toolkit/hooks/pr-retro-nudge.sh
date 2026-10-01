#!/usr/bin/env bash
# pr-retro-nudge.sh — SessionStart hook for dev-toolkit.
#
# On "startup" and "clear", checks for merged PRs that have not been through
# /dev-toolkit:pr-retro yet and emits a systemMessage nudge.
# Runs silently and exits 0 on any error or when nothing is pending.
#
# State directory: ~/.claude/pr-retro/<owner>__<repo>/
#   baseline    — ISO-8601 UTC timestamp; PRs merged before this date are never nudged
#   last-check  — epoch seconds of the last successful gh query; throttles queries to once per hour
#   pending     — cached merged PRs since baseline ("<number>\t<title JSON>"); re-shown on throttled runs
#   done        — one PR number per line; written by the skill after a retro or --skip

# ---- 1. Early exits: opt-out, not in git, gh missing, non-GitHub remote

[[ "${PR_RETRO_NUDGE:-1}" == "0" ]] && exit 0

git rev-parse --is-inside-work-tree > /dev/null 2>&1 || exit 0
command -v gh > /dev/null 2>&1 || exit 0

_origin_url=$(git remote get-url origin 2>/dev/null) || exit 0
[[ "$_origin_url" == *github.com* ]] || exit 0

# ---- 2. Resolve owner/repo from origin URL and set up state dir
#
# Handles both SSH (git@github.com:owner/repo.git) and
# HTTPS (https://github.com/owner/repo.git) remote URLs.

_nwo="${_origin_url##*github.com[:/]}"
_nwo="${_nwo%.git}"
[[ -n "$_nwo" && "$_nwo" == */* ]] || exit 0

_slug="${_nwo/\//__}"
_state_dir="${HOME}/.claude/pr-retro/${_slug}"
mkdir -p "$_state_dir" 2>/dev/null || exit 0

_baseline_file="${_state_dir}/baseline"
_last_check_file="${_state_dir}/last-check"
_done_file="${_state_dir}/done"
_pending_file="${_state_dir}/pending"

_now=$(date +%s 2>/dev/null)
[[ -n "$_now" ]] || exit 0

# ---- 3. First run: record baseline and initial last-check, then exit silently

if [[ ! -f "$_baseline_file" ]]; then
    date -u +%Y-%m-%dT%H:%M:%SZ > "$_baseline_file" 2>/dev/null
    printf '%s\n' "$_now" > "$_last_check_file" 2>/dev/null
    exit 0
fi

# ---- 4. Refresh the pending cache at most once per hour
#
# The throttle limits only the gh query. Every run (throttled or not) prints
# the nudge from the cached list, so a pending retro stays visible in every
# session. last-check moves forward only after gh succeeds, so a network
# failure does not hide the nudge for an hour.

_stale=1
if [[ -f "$_last_check_file" ]]; then
    _last=$(< "$_last_check_file")
    _last="${_last//[^0-9]/}"
    (( _now - ${_last:-0} < 3600 )) && _stale=0
fi

if (( _stale )); then
    _baseline=$(< "$_baseline_file") || exit 0
    _baseline_date="${_baseline%%T*}"
    [[ -n "$_baseline_date" ]] || exit 0

    # One line per merged PR: "<number><TAB><title as JSON string>"
    if _fresh=$(gh pr list \
        --repo "$_nwo" \
        --state merged \
        --author @me \
        --search "merged:>=${_baseline_date}" \
        --json number,title \
        --limit 20 \
        --jq '.[] | "\(.number)\t\(.title | tojson)"' \
        2>/dev/null); then
        printf '%s\n' "$_fresh" > "${_pending_file}.tmp" 2>/dev/null \
            && mv -f "${_pending_file}.tmp" "$_pending_file" 2>/dev/null \
            && printf '%s\n' "$_now" > "$_last_check_file" 2>/dev/null
    fi
fi

[[ -s "$_pending_file" ]] || exit 0

# ---- 5. Drop PRs listed in the done file (read on every run, so a retro or
#         --skip clears the nudge at once, without waiting for a refresh)

# Space-delimited list rather than an associative array: macOS ships bash 3.2.
_done=" "
if [[ -f "$_done_file" ]]; then
    while IFS= read -r _n || [[ -n "$_n" ]]; do
        _n="${_n//[^0-9]/}"
        [[ -n "$_n" ]] && _done+="${_n} "
    done < "$_done_file"
fi

_pending=()
while IFS=$'\t' read -r _n _title || [[ -n "$_n" ]]; do
    [[ "$_n" =~ ^[0-9]+$ && "$_done" != *" ${_n} "* ]] || continue
    _pending+=("${_n}"$'\t'"${_title}")
done < "$_pending_file"

(( ${#_pending[@]} > 0 )) || exit 0

# ---- 6. Build the message: first 3 PRs in full, then a "+N more" suffix

_json_escape() {
    local s="${1//\\/\\\\}"
    printf '%s' "${s//\"/\\\"}"
}

_msg=""
_nums=""
_i=0
for _entry in "${_pending[@]}"; do
    _n="${_entry%%$'\t'*}"
    _title="${_entry#*$'\t'}"
    if (( _i < 3 )); then
        _msg+="${_msg:+ }PR #${_n} ${_title} merged with no retro. Run /dev-toolkit:pr-retro ${_n}, or /dev-toolkit:pr-retro --skip ${_n}."
    fi
    _nums+="${_nums:+, }#${_n}"
    _i=$(( _i + 1 ))
done
(( _i > 3 )) && _msg+=" +$(( _i - 3 )) more."

# ---- 7. Emit output

printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' \
    "$(_json_escape "$_msg")" \
    "Pending retro: ${_nums}. Offer once if relevant; do not start without explicit user request."
exit 0
