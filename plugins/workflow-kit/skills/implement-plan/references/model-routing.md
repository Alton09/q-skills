# Model Routing Reference

> Per-role model map, family groupings, diversity rule, escalation ladder, and config surface
> for `implement-plan`. Applies to both Claude Code and opencode hosts.
>
> opencode column: **bake-off-governed** — sourced from Stage 1b measured results
> (docs/research/model-bakeoff.md, 2026-08-25, opencode 1.18.18). Hypothesis column from the
> plan is superseded; this file is the authoritative record.

---

## Routing Table

| Role | Tier | Claude Code | opencode |
|---|---|---|---|
| Orchestrator | deep | `opus` | `qwen3.8-max` |
| Prep parse | standard | `sonnet` | `qwen3.7-plus` |
| Phase — mechanical | light | `haiku` | `minimax-m3` |
| Phase — normal | standard | `sonnet` | `glm-5.3` |
| Phase — complex | deep | `opus` | `kimi-k3` |
| Gate-verify (exit-code) | light | `haiku` | `qwen3.7-plus` |
| Gate-verify (behavioral) | standard | `sonnet` | `grok-4.6` |
| Review | deep | `opus` | `grok-4.6` |
| Fix | standard | `sonnet` | `glm-5.3` |
| Escalation rung 1 | deep | `opus` | `qwen3.8-max` if Kimi implementer failed; `kimi-k3` if Qwen implementer failed |

### Plan Hypothesis Overturned by Measurement

The plan hypothesized `kimi-k3` as orchestrator for the opencode host. Stage 1b bake-off
overturns this: kimi-k3 failed the tool-discipline canary (C2) with a premature stop after
4 of 10 sequential tool calls, with no retries — a disqualifying behavior for orchestrator
and gate roles where completing all required sequential steps is non-negotiable.

**qwen3.8-max** replaces kimi-k3 as orchestrator. **kimi-k3** is retained as the complex-phase
implementer, where batching tool calls in implementation context is acceptable and the gate
catches errors.

`deepseek-v4-flash` and `deepseek-v4-pro` were excluded from the bake-off and from this table:
both are unreachable on the opencode-go catalog without China-region opt-in (`deepseek-v4-flash`
returns an explicit error; `deepseek-v4-pro` silently produces 0 tokens). All 10 remaining
catalog models were successfully canary-tested.

---

## Four Principles (Normative)

These are requirements, not guidelines. The skill enforces them; overrides that violate them
must be treated as misconfiguration.

1. **Tool-call discipline outranks raw capability** for orchestrator and gate roles. A model
   that fumbles sequential tool calls stalls the pipeline; a disciplined mediocre model writes
   mediocre code the gate catches. The bake-off C2 canary (10 sequential tool calls, 0 retries
   = pass) is the measurement basis for these roles. kimi-k3's 4/10 failure is the direct
   evidence for this principle.

2. **Diversity rule** (where the host's catalog has more than one model family): gate-verify
   and review must use a **different model family** than the implementer they check.
   Escalation rung 1 switches family from the failed implementer.
   Minimum: different company/training lineage (within-cluster diversity). Preferred: cross-cluster
   (Chinese-family implementer + Western-family gate/review). This rule exists because
   same-family models share blind spots; cross-family checking is free on a flat-rate plan.

3. **Flat-rate changes tier economics:** inside opencode, tiers exist for latency management
   and the $60/month equivalent cap, not per-token cost. **Never pick a weaker model to "save"
   un-metered tokens.** On Claude Code, tiers save real money — the usual frugality applies.

4. **Unknown model ids error loudly, never substitute.** The catalog drifts. When a configured
   model id is not recognized by the host, the skill must halt with an explicit error naming
   the unknown id. Silent fallback to any other model is forbidden — it masks misconfiguration
   and produces unaccountable routing.

---

## Model Family Groupings

Required for the diversity rule. All models within one family share training lineage and must
be treated as a single unit for diversity purposes.

| Family | Models | Origin | Notes |
|---|---|---|---|
| **Kimi** | `kimi-k3`, `kimi-k2.7-code` | Moonshot AI (China) | Same company, same training lineage; treat as one family regardless of size |
| **GLM** | `glm-5.3` | Zhipu AI (China) | ChatGLM series; different company from Kimi/Qwen |
| **Qwen** | `qwen3.7-plus`, `qwen3.8-max`, `qwen3.7-max` | Alibaba (China) | Same Qwen3 series; treat all as one family regardless of size suffix |
| **MiniMax** | `minimax-m3` | MiniMax (China) | Independent company; distinct from other Chinese families |
| **MiMo** | `mimo-v2.5` | Research model (China) | Very low equivalent-cost; distinct lineage from above |
| **GPT** | `gpt-5.6-luna` | OpenAI lineage (Western) | Anomalous token_in reporting suggests provider-side caching; functional behavior correct in all canaries |
| **Grok** | `grok-4.6` | xAI (Western) | Fastest fidelity in catalog (14s); distinct Western lineage; maximally family-diverse from all Chinese-family implementers; grok-4.5 retired from catalog 2026-08 — replaced per catalog-drift rule; bake-off numbers are grok-4.5's |

### Diversity Pairing Reference

Default per-role map satisfies the diversity rule as follows:

| Implementer | Family | Gate-verify | Gate family | Gate-diverse? |
|---|---|---|---|---|
| Phase mechanical | MiniMax | Qwen (exit-code), Grok (behavioral) | Qwen, Grok | Yes |
| Phase normal | GLM | Qwen (exit-code), Grok (behavioral) | Qwen, Grok | Yes |
| Phase complex | Kimi | Qwen (exit-code), Grok (behavioral) | Qwen, Grok | Yes |

Review (Grok) is family-diverse from all three implementer families (Kimi, GLM, MiniMax).

---

## Escalation Ladder

### Rung 1 — Within-host, family switch (automatic)

Triggered when: gate-verify fails all `SELF_VERIFY_LIMIT` attempts for a phase.

Action: re-run the failed phase at deep tier with a different model family than the
implementer that failed. Payload includes full failure history with verbatim error messages
and a "diagnose root cause before fixing" instruction. Budget: `ESCALATION_TOKEN_CEILING`
(default 400k) and `ESCALATION_TIME_BUDGET` (default 30 min). Capped at
`ESCALATION_ATTEMPTS` (default 2 rung-1 attempts before rung 2).

**opencode-specific family-switch rule:**
- If the failed implementer was **Kimi family** (kimi-k3): escalation model is `qwen3.8-max`
- If the failed implementer was **Qwen family** (qwen3.8-max): escalation model is `kimi-k3`
- If the failed implementer was any other family: escalation model is `qwen3.8-max`

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

| Variable | Default (Claude Code) | Default (opencode) | Description |
|---|---|---|---|
| `ORCHESTRATOR_MODEL` | `opus` | `opencode-go/qwen3.8-max` | Orchestrator model |
| `PREP_MODEL` | `sonnet` | `opencode-go/qwen3.7-plus` | Prep-parse model (Step 1) |
| `PHASE_MODEL_LIGHT` | `haiku` | `opencode-go/minimax-m3` | Mechanical-tier phase model |
| `PHASE_MODEL_STANDARD` | `sonnet` | `opencode-go/glm-5.3` | Normal-tier phase model |
| `PHASE_MODEL_DEEP` | `opus` | `opencode-go/kimi-k3` | Complex-tier phase model |
| `VERIFY_MODEL` | `haiku` (exit-code) / `sonnet` (behavioral) | `opencode-go/qwen3.7-plus` / `opencode-go/grok-4.6` | Gate-verify models |
| `REVIEW_MODEL` | `opus` | `opencode-go/grok-4.6` | Review model (Step 8) |
| `FIX_MODEL` | `sonnet` | `opencode-go/glm-5.3` | Fix model (Step 8b) |
| `ESCALATION_LADDER` | `opus` | Family-switch rule above | Rung-1 escalation model(s) |

### Tier Token Ceilings (unchanged)

`PHASE_TOKEN_CEILING` is keyed by tier. Values are the existing SKILL.md defaults and must
not be altered by this file.

| Tier | Claude Code model | opencode model | Token ceiling |
|---|---|---|---|
| light | `haiku` | `minimax-m3` | 80k |
| standard | `sonnet` | `glm-5.3` | 150k |
| deep | `opus` | `kimi-k3` / `qwen3.8-max` | 250k |

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

The catalog drifts between opencode releases. When a bake-off-governed default is removed
from the catalog, the skill surfaces it immediately so the operator can re-run the bake-off
and update the routing table, rather than discovering silent degradation mid-run.

---

## Adding a Host

When a new harness is added to `runtimes.md`, this file gains a new column. Required steps:

1. Run the Stage 1b bake-off shape against the new host's model catalog.
2. Record per-role recommendations and family groupings in the bake-off findings doc.
3. Add the host column to the routing table above (mark it bake-off-governed with a citation).
4. Add the host's defaults to the Config Surface table.
5. Verify the diversity rule is satisfied for the new host's default pairing.

The SKILL.md tier vocabulary and capability names remain unchanged — only this file and
`runtimes.md` gain new columns.
