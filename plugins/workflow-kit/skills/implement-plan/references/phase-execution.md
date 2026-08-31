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

**1. Classify complexity → pick the sub-agent tier** (auto, no user prompt). Judge
the phase's tasks and assign a tier:

| Phase character | Tier |
|---|---|
| Mechanical/boilerplate (wiring, renames, simple CRUD, test scaffolds) | `light` |
| Normal feature work (typical layer impl, standard tests) | `standard` |
| Complex/novel (tricky algorithms, cross-cutting design, ambiguous tasks) | `deep` |

The tier resolves to a host-specific model via `references/model-routing.md`
(`PHASE_MODEL_LIGHT`, `PHASE_MODEL_STANDARD`, `PHASE_MODEL_DEEP`). The orchestrator
resolves the model at spawn time using the active host binding. Record the chosen tier
and model per phase for the final report.

**2. Build the handoff payload.** Sub-agents start blank, so the prompt MUST carry
everything the phase needs:

- Plan file path + the **verbatim task list for this phase only**
- **Worktree path** — depends on how the phase runs (see 5a.3):
  - *Sequential phase* → the integration worktree from Step 3; `cd` in and work there.
  - *Parallel phase* → its own **child worktree** that the orchestrator created off
    integration HEAD; the agent works ONLY inside that child worktree.
  **Worktree-ownership rule (normative):** the orchestrator creates and owns every
  worktree explicitly — workers must never create worktrees of their own. A worker
  spawning its own worktree (e.g. via `isolation: "worktree"` on claude-code) scatters
  each phase's edits and breaks carry-forward. Edits never touch `main`.
  **Worktree-placement rule (normative, host-independent):** the integration worktree is a
  **sibling** of the project repository, and each child worktree is a **sibling** of the
  integration worktree (5a.3) — never nested inside either, so the integration build and
  gate-verify never traverse in-flight child files and the project's own tooling never
  walks the worktrees. This shape is the same on every host. Where a host confines worker
  tool calls to a session root (`PATH_SCOPE` restricted — see *Session Root Constraint* in
  `references/runtimes.md`), the **session root** is what must contain the whole family;
  the worktrees do not move. Step 0.5 verifies that and halts if it fails, because a worker
  pointed outside such a root hangs with no error and no way to cancel it.
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
- **Destructive-git prohibition**: "Do NOT run `git reset --hard`, `git checkout -- <path>`,
  `git restore`, `git clean`, or `git stash` in this worktree. The orchestrator keeps
  uncommitted state here (plan progress, and in-flight work from other phases) and these
  commands destroy it with no warning and no recovery. To discard your own changes, revert the
  specific edit you made."
- Explicit boundaries: "implement ONLY this phase's tasks; do NOT edit the plan file,
  do NOT start other phases. Return a structured summary."
- Required return format: files touched, what each does, decisions made, anything the
  next phase needs, your final self-verify result (pass/fail + remaining errors), and
  any tasks you could not complete.

## 5a.3 Execute each layer

Walk layers in topological order (5a.1). Every phase agent is spawned via **SPAWN_WORKER**
(on claude-code: the `Agent` tool with `run_in_background: true`). This gives no live
token/tool feed, but it buys two things the orchestrator needs: it stays responsive instead
of blocking (so it can run the 5b wall-clock guard, and watch several agents at once), and
each spawned worker is stoppable via **STOP_WORKER**. On hosts without STOP_WORKER
(opencode: no first-class cancellation tool — see `references/runtimes.md`), the guard
is post-hoc only: a runaway worker burns to completion before the token ceiling stops its
successor. The completion notification carries the agent's total token count and duration,
which feeds the 5b ceiling check.

**PACE and parallel-group demotion:** `PACE` covers two things — running phases
*concurrently*, and *backgrounding*: control returning to the orchestrator while a worker
runs, which is what the 5b wall-clock guard needs in order to observe an in-flight agent.
Where **either** half is unavailable, the entire parallel group demotes to sequential —
phases run one at a time in the integration worktree rather than in isolated child
worktrees. On opencode the missing half is backgrounding: sibling subagents do execute
concurrently (measured), but the `task` tool blocks until the child returns, so with no
backgrounding and no `STOP_WORKER` a concurrent group there would run entirely
unsupervised. See *Parallel-Group Availability* in `references/runtimes.md` for the full
rationale and what a future flip would require. The orchestrator's dependency graph is still computed and its ordering
respected; the atomic-advance contract (all phases in the group checked off only when the
whole group passes the integration gate-verify) is unchanged. Child worktree creation is
skipped for groups that are sequential-demoted.

**Single-phase layer (the common case — unchanged from sequential):**
1. Spawn the phase agent in the integration worktree (background; 5b guard applies).
2. On return, review the summary including the agent's self-verify result.
3. Delegate the authoritative gate-verify (Step 6) — independent, even if the agent
   self-reported pass.
4. Gate pass → IMMEDIATELY check off the phase (Step 7), append its summary to the
   carry-forward, advance. Do not batch checkbox updates — write after each phase.

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
   passes — check off ALL phases in the group (Step 7), append every member's summary to
   the carry-forward, then clean up (5a.4) and advance to the next layer.
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
