---
name: address-pr
description: |
  Act on feedback for your own open pull request: triage and fix review comments, fix failing
  CI checks, or merge the base branch into the PR and resolve conflicts. Fixes go through
  verified fix workers, get pushed, and each review thread gets a reply. Use this whenever the
  user wants to address, fix, or respond to PR comments or review feedback, make red PR checks
  green, or update a PR with main ("address PR comments", "fix CI on my PR", "PR checks are
  red", "update PR #N with main", "resolve conflicts on PR #N"). To review someone's PR, use
  pr-review instead; to open a new PR, use create-pr.
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
- `--worker` means another agent session (the **lead**) launched this run in the background
  and answers its questions. It changes only how this skill asks; see
  [Asking the user](#asking-the-user). Without it, this is a standalone run.

## Roles

- **Orchestrator:** this session. It runs git operations (fetch, merge, push, and a
  confirmed reset in sync mode) and GitHub calls, but it never edits file contents.
- **Fix worker:** applies only an assigned fix job in the PR worktree, verifies it, commits,
  and returns the required JSON handoff result.
- **Gate-verify worker:** verifies the worktree head after all fix workers finish.

## Shared definitions

The mode references cite these sections instead of repeating them.

### Fix jobs

Each mode produces zero or more fix jobs with this shape:

```text
{id, kind: comments|ci|conflict|verify, files, payload}
```

`id` is stable within the run. `files` lists the paths the job may touch; it may be empty
when the evidence names none. `payload` is mode-specific.

### Markers

Every comment or reply this skill posts ends with exactly one hidden marker on its own line.
The marker names what the post is, so a later run can tell its own posts apart:

| Marker | Posted by |
| --- | --- |
| `<!-- address-pr:fix -->` | comment-mode thread reply for a fixed item |
| `<!-- address-pr:answer -->` | comment-mode thread reply for an answer |
| `<!-- address-pr:pushback -->` | comment-mode thread reply for a pushback |
| `<!-- address-pr:comments -->` | comment-mode round summary |
| `<!-- address-pr:ci -->` | CI-mode round comment |
| `<!-- address-pr:sync -->` | sync-mode comment |

A body is this skill's post when it contains `<!-- address-pr:`. Posts use the user's own
`gh` account, which may also be the reviewer's account, so the marker is the only reliable
way to identify them. Separate markers keep the modes independent: a CI or sync comment must
never move the comment-mode cutoff, and a pushback must be distinguishable from an answer.

### Early exits

If a mode reports that there is nothing to do, CI is already green, or the branch is
already up to date, skip Steps 5–8. Release the lock, then run Step 9's report. Do not start
workers, push, or post anything. In a `--worker` run, the report must still end with
`address-pr: done #<number> no-push`.

## Steps

### Step 1: Resolve the PR

Run:

```bash
gh pr view <pr> --json number,url,state,isCrossRepository,headRefName,baseRefName,title,body
```

Refuse a PR that is not `OPEN`, and refuse a cross-repository (fork) PR; forks are out of
scope for v1. If the cwd is not inside a clone of the PR's repository and no `--worktree`
was supplied, refuse with a message naming `--worktree`.

### Step 2: Lock

Take the lock before touching any worktree, so two runs never race to create or change the
same PR worktree. From the clone (or the `--worktree` path), run:

```bash
lock="$(git rev-parse --path-format=absolute --git-common-dir)/address-pr-<number>.lock"
<skill-dir>/scripts/pr-lock.sh acquire "$lock"
```

It prints `locked <pid>` and exits 0 when this run holds the lock; record `<pid>` for
release. The script starts the holder in its own process group (`setsid flock -n -o`) and
confirms the holder is alive and owns the lock before it returns, as in
`../implement-plan/references/executors.md § "Executor entries"`.

If it prints `busy <pid> <start time>`, exit with `address-pr already running on #<number>`
and that line. Tell the user that a stale lock is freed with `kill -TERM -- -<pid>` (the
whole holder group).

Release the lock on every final exit path:

```bash
<skill-dir>/scripts/pr-lock.sh release "$lock" <pid>
```

A `--worker` question that ends the turn is not an exit: keep the lock; see
[Asking the user](#asking-the-user).

### Step 3: Worktree

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

If the worktree is dirty, stop and ask. Then, in the worktree, run:

```bash
git fetch origin <headRefName>
git merge --ff-only origin/<headRefName>
```

This works whether or not the local branch tracks an upstream. If the fast-forward fails
because the branch has diverged from the remote, stop and ask.

### Step 4: Mode

Follow exactly one mode reference:

- Default comment mode: `references/comment-mode.md`.
- `--ci` mode: `references/ci-mode.md`.
- `--sync` mode: `references/sync-mode.md`.

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
`PR_FIX_TIME_BUDGET` as the budget in seconds (default `1800`) and the standard-tier token
ceiling.

The handoff tells every worker to apply only its listed fixes, run `VERIFY_SKILL` and iterate
up to `SELF_VERIFY_LIMIT` times, commit with the project's commit convention, and end with:

```json
{"jobs":[{"id","outcome":"fixed|failed","commit","note"}]}
```

A job is `fixed` only when the worker returned `outcome: fixed` and its `commit` is an
ancestor of the worktree `HEAD`. Treat anything else (including a missing or unparseable
result, or a runaway-guard stop) as `failed`. Mode references say what a failed job means
for write-back.

### Step 6: Gate verify

After all workers finish, if no job produced a commit and the mode made no merge commit,
skip the gate and Step 7. Otherwise, run one gate verify of the worktree head. Delegate it
with the target from `route-target.sh --role gateVerify --project-dir <repo-root>`, unless
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

Perform the mode-specific write-back after the push, so replies can cite pushed SHAs. When
Step 6 skipped the push because nothing was committed, write back directly; never cite an
unpushed SHA. If the push did not happen for any other reason (red gate, rejected push), do
not write back. End every post with its marker from [Markers](#markers).

### Step 9: Report

Give a terminal summary with the PR URL, mode, every job's outcome and worker target (with
the router `reason`), gate result, pushed SHA, and anything requiring the user. Print each
router `warnings` entry once. In a `--worker` run, end the final reply with exactly:

```text
address-pr: done #<number> <pushed-sha|no-push>
```

## Asking the user

Whenever a step says "ask", do not guess: stop and get the user's decision before acting.

- **Standalone (no `--worker`):** use `AskUserQuestion` and wait.
- **`--worker`:** do not use `AskUserQuestion`. A background session blocks on it, and a
  `SendMessage` from the lead cannot answer it, so the run would hang. Instead, end the turn
  with a plain-text block whose first line is exactly `address-pr: needs input #<number>`,
  followed by the question and options. Keep the lock and worktree unchanged. The next user
  turn, through `claude attach` or the lead's `SendMessage`, is the answer; resume from the
  step that asked. Notifying the user is the lead's job, not this skill's.

## Configuration

Set these through the environment or project `CLAUDE.md`:

- `VERIFY_SKILL` — default `/verify`.
- `SELF_VERIFY_LIMIT` — default `2`.
- `PR_FIX_MODEL` — `executor:model` pin for fix workers; skips routing. The default is
  `claude:sonnet` when routing returns `null`.
- `VERIFY_AGENT_MODEL` — pins gate verify.
- `PR_FIX_TIME_BUDGET` — fix-worker wall-clock budget in seconds; default `1800` (30 min),
  as for `PHASE_TIME_BUDGET`.
- `PR_BOT_ALLOWLIST` — default
  `copilot-pull-request-reviewer,copilot-pull-request-reviewer[bot],coderabbitai,coderabbitai[bot]`.
- `CI_FIX_MAX_ROUNDS` — default `2`.
- `CI_WAIT_TIMEOUT` — default 30 min (`30m` in `timeout(1)` syntax).
- `CI_REPRO_COMMAND` — optional local command mirroring CI for `--ci` checks whose logs gh
  cannot fetch.

For routing configuration files, precedence, router output, and fail-safe behavior, see
`../implement-plan/references/routing.md`.
