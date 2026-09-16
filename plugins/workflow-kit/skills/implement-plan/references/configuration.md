# Configuration Reference

Referenced from `SKILL.md` Configuration. Projects can override via environment variables or
the project's agent config file (`CLAUDE.md`, `AGENTS.md`, or the host's equivalent). Unknown
model ids halt loudly and are never substituted — see the Loud-Failure Rule in
`references/model-routing.md`.

**Runtime**

- `HOST_RUNTIME` — explicit host override for Step 0.5 detection. When unset, the host is
  detected from the toolset. An unknown value, an ambiguous toolset, or a host with no
  column in `references/runtimes.md` halts the run.

**Models** — every default below resolves through the detected host's column in
`references/model-routing.md`. **Unknown model ids halt loudly and are never substituted.**

- `ORCHESTRATOR_MODEL` — orchestrator model (default: the host's **deep** tier)
- `PREP_MODEL` — model for the delegated plan parse (Step 1). Default: the host's
  **standard** tier — keeps the raw plan out of the orchestrator's persistent window while
  preserving the load-bearing extract verbatim. (Avoid the `light` tier: the extract is
  load-bearing and needs light judgment.)
- `PHASE_MODEL_LIGHT` / `PHASE_MODEL_STANDARD` / `PHASE_MODEL_DEEP` — per-tier phase
  sub-agent models (Step 5a.2), one per complexity class.
- `VERIFY_MODEL` — model for the delegated gate-verify sub-agent (Step 6). Default: the
  host's **standard** tier; drop to the **light** tier when the project's verify is a
  deterministic exit-code gate.
- `REVIEW_MODEL` — review sub-agent model (Step 8). Default: the host's **deep** tier.
- `FIX_MODEL` — auto-fix sub-agent model (Step 8b). Default: the host's **standard** tier.
- `ESCALATION_LADDER` — rung-1 escalation model(s) (Step 6). Default: the **deep** tier with
  a family switch away from the implementer that failed.
- *Deprecated aliases* — `PREP_AGENT_MODEL` → `PREP_MODEL`, `VERIFY_AGENT_MODEL` →
  `VERIFY_MODEL`. Still accepted; they emit a deprecation warning on load and are removed in
  a future major version.

**Skills**

- `VERIFY_SKILL` — project's verification skill (default: `/verify`)
- `NOTIFY_SKILL` — notification skill (default: `/notify-me`)
- `REVIEW_SKILL` — project's code-review skill for Step 8 (default: `/code-review`). Must be
  **non-interactive**: it runs as a background sub-agent with no user present, so a skill that
  prompts mid-run (e.g. `/pr-review`, which asks which findings to keep and whether to post)
  will stall. If absent, Step 8 is skipped.

**Budgets and gates**

- `SELF_VERIFY_LIMIT` — default 2. Governs **two** caps with the same value: (a) max warm
  self-verify fix rounds inside a phase sub-agent before it stops and reports (Step 5a);
  and (b) max orchestrator-level gate-verify attempts per phase before the hard stop /
  escalation pass (Step 6). One knob, both retry budgets.
- `PHASE_TOKEN_CEILING` — per-phase sub-agent token total that triggers a user page on
  completion (Step 5b). Now budgets impl + warm self-verify together. Defaults by tier:
  `light` 80k / `standard` 150k / `deep` 250k. Single source for these numbers — Step 5b
  references it.
- `PHASE_TIME_BUDGET` — per-phase wall-clock budget before the runaway guard stops the
  sub-agent (Step 5b). Default 15 min; scale up for `deep`-tier phases.
- `ESCALATION_ATTEMPTS` — max rung-1 rescue attempts in the Step 6 escalation pass
  before HALTED / user-wait. Default 2.
- `ESCALATION_TOKEN_CEILING` — token ceiling for an escalation attempt (Step 6), replacing
  the per-phase ceiling for the rescue. Default 400k (above the `deep`-tier phase 250k —
  these are the hardest cases).
- `ESCALATION_TIME_BUDGET` — wall-clock budget for an escalation attempt (Step 6). Default
  30 min.
- `MAX_PARALLEL_AGENTS` — max phase sub-agents run concurrently in a parallel group
  (Step 5a.1/5a.3). Default 3; larger groups run in batches of this size. Has no effect on a
  host whose `PACE` capability is unavailable — those runs are sequential.
- `RUN_REVIEW` — whether to run the post-implementation review + auto-fix step (Step 8).
  Default `true`; set `false` to stop after implementation.
- `REVIEW_AUTOFIX_SEVERITY` — minimum finding severity that gets auto-fixed (Step 8b).
  Default: high / correctness and above; lower-severity findings are reported, not touched.
- `REVIEW_MAX_ROUNDS` — max review↔fix rounds before stopping and listing anything still
  open (Step 8d). Default 2.
- `CREATE_PR` — whether Step 9 delegates to the project's `/create-pr` skill. Default `true`;
  set `false` to end the run at the local worktree branch. Has no effect when the project has
  no `/create-pr` — the step is skipped either way.
