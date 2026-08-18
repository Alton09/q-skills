#!/usr/bin/env bash
# Count production lines changed in a git range, excluding test/generated paths,
# comment lines, and blank lines.
#
# Usage:   count-prod-lines.sh <base>...<head> [extra-pathspec ...]
# Example: count-prod-lines.sh main...HEAD
#
# Override the default exclude list with PR_PROD_EXCLUDES (space-separated git
# pathspecs). Extra pathspecs given as arguments are appended to whichever list
# is in effect.
#
# Output (stdout, one key per line):
#   PROD_LINES=<added+deleted production code lines>
#   ADDED=<n>  DELETED=<n>
#   SKIPPED_COMMENT=<n>  SKIPPED_BLANK=<n>
#   FILES=<n production files touched>

set -euo pipefail

RANGE="${1:-}"
if [[ -z "$RANGE" ]]; then
  echo "usage: count-prod-lines.sh <base>...<head> [extra-pathspec ...]" >&2
  exit 2
fi
shift

DEFAULT_EXCLUDES=(
  ':(exclude,glob)**/test/**'      ':(exclude,glob)**/tests/**'
  ':(exclude,glob)**/androidTest/**' ':(exclude,glob)**/testFixtures/**'
  ':(exclude,glob)**/__tests__/**'  ':(exclude,glob)**/__mocks__/**'
  ':(exclude,glob)**/*Test.*'      ':(exclude,glob)**/*Tests.*'
  ':(exclude,glob)**/*_test.*'     ':(exclude,glob)**/*.test.*'
  ':(exclude,glob)**/*.spec.*'
  ':(exclude,glob)**/build/**'     ':(exclude,glob)**/dist/**'
  ':(exclude,glob)**/generated/**' ':(exclude,glob)**/vendor/**'
  ':(exclude,glob)**/node_modules/**'
  ':(exclude,glob)**/*.lock'       ':(exclude,glob)**/*.md'
  ':(exclude,glob)**/*.json'       ':(exclude,glob)**/*.txt'
  ':(exclude,glob)**/*.svg'        ':(exclude,glob)**/*.png'
  ':(exclude,glob)**/*.jpg'        ':(exclude,glob)**/*.webp'
)

if [[ -n "${PR_PROD_EXCLUDES:-}" ]]; then
  read -r -a EXCLUDES <<< "$PR_PROD_EXCLUDES"
else
  EXCLUDES=("${DEFAULT_EXCLUDES[@]}")
fi
EXCLUDES+=("$@")

git diff -U0 "$RANGE" -- . "${EXCLUDES[@]}" | awk '
function commentstyle(path,   ext) {
  ext = path
  sub(/^.*\./, "", ext)
  if (ext ~ /^(kt|kts|java|js|jsx|ts|tsx|go|swift|c|h|cc|cpp|hpp|rs|scala|cs|dart|groovy|php|m|mm)$/) return "slash"
  if (ext ~ /^(py|rb|sh|bash|zsh|yml|yaml|toml|tf|pl|r|ex|exs|nix)$/) return "hash"
  if (ext ~ /^(sql|lua|hs|elm)$/) return "dash"
  return "none"   # unknown language: count every non-blank line (conservative)
}
function iscomment(body, style) {
  if (style == "slash") return body ~ /^(\/\/|\/\*|\*\/|\*)/
  if (style == "hash")  return body ~ /^#/
  if (style == "dash")  return body ~ /^(--|\{-)/
  return 0
}
/^diff --git / { style = ""; apath = ""; next }
/^--- a\// { apath = substr($0, 7); next }
/^\+\+\+ b\// {
  path = substr($0, 7)
  if (path == "/dev/null") path = apath   # file deleted: classify by its old path
  if (path == "" || path == "/dev/null") { style = "none"; next }
  style = commentstyle(path)
  if (!(path in seen)) { seen[path] = 1; files++ }
  next
}
/^(\+\+\+|---)/ { next }
/^[+-]/ {
  body = substr($0, 2)
  gsub(/^[ \t]+/, "", body)
  if (body == "") { blank++; next }
  if (iscomment(body, style)) { comment++; next }
  if (substr($0, 1, 1) == "+") added++; else deleted++
}
END {
  printf "PROD_LINES=%d\n", added + deleted
  printf "ADDED=%d\nDELETED=%d\n", added, deleted
  printf "SKIPPED_COMMENT=%d\nSKIPPED_BLANK=%d\n", comment, blank
  printf "FILES=%d\n", files
}
'
