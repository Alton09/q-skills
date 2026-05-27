---
name: deep-dive
description: >
  Rescue a stuck implementation phase by spawning a single stronger-model sub-agent
  to diagnose and fix a 3x verification failure. Use this skill whenever the user says
  "deep dive", "rescue this phase", "try again with a stronger model", "send in opus",
  invokes `/deep-dive`, or whenever the `implement-plan` skill hits its hard-stop path
  after three consecutive `/verify` failures on the same phase. Also trigger when the
  user is stuck on a specific failing phase and wants one focused, higher-capability
  attempt before giving up — even if they don't say "deep dive" explicitly.
---

# Deep Dive

A focused rescue pass for an `implement-plan` phase that has exhausted its retry budget.
Spawn one sub-agent with a stronger model, hand it everything it needs to understand the
failure, and let it attempt a fix in the same worktree. Hard-cap the attempts so a stuck
phase cannot quietly burn the user's token budget.

## When This Skill Runs

Two entry points:

1. **Manual** — user invokes `/deep-dive` after watching a phase fail repeatedly, or wants
   to throw a stronger model at a tricky problem.
2. **Auto-delegated** — `implement-plan` hits its 3x `/verify` failure hard-stop on a phase
   and routes here before falling back to the user-wait path.

In both cases the skill operates as the *escalation step before the human is paged*.

## Inputs

Collect these before doing anything. If `implement-plan` delegated, it should pass them
through; otherwise prompt the user.

- **Plan file path** — the markdown plan being executed
- **Failed phase** — section heading or task ID that failed verification
- **Last `/verify` error output** — raw error/log from the most recent failed run
- **Worktree path** — where the in-progress code lives
- **Model override** — optional, defaults to Opus

If the failed phase or error output is missing, ask once. Don't proceed blind — the whole
point of deep-dive is targeted reasoning over the actual failure signal.

## Plan Annotation Contract

`implement-plan` writes a `> ⚠️ **BLOCKED**: ...` callout under the failed phase heading
before handing off. This skill owns that marker for the duration of the rescue loop:

- On entry, expect the BLOCKED callout to already be present. If it's not (manual
  invocation), write one yourself before Step 2 so the plan reflects in-progress rescue.
- On success (Step 3 pass), **remove the BLOCKED callout** so the plan returns to a clean
  state before `implement-plan` checks off the phase.
- On halt (Step 4), **replace the BLOCKED callout with a HALTED callout** that captures
  the final error and worktree path — see Step 4 for the exact format.

Always write the plan back to disk after touching the marker. The point of the marker is
durability across sessions; transient updates defeat that.

## Attempt Budget

**Hard cap: 3 deep-dive attempts.** This skill's job is not to grind indefinitely on a
hard problem — it is to give one focused, higher-capability rescue effort. After 3 failed
attempts, halt and notify the user. The cost of a runaway deep-dive (token burn, wall
clock, no convergence signal) is higher than the cost of asking the user to look at it.

Track attempt count in working memory across the loop below.

## Step 1: Gather Context

1. Read the plan file at the provided path
2. Locate the failed phase section and extract its tasks
3. Read the `/verify` error output verbatim — preserve quoted text, stack traces, file:line
4. Invoke `/clean-architecture` to load the project's architecture rules into context

The sub-agent gets briefed with this material, so the parent must collect it cleanly.
Don't paraphrase the error — the exact message often contains the fix.

## Step 2: Spawn the Rescue Sub-Agent

Use the Agent tool with the stronger model (default Opus, or the user's override). Brief
it with everything from Step 1. The sub-agent's job is to diagnose, fix, and re-verify
in one pass.

Sub-agent prompt template:

```
You are rescuing a stuck implementation phase. The primary agent ran /verify three times
on this phase and failed each time. Your job: diagnose the root cause, apply a fix in
the worktree, then run /verify and report whether it passed.

Plan: <plan file path>
Failed phase: <phase name / heading>
Worktree: <worktree path>

The phase tasks:
<copy of phase tasks from plan>

Last /verify error output:
<raw error output, fenced>

Architecture rules (from /clean-architecture):
<rules summary or pointer>

Constraints:
- Work only inside the worktree path above
- Honor the architecture rules — don't bypass layers or add abstractions the rules forbid
- Don't restructure unrelated code; stay focused on the phase's scope and the failure signal
- After you apply your fix, run /verify and report the exact pass/fail result back to me
- If you can't determine a fix from the error signal alone, say so explicitly rather than
  guessing — a clear "I don't know why" is more useful than a speculative patch

Report back with:
1. Root cause diagnosis (one or two sentences)
2. What you changed (file paths + summary)
3. /verify result (pass | fail + raw output if fail)
```

Spawn the sub-agent with `subagent_type: general-purpose` (or a more specific type if
appropriate) and the model override.

## Step 3: Read the Result

When the sub-agent returns:

- **Pass** → remove the BLOCKED callout from the plan and write the plan back. Exit
  successfully and return control to `implement-plan` so it can check off the phase and
  continue. Report to the user: which attempt succeeded, root cause, files changed.
- **Fail** → log the new error output, increment attempt counter, and decide:
  - If attempts < 3 → return to Step 2 with the new error signal in the brief
  - If attempts == 3 → go to Step 4

Each retry's brief should include the *previous* attempt's diagnosis and what it tried.
This avoids the rescue agent repeating a failed approach and gives it a chance to course-correct.

## Step 4: Hard Halt

Three rescue attempts have failed. Stop.

1. **Replace the BLOCKED callout in the plan with a HALTED callout** under the failed
   phase heading, then write the plan back to disk:

   ```markdown
   ### Phase <N>: <name>

   > 🛑 **HALTED**: deep-dive exhausted 3 rescue attempts.
   > **Last error:** <one-line summary>
   > **Worktree:** <worktree path>
   > **Recovery:** investigate manually, then re-run `/implement-plan` from this phase.

   - [ ] Task ...
   ```

   The HALTED marker is the durable signal that this phase needs human attention. Leave
   it in place — the user (or a later session) clears it when they resume.

2. Invoke `/notify-me` with a summary:
   ```
   /notify-me "deep-dive halt: Phase <name> failed 3x rescue attempts. Last error: <one-line summary>"
   ```
3. Print a halt report to the user:

```markdown
# Deep Dive Halted

**Plan:** <plan name>
**Phase:** <phase name>
**Attempts:** 3 (all failed)
**Worktree:** <path>

## Attempt History
1. Attempt 1 — <one-line diagnosis> → fail
2. Attempt 2 — <one-line diagnosis> → fail
3. Attempt 3 — <one-line diagnosis> → fail

## Last Error
<raw /verify output from attempt 3>

## Recovery
- The worktree is intact at <path>
- Review the attempt history above for partial progress to keep or discard
- Investigate manually, then resume `implement-plan` from this phase or revise the plan
```

4. Do NOT check off the phase. Do NOT continue. Wait for the user. The HALTED callout
   in the plan is the source of truth for what needs attention.

## Why the Cap Matters

A rescue loop without a cap can chew through tokens on a problem that is genuinely
ambiguous, blocked on missing information (e.g., an external API change), or outside
the model's reach with the available context. Three attempts is enough to try meaningfully
different angles; beyond that, returning control to the human is almost always cheaper
than another attempt.

## Why a Sub-Agent

The parent agent has been running the plan and may have accumulated context that's pulling
it toward the same failed approach. A fresh sub-agent with a focused brief — plan tasks,
error output, architecture rules — gets a clean reasoning slate and a stronger model.
That combination is what makes deep-dive meaningfully different from the parent's own
retry loop, not just "try again with more determination".

## Configuration

- Default rescue model: **Opus**
- Max attempts: **3** (do not raise without an explicit user request)
- Sub-agent isolation: same worktree as the parent — fixes need to land where the next
  `/verify` will run

## Notes

- This skill does not commit, merge, or clean up. The worktree is the user's to keep
  or discard after the loop terminates.
- The skill is project-agnostic. It delegates verification to `/verify` and architecture
  rules to `/clean-architecture`, just like its sibling skills in workflow-kit.
- If `/clean-architecture` or `/verify` is missing in the project, surface that to the
  user and proceed with whatever guidance the project does provide. Don't fabricate rules.
