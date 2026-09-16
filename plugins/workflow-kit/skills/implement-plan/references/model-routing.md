# Model Routing Reference

> Per-role model map, diversity rule, escalation ladder, and config surface
> for `implement-plan`.

---

## Routing Table

| Role | Tier | Claude Code |
|---|---|---|
| Orchestrator | deep | `opus` |
| Prep parse | standard | `sonnet` |
| Phase — mechanical | light | `haiku` |
| Phase — normal | standard | `sonnet` |
| Phase — complex | deep | `opus` |
| Gate-verify (exit-code) | light | `haiku` |
| Gate-verify (behavioral) | standard | `sonnet` |
| Review | deep | `opus` |
| Fix | standard | `sonnet` |
| Escalation rung 1 | deep | `opus` |

---

## Four Principles (Normative)

These are requirements, not guidelines. The skill enforces them; overrides that violate them
must be treated as misconfiguration.

1. **Tool-call discipline outranks raw capability** for orchestrator and gate roles. A model
   that fumbles sequential tool calls stalls the pipeline; a disciplined mediocre model writes
   mediocre code the gate catches. The bake-off C2 canary (10 sequential tool calls, 0 retries
   = pass) is the measurement basis for these roles.

2. **Diversity rule** (where the host's catalog has more than one model family): gate-verify
   and review must use a **different model family** than the implementer they check.
   Escalation rung 1 switches family from the failed implementer.
   Minimum: different company/training lineage (within-cluster diversity). This rule exists
   because same-family models share blind spots.

3. **Tier choice follows the host's billing model.** On metered hosts, tiers save real money
   — the usual frugality applies. On flat-rate hosts, tiers exist for latency management only
   and the token-frugality calculus is reversed — **never pick a weaker model to save
   unmetered tokens.** Claude Code is metered.

4. **Unknown model ids error loudly, never substitute.** The catalog drifts. When a configured
   model id is not recognized by the host, the skill must halt with an explicit error naming
   the unknown id. Silent fallback to any other model is forbidden — it masks misconfiguration
   and produces unaccountable routing.

---

## Escalation Ladder

### Rung 1 — Within-host, family switch (automatic)

Triggered when: gate-verify fails all `SELF_VERIFY_LIMIT` attempts for a phase.

Action: re-run the failed phase at deep tier with a different model family than the
implementer that failed. Payload includes full failure history with verbatim error messages
and a "diagnose root cause before fixing" instruction. Budget: `ESCALATION_TOKEN_CEILING`
(default 400k) and `ESCALATION_TIME_BUDGET` (default 30 min). Capped at
`ESCALATION_ATTEMPTS` (default 2 rung-1 attempts before rung 2).

**Claude Code:** escalation always uses `opus` (there is only one deep-tier model family on
Claude Code; no family-switch is possible, but `opus` re-run with richer payload and extended
budget is still rung 1).

### Rung 2 — Manual resume (user action required)

Triggered when: rung 1 exhausts `ESCALATION_ATTEMPTS` without clearing the gate.

Action: emit a `HALTED` report. On a host other than Claude Code, the HALTED report must
additionally include a **"Resume in Claude Code" block** with:
- Worktree path (absolute)
- Failed phase name and description
- Models run at rung 1 and their families (for the user's context)
- Verbatim relaunch instruction: "Open this worktree in Claude Code and run `/implement-plan`
  to continue from this phase with full Claude Code capabilities."

On Claude Code, the HALTED report is emitted as-is — no rescue block is appended (the run
is already on Claude Code).

Rationale: automatic cross-harness escalation was evaluated and dropped — it requires
resurrecting the subprocess bridge for a path that fires rarely, and manual user-wait matches
the existing flow. The HALTED + "Resume in Claude Code" pattern is the correct escalation
boundary.

---

## Config Surface

### Environment Variables / CLAUDE.md Overrides

| Variable | Default (Claude Code) | Description |
|---|---|---|
| `ORCHESTRATOR_MODEL` | `opus` | Orchestrator model |
| `PREP_MODEL` | `sonnet` | Prep-parse model (Step 1) |
| `PHASE_MODEL_LIGHT` | `haiku` | Mechanical-tier phase model |
| `PHASE_MODEL_STANDARD` | `sonnet` | Normal-tier phase model |
| `PHASE_MODEL_DEEP` | `opus` | Complex-tier phase model |
| `VERIFY_MODEL` | `haiku` (exit-code) / `sonnet` (behavioral) | Gate-verify models |
| `REVIEW_MODEL` | `opus` | Review model (Step 8) |
| `FIX_MODEL` | `sonnet` | Fix model (Step 8b) |
| `ESCALATION_LADDER` | `opus` | Rung-1 escalation model(s) |

### Tier Token Ceilings (unchanged)

`PHASE_TOKEN_CEILING` is keyed by tier. Values are the existing SKILL.md defaults and must
not be altered by this file.

| Tier | Claude Code model | Token ceiling |
|---|---|---|
| light | `haiku` | 80k |
| standard | `sonnet` | 150k |
| deep | `opus` | 250k |

Escalation ceiling (`ESCALATION_TOKEN_CEILING`): 400k (default, unchanged).

### Deprecated Aliases

These names are accepted for backward compatibility but emit a deprecation warning on load.
New configuration must use the canonical names.

| Deprecated alias | Canonical replacement | Notes |
|---|---|---|
| `PREP_AGENT_MODEL` | `PREP_MODEL` | Renamed for vocabulary consistency |
| `VERIFY_AGENT_MODEL` | `VERIFY_MODEL` | Renamed for vocabulary consistency |

Both aliases will be removed in a future major version. Projects using them should migrate
before upgrading past v3.x.

### Loud-Failure Rule

> **Unknown model ids error loudly, never substitute.**

If any configured model id (default or override) is not recognized by the host at Step 0.5:

1. Halt immediately — do not attempt any phase work.
2. Emit an explicit error naming the unknown id, the role it was assigned to, and the host.
3. Do not fall back silently to any other model.

The catalog drifts. When a bake-off-governed default is removed from the catalog, the skill
surfaces it immediately so the operator can re-run the bake-off and update the routing
table, rather than discovering silent degradation mid-run.

---

## Adding a Host

When a new harness is added to `runtimes.md`, this file gains a new column. Required steps:

1. Run the Stage 1b bake-off shape against the new host's model catalog.
2. Record per-role recommendations and family groupings in the bake-off findings doc.
3. Add the host column to the routing table above (mark it bake-off-governed with a citation).
4. Add the host's defaults to the Config Surface table.
5. Verify the diversity rule is satisfied for the new host's default pairing.

The SKILL.md tier vocabulary and capability names remain unchanged — only this file and
`runtimes.md` gain new columns. If the new host's `SPAWN_WORKER` binding requires static
named agents, add a corresponding normative agent-name registry section here.
