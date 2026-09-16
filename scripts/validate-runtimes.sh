#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# validate-runtimes.sh — End-to-end validation harness for
# workflow-kit's `implement-plan` skill (Stage 5 of the multi-runtime plan).
#
# WHY THIS EXISTS
#   Every change to implement-plan has to be re-validated on every supported
#   host. At two or more hosts that is the only way the validation cost stays
#   sane. This script owns the whole loop: scaffold a throwaway project with a
#   REAL /verify, generate a throwaway plan, point the host at the WORKTREE
#   copy of the skill (never the installed plugin), run the host headless, and
#   collect observable evidence.
#
# USAGE
#   scripts/validate-runtimes.sh <host> [scenario] [command]
#
#     host      claude-code
#     scenario  baseline        4 phases: mechanical, normal, file-disjoint
#                               parallel pair            (default)
#               forced-failure  2 phases: mechanical, then a phase whose
#                               committed contract test is UNSATISFIABLE —
#                               forces gate failure -> escalation rung 1.
#                               Acceptance criterion on claude-code: a bare
#                               HALTED callout is emitted and the run stops.
#                               No rescue block is appended on claude-code.
#               resume          no scaffold; re-enters an existing run
#                               directory (RUN_DIR=... required) on this host.
#                               On claude-code, HALTED is the complete terminal
#                               state — point RUN_DIR at the halted run,
#                               PROJECT_SUBDIR at its integration worktree,
#                               and pass the human's decision via
#                               PROMPT_OVERRIDE to confirm the skill accepts
#                               the decision and stops cleanly (bare HALTED
#                               callout, no rescue block).
#     command   all (default) | setup | run | collect
#
# ENVIRONMENT
#   REPO_ROOT        repo whose skill is under test  (default: git toplevel)
#   VALIDATION_ROOT  where run dirs are created      (default: $TMPDIR/implement-plan-validation)
#   RUN_DIR          explicit run dir (required for `resume`)
#   PROJECT_SUBDIR   dir under RUN_DIR to run in (default: project). Set to the
#                    integration worktree (e.g. project-wordkit) to perform the
#                    escalation rung-2 manual rescue from where HALTED left off.
#   RUN_LABEL        label for the run dir name      (default: <host>-<scenario>)
#   CLAUDE_MODEL     orchestrator model, claude-code (default: opus)
#   MAX_BUDGET_USD   claude-code spend cap           (default: 15)
#   RUN_TIMEOUT      per-run wall-clock cap in seconds (default: 3600). A host
#                    that stalls with no STOP_WORKER primitive will otherwise
#                    hang forever — that is a finding, not a reason to wait.
#   PROMPT_OVERRIDE  replace the generated driver prompt entirely
#   DRY_RUN=1        scaffold + print the command, never invoke the host
#
# ADDING A HOST
#   1. add a `configure_<host>` function (make the WORKTREE skill visible, and
#      the scratch project's own skills too),
#   2. add a `run_<host>` function (headless invocation + cost capture),
#   3. add a `cost_<host>` function (however that host reports usage),
#   4. add the name to KNOWN_HOSTS.
#   Nothing else in this script is host-specific.
# ---------------------------------------------------------------------------

KNOWN_HOSTS="claude-code"

HOST="${1:-}"
SCENARIO="${2:-baseline}"
COMMAND="${3:-all}"

if [[ -z "$HOST" || " $KNOWN_HOSTS " != *" $HOST "* ]]; then
  echo "usage: $0 <${KNOWN_HOSTS// /|}> [baseline|forced-failure|resume] [all|setup|run|collect]" >&2
  exit 2
fi
case "$SCENARIO" in baseline|forced-failure|resume) ;; *)
  echo "unknown scenario: $SCENARIO" >&2; exit 2 ;;
esac
case "$COMMAND" in all|setup|run|collect) ;; *)
  echo "unknown command: $COMMAND" >&2; exit 2 ;;
esac

REPO_ROOT="${REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
SKILL_SRC="$REPO_ROOT/plugins/workflow-kit/skills"
VALIDATION_ROOT="${VALIDATION_ROOT:-${TMPDIR:-/tmp}/implement-plan-validation}"
RUN_LABEL="${RUN_LABEL:-${HOST}-${SCENARIO}}"
RUN_DIR="${RUN_DIR:-$VALIDATION_ROOT/$RUN_LABEL}"
# Absolute path for notifications so every worktree (including phase worktrees
# nested under $RUN_DIR/.wt/) appends to the same file that collect() reads.
NOTIFICATIONS_LOG="$RUN_DIR/notifications.log"
export NOTIFICATIONS_LOG
PROJECT_SUBDIR="${PROJECT_SUBDIR:-project}"
PROJECT_DIR="$RUN_DIR/$PROJECT_SUBDIR"
# A resume run must not overwrite the artifacts of the run it is rescuing —
# the halted run's report and cost data are the evidence for the handoff.
if [[ "$SCENARIO" == "resume" ]]; then
  ARTIFACT_DIR="$RUN_DIR/artifacts-resume-$HOST"
else
  ARTIFACT_DIR="$RUN_DIR/artifacts"
fi
PLAN_REL="docs/plans/wordkit.md"

CLAUDE_MODEL="${CLAUDE_MODEL:-opus}"
MAX_BUDGET_USD="${MAX_BUDGET_USD:-15}"
RUN_TIMEOUT="${RUN_TIMEOUT:-3600}"

log() { printf '[validate-runtimes] %s\n' "$*" >&2; }

# Portable wall-clock cap: macOS ships no coreutils `timeout`.
with_timeout() {
  local secs="$1"; shift
  # Enable monitor mode so the background job runs in its own process group
  # (pgid == pid).  The watchdog then uses kill -- -$pid to signal every
  # descendant, including the real claude child that would otherwise be
  # orphaned when only the wrapper subshell is killed.
  set -m
  "$@" &
  local pid=$!
  set +m
  ( sleep "$secs"
    kill -TERM -- -"$pid" 2>/dev/null
    sleep 5
    kill -KILL -- -"$pid" 2>/dev/null
  ) &
  local watchdog=$!
  local rc=0
  wait "$pid" || rc=$?
  kill -TERM "$watchdog" 2>/dev/null || true
  return "$rc"
}

# ===========================================================================
# Scaffold — a tiny REAL project: pytest suite, real /verify, real skills
# ===========================================================================

scaffold_project() {
  # On a re-run, the previous run may have left registered git worktrees,
  # sibling directories, and a notifications.log under $RUN_DIR.  Clean all of
  # these before re-scaffolding so /create-worktree never sees "already exists"
  # and collect() never presents stale notification pages.
  if git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    # De-register sibling worktrees via git so .git/worktrees stays consistent.
    git -C "$PROJECT_DIR" worktree list --porcelain 2>/dev/null \
      | awk '/^worktree /{print $2}' \
      | while IFS= read -r wt; do
          [[ "$wt" == "$PROJECT_DIR" ]] && continue
          [[ "$wt" == "$RUN_DIR/"* ]] || continue
          git -C "$PROJECT_DIR" worktree remove --force "$wt" 2>/dev/null \
            || rm -rf "$wt"
        done
    git -C "$PROJECT_DIR" worktree prune 2>/dev/null || true
  fi
  rm -rf "$PROJECT_DIR"
  # Remove any remaining sibling directories under RUN_DIR (e.g. .wt/ left after
  # phase worktrees were de-registered, or integration worktrees missed above).
  # Only touch direct children of $RUN_DIR; never touch the artifacts directory.
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    case "$(basename "$d")" in
      artifacts|"artifacts-resume-"*) continue ;;
      *) rm -rf "$d" ;;
    esac
  done < <(find "$RUN_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
  rm -f "$RUN_DIR/notifications.log"
  mkdir -p "$PROJECT_DIR"/{wordkit,tests,docs/plans,.claude/skills}

  cat > "$PROJECT_DIR/verify.sh" <<'EOF'
#!/usr/bin/env bash
# Real verification command for this project.
cd "$(dirname "$0")"
exec python3 -m pytest -q
EOF
  chmod +x "$PROJECT_DIR/verify.sh"

  : > "$PROJECT_DIR/wordkit/__init__.py"
  cat > "$PROJECT_DIR/tests/test_smoke.py" <<'EOF'
def test_package_importable():
    import wordkit  # noqa: F401
EOF
  cat > "$PROJECT_DIR/pytest.ini" <<'EOF'
[pytest]
testpaths = tests
EOF
  cat > "$PROJECT_DIR/README.md" <<'EOF'
# wordkit

Throwaway project used by `scripts/validate-runtimes.sh` to exercise
`implement-plan` end-to-end on each supported host. Not shipped anywhere.

Verify with: `./verify.sh`
EOF

  scaffold_skills
  [[ "$SCENARIO" == "forced-failure" ]] && plant_failure
  write_plan

  git -C "$PROJECT_DIR" init -q -b main
  git -C "$PROJECT_DIR" add -A
  git -C "$PROJECT_DIR" -c user.email=validate@local -c user.name=validate \
      commit -q -m "wordkit scaffold"
}

scaffold_skills() {
  local S="$PROJECT_DIR/.claude/skills"

  mkdir -p "$S/verify"
  cat > "$S/verify/SKILL.md" <<'EOF'
---
name: verify
description: Verify the wordkit project builds and all tests pass. Use whenever asked to verify, validate, or check that the project is green.
---

# Verify

Run the project's real verification command from the repository root of the
worktree you are working in:

```bash
./verify.sh
```

This runs `python3 -m pytest -q` over `tests/`.

Report the result as exactly one of:

- `VERIFY: pass` — exit code 0
- `VERIFY: fail` — non-zero exit code, followed by the verbatim pytest output

Do not fix anything from inside this skill. Only run the command and report.
EOF

  mkdir -p "$S/create-worktree"
  cat > "$S/create-worktree/SKILL.md" <<'EOF'
---
name: create-worktree
description: Create an isolated git worktree for a feature. Use when asked to create a worktree, set up an isolated branch workspace, or start work in isolation.
---

# Create Worktree

Create a sibling worktree of this repository.

```bash
REPO="$(git rev-parse --show-toplevel)"
NAME="<short-feature-slug>"
git -C "$REPO" worktree add -b "feat/$NAME" "$REPO/../$(basename "$REPO")-$NAME" HEAD
```

Then report the absolute worktree path and the branch name. Do not cd the
caller anywhere; just report the path.
EOF

  mkdir -p "$S/notify-me"
  cat > "$S/notify-me/SKILL.md" <<'EOF'
---
name: notify-me
description: Send the user a notification. Use to page the user on completion, a hard stop, or when input is required.
---

# Notify Me

Append the message to the run's notification log and echo it:

```bash
echo "[notify] $(date -u +%FT%TZ) <message>" | tee -a "${NOTIFICATIONS_LOG}"
```

This is a headless validation environment — there is no interactive user. After
notifying, continue to report your final status rather than blocking forever.
EOF

  mkdir -p "$S/code-review"
  cat > "$S/code-review/SKILL.md" <<'EOF'
---
name: code-review
description: Review a diff for correctness and quality. Use when asked to review code, review a diff, or check changes before merge. Non-interactive — never prompts.
---

# Code Review

Review the diff you are given (or `git diff main...HEAD` when none is given).

This skill is NON-INTERACTIVE: never ask the user anything.

Return only a findings list, no code changes:

```
- [severity: critical|high|medium|low] <file>:<line> — <problem> — <suggested fix>
```

If there are no findings, return exactly: `No findings.`
Focus on correctness bugs and missing tests. Style nits are `low`.
EOF
}

plant_failure() {
  # A committed contract test that is UNSATISFIABLE by construction: two
  # assertions on the same input demand two different outputs. No implementer
  # at any tier can make this pass by editing the implementation — that is the
  # point. It forces gate failure -> rung 1 family switch -> HALTED, which is
  # the escalation path under test. The fix requires a judgement call the
  # phase contract forbids (editing a test the phase did not create), which is
  # exactly what the manual rung exists for.
  #
  # pytest.importorskip keeps the test inert (entire module skipped, rc=0 for
  # the skip) when wordkit.slugify does not yet exist (Phase 1), and fails as
  # a single assertion failure (rc=1) once the module is created (Phase 2).
  # Without this, pytest aborts collection (rc=2) and the scenario halts in
  # Phase 1 instead of reaching the intended phase.
  cat > "$PROJECT_DIR/tests/test_slugify_contract.py" <<'EOF'
"""Frozen contract tests for slugify. Phase agents must NOT edit this file."""
import pytest

slugify_mod = pytest.importorskip(
    "wordkit.slugify",
    reason="wordkit.slugify not yet implemented — skipping until Phase 2",
)
slugify = slugify_mod.slugify


def test_contract_hyphen_form():
    assert slugify("Hello World") == "hello-world"


def test_contract_underscore_form():
    assert slugify("Hello World") == "hello_world"
EOF
}

write_plan() {
  local plan="$PROJECT_DIR/$PLAN_REL"
  mkdir -p "$(dirname "$plan")"

  if [[ "$SCENARIO" == "forced-failure" ]]; then
    cat > "$plan" <<'EOF'
# Feature: wordkit core helpers

## Overview
Add two tiny pure-Python helpers to the `wordkit` package. Each phase owns its
own files. Verification is `./verify.sh` (pytest).

## Phases

### Phase 1 — Constants module
**Files**: `wordkit/constants.py`, `tests/test_constants.py`

- [ ] Create `wordkit/constants.py` defining exactly two module-level constants: `VOWELS = "aeiou"` and `SEPARATORS = " -_"`
- [ ] Create `tests/test_constants.py` asserting both constants equal those exact strings

### Phase 2 — Slugify (depends on Phase 1)
**Files**: `wordkit/slugify.py`, `tests/test_slugify.py`

- [ ] Implement `slugify(text: str) -> str` in `wordkit/slugify.py`: lowercase the input, replace every character present in `SEPARATORS` (imported from `wordkit.constants`) with `-`, drop any remaining character that is not `a`-`z`, `0`-`9` or `-`, collapse runs of `-` into one, and strip leading/trailing `-`
- [ ] Create `tests/test_slugify.py` covering at least `"Hello World" -> "hello-world"` and `"  A__B--C  " -> "a-b-c"`
- [ ] The repository already contains `tests/test_slugify_contract.py`. It is a frozen contract file — do NOT edit or delete it. Your implementation must satisfy it.

## Task Dependency Graph

```
Phase 1 (sequential): constants
Phase 2 (sequential, depends on Phase 1): slugify
```

## Tests
- `./verify.sh` (pytest) must be green at the end of every phase.

## Edge Cases
- Empty string input
- Input that is entirely separators
EOF
  else
    cat > "$plan" <<'EOF'
# Feature: wordkit text utilities

## Overview
Add four tiny pure-Python helpers to the `wordkit` package. Each phase owns its
own files, so Phases 3 and 4 are file-disjoint and may run in parallel.
Verification is `./verify.sh` (pytest).

## Phases

### Phase 1 — Constants module
**Files**: `wordkit/constants.py`, `tests/test_constants.py`

- [ ] Create `wordkit/constants.py` defining exactly two module-level constants: `VOWELS = "aeiou"` and `SEPARATORS = " -_"`
- [ ] Create `tests/test_constants.py` asserting both constants equal those exact strings

### Phase 2 — Slugify (depends on Phase 1)
**Files**: `wordkit/slugify.py`, `tests/test_slugify.py`

- [ ] Implement `slugify(text: str) -> str` in `wordkit/slugify.py`: lowercase the input, replace every character present in `SEPARATORS` (imported from `wordkit.constants`) with `-`, drop any remaining character that is not `a`-`z`, `0`-`9` or `-`, collapse runs of `-` into one, and strip leading/trailing `-`
- [ ] Create `tests/test_slugify.py` covering at least `"Hello World" -> "hello-world"` and `"  A__B--C  " -> "a-b-c"`

### Phase 3 — Word count (depends on Phase 2)
**Files**: `wordkit/wordcount.py`, `tests/test_wordcount.py`

- [ ] Implement `word_count(text: str) -> int` in `wordkit/wordcount.py` returning the number of whitespace-separated tokens
- [ ] Create `tests/test_wordcount.py` covering the empty string (0), a single word (1), and multiple words with irregular spacing

### Phase 4 — Title case (depends on Phase 2)
**Files**: `wordkit/titlecase.py`, `tests/test_titlecase.py`

- [ ] Implement `title_case(text: str) -> str` in `wordkit/titlecase.py` upper-casing the first letter of each whitespace-separated word and lower-casing the rest
- [ ] Create `tests/test_titlecase.py` covering `"hello world" -> "Hello World"` and `"gOOd DAY" -> "Good Day"`

## Task Dependency Graph

```
Phase 1 (sequential): constants
Phase 2 (sequential, depends on Phase 1): slugify
Phase 3 (parallel, depends on Phase 2): word_count
Phase 4 (parallel, depends on Phase 2): title_case
```

## Tests
- `./verify.sh` (pytest) must be green at the end of every phase.

## Edge Cases
- Empty string input for every helper
- Input that is entirely separators or whitespace
EOF
  fi
}

# ===========================================================================
# Host configuration — always point at the WORKTREE skill, never the installed
# plugin cache. This is the single most important property of this harness.
# ===========================================================================

configure_claude_code() {
  # Project-scoped skills dir wins, and `--setting-sources project` keeps user
  # settings (and therefore the installed workflow-kit plugin + global hooks)
  # out of the run entirely.
  mkdir -p "$PROJECT_DIR/.claude/skills"
  ln -snf "$SKILL_SRC/implement-plan" "$PROJECT_DIR/.claude/skills/implement-plan"
  cat > "$PROJECT_DIR/.claude/settings.json" <<'EOF'
{
  "permissions": { "defaultMode": "bypassPermissions" }
}
EOF
}

# ===========================================================================
# Driver prompt — pre-answers every interactive Step 0 question, because
# headless hosts have no user. Coverage note: this means AskUserQuestion-style
# interactive prompts are NOT exercised by this harness.
# ===========================================================================

build_prompt() {
  if [[ -n "${PROMPT_OVERRIDE:-}" ]]; then printf '%s' "$PROMPT_OVERRIDE"; return; fi
  local plan_arg="$PLAN_REL"
  cat <<EOF
Use the implement-plan skill to implement the plan at $plan_arg.
This is a fully unattended headless run — there is no interactive user, so
treat the following as the answers to every question the skill would ask:

- Plan path: $plan_arg
- Orchestrator model: this session's model; confirmed, continue without asking.
- Create a worktree: yes.
- If the skill would wait for user input at any point, instead write the report
  it would have written and stop.

Run the whole workflow to its end and print the final report, including its
Runtime & Models section.
EOF
}

# ===========================================================================
# Run
# ===========================================================================

run_claude_code() {
  local prompt; prompt="$(build_prompt)"
  mkdir -p "$ARTIFACT_DIR"
  log "claude -p (model=$CLAUDE_MODEL, budget=\$$MAX_BUDGET_USD)"
  if [[ -n "${DRY_RUN:-}" ]]; then echo "DRY_RUN: claude -p ... in $PROJECT_DIR"; return 0; fi
  _cc() { cd "$PROJECT_DIR" && claude -p "$prompt" \
      --model "$CLAUDE_MODEL" \
      --setting-sources project \
      --permission-mode bypassPermissions \
      --output-format json \
      --max-budget-usd "$MAX_BUDGET_USD" \
      --add-dir "$RUN_DIR" \
      > "$ARTIFACT_DIR/claude-result.json" 2> "$ARTIFACT_DIR/claude-stderr.log"; }
  with_timeout "$RUN_TIMEOUT" _cc || log "claude run ended non-zero (timeout or error) — collecting anyway"
  python3 - "$ARTIFACT_DIR/claude-result.json" "$ARTIFACT_DIR/report.md" <<'PY' || true
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    print("could not parse claude json:", e); raise SystemExit(0)
open(sys.argv[2], "w").write(d.get("result") or "")
PY
}

# ===========================================================================
# Cost
# ===========================================================================

cost_claude_code() {
  python3 - "$ARTIFACT_DIR/claude-result.json" <<'PY' || true
import json, sys
try: d = json.load(open(sys.argv[1]))
except Exception: print("cost: unavailable"); raise SystemExit(0)
u = d.get("usage") or {}
print("host: claude-code (metered)")
print("total_cost_usd:", d.get("total_cost_usd"))
print("duration_ms:", d.get("duration_ms"))
print("num_turns:", d.get("num_turns"))
for k in ("input_tokens","output_tokens","cache_read_input_tokens","cache_creation_input_tokens"):
    print(f"{k}:", u.get(k))
PY
}

# ===========================================================================
# Collect — observable evidence only; never edit the skill to make a run pass
# ===========================================================================

collect() {
  mkdir -p "$ARTIFACT_DIR"
  local out="$ARTIFACT_DIR/collected.txt"
  {
    echo "=== run ==============================================================="
    echo "host:      $HOST"
    echo "scenario:  $SCENARIO"
    echo "run dir:   $RUN_DIR"
    echo "skill src: $SKILL_SRC/implement-plan"
    echo
    echo "=== worktrees created ================================================="
    git -C "$PROJECT_DIR" worktree list 2>/dev/null || echo "(none / not a repo)"
    echo
    echo "=== branches =========================================================="
    git -C "$PROJECT_DIR" branch -a 2>/dev/null || true
    echo
    echo "=== commits per worktree =============================================="
    for wt in $(git -C "$PROJECT_DIR" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}'); do
      echo "--- $wt"
      git -C "$wt" log --oneline -20 2>/dev/null || true
    done
    echo
    echo "=== plan checkbox state (every copy of the plan) ======================"
    for wt in $(git -C "$PROJECT_DIR" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}'); do
      if [[ -f "$wt/$PLAN_REL" ]]; then
        echo "--- $wt/$PLAN_REL"
        grep -nE '^(###|- \[|> ⚠️|> 🛑|>   )' "$wt/$PLAN_REL" || true
      fi
    done
    echo
    echo "=== verify result in each worktree ===================================="
    for wt in $(git -C "$PROJECT_DIR" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}'); do
      if [[ -x "$wt/verify.sh" ]]; then
        echo "--- $wt"
        ( cd "$wt" && ./verify.sh 2>&1 | tail -5 ) || true
      fi
    done
    echo
    echo "=== notifications ====================================================="
    cat "$RUN_DIR/notifications.log" 2>/dev/null || echo "(none)"
    echo
    echo "=== cost =============================================================="
    "cost_${HOST//-/_}"
  } | tee "$out"
  log "collected -> $out"
}

# ===========================================================================

main() {
  case "$COMMAND" in
    setup)   do_setup ;;
    run)     do_run ;;
    collect) collect ;;
    all)     do_setup; do_run; collect ;;
  esac
}

do_setup() {
  if [[ "$SCENARIO" == "resume" ]]; then
    [[ -d "$PROJECT_DIR" ]] || { echo "resume needs an existing RUN_DIR with a project/" >&2; exit 2; }
    log "resume: reusing $PROJECT_DIR"
  else
    log "scaffolding $PROJECT_DIR ($SCENARIO)"
    mkdir -p "$RUN_DIR"
    scaffold_project
  fi
  "configure_${HOST//-/_}"
  log "configured for $HOST"
}

do_run() {
  local t0 t1
  t0=$(date -u +%s)
  "run_${HOST//-/_}"
  t1=$(date -u +%s)
  echo "$((t1 - t0))" > "$ARTIFACT_DIR/wall-seconds"
  log "run finished in $((t1 - t0))s"
}

main
