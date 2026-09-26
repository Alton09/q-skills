---
name: create-pr
description: Create a PR or open a pull request for the current q-skills branch; use when asked to "create a pr" or "open a pull request".
---

# Create Pull Request

Run non-interactively from the repository or worktree root. Accept an optional plan-file path
and an optional request to include its latest `## Implementation Report — <date>` section in
the PR body. Never merge a PR: this repository squash-merges after review.

1. Identify the current branch with `git branch --show-current`, then push it:

   ```bash
   git push -u origin "$(git branch --show-current)"
   ```

2. Inspect the branch diff and recent conventional-commit history. Choose a concise title in
   the established form `feat(<skill>): …`, `fix(<skill>): …`, or `chore(<skill>): …`.
3. Compose a body with short summary bullets. If requested and the plan file is supplied,
   append its latest `## Implementation Report — <date>` section, stopping at the next `## `
   heading. End the body with exactly:

   ```markdown
   🤖 Generated with [Claude Code](https://claude.com/claude-code)
   ```

4. Create a draft PR against `main`, supplying the composed body directly:

   ```bash
   gh pr create --draft --base main --title "$title" --body "$body"
   ```

If a body correction is needed, `gh pr edit` can fail with the GraphQL error `Projects
(classic) is being deprecated`. Use this workaround instead:

```bash
gh api -X PATCH repos/{owner}/{repo}/pulls/<n> -f body="$body"
```

Return the draft PR URL and the exact body used. Do not merge, approve, or otherwise change
the PR after creating it.
