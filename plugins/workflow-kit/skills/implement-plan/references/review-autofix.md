# Plan Review & Auto-fix (Step 8)

Referenced from `SKILL.md` Step 8. Runs ONLY after every phase is implemented and checked
off (Step 7). If the plan hard-stopped or any phase is BLOCKED/HALTED, SKIP this step —
there is nothing coherent to review. Disable entirely with `RUN_REVIEW=false`. If
`REVIEW_SKILL` is not available in the project, skip Step 8 and note it in the report.

This step mirrors Step 5's delegation discipline: the deep-tier reviewer (via the `REVIEW`
capability / `REVIEW_MODEL`) exercises judgment, a standard/light-tier fix agent
(via `FIX_MODEL`) handles mechanical application, and the orchestrator holds only the
findings list — it never ingests the raw diff.

On **claude-code** the deep-tier is `opus` and the standard/light-tier is `sonnet` / `haiku`
respectively; on **opencode** these are the named subagents registered in `model-routing.md`
(`review` and `fix`). Consult `references/model-routing.md` for per-host model ids.

## 8a. Delegate the review (deep tier — REVIEW capability)

Spawn ONE review sub-agent via the `REVIEW` capability (`REVIEW_MODEL`, deep tier; default:
`opus` on claude-code, `opencode-go/grok-4.6` on opencode — see `model-routing.md` and the
opencode agent-name registry there). Invoke as background; the 5b runaway guard applies.
Payload:

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

The orchestrator keeps the findings list (small); it does not read the diff itself.

## 8b. Triage by severity

Split findings at `REVIEW_AUTOFIX_SEVERITY` (default: high / correctness and above):

- **At/above threshold** → auto-fix queue (8c).
- **Below threshold** (nits, style, subjective, out-of-scope / pre-existing) → DO NOT
  touch. Collect them for the report (Step 10). Auto-fixing a reviewer's opinion churns good
  code — leave that call to the user.

If the auto-fix queue is empty, skip to 8d.

## 8c. Delegate the fixes (standard/light tier — FIX_MODEL, sequential in integration)

Review findings cluster on shared files, so fixes run **in the integration worktree, not in
parallel** — parallel fix agents would collide (the Step 5a file-overlap problem). Bundle
the auto-fix queue into ONE fix pass (or a few, grouped by area). For each pass:

1. Classify complexity across its findings → light tier (mechanical edits, no inference
   required) or standard tier (needs reasoning / cross-file inference); use the max tier
   across the bundle. Same tier table as Step 5a.2.

   | Finding character | Tier |
   |---|---|
   | Mechanical edits — rename, reformat, trivial substitution | light |
   | Reasoning required — logic correction, cross-file consistency | standard |
   | Genuinely tricky — ambiguous root cause, cross-cutting design | deep |

   On **claude-code** these map to `haiku` (light), `sonnet` (standard), `opus` (deep);
   on **opencode** use the corresponding named subagents (`fix` defaults to standard tier —
   see `model-routing.md`). Escalate to deep tier only for genuinely tricky fixes.

2. Spawn ONE fix sub-agent via `FIX_MODEL` at the classified tier (background; 5b guard) in
   the integration worktree. Payload: the verbatim findings to fix and the **same two-tier
   verify contract as Step 5** — "after fixing, run /verify and iterate while warm (bounded
   by `SELF_VERIFY_LIMIT`); report your self-verify result."
3. On return, the orchestrator runs the authoritative gate-verify (Step 6) on the
   integration worktree — independent confirmation, exactly as for a phase.
4. Gate fail → the Step 6 retry / escalation path, unchanged. Escalation (rung 1 of
   `model-routing.md`) switches to the deep tier with a family-diverse model — same ladder
   as a failed phase.

## 8d. Bounded re-review

A fix can introduce new issues or only partly address a finding. After the fixes verify
clean, re-run 8a→8c. Cap total review rounds at `REVIEW_MAX_ROUNDS` (default 2). Stop when
the cap is hit OR a round returns no at/above-threshold findings; list anything still open
in the report. Never loop review↔fix unbounded.
