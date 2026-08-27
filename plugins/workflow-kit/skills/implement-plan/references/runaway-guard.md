# Runaway Guard (Step 5b)

Referenced from `SKILL.md` Step 5. Applies to every sub-agent the orchestrator spawns —
phase, retry, escalation, review, and fix agents.

The orchestrator cannot read a running sub-agent's live token count or inspect its
individual tool calls mid-flight — a background `SPAWN_WORKER` surfaces its totals only in
the completion notification. So the guard rests on two primitives that do work: a wall-clock
timeout while running, and the token total on completion.

> **Resumption model.** Sub-agents are spawned via `SPAWN_WORKER` (background). The "on
> return" / "when all agents return" steps throughout the skill are driven by the
> background-completion notification that re-invokes the orchestrator — they are not inline
> synchronous return values. The notification is also where the token total + duration
> arrive (the metric the ceiling check uses).

## Contract

**Wall-clock budget (while running).** Set a per-phase time budget (`PHASE_TIME_BUDGET`,
default 15 min; scale up for `deep`-tier phases, and use `ESCALATION_TIME_BUDGET` for
escalation attempts). Pace check-ins with `PACE`. If the sub-agent is still running past its
budget, stop it with `STOP_WORKER`, then page the user (below). `STOP_WORKER` returns only
status, not partial work — report what the orchestrator last knew, not a recovered transcript.

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

## Host Implementations

### claude-code

- **`PACE`** → `ScheduleWakeup` tool: schedule timed check-ins to observe whether the
  sub-agent is still running past its budget.
- **`STOP_WORKER`** → `TaskStop` tool: first-class cancellation primitive; stops the running
  sub-agent immediately. `TaskStop` returns only status, not partial work.

Both primitives are fully available. The full wall-clock + token-ceiling guard operates as
described in the Contract above.

### opencode

- **`PACE`** → **backgrounding unavailable** (the half this guard depends on). Sibling
  subagents do *execute* concurrently on this host — measured — but the `task` tool has no
  `run_in_background` / async-prompt equivalent and there is no within-skill timed wakeup
  primitive, so control does not return to the orchestrator while a worker runs and no
  mid-flight check-in is possible. Parallel groups are demoted to sequential for exactly
  this reason (`references/runtimes.md`, *Parallel-Group Availability*), so the
  orchestrator tracks timing from spawn to completion notification, one worker at a time.
- **`STOP_WORKER`** → no first-class cancellation tool. The REST endpoint
  `POST /session/:id/abort` exists but is unreachable from within a running skill: the
  opencode server's HTTP port is randomly assigned at startup (unless `--port N` is set),
  and the child session ID is not returned by the `task` tool in any documented or observed
  form. Both values are unknowable at call time.

**Degradation: guard is honestly weaker on opencode — post-hoc token ceiling only.** A
runaway sub-agent burns to completion before the ceiling can stop it from continuing. The
`TOKEN_ACCOUNTING` ceiling check (`PHASE_TOKEN_CEILING`) still fires on completion and pages
the user when overrun — but only after the sub-agent finishes, not during the run.

This degradation **must appear in the Step 2 disclosure**:
```
STOP_WORKER: Runaway guard is post-hoc only — a runaway subagent will burn to completion before the token ceiling stops it from continuing.
```
