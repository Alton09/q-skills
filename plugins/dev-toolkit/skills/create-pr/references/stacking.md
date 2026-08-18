# Stack Mechanics, PR Bodies & Fallbacks

Referenced from `SKILL.md` Step 5. Read this once you know the shape (single or stacked) and
have your cut points — it covers materializing branches, driving `gh stack`, what goes in the
PR bodies, and what to do when a precondition rules the stack out.

## Contents

- [Materializing the branches](#materializing-the-branches)
- [Driving gh stack](#driving-gh-stack)
- [Manual fallback without the extension](#manual-fallback-without-the-extension)
- [Titles and bodies](#titles-and-bodies)
- [Per-layer sizes](#per-layer-sizes)
- [Fallback matrix](#fallback-matrix)

## Materializing the branches

One branch per cut point, at that cut point's SHA — **except the top layer, which is cut at
`HEAD`** so nothing on the branch is stranded outside the stack:

```
git branch <branch>-L1-domain a1b2c3d
git branch <branch>-L2-data   e4f5a6b
git branch <branch>-L3-ui     HEAD
```

Name layers `<branch>-L<n>-<slug>`, with a `-` separator rather than `/`. Git stores branches
as paths, so `feat/x/L1` cannot coexist with an existing `feat/x` — you'd get a
"cannot lock ref" failure partway through, leaving a half-built stack.

Derive each slug from what the layer does (its phase names in ledger mode, its commit
subjects in cold mode). The branch names show up in the PR list, so they're worth a moment.

## Driving gh stack

```
gh stack init <branch>-L1-domain <branch>-L2-data <branch>-L3-ui --base <PR_BASE_BRANCH>
gh stack submit --auto
```

`gh stack init` adopts existing branches in the order given, basing each on the previous one;
`--base` sets the trunk the bottom PR targets. `gh stack submit --auto` skips the interactive
editor (which would stall when an agent is driving), pushes every branch, and opens the PRs
**as drafts** — add `--open` when `PR_DRAFT=false`.

`--auto` generates placeholder titles. Replace them:

```
gh pr list --head <branch>-L1-domain --json number,url
gh pr edit <number> --title "<title>" --body-file <file>
```

## Manual fallback without the extension

If `github/gh-stack` isn't installed, offer `gh extension install github/gh-stack`. If the
user declines, chain the PRs by hand — the base-branch topology is identical and merging
still works bottom-up; only GitHub's stack UI (the stack map in the merge box, automatic
re-targeting) is missing:

```
git push -u origin <each-branch>
gh pr create --base <PR_BASE_BRANCH>  --head <branch>-L1-domain --draft ...
gh pr create --base <branch>-L1-domain --head <branch>-L2-data   --draft ...
```

Tell the user re-targeting is manual in this case: when layer 1 merges, layer 2's base has to
be pointed at the trunk by hand.

## Titles and bodies

**Single PR** — title from the branch's purpose (the plan title, the commit subjects, or ask).

```markdown
## Overview
<what this branch does and why>

## Verification
<how it was checked — test suite, verification skill, manual>

Production lines changed: <PROD_LINES> (excludes tests, comments, generated code).

🤖 Generated with [Claude Code](https://claude.com/claude-code)
```

**Stacked PRs** — one per layer, titled `[<n>/<total>] <what the layer does>`:

```markdown
Layer <n> of <total> in this stack. Base: `<branch below, or the trunk for layer 1>`.
Size: <lines> production lines.

## What's in this layer
- <commit subject or task line>
- <commit subject or task line>

## Merging
This stack merges bottom-up — layer <n-1> lands first. The PRs above re-target
automatically as each one merges.
```

In **cold mode**, add a line to every layer but the top:

```markdown
> Cut points were derived from commit history, so this intermediate layer isn't
> independently verified to build on its own.
```

That's not boilerplate hedging — a reviewer who assumes each layer is green will file a bug
against a state that never existed as a checkpoint.

In **ledger mode**, the top PR carries anything committed after the last checkpoint:

```markdown
## Also in this PR
Commits added after the final layer checkpoint (e.g. review fixes) land here rather than in
the layer that owns each file:
- <file> — <what changed>
```

## Per-layer sizes

Report each layer's size, in its PR body and in the final summary:

```
scripts/count-prod-lines.sh <previous-layer-sha>...<this-layer-sha>
```

For layer 1 the range starts at `PR_BASE_BRANCH`. This is what tells you whether the split
actually worked — a "stack" whose top layer holds 700 of 800 lines has the same review
problem as one big PR, and the user needs to see that to decide whether to re-split.

## Fallback matrix

| Situation | Path |
|---|---|
| `PROD_LINES` ≤ threshold | Single draft PR |
| Over threshold, ≥2 cut points | Stack, one PR per layer |
| Over threshold, one commit on the branch (`propose-cuts.sh` exits 3) | Single PR + a warning naming the count |
| Over threshold, user declines the proposed split | Single PR — it's their call, don't re-litigate |
| `gh-stack` absent | Offer to install; otherwise the manual `--base` chain |
| Base branch in a different repo/fork | Single PR — GitHub stacks require same-repo branches |
| Push or PR creation fails partway | Report the verbatim error and which branches/PRs already exist, so the user isn't left guessing at a half-built stack |
