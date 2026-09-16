# Runtime Bindings

> Reference for `implement-plan` orchestrators. Do **not** edit this file in a
> running session — it is a static binding document authored once per host and
> updated only when a new host probe runs (see *Adding a host* below).
>
> Sources: Claude Code defaults from current toolset.

---

## Host Detection

The orchestrator resolves its host at **Step 0.5** (before any other work):

1. **Explicit override wins.** If the env var `HOST_RUNTIME` is set to a known
   host name (`claude-code`), use it and skip toolset inspection.
   Any other value is a hard error — fail loudly: `"Unknown HOST_RUNTIME '<value>' — valid: claude-code. Halt."`.

2. **Toolset inspection (fallback).** When `HOST_RUNTIME` is absent, inspect the
   available tool list:
   - `Agent` tool present → `claude-code`
   - Neither → ambiguous; fail loudly:
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

| Capability | Claude Code |
|---|---|
| `SPAWN_WORKER` | `Agent` tool — prompt payload, model pinned at call time |
| `STOP_WORKER` | `TaskStop` tool — first-class cancellation primitive |
| `PACE` | Both halves available: `Agent` tool spawns workers **in the background**, so parallel groups execute concurrently *and* control returns to the orchestrator mid-flight (timed check-ins on a running worker) |
| `TOKEN_ACCOUNTING` | Per-subagent token and cost data available from sub-agent return payload and tool introspection |
| `VERIFY` | `/verify` skill invoked in sub-agent context via `Skill` tool |
| `WORKTREE_CREATE` | `/create-worktree` skill delegated by orchestrator; `Skill` tool invocation |
| `NOTIFY` | `/notify-me` skill or `Skill` tool invocation for OS-level notifications |
| `PATH_SCOPE` | Unrestricted — a worker's tool calls may target any path the session can reach (a headless launch makes an extra root explicit with `--add-dir <path>`); no constraint on worktree placement |
| `REVIEW` | Review sub-agent spawned via `Agent` tool, model pinned at call time (deep tier, family-diverse from implementer) |

---

## Session Root Constraint (`PATH_SCOPE`)

**Normative. Checked at Step 0.5, before any worker is spawned.**

Where a host's `PATH_SCOPE` is **restricted to a session root**, that root must contain
the **parent of the project repository** — the workspace directory that holds the project
*and* its sibling worktrees. If the constraint is not satisfied, halt with a host-specific
message directing the user to relaunch with an adequate root. Where the project repository
is not yet unambiguous at Step 0.5, carry the check to Step 3 and run it before
`WORKTREE_CREATE` is delegated. Hosts whose `PATH_SCOPE` is unrestricted (claude-code)
skip this check entirely.

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

Where a host's `PACE` binding shows either half unavailable, all parallel groups demote
to sequential — one phase at a time. Two distinct things must not be conflated:

- *Parallel execution* — can two sibling workers run concurrently? Must be confirmed
  empirically for each host, not just documented.
- *Backgrounding / pacing* — does control return to the orchestrator **while** a worker
  runs, so it can check in on one mid-flight? The 5b runaway guard depends on this.
  Without backgrounding the orchestrator cannot observe an in-flight group at all, and
  without `STOP_WORKER` it cannot stop a runaway — a concurrent group would run entirely
  unsupervised. Unsupervisable concurrency is a worse trade than sequential execution.
  Flipping the binding requires a backgrounding primitive (or an equivalent way to observe
  and cancel an in-flight worker) — more concurrency evidence alone is not sufficient.

Any parallel demotion is disclosed at Step 2 and noted in the
Step 10 `Runtime & Models` report section.

---

## Disclosure Requirement Wiring

### Step 2 — Pre-work Disclosure

Before any phase work starts the orchestrator MUST emit a disclosure block. Its
content depends on the detected host:

```
Runtime: <host>
Models: <role> → <tier> / <model>, …   (one line per role, from model-routing.md)
Session root: <path>                   (restricted-`PATH_SCOPE` hosts only; verified at Step 0.5)
Degraded capabilities on this host:
  - <capability>: <consequence>        (one line per unavailable cell)
  (none)                               ← if all capabilities are available
```

For `claude-code`, no degradations exist in the current binding table.

`PATH_SCOPE` is **not** listed as a degradation on any host: where it is restricted it is a
precondition that Step 0.5 has already verified (or halted on), so by the time the
disclosure is emitted the session root is known to be adequate. State it as a fact instead,
one line under the model list: `Session root: <path> (contains the project and its
worktrees)`.

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
```

**Models: report what actually ran (never the routing table).** Every model id in this
section MUST be the model that actually served that role, sourced from the orchestrator's
own spawn records (the tier + model it recorded per phase at `phase-execution.md` 5a.2)
and, where the host exposes it, cross-checked against `TOKEN_ACCOUNTING`. Do **not**
transcribe `model-routing.md`: that file states the *configured* default, and a report
echoing it can never reveal an override or a substitution — which is the only situation in
which the audit matters, and the reason this section exists. Where actual and configured
differ, report both: `Phase 3 (light): <actual-model-id> (configured: <routed-model-id>)`.
Where the actual model genuinely cannot be recovered, write `unknown (configured: <model-id>)`
— never fill the gap from the table.

**Cost: measured or absent, never estimated.** The `Cost:` figure MUST come from
`TOKEN_ACCOUNTING` for this run and from nothing else — on claude-code, the sum of the
per-subagent session costs reported on completion. If `TOKEN_ACCOUNTING` is unavailable,
emit `"token accounting unavailable on this host"` and no figure. If it covers only part
of the run, report the measured part, name what it covers, and say the rest is unmeasured
(e.g. `$0.57 measured across 10 sessions; orchestrator turns after this report not
included`). Do **not** derive a figure from token counts, model prices, elapsed time, or a
previous run, and never round an estimate into the slot: an unqueried figure has been wrong
by 13x in practice, and a fabricated number in a spend report is worse than no number.

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

1. **Probe its primitives** (Stage 1a shape) → a `<host>-host-primitives` research note (q-skills-vault `Notes/`)

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
   - Headless permission behavior — is there a no-interaction headless mode where every
     permission prompt is auto-denied?
   - Billing model — metered, flat-rate, or free? What are the rate limits?

2. **Bake off its model catalog** (Stage 1b shape) → a `<host>-model-bakeoff` research note (q-skills-vault `Notes/`)

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
