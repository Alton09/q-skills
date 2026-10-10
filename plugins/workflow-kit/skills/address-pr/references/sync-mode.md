# Sync Mode

`--sync` brings the PR branch up to date with its base branch after another PR
merges. It uses a merge, not a rebase: the mode never rewrites the PR branch,
so it never needs a force-push. Repositories that squash-merge the PR do not
retain the merge commit, but the sync operation still uses the same merge
workflow.

## Step 4: Merge the base

Resolve the PR's `baseRefName` and the current PR worktree before running this
mode. Fetch the base ref, then compare it with the worktree head:

```bash
git fetch origin <baseRefName>
git merge-base --is-ancestor origin/<baseRefName> HEAD
```

If the ancestor check succeeds, report `already up to date` and follow `SKILL.md`
§ "Early exits". Otherwise, record the pre-merge head, then merge:

```bash
pre_merge=$(git rev-parse HEAD)
git merge --no-edit origin/<baseRefName>
```

Keep `<pre_merge>` for rollback. The merge has two possible outcomes.

### Clean merge

A clean merge produces no fix job. Continue through Step 6 (gate verify) and
Step 7 (push, never force), because a clean merge can still break the build or
other verification checks. The gate verifies the merged worktree head.

### Conflicts

Create exactly one fix job (`SKILL.md` § "Fix jobs") for all conflicted files,
with `kind: conflict`, `files` set to the conflicted paths, and this payload:

```text
{
  paths: [<conflicted paths>],
  prTitle: <PR title>,
  prBody: <PR body>,
  intent: {
    "<path>": {
      pr:   <git log --oneline origin/<baseRefName>..HEAD -- <path>>,
      base: <git log --oneline HEAD..origin/<baseRefName> -- <path>>
    }
  },
  rules: [
    "keep both sides' intent",
    "never take --ours or --theirs for a whole file without explaining why in the commit",
    "conclude the merge with git commit --no-edit"
  ]
}
```

During the merge, `HEAD` is still the PR head, so `origin/<baseRefName>..HEAD`
lists only the PR's commits and `HEAD..origin/<baseRefName>` lists only the
base's commits. Do not use the symmetric `...` range: it gives both sides the
same log.

If the conflict worker fails, do not continue to gate verify or push. Roll the
worktree back to `<pre_merge>`:

- If `MERGE_HEAD` exists (`git rev-parse -q --verify MERGE_HEAD`), the merge is
  still open: run `git merge --abort`.
- Otherwise the worker already committed the merge, and `git merge --abort`
  cannot undo it. Ask the user to confirm, then run
  `git reset --hard <pre_merge>`. This discards the worker's merge commit and
  any uncommitted changes, so never run it without that confirmation.

Then report the failure and ask the user. If the worker succeeds, continue
through Step 6 gate verify and Step 7 push; never force-push.

## Step 8: GitHub write-back

After the push, post one PR comment. The comment reports:

- the merged base ref and commit, in the form `merged <base>@<sha>`;
- whether conflicts were resolved, including the conflicted file list when
  applicable; and
- the gate result.

End the comment with `<!-- address-pr:sync -->`.
