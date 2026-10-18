# Lifecycle

Use this procedure after the handoff plan is complete. Keep the item file as the
source of truth: make item changes with `dossier.py item set`, regenerate and
sync through `dossier.py sync --board <feature-dir>`, and never hand-edit the
board. Read `references/dossier.md` § "Item format" before changing fields and
`references/dossier.md` § "Events" before notifying, so recovery and a resumed
project manager see the same state.

## Implement (4)

After `plan-done`, start the implementation launch procedure. Set `stage:
implement`, `status: running`, `worker`, `sessionId`, and `workerKind:
implement`; `updated` changes with the write. Notify `impl-started` after the
launch is recorded. The worker proceeds without an approval stop, because design
review and the user's PR review are the decision points.

Let `events.py worker-event` record a worker final line before acting on it. For
an exhausted rescue or runaway-guard `needs input` block, it writes `status:
paused`, `question`, `notified` (with `paused-<id>`), and `updated`, and logs the
pause. Show the worker's options and recommendation from that block; the
notification includes its attach command. On `stuck`, it writes `status: stuck`,
adds `stuck` to `notified`, updates `updated`, and logs the reason. Notify
`stuck`, then ask before any relaunch, since spending another worker is a project manager
decision.

## PR open (5)

When the implementation final line is `implement-plan: done <key> <url>`, let
`worker-event` first write `stage: pr`, `status: idle`, `pr`, `branch`,
`worktree`, `unplanned`, and `updated`; it also logs `impl-done`. Watch that
PR's checks. A live project manager arms a `Monitor` loop over `gh pr checks <n> --json
name,bucket`, emitting only a terminal `pass`, `fail`, or `cancel` bucket.

On red, launch one `ci` worker and write `status: running`, `worker`,
`sessionId`, `workerKind: ci`, and `updated`. Its completed final line restores
`status: idle`, updates `updated`, and logs `ci-fixed`; it sends no notification.
On green, when `origin` is not `implement-plan`, run `/dev-toolkit:pr-review` in
a sub-agent and append its findings as an item note (therefore updating
`updated`). Then add `pr-ready` to `notified`, update `updated`, and notify
`pr-ready`. Include `, <unplanned> unplanned decisions` in that notification
when `unplanned` is above `0`, and surface those decisions in the next briefing.
The user, not the project manager, performs stage-5 review.

## Review rounds (6)

Detect a newly submitted user review (`COMMENTED` or `CHANGES_REQUESTED`) newer
than `reviewSeen` through a Monitor loop over `gh pr view <n> --json reviews`,
on rehydrate, or when the user asks to address comments. Record the newest
handled timestamp in `reviewSeen`, set `stage: review` and `status: running`,
and write `worker`, `sessionId`, `workerKind: comments`, and `updated` before
launching one comments worker. This prevents duplicate rounds when the project manager is
restarted.

On a completed comments worker, `worker-event` writes `status: idle`, increments
`round`, adds `fix-pushed-<round>` to `notified`, and updates `updated`. Notify
that event. Do not run another
`pr-review` for a fix round. If address-pr cannot settle pushback, its `needs
input` block writes `status: paused`, `question`, `notified:
paused-<id>`, and `updated`, logs the pause, and notifies `paused-<id>`; present
the question to the user.

## Merge (7)

The user merges the PR. The project manager records no merge command and does not alter
the branch or remote for this step. Once the merged state is confirmed, continue
with After merge.

## After merge (8)

Set `stage: merged`, then set `stage: done` and `status: idle`; each write sets
`updated`. Run `herdr.py close --item <item>` after `stage: done`.
Log `phase-done` after the completed transition, with no notification.
Read `### Unplanned Decisions` from the merged PR body. Append every decision
that survived review to the appropriate `decisions.md` using source `PR #<n>
unplanned` and its suggested scope. Log a review reversal with source `user
reversal`. Ask about scope only when the default is project scope; record
the project manager's ask by adding `decision-<n>` to `notified`, updating `updated`, and
notifying `decision-<n>`.

Run the merge-time sync check across this vault only: enumerate active items
under `<vault>/Features/*/items/*.md`, including `_project/items/`, and select
each item with an open `pr`. Do not scan sibling vaults. For each, run
`gh pr view <pr> --json state,mergeable`. For every open `CONFLICTING` PR, subject to the global capacity, launch one `sync` worker
and write that item's `status: running`, `worker`, `sessionId`, `workerKind:
sync`, and `updated`. When it finishes, `worker-event` writes `status: idle`,
updates `updated`, and logs `synced`, with no notification. Suggest the next
unblocked item across the project after this scan. Then run
`scan.py scan --vault <vault> --project-dir <repo> --exclude-session <supervisor-name>`
(omit `--exclude-session` when the supervisor name is unknown) to refresh the inbox, present
its entries as in `references/project.md` § "Discovery and inbox", and run
`dossier.py sync --vault <vault> -m "pm: after merge discovery" --board
<vault>/Features/_project -- <vault>/Features/_project/inbox.md`, including any
other paths touched and `--board <feature-dir>` for each affected feature.

## Drop

Drop an item to stop pursuing it while keeping its dossier history. Run `events.py agents`;
if the item's worker is live, find its short id in `claude agents --json --all` and run
`claude stop <short id>` before closing the tab, because a dropped item's worker would keep
spending quota unmirrored. Set `stage: dropped` and `status: idle` with `dossier.py item set`,
then sync through `dossier.py sync --board <feature-dir>` as in After merge (8). Run
`herdr.py close --item <item>` to remove its mirror tab.

## Retro (9)

Offer `/dev-toolkit:pr-retro <n>` after merge; recommend skipping it for a small
PR (about fewer than 200 changed lines). The retro may propose brief updates,
design-review checklist additions, and stable project decisions. Apply only
changes the user approves through the dossier workflow, so the proposal does
not silently change future work. The project manager runs the retro analysis and gets the
approval itself. It writes no item field unless an approved item
note is added (then `updated` changes); append `retro-ready` to `log.md` and do
not notify it. Stable project decisions belong in the project `decisions.md`.

The project manager does not edit repository files for approved fixes (skill files, rules,
harness config). It does not commit or open PRs for them. A headless Claude
worker makes the edits and opens or updates the PR. The project manager writes only the
dossier: brief, decisions, and log.

`launch.py command` has no `retro` kind. Start the worker with the same argv
shape it returns for other kinds: `claude --bg --permission-mode auto --model
<model> -n <feature>-retro-<pr> ...`. The prompt names the approved findings,
the target repo and branch, and whether to open a new PR or update an existing
one.

## Monitor loops

Use at most one loop per watched PR. Arm it with the maximum timeout and re-arm
it after expiry while the item remains active. A loop only reports actionable
lines: check terminal buckets for CI and newly submitted user reviews for review
rounds. Treat command failure, missing PR data, cancellation, and expiry as
explicit states: log the observed detail without changing item fields, retry on
the next re-arm or rehydrate, and do not emit an unsupported notification.
Monitor loops are optional because rehydration repeats the same checks after a
project manager session closes.

Never merge a PR, force-push, or instruct a worker to do either.
