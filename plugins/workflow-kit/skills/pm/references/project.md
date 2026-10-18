# Project

Use this reference for repository-wide supervision, discovery, standalone work, and the
single-supervisor lock. `<repo>` is the repository root and `<vault>` is its resolved vault.

## Project mode

1. Run Startup in the skill, including `lock.py acquire --project-dir <repo>`. Continue with
   supervision only on `ok: true`; otherwise follow the Lock section below.
2. Run `dossier.py init-project --vault <vault>`. This idempotently creates the project
   decisions, log, items directory, and union merge attributes even when no feature exists.
   Run `dossier.py sync --vault <vault> -m "pm: initialize project" --board
   <vault>/Features/_project -- <vault>/.gitattributes <vault>/Features/_project/decisions.md
   <vault>/Features/_project/log.md` when initialization touched those files. With
   `--from <master-plan>`, defer all vault syncs until the bootstrap approval in the skill.
3. Run `dossier.py list --vault <vault>` to enumerate features and standalone item counts.
   Refresh discovery using the Discovery and inbox section below, then run
   `dossier.py board --project --vault <vault>` so the board includes the current inbox.
4. Follow Rehydrate in the skill for lazy context, reconciliation of every active item in
   this vault, the grouped briefing, and the log-and-board sync. The discovery refresh in
   step 3 is the scan for this rehydrate. Keep supervising all features and standalone items;
   suggest the next unblocked item across the project using the existing launch gates.

## Discovery and inbox

On every rehydrate and after each merge, run
`scan.py scan --vault <vault> --project-dir <repo>`. Add
`--exclude-session <supervisor-name>` when the supervising session's name is known; repeat
it for any other known supervisor session names. The scan groups untracked open PRs,
branches, worktrees, and sessions, excludes tracked and ignored entries, and writes
`<vault>/Features/_project/inbox.md`. Source failures appear in `warnings`; show them and
continue with the available entries. Never hand-edit the generated inbox.

Present each entry's `key`, title, and available PR, branch, worktree, session, author, and
draft metadata. Offer the three triage choices below. The project manager never adopts an
entry on its own; wait for the user's choice and target before running an adoption command.
An unanswered entry stays in the inbox. Ignore also follows the user's triage choice.

- Add to an existing feature: run `scan.py adopt --vault <vault> --project-dir <repo>
  --key <key> --feature <feature> --slug <slug>`, optionally with `--title <title>`. The feature
  must already exist. Then run `dossier.py sync --vault <vault> -m "pm: adopt discovery"
  --board <vault>/Features/<feature> -- <returned-file> <returned-inbox>`.
- Track as standalone: run `scan.py adopt --vault <vault> --project-dir <repo> --key <key>
  --standalone --slug <slug>`, optionally with `--title <title>`. Then run
  `dossier.py sync --vault <vault> -m "pm: adopt standalone" --board <vault>/Features/_project
  -- <returned-file> <returned-inbox>`.
- Ignore: run `scan.py ignore --vault <vault> --key <key>`. Then run
  `dossier.py sync --vault <vault> -m "pm: ignore discovery" --board <vault>/Features/_project
  -- <returned-ignored> <returned-inbox>`. The ignored key is append-only and future scans
  omit it.

Adoption rescans before creating the item. If the key is absent, report the error, refresh
with `scan.py scan --vault <vault> --project-dir <repo>`, and present the current choices;
do not substitute another entry. Adoption sets `origin: external`, `status: idle`, and the
available PR, branch, worktree, and worker fields. A PR starts at `stage: pr`; other entries
start at `stage: implement`. Continue the existing lifecycle from that stage.

Include the generated inbox in the rehydrate or after-merge sync even when no entry is
triaged. Every sync above regenerates the project board through `--board`; include any
other touched dossier paths in the same sync. Treat `ok: false` as a visible stop as in
`references/dossier.md` § "Command contract".

## Standalone items

Standalone items live in `<vault>/Features/_project/items/` and use the label `project`.
Suggest one instead of a feature for a single PR with no brief-worthy context. Keep the
same Stages 1–9, decision tiers, user boundaries, launch gates, and worker lifecycle; the
project decisions supply context and standalone events go to `_project/log.md`.

For user-approved new standalone work, run `dossier.py item new --feature-dir
<vault>/Features/_project --slug <slug> --title <title>` after project initialization. Set
fields with `dossier.py item set <item> <key>=<value>...`, and sync touched paths with
`dossier.py sync --vault <vault> -m "pm: standalone item" --board <vault>/Features/_project
-- <item>`, adding any decision or log paths written. Use `_project` as the feature directory
for dossier commands, and `project/<slug>` in cross-item `blockedBy` references. Worker names
are `project-<slug>[-<kind>]`, notifications start with `[project]`, and herdr uses the
`project` workspace. No standalone brief is required.

## Lock

Run `lock.py acquire --project-dir <repo>` before launching or reconciling. The lock is
`<git-common-dir>/pm.lock`, shared by every worktree of the repository and outside the vault.
Its holder is `{pid, host, cwd, startedAt}`; the owner is the nearest `claude` ancestor.
A same-owner acquire succeeds. A stale local holder is taken over automatically: its process
has exited or no longer identifies as `claude`. Remote-host holders cannot be checked locally
and require force. A missing `claude` ancestor returns `ok: false` with
`reason: "no claude ancestor"`; run supervision from Claude instead of inventing an owner.

When acquire returns `ok: false`, show the holder and reason, launch and reconcile nothing,
and offer to return to the holder or force takeover. Force is an ask decision: only after
explicit confirmation run `lock.py acquire --project-dir <repo> --force`, and continue only
on `ok: true`. Force cannot fix a missing Claude ancestor. Read-only answers remain available.
For `show the board`, run `dossier.py board --project --vault <vault>` and print
`<vault>/Features/_project/board.md`; skip discovery, dossier sync, launches, and reconciliation.

Run `lock.py status --project-dir <repo>` to inspect `{held, holder, stale}` without writing.
Never launch or reconcile without holding the lock; after an ownership change, acquire it
again before supervising. When the user ends the session, run
`lock.py release --project-dir <repo>`; only the owner removes it. An exited session leaves a
stale lock that the next local owner can acquire.
