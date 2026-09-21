# Executor Registry

The Claude Code orchestrator owns scheduling, worktrees, pacing, gate verification,
notifications, and all decisions. An executor changes only a worker's harness. Worker
targets use `executor:model`; an unprefixed model resolves to `claude:model`. Split on the
first colon and use the matching entry below for every phase, retry, escalation, review, or
fix spawn. Reject unknown executors or model ids before spawning, and name the executor and
id in the error (for example, `unknown model 'x' for executor 'pi'`).

## Executor entries

### `claude`

- **Spawn command template:** Spawn every worker with the Agent tool and
  `run_in_background: true`. This keeps the orchestrator responsive for the wall-clock
  guard and concurrent workers, makes the worker cancellable, and returns total tokens and
  duration in the completion notification.
- **Model address syntax:** `claude:<enum>`; pass the suffix (`haiku`, `sonnet`, or `opus`)
  as the Agent `model`. An unprefixed id is equivalent to `claude:<id>`.
- **Stop mechanism:** `TaskStop`; it returns status only, not partial work.
- **Token-accounting extraction:** Use the total from the completion notification; no extra
  extraction is required.

### `pi`

- **Spawn command template:** Run with `Bash(run_in_background: true)`:
  ```bash
  cd <worktree> && { setsid timeout <secs> pi -p --mode json --no-session \
    --model <provider/id> --skill <consumer .claude/skills> \
    "$(cat <handoff-file>)" </dev/null > <scratch>/<phase>.jsonl \
    2> <scratch>/<phase>.err & echo $! > <scratch>/<phase>.pid; wait $!; }
  ```
  `setsid` makes the PID its process-group ID, so a group TERM reaches pi rather than only
  its wrapper; do not use shell job control (zsh `eval` rejects `set -m`). `</dev/null` is
  mandatory: without it, the 2026-09-16 probe produced
  0 bytes on stdout and stderr, then timed out at 180 s (`rc=124`). Read the large handoff
  file into argv, rather than inlining it. `--skill` exposes consumer skills for `/verify`;
  do not create an `.agents` symlink or edit `~/.pi/agent/settings.json`. Its cwd is the
  worktree; no session-root constraint applies because the orchestrator is not confined.
- **Model address syntax:** `pi:<provider/id>`; pass the suffix as `--model <provider/id>`.
  Phase tiers currently use
  `opencode-go/minimax-m3`, `opencode-go/glm-5.3`, and `opencode-go/qwen3.8-max`.
- **Stop mechanism:** TERM the recorded process group: `kill -TERM -- -<pid>`. See
  `references/runaway-guard.md` § "Stop" for the measured rationale and tree-kill caveat.
- **Token-accounting extraction:** At worker exit, sum `.message.usage` from assistant
  `message_end` events in the JSONL. Budget `input + output`, exclude `cacheRead`, and
  report `cost.total` only as flat-rate equivalent value. The exact jq extraction and
  measured caveats are in `references/runaway-guard.md` § "Token accounting".

### `codex`

- **Spawn command template:** Run setup once, then use `Bash(run_in_background: true)`:
  ```bash
  cd <worktree> && { setsid timeout <secs> codex exec --json -m <model> \
    -s workspace-write --add-dir "$HOME" --add-dir "$(git rev-parse --git-common-dir)" \
    -c sandbox_workspace_write.network_access=true -o <scratch>/<phase>.last.md \
    "$(cat <handoff-file>)" </dev/null > <scratch>/<phase>.jsonl \
    2> <scratch>/<phase>.err & echo $! > <scratch>/<phase>.pid; wait $!; }
  ```
  `</dev/null` is mandatory: the 180 s probe otherwise waited for input with no stdout
  (`rc=124`); `Reading additional input from stdin...` appears on stderr in both cases and
  is not a hang signal. Keep these narrowest-working sandbox flags: `workspace-write` alone
  blocks `~/.gradle`, `~/.maestro`, and adb; `--add-dir` accepts directories only, so `$HOME`
  is the narrowest writable root for those and Robolectric's lock; Codex keeps `.git`
  read-only inside writable roots, so the git common dir permits `index.lock`; network access
  enables verification. Do not pass `--ephemeral`: the JSON stream never names the model; only
  `~/.codex/sessions/**/rollout-*-<thread_id>.jsonl` records it in
  `turn_context.payload.model` (`thread_id` comes from `thread.started`) and preserves token
  totals and plan windows. `setsid` alone is insufficient for stopping; the final answer is
  `-o` output or the last `item.completed` `agent_message`.
- **Model address syntax:** `codex:<model>`; pass the suffix as `-m <model>`. Phase tiers use `gpt-5.6-luna`,
  `gpt-5.6-terra`, and `gpt-5.6-sol` (all GPT family).
- **Stop mechanism:** Walk descendants before killing, then TERM every discovered process
  group; `codex-linux-sandbox` creates sessions, so a launcher group kill leaves children.
  Use the exact GNU-procps/macOS procedure in `references/runaway-guard.md` § "Stop".
- **Token-accounting extraction:** At worker exit, take the single `turn.completed` usage,
  budgeting `input_tokens - cached_input_tokens + output_tokens`. If scratch JSONL is gone,
  read the thread's non-ephemeral session file; use `total_token_usage` and the first/last
  `token_count` window percentages. Report tokens and window share, never dollars; see
  `references/runaway-guard.md` § "Token accounting" for the exact jq extractions.
- **Setup:** Codex has no per-call skill flag and discovers skills only under repo/parent or
  user `.agents/skills`. Before the first spawn in a worktree, create
  `<worktree>/.agents/skills` as a symlink to `../.claude/skills`, add `.agents/` once to
  that worktree's git `info/exclude`, and link any required user-level skill from
  `~/.agents/skills/<name>` to `~/.claude/skills/<name>`. The orchestrator, never the user,
  does this; pi's no-`.agents` rule still applies only to pi.

## Adding an executor

1. Prove the harness runs headless and non-interactively with stdin closed.
2. Prove it loads the consumer project's required skills.
3. Prove model selection works per call.
4. Name the durable source of its token data.
