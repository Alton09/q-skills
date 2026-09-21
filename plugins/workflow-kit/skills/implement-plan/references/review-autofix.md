# Plan Review & Auto-fix (Step 8)

Referenced from `SKILL.md` Step 8. Runs ONLY after every phase is implemented and checked
off (Step 7). If the plan hard-stopped or any phase is BLOCKED/HALTED, SKIP this step —
there is nothing coherent to review. Disable entirely with `RUN_REVIEW=false`. If
`REVIEW_SKILL` is not available in the project, skip Step 8 and note it in the report.

This step mirrors Step 5's delegation discipline: the review sub-agent (deep tier,
executor-resolved) reviews for judgment, a cheaper fix agent handles mechanical changes,
and the orchestrator holds only the findings list — it never ingests the raw diff.

## 8a. Delegate the review

Resolve `REVIEW_MODEL` as `executor:model` (see SKILL.md Configuration), then spawn ONE
review sub-agent with that registry entry (background; 5b guard applies). Payload:

- Integration worktree path + the base ref. Phases commit to the integration branch (5a.2)
  but nothing is pushed, so there is no GitHub PR — instruct it to review the **cumulative diff
  of the whole plan**: `git -C <integration> diff <base>...HEAD` — the local committed diff,
  not a PR. (This diff is non-empty precisely because phases commit; uncommitted work would be
  invisible here.)
- Invoke the project's review skill (`REVIEW_SKILL`, default `/code-review`) on that diff. It
  must be **non-interactive** — running headless in a sub-agent, an interactive review skill
  like `/pr-review` (which prompts for finding selection / posting) would stall.
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
  ```
  cd <integration> && setsid timeout <secs> codex exec --json -m <REVIEW_MODEL> -s read-only \
    --output-schema <scratch>/review-schema.json -o <scratch>/review.json \
    "$(cat <review-handoff-file>)" </dev/null > <scratch>/review.jsonl 2> <scratch>/review.err
  ```
  The schema forces a severity per finding, which 8b needs: an object with `summary` and a
  `findings` array whose items require `severity` (`critical|high|medium|low`), `category`,
  `file`, `line`, `title` and `detail`. Stop and token accounting follow
  `references/runaway-guard.md` for codex.

## 8b. Triage by severity

Split findings at `REVIEW_AUTOFIX_SEVERITY` (default: high / correctness and above):

- **At/above threshold** → auto-fix queue (8c).
- **Below threshold** (nits, style, subjective, out-of-scope / pre-existing) → DO NOT
  touch. Collect them for the report (Step 10). Auto-fixing a reviewer's opinion churns good
  code — leave that call to the user.

If the auto-fix queue is empty, skip to 8d.

## 8c. Delegate the fixes (phase tiers, sequential in integration)

Review findings cluster on shared files, so fixes run **in the integration worktree, not in
parallel** — parallel fix agents would collide (the Step 5a file-overlap problem). Bundle
the auto-fix queue into ONE fix pass (or a few, grouped by area). For each pass:

1. Classify complexity across its findings → light (mechanical) or standard (needs
   inference); use the max across the bundle. Resolve `PHASE_MODEL_LIGHT` or
   `PHASE_MODEL_STANDARD` exactly like a phase worker (Step 5a.2), including its executor.
   Use `PHASE_MODEL_DEEP` only for genuinely tricky fixes.
2. Spawn ONE fix sub-agent (background; 5b guard) in the integration worktree. Payload: the
   verbatim findings to fix and the **same two-tier verify contract as Step 5** — "after
   fixing, run /verify and iterate while warm (bounded by `SELF_VERIFY_LIMIT`); report your
   self-verify result."
3. On return, the orchestrator runs the authoritative gate-verify (Step 6) on the
   integration worktree — independent confirmation, exactly as for a phase.
4. Gate fail → the Step 6 retry / escalation path, unchanged.

## 8d. Bounded re-review

A fix can introduce new issues or only partly address a finding. After the fixes verify
clean, re-run 8a→8c. Cap total review rounds at `REVIEW_MAX_ROUNDS` (default 2). Stop when
the cap is hit OR a round returns no at/above-threshold findings; list anything still open
in the report. Never loop review↔fix unbounded.
