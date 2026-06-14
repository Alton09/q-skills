---
name: implement-plan
description: |
  Execute a plan end-to-end with an orchestrator that delegates each phase to a
  dedicated sub-agent, plus automatic quality verification and task tracking.

  Use this skill whenever you have a structured implementation plan (markdown file 
  with phases and checkboxes) and want to implement it in an isolated worktree with 
  full verification and automatic task tracking. The main agent acts as an
  orchestrator (Opus 4.8 by default): it reads the plan, sets up the worktree, and
  for each phase spawns ONE sub-agent — auto-selecting that sub-agent's model by
  phase complexity — to implement the phase. Each phase sub-agent runs the project's
  /verify skill and iterates on failures while warm; the orchestrator then delegates an
  independent gate-verify to its own sub-agent, observes phase sub-agents for runaway
  token burn or stuck loops, owns the pass/fail decision, and automatically checks off
  completed tasks.

  Perfect for feature implementations, refactors, and bug fixes where you need 
  quality gates, per-phase delegation, and progress visibility.
---

# Implement Plan

Turn a plan into working, verified, tested code. The main agent is the
**orchestrator**: it never writes phase code itself — it delegates each phase to a
dedicated sub-agent, watches that sub-agent, delegates the authoritative gate-verify,
and owns the pass/fail decision and task tracking.

## Roles

- **Orchestrator** (this agent, Opus 4.8 by default): pre-flight, worktree setup,
  per-phase model selection, spawning + observing sub-agents, delegating the
  authoritative gate-verify, the pass/fail decision, deep-dive escalation, checkbox
  updates, reporting. Holds all cross-phase state. Never runs `/verify` in its own
  context — it delegates it to keep its window clean.
- **Phase sub-agent** (one per phase, model auto-selected): implements exactly one
  phase's tasks inside the shared worktree, runs `/verify` and iterates on failures
  while warm (bounded), then returns a structured summary including its self-verify
  result. Does not touch the plan file or advance phases.
- **Gate-verify sub-agent** (one per phase after the phase agent returns, model by
  verify nature): runs the project's `/verify` independently of the implementer and
  returns only `pass | fail + verbatim errors`. The independent confirmation is the
  real quality gate; it writes no code and makes no decisions.

## Workflow Overview

1. **Plan Selection** — file path or inline markdown
2. **Orchestrator Model** — Opus 4.8 default (per-phase sub-agent models auto-selected)
3. **Worktree Setup** — delegate to `/create-worktree` skill
4. **Read Plan Structure**
5. **Phase-by-Phase Delegation** — one sub-agent per phase (implements + warm self-verify), observed while running
6. **Quality Verification** — two-tier: phase agent's warm self-verify, then an orchestrator-delegated independent gate-verify sub-agent
7. **Task Tracking** — check off completed phases in plan file
8. **Report** — summary, per-phase models, worktree path, status

## Step 0: Pre-Flight (MANDATORY before any implementation work)

Before reading source files, writing code, or spawning any sub-agent,
you MUST collect three answers in order:

1. Plan path/content (Step 1)
2. Orchestrator model confirmation (Step 2) — Opus 4.8 default; per-phase
   sub-agent models are auto-selected later, NOT asked here
3. Worktree decision (Step 3) — and if yes, complete `/create-worktree`
   and note the new worktree path, then proceed immediately

Do NOT begin Step 4 (Read Plan Structure) or any code reading until
Steps 1–3 are answered and the worktree (if requested) exists. Skipping
Step 3 has caused users to implement features on `main` and then
manually migrate diffs — never acceptable. Sub-agents inherit the worktree
path as their working directory, so the worktree MUST exist before any phase
is delegated.

If the user supplied a plan path as an argument, you have answered Step 1
but you have NOT answered Steps 2 and 3. Ask them now.

## Step 1: Plan Selection

Prompt user:
```
Plan file path (or paste markdown content):
```

Accept either:
- File path: `docs/plans/add-recipe-favorites.md`, `./my-plan.md`, etc.
- Inline markdown: (user pastes plan content directly)

If file path, read it. If inline, use content directly.

Then validate plan structure: must have phases (markdown sections starting with `###`) with checkboxes (`- [ ]` for incomplete, `- [x]` for complete).

## Step 2: Orchestrator Model

The orchestrator runs on **Opus 4.8 by default** — it holds cross-phase state, judges
complexity, and supervises sub-agents, which is exactly the work Opus is best at.

Confirm with the user (one line, default accepts):
```
Orchestrator model: Opus 4.8 (default). Press enter to accept, or name another.
```

Do NOT ask which model implements each phase — that is decided automatically per phase
in Step 5 by complexity classification. Store the orchestrator model for the final report.

## Step 3: Worktree Setup

Ask: "Should I create a new worktree? (y/n, default: y)"

If yes, call `/create-worktree` skill. Let the project implement worktree creation strategy (branch naming, isolation, etc.). Once the worktree is created, proceed directly to Step 4 — do NOT pause to confirm the worktree path with the user.

## Step 4: Read Plan Structure

Plans must have this structure:

```markdown
# Feature Name

## Overview
Brief description of what's being implemented.

## Phases

### Phase 1: Foundation Setup
- [ ] Task 1a: description
- [ ] Task 1b: description

### Phase 2: Core Implementation
- [ ] Task 2a: description
- [ ] Task 2b: description
- [ ] Task 2c: description

## Tests
List of expected test coverage.

## Edge Cases
Known edge cases to handle.
```

Key: Each phase is a section with checkboxes for tasks. The skill tracks and updates these.

## Step 5: Phase-by-Phase Delegation

The orchestrator delegates each phase to **one** sub-agent. Phases run **sequentially**
(later phases depend on earlier ones); the per-phase sub-agent is single, not a
parallel fan-out.

### 5a. Load architecture rules once

Before the first phase, invoke `/clean-architecture` to load the project's rules into
the orchestrator's context:

```
/clean-architecture
```

Distill the rules into a short **architecture digest** (the load-bearing constraints,
not the whole document). The orchestrator injects this digest into every sub-agent
prompt — sub-agents start cold and cannot cheaply re-derive it.

### 5b. Per-phase loop

For each phase, in order:

**1. Classify complexity → pick the sub-agent model** (auto, no user prompt). Judge
the phase's tasks and map to the Agent tool's `model` parameter:

| Phase character | Agent `model` |
|---|---|
| Mechanical/boilerplate (wiring, renames, simple CRUD, test scaffolds) | `haiku` |
| Normal feature work (typical layer impl, standard tests) | `sonnet` |
| Complex/novel (tricky algorithms, cross-cutting design, ambiguous tasks) | `opus` |

The values are the literal `model` enum tokens — pass them straight to the Agent tool.
Record the chosen model per phase for the final report.

**2. Build the handoff payload.** Sub-agents start blank, so the prompt MUST carry
everything the phase needs:

- Plan file path + the **verbatim task list for this phase only**
- Worktree path → instruct the sub-agent to `cd` into this existing worktree and do
  all work there. Do NOT use `isolation: "worktree"` — that spawns a *separate* new
  worktree per sub-agent and scatters each phase's edits, breaking carry-forward. All
  phases share the one worktree from Step 3; edits never touch `main`.
- The architecture digest from 5a — retain the non-negotiable rules (layering,
  forbidden dependencies, naming) **verbatim**; paraphrase only the soft guidance
- **Prior-phase carry-forward**: a short summary the orchestrator maintains across
  phases — files created/modified, key decisions, public interfaces introduced — so
  Phase N builds correctly on Phases 1..N-1
- Self-verify instruction: "After implementing, run /verify. If it fails, iterate to
  fix — up to <SELF_VERIFY_LIMIT, default 2> rounds — then stop regardless. Report your
  final /verify result (pass/fail) and any remaining errors verbatim."
- Explicit boundaries: "implement ONLY this phase's tasks; do NOT edit the plan file,
  do NOT start other phases. Return a structured summary."
- Required return format: files touched, what each does, decisions made, anything the
  next phase needs, your final self-verify result (pass/fail + remaining errors), and
  any tasks you could not complete.

**3. Spawn the sub-agent in the background.** Use the Agent tool with
`run_in_background: true`. This does NOT give a live token/tool feed — it buys two
things the orchestrator needs: it stays responsive instead of blocking until the phase
finishes (so it can enforce a wall-clock budget), and the sub-agent is cancellable via
`TaskStop`. The completion notification carries the sub-agent's total token count and
duration, which is the metric the ceiling check uses.

**4. Guard while running, then evaluate on return (Step 5c).** Enforce the wall-clock
budget; check the token total when the sub-agent completes.

**5. On sub-agent return**, the orchestrator (not the sub-agent):
   - Reviews the returned summary, including the phase agent's self-verify result
   - Delegates the authoritative gate-verify (Step 6) — an independent sub-agent, even
     if the phase agent self-reported pass
   - On gate pass, IMMEDIATELY checks off the phase in the plan file (Step 7) before the
     next phase. Do not batch checkbox updates — write after each phase.
   - Appends this phase's summary to the carry-forward for the next phase.

### 5c. Runaway guard

The orchestrator cannot read a running sub-agent's live token count or inspect its
individual tool calls mid-flight — a background Agent surfaces its totals only in the
completion notification. So the guard rests on two primitives that do work: a
wall-clock timeout while running, and the token total on completion.

**Wall-clock budget (while running).** Set a per-phase time budget (default 15 min;
scale up for `opus` phases). Pace check-ins with `ScheduleWakeup`. If the sub-agent is
still running past its budget, treat it as runaway: `TaskStop` it, then page the user
(below). `TaskStop` returns only status, not partial work — report what the
orchestrator last knew, not a recovered transcript.

**Token ceiling (on completion).** When the sub-agent returns, compare its reported
total tokens against the per-model ceiling in Configuration. The phase agent's total
now includes its warm self-verify loop, so the ceilings already budget for impl +
verify — don't double-count. If it overran, do NOT silently accept the result — page
the user before the gate-verify so an overrun phase gets a human look (the output may
still be fine, but the cost signal is worth a glance, and it lets you tune the ceiling).

**On either trip:**

1. **Do NOT** check off the phase, run `/verify`, or advance to the next phase.
2. Page the user via the configured notify skill (`NOTIFY_SKILL`, default `/notify-me`):
   ```
   <NOTIFY_SKILL> "implement-plan paused: Phase <N> hit <wall-clock timeout | token ceiling NNNk>. Awaiting your call: resume, re-scope, switch model, or take over."
   ```
3. Wait for the user's decision before doing anything else with this phase.

> **Note:** mid-flight repeated-call / no-progress detection is intentionally NOT
> claimed here — there is no live per-call feed for a sub-agent. The wall-clock budget
> is what catches silent loops; the token ceiling catches expensive-but-completing ones.

## Step 6: Quality Verification

Verification is **two-tier**:

1. **Warm self-verify (phase agent).** The phase sub-agent runs `/verify` itself and
   iterates on failures while it still holds full context of the code it just wrote
   (Step 5b payload). This catches most issues in-context, with no cold re-derivation,
   and is bounded by `SELF_VERIFY_LIMIT` so it can't loop forever.

2. **Authoritative gate-verify (delegated).** Self-report on one's own gate is not a
   gate — so after the phase agent returns, the **orchestrator delegates an independent
   `/verify`** to a fresh sub-agent (the implementer never confirms its own work). The
   orchestrator does NOT run `/verify` in its own context: that would pour build/test
   output into the expensive Opus window every phase. It gets back only `pass | fail +
   verbatim errors`.

**Gate-verify model** — classify like a phase (Step 5b), by what the project's `/verify`
actually does:

| `/verify` nature | gate-agent `model` |
|---|---|
| Pure pass/fail (build + tests, exit-code gate) | `haiku` |
| Behavioral (run the app, observe behavior matches intent) | `sonnet` |

Default `sonnet` (`VERIFY_AGENT_MODEL`); drop to `haiku` only when the project declares
its verify is deterministic. Spawn it with the worktree path; it writes no code and only
reports.

**Retry Logic (orchestrator-level, on gate-verify fail):**
- Gate fail → orchestrator re-delegates the fix to a phase sub-agent for the SAME phase.
  The prior edits persist on disk in the shared worktree, so instruct the retry agent to
  FIRST read the current worktree diff, then fix and re-run its warm self-verify — do not
  re-implement from scratch off the summary. Pass the verbatim gate-verify error plus the
  prior summary. Then re-spawn the gate-verify sub-agent. (The runaway guard from Step 5c
  applies to retry sub-agents too.)
- Max 3 gate attempts per phase
- 3rd gate failure → hard stop

**On Hard Stop (3x failure):**

Before paging the user, escalate to `/deep-dive` for a focused rescue attempt with a
stronger model. The deep-dive skill is the dedicated escalation path for this exact
case — one sub-agent, capped retry budget, explicit halt if it can't converge.

1. Capture the last gate-verify error output verbatim
2. **Annotate the plan with a BLOCKED marker** so the failure persists across sessions
   and is visible to anyone reading the plan. Append a callout block immediately under
   the failed phase heading:

   ```markdown
   ### Phase <N>: <name>

   > ⚠️ **BLOCKED**: 3x `/verify` failure. Deep-dive in progress.
   > **Last error:** <one-line summary of the verify error>
   > **Worktree:** <worktree path>

   - [ ] Task ...
   ```

   Write the updated plan back to disk before handoff. This way, if the session ends
   mid-rescue, the plan still reflects reality and a future run can pick up the thread.

3. Invoke `/deep-dive` with:
   - Plan file path
   - Failed phase name/section
   - Last `/verify` error output (raw)
   - Worktree path
   - Model override (default: opus)
4. Read the deep-dive result:
   - **Pass** → deep-dive will have cleared the BLOCKED callout. Check off the phase
     and continue to the next phase.
   - **Halt** (deep-dive exhausted its 3 attempts) → deep-dive will have replaced the
     BLOCKED callout with a HALTED callout. Fall through to user-wait below.

**User-Wait (deep-dive exhausted):**

1. Report what failed (deep-dive halt report already covers attempt history)
2. Call `/notify-me` with error summary:
   ```
   /notify-me "implement-plan hard stop: Phase <N> failed verification 3x and deep-dive halted. Error: <summary>"
   ```
3. Wait for user intervention — do NOT check off phase or continue
4. User fixes issue in the worktree, signals ready to retry
5. Skill resumes from the failed phase

If `/deep-dive` is not available in the project, skip directly to the user-wait path.

## Step 7: Task Tracking

When a phase passes verification, update the plan file locally:

1. Read the plan file
2. Change phase checkbox from `- [ ]` to `- [x]`
3. Write the updated plan back to the file

Then print updated plan state so user can see progress:

```
Phases completed:
✓ Phase 1: Foundation Setup
✓ Phase 2: Core Implementation
- Phase 3: Testing & Refinement (in progress)
- Phase 4: Documentation (pending)
```

The plan file is updated in your working directory — you decide what to do with it (commit, discard, etc.).

## Step 8: Final Report

Before writing the report, re-read the plan file and confirm every implemented phase shows `- [x]`. If any are still `- [ ]`, update them now (Step 7) before continuing.

Once all phases are checked off:

```markdown
# Implementation Summary

**Plan:** <plan-name>
**Orchestrator:** <orchestrator model, e.g. Opus 4.8>
**Worktree:** <path>
**Branch:** <branch-name>

## Phases Completed
- Phase 1: <description> — sub-agent: <model>
- Phase 2: <description> — sub-agent: <model>
- Phase 3: <description> — sub-agent: <model>

## Verification Status
✓ All phases passed verification

## What's Next
- Worktree is ready at <path>
- Review code and decide: merge, iterate, or cleanup
- Skill does NOT auto-merge or cleanup — that's your call
```

If hard-stopped due to failure:

```markdown
# Implementation Stopped

**Plan:** <plan-name>
**Failed Phase:** <phase-name>
**Failure Point:** 3x verification failure

## Error Summary
<error output from last /verify call>

## Recovery
- Review the error above
- Fix the issue manually in the worktree
- Signal ready to retry
- Skill will rerun verification on the failed phase
```

## Configuration

Projects can override via environment or project CLAUDE.md:

- `VERIFY_SKILL` — project's verification skill (default: `/verify`)
- `VERIFY_AGENT_MODEL` — model for the delegated gate-verify sub-agent (Step 6). Default
  `sonnet`; set `haiku` when the project's verify is a deterministic exit-code gate.
- `SELF_VERIFY_LIMIT` — max warm self-verify fix rounds inside a phase sub-agent before
  it stops and reports (Step 5b / Step 6). Default 2.
- `NOTIFY_SKILL` — notification skill (default: `/notify-me`)
- `ORCHESTRATOR_MODEL` — orchestrator model (default: Opus 4.8)
- `PHASE_TOKEN_CEILING` — per-phase sub-agent token total that triggers a user page on
  completion (Step 5c). Now budgets impl + warm self-verify together. Defaults by model:
  `haiku` 80k / `sonnet` 150k / `opus` 250k. Single source for these numbers — Step 5c
  references it.
- `PHASE_TIME_BUDGET` — per-phase wall-clock budget before the runaway guard stops the
  sub-agent (Step 5c). Default 15 min; scale up for `opus` phases.

## Plan Format Example

```markdown
# Feature: Recipe Favorites

## Overview
Add ability to mark recipes as favorites and filter by them.

## Phases

### Phase 1: Domain Layer
- [ ] Create Favorite use case in domain/favorites/
- [ ] Create FavoritesRepository interface
- [ ] Add unit tests for use case

### Phase 2: Data Layer
- [ ] Implement FavoritesRepositoryImpl
- [ ] Add Room entity and DAO
- [ ] Add data layer tests

### Phase 3: UI Layer
- [ ] Create FavoritesViewModel with UDF state
- [ ] Build Favorites Compose screens
- [ ] Add UI tests

### Phase 4: Integration
- [ ] Wire up navigation
- [ ] Integration tests across layers
- [ ] Manual testing (happy path + edge cases)

## Tests
- FavoritesUseCaseTest: ≥80% coverage
- FavoritesRepositoryImplTest: ≥80% coverage
- FavoritesViewModelTest: ≥80% coverage

## Edge Cases
- Favorite a recipe, then delete it from system
- Toggle favorite state rapidly
- Sync favorites across multiple devices (if applicable)
```

## Notes

- **Orchestrator owns state and decisions, not execution** — plan-file edits, deep-dive,
  carry-forward, and the pass/fail call live in the orchestrator. It delegates even the
  gate-verify so build/test output never enters its window. Phase sub-agents write code
  and self-verify; the gate-verify sub-agent confirms independently.
- **One sub-agent per phase, sequential** — not a parallel fan-out; later phases
  depend on earlier ones via the carry-forward summary.
- **Sub-agents are observed** — runaway token burn or silent loops pause the phase and
  page you (Step 5c) rather than burning budget unattended.
- **No auto-cleanup** — worktree stays on disk until you decide (merge, delete, etc.)
- **No auto-commit** — all code is staged/uncommitted in the worktree, ready for your review
- **User review is required** — don't merge automatically, inspect first
- **Skill failures are explicit** — hard stops make it clear when user input is needed
