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
| `SPAWN_WORKER` | `Agent` tool — prompt payload, model pinned at call time | Named subagent in `opencode.jsonc` under `agent.<name>` with `"mode": "subagent"`, `"model": "opencode-go/<id>"`; orchestrator invokes by name (`@<name>`); config model wins over parent inheritance (no dynamic call-time override verified) |
| `STOP_WORKER` | `TaskStop` tool — first-class cancellation primitive | **unavailable as a tool** → REST `POST /session/:id/abort` exists but port and child-session-id are unknowns from within a running skill; degradation: post-hoc token ceiling only — a runaway subagent burns to completion before the ceiling stops its successor |
| `PACE` | `Agent` tool allows multiple parallel spawns; parallel groups run concurrently | **documented** but **empirically sequential** across all 14 observed sessions — no `run_in_background` / `async_prompt` equivalent on the `task` tool; degradation: demote all parallel groups to sequential; one phase at a time |
| `TOKEN_ACCOUNTING` | Per-subagent token and cost data available from sub-agent return payload and tool introspection | Per-session rows in opencode SQLite DB (`~/.local/share/opencode/opencode.db`) — fields: `cost REAL`, `tokens_input`, `tokens_output`, `tokens_reasoning`, `tokens_cache_read`, `tokens_cache_write`; queryable via `opencode db "SELECT ..."` or `opencode export <sessionID>`; `cost` is equivalent retail value (not actual charge) against flat-rate $60/mo cap |
| `VERIFY` | `/verify` skill invoked in sub-agent context via `Skill` tool | `/verify` skill invoked via `skill` tool; global `skills.paths` visible to all subagents; **warning**: a project-local `opencode.jsonc` with `skills.paths` OVERRIDES global config (not merged) — consumer must register `/verify` in auto-discovered paths (`.opencode/skills/`, `.claude/skills/`, `.agents/skills/`, or global `~/.config/opencode/skills/`) or include both skill-repo paths AND their own path in a merged `skills.paths` list |
| `WORKTREE_CREATE` | `/create-worktree` skill delegated by orchestrator; `Skill` tool invocation | `/create-worktree` skill via `skill` tool; requires `bash` + `git` (available on opencode `build` agent by default); same delegation pattern; subject to the same `skills.paths` visibility as `VERIFY` |
| `NOTIFY` | `/notify-me` skill or `Skill` tool invocation for OS-level notifications | `/notify-me` skill via `skill` tool; skill is registered in global `skills.paths` and visible from all subagents; falls back to `bash`-level notifier if skill unavailable; subject to same `skills.paths` visibility rules |
| `REVIEW` | Review sub-agent spawned via `Agent` tool, model pinned at call time (deep tier, family-diverse from implementer) | Named `review` subagent in `opencode.jsonc` (`"mode": "subagent"`, deep-tier model, family-diverse from implementer per diversity rule); same `/review` skill via `skill` tool; see `model-routing.md` for family assignments |

---

## Parallel-Group Availability

Sourced from Stage 1a Q2 findings.

| Host | Status | Effective behavior |
|---|---|---|
| `claude-code` | Full parallel support | Independent phases in the dependency graph run as concurrent sub-agents in isolated child worktrees; merged back in declared order |
| `opencode` | **Demote to sequential** | All parallel groups are run sequentially — one phase at a time — regardless of declared independence; worktree-per-phase ownership contract is unaffected; the orchestrator's dependency graph is still computed and respected (order within a group becomes arbitrary but stable) |

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

Only include the cost line for the active host. If token data is unavailable,
emit `"token accounting unavailable on this host"`.

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
     (not just documented)?
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
   document — no assumptions. Update the *Parallel-Group Availability* table.
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
