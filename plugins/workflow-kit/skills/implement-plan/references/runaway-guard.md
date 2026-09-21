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
default 30 min; scale up for `opus` phases, and use `ESCALATION_TIME_BUDGET` for escalation
attempts). The orchestrator checks elapsed time on each natural re-invocation — the
background-completion notification is the heartbeat, not a scheduled wakeup primitive. If
any worker is still outstanding past its budget when the orchestrator next runs, treat it as
runaway: stop it (see Per-executor bindings below), then page the user (below). Stop returns
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

## Per-executor bindings

### Stop

- **`claude`** → `TaskStop`. Returns only status, no partial work.
- **`pi`** → kill the worker's **process group**. Killing only the wrapper PID orphans the real `pi` subprocess, which continues running and spending. Launch the worker under `setsid` (see `phase-execution.md` § 5a.3) so its PID is also its process-group ID, and record that PID in a pidfile. Stop it with `kill -TERM -- -<pid>`. Do not enable shell job control for this instead: the Claude Code Bash tool runs commands through zsh `eval`, where it fails with `(eval):set:1: can't change option: -m` and the worker never starts (measured 2026-09-18).
- **`codex`** → kill the worker's **process tree**, not only its group. `codex exec` runs each tool command inside `codex-linux-sandbox`, which calls `setsid` itself; a group kill of the `setsid` launcher left the sandboxed command (and its children, e.g. a Gradle build) running, reparented to init (measured 2026-09-18). Walk the tree from the pidfile PID **before** killing anything — once the parent dies the sandbox helper is no longer reachable — then TERM every process group in it:
  ```bash
  descendants() { local c; for c in $(ps -o pid= --ppid "$1"); do echo "$c"; descendants "$c"; done; }
  for g in $(for p in "$PID" $(descendants "$PID"); do ps -o pgid= -p "$p"; done | tr -d ' ' | sort -u); do
    kill -TERM -- -"$g" 2>/dev/null
  done
  ```
  This left 0 processes in the same test. `ps --ppid` is GNU procps; on macOS use `pgrep -P`. pi's group kill has not been tested against the same failure; if pi tool children start their own sessions, use the tree kill for pi too.

### Pace

The orchestrator is always Claude Code regardless of which executor the workers use. `PACE` (background spawning and the parallel-group structure) is therefore available for **every** executor. Pi and codex workers do **not** force a parallel-group demotion — that is the direct consequence of moving the harness choice to the worker level rather than the orchestrator. This is the opposite of the opencode outcome, where the foreign orchestrator lost group control because the entire run ran inside opencode.

### Token accounting

**Extract at worker exit, not at report time.** As soon as a foreign worker's process ends,
run its extraction below and write the numbers into that phase's spawn record (5a.2), beside
the model that actually ran. The JSONL logs live in the session scratchpad, which does not
survive the session: measured 2026-09-19 (MenuLens session `21163bb7`), the orchestrator
deferred accounting to Step 10, found the scratchpad emptied, and reported `token accounting
unavailable` for a run whose numbers were fully recoverable. Step 10's F4 rule forbids
estimating the gap away, so a deferred extraction turns into a permanently unmeasured run.

**Keep the report split at exit.** Tag every spawn record with its role: `worker` for phase,
retry, escalation, and gate-verify work; `review+fix` for Step 8 work. Step 10 aggregates
only records with the same role and executor, so review/fix numbers cannot silently inflate
the worker row. A missing extraction makes that role/executor measure `token accounting
unavailable`; it is not repaired from another role, model price, elapsed time, or a prior
run. The Claude Code orchestrator is not a spawned worker: its row may use only a genuine
per-run Claude Code record for its own cost, API calls, and peak context. This skill has no
such record by default, so Step 10 explicitly reports each absent field rather than deriving
it from its turns, messages, workers, or account-level quota.

- **`claude`** → totals arrive in the completion notification; nothing extra required.
- **`pi`** → `--mode json` writes a JSONL event stream to stdout. Token and cost data live at `.message.usage` on `message_end` events where `.message.role == "assistant"`. Top-level usage on `turn_end`, `agent_end`, and `agent_settled` is `null`; there is **no run-level aggregate event**. Sum across all qualifying events:
  ```
  jq -s '[.[] | select(.type=="message_end" and .message.role=="assistant") | .message.usage]
         | {new: (map(.input + .output)|add), cacheRead: (map(.cacheRead)|add),
            cost: (map(.cost.total)|add)}'
  ```
  `new` (`input + output`) is the budget figure checked against the 5b token ceiling. `cacheRead` is reported on its own line and **excluded** from the budget: pi re-reports the cached context on every turn, so it grows with turns × context size and means nothing as a budget. Do not use `totalTokens`, which includes `cacheRead` — on a real run it reported 3.65M tokens for a worker that used 63k new. On flat-rate `opencode-go`, `cost.total` is retail-equivalent value, not metered cash — report it as equivalent value and never as metered spend. The cap that matters is the provider's rate limit, not a dollar ceiling.
- **`codex`** → `--json` emits exactly one `turn.completed` per `codex exec`, and its `usage` already covers the whole run (every tool call and model request). No summing is needed:
  ```
  jq -s '[.[] | select(.type=="turn.completed") | .usage][0]
         | {new: (.input_tokens - .cached_input_tokens + .output_tokens),
            cached: .cached_input_tokens}'
  ```
  `cached_input_tokens` is a **subset** of `input_tokens` (the session file's `total_tokens` equals `input + output`), so the budget figure subtracts it; this is not the same arithmetic as pi. There is no cost field: codex runs on a ChatGPT subscription, so report tokens and the plan-window share, **never a dollar figure**.

  If the scratchpad JSONL is gone, the session file is the durable fallback — this is the
  second reason the codex contract forbids `--ephemeral`. Every `token_count` event carries
  the run-cumulative totals *and* the live plan windows, so one read gives both figures
  (measured 2026-09-19, MenuLens session `21163bb7`):
  ```
  jq -s '[.[] | select(.payload.type=="token_count") | .payload] | last
         | {new: (.info.total_token_usage.input_tokens
                  - .info.total_token_usage.cached_input_tokens
                  + .info.total_token_usage.output_tokens),
            cached: .info.total_token_usage.cached_input_tokens,
            window_5h: .rate_limits.primary.used_percent,
            window_weekly: .rate_limits.secondary.used_percent}' \
     ~/.codex/sessions/<Y>/<M>/<D>/rollout-*-<thread_id>.jsonl
  ```
  Use `total_token_usage`, never `last_token_usage`, which covers one turn only. The
  `used_percent` figures are cumulative within the window, so a worker's share is the
  difference between its first and last `token_count` event, not the last value.

  The same first/last delta is the only plan-window share Step 10 may report for a codex
  review or fix record. Codex is subscription-backed: report its new tokens and window
  share, never dollars.
