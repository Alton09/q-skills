---
name: create-pr
description: Push the current q-skills branch and open (or update) a draft pull request with a conventional-commit title. Use this whenever asked to create a PR, open a pull request, "ship this", or "push and open a draft", and as implement-plan's final PR step — including when it passes a plan file whose implementation report belongs in the PR body.
---

# Create Pull Request

Run non-interactively from the repository or worktree root. Inputs are optional: a
plan-file path, and whether to include its latest `## Implementation Report — <date>`
section in the body.

This skill stops at a draft PR. The repo squash-merges only after human review, so leave
merging, approving, and marking ready to the reviewer.

1. Push the current branch:

   ```bash
   git push -u origin "$(git branch --show-current)"
   ```

2. Read the branch diff and recent commit history. Pick a title in the repo's
   conventional-commit form: `feat(<skill>): …`, `fix(<skill>): …`, or `chore(<skill>): …`.
3. Write a body of short summary bullets. If a plan file was supplied and the report was
   requested, append its latest `## Implementation Report — <date>` section, stopping at
   the next `## ` heading. End the body with exactly:

   ```markdown
   🤖 Generated with [Claude Code](https://claude.com/claude-code)
   ```

4. Check for an existing PR on this branch, since `gh pr create` fails when one exists
   (common when implement-plan is re-run):

   ```bash
   gh pr list --head "$(git branch --show-current)" --state open --json number,url
   ```

   - None: create a draft against `main`:

     ```bash
     gh pr create --draft --base main --title "$title" --body "$body"
     ```

   - One exists: update it instead. Use `gh api`, not `gh pr edit` — `gh pr edit` fails
     in this repo with the GraphQL error `Projects (classic) is being deprecated`:

     ```bash
     gh api -X PATCH repos/{owner}/{repo}/pulls/<number> -f title="$title" -f body="$body"
     ```

Return the PR URL and the exact body used.
