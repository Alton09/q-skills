# Runaway Guard (Step 5b)

Referenced from `SKILL.md` Step 5. Applies to every sub-agent the orchestrator spawns —
phase, retry, escalation, review, E2E, and fix agents.

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
default 30 min; scale up for deep phases, use `ESCALATION_TIME_BUDGET` for escalation
attempts, and use `E2E_TIME_BUDGET` for E2E). Alongside every Claude or codex spawn, start a timer with
`Bash(run_in_background: true)` running `sleep <budget seconds>`. In the spawn record, bind
the timer task id to the exact worker it guards: the Agent task id for Claude or the pidfile
for codex. Its completion notification re-invokes the orchestrator even if the worker hangs
silently. On wakeup, act only if that same bound worker is still outstanding: use `TaskStop`
for Claude or walk and stop the codex process tree while its parent is still alive, then page
the user (below). When the worker completes first, `TaskStop` its timer immediately so an old
attempt, completed phase, or parallel sibling's timer cannot stop later work.

Pi enforces the budget directly with `timeout -k <grace> <budget-secs>`. Codex's command
uses `timeout -k <grace> <budget-plus-5-min-secs>`—the wall-clock budget plus a five-minute
margin—only as a backstop for a missed timer wakeup. Exit 124 from either pi/codex spawn, or
137 when `timeout -k` had to KILL it, is a wall-clock trip handled by **On either trip**, not
an ordinary worker failure: do not gate-verify, retry, or escalate. Do not use
`ScheduleWakeup`, which is available only in `/loop` dynamic mode. Stop returns only status,
not partial work—report what the orchestrator last knew, not a recovered transcript.

**Token ceiling (on completion).** When the sub-agent returns, compare its budget figure
against the resolved light/standard/deep tier ceiling in Configuration
(`PHASE_TOKEN_CEILING`, `ESCALATION_TOKEN_CEILING` for escalation attempts, or
`E2E_TOKEN_CEILING` for E2E): Claude uses
the completion-notification total, while pi and codex use `new` tokens below. The phase
agent's total now includes its warm self-verify loop, so the ceilings already budget for
impl + verify — don't double-count. If it overran, do NOT silently accept the result — page
the user before the gate-verify so an overrun phase gets a human look (the output may still
be fine, but the cost signal is worth a glance, and it lets you tune the ceiling).

**On either trip:**

For a Step 8 review or E2E worker, mark only that worker `not finished`, do not apply the
phase wait below, and let its enabled sibling continue. Wait for that sibling, then continue
Step 8; do not automatically re-run the stopped worker in that round.

For all other workers:

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

At foreign-worker exit, use the executor's single combined extraction below. Its stdout
contains only the extracted fields and the worker's final answer, never the raw pi/codex event
stream. Keep the JSONL redirected to its scratch file; do not `Read`, print, or return the
event stream before filtering.
Measured 2026-09-21 (MenuLens sessions `21163bb7` / `9e8b7fa4`): foreign-output/accounting
extraction was only 0.0% / 1.1% of positive orchestrator context growth, so keep its existing
one-command extracted-fields contract rather than adding turns or a new summary layer.

**Extract at worker exit, not at report time.** As soon as a foreign worker's process ends,
run its extraction below and write the numbers into that phase's spawn record (5a.2), beside
the model that actually ran. The JSONL logs live in the session scratchpad, which does not
survive the session: measured 2026-09-19 (MenuLens session `21163bb7`), the orchestrator
deferred accounting to Step 10, found the scratchpad emptied, and reported `token accounting
unavailable` for a run whose numbers were fully recoverable. Step 10's F4 rule forbids
estimating the gap away, so a deferred extraction turns into a permanently unmeasured run.

**Keep the report split at exit.** Tag every spawn record with its role: `worker` for phase,
retry, escalation, and gate-verify work; `review+fix` for Step 8 review and fix work; and
`e2e` for Step 8 E2E work. Step 10 aggregates only records with the same role and executor,
so review, fix, or E2E numbers cannot silently inflate the worker row. A missing extraction makes that role/executor measure `token accounting
unavailable`; it is not repaired from another role, model price, elapsed time, or a prior
run. The Claude Code orchestrator is not a spawned worker: its row may use only a genuine
per-run Claude Code record for its own cost, API calls, and peak context. Its session
transcript measures API calls and peak context, but has no dollar cost record; Step 10 must
leave cost unavailable rather than deriving it from prices, usage, workers, or account-level
quota.

- **`claude` orchestrator** → Claude Code writes its transcript to
  `~/.claude/projects/<project-slug>/<session-id>.jsonl`. Locate it by the orchestrator's
  own session id; if that file cannot be identified unambiguously, print `unavailable —
  session transcript not identified` for both API calls and peak context — never select the
  newest file. An API call can occupy several assistant JSONL lines with the same
  `message.id` (one per content block), so exclude `isSidechain == true`, retain assistant
  lines with `message.usage`, then count distinct `message.id` values and take the maximum
  context across those calls:
  ```
  jq -s '[.[] | select(.type == "assistant" and .isSidechain != true
                       and .message.usage != null and .message.id != null)
          | {id: .message.id,
             context: (.message.usage.input_tokens
                       + .message.usage.cache_creation_input_tokens
                       + .message.usage.cache_read_input_tokens)}]
         | unique_by(.id)
         | {api_call_count: length, peak_context: (map(.context) | max // 0)}' \
     ~/.claude/projects/<project-slug>/<session-id>.jsonl
  ```
  The transcript contains no dollar figure. Leave orchestrator cost as `token accounting
  unavailable`; F4 forbids a price-based estimate.

- **`claude`** → totals arrive in the completion notification; nothing extra required.
- **`pi`** → `--mode json` writes a JSONL event stream to stdout. Token and cost data live at `.message.usage` on `message_end` events where `.message.role == "assistant"`. Top-level usage on `turn_end`, `agent_end`, and `agent_settled` is `null`; there is **no run-level aggregate event**. At exit, run this one command; it emits the token fields and the last assistant text as `final_answer`:
  ```
  jq -s '[.[] | select(.type=="message_end" and .message.role=="assistant")]
         | {new: (map(.message.usage.input + .message.usage.output)|add),
            cacheRead: (map(.message.usage.cacheRead)|add),
            cost: (map(.message.usage.cost.total)|add),
            final_answer: ([.[] | .message.content
              | if type == "string" then . else [.[]? | select(.type == "text") | .text] | join("") end]
              | last)}' <scratch>/<phase>.jsonl
  ```
  `new` (`input + output`) is the budget figure checked against the 5b token ceiling. `cacheRead` is reported on its own line and **excluded** from the budget: pi re-reports the cached context on every turn, so it grows with turns × context size and means nothing as a budget. Do not use `totalTokens`, which includes `cacheRead` — on a real run it reported 3.65M tokens for a worker that used 63k new. On flat-rate `opencode-go`, `cost.total` is retail-equivalent value, not metered cash — report it as equivalent value and never as metered spend. The cap that matters is the provider's rate limit, not a dollar ceiling.
- **`codex`** → `--json` emits exactly one `turn.completed` per `codex exec`, and its `usage` already covers the whole run (every tool call and model request). No summing is needed. At exit, run this one command; `-o` normally wrote the final answer, but a missing file is a failed hand-back, not lost accounting:
  ```
  jq -cs --rawfile final_answer <(if [ -f <scratch>/<phase>.last.md ]; then cat <scratch>/<phase>.last.md; fi) '[.[] | select(.type=="turn.completed") | .usage][0]
         | {new: (.input_tokens - .cached_input_tokens + .output_tokens),
            cached: .cached_input_tokens, final_answer: $final_answer}' <scratch>/<phase>.jsonl
  ```
  `cached_input_tokens` is a **subset** of `input_tokens` (the session file's `total_tokens` equals `input + output`), so the budget figure subtracts it; this is not the same arithmetic as pi. There is no cost field: codex runs on a ChatGPT subscription, so report tokens and the plan-window share, **never a dollar figure**.

  If the scratchpad JSONL is gone, the session file is the durable fallback — this is the
  second reason the codex contract forbids `--ephemeral`. Every `token_count` event carries
  the run-cumulative totals and may carry the live plan windows. Extract tokens separately
  so absent rate-limit data cannot discard recoverable token figures
  (measured 2026-09-19, MenuLens session `21163bb7`):
  ```bash
  jq -s '[.[] | select(.payload.type=="token_count") | .payload] | last
         | if . == null then {new: "unavailable", cached: "unavailable"}
           else {new: (.info.total_token_usage.input_tokens
                       - .info.total_token_usage.cached_input_tokens
                       + .info.total_token_usage.output_tokens),
                 cached: .info.total_token_usage.cached_input_tokens}
           end' ~/.codex/sessions/<Y>/<M>/<D>/rollout-*-<thread_id>.jsonl

  jq -s 'def delta($a; $b):
           if ($a.used_percent == null or $b.used_percent == null
               or $a.resets_at != $b.resets_at or $b.used_percent < $a.used_percent)
           then "unavailable" else ($b.used_percent - $a.used_percent) end;
         [.[] | select(.payload.type=="token_count")
          | {timestamp, rate_limits: .payload.rate_limits}] | sort_by(.timestamp) as $events
         | ($events[0] // null) as $first | ($events[-1] // null) as $last
         | {window_5h_first: $first.rate_limits.primary.used_percent,
            window_5h_last: $last.rate_limits.primary.used_percent,
            window_5h_delta: delta($first.rate_limits.primary; $last.rate_limits.primary),
            window_weekly_first: $first.rate_limits.secondary.used_percent,
            window_weekly_last: $last.rate_limits.secondary.used_percent,
            window_weekly_delta: delta($first.rate_limits.secondary; $last.rate_limits.secondary)}' \
     ~/.codex/sessions/<Y>/<M>/<D>/rollout-*-<thread_id>.jsonl
  ```
  Use `total_token_usage`, never `last_token_usage`, which covers one turn only. The
  `used_percent` figures are cumulative within the window, so report the explicitly extracted
  first/last delta. If the later value is lower or `resets_at` changed, report `unavailable`
  rather than deriving a number across the reset. When codex workers overlap in time (or
  other account activity makes attribution ambiguous), merge exactly the rollout files named
  by the codex thread ids in this run's spawn records, sort their eligible events by time, and
  report the window delta once for the whole run rather than per worker:

  ```bash
  jq -s 'def delta($a; $b):
           if ($a.used_percent == null or $b.used_percent == null
               or $a.resets_at != $b.resets_at or $b.used_percent < $a.used_percent)
           then "unavailable" else ($b.used_percent - $a.used_percent) end;
         [.[] | select(.payload.type=="token_count" and .payload.rate_limits != null)
          | {timestamp, rate_limits: .payload.rate_limits}] | sort_by(.timestamp) as $events
         | ($events[0] // null) as $first | ($events[-1] // null) as $last
         | {window_5h_first: $first.rate_limits.primary.used_percent,
            window_5h_last: $last.rate_limits.primary.used_percent,
            window_5h_delta: delta($first.rate_limits.primary; $last.rate_limits.primary),
            window_weekly_first: $first.rate_limits.secondary.used_percent,
            window_weekly_last: $last.rate_limits.secondary.used_percent,
            window_weekly_delta: delta($first.rate_limits.secondary; $last.rate_limits.secondary)}' \
     <rollout-file-for-thread-id-1> <rollout-file-for-thread-id-2> [...]
  ```

  A changed `resets_at` makes that window's whole-run delta `unavailable`.

  The same first/last delta is the only plan-window share Step 10 may report for a codex
  review or fix record. Codex is subscription-backed: report its new tokens and window
  share, never dollars.
