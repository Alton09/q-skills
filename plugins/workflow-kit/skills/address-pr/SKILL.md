---
name: address-pr
description: |
  Address PR comments, fix review comments, fix CI on my PR, handle PR checks that are red,
  update a PR with main, or resolve conflicts on PR #N. Works standalone and as a tech-lead
  worker to triage, delegate, verify, push, and report fixes for an open pull request.
---

# Address PR

Address an open PR without editing code in this session. This session is the
**orchestrator**: it resolves the PR, triages, writes GitHub replies, and makes decisions.
All code edits go to fix workers.

## Invocation

```text
/workflow-kit:address-pr [<pr-number|url>] [--ci | --sync] [--worktree <path>] [--worker]
```

- With no PR argument, use the PR for the current branch:
  `gh pr view --json number`.
- With no mode flag, use comment mode. `--ci` and `--sync` are mutually exclusive; refuse
  an invocation with both.
- `--worktree <path>` uses that worktree instead of searching for one. Run every git and
  gh command there (`git -C <path>` and gh from that directory).
- `--worker` means the tech lead launched this run. It changes only how this skill asks the
  user; without it, this is a standalone run.

## Roles

- **Orchestrator:** this session. It never edits code itself.
- **Fix worker:** applies only an assigned fix job in the PR worktree, verifies it, commits,
  and returns the required JSON handoff result.
- **Gate-verify worker:** verifies the worktree head after all fix workers finish.

## Steps

### Step 1: Resolve the PR

Run:

```bash
gh pr view <pr> --json number,url,state,isCrossRepository,headRefName,baseRefName,title,body
```

Refuse a PR that is not `OPEN`, and refuse a cross-repository (fork) PR; forks are out of
scope for v1. If the cwd is not inside a clone of the PR's repository and no `--worktree`
was supplied, refuse with a message naming `--worktree`.

### Step 2: Worktree

With `--worktree <path>`, check that the path is a worktree whose branch is
`<headRefName>`; refuse a mismatch. Without it, find a worktree whose branch is
`refs/heads/<headRefName>` with `git worktree list --porcelain`. If none exists, run
`git fetch origin <headRefName>`. Resolve `<repo-root>` with `git rev-parse --show-toplevel`
and make `<abs-sibling>` the absolute path `dirname(<repo-root>)/<repo>-pr-<number>`. From
`<repo-root>`, if `refs/heads/<headRefName>` is missing, run:

```bash
git worktree add -b <headRefName> <abs-sibling> origin/<headRefName>
```

Otherwise, add `<abs-sibling>` with the existing local `<headRefName>` branch. Do not use
`/create-worktree`, which creates new branches in consumer projects.

If the worktree is dirty, stop and ask. Then run `git pull --ff-only`. If the branch has
diverged from the remote, stop and ask.

### Step 3: Lock

Take a non-blocking lock so two runs never work on the same PR. Use `flock -n` on
`$(git rev-parse --git-common-dir)/address-pr-<number>.lock`, held by a
`setsid flock -o <lock> sleep infinity &` holder. This follows the device-reservation
pattern in `../implement-plan/references/executors.md § "Executor entries"`. Write the
holder PID and start time to `<lock>.pid`.

If the lock is busy, exit with `address-pr already running on #<number>` and the pidfile
contents. Tell the user that a stale lock is freed with `kill <pid>`. Release the lock on
every final exit path. A `--worker` question that ends the turn is not an exit: keep the
lock; see [Asking the user](#asking-the-user).

### Step 4: Mode

Follow exactly one mode reference. Each mode produces zero or more fix jobs with this shape:

```text
{id, kind: comments|ci|conflict|verify, files, payload}
```

- Default comment mode: `references/comment-mode.md`.
- `--ci` mode: `references/ci-mode.md`.
- `--sync` mode: `references/sync-mode.md`.

### Early exits

If a mode reports that there is nothing to do, CI is already green, or the branch is
already up to date, skip Steps 5–8. Release the lock, then run Step 9's report. In a
`--worker` run, the report must still end with `address-pr: done #<number> no-push`.

### Step 5: Fix workers

Run fix jobs one at a time in the PR worktree. Each worker may stage and commit its assigned
changes, so serial execution prevents concurrent `git add` and `git commit` mutations.

Before each spawn, unless `PR_FIX_MODEL` pins the role, call:

```bash
<skill-dir>/../implement-plan/scripts/route-target.sh --role prFix --project-dir <repo-root>
```

Do not pass `--tier`: `prFix` has no tier. A `null` target resolves to `claude:sonnet`.
`PR_FIX_MODEL` is an `executor:model` value that pins the fix-worker role and skips routing.
Spawn through `../implement-plan/references/executors.md § "Executor entries"`, including
the codex `.agents` setup. Apply `../implement-plan/references/runaway-guard.md` with
`PR_FIX_TIME_BUDGET` (default `30m` for `timeout(1)`) and the standard-tier token ceiling.

The handoff tells every worker to apply only its listed fixes, run `VERIFY_SKILL` and iterate
up to `SELF_VERIFY_LIMIT` times, commit with the project's commit convention, and end with:

```json
{"jobs":[{"id","outcome":"fixed|failed","commit","note"}]}
```

### Step 6: Gate verify

After all workers finish, run one gate verify of the worktree head. Delegate it with the
target from `route-target.sh --role gateVerify --project-dir <repo-root>`, unless
`VERIFY_AGENT_MODEL` pins the role. If it is red, spawn one `kind: verify` fix job carrying
the failure output, then gate again. After `SELF_VERIFY_LIMIT` red gates, do not push:
report and ask.

### Step 7: Push

Push with:

```bash
git push origin HEAD:<headRefName>
```

Never force-push, in any mode. If the push is rejected because the remote moved, stop and
ask.

### Step 8: GitHub write-back

Perform mode-specific GitHub write-back after the push so replies can cite pushed SHAs.
Every comment or reply posted by this skill ends with this hidden marker:

```html
<!-- address-pr -->
```

Posts use the user's own `gh` account, which may also be the reviewer's account; the marker
is the only reliable way to distinguish this skill's posts.

### Step 9: Report

Give a terminal summary with the PR URL, mode, every job's outcome and worker target (with
the router `reason`), gate result, pushed SHA, and anything requiring the user. Print each
router `warnings` entry once. In a `--worker` run, end the final reply with exactly:

```text
address-pr: done #<number> <pushed-sha|no-push>
```

## Asking the user

Whenever a step says “ask”, do not guess. This is the Ask tier from the tech-lead design.

- **Standalone (no `--worker`):** use `AskUserQuestion` and wait.
- **`--worker`:** do not use `AskUserQuestion`. End the turn with a plain-text block whose
  first line is exactly `address-pr: needs input #<number>`, followed by the question and
  options. Keep the lock and worktree unchanged. The next user turn, through `claude attach`
  or the lead's `SendMessage`, is the answer; resume from the step that asked.

A `--bg` worker blocks on `AskUserQuestion`, while the lead's `SendMessage` cannot answer it;
a message sent during a pending question was lost. Writing item-file `status: ask` and
sending notifications belong to the lead's launch prompt; address-pr does not touch the
vault.

## Configuration

Set these through the environment or project `CLAUDE.md`:

- `VERIFY_SKILL` — default `/verify`.
- `SELF_VERIFY_LIMIT` — default `2`.
- `PR_FIX_MODEL` — `executor:model` pin for fix workers; skips routing. The default is
  `claude:sonnet` when routing returns `null`.
- `VERIFY_AGENT_MODEL` — pins gate verify.
- `PR_FIX_TIME_BUDGET` — default 30 min (`30m` in `timeout(1)` syntax).
- `PR_BOT_ALLOWLIST` — default
  `copilot-pull-request-reviewer,copilot-pull-request-reviewer[bot],coderabbitai,coderabbitai[bot]`.
- `CI_FIX_MAX_ROUNDS` — default `2`.
- `CI_WAIT_TIMEOUT` — default 30 min (`30m` in `timeout(1)` syntax).
- `CI_REPRO_COMMAND` — optional local command mirroring CI for `--ci` checks whose logs gh
  cannot fetch.

For routing configuration files, precedence, router output, and fail-safe behavior, see
`../implement-plan/references/routing.md`.
