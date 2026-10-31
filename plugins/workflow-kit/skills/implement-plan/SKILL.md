---
name: implement-plan
description: |
  Execute a plan end-to-end with an orchestrator that delegates each phase to a
  dedicated sub-agent, plus automatic quality verification and task tracking.

  Use this skill whenever you have a structured implementation plan (markdown file
  with phases and checkboxes) and want to implement it in an isolated worktree with
  full verification and automatic task tracking. An Opus orchestrator delegates each
  phase to a model-matched sub-agent, runs two-tier verification, escalates stuck
  phases, reviews the finished diff, and opens a draft PR via the project's
  `/create-pr` (when one exists) — see the body for the mechanics.

  Perfect for feature implementations, refactors, and bug fixes where you need
  quality gates, per-phase delegation, and progress visibility.
---

# Implement Plan

Turn a plan into working, verified, tested code. The main agent is the
**orchestrator**: it never writes phase code itself — it delegates each phase to a
dedicated sub-agent, watches that sub-agent, delegates the authoritative gate-verify,
and owns the pass/fail decision and task tracking.

## Invocation

`/workflow-kit:implement-plan <plan path> [--worker]`

Parse the optional `--worker` flag. Use the plan filename stem as `<plan-key>`. With
`--worker`, a plan path is required; inline markdown is not accepted. Without `--worker`,
follow the existing flow.

## Roles

- **Orchestrator** (this agent, opus by default): pre-flight, worktree setup,
  building the dependency-graph schedule, per-phase model selection, child-worktree
  creation + merge + cleanup, spawning + observing sub-agents (sequentially or in
  parallel groups), delegating the authoritative gate-verify, the pass/fail decision,
  escalation (forced-opus rescue pass), checkbox updates, reporting. Holds all cross-phase
  state. Never runs `/verify` in its own context — it delegates it to keep its window clean.
- **Phase sub-agent** (one per phase, model auto-selected): implements exactly one
  phase's tasks inside its assigned worktree (the shared integration worktree when run
  sequentially, or a dedicated child worktree when run in a parallel group), runs
  `/verify` and iterates on failures while warm (bounded), then returns a structured
  summary including its self-verify result. Does not touch the plan file or advance phases.
- **Prep sub-agent** (routed `routing.prep` target, default `claude:sonnet`): runs the one-time setup read
  the orchestrator shouldn't pull into its window — parses the plan into a verbatim
  normalized extract (Step 1). Returns load-bearing data verbatim; makes no decisions.
- **Gate-verify sub-agent** (one per phase after the phase agent returns, model by
  verify nature): runs the project's `/verify` independently of the implementer and
  returns only `pass | fail + verbatim errors`. The independent confirmation is the
  real quality gate; it writes no code and makes no decisions.
- **Review sub-agent** (Step 8, routed `routing.review` target): reviews the full plan diff
  via the project's review skill and returns a structured findings list only — no code, no
  decisions.
- **E2E sub-agent** (Step 8, routed `routing.e2e` target): runs the project's `/e2e`
  skill against the integration worktree and returns the `references/e2e.md` verdict. It
  writes no code.
- **Fix sub-agent** (Step 8, light/standard phase tier by complexity): applies the severity-gated
  findings in the integration worktree under the same two-tier verify contract as a phase.

Prep, phase, fix, gate-verify, review, and E2E targets come from the router, which reads the
`routing` lists in `workflow-kit.json` (`references/routing.md`). Only the escalation rescue
is forced to `claude:opus`.

## Workflow Overview

1. **Plan Selection** — file path or inline markdown; parse delegated to a cheap prep agent
2. **Orchestrator Model** — opus default (per-phase sub-agent models auto-selected)
3. **Worktree Setup** — delegate to `/create-worktree` skill
4. **Plan Structure** — work from the delegated parse extract
5. **Phase Delegation** — dependency-graph scheduled: independent phases run as parallel sub-agents (isolated child worktrees, merged back), dependent phases sequentially; each implements + warm self-verify, observed while running; worker targets come from the router
6. **Quality Verification** — two-tier: phase agent's warm self-verify, then an orchestrator-delegated independent gate-verify sub-agent
7. **Task Tracking** — tick verified criteria and completed tasks in the plan file
8. **Plan Review, E2E & Auto-fix** — review and E2E workers run together on the same `HEAD`; one phase-tier fix pass handles review findings and E2E failures under the same two-tier verify
9. **Pull Request & Report Finalization** — persist the report with `PR: pending`, invoke `/create-pr` or skip it, then patch only the PR line
10. **Report Contents & Terminal Summary** — define the persisted report and print its short hand-off

## Step 0: Pre-Flight (MANDATORY before any implementation work)

Before reading source files, writing code, or spawning any phase/implementation
sub-agent, parse the invocation flags, then complete three pre-flight items in order (the
Step 1 plan-parse prep agent is part of #1 and is allowed):

1. Plan path/content (Step 1)
2. Orchestrator model check (Step 2) — opus default; confirm only for a non-Opus session;
   per-phase sub-agent models are auto-selected later, NOT asked here
3. Worktree decision (Step 3) — and if yes, complete `/create-worktree`
   and note the new worktree path, then proceed immediately

**Read the settings first**, right after parsing the flags and before any spawn. Resolve
`<run-root>` once: the repo root the run started from (`git rev-parse --show-toplevel` in the
starting directory). Then:

- Run `<skill-dir>/scripts/config.py legacy-check --project-dir <run-root>` and print each
  entry of its `warnings` once. It always exits 0. An old UPPER_CASE variable it names is
  ignored, never read.
- Run `<skill-dir>/scripts/config.py dump --project-dir <run-root>` and keep its JSON as the
  run's settings. Every `selfVerifyLimit`, `skills.*`, and `implementPlan.*` value this skill
  names comes from that one read; there is no cache to refresh mid-run. Routing lists are the
  exception: the router reads the files again before each spawn (`references/routing.md`).
  Duration values convert to seconds as `references/runaway-guard.md` describes.
- Apply the startup check in § "Reviewer diversity" to the dumped `routing` lists.

A `config.py` error (exit 1, `config.py: <file>: <key>: <problem>` on stderr) stops
pre-flight: print the message and ask the user to fix that file. With `--worker`, end with
`implement-plan: stopped <plan-key> pre-flight`.

Do NOT begin Step 4 (Plan Structure) or any code reading until
Steps 1–3 are answered and the worktree (if requested) exists. Skipping
Step 3 has caused users to implement features on `main` and then
manually migrate diffs — never acceptable. Sub-agents inherit the worktree
path as their working directory, so the worktree MUST exist before any phase
is delegated.

If the user supplied a plan path as an argument, Step 1 is answered but Steps 2 and 3
are not. Without `--worker`, ask them now. With `--worker`, ask nothing: use the session
model as described in Step 2 and always create the worktree through `/create-worktree` as
described in Step 3. A `--worker` invocation with no plan path, or with inline markdown,
does not enter Step 1: end with `implement-plan: stopped <unknown> pre-flight`.

## Step 1: Plan Selection

Without `--worker`, prompt user:
```
Plan file path (or paste markdown content):
```

Without `--worker`, accept either:
- File path: `docs/plans/add-recipe-favorites.md`, `./my-plan.md`, etc.
- Inline markdown: (user pastes plan content directly)

**Delegate the parse — do not read the raw plan into the orchestrator window.** Spawn ONE
prep sub-agent on the target the router returns for `--role prep --project-dir <run-root>`
(default `claude:sonnet`; `routing.prep` accepts only `claude:*`, since prep runs through the
Agent tool) to read the plan (from the path, or
the inline content you pass it) and return a **verbatim normalized extract** — not a lossy
summary. The orchestrator schedules and hands off from this extract, so it must preserve the
load-bearing data exactly:

- Skip leading YAML front matter (a `---` fenced block at the top). Its fences are not the
  Overview/checklist divider.
- Validate structure first. Accept three forms. **New**: `### Phase` headings under
  `## Implementation Checklist`. **Legacy task blocks**: `### Phase` headings under
  `## Tasks`, with `#### Task N:` blocks and acceptance criteria. **Legacy task lines**:
  `### Phase 1: Name` headings under `## Phases`, with top-level `- [ ] Task 1a:` lines
  and no task blocks or acceptance criteria. Each top-level checkbox line is a task.
  Ignore every `###` heading outside those sections. If no form matches, return a
  structure error instead of an extract.
- For each phase, return: phase name/heading, dependency edges, and the **verbatim nested
  block of every task** (Module, Files, Depends on when present, Do, and Done when, or the
  legacy equivalents). Do not paraphrase or drop tasks. Dependency edges come from the
  `(depends on Phase X)` suffix on
  the phase headings. In either legacy form, also read the `## Task Dependency Graph` when present. In the
  new layout, if the Approach table disagrees with the headings, return a structure error that
  names the phase.
- Also return the parallel/sequential tag per phase when the legacy graph gives one.
- Also return `## Agent Notes` verbatim and the **Risk** bullets from
  `## Decisions & risks` verbatim. For legacy plans, return any equivalent context/risks
  section verbatim. Include this shared context in every phase handoff.
- Also return every `[e2e]` criterion, verbatim and paired with its phase. New layout: items
  in a task's "Done when" list. Legacy task blocks: items in an "Acceptance criteria" list. For
  example: `- [ ] Sample recipes still render after a cleared database [e2e]`.

Why verbatim: the orchestrator injects each phase's task list into its handoff (5a.2) and
feeds the `Files` lists into the file-overlap *safety* check (5a.1) — a lossy summary there
causes bad scheduling or worktree collisions.

**Sanity-check on return:** count only phase sections in the accepted form. Compare the
extract's phase count with `^### Phase` headings. Compare its task count with
`^- \[[ x]\] \*\*Task` (new), `^#### Task` (legacy task blocks), or
`^- \[[ x]\]` (legacy task lines). Nested criteria checkboxes do not count as tasks. On
mismatch or a structure error, fix the parse or fall back to reading the plan directly before proceeding.

When resuming a partially-complete plan, also diff the working-tree plan against committed
state (`git show HEAD:<plan-path>`). Checkboxes present in the working tree but not in HEAD
are unreliable evidence of completed work — they may be someone's uncommitted edit, and are
destroyable. Trust committed history for the resume point, and confirm the work exists in the
diff rather than in the checkbox. Use Step 7's "phase implemented" rule for the resume
point: pending `[e2e]` criteria and the task lines they hold open do not require a phase
rerun when its gate passed and its non-`[e2e]` work is committed.

## Step 2: Orchestrator Model

The orchestrator runs on **whatever model this session was launched with** — it cannot
switch its own model mid-run. `implementPlan.orchestratorModel` (default `opus`, any Opus-family model) is the *recommended*
model because the orchestrator holds cross-phase state, judges complexity, and supervises
sub-agents, which is exactly the work Opus is best at.

Only when the session model is not in the recommended family (for default `opus`, not an
Opus model) and `--worker` is absent, confirm with the user (one line). They relaunch on it
— you can't change it from here:
```
Orchestrator runs on the current session model; <implementPlan.orchestratorModel> family recommended. To use a
different model, relaunch the session on it — I can't switch mid-run. Press enter to continue.
```

With `--worker`, ask nothing and continue on the session model. If it is not Opus-family,
record that fact in the final report.

Do NOT ask which model implements each phase — that is decided automatically per phase
in Step 5 by complexity classification. Store the running model for the final report.

## Step 3: Worktree Setup

With `--worker`, ask nothing and always call `/create-worktree`. Otherwise ask: "Should I
create a new worktree? (y/n, default: y)"

If yes, call `/create-worktree` skill. Let the project implement worktree creation strategy (branch naming, isolation, etc.). Once the worktree is created, proceed directly to Step 4 — do NOT pause to confirm the worktree path with the user.

## Step 4: Plan Structure

You already have the normalized extract from the delegated parse (Step 1) — work from that,
not a fresh raw read. This is the structure the prep agent parsed:

```markdown
---
status: planned
---
# Feature Name
> **Goal:** ...
> **Size:** ...

## Summary
...

## What changes
...

## Approach
| Phase | Outcome | Depends on |
|---|---|---|
| 1. Foundation | ... | — |

## Decisions & risks
...

---

## Implementation Checklist

### Phase 1 — Foundation
- [ ] **Task 1: Name**
  - **Module**: `path/`
  - **Files**: `a`, `b`
  - **Do**:
    - What to build
  - **Done when**:
    - [ ] Criterion

## Verification
```

Full template: `../feature-plan/references/plan-template.md`. Both legacy forms stay
accepted: `## Tasks` with `#### Task N:` blocks and `**Acceptance criteria**:` lists;
`## Phases` with `### Phase 1: Name` headings and top-level `- [ ] Task 1a:` lines.

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

Carry-forward is dependency-local: pass only contracts, constraining decisions, and assigned
follow-ups needed by direct dependents; committed files hold implementation detail. Measured
2026-09-21 (MenuLens sessions `21163bb7` / `9e8b7fa4`): plan-file edits + carry-forward
added 12.2% / 17.9% of positive orchestrator context growth. The exact payload rule is in
`references/phase-execution.md` § "5a.2 Per-phase handoff payload".

Two rules are load-bearing and easy to get wrong:

- **File-overlap demotion** — phases that share a file (or any phase missing `**Files**:`
  metadata) are demoted out of a parallel group. A false-parallel corrupts the worktree;
  a false-sequential is merely slow.
- **Every phase commits its work** — the parallel merge and the Step 8 review diff both
  read committed history, so uncommitted work is invisible to both. The commit stays on the
  worktree/child branch; nothing is pushed or merged to `main`.

→ Full schedule/handoff/execution/cleanup procedure (5a.1–5a.4):
**`references/phase-execution.md`**.

### 5b. Runaway guard

Every sub-agent runs under a **wall-clock budget** (`implementPlan.phase.timeBudget`) and a **token
ceiling** checked on completion (`implementPlan.phase.tokenCeiling.<tier>`, or `implementPlan.phase.codexTokenCeiling.<tier>` for codex). Claude and codex workers get a
parallel background Bash `sleep` timer whose notification wakes the orchestrator; codex's
command `timeout` has a five-minute margin and is only a backstop, while pi uses `timeout`
directly. On a trip, stop the worker with its executor binding (`TaskStop`, process-group
kill, or process-tree kill), page the user via `skills.notify`, and wait.

→ Full procedure, resumption model, and the notify payload: **`references/runaway-guard.md`**.
With `--worker`, use `references/worker-mode.md` § "Asking the user" for the `needs input`
block instead of waiting silently.

## Step 6: Quality Verification

Verification is **two-tier**:

1. **Warm self-verify (phase agent).** The phase sub-agent runs `/verify` itself and
   iterates on failures while it still holds full context of the code it just wrote
   (Step 5a payload). This catches most issues in-context, with no cold re-derivation,
   and is bounded by `selfVerifyLimit` so it can't loop forever.

2. **Authoritative gate-verify (delegated).** Self-report on one's own gate is not a
   gate — so after the phase agent returns, the **orchestrator delegates an independent
   `/verify`** to a fresh sub-agent (the implementer never confirms its own work). The
   orchestrator does NOT run `/verify` in its own context: that would pour build/test
   output into the expensive Opus window every phase. Its return is fixed-shape:
   `status: pass|fail`; `errors: none|<verbatim errors>`; no command log, successful-check
   recap, or prose. This preserves the complete error artifact on failure while making a
   pass two lines. Measured 2026-09-21 (MenuLens sessions `21163bb7` / `9e8b7fa4`):
   gate-verify spawn/results added 10.2% / 11.9% of positive orchestrator context growth.

**Gate-verify model** — classify like a phase (Step 5a), by what the project's `/verify`
actually does:

| `/verify` nature | gate-agent `model` |
|---|---|
| Pure pass/fail (build + tests, exit-code gate) | `claude:haiku` |
| Behavioral (run the app, observe behavior matches intent) | `claude:sonnet` |

`routing.gateVerify` holds the gate targets (shipped `["claude:sonnet"]`); the table above is
how a project picks its list — drop to `["claude:haiku"]` only when verify is a deterministic
exit-code gate. Before each gate spawn, call the router with
`--role gateVerify --project-dir <run-root>` (the repo root the run started from) per `references/routing.md` § "Calling the router";
its `target` is the gate address. On `target: null` or a router failure, use the role's first
shipped target from `config.py defaults`. Spawn it with
the worktree path; it writes no code and only reports.
A codex gate that is given device checks gets the same device reservation, `ANDROID_SERIAL`,
`DEVICE_RESERVED=1`, and reserved-device handoff line as a codex worker; see `references/executors.md`
§ codex and `implementPlan.e2e.codexDeviceMode`.

Resolve this address by the same `executor:model` rule as phase workers (5a.2). An
unprefixed id still means `claude:<id>`. For gate verify the routing list order wins, so
the same executor or model family may implement and verify: gate verify mostly runs `/verify`
and reads exit codes, so the soft diversity rule is relaxed for gate verify only. Reviewer
diversity (§ "Reviewer diversity") stays mandatory.

**A sub-agent can fail *after* it has delivered.** A task notification with status
`failed` — a rate limit, an API error, a killed process — means the agent stopped, not that
its work is void. Read its hand-back first: if the agent already returned the artifact it was
spawned for (a findings list, a verify verdict, a phase summary), treat that artifact as
delivered and continue; do not re-spawn the agent to reproduce work you already hold.
Measured 2026-09-19 (MenuLens session `21163bb7`): the Step 8 review agent returned all five
findings and was then killed by a session rate limit, and the notification said `failed`.
Re-running it would have burned the capstone review twice. If the hand-back is missing or
truncated mid-artifact, re-spawn as usual and say so in the report.

**Retry Logic (orchestrator-level, on gate-verify fail):**
- Gate fail → orchestrator re-delegates the fix to a phase sub-agent for the SAME phase.
  Resolve the retry agent's target through the phase tier again (5a.2 step 1): every retry
  gets a fresh router call, so a fallback can take over mid-run. The re-spawned gate
  routes again the same way. The prior phase work is committed (5a.2), so instruct the retry agent to FIRST read the
  committed diff plus any working changes, then fix and re-run its warm self-verify — do not
  re-implement from scratch off the summary. It commits the fix when its self-verify passes,
  same commit contract as 5a.2. Pass the verbatim gate-verify error plus the prior summary
  and the shared context from 5a.2.
  Then re-spawn the gate-verify sub-agent. (The runaway guard from Step 5b applies to retry
  sub-agents too.)
- A phase gets at most `selfVerifyLimit` gate-verify attempts (default 2): attempt 1 is
  the initial phase agent, each subsequent attempt is one re-delegated fix. The same knob
  intentionally bounds the in-agent warm self-verify loop and these orchestrator-level gate
  retries (one budget, see Configuration) — the old fixed "3x retry" contract is retired.
- When all `selfVerifyLimit` attempts have failed their gate → hard stop

**On Hard Stop (`selfVerifyLimit` gate failures):**

Before paging the user, run a bounded **escalation pass** — the same Step 5 delegation loop
with the rescue target forced to `claude:opus` (switching executor first for pi/codex), an extended 5b budget (`implementPlan.escalation.tokenCeiling` /
`implementPlan.escalation.timeBudget`), a richer payload (full failure history + "diagnose root cause
before fixing"), and capped at `implementPlan.escalation.attempts` (default 2). It reuses the existing
machinery, so it inherits the runaway guard automatically — not a separate skill. The plan
gets a BLOCKED marker before the pass and a HALTED marker if it exhausts; for a parallel
group the marker lands on the group's first phase heading. On exhaustion, fall through to
user-wait (page via `skills.notify`, do NOT check off, resume from the failed phase on the
user's signal).

→ Full escalation procedure, BLOCKED/HALTED callout formats, group-failure handling, and
the user-wait steps: **`references/escalation.md`**.
With `--worker`, that reference ends the turn after notification with the required
`needs input` block from `references/worker-mode.md` § "Asking the user" instead of waiting
silently.

## Step 7: Task Tracking

When a phase passes verification, update the plan file:

1. Read the plan file **in the integration worktree** (Step 3) — not the copy in the
   original checkout
2. Tick verified criteria. New layout: tick each non-`[e2e]` criterion in the phase, then
   tick each task line whose criteria are all ticked. Defer `[e2e]` criteria only when E2E
   will run in Step 8. When E2E is skipped, tick them once the phase gate verifies them
   (references/phase-execution.md). If E2E is skipped or returns `env-error` after criteria
   were deferred, use the post-loop gate in `references/review-autofix.md` § "8d. Bounded re-run".
   Tick all remaining `[e2e]` criteria only on `status: pass`. On fail, leave them unticked,
   list them in the report, and do not enter the fix loop. Legacy task blocks: tick acceptance criteria the same
   way. Legacy task lines: tick each top-level task checkbox when its phase passes the gate.
   A phase is implemented when its gate passed, all non-`[e2e]` criteria are ticked, and
   every task line without pending `[e2e]` criteria is ticked. This permits scheduling and
   Step 8 before deferred E2E checks. A phase is complete when all its criteria and task
   lines are ticked; legacy task blocks require all acceptance criteria ticked.
3. Write the updated plan back to that same file
4. **Commit it immediately** — `git add <plan-path> && git commit -m "Plan: mark <phase> complete"`.
   Do not leave plan state uncommitted between phases. The same reasoning that makes 5a.2
   require phase commits applies here: sub-agents run `git add -A` and other destructive git
   commands in this worktree, and an uncommitted checkbox is silently destroyable. A
   plan-only commit also keeps progress legible in history and survives a worker that resets
   the tree.

Then print updated plan state so user can see progress:

```
Phases completed:
✓ Phase 1: Foundation Setup
✓ Phase 2: Core Implementation
- Phase 3: Testing & Refinement (in progress)
- Phase 4: Documentation (pending)
```

**Which copy (normative).** With an integration worktree there are always two copies of the
plan. Every plan-state update this skill makes — phase checkboxes, the plan status, the BLOCKED callout, and
the HALTED callout (`references/escalation.md`) — lands in the **integration worktree's
copy**, and only there. Never the original checkout's copy. That worktree copy is the file a
resuming session reads and the file the rung-2 rescue block tells the user to open, so a
marker written anywhere else leaves the resume target with no record of the failure it is
being asked to resume from. If the plan path you were given points outside the integration
worktree, resolve it to the same relative path inside the worktree before writing.

**Plans that live outside the project repo.** A plan kept in a separate repo — a notes vault,
a docs repo — has no copy inside the integration worktree, so the resolve-into-the-worktree
rule above does not apply to it. Write checkboxes and callouts to the plan file where it
actually lives. Do **not** commit it in step 4: no worker touches that repo, so the
destructive-git reasoning behind the commit rule does not hold, and a blind commit there
sweeps in whatever else the user has uncommitted in it. Say in the report that plan state was
updated in place and left uncommitted, and name the file.

## Step 8: Plan Review & Auto-fix

Run ONLY after every phase is implemented under Step 7's rule; deferred `[e2e]` criteria
and the task lines they hold open may remain unticked. On the last phase's `HEAD`, spawn
the enabled review and E2E workers together. Each has its own runaway guard and shares the
parallel-worker limit. Skip both after a hard stop or BLOCKED/HALTED phase.
Otherwise, each worker runs alone when the other is disabled or its skill is absent. State
every skip reason in the report.

The review worker reads the cumulative diff without building or testing. The E2E worker
receives the worktree, the prep extract's `[e2e]` criteria, and `references/e2e.md`. Wait for
both enabled workers. Then delegate one combined fix pass for at-threshold review findings
and E2E failures. Re-run E2E only after a fix commit. One cap, `implementPlan.review.maxRounds`, bounds
the combined loop. The orchestrator never reads the raw diff or verbatim E2E failures.

→ Full review/triage/fix/re-review procedure (8a–8d): **`references/review-autofix.md`**.

## Step 9: Pull Request

Runs only after Step 8 has fully settled — every review/E2E round finished, every auto-fix
committed and gate-verified. First re-read the plan file at the Step 7 plan-state location —
the copy in the integration worktree for a repository plan, or the original file for a plan
outside the repository — and confirm all non-`[e2e]` criteria and the task lines they
complete are ticked under Step 7. Tick `[e2e]` criteria only on the final E2E pass or gate
verification when E2E is skipped, then tick the task lines they complete. Apply missing
updates only with that verification evidence. Phases have no checkbox.

**Set plan status (completed run only).** After Step 8 settles and before writing the report,
set `status: complete` only when every phase is complete under Step 7 and the run completes.
Use the same Step 7 plan-state copy. Add a front matter block (`---`, `status: complete`,
`---`) when absent. Keep other keys. Never change status on a stopped, stuck, or blocked run.

Assemble the Step 10 report with `**PR:** pending` and write it to that plan file as
`## Implementation Report — <YYYY-MM-DD>`. Replace only the latest (closest to end of file) `## Implementation Report` section whose `**PR:**` line is
exactly `pending`, regardless of its date; otherwise replace the section with today's exact
heading, from that heading to the next `##` heading or end of file; append only when neither
exists. Earlier completed reports stay. For a plan outside the project repository, write the
report in place and leave
it uncommitted, even when its vault has other uncommitted edits. For a repository plan, write
it to the integration-worktree copy and commit it together with the status change using the
Step 7 plan-state rule, before invoking `/create-pr`. Do not leave the status change
uncommitted for a worker to stage. For a plan outside the repository, leave the status
change uncommitted with the report.

Then invoke `/create-pr` (`skills.createPr`) from the integration worktree when it exists and `implementPlan.createPr` is not `false`,
passing the branch and the **path of the plan file that contains the dated
`## Implementation Report — <YYYY-MM-DD>` section**, with a request to include that report in
the PR body. Let `/create-pr` own everything else — push, title, body, templates, and host
tooling. The orchestrator never edits the PR body itself. PR conventions vary too much between
projects for this skill to bundle an implementation.

Expectations on the project's `/create-pr`: open a **draft** PR, never merge anything, run
without prompting (Step 9 is unattended), and return the PR URL for the report. If no
`/create-pr` skill exists in the session, or `implementPlan.createPr` is `false`, skip it. Patch only the
persisted report's `**PR:**` line to `skipped — <reason>`; do not reassemble the report. The
report still goes to the plan and the run ends at the local worktree branch, as before.
Otherwise, after `/create-pr` returns, patch only that line to its URL; do not reassemble the
report or change its measured figures. After either PR-line patch, commit a repository plan
using the Step 7 plan-state rule; leave an outside-repository plan uncommitted. Read the
returned PR body through the available read-only PR detail. If
it omits the report, leave the body unchanged and mark that omission for Step 10's terminal
summary.

## Step 10: Report Contents & Terminal Summary

Step 9 assembles, persists, and finalizes this report. Step 10 defines its contents and prints
the terminal summary. Never rewrite a report that Step 9 has finalized. The exact assembled
report is the copy requested for the PR body. The orchestrator does not edit that body.

Two rules govern the report's contents and have been violated in practice:

**F3 — Models: report what actually ran.** Every model id in the report comes from the
orchestrator's own spawn records (the model it recorded per phase at Step 5a.2), never
transcribed from configuration defaults or a routing table. A report that echoes configured
defaults can never reveal an override or substitution — the only case where the audit
matters. Where actual and configured differ, print both:
`Phase 3 (light): <actual> (configured: <configured>)`. Where the actual model cannot be
recovered, print `unknown (configured: <id>)` — never fill the gap from a table. Phase,
gate, review, fix, and E2E model lines carry the router reason in parentheses, also from the
spawn record, per `references/routing.md` § "Report format".

**F4 — Cost: measured or absent, never estimated.** Any cost figure comes from token
accounting for this run and nothing else. Unavailable → emit `token accounting unavailable`
with no number. Partial → report the measured part and name what it covers. Never derive a
figure from token counts, model prices, elapsed time, or a previous run. An estimated cost
figure was wrong by 13× in a real run; no number is better than a wrong one.

After Step 8 settles:

Fill `### Unplanned Decisions` from the workers' `unplanned_decisions` returns. Write `- None`
when every list is empty. The user checks these at PR review instead of being asked during the
run.

```markdown
## Implementation Report — <YYYY-MM-DD>

**Date:** <YYYY-MM-DD>

### Implementation Summary

**Plan:** <plan-name>
**Orchestrator:** <orchestrator model, e.g. claude-opus-5-5>
**Worktree:** <path>
**Branch:** <branch-name>
**PR:** <`pending` before Step 9, then url, or `skipped — <reason>`>

### Phases Completed
- Phase 1 (<tier>): <description> — sub-agent: <model> (<router reason>); gate: <model> (<router reason>)
- Phase 2 (<tier>): <description> — sub-agent: <model> (<router reason>); gate: <model> (<router reason>)
- Phase 3 (<tier>): <description> — sub-agent: <model> (<router reason>); gate: <model> (<router reason>)
- Routing warnings: <each router warning once, or none>

### Verification Status
✓ All phases passed verification

### Unplanned Decisions
- <decision> (<Phase N | rescue Phase N | review fix round N>) — <why>

### Review & Auto-fix
- Reviewer: <review target> (<router reason>) on `<base>...HEAD` via <skills.review>
- Findings: <N total> — <M auto-fixed & verified> / <K left for you>
- Auto-fixed: <one line each, file:line + what changed> — fix sub-agent: <model> (<router reason>)
- Left for you (below threshold): <one line each, severity + file:line + problem>
- Rounds: <R> of <implementPlan.review.maxRounds>

### E2E
- Worker: <actual executor:model from the E2E spawn record> (<router reason>)
- Status: <pass | fail — failed names or failed hand-back | env-error — E2E did not run | skipped — reason | not finished — reason>
- Passed: <n>/<total>
- Failed: <names; empty if none>
- Flaky: <names; empty if none>
- Rounds: <R> of <implementPlan.review.maxRounds>
- Evidence: <path, or absent>
- Codex device mode: <reserved-device | full-access (user confirmed: yes/no) | off>

### Cost
- **Orchestrator (Claude Code):** cost: `token accounting unavailable — the session
  transcript has no dollar cost record; F4 forbids estimating`; API calls: <measured distinct
  `message.id` count from the orchestrator's own session transcript, or `unavailable —
  session transcript not identified`>; peak context: <measured maximum context from that
  transcript, or `unavailable — session transcript not identified`>. Extract API calls and
  peak context as specified in `references/runaway-guard.md` § "Token accounting". Do not
  substitute turns, messages, elapsed time, worker totals, model prices, or a UI/account-level
  quota for any of these fields.
- **Workers (by executor):** <one row for every executor that ran phase, retry, escalation,
  or gate-verify work; aggregate only its exit-time spawn records. If no accounting record
  exists for that executor, print `token accounting unavailable` rather than a total.>
  - `claude`: <tokens from completion notifications>; cost: <measured cost record, or
    `token accounting unavailable`>. Completion tokens alone do not establish dollars.
  - `pi`: <new tokens, plus cache-read tokens separately>; equivalent value: <sum of
    `cost.total`, labelled flat-rate equivalent value — not metered spend>. If an exit-time
    record is missing, print `token accounting unavailable`.
  - `codex`: <new tokens>; plan-window usage: <5-hour and weekly first/last values and
    deltas from the token-count records>; no dollars. If either required record is absent,
    the later value is lower, or `resets_at` changed, print `token accounting unavailable`
    for that window; never derive it. When codex workers overlap, merge the rollout files
    named by their spawn-record thread ids and report the time-sorted whole-run delta using
    `references/runaway-guard.md`, rather than attributing it to individual workers.
- **Review + fix (by executor):** <one row for every executor that ran Step 8 review or
  fix work, using the same executor-specific form and source rules as Workers. If review was
  skipped, say `absent — review skipped: <reason>`; if it ran but has no accounting, say
  `token accounting unavailable`.>
- **E2E (by executor):** <one row for every executor that ran the Step 8 E2E worker, using
  the same executor-specific form and source rules as Workers. If E2E was skipped, say
  `absent — E2E skipped: <reason>`; if it ran but has no accounting, say
  `token accounting unavailable`.>

The four rows are independent. A measured worker, review, or E2E value does not fill an absent
orchestrator value (or vice versa). `pi`'s figure remains equivalent value, never cash
spend; codex, the shipped subscription-backed executor, reports tokens and plan-window share
only, never dollars.

### What's Next
- Worktree is ready at <path>
- Review code and decide: merge, iterate, or cleanup
- Skill does NOT auto-merge or cleanup — that's your call
```

After Step 9 finalizes the plan report, print only a short terminal summary: plan, branch,
worktree, pass/fail per phase, E2E status, findings and failures left for the user, the
orchestrator cost row, PR URL or `PR skipped — <reason>`, and
`Full report: <plan-file path>`. If `/create-pr` opened a PR
but its returned body omits the report, also print `PR report omitted — /create-pr left the
report out`. Do not print the full report to the terminal.

With `--worker`, every terminal exit ends with either
`implement-plan: done <plan-key> <PR url | pr-skipped>` or
`implement-plan: stopped <plan-key> <phase>`. `needs input` pauses the run and resumes from
that step. Use `pre-flight` for a plan structure error, a `config.py` error, or a
`/create-worktree` failure before a phase, `step-9` for a Step 9 failure, and `<unknown> pre-flight` for missing or inline plan
input. Use a phase name for a hard stop, including when a `needs input` answer selects "stop
the run".

The run is complete. Follow-up questions, fixes (including below-threshold findings), and
re-verification belong in a fresh session, which starts near zero context rather than at this
run's peak. Carry over the worktree path, branch, PR link, plan file path and its checked-off
state, below-threshold findings left for you, and known gaps from this report.

If hard-stopped due to failure:

```markdown
# Implementation Stopped

**Plan:** <plan-name>
**Failed Phase:** <phase-name>
**Failure Point:** verification failed every gate attempt (selfVerifyLimit) + escalation halted

## Error Summary
<error output from last /verify call>

## Recovery
- Review the error above
- Fix the issue manually in the worktree
- Signal ready to retry
- Skill will rerun verification on the failed phase
```

## Configuration

Settings live in `workflow-kit.json`: the user file `~/.claude/workflow-kit.json`, then the
project file `<repo>/.claude/workflow-kit.json`, which overrides it key by key (lists and
scalars replace whole). `scripts/config.py` is the only reader and the single source of the
defaults below (`config.py defaults` prints them); Step 0 reads the run's settings through it.
A duration is one number and one unit (`30m`, `45m`, `1h`). Routing lists, budget thresholds,
and the router contract: `references/routing.md`. Old UPPER_CASE variables in the environment
or CLAUDE.md are ignored; `config.py legacy-check` names each one and its new key. Where this
skill says `/verify`, `/e2e`, `/notify-me`, or `/create-pr`, it means the configured
`skills.*` value.

| Key | Default | Meaning |
|---|---|---|
| `routing.phase.light` / `.standard` / `.deep` | `["claude:haiku"]` / `["claude:sonnet"]` / `["claude:opus"]` | Phase, retry, and fix worker targets per tier (Step 5a.2). |
| `routing.gateVerify` | `["claude:sonnet"]` | Gate-verify targets (Step 6); `["claude:haiku"]` suits an exit-code-only verify. |
| `routing.review` | `["claude:opus"]` | Step 8 reviewer targets; § "Reviewer diversity" applies. |
| `routing.prep` | `["claude:sonnet"]` | Step 1 plan-parse targets; `claude:*` only, and avoid `haiku` (the extract is load-bearing). |
| `routing.e2e` | `["claude:sonnet"]` | Step 8 E2E worker targets; foreign targets are guarded by the fresh-evidence check. |
| `minBudgetPercent` | `15` | Quota percent a target needs before the router picks it. |
| `minBudgetPercentByRole.<role>` | `review: 25` | Per-role override of `minBudgetPercent`. |
| `skills.verify` | `/verify` | Verify skill for self-verify and gate-verify. |
| `skills.review` | `/code-review` | Step 8 review skill; must be non-interactive and read-only; absent skips review. |
| `skills.e2e` | `/e2e` | Step 8 E2E skill; absent skips E2E. |
| `skills.notify` | `/notify-me` | Skill that pages the user. |
| `skills.createPr` | `/create-pr` | Step 9 PR skill; absent skips the PR. |
| `selfVerifyLimit` | `2` | Caps both the warm self-verify rounds in a phase agent and the gate-verify attempts per phase. |
| `implementPlan.orchestratorModel` | `opus` | Recommended orchestrator model family (Step 2). |
| `implementPlan.maxParallelAgents` | `3` | Max concurrent phase agents; larger groups run in batches. |
| `implementPlan.phase.timeBudget` | `30m` | Per-phase wall-clock budget (Step 5b). |
| `implementPlan.phase.tokenCeiling.<tier>` | `80000` / `150000` / `250000` | Claude and pi token ceiling per tier, checked on completion (Step 5b). |
| `implementPlan.phase.codexTokenCeiling.<tier>` | `200000` / `250000` / `400000` | Codex token ceiling per tier; replaces `tokenCeiling` for codex workers. |
| `implementPlan.escalation.attempts` | `2` | Max forced-`claude:opus` rescue attempts before HALTED (Step 6). |
| `implementPlan.escalation.tokenCeiling` | `400000` | Token ceiling for one rescue attempt. |
| `implementPlan.escalation.timeBudget` | `30m` | Wall-clock budget for one rescue attempt. |
| `implementPlan.review.enabled` | `true` | Run the Step 8 review; `false` skips review only. |
| `implementPlan.review.autofixSeverity` | `high` | Lowest finding severity auto-fixed: `critical`, `high`, `medium`, or `low`. |
| `implementPlan.review.maxRounds` | `2` | Cap on combined review/E2E↔fix rounds (Step 8d). |
| `implementPlan.e2e.enabled` | `true` | Run the Step 8 E2E worker. |
| `implementPlan.e2e.timeBudget` | `45m` | E2E wall-clock budget (a cold emulator plus the suite). |
| `implementPlan.e2e.tokenCeiling` | `150000` | E2E token ceiling. |
| `implementPlan.e2e.codexDeviceMode` | `reserved-device` | How codex workers, gates, and E2E get a device: `reserved-device`, `full-access`, or `off` (`references/executors.md` § codex). |
| `implementPlan.createPr` | `true` | `false` ends the run at the local branch instead of calling `skills.createPr`. |

`routing.prFix` (address-pr fix workers) and `routing.orchestrator` (the pm launch gate) live
in the same file; implement-plan does not read them.

### Reviewer diversity

The Step 8 reviewer and each implementer it checks must differ by executor or model family
whenever the configured lists offer such a target. The rule checks resolved routing targets,
and it is inert (not falsely claimed satisfied) when every list is Claude-only. For pi, when
the routed pi reviewer shares a family with a pi implementer (for example a Grok phase target
under a Grok reviewer), switch the reviewer to `pi:opencode-go/qwen3.8-max`, or to
`pi:opencode-go/glm-5.3` when the implementer is Qwen. For codex the rule is mandatory: every
Codex model is GPT family, so a codex reviewer never differs in family from a codex
implementer. When every `routing.review` target is `codex:*`, pass `--exclude-executor codex`
on every phase, retry, and fix router call. When a phase tier list is also all `codex:*`, fail
at startup (Step 0) with an error that names the family-diversity rule, includes the review
list and that tier list, and says **do not start the run**. A mixed review list is handled by
the review router call (`references/routing.md` § "Calling the router"). A codex reviewer over
pi or Claude implementers is valid; pi workers with a codex reviewer is the pairing to evaluate
as a cheap, family-diverse default. No bake-off measured review judgement on a real diff, so
keep `routing.review` on `claude:opus` if review reliability is a concern. On a ChatGPT Plus
plan one full-diff review is expensive: a `gpt-6-astra` review of a 106-file diff took 22 % of
the 5-hour window (measured 2026-09-18).

## Plan Format Example

See Step 4 for the layout and `../feature-plan/references/plan-template.md` for the full
template.

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
  integration gate-verify must pass before Step 7 records progress and the group advances.
- **The orchestrator window stays lean** — the raw plan is read by a cheap prep agent
  (`routing.prep`), which returns a verbatim extract; the orchestrator never holds the
  raw source, so it doesn't get re-processed every turn.
- **Carry-forward is dependency-local** — retain only contracts, constraining decisions,
  and assigned follow-ups needed by direct dependents; committed files hold implementation
  detail. Measured 2026-09-21 (MenuLens sessions `21163bb7` / `9e8b7fa4`): plan edits +
  carry-forward were 12.2% / 17.9% of positive context growth.
- **Measured small buckets stay unchanged** — worker hand-backs (3.9% / 5.9%), foreign
  output extraction (0.0% / 1.1%), and timer/bookkeeping calls (8.4% / 5.5%) were each below
  10% in those runs, so their full summary, extracted-only accounting, and timer-binding
  contracts remain intact.
- **Sub-agents are observed** — runaway token burn or silent loops pause the phase and
  page you (Step 5b) rather than burning budget unattended.
- **Review and E2E are the capstone** — after all phases pass, the enabled review and E2E
  workers run together on the same `HEAD`. One fix pass handles their actionable results.
  The combined loop is bounded by `implementPlan.review.maxRounds`; disable either worker independently.
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
