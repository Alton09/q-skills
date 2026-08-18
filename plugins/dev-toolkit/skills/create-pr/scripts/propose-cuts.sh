#!/usr/bin/env bash
# Propose stack cut points for a branch that has no layer ledger.
#
# Walks the branch's commits oldest-first, measures cumulative production lines
# at each one, and picks cut points that divide the branch into roughly equal
# layers. Cuts always land on existing commit boundaries — a stack layer has to
# be a contiguous prefix of history, so no reordering or cherry-picking happens.
#
# Usage: propose-cuts.sh <base> <head> <threshold> [count-prod-lines.sh path]
#
# Output (stdout):
#   TOTAL=<production lines on the branch>
#   COMMITS=<n>
#   LAYERS=<n proposed>
#   CUT <layer> <sha> <cumulative-prod-lines> <subject>
#
# Exits 3 when the branch cannot be split (single commit), so the caller can
# fall back to a single PR.

set -euo pipefail

BASE="${1:?usage: propose-cuts.sh <base> <head> <threshold> [counter-path]}"
HEAD_REF="${2:?missing <head>}"
THRESHOLD="${3:?missing <threshold>}"
COUNTER="${4:-$(dirname "$0")/count-prod-lines.sh}"

# Read into an array without mapfile — macOS ships bash 3.2, where it does not exist.
COMMITS=()
while IFS= read -r sha; do COMMITS+=("$sha"); done \
  < <(git log --first-parent --reverse --format=%H "$BASE..$HEAD_REF")
N=${#COMMITS[@]}

if (( N < 2 )); then
  echo "COMMITS=$N"
  echo "ERROR=branch has fewer than 2 commits on --first-parent; nothing to cut" >&2
  exit 3
fi

# Cumulative production lines at each commit, measured from the merge base.
declare -a CUM
for i in "${!COMMITS[@]}"; do
  CUM[$i]=$("$COUNTER" "$BASE...${COMMITS[$i]}" | awk -F= '/^PROD_LINES=/{print $2}')
done

TOTAL=${CUM[$((N-1))]}
LAYERS=$(( (TOTAL + THRESHOLD - 1) / THRESHOLD ))
(( LAYERS < 2 )) && LAYERS=2
(( LAYERS > N )) && LAYERS=$N

echo "TOTAL=$TOTAL"
echo "COMMITS=$N"
echo "LAYERS=$LAYERS"

# Aim for equal-sized layers rather than "fill to threshold, then a small
# remainder" — a 900-line branch reads better as 2x450 than 500+400 chased by
# stragglers.
TARGET=$(( (TOTAL + LAYERS - 1) / LAYERS ))
layer=1
for i in "${!COMMITS[@]}"; do
  last=$(( i == N-1 ))
  if (( last )) || { (( CUM[i] >= layer * TARGET )) && (( layer < LAYERS )); }; then
    subject=$(git log -1 --format=%s "${COMMITS[$i]}")
    printf 'CUT %d %s %d %s\n' "$layer" "${COMMITS[$i]}" "${CUM[$i]}" "$subject"
    layer=$(( layer + 1 ))
    (( last )) && break
  fi
done
