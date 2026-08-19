---
name: implement-plan
description: |
  Execute a plan end-to-end with an orchestrator that delegates each phase to a
  dedicated sub-agent, plus automatic quality verification and task tracking.

  Use this skill whenever you have a structured implementation plan (markdown file
  with phases and checkboxes) and want to implement it in an isolated worktree with
  full verification and automatic task tracking. An Opus orchestrator delegates each
  phase to a model-matched sub-agent, runs two-tier verification, escalates stuck
  phases, reviews the finished diff, and opens the pull request — as a stack of PRs,
  one per dependency layer, when the plan changed a lot of production code. See the
  body for the mechanics.

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
  building the dependency-graph schedule, per-phase model selection, child-worktree
  creation + merge + cleanup, spawning + observing sub-agents (sequentially or in
  parallel groups), delegating the authoritative gate-verify, the pass/fail decision,
  escalation (forced-opus rescue pass), checkbox updates, the layer-SHA ledger, pull-request
  creation, reporting. Holds all cross-phase
  state. Never runs `/verify` in its own context — it delegates it to keep its window clean.
- **Phase sub-agent** (one per phase, model auto-selected): implements exactly one
  phase's tasks inside its assigned worktree (the shared integration worktree when run
  sequentially, or a dedicated child worktree when run in a parallel group), runs
  `/verify` and iterates on failures while warm (bounded), then returns a structured
  summary including its self-verify result. Does not touch the plan file or advance phases.
- **Prep sub-agent** (`PREP_AGENT_MODEL`, default `sonnet`): runs the one-time setup read
  the orchestrator shouldn't pull into its window — parses the plan into a verbatim
  normalized extract (Step 1). Returns load-bearing data verbatim; makes no decisions.
- **Gate-verify sub-agent** (one per phase after the phase agent returns, model by
  verify nature): runs the project's `/verify` independently of the implementer and
  returns only `pass | fail + verbatim errors`. The independent confirmation is the
  real quality gate; it writes no code and makes no decisions.
- **Review sub-agent** (Step 8, `opus`): reviews the full plan diff via the project's
  review skill and returns a structured findings list only — no code, no decisions.
- **Fix sub-agent** (Step 8, Sonnet/Haiku by complexity): applies the severity-gated
  findings in the integration worktree under the same two-tier verify contract as a phase.

## Workflow Overview

1. **Plan Selection** — file path or inline markdown; parse delegated to a cheap prep agent
2. **Orchestrator Model** — Opus 4.8 default (per-phase sub-agent models auto-selected)
3. **Worktree Setup** — delegate to `/create-worktree` skill
4. **Plan Structure** — work from the delegated parse extract
5. **Phase Delegation** — dependency-graph scheduled: independent phases run as parallel sub-agents (isolated child worktrees, merged back), dependent phases sequentially; each implements + warm self-verify, observed while running
6. **Quality Verification** — two-tier: phase agent's warm self-verify, then an orchestrator-delegated independent gate-verify sub-agent
7. **Task Tracking** — check off completed phases in plan file
8. **Plan Review & Auto-fix** — Opus sub-agent reviews the full plan diff; severity-gated findings auto-fixed by a Sonnet/Haiku sub-agent under the same two-tier verify
9. **Pull Request** — measure production churn; one draft PR, or a stack of draft PRs (one
   per dependency layer) when it exceeds `STACK_THRESHOLD_LINES`
10. **Report** — summary, per-phase models, review outcome, PR links, worktree path, status

## Step 0: Pre-Flight (MANDATORY before any implementation work)

Before reading source files, writing code, or spawning any phase/implementation
sub-agent, you MUST collect three answers in order (the Step 1 plan-parse prep agent
is part of answering #1 and is allowed):

1. Plan path/content (Step 1)
2. Orchestrator model confirmation (Step 2) — Opus 4.8 default; per-phase
   sub-agent models are auto-selected later, NOT asked here
3. Worktree decision (Step 3) — and if yes, complete `/create-worktree`
   and note the new worktree path, then proceed immediately

Do NOT begin Step 4 (Plan Structure) or any code reading until
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

**Delegate the parse — do not read the raw plan into the orchestrator window.** Spawn ONE
prep sub-agent (`PREP_AGENT_MODEL`, default `sonnet`) to read the plan (from the path, or
the inline content you pass it) and return a **verbatim normalized extract** — not a lossy
summary. The orchestrator schedules and hands off from this extract, so it must preserve the
load-bearing data exactly:

- Validate structure first: phases are `###` sections with checkboxes (`- [ ]` / `- [x]`).
  If the plan lacks this, return a structure error instead of an extract.
- For each phase, return: phase name/heading, dependency edges (from `(depends on Phase X)`
  headings and the `## Task Dependency Graph`), the `**Files**:` list, and the **verbatim
  task lines** (do not paraphrase or drop tasks).
- Also return the parallel/sequential tag per phase from the dependency graph.

Why verbatim: the orchestrator injects each phase's task list into its handoff (5a.2) and
feeds the `Files` lists into the file-overlap *safety* check (5a.1) — a lossy summary there
causes bad scheduling or worktree collisions.

**Sanity-check on return:** confirm the extract's phase count and per-phase task counts look
right (e.g. match a quick `grep -c` of `###` and `- [` in the source). On mismatch or a
structure error, fix the parse or fall back to reading the plan directly before proceeding.

## Step 2: Orchestrator Model

The orchestrator runs on **whatever model this session was launched with** — it cannot
switch its own model mid-run. `ORCHESTRATOR_MODEL` (default Opus 4.8) is the *recommended*
model because the orchestrator holds cross-phase state, judges complexity, and supervises
sub-agents, which is exactly the work Opus is best at.

Confirm with the user (one line). If the session isn't already on the recommended model,
they relaunch on it — you can't change it from here:
```
Orchestrator runs on the current session model; <ORCHESTRATOR_MODEL> recommended. To use a
different model, relaunch the session on it — I can't switch mid-run. Press enter to continue.
```

Do NOT ask which model implements each phase — that is decided automatically per phase
in Step 5 by complexity classification. Store the running model for the final report.

## Step 3: Worktree Setup

Ask: "Should I create a new worktree? (y/n, default: y)"

If yes, call `/create-worktree` skill. Let the project implement worktree creation strategy (branch naming, isolation, etc.). Once the worktree is created, proceed directly to Step 4 — do NOT pause to confirm the worktree path with the user.

## Step 4: Plan Structure

You already have the normalized extract from the delegated parse (Step 1) — work from that,
not a fresh raw read.

Each phase is a `###` section whose tasks are checkboxes (`- [ ]` / `- [x]`); the skill reads
and rewrites those boxes to track progress. Two optional-but-load-bearing extras drive later
steps: `**Files**:` per phase (the file-overlap safety check, 5a.1) and a
`## Task Dependency Graph` block (parallel scheduling).

A full worked example is in **`references/plan-format.md`** — read it when a plan doesn't
parse cleanly and you need to show the user the expected shape.

## Step 5: Phase Delegation

The orchestrator delegates each phase to a dedicated sub-agent. Phases are scheduled by
the plan's **dependency graph**, not blindly in file order: independent phases run
**concurrently**, dependent phases run **after** their prerequisites. A plan with a fully
linear dependency chain degenerates to one phase agent at a time — the old sequential
behavior, which is exactly correct for that shape.

### 5a. Schedule, handoff, and layer execution

The orchestrator parses the dependency graph into topological **layers**, builds a
cold-start handoff for each phase (model auto-selected by complexity, plus task list,
worktree path, carry-forward, and self-verify + commit instructions), then walks the layers:
single-phase layers run in the integration worktree; multi-phase layers fan out into
**sibling** child worktrees, merge back, and advance atomically.

Two rules are load-bearing and easy to get wrong:

- **File-overlap demotion** — phases that share a file (or any phase missing `**Files**:`
  metadata) are demoted out of a parallel group. A false-parallel corrupts the worktree;
  a false-sequential is merely slow.
- **Every phase commits its work** — the parallel merge and the Step 8 review diff both
  read committed history, so uncommitted work is invisible to both. The commit stays on the
  worktree/child branch; nothing is pushed until Step 9 and nothing is ever merged for you.

→ Full schedule/handoff/execution/cleanup procedure (5a.1–5a.4):
**`references/phase-execution.md`**.

### 5b. Runaway guard

Every sub-agent runs under a **wall-clock budget** (`PHASE_TIME_BUDGET`, paced with
`ScheduleWakeup` + `TaskStop`) and a **token ceiling** checked on completion
(`PHASE_TOKEN_CEILING`). On either trip, do NOT advance — page the user via `NOTIFY_SKILL`
and wait. The two primitives are all that work: a background Agent gives no live per-call
feed, only its totals in the completion notification.

→ Full procedure, resumption model, and the notify payload: **`references/runaway-guard.md`**.

## Step 6: Quality Verification

Verification is **two-tier**:

1. **Warm self-verify (phase agent).** The phase sub-agent runs `/verify` itself and
   iterates on failures while it still holds full context of the code it just wrote
   (Step 5a payload). This catches most issues in-context, with no cold re-derivation,
   and is bounded by `SELF_VERIFY_LIMIT` so it can't loop forever.

2. **Authoritative gate-verify (delegated).** Self-report on one's own gate is not a
   gate — so after the phase agent returns, the **orchestrator delegates an independent
   `/verify`** to a fresh sub-agent (the implementer never confirms its own work). The
   orchestrator does NOT run `/verify` in its own context: that would pour build/test
   output into the expensive Opus window every phase. It gets back only `pass | fail +
   verbatim errors`.

**Gate-verify model** — classify like a phase (Step 5a), by what the project's `/verify`
actually does:

| `/verify` nature | gate-agent `model` |
|---|---|
| Pure pass/fail (build + tests, exit-code gate) | `haiku` |
| Behavioral (run the app, observe behavior matches intent) | `sonnet` |

`VERIFY_AGENT_MODEL` is the configured default (`sonnet`) and wins when set; the table
above is how you pick it when the project hasn't — drop to `haiku` only when verify is a
deterministic exit-code gate. Spawn it with the worktree path; it writes no code and only
reports.

**Retry Logic (orchestrator-level, on gate-verify fail):**
- Gate fail → orchestrator re-delegates the fix to a phase sub-agent for the SAME phase.
  The prior phase work is committed (5a.2), so instruct the retry agent to FIRST read the
  committed diff plus any working changes, then fix and re-run its warm self-verify — do not
  re-implement from scratch off the summary. It commits the fix when its self-verify passes,
  same commit contract as 5a.2. Pass the verbatim gate-verify error plus the prior summary.
  Then re-spawn the gate-verify sub-agent. (The runaway guard from Step 5b applies to retry
  sub-agents too.)
- A phase gets at most `SELF_VERIFY_LIMIT` gate-verify attempts (default 2): attempt 1 is
  the initial phase agent, each subsequent attempt is one re-delegated fix. The same knob
  intentionally bounds the in-agent warm self-verify loop and these orchestrator-level gate
  retries (one budget, see Configuration) — the old fixed "3x retry" contract is retired.
- When all `SELF_VERIFY_LIMIT` attempts have failed their gate → hard stop

**On Hard Stop (`SELF_VERIFY_LIMIT` gate failures):**

Before paging the user, run a bounded **escalation pass** — the same Step 5 delegation loop
with the model forced to `opus`, an extended 5b budget (`ESCALATION_TOKEN_CEILING` /
`ESCALATION_TIME_BUDGET`), a richer payload (full failure history + "diagnose root cause
before fixing"), and capped at `ESCALATION_ATTEMPTS` (default 2). It reuses the existing
machinery, so it inherits the runaway guard automatically — not a separate skill. The plan
gets a BLOCKED marker before the pass and a HALTED marker if it exhausts; for a parallel
group the marker lands on the group's first phase heading. On exhaustion, fall through to
user-wait (page via `NOTIFY_SKILL`, do NOT check off, resume from the failed phase on the
user's signal).

→ Full escalation procedure, BLOCKED/HALTED callout formats, group-failure handling, and
the user-wait steps: **`references/escalation.md`**.

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

**Also record the layer's head SHA.** When a layer's gate-verify passes, append one line to
the **layer-SHA ledger** you hold in cross-phase state:

```
layer 2  phases: [Data, Cache]  sha: <git rev-parse HEAD in the integration worktree>
```

Step 9 hands these SHAs to `PR_SKILL` as stack cut points. They can only be captured here —
once a parallel group's merges are behind you, its commits are interleaved and the layer
boundary is gone.

The plan file is updated in the integration worktree. If Step 9 is going to run, commit it
before then (`docs: check off completed phases`) so the tree is clean and the plan's final
state ships with the PR.

## Step 8: Plan Review & Auto-fix

Run ONLY after every phase is implemented and checked off (Step 7). Skip if the plan
hard-stopped, any phase is BLOCKED/HALTED, `RUN_REVIEW=false`, or `REVIEW_SKILL` is absent.

Mirrors Step 5's delegation discipline: an **Opus** sub-agent reviews the cumulative plan
diff (`git diff <base>...HEAD`, no PR) via `REVIEW_SKILL` and returns a structured findings
list only — the orchestrator never ingests the raw diff. Findings are triaged at
`REVIEW_AUTOFIX_SEVERITY`: at/above-threshold go to a **Sonnet/Haiku** fix pass run
sequentially in the integration worktree under the same two-tier verify as a phase;
below-threshold are reported, not touched. Re-review is bounded by `REVIEW_MAX_ROUNDS`.

→ Full review/triage/fix/re-review procedure (8a–8d): **`references/review-autofix.md`**.

## Step 9: Pull Request

Runs only after Step 8 has fully settled — every review round finished, every auto-fix
committed and gate-verified. Branches cut before that would leave fix commits outside the
PRs people actually review.

**Delegate to `PR_SKILL`.** It owns measuring the branch, choosing single-PR vs stacked, and
driving `gh` — none of which is plan-execution work, and all of which a project may want to
swap out (GitLab, internal tooling, a required template).

Resolve it in this order, taking the first that exists:

1. `PR_SKILL`, when the project set it explicitly — an explicit choice outranks discovery
2. a **project-local `/create-pr`** — same convention as `/verify` and `/create-worktree`:
   the project knows its own conventions better than a generic skill does
3. `/dev-toolkit:create-pr` — the bundled implementation
4. none of the above → skip Step 9 and say so in Step 10

Judge existence from the skills available to you in this session, not from the filesystem
alone. A `.claude/skills/create-pr/SKILL.md` that was added after the session started isn't
invokable until the harness reloads, so a file on disk is not proof you can call it — if you
see the file but not the skill, say that in Step 10 rather than failing at the call.

Hand the resolved skill:

- the integration worktree path and branch
- `PR_BASE_BRANCH`
- the **layer-SHA ledger** from Step 7, oldest-first — these are its cut points, and they are
  better than anything it could derive on its own, because each one is a checkpoint that
  passed its gate-verify
- the plan path and Overview, for PR titles and bodies
- the Step 8 review outcome, which belongs in the top PR's body

`CREATE_PR` defaults to **true**, so a successful run ends with pushed branches and open draft
PRs. That is a deliberate change from this skill's earlier "nothing leaves the worktree"
contract: drafts merge nothing, and a finished branch sitting on disk is where this work used
to stall. Set `CREATE_PR=false` to end at the local branch.

Don't prompt the user mid-run about any of this — but always report the outcome in Step 10,
including which skill ran, or the reason nothing was opened. Skip when `CREATE_PR=false`,
when resolution finds nothing (name `dev-toolkit:create-pr` as the way to get one), or when
the plan hard-stopped or has BLOCKED/HALTED phases. If the ledger has fewer than two entries there is nothing to stack against; the PR
skill handles that itself and opens a single PR.

## Step 10: Final Report

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

## Review & Auto-fix
- Reviewer: Opus 4.8 on `<base>...HEAD` via <REVIEW_SKILL>
- Findings: <N total> — <M auto-fixed & verified> / <K left for you>
- Auto-fixed: <one line each, file:line + what changed> — fix sub-agent: <model>
- Left for you (below threshold): <one line each, severity + file:line + problem>
- Rounds: <R> of <REVIEW_MAX_ROUNDS>

## Pull Request
- Opened by: <resolved skill name>
- <as reported by that skill: urls, per-layer sizes, merge order>
- Review auto-fixes are in the top PR, not the layers that own the files

(or: `PR creation skipped — <reason>`)

## What's Next
- Worktree is ready at <path>
- Review the PRs and decide: merge, iterate, or cleanup
- Skill does NOT auto-merge or cleanup — that's your call
```

If hard-stopped due to failure:

```markdown
# Implementation Stopped

**Plan:** <plan-name>
**Failed Phase:** <phase-name>
**Failure Point:** verification failed every gate attempt (SELF_VERIFY_LIMIT) + escalation halted

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

- `PREP_AGENT_MODEL` — model for the delegated plan parse (Step 1). Default `sonnet` — keeps
  the raw plan out of the orchestrator's persistent window while preserving the load-bearing
  extract verbatim. (Avoid `haiku`: the extract is load-bearing and needs light judgment.)
- `VERIFY_SKILL` — project's verification skill (default: `/verify`)
- `VERIFY_AGENT_MODEL` — model for the delegated gate-verify sub-agent (Step 6). Default
  `sonnet`; set `haiku` when the project's verify is a deterministic exit-code gate.
- `SELF_VERIFY_LIMIT` — default 2. Governs **two** caps with the same value: (a) max warm
  self-verify fix rounds inside a phase sub-agent before it stops and reports (Step 5a);
  and (b) max orchestrator-level gate-verify attempts per phase before the hard stop /
  escalation pass (Step 6). One knob, both retry budgets.
- `NOTIFY_SKILL` — notification skill (default: `/notify-me`)
- `ORCHESTRATOR_MODEL` — orchestrator model (default: Opus 4.8)
- `PHASE_TOKEN_CEILING` — per-phase sub-agent token total that triggers a user page on
  completion (Step 5b). Now budgets impl + warm self-verify together. Defaults by model:
  `haiku` 80k / `sonnet` 150k / `opus` 250k. Single source for these numbers — Step 5b
  references it.
- `PHASE_TIME_BUDGET` — per-phase wall-clock budget before the runaway guard stops the
  sub-agent (Step 5b). Default 15 min; scale up for `opus` phases.
- `ESCALATION_ATTEMPTS` — max forced-`opus` rescue attempts in the Step 6 escalation pass
  before HALTED / user-wait. Default 2.
- `ESCALATION_TOKEN_CEILING` — token ceiling for an escalation attempt (Step 6), replacing
  the per-phase ceiling for the rescue. Default 400k (above the `opus` phase 250k — these
  are the hardest cases).
- `ESCALATION_TIME_BUDGET` — wall-clock budget for an escalation attempt (Step 6). Default
  30 min.
- `MAX_PARALLEL_AGENTS` — max phase sub-agents run concurrently in a parallel group
  (Step 5a.1/5a.3). Default 3; larger groups run in batches of this size.
- `RUN_REVIEW` — whether to run the post-implementation review + auto-fix step (Step 8).
  Default `true`; set `false` to stop after implementation.
- `REVIEW_SKILL` — project's code-review skill for Step 8 (default: `/code-review`). Must be
  **non-interactive**: it runs as a background sub-agent with no user present, so a skill that
  prompts mid-run (e.g. `/pr-review`, which asks which findings to keep and whether to post)
  will stall. If absent, Step 8 is skipped.
- `REVIEW_AUTOFIX_SEVERITY` — minimum finding severity that gets auto-fixed (Step 8b).
  Default: high / correctness and above; lower-severity findings are reported, not touched.
- `REVIEW_MAX_ROUNDS` — max review↔fix rounds before stopping and listing anything still
  open (Step 8d). Default 2.
- `CREATE_PR` — whether Step 9 opens PRs. Default `true`; set `false` to end at the local
  worktree branch.
- `PR_SKILL` — skill that opens the PRs (Step 9). Unset by default: Step 9 prefers a
  project-local `/create-pr`, then falls back to `/dev-toolkit:create-pr`. Set this to force
  one, e.g. on a non-GitHub host. Whichever wins owns its own knobs (`PR_BASE_BRANCH`,
  `STACK_THRESHOLD_LINES`, `PR_DRAFT`, `PR_PROD_EXCLUDES`) — they're documented there, not
  here, so there's one owner per setting.

  A project-local skill that ignores the layer ledger still works; you just get one PR
  instead of a stack. Report which skill ran, so a missing stack is traceable to the
  substitution rather than looking like a bug.

## Notes

- **Orchestrator owns state and decisions, not execution** — plan-file edits, escalation,
  carry-forward, and the pass/fail call live in the orchestrator. It delegates even the
  gate-verify so build/test output never enters its window. Phase sub-agents write code
  and self-verify; the gate-verify sub-agent confirms independently.
- **Dependency-graph scheduled** — independent phases run as parallel sub-agents in
  isolated child worktrees (merged back into integration), dependent phases run after
  their prerequisites via the carry-forward summary. A linear plan degenerates to pure
  sequential. Logical independence never overrides file-overlap: phases sharing a file
  are demoted to sequential (Step 5a.1).
- **Parallel groups advance atomically** — every member must merge cleanly AND the single
  integration gate-verify must pass before the group is checked off and advanced.
- **The orchestrator window stays lean** — the raw plan is read by a cheap prep agent
  (`PREP_AGENT_MODEL`), which returns a verbatim extract; the orchestrator never holds the
  raw source, so it doesn't get re-processed every turn.
- **Sub-agents are observed** — runaway token burn or silent loops pause the phase and
  page you (Step 5b) rather than burning budget unattended.
- **Review is a capstone, not a phase gate** — after all phases pass, an Opus sub-agent
  reviews the whole plan diff; only severity-gated findings are auto-fixed (Sonnet/Haiku),
  the rest are reported for you. Bounded by `REVIEW_MAX_ROUNDS`; disable with `RUN_REVIEW`.
- **Child worktrees are auto-cleaned, integration is not** — ephemeral child worktrees
  and branches are removed after their group's gate-verify passes (Step 5a.4); the
  integration worktree stays on disk until you decide (merge, delete, etc.).
- **Phases commit locally; only Step 9 pushes** — each phase commits its own work (required
  so the parallel merge and the Step 8 review diff can see it; see 5a.2). Nothing leaves the
  machine until Step 9, which delegates to `PR_SKILL` to push the branches and open **draft**
  PRs. Nothing is ever merged for you.
- **Big changes ship as a stack** — `PR_SKILL` splits a branch that changed a lot of
  production code into one draft PR per dependency layer, so each is reviewable on its own.
  The cut points come from the SHA ledger recorded during Step 7; they cannot be
  reconstructed afterwards, which is why the ledger is written as layers pass rather than
  computed at the end.
- **User review is required** — don't merge automatically, inspect first
- **Skill failures are explicit** — hard stops make it clear when user input is needed
