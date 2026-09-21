# Escalation Pass & Hard Stop (Step 6)

Referenced from `SKILL.md` Step 6. Runs after a phase (or parallel group) has failed its
gate-verify on all `SELF_VERIFY_LIMIT` attempts.

Before paging the user, run a bounded **escalation pass** — the same Step 5 delegation
loop, but with a stronger model and an extended budget. This is not a separate skill: it
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

   Write the updated plan back to disk **before** the escalation pass — to the
   **integration worktree's copy** of the plan (SKILL.md Step 7), the same copy the
   checkboxes are written in. Never the original checkout's copy. This way, if the session
   ends mid-rescue, the plan in the worktree the user is sent to still reflects reality and a
   future run can pick up the thread.

3. **Run the escalation pass** (reuse Step 5a.2 handoff + 5a.3 single-phase execution +
   Step 6 gate-verify), with these overrides:
   - **Rung 1 switches executor first:** a failed `pi:*` or `codex:*` worker is rescued by
     `claude:opus`; a failed `claude:*` worker stays on `claude:opus`. This executor switch
     is stronger than a same-harness model bump and is the default rescue address regardless
     of the phase's complexity classification.
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
     > 🛑 **HALTED**: escalation exhausted `ESCALATION_ATTEMPTS` opus rescue attempts.
     > **Last error:** <one-line summary>
     > **Worktree:** <worktree path>
     ```

     Write the HALTED callout to the **integration worktree's copy** of the plan — the same
     copy the checkboxes and BLOCKED marker were written in, and the file the block above
     tells the user to open. A handoff pointing at a worktree with no HALTED marker is a
     broken handoff: a resuming session reads that file and finds no record of the failure it
     is being asked to resume from.

## User-Wait (escalation exhausted)

1. Report what failed, including the escalation attempt history and last error.
2. Call the notify skill with an error summary:
   ```
   /notify-me "implement-plan hard stop: Phase <N> failed verification every gate attempt (SELF_VERIFY_LIMIT) and escalation halted. Error: <summary>"
   ```
3. Wait for user intervention — do NOT check off the phase or continue.
4. User fixes the issue in the worktree, signals ready to retry.
5. Skill resumes from the failed phase.
