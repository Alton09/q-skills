---
name: create-worktree
description: >
  Create an isolated git worktree and branch for safe feature development.
  Use this skill to set up a worktree, create an isolated branch, or prepare
  an isolated environment before starting implementation.
---

# Create Worktree

Create an isolated git worktree + branch so implement-plan works on a copy of the repo
without touching the main checkout. Return the worktree path for the caller to confirm.

## Steps

### 1. Create the worktree

```bash
git worktree add ../<repo>-<branch> -b feature/<name>
```

Replace `<repo>` with the repository directory name and `<name>` with a kebab-case feature name
derived from the plan title or branch intent.

**Example:**

```bash
git worktree add ../MenuLens-add-favorites -b feature/add-favorites
```

This places the worktree as a sibling of the current repo directory. Both share the same
`.git` object store — no redundant clones.

### 2. Copy `local.properties`

```bash
cp local.properties ../<repo>-<branch>/local.properties
```

**Why this is required:** `local.properties` is gitignored because it contains the local
Android SDK path (`sdk.dir`). A fresh worktree will not have this file, so `./gradlew`
commands — including those run by `/verify` — will fail immediately with
`SDK location not found`. Copying it is the only step needed to make the worktree buildable.

## Return Value

After the worktree is created and `local.properties` is copied, return the full path:

```
Worktree ready: /Users/<you>/MenuLens-add-favorites
Branch: feature/add-favorites
```

implement-plan will confirm this path with the user before proceeding to implementation.

## Cleanup

Worktrees are **not** automatically removed. When the feature is merged or abandoned:

```bash
git worktree remove ../<repo>-<branch>
git branch -d feature/<name>
```

Or use `git worktree prune` to clean up any worktrees whose directories have been deleted manually.
