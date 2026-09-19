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

# ---- 1. Early exits: opt-out, not in git, gh missing or not authed, non-GitHub remote

[[ "${PR_RETRO_NUDGE:-1}" == "0" ]] && exit 0

git rev-parse --is-inside-work-tree > /dev/null 2>&1 || exit 0
command -v gh > /dev/null 2>&1 || exit 0
gh auth status > /dev/null 2>&1 || exit 0

_origin_url=$(git remote get-url origin 2>/dev/null) || exit 0
[[ "$_origin_url" == *github.com* ]] || exit 0

# ---- 2. Resolve owner/repo and state dir

_nwo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || exit 0
[[ -n "$_nwo" ]] || exit 0

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

# ---- 5. Query merged PRs since baseline

_baseline=$(< "$_baseline_file") || exit 0
_baseline_date="${_baseline%%T*}"
[[ -n "$_baseline_date" ]] || exit 0

_pr_json=$(gh pr list \
    --state merged \
    --author @me \
    --search "merged:>=${_baseline_date}" \
    --json number,title \
    --limit 20 \
    2>/dev/null) || exit 0
[[ -n "$_pr_json" ]] || exit 0

# ---- 6. Filter out already-done PRs and build JSON output via python3

_done_str=""
[[ -f "$_done_file" ]] && _done_str=$(< "$_done_file")

_output=$(PR_JSON="$_pr_json" DONE_NUMBERS="$_done_str" python3 - <<'EOF'
import json, os, sys

try:
    prs = json.loads(os.environ.get('PR_JSON', '[]'))
    done_raw = os.environ.get('DONE_NUMBERS', '')
    done = {ln.strip() for ln in done_raw.splitlines() if ln.strip()}
    pending = [p for p in prs if str(p['number']) not in done]
    if not pending:
        sys.exit(0)
    shown = pending[:3]
    extra = len(pending) - len(shown)
    parts = []
    for p in shown:
        n = p['number']
        t = json.dumps(p['title'])
        parts.append(
            'PR #' + str(n) + ' ' + t + ' merged with no retro. '
            'Run /dev-toolkit:pr-retro ' + str(n) + ', or '
            '/dev-toolkit:pr-retro --skip ' + str(n) + '.'
        )
    msg = ' '.join(parts)
    if extra:
        msg += ' +' + str(extra) + ' more.'
    nums = ', '.join('#' + str(p['number']) for p in pending)
    ctx = (
        'Pending retro: ' + nums + '. '
        'Offer once if relevant; do not start without explicit user request.'
    )
    print(json.dumps({
        'systemMessage': msg,
        'hookSpecificOutput': {
            'hookEventName': 'SessionStart',
            'additionalContext': ctx,
        },
    }))
except Exception:
    sys.exit(0)
EOF
)

# ---- 7. Emit output (empty means nothing pending or python exited non-zero)

[[ -n "$_output" ]] && printf '%s\n' "$_output"
exit 0
