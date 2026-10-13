#!/usr/bin/env bash
# Hermetic tests for escalation-rules.py. Prints `ok <n>` for each case.
set -u

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script="$here/escalation-rules.py"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
n=0

fail() { echo "FAIL case $n: $1" >&2; [ -n "${out:-}" ] && echo "  output: $out" >&2; exit 1; }
pass() { echo "ok $n"; }
expect() {
  actual=$(python3 -c 'import json,sys; value=json.load(sys.stdin); print(json.dumps(eval(sys.argv[1], {}, {"x": value}), separators=(",", ":")))' "$1" <<<"$out" 2>/dev/null) || fail "invalid JSON"
  [ "$actual" = "$2" ] || fail "$1 = $actual, expected $2"
}
run() { out=$(python3 -I "$script" "$@"); rc=$?; [ "$rc" -eq 0 ] || fail "exit $rc"; }
check() { printf '%s\n' "$1" >"$tmp/changed"; printf '%s\n' "$2" >"$tmp/named"; run check --no-defaults --rules "$3" --changed "$tmp/changed" --named "$tmp/named"; }

# 1. Shipped defaults.
n=1; run merge
expect 'len(x["ask"]) > 0' true
expect 'any(g["pattern"] == ".github/workflows/" for g in x["guardrails"])' true
pass

# 2. Only the Escalation section contributes.
cat >"$tmp/brief.md" <<'EOF'
- outside rule
## Escalation
### Ask
- inside rule
## Other
### Ask
- later rule
EOF
n=2; run merge --no-defaults --rules "$tmp/brief.md"
expect 'x["ask"]' '[{"rule":"inside rule","layer":"'"$tmp"'/brief.md"}]'
pass

# 3. Directory guardrail hits.
cat >"$tmp/project.md" <<'EOF'
### Guardrail paths
- `konsist/` — architecture
EOF
n=3; check 'konsist/src/Rule.kt' '' "$tmp/project.md"
expect 'x["hits"]' '[{"path":"konsist/src/Rule.kt","pattern":"konsist/","layer":"'"$tmp"'/project.md"}]'
pass

# 4. Basename matching.
cat >"$tmp/base.md" <<'EOF'
### Guardrail paths
- `build.gradle.kts` — build
EOF
n=4; check 'feature/menu/build.gradle.kts' '' "$tmp/base.md"
expect 'len(x["hits"])' 1
pass

# 5. ** spans path segments.
cat >"$tmp/docs.md" <<'EOF'
### Guardrail paths
- `docs/**/adr-*.md` — docs
EOF
n=5; check $'docs/a/b/adr-1.md\ndocs/adr.txt' '' "$tmp/docs.md"
expect '[h["path"] for h in x["hits"]]' '["docs/a/b/adr-1.md"]'
pass

# 6. Exact and directory named paths suppress hits.
cat >"$tmp/named.md" <<'EOF'
### Guardrail paths
- `app/**` — app
EOF
n=6; check $'app/exact.kt\napp/child/file.kt' $'app/exact.kt\napp/child/' "$tmp/named.md"
expect 'x["hits"]' '[]'
pass

# 7. Existing design note loosens a guardrail.
touch "$tmp/note.md"
cat >"$tmp/guard.md" <<'EOF'
### Guardrail paths
- `settings.gradle.kts` — build
EOF
cat >"$tmp/loosen.md" <<'EOF'
### Loosen
- `settings.gradle.kts` — note.md
EOF
n=7; printf 'settings.gradle.kts\n' >"$tmp/changed"; : >"$tmp/named"
run check --no-defaults --rules "$tmp/guard.md" --rules "$tmp/loosen.md" --changed "$tmp/changed" --named "$tmp/named"
expect 'x["hits"]' '[]'
pass

# 8. Missing note preserves the guardrail and warns.
cat >"$tmp/missing-note.md" <<'EOF'
### Loosen
- `settings.gradle.kts` — absent.md
EOF
n=8; printf 'settings.gradle.kts\n' >"$tmp/changed"; : >"$tmp/named"
run check --no-defaults --rules "$tmp/guard.md" --rules "$tmp/missing-note.md" --changed "$tmp/changed" --named "$tmp/named"
expect 'len(x["hits"])' 1
expect 'len(x["warnings"])' 1
pass

# 9. Missing layer is an error.
n=9; out=$(python3 -I "$script" merge --rules "$tmp/absent.md" 2>&1); rc=$?
[ "$rc" -eq 2 ] || fail "exit $rc"; pass

# 10. Bad guardrail bullet warns and does not add a guardrail.
cat >"$tmp/bad.md" <<'EOF'
### Guardrail paths
- not quoted
EOF
n=10; run merge --no-defaults --rules "$tmp/bad.md"
expect 'x["guardrails"]' '[]'
expect 'len(x["warnings"])' 1
pass

# 11. No defaults can produce an empty result.
n=11; run merge --no-defaults
expect 'x["ask"]' '[]'
expect 'x["guardrails"]' '[]'
pass

# 12. Unknown subcommand is an error.
n=12; out=$(python3 -I "$script" nonsense 2>&1); rc=$?
[ "$rc" -eq 2 ] || fail "exit $rc"; pass

# 13. Rootless directory patterns match nested directories.
n=13; check 'mod/konsist/Rule.kt' '' "$tmp/project.md"
expect 'len(x["hits"])' 1
pass

# 14. Rootless glob directory patterns match nested directories.
cat >"$tmp/glob-directory.md" <<'EOF'
### Guardrail paths
- `*.egg-info/` — package metadata
EOF
n=14; check 'src/foo.egg-info/PKG-INFO' '' "$tmp/glob-directory.md"
expect 'len(x["hits"])' 1
pass

# 15. A free-text loosen may contain backticks and removes the Ask rule.
touch "$tmp/decision-note.md"
cat >"$tmp/ask.md" <<'EOF'
### Ask
- A decision contradicts a `decisions.md`.
EOF
cat >"$tmp/ask-loosen.md" <<'EOF'
### Loosen
- A decision contradicts a `decisions.md`. — decision-note.md
EOF
n=15; run merge --no-defaults --rules "$tmp/ask.md" --rules "$tmp/ask-loosen.md"
expect 'x["ask"]' '[]'
expect 'x["loosened"][0]["rule"]' '"A decision contradicts a `decisions.md`."'
pass

# 16. Whole-file headings reset the active rule section.
cat >"$tmp/headings.md" <<'EOF'
### Ask
- real rule
## Notes
- example rule
EOF
n=16; run merge --no-defaults --rules "$tmp/headings.md"
expect 'x["ask"]' '[{"rule":"real rule","layer":"'"$tmp"'/headings.md"}]'
pass

# 17. Whole-file fenced examples do not contribute rules.
cat >"$tmp/fenced.md" <<'EOF'
### Ask
- real rule
```
### Ask
- example rule
```
EOF
n=17; run merge --no-defaults --rules "$tmp/fenced.md"
expect 'x["ask"]' '[{"rule":"real rule","layer":"'"$tmp"'/fenced.md"}]'
pass

# 18. Root-anchored directory patterns do not match nested directories.
cat >"$tmp/anchored-directory.md" <<'EOF'
### Guardrail paths
- `/konsist/` — root architecture
EOF
n=18; check 'mod/konsist/Rule.kt' '' "$tmp/anchored-directory.md"
expect 'x["hits"]' '[]'
pass
