# Sync Mode

`--sync` brings the PR branch up to date with its base branch after another PR
merges. It uses a merge, not a rebase: the mode never rewrites the PR branch,
so it never needs a force-push. Repositories that squash-merge the PR do not
retain the merge commit, but the sync operation still uses the same merge
workflow.

## Step 4: Mode

Resolve the PR's `baseRefName` and the current PR worktree before running this
mode. Fetch the base ref, then compare it with the worktree head:

```bash
git fetch origin <baseRefName>
git merge-base --is-ancestor origin/<baseRefName> HEAD
```

If the ancestor check succeeds, report `already up to date` and exit the sync
mode. Otherwise, run:

```bash
git merge --no-edit origin/<baseRefName>
```

The merge has two possible outcomes.

### Clean merge

A clean merge produces no fix job. Continue through Step 6 (`gate verify`) and
Step 7 (`git push`, with no force), because a clean merge can still break the
build or other verification checks. The gate verify checks the merged worktree
head after the merge.

### Conflicts

Create exactly one fix job for all conflicted files. Its shape is:

```text
{
  id,
  kind: conflict,
  files: [<conflicted paths>],
  payload: {
    paths: [<conflicted paths>],
    prTitle: <PR title>,
    prBody: <PR body>,
    intent: {
      "<path>": {
        pr: <git log --oneline HEAD...origin/<baseRefName> -- <path>>,
        base: <git log --oneline origin/<baseRefName>...HEAD -- <path>>
      }
    },
    rules: [
      "keep both sides' intent",
      "never take --ours or --theirs for a whole file without explaining why in the commit",
      "conclude the merge with git commit --no-edit"
    ]
  }
}
```

The `intent` payload must include `git log --oneline HEAD...origin/<baseRefName>
-- <paths>` for both sides' intent, using the conflicted paths. The worker
resolves all listed conflicts while preserving both sides' intent. It must not
take `--ours` or `--theirs` for a whole file unless the commit explains why,
and it must conclude the merge with `git commit --no-edit`.

If the conflict worker fails, do not continue to gate verify or push. Run:

```bash
git merge --abort
```

Then report the failure and ask the user. The worktree must remain at the
pre-merge state. If the worker succeeds, continue through Step 6 gate verify
and Step 7 push; never force-push.

## Step 8: GitHub write-back

After the push, post one marked PR comment. The comment reports:

- the merged base ref and commit, in the form `merged <base>@<sha>`;
- whether conflicts were resolved, including the conflicted file list when
  applicable; and
- the gate result.

End the comment with the required marker, exactly:

```html
<!-- address-pr -->
```

For an already-up-to-date sync, there is no merge, gate, or push to report;
follow the mode's terminal summary and do not claim that a base commit was
merged.
