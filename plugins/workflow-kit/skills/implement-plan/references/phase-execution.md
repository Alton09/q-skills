# Phase Scheduling, Handoff & Layer Execution (Step 5a)

Referenced from `SKILL.md` Step 5. The orchestrator schedules phases by the plan's
dependency graph, builds each phase's cold-start handoff, and executes layers — running
independent phases in parallel and dependent phases in order.

## 5a.1 Build the execution schedule

feature-plan encodes dependencies two ways — use both:

- Phase headings: `### Phase 2 — Name (depends on Phase 1)`
- A `## Task Dependency Graph` block:
  ```
  Phase 1 (parallel): Task 1, Task 2
  Phase 2 (sequential, depends on Phase 1): Task 3
  Phase 3 (parallel, depends on Phase 2): Task 4, Task 5
  ```

Parse these into a phase → prerequisites map and compute **layers** (topological levels):
a layer is the set of phases whose prerequisites are all already complete. Phases in the
same layer have no dependency edge between them → **candidate parallel group**.

If the plan has no dependency notation at all, treat every phase as depending on the
previous one (pure sequential) — safe default.

**File-overlap demotion (mandatory safety check).** The dependency graph encodes
*logical* deps, not *file* deps — two "independent" phases can still edit the same file.
Before parallelizing a candidate group, read each phase's `**Files**:` metadata. If two
phases in the group share any file, they CANNOT run concurrently: split the group so each
parallel subset has pairwise-disjoint file sets, and run the leftover phases in a later
sequential sub-step. If any phase in the group has **no `**Files**:` metadata at all**, you
cannot prove its file set is disjoint — demote the whole group to sequential rather than
guess. When in doubt, demote: a false-sequential is merely slow; a false-parallel corrupts
the worktree.

Cap concurrency at `MAX_PARALLEL_AGENTS` (default 3); if a group is larger, run it in
batches of that size.

## 5a.2 Per-phase handoff payload

For each phase (sequential or parallel), build its handoff:

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
- **Worktree path** — depends on how the phase runs (see 5a.3):
  - *Sequential phase* → the integration worktree from Step 3; `cd` in and work there.
  - *Parallel phase* → its own **child worktree** that the orchestrator created off
    integration HEAD; the agent works ONLY inside that child worktree.
  In both cases do NOT pass `isolation: "worktree"` — the orchestrator creates and owns
  every worktree explicitly; letting the Agent tool spawn its own scatters each phase's
  edits and breaks carry-forward. Edits never touch `main`.
- **Carry-forward**: a short summary the orchestrator maintains — files created/modified,
  key decisions, public interfaces introduced — covering **all completed prerequisite
  phases**, so this phase builds correctly on what came before. (Within a parallel group,
  members do NOT see each other's in-flight work — fine, they have no mutual dependency.)
- Self-verify instruction: "After implementing, run /verify. If it fails, iterate to
  fix — up to <SELF_VERIFY_LIMIT, default 2> rounds — then stop regardless. Report your
  final /verify result (pass/fail) and any remaining errors verbatim."
- **Commit instruction**: "When your self-verify is done, stage and commit your phase's
  work on the current branch (`git add -A && git commit -m \"<phase name>\"`)." This is
  load-bearing, not optional: the parallel merge (5a.3) and the Step 8 review diff both read
  **committed** history — uncommitted work is invisible to the merge and to the reviewer. The
  commit lands on the worktree/child branch only; nothing is pushed or merged to `main` (see
  SKILL.md Notes).
- Explicit boundaries: "implement ONLY this phase's tasks; do NOT edit the plan file,
  do NOT start other phases. Return a structured summary."
- Required return format: files touched, what each does, decisions made, anything the
  next phase needs, your final self-verify result (pass/fail + remaining errors), and
  any tasks you could not complete.

## 5a.3 Execute each layer

Walk layers in topological order (5a.1). Every phase agent is spawned with the Agent tool
and `run_in_background: true` — this gives no live token/tool feed, but it buys two things
the orchestrator needs: it stays responsive instead of blocking (so it can run the 5b
wall-clock guard, and watch several agents at once), and each agent is cancellable via
`TaskStop`. The completion notification carries the agent's total token count and
duration, which feeds the 5b ceiling check.

**Single-phase layer (the common case — unchanged from sequential):**
1. Spawn the phase agent in the integration worktree (background; 5b guard applies).
2. On return, review the summary including the agent's self-verify result.
3. Delegate the authoritative gate-verify (Step 6) — independent, even if the agent
   self-reported pass.
4. Gate pass → IMMEDIATELY check off the phase (Step 7), record the layer's head SHA in the
   ledger (`git -C <integration> rev-parse HEAD`), append its summary to the carry-forward,
   advance. Do not batch checkbox updates — write after each phase.

**Multi-phase layer (parallel group):**
1. For each phase, create a child worktree + branch off integration HEAD, as a **sibling**
   of the integration worktree (not nested inside it, so the integration build/gate-verify
   never traverses in-flight child files):
   ```
   git -C <integration> worktree add <integration>/../.wt/<phase-slug> -b <phase-branch>
   ```
2. Spawn all phase agents concurrently (background), each pointed at its own child
   worktree, capped at `MAX_PARALLEL_AGENTS`. The 5b runaway guard applies per agent.
3. When ALL agents in the group have returned, merge each child branch into integration
   in turn (each agent committed its work per 5a.2, so there is something to merge):
   ```
   git -C <integration> merge --no-ff <phase-branch>
   ```
   A clean merge is expected (disjoint files by 5a.1). A real conflict = treat that phase
   as failed: keep its child worktree for inspection and enter the Step 6 retry path on
   the conflicted phase.
4. Run ONE **integration gate-verify** (Step 6) on the merged state — not per-child; a
   child can pass alone yet break once merged.
5. **Atomic advance:** only when the whole group is merged AND the integration gate-verify
   passes — check off ALL phases in the group (Step 7), record the layer's head SHA in the
   ledger (`git -C <integration> rev-parse HEAD`, i.e. after every merge has landed), append
   every member's summary to the carry-forward, then clean up (5a.4) and advance.
6. Integration-verify fail → the failure belongs to the **group as a unit**, not any one
   phase (the break is in the merged result). Re-delegate the fix to ONE sub-agent working
   on the merged integration worktree (warm: read the full merged diff + verbatim error),
   covering ALL phases in the group; then re-run the integration gate-verify. This is the
   Step 6 retry path, scoped to the group. If it exhausts `SELF_VERIFY_LIMIT` attempts, the
   Step 6 escalation runs on the same merged integration worktree and the BLOCKED/HALTED
   marker is attached to the **first phase heading in the group**, with a note listing all
   member phases. Do NOT clean up child worktrees until the group finally passes.

## 5a.4 Clean up child worktrees

Child worktrees and branches are ephemeral scaffolding — remove them once their work is
safely in integration. Clean up a group's children ONLY after the group's integration
gate-verify passes (5a.3 step 5):

```
git -C <integration> worktree remove <integration>/../.wt/<phase-slug>
git -C <integration> branch -d <phase-branch>
```

Use `branch -d` (not `-D`): git refuses to delete a branch that isn't fully merged, so a
failed delete is a tripwire that the merge didn't actually land — investigate, don't
force. If a merge conflicted or the gate failed, KEEP the child worktree so you can
inspect it. **Never** remove the integration worktree — that is the user's deliverable
(see SKILL.md Notes / "No auto-cleanup").

## 5a.5 The layer-SHA ledger

Alongside the carry-forward, keep one line per completed layer:

```
layer 1  phases: [Domain]         sha: a1b2c3d
layer 2  phases: [Data, Cache]    sha: e4f5a6b
```

Step 9 hands this ledger to `PR_SKILL`, which cuts one stacked-PR branch per entry. Record it at
the moment the layer's gate-verify passes — for a parallel group, after its merges land.
Afterwards the boundary is unrecoverable: the group's commits are interleaved by the merge,
and no later `git log` walk can tell you which prefix of history was "layer 2".
