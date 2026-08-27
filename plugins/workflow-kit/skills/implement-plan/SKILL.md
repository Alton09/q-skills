---
name: implement-plan
description: |
  Execute a plan end-to-end with an orchestrator that delegates each phase to a
  dedicated sub-agent, plus automatic quality verification and task tracking.

  Use this skill whenever you have a structured implementation plan (markdown file
  with phases and checkboxes) and want to implement it in an isolated worktree with
  full verification and automatic task tracking. A deep-tier orchestrator delegates
  each phase to a tier-matched sub-agent, runs two-tier verification, escalates stuck
  phases, reviews the finished diff, and opens a draft PR via the project's
  `/create-pr` (when one exists) — see the body for the mechanics. It is
  host-neutral: the harness is detected at Step 0.5 and every capability and model
  is bound from `references/runtimes.md` and `references/model-routing.md`.

  Perfect for feature implementations, refactors, and bug fixes where you need
  quality gates, per-phase delegation, and progress visibility.
---

# Implement Plan

Turn a plan into working, verified, tested code. The main agent is the
**orchestrator**: it never writes phase code itself — it delegates each phase to a
dedicated sub-agent, watches that sub-agent, delegates the authoritative gate-verify,
and owns the pass/fail decision and task tracking.

The workflow is written in **model tiers** (`light` / `standard` / `deep`) and
**capability names** (`SPAWN_WORKER`, `STOP_WORKER`, `PACE`, `TOKEN_ACCOUNTING`,
`VERIFY`, `WORKTREE_CREATE`, `NOTIFY`, `REVIEW`, `PATH_SCOPE`). It names no harness, tool, or model
id. Step 0.5 binds both vocabularies to the detected host:

- **`references/runtimes.md`** — capability bindings per host, host detection, disclosure wiring.
- **`references/model-routing.md`** — tier → model per role per host, family groupings, the
  diversity rule, the escalation ladder, and the config surface.

## Roles

- **Orchestrator** (this agent, **deep** tier by default): pre-flight, runtime detection,
  worktree setup, building the dependency-graph schedule, per-phase tier selection,
  child-worktree creation + merge + cleanup, spawning + observing sub-agents (sequentially or
  in parallel groups), delegating the authoritative gate-verify, the pass/fail decision,
  escalation (deep-tier, family-switch rescue pass), checkbox updates, reporting. Holds all
  cross-phase state. Never runs `/verify` in its own context — it delegates it to keep its
  window clean.
- **Phase sub-agent** (one per phase, tier auto-selected): implements exactly one
  phase's tasks inside its assigned worktree (the shared integration worktree when run
  sequentially, or a dedicated child worktree when run in a parallel group), runs
  `/verify` and iterates on failures while warm (bounded), then returns a structured
  summary including its self-verify result. Does not touch the plan file or advance phases.
- **Prep sub-agent** (`PREP_MODEL`, **standard** tier): runs the one-time setup read
  the orchestrator shouldn't pull into its window — parses the plan into a verbatim
  normalized extract (Step 1). Returns load-bearing data verbatim; makes no decisions.
- **Gate-verify sub-agent** (one per phase after the phase agent returns, tier by
  verify nature): runs the project's `/verify` independently of the implementer and
  returns only `pass | fail + verbatim errors`. The independent confirmation is the
  real quality gate; it writes no code and makes no decisions.
- **Review sub-agent** (Step 8, **deep** tier): reviews the full plan diff via the project's
  review skill and returns a structured findings list only — no code, no decisions.
- **Fix sub-agent** (Step 8, **standard** tier — **light** for mechanical findings): applies
  the severity-gated findings in the integration worktree under the same two-tier verify
  contract as a phase.

## Workflow Overview

Step 0.5 (runtime detection) runs before everything below — see Step 0.

1. **Plan Selection** — file path or inline markdown; parse delegated to a cheap prep agent
2. **Runtime & Model Disclosure** — host, per-role tiers/models, and degraded capabilities
   disclosed; orchestrator runs on the session model (deep tier recommended, per-phase
   sub-agent tiers auto-selected)
3. **Worktree Setup** — delegate to `/create-worktree` skill (`WORKTREE_CREATE`)
4. **Plan Structure** — work from the delegated parse extract
5. **Phase Delegation** — dependency-graph scheduled: independent phases run as parallel sub-agents (isolated child worktrees, merged back), dependent phases sequentially; each implements + warm self-verify, observed while running
6. **Quality Verification** — two-tier: phase agent's warm self-verify, then an orchestrator-delegated independent gate-verify sub-agent
7. **Task Tracking** — check off completed phases in the integration worktree's copy of the plan file
8. **Plan Review & Auto-fix** — a deep-tier sub-agent reviews the full plan diff; severity-gated findings auto-fixed by a standard-tier sub-agent under the same two-tier verify
9. **Pull Request** — delegate to the project's `/create-pr` skill, if it exists
10. **Report** — summary, per-phase tiers/models, runtime & degradations, review outcome, PR link, worktree path, status

## Step 0: Pre-Flight (MANDATORY before any implementation work)

Before reading source files, writing code, or spawning any phase/implementation
sub-agent, you MUST resolve the runtime (Step 0.5) and then collect three answers in
order (the Step 1 plan-parse prep agent is part of answering #1 and is allowed):

0. Runtime resolved (Step 0.5) — host detected, capability bindings and per-role model
   map loaded, degradations noted
1. Plan path/content (Step 1)
2. Runtime & model disclosure + orchestrator confirmation (Step 2) — deep tier
   recommended; per-phase sub-agent tiers are auto-selected later, NOT asked here
3. Worktree decision (Step 3) — and if yes, complete `/create-worktree`
   and note the new worktree path, then proceed immediately

Do NOT begin Step 4 (Plan Structure) or any code reading until
Steps 0.5–3 are answered and the worktree (if requested) exists. Skipping
Step 3 has caused users to implement features on `main` and then
manually migrate diffs — never acceptable. Sub-agents inherit the worktree
path as their working directory, so the worktree MUST exist before any phase
is delegated.

If the user supplied a plan path as an argument, you have answered Step 1
but you have NOT answered Steps 2 and 3. Ask them now.

## Step 0.5: Runtime Detection (MANDATORY — first thing in the run)

Nothing else happens until the host is resolved and its bindings are loaded. Do not read
source, write code, or spawn any sub-agent before this completes.

1. **Detect the host.** Follow *Host Detection* in **`references/runtimes.md`**: the
   `HOST_RUNTIME` env var wins when set to a known host; otherwise inspect the available
   toolset. An unknown `HOST_RUNTIME` value, an ambiguous toolset, or a host with no column
   in the binding table is a **hard error** — halt with the exact message that file
   specifies. Never guess: a silent mismatch costs more than a user restart.
2. **Load the capability bindings** for the detected host — `SPAWN_WORKER`, `STOP_WORKER`,
   `PACE`, `TOKEN_ACCOUNTING`, `VERIFY`, `WORKTREE_CREATE`, `NOTIFY`, `REVIEW`,
   `PATH_SCOPE`. Every capability this workflow calls by name is bound in that table.
3. **Load the per-role model map** for the detected host from
   **`references/model-routing.md`**, applying any config overrides (see Configuration).
   **Unknown model ids halt loudly and are never substituted** — emit the unknown id, the
   role it was assigned to, and the host, then stop.
4. **Note every degradation.** Each `unavailable → consequence` cell in the host's column is
   a degradation: record it for the Step 2 disclosure and the final report. Degraded
   capabilities are **disclosed, never simulated**.
5. **Check the path-scope precondition.** Where the host's `PATH_SCOPE` is restricted to a
   session root, confirm that root contains the **parent of the project repository** — the
   directory that will hold the integration worktree and every child worktree as siblings.
   If it does not, **halt** with the exact message in *Session Root Constraint*
   (`references/runtimes.md`). This is checked here, before any worker exists, because on
   such a host a worker pointed outside the root hangs forever with no error, no timeout and
   no way to cancel it — the failure is undetectable once it has happened. Resolve the
   project repository from the session's working directory, or from the plan path once
   Step 1 supplies it; if it cannot be resolved yet, carry the check to Step 3 and run it
   there. Either way it MUST pass before any worktree is created or any worker is spawned.
   Hosts with an unrestricted `PATH_SCOPE` skip this check.

## Step 1: Plan Selection

Prompt user:
```
Plan file path (or paste markdown content):
```

Accept either:
- File path: `docs/plans/add-recipe-favorites.md`, `./my-plan.md`, etc.
- Inline markdown: (user pastes plan content directly)

**Delegate the parse — do not read the raw plan into the orchestrator window.** Spawn ONE
prep sub-agent (`SPAWN_WORKER`, `PREP_MODEL`, standard tier) to read the plan (from the path,
or the inline content you pass it) and return a **verbatim normalized extract** — not a lossy
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

## Step 2: Runtime & Model Disclosure

Disclose what this run is about to do — host, per-role models, and anything degraded on this
host — **before any work starts**, then confirm the orchestrator model in the same beat.

Emit the disclosure block (content from Step 0.5; format per *Disclosure Requirement Wiring*
in `references/runtimes.md`):

```
Runtime: <host>
Models: <role> → <tier> / <model>, …   (one line per role, from model-routing.md)
Session root: <path>                   (restricted-`PATH_SCOPE` hosts only; verified at Step 0.5)
Degraded capabilities on this host:
  - <capability>: <consequence>        (one line per unavailable cell)
  (none)                               ← if all capabilities are available
```

The orchestrator runs on **whatever model this session was launched with** — it cannot
switch its own model mid-run. `ORCHESTRATOR_MODEL` (the host's **deep** tier) is the
*recommended* model because the orchestrator holds cross-phase state, judges complexity, and
supervises sub-agents, which is exactly the work the deep tier is for.

Confirm with the user (one line). If the session isn't already on the recommended model,
they relaunch on it — you can't change it from here:
```
Orchestrator runs on the current session model; <ORCHESTRATOR_MODEL> recommended. To use a
different model, relaunch the session on it — I can't switch mid-run. Press enter to continue.
```

Do NOT ask which model implements each phase — that is decided automatically per phase
in Step 5 by complexity classification. Store the running model, the host, and the
degradation list for the final report.

## Step 3: Worktree Setup

Ask: "Should I create a new worktree? (y/n, default: y)"

If yes, call `/create-worktree` skill (`WORKTREE_CREATE`). Let the project implement worktree creation strategy (branch naming, isolation, etc.). Once the worktree is created, proceed directly to Step 4 — do NOT pause to confirm the worktree path with the user.

Worktree **placement** is host-independent: the integration worktree is a sibling of the
project repository, and parallel-group child worktrees are siblings of the integration
worktree (`references/phase-execution.md` 5a.2). That does not change to suit a host — where
the host's `PATH_SCOPE` is restricted, the *session root* is what must contain them all.
Run the Step 0.5 path-scope check now if it was deferred (the project repo is unambiguous by
this point), and after `/create-worktree` returns, confirm the worktree it created is inside
that root. If it is not, halt and report it rather than pointing a worker at it.

## Step 4: Plan Structure

You already have the normalized extract from the delegated parse (Step 1) — work from that,
not a fresh raw read. This is the structure the prep agent parsed:

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

## Step 5: Phase Delegation

The orchestrator delegates each phase to a dedicated sub-agent (`SPAWN_WORKER`). Phases are
scheduled by the plan's **dependency graph**, not blindly in file order: independent phases
run **concurrently**, dependent phases run **after** their prerequisites. A plan with a fully
linear dependency chain degenerates to one phase agent at a time — the old sequential
behavior, which is exactly correct for that shape.

### 5a. Schedule, handoff, and layer execution

The orchestrator parses the dependency graph into topological **layers**, builds a
cold-start handoff for each phase (**tier** auto-selected by complexity — `light` /
`standard` / `deep`, 5a.2 — plus task list, worktree path, carry-forward, and self-verify +
commit instructions), then walks the layers: single-phase layers run in the integration
worktree; multi-phase layers fan out into **sibling** child worktrees, merge back, and
advance atomically.

Two rules are load-bearing and easy to get wrong:

- **File-overlap demotion** — phases that share a file (or any phase missing `**Files**:`
  metadata) are demoted out of a parallel group. A false-parallel corrupts the worktree;
  a false-sequential is merely slow.
- **Every phase commits its work** — the parallel merge and the Step 8 review diff both
  read committed history, so uncommitted work is invisible to both. The commit stays on the
  worktree/child branch; nothing is pushed or merged to `main`.

**Parallelism is capability-gated.** `PACE` covers both concurrent execution and
*backgrounding* (control returning mid-flight so the 5b guard can watch a running worker).
Where either half is unavailable on the host, every parallel group demotes to sequential — one phase at a time — regardless of declared
independence. The dependency graph is still computed and respected, and the worktree
ownership contract is unchanged; the demotion is disclosed at Step 2.

→ Full schedule/handoff/execution/cleanup procedure (5a.1–5a.4):
**`references/phase-execution.md`**.

### 5b. Runaway guard

Every sub-agent runs under a **wall-clock budget** (`PHASE_TIME_BUDGET`, paced with
`PACE` + `STOP_WORKER`) and a **token ceiling** checked on completion
(`PHASE_TOKEN_CEILING`, read via `TOKEN_ACCOUNTING`). On either trip, do NOT advance — page
the user via `NOTIFY_SKILL` (`NOTIFY`) and wait. The two primitives are all that work: a
backgrounded `SPAWN_WORKER` gives no live per-call feed, only its totals in the completion
notification.

Where `STOP_WORKER` is unavailable on the host, the guard is honestly weaker — post-hoc
token ceiling only, so a runaway sub-agent burns to completion before the ceiling stops it
from continuing. That is disclosed at Step 2, never papered over. Where `TOKEN_ACCOUNTING`
is unavailable, say so in the report instead of inventing totals.

→ Full procedure, resumption model, and the notify payload: **`references/runaway-guard.md`**.

## Step 6: Quality Verification

Verification is **two-tier**:

1. **Warm self-verify (phase agent).** The phase sub-agent runs `/verify` (`VERIFY`) itself
   and iterates on failures while it still holds full context of the code it just wrote
   (Step 5a payload). This catches most issues in-context, with no cold re-derivation,
   and is bounded by `SELF_VERIFY_LIMIT` so it can't loop forever.

2. **Authoritative gate-verify (delegated).** Self-report on one's own gate is not a
   gate — so after the phase agent returns, the **orchestrator delegates an independent
   `/verify`** to a fresh sub-agent (the implementer never confirms its own work). The
   orchestrator does NOT run `/verify` in its own context: that would pour build/test
   output into the orchestrator's deep-tier window every phase. It gets back only
   `pass | fail + verbatim errors`.

**Gate-verify tier** — classify like a phase (Step 5a), by what the project's `/verify`
actually does:

| `/verify` nature | gate-agent tier |
|---|---|
| Pure pass/fail (build + tests, exit-code gate) | `light` |
| Behavioral (run the app, observe behavior matches intent) | `standard` |

`VERIFY_MODEL` is the configured default (the host's **standard** tier) and wins when set;
the table above is how you pick it when the project hasn't — drop to `light` only when
verify is a deterministic exit-code gate. Where the host's catalog has more than one model
family, resolve the model within the tier by the **diversity rule** in
`references/model-routing.md` (the gate never comes from the implementer's family). Spawn it
with the worktree path; it writes no code and only reports.

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

Before paging the user, run a bounded **escalation pass** — rung 1 of the ladder in
`references/model-routing.md`: the same Step 5 delegation loop run at the **deep tier with a
family switch** away from the implementer that failed (on a single-family host the switch is
a no-op and rung 1 is a deep-tier re-run), an extended 5b budget
(`ESCALATION_TOKEN_CEILING` / `ESCALATION_TIME_BUDGET`), a richer payload (full failure
history + "diagnose root cause before fixing"), and capped at `ESCALATION_ATTEMPTS`
(default 2). It reuses the existing machinery, so it inherits the runaway guard
automatically — not a separate skill. The plan gets a BLOCKED marker before the pass and a
HALTED marker if it exhausts; for a parallel group the marker lands on the group's first
phase heading. On exhaustion, rung 2 is **manual**: fall through to user-wait (page via
`NOTIFY_SKILL`, do NOT check off, resume from the failed phase on the user's signal). On a
host other than Claude Code, the HALTED report additionally carries the rung-2
**"Resume in Claude Code"** block — worktree path, failed phase, models/families already
run, and the relaunch instruction.

→ Full escalation procedure, BLOCKED/HALTED callout formats, group-failure handling, and
the user-wait steps: **`references/escalation.md`**.

## Step 7: Task Tracking

When a phase passes verification, update the plan file:

1. Read the plan file **in the integration worktree** (Step 3) — not the copy in the
   original checkout
2. Change phase checkbox from `- [ ]` to `- [x]`
3. Write the updated plan back to that same file

Then print updated plan state so user can see progress:

```
Phases completed:
✓ Phase 1: Foundation Setup
✓ Phase 2: Core Implementation
- Phase 3: Testing & Refinement (in progress)
- Phase 4: Documentation (pending)
```

**Which copy (normative, every host).** With an integration worktree there are always two
copies of the plan. Every plan-state update this skill makes — phase checkboxes, the BLOCKED
callout, and the HALTED callout with its rung-2 rescue block
(`references/escalation.md`) — lands in the **integration worktree's copy**, and only there.
Never the original checkout's copy. That worktree copy is the file the rescue block tells the
user to open and the file a resuming session reads, so a marker written anywhere else leaves
the resume target with no record of the failure it is being asked to resume from. If the plan
path you were given points outside the worktree, resolve it to the same relative path inside
the worktree before writing. The worktree copy is yours to commit or leave dirty — but it is
the copy that gets written.

## Step 8: Plan Review & Auto-fix

Run ONLY after every phase is implemented and checked off (Step 7). Skip if the plan
hard-stopped, any phase is BLOCKED/HALTED, `RUN_REVIEW=false`, or `REVIEW_SKILL` is absent.

Mirrors Step 5's delegation discipline: a **deep-tier** sub-agent (`REVIEW`) reviews the
cumulative plan diff (`git diff <base>...HEAD`, no PR) via `REVIEW_SKILL` and returns a
structured findings list only — the orchestrator never ingests the raw diff. The reviewer
follows the same **diversity rule** as the gate where the host's catalog allows it. Findings
are triaged at `REVIEW_AUTOFIX_SEVERITY`: at/above-threshold go to a **standard-tier** fix
pass (`light` for mechanical findings) run sequentially in the integration worktree under the
same two-tier verify as a phase; below-threshold are reported, not touched. Re-review is
bounded by `REVIEW_MAX_ROUNDS`.

→ Full review/triage/fix/re-review procedure (8a–8d): **`references/review-autofix.md`**.

## Step 9: Pull Request

Runs only after Step 8 has fully settled — every review round finished, every auto-fix
committed and gate-verified. If the project provides a `/create-pr` skill and `CREATE_PR`
is not `false`, invoke it from the integration worktree, passing the branch, and let it own
everything else — push, title, body, templates, host tooling. PR conventions vary too much
between projects for this skill to bundle an implementation.

Expectations on the project's `/create-pr`: open a **draft** PR, never merge anything, run
without prompting (Step 9 is unattended), and return the PR URL for the report. If no
`/create-pr` skill exists in the session, skip this step and say so in the report — the run
ends at the local worktree branch, as before.

## Step 10: Final Report

Before writing the report, re-read the plan file **in the integration worktree** (the copy Step 7 writes, and the only copy that carries this run's state) and confirm every implemented phase shows `- [x]`. If any are still `- [ ]`, update them now (Step 7) before continuing.

The `Runtime & Models` section below is mandatory — it is the section
`references/runtimes.md` specifies for the final report. Two rules govern its contents, and
both have been violated in practice:

- **Models: report what actually ran.** Every model id in that section comes from the
  orchestrator's own spawn records (the tier + model it recorded per phase at 5a.2) and,
  where the host exposes it, from `TOKEN_ACCOUNTING`. Never transcribe
  `references/model-routing.md`: that table is the *configured* default, and a report that
  echoes it can never reveal an override or a substitution — the only case where the audit
  matters. Where actual and configured differ, print both:
  `Phase 3 (light): <actual> (configured: <routed>)`. Where the actual model cannot be
  recovered, print `unknown (configured: <model-id>)` — never fill the gap from the table.
- **Cost: measured or absent, never estimated.** The `Cost:` figure comes from
  `TOKEN_ACCOUNTING` for this run and from nothing else. Unavailable → emit
  `"token accounting unavailable on this host"` with no number. Partial → report the
  measured part, say what it covers, and state that the rest is unmeasured. Do not derive a
  figure from token counts, model prices, elapsed time, or a previous run. An estimated
  spend figure has been wrong by 13x in practice; no number is better than a wrong one.

Once all phases are checked off:

```markdown
# Implementation Summary

**Plan:** <plan-name>
**Orchestrator:** <tier> / <model>
**Worktree:** <path>
**Branch:** <branch-name>
**PR:** <url, or `skipped — <reason>`>

## Phases Completed
- Phase 1: <description> — sub-agent: <tier> / <model>
- Phase 2: <description> — sub-agent: <tier> / <model>
- Phase 3: <description> — sub-agent: <tier> / <model>

## Verification Status
✓ All phases passed verification

## Runtime & Models

Host: <host>
Orchestrator: <model-id>
Per-phase models:
  Phase <N> (<tier>): <model-id actually used> [ (configured: <routed-model-id>) if different ]
  …
Gate-verify: <model-id actually used>
Review: <model-id actually used>
Degradations active: <list from Step 2, or "none">
Cost: <read from TOKEN_ACCOUNTING for this run — metered spend on a metered host, or the
flat-rate equivalent-consumed note on a flat-rate host, per `references/runtimes.md`; emit
"token accounting unavailable on this host" when `TOKEN_ACCOUNTING` is unavailable. Never
estimated>

## Review & Auto-fix
- Reviewer: <tier> / <model> on `<base>...HEAD` via <REVIEW_SKILL>
- Findings: <N total> — <M auto-fixed & verified> / <K left for you>
- Auto-fixed: <one line each, file:line + what changed> — fix sub-agent: <tier> / <model>
- Left for you (below threshold): <one line each, severity + file:line + problem>
- Rounds: <R> of <REVIEW_MAX_ROUNDS>

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

Projects can override via environment or the project's agent config file (`CLAUDE.md`,
`AGENTS.md`, or the host's equivalent):

**Runtime**

- `HOST_RUNTIME` — explicit host override for Step 0.5 detection. When unset, the host is
  detected from the toolset. An unknown value, an ambiguous toolset, or a host with no
  column in `references/runtimes.md` halts the run.

**Models** — every default below resolves through the detected host's column in
`references/model-routing.md`. **Unknown model ids halt loudly and are never substituted.**

- `ORCHESTRATOR_MODEL` — orchestrator model (default: the host's **deep** tier)
- `PREP_MODEL` — model for the delegated plan parse (Step 1). Default: the host's
  **standard** tier — keeps the raw plan out of the orchestrator's persistent window while
  preserving the load-bearing extract verbatim. (Avoid the `light` tier: the extract is
  load-bearing and needs light judgment.)
- `PHASE_MODEL_LIGHT` / `PHASE_MODEL_STANDARD` / `PHASE_MODEL_DEEP` — per-tier phase
  sub-agent models (Step 5a.2), one per complexity class.
- `VERIFY_MODEL` — model for the delegated gate-verify sub-agent (Step 6). Default: the
  host's **standard** tier; drop to the **light** tier when the project's verify is a
  deterministic exit-code gate.
- `REVIEW_MODEL` — review sub-agent model (Step 8). Default: the host's **deep** tier.
- `FIX_MODEL` — auto-fix sub-agent model (Step 8b). Default: the host's **standard** tier.
- `ESCALATION_LADDER` — rung-1 escalation model(s) (Step 6). Default: the **deep** tier with
  a family switch away from the implementer that failed.
- *Deprecated aliases* — `PREP_AGENT_MODEL` → `PREP_MODEL`, `VERIFY_AGENT_MODEL` →
  `VERIFY_MODEL`. Still accepted; they emit a deprecation warning on load and are removed in
  a future major version.

**Skills**

- `VERIFY_SKILL` — project's verification skill (default: `/verify`)
- `NOTIFY_SKILL` — notification skill (default: `/notify-me`)
- `REVIEW_SKILL` — project's code-review skill for Step 8 (default: `/code-review`). Must be
  **non-interactive**: it runs as a background sub-agent with no user present, so a skill that
  prompts mid-run (e.g. `/pr-review`, which asks which findings to keep and whether to post)
  will stall. If absent, Step 8 is skipped.

**Budgets and gates**

- `SELF_VERIFY_LIMIT` — default 2. Governs **two** caps with the same value: (a) max warm
  self-verify fix rounds inside a phase sub-agent before it stops and reports (Step 5a);
  and (b) max orchestrator-level gate-verify attempts per phase before the hard stop /
  escalation pass (Step 6). One knob, both retry budgets.
- `PHASE_TOKEN_CEILING` — per-phase sub-agent token total that triggers a user page on
  completion (Step 5b). Now budgets impl + warm self-verify together. Defaults by tier:
  `light` 80k / `standard` 150k / `deep` 250k. Single source for these numbers — Step 5b
  references it.
- `PHASE_TIME_BUDGET` — per-phase wall-clock budget before the runaway guard stops the
  sub-agent (Step 5b). Default 15 min; scale up for `deep`-tier phases.
- `ESCALATION_ATTEMPTS` — max rung-1 rescue attempts in the Step 6 escalation pass
  before HALTED / user-wait. Default 2.
- `ESCALATION_TOKEN_CEILING` — token ceiling for an escalation attempt (Step 6), replacing
  the per-phase ceiling for the rescue. Default 400k (above the `deep`-tier phase 250k —
  these are the hardest cases).
- `ESCALATION_TIME_BUDGET` — wall-clock budget for an escalation attempt (Step 6). Default
  30 min.
- `MAX_PARALLEL_AGENTS` — max phase sub-agents run concurrently in a parallel group
  (Step 5a.1/5a.3). Default 3; larger groups run in batches of this size. Has no effect on a
  host whose `PACE` capability is unavailable — those runs are sequential.
- `RUN_REVIEW` — whether to run the post-implementation review + auto-fix step (Step 8).
  Default `true`; set `false` to stop after implementation.
- `REVIEW_AUTOFIX_SEVERITY` — minimum finding severity that gets auto-fixed (Step 8b).
  Default: high / correctness and above; lower-severity findings are reported, not touched.
- `REVIEW_MAX_ROUNDS` — max review↔fix rounds before stopping and listing anything still
  open (Step 8d). Default 2.
- `CREATE_PR` — whether Step 9 delegates to the project's `/create-pr` skill. Default `true`;
  set `false` to end the run at the local worktree branch. Has no effect when the project has
  no `/create-pr` — the step is skipped either way.

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

- **The workflow is host-neutral** — tiers and capability names in this file, bindings in
  `references/runtimes.md` and `references/model-routing.md`. Adding a harness adds columns
  there and never touches this file.
- **Degraded capabilities are disclosed, never simulated** — anything a host can't do is
  named at Step 2 before work starts and repeated in the final report.
- **Orchestrator owns state and decisions, not execution** — plan-file edits, escalation,
  carry-forward, and the pass/fail call live in the orchestrator. It delegates even the
  gate-verify so build/test output never enters its window. Phase sub-agents write code
  and self-verify; the gate-verify sub-agent confirms independently.
- **Dependency-graph scheduled** — independent phases run as parallel sub-agents in
  isolated child worktrees (merged back into integration), dependent phases run after
  their prerequisites via the carry-forward summary. A linear plan degenerates to pure
  sequential. Logical independence never overrides file-overlap: phases sharing a file
  are demoted to sequential (Step 5a.1). Where the host lacks either half of `PACE` —
  concurrent execution, or backgrounding to supervise it — every group is.
- **Parallel groups advance atomically** — every member must merge cleanly AND the single
  integration gate-verify must pass before the group is checked off and advanced.
- **The orchestrator window stays lean** — the raw plan is read by a cheap prep agent
  (`PREP_MODEL`), which returns a verbatim extract; the orchestrator never holds the
  raw source, so it doesn't get re-processed every turn.
- **Sub-agents are observed** — runaway token burn or silent loops pause the phase and
  page you (Step 5b) rather than burning budget unattended.
- **Review is a capstone, not a phase gate** — after all phases pass, a deep-tier sub-agent
  reviews the whole plan diff; only severity-gated findings are auto-fixed (standard tier),
  the rest are reported for you. Bounded by `REVIEW_MAX_ROUNDS`; disable with `RUN_REVIEW`.
- **Child worktrees are auto-cleaned, integration is not** — ephemeral child worktrees
  and branches are removed after their group's gate-verify passes (Step 5a.4); the
  integration worktree stays on disk until you decide (merge, delete, etc.).
- **Phases commit, but only to the worktree branch** — each phase commits its own work
  (required so the parallel merge and the Step 8 review diff can see it; see 5a.2). Those
  commits stay on the integration/child branch in the worktree — nothing is merged for you.
  Only Step 9's delegated `/create-pr` pushes the branch, and only to open a draft PR. The
  branch is yours to review, squash, merge, or discard.
- **User review is required** — don't merge automatically, inspect first
- **Skill failures are explicit** — hard stops make it clear when user input is needed
