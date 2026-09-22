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

**1. Classify complexity → resolve the sub-agent target** (auto, no user prompt). Judge
the phase's tasks as light, standard, or deep, then read `PHASE_MODEL_LIGHT`,
`PHASE_MODEL_STANDARD`, or `PHASE_MODEL_DEEP`. Each value is an `executor:model` address;
split only on the first colon and use the matching registry entry. An unprefixed model id
always resolves to `claude:<id>` for backward compatibility. Reject an unknown executor or
an invalid model id before spawning, with an error that names the resolved executor and id.

The shipped tier defaults preserve the existing `PHASE_EXECUTOR` shorthand:

| `PHASE_EXECUTOR` | light | standard | deep |
|---|---|---|---|
| `claude` (default) | `claude:haiku` | `claude:sonnet` | `claude:opus` |
| `pi` | `pi:opencode-go/minimax-m3` | `pi:opencode-go/glm-5.3` | `pi:opencode-go/qwen3.8-max` |
| `codex` | `codex:gpt-5.6-luna` | `codex:gpt-5.6-terra` | `codex:gpt-5.6-sol` |

Explicit `PHASE_MODEL_*` values win over that shorthand, so tiers may use different
executors. For example, `PHASE_MODEL_LIGHT=pi:opencode-go/minimax-m3` and
`PHASE_MODEL_STANDARD=codex:gpt-5.6-terra` are valid in the same run.

The deep tier is `qwen3.8-max`, not Kimi K3. In the 2026-09-16 bake-off, Kimi K3 failed
C2 tool discipline: it stopped after 4 of 10 steps and reported the task done. Complex
phases are the longest multi-step work and end with `/verify`, so a premature stop with a
false completion claim costs most there. `qwen3.8-max` passed all three canaries and was
faster and cheaper than Kimi K3 on each.

These are provisional defaults taken from the model descriptions, not from a bake-off. Every
Codex model is GPT family. On a Plus plan a single large worker can take a double-digit share
of the 5-hour window (one full-diff review on `gpt-6-astra` took 22 %), so `gpt-6-astra` is
deliberately not a phase tier.

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
- **Carry-forward**: include only facts this phase needs from its **direct prerequisites**:
  public interfaces/contracts introduced, non-obvious decisions that constrain this phase,
  and any prerequisite blocker or follow-up assigned to it. Do not accumulate files touched,
  verification history, or summaries from unrelated/indirect phases; the committed tree is
  the source of truth for their implementation. Within a parallel group, members do NOT see
  each other's in-flight work — fine, they have no mutual dependency. Measured 2026-09-21
  (MenuLens sessions `21163bb7` / `9e8b7fa4`): plan-file edits + carry-forward added
  12.2% / 17.9% of positive orchestrator context growth.
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

**3. Foreign executors: name the required skills by path.** For any executor other than
`claude`, add a block to the handoff that lists, by file path, the project skills the worker
must read **before editing** (e.g. the project's architecture skill before touching source)
and the skill it must follow **to finish** (the project's verify skill). Resolve each path
the way that executor sees skills — for `pi`, inside the `--skill` directory (e.g.
`<consumer .claude/skills>/verify/SKILL.md`); for `codex`, under `<worktree>/.agents/skills/`
(e.g. `.agents/skills/verify/SKILL.md`). Foreign workers have no `Skill` tool, and
description-triggered loading proved unreliable: on a 2026-09-18 run, pi workers never
opened the architecture skill in five phases that moved code between layers, and only two of
six opened `verify`.

Do **not** paste the commands a skill contains into the handoff — name the skill and let the
worker read it. Inlined commands make the worker follow the handoff instead of the skill, and
hide whether it can follow a skill at all.

Naming the path is what makes the skill reachable, for both foreign executors. Neither
harness puts a skill's body in the model's context: `--skill` registers only the skill's
name and description, exactly as `.agents/skills` discovery does for codex (measured
2026-09-19 — a pi worker given `--skill` listed both probe skills by name and answered
`UNKNOWN` for a passphrase written in their bodies, then read both files and answered
correctly the moment the handoff named their paths). So a worker that is not told to open
the file has seen a one-line description and nothing else.

Require **proof of reading** in the return format: the worker quotes one verbatim line from
each required skill file — its first heading, plus the heading of the section it acted on.
A worker that cannot produce the quotes did not read the skill, which turns a silent
skip into a visible one the report can state.

The `claude` handoff is unchanged: Claude Code workers have the `Skill` tool, and "run
/verify" above is sufficient.

Expect foreign workers to follow the **static half** of a verify skill. They may skip the part that
needs a device or an emulator. Measured 2026-09-19 (MenuLens session `21163bb7`): both codex
workers opened the architecture and verify skills as their first action and ran every Gradle
check in them, and neither ran `adb`, the emulator or Maestro — including for a phase whose
acceptance criterion was "sample recipes still render with a cleared database". When E2E
will run in Step 8, route every criterion tagged `[e2e]` to that worker and omit it from the
per-phase gate payload. When E2E will be skipped, name each tagged criterion explicitly in
its phase's gate-verify payload (SKILL.md Step 6) as a check the gate must perform itself. Do
not rely on the foreign worker's self-verify to have covered it.

## 5a.3 Execute each layer

Walk layers in topological order (5a.1). The resolved `executor:model` address determines
how each phase agent is spawned. Use the selected entry in
references/executors.md § "Executor entries" for its spawn command, model address syntax,
stop mechanism, token extraction, and any one-time setup. With `PHASE_EXECUTOR` unset, use
the `claude` entry: the Agent-tool `run_in_background: true` spawn remains the default path.

The worktree-ownership rule and the destructive-git prohibition in the handoff (5a.2) apply
identically to every executor — they are properties of the handoff, not the harness.

**Single-phase layer (the common case — unchanged from sequential):**
1. Spawn the phase agent in the integration worktree (background; 5b guard applies).
2. On return, review the summary including the agent's self-verify result.
3. Delegate the authoritative gate-verify (Step 6) — independent, even if the agent
   self-reported pass.
4. Gate pass → IMMEDIATELY check off the phase (Step 7), retain only the return facts that
   a direct dependent needs under 5a.2's compact carry-forward rule, and advance. Do not
   batch checkbox updates — write after each phase.

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
   passes — check off ALL phases in the group (Step 7), retain only each member's facts
   needed by a direct dependent under 5a.2's compact carry-forward rule, then clean up
   (5a.4) and advance to the next layer.
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
