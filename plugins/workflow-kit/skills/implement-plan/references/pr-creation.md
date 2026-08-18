# Pull Request Creation (Step 9)

Referenced from `SKILL.md` Step 9. The orchestrator turns the finished integration branch
into either a single draft PR or a **stack** of draft PRs — one per topological layer —
depending on how much production code the plan actually changed.

## Contents

- [9a. Preconditions](#9a-preconditions)
- [9b. Measure production churn](#9b-measure-production-churn)
- [9c. Single-PR path](#9c-single-pr-path-at-or-under-threshold)
- [9d. Stacked-PR path](#9d-stacked-pr-path-over-threshold)
- [9e. Titles and bodies](#9e-titles-and-bodies)
- [Fallback matrix](#fallback-matrix)

## 9a. Preconditions

Step 9 runs **after Step 8 has fully settled** — every review round complete, every
auto-fix committed and gate-verified. Cutting branches earlier would strand fix commits
outside the PRs that get reviewed.

Check these in order and skip PR creation (reporting why in Step 10) on any failure —
none of them are worth prompting the user about mid-run:

| Check | Command | On failure |
|---|---|---|
| Every phase checked off, nothing BLOCKED/HALTED | read the plan file | Skip — the branch isn't finished |
| `CREATE_PR` is true | config | Skip silently |
| A remote exists | `git -C <integration> remote` | Skip — nothing to push to |
| `gh` is authenticated | `gh auth status` | Skip, and tell the user to run `gh auth login` |
| Working tree is clean | `git -C <integration> status --porcelain` | Commit the plan-file edits (Step 7) first, then re-check |
| Branch is in the same repo as the base | `gh repo view --json nameWithOwner` | Stacks are same-repo only — force the single-PR path |

The plan file is edited in the worktree by Step 7 and is usually the only dirty path. Commit
it before branching (`docs: check off completed phases`) so the tree is clean and the plan's
final state travels with the PR.

## 9b. Measure production churn

The threshold is about **reviewer burden**, so it counts production code only — no tests, no
generated output, no comments, no blank lines — and counts additions *and* deletions, since a
large deletion is real review work.

```
scripts/count-prod-lines.sh <base>...HEAD
```

Run it from the integration worktree. It prints:

```
PROD_LINES=812
ADDED=690
DELETED=122
SKIPPED_COMMENT=204
SKIPPED_BLANK=97
FILES=23
```

`PROD_LINES` is the number compared against `STACK_THRESHOLD_LINES` (default 500).

**What it excludes** — test paths (`**/test/**`, `**/*Test.*`, `**/*.spec.*`, …), build and
generated output, vendored code, lockfiles, and non-code files (`*.md`, `*.json`, images).
Override the whole list with `PR_PROD_EXCLUDES` (space-separated git pathspecs) when a
project's layout doesn't match — an Android project with `src/androidTest/` is covered by
default; a project that keeps tests in `spec/` is not.

**Comment detection is per-language and prefix-based** (`//`, `/*`, `*`, `#`, `--`). It
classifies unknown extensions as code, which over-counts rather than under-counts — the
failure mode is an unnecessary stack, not an accidentally-huge single PR. If `cloc` is
installed, `cloc --git-diff-simple <base> HEAD` gives a genuinely language-aware
code/comment/blank split; use it to sanity-check a borderline number, but the script is the
default because it needs no dependency.

Report the number in Step 10 regardless of which path it selects — a user who disagrees with
the split needs to see what drove it.

## 9c. Single-PR path (at or under threshold)

```
git -C <integration> push -u origin <integration-branch>
gh pr create --base <PR_BASE_BRANCH> --head <integration-branch> \
  --draft --title "<title>" --body-file <body-file>
```

Drop `--draft` when `PR_DRAFT=false`.

## 9d. Stacked-PR path (over threshold)

### The layer-SHA ledger

Stacking needs a cut point per layer, and those cut points only exist while the layers are
executing — after the fact, a parallel group's commits are interleaved by the merge and
can't be separated without cherry-pick surgery. So the orchestrator records, as part of its
cross-phase state, one entry per layer at the moment that layer's gate-verify passes
(`references/phase-execution.md` 5a.3):

```
layer 1  phases: [Domain]              sha: a1b2c3d
layer 2  phases: [Data, Cache]         sha: e4f5a6b
layer 3  phases: [UI]                  sha: 7c8d9e0
```

For a single-phase layer the SHA is integration HEAD after that phase's commit; for a
parallel group it is integration HEAD after the group's merges land and the integration
gate-verify passes. One line per layer — cheap to hold, and impossible to reconstruct later.

If the ledger is missing or has fewer than two entries, you cannot stack: fall back to 9c
and say so.

### Materialize the stack

Each layer becomes a branch at its recorded SHA, **except the top layer, which is created at
integration HEAD** so it carries the Step 8 review fixes and the plan-file commit:

```
git -C <integration> branch <integration-branch>-L1-domain a1b2c3d
git -C <integration> branch <integration-branch>-L2-data   e4f5a6b
git -C <integration> branch <integration-branch>-L3-ui     HEAD
```

Use the `-L<n>-<slug>` suffix, not a `/` separator — `feat/x/L1` collides with the existing
`feat/x` branch (git can't have both a file and a directory at that path).

Then adopt them bottom-to-top and submit:

```
gh stack init <integration-branch>-L1-domain <integration-branch>-L2-data \
              <integration-branch>-L3-ui --base <PR_BASE_BRANCH>
gh stack submit --auto
```

`gh stack init` adopts existing branches in the order given, basing each on the previous one;
`--base` sets the trunk the bottom PR targets. `gh stack submit --auto` skips the interactive
editor, pushes every branch, and opens the PRs **as drafts** — add `--open` when
`PR_DRAFT=false`. Auto-generated titles are placeholders; replace them in 9e.

The `gh stack` extension (`github/gh-stack`) is what makes GitHub render these as a real
stack. If it isn't installed, offer `gh extension install github/gh-stack`; if the user
declines, chain the PRs manually — the base-branch topology is identical, only GitHub's stack
UI is missing:

```
git -C <integration> push -u origin <each-branch>
gh pr create --base <PR_BASE_BRANCH>            --head <branch-L1> --draft ...
gh pr create --base <integration-branch>-L1-... --head <branch-L2> --draft ...
```

Tell the user the merge order is bottom-up: layer 1 first, and the PRs above re-target
automatically as each one lands.

## 9e. Titles and bodies

Get the PR numbers with `gh pr list --head <branch> --json number,url` and set the real title
and body with `gh pr edit <number> --title ... --body-file ...`.

**Single PR** — title from the plan's `# Feature: …` heading. Body:

```markdown
## Overview
<plan Overview section, verbatim>

## Phases
- Phase 1: <name>
- Phase 2: <name>

## Verification
All phases passed independent gate-verify via `<VERIFY_SKILL>`.
Review: <N> findings, <M> auto-fixed (see commits), <K> left open.

Production lines changed: <PROD_LINES> (excludes tests, comments, generated code).

Plan: `<plan path>`

🤖 Generated with [Claude Code](https://claude.com/claude-code)
```

**Stacked PRs** — one per layer, title `[<n>/<total>] <layer's phase names>`. Body carries
that layer's phases and their verbatim task lines, plus its position:

```markdown
Layer <n> of <total> in this stack. Base: `<branch below, or the trunk for layer 1>`.

## Phases in this layer
### <Phase name>
- <verbatim task line>
- <verbatim task line>

## Verification
Gate-verified via `<VERIFY_SKILL>` before this layer was cut.

Plan: `<plan path>`
```

The **top** PR additionally lists the Step 8 review outcome, because that's where the fix
commits live:

```markdown
## Review & auto-fix (whole stack)
These commits fix findings from the review of the full plan diff, so they land here rather
than in the layer that owns each file:
- <file:line> — <what changed>
```

Say this out loud in Step 10 too. It's the one place the stack's history is less tidy than
the layers suggest, and a reviewer who expects fixes in the owning layer will go looking.

## Fallback matrix

| Situation | Path |
|---|---|
| `PROD_LINES` ≤ threshold | 9c single draft PR |
| `PROD_LINES` > threshold, ≥2 layers in the ledger | 9d stack, one PR per layer |
| `PROD_LINES` > threshold, 1 layer (or no ledger) | 9c, plus a warning naming the count and suggesting the plan be split into dependent phases next time |
| `gh-stack` extension absent | Offer to install; otherwise manual `--base` chain (9d) |
| Base branch is in a different repo/fork | 9c — GitHub stacks require same-repo branches |
| Push or PR creation fails | Report the verbatim error in Step 10; the branches stay local and the worktree is untouched |
