---
name: release
description: Release one or more q-skills plugins (workflow-kit, dev-toolkit) — pick the semver bump from merged changes, open and squash-merge the version-bump PR via scripts/release.sh, push the <plugin>--vX.Y.Z tag, then update the local Claude Code install to the new version. Use this whenever asked to release, cut a release, publish, bump the version, or tag a plugin, including "release the plugin that PR #N touched" or "ship a new version after that merge".
---

# Release Plugins

Releases go through `scripts/release.sh`, a two-step tool. `prepare` bumps both
manifests on a `release/<plugin>--v<version>` branch and opens a PR. `tag` runs on
freshly-pulled main, parses the squash-merged subject, and pushes an annotated tag. Run
`./scripts/release.sh help` for its full contract.

## 1. Decide what to release

Start from a clean, up-to-date `main` (`git switch main && git pull`).

If the user named a PR, list its files with `gh pr view <N> --json title,files`. Otherwise
find changes since each plugin's last tag:

```bash
git describe --tags --abbrev=0 --match '<plugin>--v*'
git log --oneline <last-tag>..HEAD -- plugins/<plugin>/
```

Only plugins with changes under `plugins/<plugin>/` need a release. Read the current
version from `plugins/<plugin>/.claude-plugin/plugin.json`.

## 2. Pick the version

Follow the conventional-commit types of the merged changes:

- `fix`, `chore`, docs-only — patch (`2.3.0` → `2.3.1`)
- `feat` — minor (`2.3.0` → `2.4.0`)
- `!` or `BREAKING CHANGE` — major (`2.3.0` → `3.0.0`)

The highest bump across the plugin's changes wins. If the commit type looks wrong for
the diff (for example, a `fix` that adds a new user-facing feature), say so in the report
and keep the type-based bump unless the user asked for a different one.

## 3. Release each plugin, one at a time

`tag` requires HEAD on main to be that plugin's release commit. Finish one plugin's full
cycle before you start the next. If you open two release PRs at once, the second merge
buries the first release commit, and `tag` refuses to run for it.

For each plugin:

```bash
./scripts/release.sh prepare <plugin> <version>   # prints the PR URL
gh pr merge <N> --squash --delete-branch
git switch main && git pull
./scripts/release.sh tag
```

- Pass both arguments to `prepare`. Without them it opens an interactive `select` prompt,
  which hangs in a non-interactive shell.
- Leave the PR title unchanged and use squash-merge. `tag` matches the subject
  `release <plugin>--v<version> (#N)` with a regex, so an edited title or a merge commit
  breaks the parse.
- Merging the bump PR is part of the release. The user asked for a release, so the bump
  needs no separate review.

## 4. Handle failures

`release.sh` stops before it changes anything on the usual precondition failures: a dirty
tree, not on `main`, behind `origin/main`, a version that already exists, or a downgrade.
Fix the cause and re-run. If `tag` fails after the merge, read the error. The usual cause
is that HEAD is not the release commit because something else merged first. Do not
create the tag by hand on some other commit. Ask the user how to proceed.

## 5. Update the local Claude Code install

After the last tag, update the installed plugins so this machine runs the new versions:

```bash
claude plugin marketplace list            # find the q-skills marketplace source
claude plugin marketplace update q-skills
claude plugin update <plugin>@q-skills    # once per released plugin
claude plugin list                        # confirm the new versions
```

The q-skills marketplace is often a local folder source. `marketplace update` re-reads that
folder, so it only picks up the release when the folder is a checkout of `main` that you
have pulled. Check the folder first. If it is a worktree on another branch or behind
`origin/main`, `plugin update` reports the old version. In that case, stop and ask the
user before you change anything. Re-pointing the marketplace is their config, and
removing a marketplace can uninstall its plugins. Usually the fix is to re-add the
marketplace from the main repo checkout.

`claude plugin update` applies only after a restart, so tell the user to restart Claude
Code.

## 6. Report

Report each plugin with its old and new versions, the release PR URL, the tag with its
short SHA, and the locally installed version. For example:
`workflow-kit 2.3.0 → 2.3.1 — PR #41, tag workflow-kit--v2.3.1 → 4f0f20d, installed 2.3.1 (restart to apply)`.
