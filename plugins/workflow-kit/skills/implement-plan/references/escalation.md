# Escalation Pass & Hard Stop (Step 6)

Referenced from `SKILL.md` Step 6. Runs after a phase (or parallel group) has failed its
gate-verify on all `SELF_VERIFY_LIMIT` attempts.

Before paging the user, run a bounded **escalation pass** — the same Step 5 delegation
loop, run at the **deep tier with a family switch** (rung 1 of the ladder in
`references/model-routing.md`), with an extended budget. This is not a separate skill: it
reuses the orchestrator + sub-agent + two-tier-verify + 5b-guard machinery already defined,
so the rescue attempt inherits the runaway guard automatically.

**Group failures.** When the failure is a parallel group's *integration* verify (5a.3
step 6), the escalation operates on the merged integration worktree and covers ALL member
phases as a unit. The BLOCKED/HALTED marker is attached to the **first phase heading in the
group**, with a note listing every member phase. Everywhere "the failed phase" appears
below, read it as "the failed phase or group."

1. Capture the full failure history: every prior attempt's summary and every gate-verify
   error, verbatim.
2. **Annotate the plan with a BLOCKED marker** so the failure persists across sessions and
   is visible to anyone reading the plan. Append a callout block immediately under the
   failed phase heading (the first phase heading for a group):

   ```markdown
   ### Phase <N>: <name>

   > ⚠️ **BLOCKED**: `/verify` failed every gate attempt (`SELF_VERIFY_LIMIT`). Escalation in progress.
   > **Last error:** <one-line summary of the verify error>
   > **Worktree:** <worktree path>
   > **Phases:** <single phase, or all members of the group>

   - [ ] Task ...
   ```

   Write the updated plan back to disk before the escalation pass. This way, if the session
   ends mid-rescue, the plan still reflects reality and a future run can pick up the thread.

3. **Run the escalation pass** (reuse Step 5a.2 handoff + 5a.3 single-phase execution +
   Step 6 gate-verify), with these overrides:
   - **Rung 1 of the ladder** (`references/model-routing.md`): re-run at the **deep tier
     with a family switch** away from the implementer that failed. On a single-family host
     (Claude Code), the family switch is a no-op — the rescue is a deep-tier re-run with the
     richer payload and extended budget. Consult `references/model-routing.md` for the
     host-specific model selection.
   - **Extended 5b budget** — `ESCALATION_TOKEN_CEILING` / `ESCALATION_TIME_BUDGET` instead
     of the per-phase defaults (these are the hardest cases; don't strangle the rescue).
   - **Richer payload** — beyond the normal phase handoff, include the full failure history
     from step 1 and an explicit instruction: *"diagnose the root cause from the prior
     attempts and errors BEFORE writing any fix; do not just re-run the same approach."*
     This is what makes the escalation more than a model bump.
   - Bounded by `ESCALATION_ATTEMPTS` (default 2): each attempt is implement(+warm
     self-verify) → gate-verify, same as a phase. The runaway guard (5b, extended budget)
     applies to every escalation attempt.
4. Outcome:
   - **Gate pass** within the attempt budget → clear the BLOCKED callout, check off the
     phase/group (Step 7), and continue to the next phase/layer.
   - **Exhausted** (`ESCALATION_ATTEMPTS` gate failures) → replace the BLOCKED callout with
     a HALTED callout, then fall through to user-wait below:

     ```markdown
     > 🛑 **HALTED**: escalation exhausted `ESCALATION_ATTEMPTS` rung-1 rescue attempts.
     > **Last error:** <one-line summary>
     > **Worktree:** <worktree path>
     > **Rungs run:**
     >   - Rung 1, attempt 1: <model-id> (<family>)
     >   - Rung 1, attempt 2: <model-id> (<family>)
     ```

     On a host other than Claude Code, append the following block to the callout:

     ```markdown
     > **Resume in Claude Code:**
     >   Worktree: <worktree path>
     >   Failed phase: <phase-name and description>
     >   Models already run (rung 1): <model-id> (<family>), …
     >   Relaunch: Open this worktree in Claude Code and run `/implement-plan` to continue
     >   from this phase with full Claude Code capabilities.
     ```

     On Claude Code, the HALTED format above is the complete callout — no rescue block is
     appended (the run is already on Claude Code).

## User-Wait (escalation exhausted)

1. Report what failed, including the escalation attempt history and last error.
2. Call the notify skill with an error summary:
   ```
   /notify-me "implement-plan hard stop: Phase <N> failed verification every gate attempt (SELF_VERIFY_LIMIT) and escalation halted. Error: <summary>"
   ```
3. Wait for user intervention — do NOT check off the phase or continue.
4. User fixes the issue in the worktree, signals ready to retry.
5. Skill resumes from the failed phase.
