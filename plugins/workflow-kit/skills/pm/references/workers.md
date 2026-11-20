# Workers

Use this reference whenever launching, watching, reconciling, or resuming a background
worker. Keep the item file authoritative: sessions and notices are signals that help the project manager
bring that state up to date.

## Herdr spaces

Give every running worker its own herdr workspace (a "space") so the user can watch it, and
close the space as soon as the worker finishes. Never use `herdr agent start`: native start
would replace the background supervisor and require new watch, reconcile, and resume
procedures.

Spaces are on only when the project manager runs inside herdr (`HERDR_ENV=1`) and `herdr` is on
`PATH`. They are on by default when available; set `pm.herdr: false` in
`.claude/workflow-kit.json` (or the user file) to disable them. Outside herdr, every
`herdr.py` call is a silent no-op.

- **pm workers** (plan, implement, ci, sync, comments, retro). `herdr.py` opens a workspace
  labeled `pm:<worker>` in the repository root. Its only pane runs `command claude attach
  <short id>`, and its agent is named after the worker (`references/dossier.md` § "Worker
  names"). Attach by short id, never by name: `claude attach` matches names by prefix, so
  `<feature>-<slug>` is ambiguous once `<feature>-<slug>-plan` exists.
- **Executor workers** (codex and pi phase, review, fix, and E2E workers inside a worker).
  Pass `--herdr` to `launch.py command`. The worker then runs with `WORKFLOW_KIT_HERDR=1`, and
  implement-plan and address-pr open a `codex:` or `pi:` space for each executor spawn.
  `<skill-dir>/../implement-plan/references/executors.md` § "Herdr spaces" defines these
  spaces. Each space shows a live view of the worker's JSON stream and closes itself when the
  worker process exits. Claude sub-agents run in-process and have no space.

A pm space stays open while its worker is running or waiting on `AskUserQuestion`, and while
its item is `paused` on a needs input block, so the user can answer in it. It closes once the
session is `done` and the item is not paused, or once the session is `stopped`.
`herdr.py sync` applies that rule to every `pm:` space of this repository. It opens missing
spaces, closes finished ones, and sweeps executor spaces whose viewer has exited. It never
closes a pane that runs a process pm did not start, a `pm:` space whose pane is outside this
repository, or any other workspace.

Never write herdr IDs to the dossier. Each call finds spaces by label and `claude agents`
records, so a restarted project manager can rebuild the view from item files alone. Use
`events.py agents` and the item file as the authoritative inputs to reconcile: herdr status
is screen-scraped, lags the worker, and can be wrong.

Treat `skipped: true` as a no-op. A space failure returns `warning` in JSON; tell the user once
and continue. Never let a space failure block a launch, reconcile, or item write. Usage
errors write to stderr and exit 2; report the message once and continue without the space.

## Launch

Evaluate gates in this order so a scarce worker slot is not spent on work that cannot proceed.

1. Run `launch.py overlap --vault <vault> --item <item>`; it evaluates both `blockedBy` and
   plan-file/module overlap. When it reports a blocker, set `status: blocked`, sync the item,
   and tell the user which item blocks it. No worker starts and no notification event is sent.
   Launch it automatically once the blocker reaches `merged`. Send `decision-<n>` only when
   the user must choose the order between otherwise-ready work; use `events.py notify` so the
   decision ask is deduplicated.
2. Run `launch.py capacity --vault <vault> --project-dir <repo>`. When `free` is zero, set
   `status: queued`, sync the item, and tell the user it is queued; no notification event is
   sent. Reconsider queued items in the returned `queue` order when capacity frees.
3. Run `<skill-dir>/../implement-plan/scripts/route-target.sh --role orchestrator
   --project-dir <repo>`.
   When `usable` is `false`, keep the item at `status: queued`, ask `Claude at <percent>%,
   resets <relative resetsAt>. Start now or wait?`, and notify `quota-blocked` with
   `events.py notify`. On approval, continue with the selected target. When `quota` is
   `unavailable`, continue the launch, notify no event, and tell the user the warning: routing
   is fail-safe and does not stop a run. Take the model id after `claude:` from `target` for
   `--model`. When `target` is `null` (a failed script or output that is not
   JSON), print its `warnings` or stderr once and use `--model opus`, the built-in orchestrator
   default; this is not a quota block, so notify no event.
4. Before launching, write `status: running` and `workerKind`, clear `question`, and remove
   `stuck` and all `paused-*` keys from `notified` while preserving all other keys. This
   applies to relaunches too. Do this first because a worker that stops quickly records its own
   `stuck` or `paused-<id>`, and a later cleanup would erase it.
5. Run `launch.py command` with the item, kind, model, the dev-toolkit `notify-me.sh` path as
   `--notify-cmd` when it exists, `--herdr` when herdr spaces are on, and the required
   kind-specific arguments. Execute its
   returned `argv` without changing argument order. For a `ci`, `sync`, or `comments`
   launch, pass the item's `worktree` as `--worktree` only when that directory exists and is
   on the PR branch. Otherwise omit `--worktree`: address-pr then finds the PR worktree or
   creates it through the project's `/create-worktree`, so project setup runs. Never create
   an ad-hoc PR worktree for the worker. Its `--settings` env sets `HERDR_ENV=0`
   so the worker hook stays silent. If the launch fails, restore the item's
   previous `status` and sync. Otherwise record only `worker` and `sessionId`, without
   rewriting `status`, and sync the item. Then run `herdr.py open --item <item> --repo <repo>`
   to give the worker its space. For an `implement` launch, notify `impl-started`
   through `events.py notify`; other launch kinds have no notification event. Subscribe using
   an empty `SendMessage` with `notify_when_idle: true` immediately after launch. Then arm
   `events.py wait --vault <vault>` with `Bash(run_in_background: true)` when no wait is
   running, as in § "Watch". Keep exactly one wait: an existing wait ends within one interval
   because the new item became `running`; handle its result and re-arm then.

## Worker protocol

The launch helper appends this exact block to every worker prompt. Do not alter it here without
making the same exact change to `launch.py` and its comparison test.

```text
Worker protocol:
Item file: {item_path}
Repository: {repo_dir}
Worktree: {worktree_path}
Never edit the dossier directly; use python3 {events_path} worker-event for every dossier update.
Before ending with a needs input block, pass the whole block on stdin through this quoted heredoc, so the shell never expands its text:
python3 {events_arg} worker-event --item {item_arg} --line-file -{notify_arg} <<'PM_EVENT'
<whole needs input block>
PM_EVENT
After the skill's final done or stopped line, run the same command with that line as the heredoc body.
After either command, if `push` is non-null, call PushNotification with it.
```

## Watch

Run `events.py wait --vault <vault>` with `Bash(run_in_background: true)` while any item
is `running`, and arm it only when no wait is running. Its background-task completion is the
primary completion signal and wakes the project manager in any permission mode. Read its
JSON result and report each `warnings` entry once.

- On `changed`, read each listed item and follow its recorded event as for an idle notice.
  A new `running` item also ends the wait; read its state before continuing supervision.
- On `worker-gone`, reconcile each listed item: run `events.py last-reply --session
  <sessionId> --cwd <repo>` and record any final line through `worker-event` first, then
  apply the absent-worker row of § "Reconcile" if the item is still `running`.
- On `timeout`, reconcile every still-`running` item per § "Reconcile" before re-arming:
  use the session-first `agents` lookup below, then `last-reply` where the row calls for it.
  This catches idle workers with unrecorded final lines and workers waiting for user input.
- On `none`, no item is `running`; do not re-arm.

After each result, run `herdr.py sync --vault <vault> --repo <repo>` so finished workers'
spaces close. Except after `none`, re-arm one wait while any item is `running`.

Keep the idle notice as a secondary signal. Run `events.py worker-event --item <item>
--line-file -` for its final line, passing the line on stdin through a quoted heredoc; if the
notice is truncated, first run `events.py last-reply --session <sessionId> --cwd <repo>` and
use its `line`. Both signal paths are idempotent through `worker-event`, so reporting the
same final line from the worker and project manager is safe. Act on the recorded event and
item state, run `herdr.py sync --vault <vault> --repo <repo>`, then re-arm the empty
`SendMessage` subscription while the item remains active. Ensure one wait is armed while
any item is `running`; leave an existing wait running.

## Reconcile

For every active item, read the item and run `events.py agents --session <sessionId>`.
Read its `worker` result, not `byName`. If the item has no `sessionId`, use
`events.py agents --worker <worker>` instead. A null result means that worker is absent;
never fall back to a name when the item's session is absent from the records.
Check its plan-file checkboxes, run `gh pr view <pr> --json state,mergeable,reviews,statusCheckRollup` when it has a PR, and
run `events.py last-reply --session <sessionId> --cwd <repo>`. Workers start in the project manager's
repository root, so their transcripts live under that directory, not the worktree. After
reconciling, run `herdr.py sync --vault <vault> --repo <repo>` once to open missing spaces and
close finished ones; do not use its output as worker evidence. Reconcile the combinations as
follows:

| Observed combination | Action |
|---|---|
| Item is `running`; `agents` says its worker is `idle`; `last-reply.line` is a final line not yet recorded. | Run `events.py worker-event` with that line, then follow the resulting item event. |
| `agents` reports `status: waiting`. | The worker used `AskUserQuestion`. Keep its item status unchanged, tell the user to open the worker's `pm:<worker>` herdr space when available or run `claude attach <short id>`, and do not send it a message. |
| The worker is absent from `agents` or its record has no live `status`, but the item says `status: running`. | Set `status: stuck`, sync, notify `stuck`, and offer a relaunch rather than silently replacing the session. |
| GitHub confirms the PR is merged. | Continue with the after-merge procedure in the lifecycle reference. |

Do not trust GitHub `state` alone: use the item, merged PR details, reviews, checks, and worker
evidence together before changing a stage.

## Resuming a paused worker

A `paused` worker is either an `implement-plan` worker stopped by its own guard or an
`address-pr` worker waiting for a decision. The user can answer in `claude attach <short id>`
per `references/dossier.md` § "Worker names", or give the answer to the project manager.
Before forwarding an answer held by the project manager, run
`events.py agents --session <sessionId>` and read `worker`. Use
`events.py agents --worker <worker>` only when the item has no `sessionId`, as in
§ "Reconcile". A null session match does not permit a name fallback.
Send `SendMessage` only when that worker is `idle`; when it is `waiting`, the user must attach
because `AskUserQuestion` owns the reply path. After a successful forward, set
`status: running`, clear `question`, and remove `stuck` and all `paused-*` keys from
`notified` while preserving other keys; sync and re-arm `notify_when_idle`. Also arm
`events.py wait --vault <vault>` with `Bash(run_in_background: true)` when no wait is running,
per § "Watch". Apply the same state changes when reconciling a resume through `claude attach`.
Do not send a notification merely for the resume; the earlier `paused-<id>` notification already carries the attach command.

## Permissions and trust

Run the project manager from the repository root in permission mode `auto`, and ensure the workspace is
trusted before launching. Add the one-time allow rule for `Bash(claude --bg *)`: the worker
command begins with `claude --bg`, which is what the rule matches. Do not wrap the launch in
`cd <repo> && claude --bg ...`; that changes the shell command shape and the allow rule denies
it. The `launch.py command` result also supplies `--permission-mode auto`, so project manager and worker
can exchange messages in the same mode.
