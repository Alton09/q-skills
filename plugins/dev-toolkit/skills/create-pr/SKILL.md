---
name: create-pr
description: |
  Open a pull request for the current branch — as a single draft PR, or as a
  stack of stacked PRs (one per layer, each targeting the one below) when the
  branch changes more production code than a reviewer can absorb in one sitting.

  Use this skill whenever the user wants to open, create, raise, or put up a PR
  or MR for a branch, or says anything about stacked PRs, splitting a PR, a
  branch being "too big to review", breaking a change into reviewable chunks,
  or asks how many lines a branch actually changed. Also use it when a workflow
  (such as implement-plan) finishes a branch and needs it shipped for review.

  Trigger even when the user just says "open a PR" without mentioning size —
  measuring the branch and choosing single vs stacked is the whole point, and
  they can't ask for a split they don't yet know they need.
---

# Create PR

Turn a finished branch into review-ready pull requests. The decision this skill exists to
make is **one PR or a stack**, and it makes that decision from what the branch actually
changed rather than from a guess.

Large PRs get rubber-stamped. Splitting a 900-line change into three 300-line PRs that each
build on the last is what stacked PRs are for — GitHub keeps them in a chain, shows the
stack in the merge box, and re-targets the survivors automatically as each one lands.

## Two modes

The skill needs **cut points** — the commits where one layer ends and the next begins. Where
they come from is the difference between the modes:

- **Ledger mode.** A caller hands you cut points it recorded while building the branch (see
  "Ledger handoff" below). These are trustworthy: each one was a real, verified checkpoint.
  Run non-interactively — the caller is usually an agent, not a person.
- **Cold mode.** You were pointed at an existing branch with no ledger. Derive candidate
  cuts from commit history, then **show them to the user and get confirmation** before
  creating anything. This matters: an arbitrary cut can produce a middle layer that doesn't
  compile, and unlike ledger mode nothing has verified those intermediate states. Proposing
  rather than assuming is the honest move.

## Workflow

1. **Preconditions** — remote, `gh` auth, clean tree, same-repo base
2. **Measure** — production lines changed on the branch
3. **Choose shape** — single PR at or under `STACK_THRESHOLD_LINES`, stack above it
4. **Get cut points** — from the ledger, or propose them and confirm (cold mode)
5. **Create** — push and open draft PRs
6. **Report** — links, per-layer sizes, merge order

## Step 1: Preconditions

Check before doing anything that touches the remote. Report and stop on failure rather than
working around it — each of these means the user has something to fix:

| Check | Command | On failure |
|---|---|---|
| Inside a git repo with a remote | `git remote` | Stop — nothing to push to |
| `gh` authenticated | `gh auth status` | Stop — tell them to run `gh auth login` |
| Working tree clean | `git status --porcelain` | Ask whether to commit or stash first |
| Branch is not the base branch | `git branch --show-current` | Stop — you'd be opening a PR against itself |
| Base is in the same repo | `gh repo view --json nameWithOwner` | Force single-PR: GitHub stacks are same-repo only |

`PR_BASE_BRANCH` defaults to the repo's default branch (`gh repo view --json defaultBranchRef`).

## Step 2: Measure production churn

The threshold is about reviewer burden, so count production code only — no tests, no
generated output, no comments, no blank lines — and count additions **and** deletions, since
a large deletion is real review work.

```
<skill-dir>/scripts/count-prod-lines.sh <PR_BASE_BRANCH>...HEAD
```

Use the absolute path — `<skill-dir>` is this skill's base directory, which your harness
gives you when the skill loads. The working directory is the user's repo, not the skill's,
so a relative path silently fails and tempts you into hand-rolling the count instead. Don't:
the script exists so the number is the same every run and reviewable by the user.

It prints `PROD_LINES`, `ADDED`, `DELETED`, `SKIPPED_COMMENT`, `SKIPPED_BLANK`, `FILES`.
`PROD_LINES` (added + deleted) is the number the threshold compares against.

The triple-dot form measures from the merge base, so a stale branch isn't penalized for
commits that landed on the trunk after it forked.

**What's excluded** — test paths (`**/test/**`, `**/*Test.*`, `**/*.spec.*`, …), build and
generated output, vendored code, lockfiles, and non-code files (`*.md`, `*.json`, images).
Override the whole list with `PR_PROD_EXCLUDES` (space-separated git pathspecs) when a
project's layout doesn't match — Android's `src/androidTest/` is covered by default, a
project that keeps tests in `spec/` is not.

Comment detection is prefix-based per language (`//`, `/*`, `*`, `#`, `--`) and treats
unknown extensions as code. That over-counts rather than under-counts, so the failure mode is
a stack you didn't need rather than an accidentally-enormous single PR.

Always report the number, whichever shape you pick. A user who disagrees with the split needs
to see what drove it.

## Step 3: Choose the shape

- `PROD_LINES` ≤ `STACK_THRESHOLD_LINES` (default 500) → **one draft PR**. Skip to Step 5.
- Above the threshold → **stack**, continue to Step 4.
- Above the threshold but the branch can't be split (one commit, or cut points unavailable)
  → one PR, plus a plain warning naming the count. Don't pretend a single-layer "stack"
  helps.

## Step 4: Get cut points

**Ledger mode** — use the supplied SHAs in order. Nothing to compute.

**Cold mode** — propose cuts from history:

```
<skill-dir>/scripts/propose-cuts.sh <PR_BASE_BRANCH> HEAD <STACK_THRESHOLD_LINES>
```

It walks `--first-parent` commits oldest-first, measures cumulative production lines at each,
and picks boundaries that divide the branch into roughly equal layers — equal beats
"fill to threshold then a straggler", since a 40-line trailing PR wastes a review cycle. Cuts
always land on existing commits, because a stack layer has to be a contiguous prefix of
history; nothing is reordered or cherry-picked. It exits 3 when the branch has fewer than two
commits.

Show the user the proposal before creating anything:

```
This branch changes 812 production lines (690 added, 122 deleted; tests, comments,
and generated code excluded). Proposed 2-layer stack:

  1. through "add repository + DAO"     — 402 lines
  2. through "wire up favorites screen" — 410 lines

Each layer becomes a draft PR targeting the one below. Note these cut points come from
commit history, so intermediate layers aren't verified to build on their own.
Go ahead, adjust the split, or open one PR instead?
```

Take their edits — a different commit, more or fewer layers — and re-run the numbers so the
sizes you show always match the cuts you'll make.

## Step 5: Create

**Single PR:**

```
git push -u origin <branch>
gh pr create --base <PR_BASE_BRANCH> --head <branch> --draft --title "<title>" --body-file <file>
```

**Stack:** one branch per cut point, then `gh stack init` + `gh stack submit`. The top branch
is created at `HEAD` so nothing on the branch is left out of the stack.

Drafts are the default (`PR_DRAFT`), because this skill opens PRs but never merges them — the
user decides when something is ready.

→ Branch naming, `gh stack` mechanics, the manual fallback when the extension is missing,
PR title and body templates, and the full fallback matrix: **`references/stacking.md`**.

## Step 6: Report

```markdown
## Pull request(s)

Production lines: <PROD_LINES> (<ADDED> added / <DELETED> deleted, excludes tests,
comments, generated code) vs threshold <STACK_THRESHOLD_LINES> → <single PR | stack of N>

- <url> — [1/N] <name> (<lines> lines)
- <url> — [2/N] <name> (<lines> lines)

Opened as drafts. Merge bottom-up: layer 1 first, and the PRs above re-target automatically
as each lands.
```

Include the per-layer sizes even when they're lopsided — especially then. A stack whose top
layer holds most of the diff hasn't actually reduced anyone's review burden, and the user
should be able to see that and re-split.

## Ledger handoff

A caller that builds a branch in verified stages can supply its own cut points instead of
letting Step 4 guess. That's strictly better: those checkpoints were verified, derived ones
aren't. Pass them oldest-first:

```
layer 1  name: Domain          sha: a1b2c3d
layer 2  name: Data, Cache     sha: e4f5a6b
layer 3  name: UI              sha: 7c8d9e0
```

The top layer's branch is cut at `HEAD` rather than its recorded SHA, so any commits added
after the last checkpoint — review fixes, for instance — still ship. Say so in that PR's
body, since a reviewer expecting them in the layer that owns each file won't find them.

`workflow-kit:implement-plan` uses this: it records a SHA each time a dependency layer passes
its verification gate, then calls this skill at the end.

## Configuration

- `PR_BASE_BRANCH` — trunk the bottom/single PR targets. Default: repo default branch.
- `STACK_THRESHOLD_LINES` — production lines (added + deleted) above which the branch is
  split into a stack. Default 500.
- `PR_DRAFT` — open PRs as drafts. Default `true`.
- `PR_PROD_EXCLUDES` — space-separated git pathspecs replacing the counter's default
  test/generated excludes.

## Dependencies

- `gh` CLI, authenticated (`gh auth status`)
- [`github/gh-stack`](https://github.com/github/gh-stack) extension for stacks —
  `gh extension install github/gh-stack`. Without it the PRs are still chained by base
  branch; only GitHub's stack UI is missing. Stacked PRs are in public preview, so this
  extension's flags are the likeliest thing here to drift.
