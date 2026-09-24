---
name: create-worktree
description: >
  Create an isolated git worktree and branch as a sibling of the repository
  directory. Use this skill to set up a worktree, create an isolated branch, or
  prepare an isolated environment before starting implementation.
---

# Create Worktree

Create a git worktree + branch so work happens on a copy of the repo without touching the
main checkout. The worktree is placed **next to** the repository directory, never inside it,
so it can never be picked up by the repo's own tooling or committed by accident.

## Steps

### 1. Pick a branch name

Derive a kebab-case name from the plan title or the branch intent, prefixed with the change
type used by this repo's commits (`feat`, `fix`, `docs`, `chore`):

```
feat/swappable-executors
fix/worktree-placement
```

### 2. Create the worktree

Run from inside the repository:

```bash
repo_root=$(git rev-parse --show-toplevel)
repo_name=$(basename "$repo_root")
branch=feat/<name>
slug=<name>

git worktree add "$repo_root/../$repo_name-$slug" -b "$branch"
```

`$repo_root/../` resolves to the parent of the repository directory, so the worktree lands
as a sibling — for this repo, `/home/alton/Workspace/q-skills-<slug>`. Both checkouts share
one `.git` object store, so there is no second clone.

If the branch already exists, drop `-b` and check it out instead:

```bash
git worktree add "$repo_root/../$repo_name-$slug" "$branch"
```

### 3. Carry over untracked local files

This repo needs no build configuration, so a fresh worktree is usable immediately. Copy
anything gitignored that the work depends on — for example local settings overrides:

```bash
cp .claude/settings.local.json "$repo_root/../$repo_name-$slug/.claude/" 2>/dev/null || true
```

Skip this step when there is nothing to copy.

### 4. Verify the worktree is clean

```bash
git -C "$repo_root/../$repo_name-$slug" status --short
```

Expect empty output. Anything listed means a stray file was copied in and should be removed
before implementation starts.

## Return Value

Report the absolute path and branch so the caller can use them directly:

```
Worktree ready: /home/alton/Workspace/q-skills-swappable-executors
Branch: feat/swappable-executors
```

Callers such as `implement-plan` use this path as the working directory for every phase.

## Cleanup

Worktrees are **not** removed automatically. Once the branch is merged or abandoned:

```bash
git worktree remove "$repo_root/../$repo_name-$slug"
git branch -d feat/<name>
```

Use `git worktree prune` to clear entries whose directories were deleted by hand.
