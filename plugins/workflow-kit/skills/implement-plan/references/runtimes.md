# Runtime Bindings

> Reference for `implement-plan` orchestrators. Do **not** edit this file in a
> running session — it is a static binding document authored once per host and
> updated only when a new host probe runs (see *Adding a host* below).
>
> Sources: Stage 1a probe (`docs/research/opencode-host-primitives.md`, 2026-08-25);
> Claude Code defaults from current toolset.

---

## Host Detection

The orchestrator resolves its host at **Step 0.5** (before any other work):

1. **Explicit override wins.** If the env var `HOST_RUNTIME` is set to a known
   host name (`claude-code` or `opencode`), use it and skip toolset inspection.
   Any other value is a hard error — fail loudly: `"Unknown HOST_RUNTIME '<value>' — valid: claude-code | opencode. Halt."`.

2. **Toolset inspection (fallback).** When `HOST_RUNTIME` is absent, inspect the
   available tool list:
   - `Agent` tool present → `claude-code`
   - `task` tool present (and `Agent` absent) → `opencode`
   - Neither or both → ambiguous; fail loudly:
     `"Cannot detect host runtime from toolset — set HOST_RUNTIME explicitly. Halt."`

3. **Verify binding table entry exists.** After resolving the host name, confirm
   a column exists in this file. If not, fail loudly with the host name and
   "no column in runtimes.md — see 'Adding a host'."

The host name is logged at Step 2 (disclosure) and Step 10 (report). Wrong
detection fails the run before any code is written — the cost of silent
mismatch is greater than the cost of a user restart with `HOST_RUNTIME` set.

---

## Capability Binding Table

Each row is a named **capability** the SKILL.md workflow calls by name. Each
cell is either the **native binding** (tool name, config pattern, or mechanism)
or `unavailable → consequence` (what the run does instead, and what the user
is told at Step 2 disclosure).

| Capability | Claude Code | opencode |
|---|---|---|
| `SPAWN_WORKER` | `Agent` tool — prompt payload, model pinned at call time | Named subagent in `opencode.jsonc` under `agent.<name>` with `"mode": "subagent"`, `"model": "opencode-go/<id>"`; orchestrator invokes by name (`@<name>`); config model wins over parent inheritance (no dynamic call-time override verified); every tool call a spawned worker makes is confined to the session root — see *Session Root Constraint* below |
| `STOP_WORKER` | `TaskStop` tool — first-class cancellation primitive | **unavailable as a tool** → REST `POST /session/:id/abort` exists but port and child-session-id are unknowns from within a running skill; degradation: post-hoc token ceiling only — a runaway subagent burns to completion before the ceiling stops its successor |
| `PACE` | Both halves available: `Agent` tool spawns workers **in the background**, so parallel groups execute concurrently *and* control returns to the orchestrator mid-flight (timed check-ins on a running worker) | Split verdict. *Parallel execution*: **available** — two sibling subagents were measured running concurrently (5.86 s overlap, both rendered in-flight by the CLI). *Backgrounding / pacing*: **unavailable** — the `task` tool has no `run_in_background` / `async_prompt` equivalent and there is no within-skill timed-wakeup primitive, so control never returns to the orchestrator while a worker runs. `PACE` gates both and the backgrounding half is missing, so the binding stays conservative; degradation: demote all parallel groups to sequential; one phase at a time (rationale under *Parallel-Group Availability*) |
| `TOKEN_ACCOUNTING` | Per-subagent token and cost data available from sub-agent return payload and tool introspection | Per-session rows in opencode SQLite DB (`~/.local/share/opencode/opencode.db`) — fields: `cost REAL`, `tokens_input`, `tokens_output`, `tokens_reasoning`, `tokens_cache_read`, `tokens_cache_write`; queryable via `opencode db "SELECT ..."` or `opencode export <sessionID>`; `cost` is equivalent retail value (not actual charge) against flat-rate $60/mo cap |
| `VERIFY` | `/verify` skill invoked in sub-agent context via `Skill` tool | `/verify` skill invoked via `skill` tool; global `skills.paths` visible to all subagents; **warning**: a project-local `opencode.jsonc` with `skills.paths` OVERRIDES global config (not merged) — consumer must register `/verify` in auto-discovered paths (`.opencode/skills/`, `.claude/skills/`, `.agents/skills/`, or global `~/.config/opencode/skills/`) or include both skill-repo paths AND their own path in a merged `skills.paths` list |
| `WORKTREE_CREATE` | `/create-worktree` skill delegated by orchestrator; `Skill` tool invocation | `/create-worktree` skill via `skill` tool; requires `bash` + `git` (available on opencode `build` agent by default); same delegation pattern; subject to the same `skills.paths` visibility as `VERIFY`; worktree **placement** is unchanged (integration worktree is a sibling of the project repo) — the *session root*, not the worktree, is what must accommodate this host: see *Session Root Constraint* |
| `NOTIFY` | `/notify-me` skill or `Skill` tool invocation for OS-level notifications | `/notify-me` skill via `skill` tool; skill is registered in global `skills.paths` and visible from all subagents; falls back to `bash`-level notifier if skill unavailable; subject to same `skills.paths` visibility rules |
| `PATH_SCOPE` | Unrestricted — a worker's tool calls may target any path the session can reach (a headless launch makes an extra root explicit with `--add-dir <path>`); no constraint on worktree placement | **Restricted to the session root** (the directory passed as `--dir`). A subagent tool call targeting a path outside that root never completes: no error, no permission prompt, no timeout, even under `--auto` — the call sits at `status: running` indefinitely. This is not a degradation but a **precondition** — see *Session Root Constraint* |
| `REVIEW` | Review sub-agent spawned via `Agent` tool, model pinned at call time (deep tier, family-diverse from implementer) | Named `review` subagent in `opencode.jsonc` (`"mode": "subagent"`, deep-tier model, family-diverse from implementer per diversity rule); same `/review` skill via `skill` tool; see `model-routing.md` for family assignments |

---

## Session Root Constraint (`PATH_SCOPE`)

**Normative. Checked at Step 0.5, before any worker is spawned.**

Where a host's `PATH_SCOPE` is **restricted to a session root**, every path this workflow
touches — the project repository, the integration worktree, and every child worktree —
MUST lie inside that root. A worker pointed outside it does not fail cleanly: on opencode
its first tool call hangs at `status: running` forever, with no error, no prompt and no
timeout, and `STOP_WORKER` is unavailable on that host to cancel it. The orchestrator can
neither detect nor recover from that state, which is why this is a **precondition rather
than a degradation**: an unsatisfied root halts the run at Step 0.5 instead of deadlocking
it at the first phase.

**The rule (opencode).** The session root passed at launch (`--dir`) MUST be a directory
that contains the **parent of the project repository** — the workspace directory that
holds the project *and* its sibling worktrees:

```
<session root>/          ← opencode launched with --dir pointing here
  project/               ← the git repo the plan lives in
  project-<feature>/     ← integration worktree (sibling of the repo, from /create-worktree)
  .wt/<phase-slug>/      ← child worktrees for a parallel group (siblings of integration)
```

The consumer-facing form of this rule is in the project README's opencode section; a
project-local `opencode.jsonc` should sit at the session root so it applies to the session.

**Step 0.5 check.** Resolve the project's git toplevel and confirm its **parent directory**
is at or inside the session root. If it is not, halt with:

```
Session root does not contain the project's worktree parent — this host confines every
worker tool call to the session root, and implement-plan's worktrees are siblings of the
project repo. Relaunch with the session root set to the directory containing both
(opencode: `--dir <parent-of-project>`). Halt.
```

Where the project repository is not yet unambiguous at Step 0.5 (the plan path arrives at
Step 1), carry the check to Step 3 and run it there — it MUST pass before `WORKTREE_CREATE`
is delegated and before any worker is spawned. Re-confirm after the worktree is created that
it too lies inside the root.

Hosts whose `PATH_SCOPE` is unrestricted (claude-code) skip this check entirely.

**Why the session root moves and the worktrees do not.** The alternative shape — nesting
the integration and child worktrees inside the project repo so they fall within a narrower
session root — was considered and rejected. Worktree placement is load-bearing for reasons
that have nothing to do with the host: child worktrees are siblings of integration so the
integration build and gate-verify never traverse in-flight child files
(`phase-execution.md` 5a.3), and the integration worktree is a sibling of the repo so the
project's own tooling never walks it. Nesting to satisfy one host would break those
guarantees on **every** host, and would additionally override the consumer-owned
`/create-worktree` strategy that Step 3 deliberately delegates. Moving the session root up
one level satisfies the restricted host with no change to the worktree contract, and costs
the consumer exactly one launch flag.

---

## Parallel-Group Availability

| Host | Status | Effective behavior |
|---|---|---|
| `claude-code` | Full parallel support | Independent phases in the dependency graph run as concurrent sub-agents in isolated child worktrees; merged back in declared order |
| `opencode` | **Demote to sequential** (deliberate, conservative — not a capability floor) | All parallel groups are run sequentially — one phase at a time — regardless of declared independence; worktree-per-phase ownership contract is unaffected; the orchestrator's dependency graph is still computed and respected (order within a group becomes arbitrary but stable) |

**Why opencode demotes even though sibling workers can run concurrently.** Two distinct
things must not be conflated:

- *Parallel execution* — can two sibling subagents run at the same time? On opencode:
  **yes**, measured. A purpose-built canary produced two overlapping child sessions
  (`phase-light` and `phase-alt`, 5.86 s of overlap), and the CLI rendered both in flight.
- *Backgrounding / pacing* — does control return to the orchestrator **while** a worker
  runs, so it can check in on one mid-flight? On opencode: **no** evidence of any such
  primitive; the `task` tool blocks until the child returns.

The 5b runaway guard is built on the second. Without backgrounding the orchestrator cannot
observe an in-flight group at all, and with `STOP_WORKER` also unavailable it could not
stop a runaway even if it noticed one — a concurrent group on this host would run entirely
unsupervised. Unsupervisable concurrency is a worse trade than sequential execution, so the
binding stays sequential. This is a priced choice, not an unknown: sequential execution
measured ~52 % more wall clock than the same plan's parallel run on claude-code. Flipping
the binding requires a backgrounding primitive (or an equivalent way to observe and cancel
an in-flight worker) — more concurrency evidence alone is not sufficient.

The parallel demotion on opencode is disclosed at Step 2 and noted in the
Step 10 `Runtime & Models` report section.

---

## Disclosure Requirement Wiring

### Step 2 — Pre-work Disclosure

Before any phase work starts the orchestrator MUST emit a disclosure block. Its
content depends on the detected host:

```
Runtime: <host>
Models: <role> → <model or tier alias>, …  (one line per role, from model-routing.md)
Degraded capabilities on this host:
  - <capability>: <consequence>  (one line per unavailable cell in the table above)
  (none)  ← if all capabilities are available
```

For `opencode`, the following degradations MUST appear in the disclosure:

- `STOP_WORKER`: Runaway guard is post-hoc only — a runaway subagent will burn to
  completion before the token ceiling stops it from continuing.
- `PACE`: Parallel phase groups are demoted to sequential — phases run one at a time.

For `claude-code`, no degradations exist in the current binding table.

`PATH_SCOPE` is **not** listed as a degradation on any host: where it is restricted it is a
precondition that Step 0.5 has already verified (or halted on), so by the time the
disclosure is emitted the session root is known to be adequate. State it as a fact instead,
one line under the model list: `Session root: <path> (contains the project and its
worktrees)`.

If the consumer has a local `opencode.jsonc` with `skills.paths`, add:

- `VERIFY` / `WORKTREE_CREATE` / `NOTIFY`: Local `skills.paths` in project
  `opencode.jsonc` overrides global config. Confirm `/verify`, `/create-worktree`,
  and `/notify-me` are reachable before proceeding.

### Step 10 — Runtime & Models Report Section

The Step 10 summary MUST include a `Runtime & Models` section:

```
## Runtime & Models

Host: <host>
Orchestrator: <model-id>
Per-phase models:
  Phase <N> (<tier>): <model-id>
  …
Gate-verify: <model-id>
Review: <model-id>
Degradations active: <list from Step 2, or "none">
Cost:
  Claude Code — metered spend: $<total> (sum of per-subagent session costs)
  opencode    — equivalent consumed: $<sum of cost column in DB> of $60/mo cap (flat-rate, not billed)
```

Only include the cost line for the active host.

**Models: report what actually ran (never the routing table).** Every model id in this
section MUST be the model that actually served that role, sourced from the orchestrator's
own spawn records (the tier + model it recorded per phase at `phase-execution.md` 5a.2)
and, where the host exposes it, cross-checked against `TOKEN_ACCOUNTING` (on opencode the
per-session DB rows carry the model that served each child session). Do **not** transcribe
`model-routing.md`: that file states the *configured* default, and a report echoing it can
never reveal an override or a substitution — which is the only situation in which the audit
matters, and the reason this section exists. Where actual and configured differ, report
both: `Phase 3 (light): <actual-model-id> (configured: <routed-model-id>)`. Where the actual
model genuinely cannot be recovered, write `unknown (configured: <model-id>)` — never fill
the gap from the table.

**Cost: measured or absent, never estimated.** The `Cost:` figure MUST come from
`TOKEN_ACCOUNTING` for this run and from nothing else — on opencode, `SUM(cost)` over this
run's session rows in the DB; on claude-code, the sum of the per-subagent session costs
reported on completion. If `TOKEN_ACCOUNTING` is unavailable, emit
`"token accounting unavailable on this host"` and no figure. If it covers only part of the
run, report the measured part, name what it covers, and say the rest is unmeasured (e.g.
`$0.57 measured across 10 sessions; orchestrator turns after this report not included`).
Do **not** derive a figure from token counts, model prices, elapsed time, or a previous
run, and never round an estimate into the slot: an unqueried figure has been wrong by 13x
in practice, and a fabricated number in a spend report is worse than no number.

---

## Adding a Host

This section is the normative checklist for extending `implement-plan` to a new
harness. Adding a host **never touches SKILL.md or the existing workflow reference
files** — it adds columns and runs the empirical passes.

### Capability Floor — check before anything else

A harness must satisfy all of the following non-degradable requirements to be
bindable. If any fail, stop — the skill cannot run on this harness without
porting work beyond a binding:

- [ ] Loads markdown skills in SKILL.md format (e.g. via a `skills.paths`-like
      mechanism or a compatible extension format)
- [ ] Subagent spawn with a prompt payload (no subagents = no orchestrator pattern)
- [ ] Shell access (`bash` or equivalent), file editing, and `git`
- [ ] A worker path scope that can be made to contain the project repository **and** its
      sibling worktrees — if worker tool calls are confined to a root, the consumer must be
      able to set that root at launch (see *Session Root Constraint*)

The following are **degradable** — their absence reduces capability but does not
block a run (the disclosure pattern handles it at Step 2):

- Parallelism — absent → `PACE` demotes to sequential
- Cancellation — absent → `STOP_WORKER` degrades to post-hoc ceiling only
- Token accounting — absent → `TOKEN_ACCOUNTING` unavailable; cost line omitted
- Per-spawn model pinning — absent → all tiers collapse to one model; routing layer
  is inert but the skill runs; note in Step 2 disclosure

### Per-Host Checklist

Run these in order. Each step produces a recorded-findings document before the
next step begins:

1. **Probe its primitives** (Stage 1a shape) → `docs/research/<host>-host-primitives.md`

   Answer each of these questions with yes/no + evidence and a degradation path
   for any "no":
   - Native subagent spawn — is there a first-class spawn mechanism with a prompt
     payload?
   - Per-spawn model pinning — can the spawning call pin a model at call time, or
     is static named-config the only mechanism?
   - Parallelism — are parallel subagent runs possible and empirically confirmed
     (not just documented)? Answer the two halves separately: can siblings *execute*
     concurrently, and is there a *backgrounding* primitive that returns control to the
     orchestrator mid-flight (which the 5b guard needs)? One without the other is not
     `PACE`.
   - Path scope — are a worker's tool calls confined to a root (session dir, sandbox,
     allowlist)? What happens to a call outside it: an error, a prompt, or a silent hang?
     Can the consumer widen the root at launch? A host that hangs silently needs a Step 0.5
     precondition, not a degradation.
   - Cancellation — is there a first-class cancel/abort primitive reachable from
     within a running agent? If only via REST/external, is the session ID and
     server address knowable?
   - Per-subagent token totals — can the orchestrator retrieve per-child token and
     cost data?
   - Skill visibility — do subagents see the same skill registry as the primary
     agent? Are there override/precedence traps?
   - Headless permission behavior — is there a no-interaction mode equivalent to
     `--auto` + `question:deny`?
   - Billing model — metered, flat-rate, or free? What are the rate limits?

2. **Bake off its model catalog** (Stage 1b shape) → `docs/research/<host>-model-bakeoff.md`

   Three canaries (coding, tool-discipline, fidelity) on the models available on
   this host. Record per-role defaults + family groupings for the diversity rule.
   Confirm model address syntax. Record which models are reachable (test each
   before including in the bake-off).

3. **Add its column to `runtimes.md`** (this file)

   For every capability in the table, add a cell with either the native binding
   or `unavailable → consequence`. Source every cell from the Step 1 probe
   document — no assumptions. Update the *Parallel-Group Availability* table, and the
   *Session Root Constraint* section if the host restricts `PATH_SCOPE`.
   Add any host-specific degradations to the *Disclosure Requirement Wiring*
   section.

4. **Add its column to `model-routing.md`**

   Replace bake-off hypotheses with measured per-role defaults. Record family
   groupings. Verify the diversity rule is satisfiable (at least two distinct
   families in the catalog for the verifier/reviewer vs implementer split).

5. **Update host detection** in the *Host Detection* section above

   Add the new host's toolset signature (the tool or env-var pattern that
   identifies it). If toolset inspection is ambiguous, require `HOST_RUNTIME`
   for that host and document it here.

6. **Run the Stage 5 validation script against the new host** — and against all
   existing hosts as a regression run. Three runs minimum: regression on each
   existing host, new-path on the new host, forced-failure + manual rescue on the
   new host.

   Any failure is a binding gap — fix the binding document and re-run. Do not
   patch findings inline to make a run pass.

---

*End of runtimes.md*
