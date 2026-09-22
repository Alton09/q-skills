# Plan Review, E2E & Auto-fix (Step 8)

Referenced from `SKILL.md` Step 8. Runs ONLY after every phase is implemented and checked
off (Step 7). If the plan hard-stopped or any phase is BLOCKED/HALTED, skip review and E2E
and state the reason in the report. Disable review with `RUN_REVIEW=false`; skip it when
`REVIEW_SKILL` is absent. Disable E2E with `RUN_E2E=false`; skip it when `E2E_SKILL` is
absent. E2E runs alone when review is skipped. Review runs alone when E2E is skipped.

This step mirrors Step 5's delegation discipline. The review sub-agent judges the diff.
The E2E sub-agent runs device checks. One cheaper fix agent handles both result sets. The
orchestrator holds only the findings list and compact E2E hand-back. It never ingests the
raw diff or verbatim E2E failures.

## 8a. Fan out review and E2E

Resolve `REVIEW_MODEL` and `E2E_MODEL` as `executor:model` (see SKILL.md Configuration).
When enabled, spawn ONE review sub-agent and ONE E2E sub-agent together on the same `HEAD`.
Use the executor registry and background spawn contract for each. Both share the worktree
and the Step 5 concurrent-worker limit. Give each its own runaway timer: the review uses its
resolved tier budget; E2E uses `E2E_TIME_BUDGET` and `E2E_TOKEN_CEILING`. Record the spawn
time for E2E. Wait for both enabled workers before 8b, even when one finishes much earlier.

Review payload:

- Integration worktree path + the base ref. Phases commit to the integration branch (5a.2)
  but nothing is pushed, so there is no GitHub PR — instruct it to review the **cumulative diff
  of the whole plan**: `git -C <integration> diff <base>...HEAD` — the local committed diff,
  not a PR. (This diff is non-empty precisely because phases commit; uncommitted work would be
  invisible here.)
- Invoke the project's review skill (`REVIEW_SKILL`, default `/code-review`) on that diff. It
  must be **non-interactive and read-only**. It must not build, test, or write files. Running
  headless, an interactive review skill like `/pr-review` would stall. A build or test also
  contends with E2E for the Gradle lock. If a consumer review skill builds, disable review
  or E2E, or give E2E its own build directory.
- Required return format: a **structured findings list only** — each item is `severity`,
  `file:line`, one-line problem, suggested fix. No narrative, no diff echo.
- **Confirm the resolved target before the findings.** A review skill may resolve its own
  scope from the ambient git state instead of the assigned one, silently. Measured
  2026-09-19 (MenuLens session `21163bb7`): `/code-review high`, spawned from a review agent
  whose prompt named the integration worktree and `main...HEAD`, ran in the *main checkout*
  and reviewed the previous commit there; all four findings were about an unrelated change.
  Require the reviewer to open its return with the absolute repo path and the
  `<base>...<head>` range it actually reviewed, and to check both against the assigned
  worktree. On a mismatch it discards those findings, re-runs the review scoped explicitly
  to the assigned diff, and says so. A findings list that arrives without that line is not
  trusted: re-run the review before triage.

The orchestrator keeps the findings list (small); it does not read the diff itself.

E2E payload:

- Absolute integration worktree path.
- Every `[e2e]` acceptance criterion from the Step 1 extract, verbatim with its phase. An
  empty list still runs the normal suite.
- The contract in `references/e2e.md`. The worker writes no code and returns only its
  required hand-back.

Before accepting `status: pass`, check in one Bash call that `evidence` exists and its
timestamp is newer than the E2E spawn time. A missing or stale path is a failed hand-back,
not a pass. This proof guards foreign workers that skip device work. An `env-error` means
E2E did not run. It does not block the review path, never enters the fix queue, and does
not stop Step 9 from opening the PR.

If one worker hits its runaway guard, stop and report only that worker as `not finished`.
The other worker's result still counts. Do not re-run the stopped worker automatically in
that round. Wait for the other worker before continuing. A Step 8 runaway does not enter
the Step 6 opus rescue; it is an open result for the user.

**Foreign review executors (`pi`, `codex`).** A foreign reviewer cannot invoke `REVIEW_SKILL`
(no `Skill` tool). Give it a written review handoff instead: the diff command above, the
project's architecture skill named by path (5a.2 § 3), the review scope (correctness,
behavior changes, build/packaging, architecture-rule violations; no style), and the findings
format above. Tell it not to modify files. Record in the report that the review ran from a
handoff, not from `REVIEW_SKILL` — it is not a like-for-like substitute.

- **`pi`** → the 5a.3 pi spawn contract with the review handoff.
- **`codex`** → `codex exec`, **not** `codex exec review`. The native command cannot take
  instructions together with `--base` (`error: the argument '--base <BRANCH>' cannot be used
  with '[PROMPT]'`) and reports zero token usage. Spawn:
  ```bash
  cd <integration> && { setsid timeout -k <grace> <budget-plus-5-min-secs> codex exec --json \
    -m <model part of REVIEW_MODEL> -s read-only \
    --output-schema <scratch>/review-schema.json -o <scratch>/review.json \
    "$(cat <review-handoff-file>)" </dev/null > <scratch>/review.jsonl \
    2> <scratch>/review.err & echo $! > <scratch>/review.pid; wait $!; }
  ```
  Run this with `Bash(run_in_background: true)`. The schema requires top-level `repo_path`
  (absolute path), `range` (`<base>...<head>`), and `summary`, plus a `findings` array whose
  items require `severity` (`critical|high|medium|low`), `category`, `file`, `line`, `title`
  and `detail`. For schema output, the scope check above reads `repo_path` and `range`;
  absent or mismatched fields make the findings untrusted and require a re-run. Stop and
  token accounting follow `references/runaway-guard.md` for codex.

## 8b. Triage findings and failures

Split findings at `REVIEW_AUTOFIX_SEVERITY` (default: high / correctness and above):

- **At/above threshold** → auto-fix queue (8c).
- **Below threshold** (nits, style, subjective, out-of-scope / pre-existing) → DO NOT
  touch. Collect them for the report (Step 10). Auto-fixing a reviewer's opinion churns good
  code — leave that call to the user. The orchestrator never edits code for any finding.
  If the user later wants a below-threshold finding fixed, a fresh session delegates it to a
  light-tier fix sub-agent resolved on the active executor under §8c's same two-tier verify
  contract (warm self-verify bounded by `SELF_VERIFY_LIMIT`, then an independent gate-verify);
  it is never an orchestrator edit.

Add failed E2E names to the auto-fix queue with the `evidence` path. Do not add flaky names,
`env-error`, a failed hand-back, or a stopped E2E worker. If the combined queue is empty,
skip to 8d.

## 8c. Delegate the fixes (phase tiers, sequential in integration)

Review findings and E2E failures can share files, so fixes run **in the integration worktree,
not in parallel**. Bundle the whole combined queue into ONE fix pass per round:

1. Classify complexity across its findings → light (mechanical) or standard (needs
   inference); use the max across the bundle. Resolve `PHASE_MODEL_LIGHT` or
   `PHASE_MODEL_STANDARD` exactly like a phase worker (Step 5a.2), including its executor.
2. Spawn ONE fix sub-agent (background; 5b guard) in the integration worktree. Payload: the
   verbatim at-threshold review findings, the E2E failed names, and the `evidence` path. The
   fix agent reads verbatim failures from `evidence`; the orchestrator never does. Include
   the **same two-tier verify and commit contract as Step 5** — after fixing, run `/verify`
   and iterate while warm, bounded by `SELF_VERIFY_LIMIT`; commit on pass; report whether a
   commit was made.
3. On return, the orchestrator runs the authoritative gate-verify (Step 6) on the
   integration worktree — one independent confirmation for the combined pass, exactly as
   for a phase. Do not run a gate per source.
4. Gate fail → report the open result and stop this combined loop. Do not use the Step 6
   opus rescue for a Step 8 failure.

## 8d. Bounded re-run

A fix can introduce new issues or only partly address a finding. After a fix commit passes
the gate, start the next round: re-review and re-run E2E together on the new `HEAD`. An E2E
result from before that commit feeds only the fix pass and never the final report. If the
fix pass commits nothing, keep the last E2E result and re-review only when another round is
needed; do not re-run E2E.

Cap the whole combined loop at `REVIEW_MAX_ROUNDS` (default 2). Stop when the cap is hit or
a round has no at-threshold findings or E2E failures. At the cap, keep the branch and list
open findings and failed names in the report. The report shows only the last E2E run on the
code that ships. Never loop review/E2E↔fix unbounded.
