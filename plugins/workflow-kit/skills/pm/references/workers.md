# Workers

Use this reference whenever launching, watching, reconciling, or resuming a background
worker. Keep the item file authoritative: sessions and notices are signals that help the project manager
bring that state up to date.

## Herdr mirror

Mirror `claude --bg` workers through `claude attach` panes. Never use `herdr agent start`:
native start would replace the background supervisor and require new watch, reconcile, and
resume procedures.

Enable the mirror only when the project manager runs inside herdr (`HERDR_ENV=1`) and `herdr` is on
`PATH`. It is on by default when available; set `pm.herdr: false` in
`.claude/workflow-kit.json` to disable it. Outside herdr, every mirror call is a silent no-op.
Control a herdr session only from inside herdr, because outside it there is no target pane
or socket to act on.

Use one workspace labeled with the feature name and one tab labeled with the item title.
Standalone items use the `project` workspace. The project manager's own pane stays where
the user runs it. All workers for an item share that tab. A relaunch of another kind replaces the attach pane
and names the agent after the worker using `references/dossier.md` § "Worker names".
The pane runs `command claude attach <worker>`. Keep the tab open until the item is `done`
or dropped through `references/lifecycle.md` § "Drop". Tabs are found by item title and
workspaces by feature name, so item titles must be unique within a feature, and two projects
that share a feature name share one workspace.

Never write herdr IDs to the dossier. Each call finds the workspace and tab by label, so a
restarted project manager can rebuild the view from item files alone. Use `events.py agents` and the
item file as the authoritative inputs to reconcile: herdr status is screen-scraped, lags the
worker, and can be wrong.

Find prepare/attach in `references/workers.md` § "Launch", ensure in
`references/workers.md` § "Reconcile", and close in `references/lifecycle.md` § "After merge (8)"
or `references/lifecycle.md` § "Drop".

Treat `skipped: true` as a no-op; when prepare returns no pane, skip attach. A mirror failure
returns `warning` in JSON; tell the user once and continue. Never let a mirror failure block
a launch, reconcile, or item write. Usage errors write to stderr and exit 2; report the
message once and continue the launch without the mirror. `herdr.py` closes only its item's
tab, and closes a workspace only when no tabs are left.

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
   `--model`. When `target` is `null` (invalid config, a failed script, or output that is not
   JSON), print its `warnings` or stderr once and use `--model opus`, the built-in orchestrator
   default; this is not a quota block, so notify no event.
4. Before launching, write `status: running` and `workerKind`, clear `question`, and remove
   `stuck` and all `paused-*` keys from `notified` while preserving all other keys. This
   applies to relaunches too. Do this first because a worker that stops quickly records its own
   `stuck` or `paused-<id>`, and a later cleanup would erase it.
5. Run `herdr.py prepare --item <item> --repo <repo>` and keep its returned pane for attach.
   Then run `launch.py command` with the item, kind, model, the dev-toolkit `notify-me.sh` path as
   `--notify-cmd` when it exists, and the required kind-specific arguments. Execute its
   returned `argv` without changing argument order. For a `ci`, `sync`, or `comments`
   launch, pass the item's `worktree` as `--worktree` only when that directory exists and is
   on the PR branch. Otherwise omit `--worktree`: address-pr then finds the PR worktree or
   creates it through the project's `/create-worktree`, so project setup runs. Never create
   an ad-hoc PR worktree for the worker. Its `--settings` env sets `HERDR_ENV=0`
   so the worker hook stays silent. If the launch fails, restore the item's
   previous `status` and sync. Otherwise record only `worker` and `sessionId`, without
   rewriting `status`, and sync the item. If prepare returned a pane, run
   `herdr.py attach --item <item> --pane <pane>`. For an `implement` launch, notify `impl-started`
   through `events.py notify`; other launch kinds have no notification event. Subscribe using
   an empty `SendMessage` with `notify_when_idle: true` immediately after launch.

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

Treat an idle notice as the primary completion signal. Run `events.py worker-event --item <item>
--line-file -` for its final line, passing the line on stdin through a quoted heredoc; if the
notice is truncated, first run `events.py last-reply --session <sessionId> --cwd <repo>` and
use its `line`. This is idempotent, which makes it safe when both worker and project manager report the
same final line. Act on the recorded event and item state, then re-arm the empty `SendMessage`
subscription while the item remains active.

A live project manager may also use `Monitor` loops for work that needs external observation. Use
`events.py agents` only as a restarted project manager's fallback, not as normal polling: the subscription
avoids missed completion while keeping the item file as the source of truth.

## Reconcile

For every active item, read the item and run `events.py agents`. Check its plan-file checkboxes,
run `gh pr view <pr> --json state,mergeable,reviews,statusCheckRollup` when it has a PR, and
run `events.py last-reply --session <sessionId> --cwd <repo>`. Workers start in the project manager's
repository root, so their transcripts live under that directory, not the worktree. For every
active item with a worker, run `herdr.py ensure --item <item> --repo <repo>` to rebuild a missing
mirror; do not use its output as worker evidence. Reconcile the combinations as follows:

| Observed combination | Action |
|---|---|
| Item is `running`; `agents` says its worker is `idle`; `last-reply.line` is a final line not yet recorded. | Run `events.py worker-event` with that line, then follow the resulting item event. |
| `agents` reports `status: waiting`. | The worker used `AskUserQuestion`. Keep its item status unchanged, tell the user to open the item's herdr tab when available or run `claude attach <worker>`, and do not send it a message. |
| The worker is absent from `agents`, but the item says `status: running`. | Set `status: stuck`, sync, notify `stuck`, and offer a relaunch rather than silently replacing the session. |
| GitHub confirms the PR is merged. | Continue with the after-merge procedure in the lifecycle reference. |

Do not trust GitHub `state` alone: use the item, merged PR details, reviews, checks, and worker
evidence together before changing a stage.

## Resuming a paused worker

A `paused` worker is either an `implement-plan` worker stopped by its own guard or an
`address-pr` worker waiting for a decision. The user can answer in `claude attach <worker>` or
give the answer to the project manager. Before forwarding an answer held by the project manager, run `events.py agents`.
Send `SendMessage` only when that worker is `idle`; when it is `waiting`, the user must attach
because `AskUserQuestion` owns the reply path. After a successful forward, set
`status: running`, clear `question`, and remove `stuck` and all `paused-*` keys from
`notified` while preserving other keys; sync and re-arm `notify_when_idle`. Apply the same
state changes when reconciling a resume through `claude attach`. Do not send a notification merely for
the resume; the earlier `paused-<id>` notification already carries the attach command.

## Permissions and trust

Run the project manager from the repository root in permission mode `auto`, and ensure the workspace is
trusted before launching. Add the one-time allow rule for `Bash(claude --bg *)`: the worker
command begins with `claude --bg`, which is what the rule matches. Do not wrap the launch in
`cd <repo> && claude --bg ...`; that changes the shell command shape and the allow rule denies
it. The `launch.py command` result also supplies `--permission-mode auto`, so project manager and worker
can exchange messages in the same mode.
