# Plan Review & Auto-fix (Step 8)

Referenced from `SKILL.md` Step 8. Runs ONLY after every phase is implemented and checked
off (Step 7). If the plan hard-stopped or any phase is BLOCKED/HALTED, SKIP this step —
there is nothing coherent to review. Disable entirely with `RUN_REVIEW=false`. If
`REVIEW_SKILL` is not available in the project, skip Step 8 and note it in the report.

This step mirrors Step 5's delegation discipline: Opus reviews (judgment), a cheaper agent
fixes (mechanical), and the orchestrator holds only the findings list — it never ingests
the raw diff.

## 8a. Delegate the review (Opus)

Spawn ONE review sub-agent with `model: opus` (background; 5c guard applies). Payload:

- Integration worktree path + the base ref. There is no GitHub PR at this point (the skill
  never commits or pushes), so instruct it to review the **cumulative diff of the whole
  plan**: `git -C <integration> diff <base>...HEAD` — the local diff, not a PR.
- Invoke the project's review skill (`REVIEW_SKILL`, default `/pr-review`) on that diff.
- The architecture digest (5a) so findings respect project rules.
- Required return format: a **structured findings list only** — each item is `severity`,
  `file:line`, one-line problem, suggested fix. No narrative, no diff echo.

The orchestrator keeps the findings list (small); it does not read the diff itself.

## 8b. Triage by severity

Split findings at `REVIEW_AUTOFIX_SEVERITY` (default: high / correctness and above):

- **At/above threshold** → auto-fix queue (8c).
- **Below threshold** (nits, style, subjective, out-of-scope / pre-existing) → DO NOT
  touch. Collect them for the report (Step 9). Auto-fixing a reviewer's opinion churns good
  code — leave that call to the user.

If the auto-fix queue is empty, skip to 8d.

## 8c. Delegate the fixes (Sonnet/Haiku, sequential in integration)

Review findings cluster on shared files, so fixes run **in the integration worktree, not in
parallel** — parallel fix agents would collide (the Step 5b file-overlap problem). Bundle
the auto-fix queue into ONE fix pass (or a few, grouped by area). For each pass:

1. Classify complexity across its findings → `haiku` (mechanical) or `sonnet` (needs
   inference); use the max across the bundle. Same table as Step 5b.2. (Escalate to `opus`
   only for genuinely tricky fixes.)
2. Spawn ONE fix sub-agent (background; 5c guard) in the integration worktree. Payload: the
   verbatim findings to fix, the architecture digest, and the **same two-tier verify
   contract as Step 5** — "after fixing, run /verify and iterate while warm (bounded by
   `SELF_VERIFY_LIMIT`); report your self-verify result."
3. On return, the orchestrator runs the authoritative gate-verify (Step 6) on the
   integration worktree — independent confirmation, exactly as for a phase.
4. Gate fail → the Step 6 retry / escalation path, unchanged.

## 8d. Bounded re-review

A fix can introduce new issues or only partly address a finding. After the fixes verify
clean, re-run 8a→8c. Cap total review rounds at `REVIEW_MAX_ROUNDS` (default 2). Stop when
the cap is hit OR a round returns no at/above-threshold findings; list anything still open
in the report. Never loop review↔fix unbounded.
