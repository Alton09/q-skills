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
the phase's tasks and map to a model for the active executor (`PHASE_EXECUTOR`, default
`claude`).

**`claude` executor** — map to the Agent tool's `model` parameter:

| Phase character | Agent `model` |
|---|---|
| Mechanical/boilerplate (wiring, renames, simple CRUD, test scaffolds) | `haiku` |
| Normal feature work (typical layer impl, standard tests) | `sonnet` |
| Complex/novel (tricky algorithms, cross-cutting design, ambiguous tasks) | `opus` |

The values are the literal `model` enum tokens — pass them straight to the Agent tool.

**`pi` executor** — map to an `opencode-go` model string:

| Phase character (tier) | `--model` value |
|---|---|
| Mechanical/boilerplate (light) | `opencode-go/minimax-m3` |
| Normal feature work (standard) | `opencode-go/glm-5.3` |
| Complex/novel (deep) | `opencode-go/qwen3.8-max` |

The deep tier is `qwen3.8-max`, not Kimi K3. In the 2026-09-16 bake-off, Kimi K3 failed
C2 tool discipline: it stopped after 4 of 10 steps and reported the task done. Complex
phases are the longest multi-step work and end with `/verify`, so a premature stop with a
false completion claim costs most there. `qwen3.8-max` passed all three canaries and was
faster and cheaper than Kimi K3 on each.

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
`<consumer .claude/skills>/verify/SKILL.md`). Foreign workers have no `Skill` tool, and
description-triggered loading proved unreliable: on a 2026-09-18 run, pi workers never
opened the architecture skill in five phases that moved code between layers, and only two of
six opened `verify`.

Do **not** paste the commands a skill contains into the handoff — name the skill and let the
worker read it. Inlined commands make the worker follow the handoff instead of the skill, and
hide whether it can follow a skill at all.

The `claude` handoff is unchanged: Claude Code workers have the `Skill` tool, and "run
/verify" above is sufficient.

## 5a.3 Execute each layer

Walk layers in topological order (5a.1). `PHASE_EXECUTOR` (default `claude`) determines how
each phase agent is spawned.

**`claude` executor (default):** Every phase agent is spawned with the Agent tool
and `run_in_background: true` — this gives no live token/tool feed, but it buys two things
the orchestrator needs: it stays responsive instead of blocking (so it can run the 5b
wall-clock guard, and watch several agents at once), and each agent is cancellable via
`TaskStop`. The completion notification carries the agent's total token count and
duration, which feeds the 5b ceiling check.

**`pi` executor:** Spawn with `Bash(run_in_background: true)`:

```
cd <worktree> && setsid timeout <secs> pi -p --mode json --no-session \
  --model <provider/id> \
  --skill <consumer .claude/skills> \
  "$(cat <handoff-file>)" </dev/null \
  > <scratch>/<phase>.jsonl 2> <scratch>/<phase>.err & echo $! > <scratch>/<phase>.pid; wait $!
```

Every clause is load-bearing:

- `setsid` puts the worker in its own process group, so its PID is the group ID and
  `kill -TERM -- -<pid>` stops the real `pi` process, not only the wrapper
  (`references/runaway-guard.md` § Stop). Do not enable shell job control instead: it
  fails under the Bash tool's zsh `eval` and the worker never starts.
- `</dev/null` is **mandatory**. Without it pi never returns and emits nothing at all —
  measured on 2026-09-16: a backgrounded invocation produced 0 bytes on stdout and stderr
  and was killed at 180 s (rc=124). A worker that hangs silently is the one failure the
  orchestrator cannot diagnose from output.
- Pass the handoff via a file read into argv, never as a long inline argument — the 5a.2
  payload is large and argv quoting is fragile.
- `--skill` points at the consumer project's skill directory so the worker can run
  `/verify`. No symlink into `.agents/`, no edits to `~/.pi/agent/settings.json`.
- The worker's worktree is simply the process `cwd`. There is no session-root constraint,
  because the orchestrator is not the confined process.

The worktree-ownership rule and the destructive-git prohibition in the handoff (5a.2) apply
identically to both executors — they are properties of the handoff, not the harness.

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
