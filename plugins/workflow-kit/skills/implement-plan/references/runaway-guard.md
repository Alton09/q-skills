# Runaway Guard (Step 5b)

Referenced from `SKILL.md` Step 5. Applies to every sub-agent the orchestrator spawns —
phase, retry, escalation, review, and fix agents.

The orchestrator cannot read a running sub-agent's live token count or inspect its
individual tool calls mid-flight — a background Agent surfaces its totals only in the
completion notification. So the guard rests on two primitives that do work: a wall-clock
timeout while running, and the token total on completion.

> **Resumption model.** Sub-agents are spawned with `run_in_background: true`. The "on
> return" / "when all agents return" steps throughout the skill are driven by the
> background-completion notification that re-invokes the orchestrator — they are not inline
> synchronous return values. The notification is also where the token total + duration
> arrive (the metric the ceiling check uses).

**Wall-clock budget (while running).** Set a per-phase time budget (`PHASE_TIME_BUDGET`,
default 15 min; scale up for `opus` phases, and use `ESCALATION_TIME_BUDGET` for escalation
attempts). Pace check-ins with `ScheduleWakeup`. If the sub-agent is still running past its
budget, treat it as runaway: `TaskStop` it, then page the user (below). `TaskStop` returns
only status, not partial work — report what the orchestrator last knew, not a recovered
transcript.

**Token ceiling (on completion).** When the sub-agent returns, compare its reported total
tokens against the per-model ceiling in Configuration (`PHASE_TOKEN_CEILING`, or
`ESCALATION_TOKEN_CEILING` for escalation attempts). The phase agent's total now includes
its warm self-verify loop, so the ceilings already budget for impl + verify — don't
double-count. If it overran, do NOT silently accept the result — page the user before the
gate-verify so an overrun phase gets a human look (the output may still be fine, but the
cost signal is worth a glance, and it lets you tune the ceiling).

**On either trip:**

1. **Do NOT** check off the phase, run the gate-verify, or advance to the next phase.
2. Page the user via the configured notify skill (`NOTIFY_SKILL`, default `/notify-me`):
   ```
   <NOTIFY_SKILL> "implement-plan paused: Phase <N> hit <wall-clock timeout | token ceiling NNNk>. Awaiting your call: resume, re-scope, switch model, or take over."
   ```
3. Wait for the user's decision before doing anything else with this phase.

> **Note:** mid-flight repeated-call / no-progress detection is intentionally NOT claimed
> here — there is no live per-call feed for a sub-agent. The wall-clock budget is what
> catches silent loops; the token ceiling catches expensive-but-completing ones.
