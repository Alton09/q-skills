#!/usr/bin/env bash
# pr-retro-nudge.sh — SessionStart hook for dev-toolkit.
#
# On "startup", checks for merged PRs that have not been through
# /dev-toolkit:pr-retro yet and emits a systemMessage nudge.
# Runs silently and exits 0 on any error or when nothing is pending.
#
# State directory: ~/.claude/pr-retro/<owner>__<repo>/
#   baseline    — ISO-8601 UTC timestamp; PRs merged before this date are never nudged
#   last-check  — epoch seconds; throttles gh queries to once per hour
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

_now=$(date +%s 2>/dev/null)
[[ -n "$_now" ]] || exit 0

# ---- 3. First run: record baseline and initial last-check, then exit silently

if [[ ! -f "$_baseline_file" ]]; then
    date -u +%Y-%m-%dT%H:%M:%SZ > "$_baseline_file" 2>/dev/null
    printf '%s\n' "$_now" > "$_last_check_file" 2>/dev/null
    exit 0
fi

# ---- 4. Throttle: skip if last-check is less than 1 hour old

if [[ -f "$_last_check_file" ]]; then
    _last=$(< "$_last_check_file")
    _last="${_last:-0}"
    _elapsed=$(( _now - _last ))
    if (( _elapsed < 3600 )); then
        exit 0
    fi
fi

# Write updated last-check before querying
printf '%s\n' "$_now" > "$_last_check_file" 2>/dev/null

# ---- 5. Build jq filter for done PRs (read numbers from done file)

_baseline=$(< "$_baseline_file") || exit 0
_baseline_date="${_baseline%%T*}"
[[ -n "$_baseline_date" ]] || exit 0

_done_filter="true"
if [[ -f "$_done_file" ]]; then
    while IFS= read -r _n || [[ -n "$_n" ]]; do
        _n="${_n//[^0-9]/}"
        [[ -n "$_n" ]] || continue
        _done_filter="${_done_filter} and .number != ${_n}"
    done < "$_done_file"
fi

# ---- 6. Query merged PRs since baseline, filter done, build JSON output via gh --jq

_output=$(gh pr list \
    --state merged \
    --author @me \
    --search "merged:>=${_baseline_date}" \
    --json number,title \
    --limit 20 \
    --jq "
        [ .[] | select(${_done_filter}) ] as \$pending |
        if (\$pending | length) == 0 then empty
        else
          (\$pending[:3]) as \$shown |
          ((\$pending | length) - (\$shown | length)) as \$extra |
          ([ \$shown[] | \"PR #\\(.number) \\(.title | tojson) merged with no retro. Run /dev-toolkit:pr-retro \\(.number), or /dev-toolkit:pr-retro --skip \\(.number).\" ] | join(\" \")) as \$base |
          (if \$extra > 0 then \" +\" + (\$extra | tostring) + \" more.\" else \"\" end) as \$sfx |
          ([ \$pending[] | \"#\" + (.number | tostring) ] | join(\", \")) as \$nums |
          {
            systemMessage: (\$base + \$sfx),
            hookSpecificOutput: {
              hookEventName: \"SessionStart\",
              additionalContext: (\"Pending retro: \" + \$nums + \". Offer once if relevant; do not start without explicit user request.\")
            }
          }
        end
    " \
    2>/dev/null) || exit 0

# ---- 7. Emit output (empty means nothing pending or gh produced no output)

[[ -n "$_output" ]] && printf '%s\n' "$_output"
exit 0
