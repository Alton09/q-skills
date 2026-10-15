# Workers

Use this reference whenever launching, watching, reconciling, or resuming a background
worker. Keep the item file authoritative: sessions and notices are signals that help the lead
bring that state up to date.

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
3. Run `../../implement-plan/scripts/route-target.sh --role orchestrator --project-dir <repo>`.
   When `usable` is `false`, keep the item at `status: queued`, ask `Claude at <percent>%,
   resets <relative resetsAt>. Start now or wait?`, and notify `quota-blocked` with
   `events.py notify`. On approval, continue with the selected target. When `quota` is
   `unavailable`, set `status: running` after launch, notify no event, and tell the user the
   warning: routing is fail-safe and does not stop a run. Take the model id after `claude:`
   from `target` for `--model`.
4. Run `launch.py command` with the item, kind, model, and required kind-specific arguments,
   then execute its returned `argv` without changing argument order. Record `worker`,
   `sessionId`, `workerKind`, and `status: running`. Before syncing, remove `stuck` and all
   `paused-*` keys from `notified`, preserving all other keys, and clear `question`. This
   applies to relaunches too; sync the item. For an `implement` launch,
   notify `impl-started` through `events.py notify`; other launch kinds have no notification
   event. Subscribe using an empty `SendMessage` with `notify_when_idle: true` immediately
   after launch.

## Worker protocol

The launch helper appends this exact block to every worker prompt. Do not alter it here without
making the same exact change to `launch.py` and its comparison test.

```text
Worker protocol:
Item file: {item_path}
Repository: {repo_dir}
Worktree: {worktree_path}
Never edit the dossier directly; use python3 {events_path} worker-event for every dossier update.
Before ending with a needs input block, run `python3 {events_path} worker-event --item {item_path} --line "<whole needs input block>" --notify-cmd <notify-cmd>`; if `push` is non-null, call PushNotification with it.
After the skill's final done or stopped line, run the same command with that line; if `push` is non-null, call PushNotification with it.
```

## Watch

Treat an idle notice as the primary completion signal. Run `events.py worker-event --item <item>
--line <final-line>` for its final line; if the notice is truncated, first run
`events.py last-reply --session <sessionId> --cwd <worktree>` and use its `line`. This is
idempotent, which makes it safe when both worker and lead report the same final line. Act on
the recorded event and item state, then re-arm the empty `SendMessage` subscription while the
item remains active.

A live lead may also use `Monitor` loops for work that needs external observation. Use
`events.py agents` only as a restarted lead's fallback, not as normal polling: the subscription
avoids missed completion while keeping the item file as the source of truth.

## Reconcile

For every active item, read the item and run `events.py agents`. Check its plan-file checkboxes,
run `gh pr view <pr> --json state,mergeable,reviews,statusCheckRollup` when it has a PR, and
run `events.py last-reply --session <sessionId> --cwd <worktree>`. Reconcile the combinations
as follows:

| Observed combination | Action |
|---|---|
| Item is `running`; `agents` says its worker is `idle`; `last-reply.line` is a final line not yet recorded. | Run `events.py worker-event` with that line, then follow the resulting item event. |
| `agents` reports `status: waiting`. | The worker used `AskUserQuestion`. Keep its item status unchanged, tell the user to run `claude attach <worker>`, and do not send it a message. |
| The worker is absent from `agents`, but the item says `status: running`. | Set `status: stuck`, sync, notify `stuck`, and offer a relaunch rather than silently replacing the session. |
| GitHub confirms the PR is merged. | Continue with the after-merge procedure in the lifecycle reference. |

Do not trust GitHub `state` alone: use the item, merged PR details, reviews, checks, and worker
evidence together before changing a stage.

## Resuming a paused worker

A `paused` worker is either an `implement-plan` worker stopped by its own guard or an
`address-pr` worker waiting for a decision. The user can answer in `claude attach <worker>` or
give the answer to the lead. Before forwarding a lead-held answer, run `events.py agents`.
Send `SendMessage` only when that worker is `idle`; when it is `waiting`, the user must attach
because `AskUserQuestion` owns the reply path. After a successful forward, set
`status: running`, clear `question`, and remove `stuck` and all `paused-*` keys from
`notified` while preserving other keys; sync and re-arm `notify_when_idle`. Apply the same
state changes when reconciling a resume through `claude attach`. Do not send a notification merely for
the resume; the earlier `paused-<id>` notification already carries the attach command.

## Permissions and trust

Run the lead from the repository root in permission mode `auto`, and ensure the workspace is
trusted before launching. Add the one-time allow rule for `Bash(claude --bg *)`: the worker
command begins with `claude --bg`, which is what the rule matches. Do not wrap the launch in
`cd <repo> && claude --bg ...`; that changes the shell command shape and the allow rule denies
it. The `launch.py command` result also supplies `--permission-mode auto`, so lead and worker
can exchange messages in the same mode.
