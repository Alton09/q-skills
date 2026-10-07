# Executor Registry

The Claude Code orchestrator owns scheduling, worktrees, pacing, gate verification,
notifications, and all decisions. An executor changes only a worker's harness. Worker
targets use `executor:model`; an unprefixed model resolves to `claude:model`. Split on the
first colon and use the matching entry below for every phase, retry, escalation, review, or
fix spawn. Reject unknown executors or model ids before spawning, and name the executor and
id in the error (for example, `unknown model 'x' for executor 'pi'`). For an unpinned role
the `executor:model` address may come from the quota-aware router
(`references/routing.md`); the entries below apply to it unchanged.

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
  cd <worktree> && { setsid timeout -k <grace> <budget-secs> pi -p --mode json --no-session \
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
  cd <worktree> && { setsid timeout -k <grace> <budget-plus-5-min-secs> codex exec --json -m <model> \
    -s workspace-write --add-dir "$HOME" --add-dir "$(git rev-parse --git-common-dir)" \
    -c sandbox_workspace_write.network_access=true -o <scratch>/<phase>.last.md \
    "$(cat <handoff-file>)" </dev/null > <scratch>/<phase>.jsonl \
    2> <scratch>/<phase>.err & echo $! > <scratch>/<phase>.pid; wait $!; }
  ```
  Set the timeout to the wall-clock budget plus five minutes; it is only the backstop for
  the orchestrator timer in `references/runaway-guard.md`. `</dev/null` is mandatory: the 180 s probe otherwise waited for input with no stdout
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
- **Device path (`CODEX_DEVICE_MODE`):** Boot nothing inside the sandbox: `/dev/kvm` is hidden
  there (MenuLens sessions `27cab714`, `09cbe7b9`), so emulator boot stays with the
  orchestrator. Measured 2026-10-02 (codex-cli 0.158.0, 2026-10-02 probe in q-skills
  implement-plan session `e67625dd`, recorded in the plan's Probe results; no MenuLens
  session exists for it): with the flags above unchanged, codex ran `adb devices`,
  `adb -s <serial> shell getprop`, `ANDROID_SERIAL=<serial> ./gradlew installDevDebug`,
  `pm clear`, `maestro --device <serial> test ...`, and `screenrecord` plus `adb pull`, all
  exit 0. No extra env vars were needed, and `ADB_SERVER_SOCKET` was not needed, provided the
  adb server already runs outside the sandbox. The per-serial lock
  `${XDG_RUNTIME_DIR}/menulens-e2e-<serial>.lock` is visible and contended inside the sandbox
  (`XDG_RUNTIME_DIR=/run/user/1000` on both sides). A fresh consumer worktree may still need
  gitignored files (MenuLens: `local.properties`); that is the consumer's worktree setup, not
  the device path. Default mode `reserved-device`:
  1. Reserve only for a codex worker that actually carries device checks: a phase worker or
     gate given device checks (see `references/phase-execution.md` 5a.2), or the codex E2E
     worker (`E2E_MODEL=codex:*`). Before spawning it, the orchestrator runs `adb start-server`
     and reserves a device outside the sandbox. It uses the consumer project's reservation
     convention where one exists; otherwise it probes each candidate serial's lock file with
     non-blocking `flock -n`, takes the first one acquired, and holds it from a background
     process in its own process group (`setsid flock -o <lock> sleep infinity &`, recording
     that PID, which is also the group id). `-o` closes the lock fd before exec, so the child
     `sleep` does not inherit it and killing the flock process frees the lock; without `-o`
     the lock survives the kill. The `sleep` child still outlives a kill of the flock PID
     alone (measured 2026-10-03, MenuLens session `92a4589c`), which is why release kills the
     group. Before spawning the worker it confirms
     the holder is alive and holding (for example, `kill -0 <pid>` and a failing `flock -n`
     probe on the same lock). It boots an emulator only when no candidate lock was acquired.
  2. The orchestrator holds the reservation for the worker's lifetime. It passes
     `ANDROID_SERIAL=<serial>` and `DEVICE_RESERVED=1` in the spawn environment and adds this
     line to the handoff: "Device `<serial>` is already reserved for you; use only it, reuse
     the reservation, and do not boot, shut down, or re-lock a device.
     Start each device suite exactly once, in the foreground, and keep polling that same
     command session until it exits (codex returns a `session_id` while the command runs;
     poll it with empty `write_stdin`). Never relaunch a suite: a command that returned while
     still running is not dead, and `pgrep` cannot see it."
     Measured 2026-10-03/04 (MenuLens sessions `92a4589c` and `43d4d0c4`, codex gate threads
     `01a10533` and `01a106ea`): each codex command runs in its own PID namespace (a detached
     `run_e2e.sh` reported `pid=4`), so a later command's `pgrep` found nothing, the gate
     concluded the suite had died, and it relaunched it up to four times on the same serial.
     Two Maestro clients on one device kill each other's device server, so overlapping runs
     failed every flow in about 100 ms with `DeviceServerDiedException`. `DEVICE_RESERVED=1`
     skips the reservation lock, so only a consumer-side run lock (a second `flock -n` per
     serial, taken by the suite runner itself) can reject an overlapping run; file locks work
     across codex commands where `pgrep` does not.
     Device-phase spawn: use the codex template above with
     `ANDROID_SERIAL=<serial> DEVICE_RESERVED=1` placed before `setsid`.
  3. The worker's consumer skill (`/verify`, `/e2e`) must honour `DEVICE_RESERVED=1`: use
     `ANDROID_SERIAL` and skip its own selection and lock. It should still take its own
     non-blocking per-serial run lock and exit with "suite already running" when that lock is
     busy, so an overlapping run fails fast instead of crashing the live one. The reservation
     lock is contended inside the
     sandbox, so a skill that re-acquires it blocks until the time budget trips. A consumer
     skill that cannot honour a pre-held reservation is incompatible with `reserved-device`;
     use `off`. That consumer-side change belongs to the consumer project.
  4. After the worker exits, the orchestrator first stops device processes the worker left
     behind. Sandboxed commands start their own sessions, so a running suite and its Maestro
     client outlive `codex exec`; in the 2026-10-03 run they were still driving the device
     after the gate exited. Find them by the reserved serial, not by the codex tree (the
     parent is gone): on Linux, every PID whose `/proc/<pid>/environ` holds
     `ANDROID_SERIAL=<serial>`, plus `pgrep -f -- '--device <serial>'`; TERM each one's process
     group. Do this before any retry or re-spawn on the same serial as well. Then release the
     reservation: `kill -TERM -- -<holder pid>` (the whole holder group, flock and `sleep`),
     confirm `pgrep -g <holder pid>` is empty and a `flock -n` on the lock succeeds, and shut
     down only an emulator it booted.
  - `full-access` (opt-in): spawn device phases with `-s danger-full-access` in place of
    `workspace-write` and its `--add-dir` flags. Ask the user once per run before the first
    such spawn and record the answer in the report's E2E section; without a yes, fall back to
    `reserved-device`. Every other codex spawn keeps `workspace-write`. The auto-mode
    classifier may flag `danger-full-access`; surface the block to the user and never work
    around it.
  - `off`: phase-execution.md 5a.2 routing applies unchanged (no reservation; a codex worker
    or gate cannot run device checks). A codex E2E worker cannot boot a device either.
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
