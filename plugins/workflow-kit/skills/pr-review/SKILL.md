---
name: pr-review
description: >
  Review GitHub pull requests with project-aware code review. Use this skill whenever
  the user asks to review a PR, check a pull request, give feedback on a diff, review
  code changes, or look at what changed in a PR — even if they don't say "code review"
  explicitly. Also trigger when the user pastes a GitHub PR URL or says things like
  "what do you think of PR #123", "check this PR", or "review this before I merge".
  Produces a focused, numbered findings report with severity levels and an actionable
  verdict.
---

# PR Review

Review GitHub PRs by combining project conventions, delegate skills, and general
code quality analysis into a single numbered findings report.

## Step 1 — Get PR Reference

Require a PR number or GitHub URL. If not provided, ask before proceeding.

Do NOT run `gh pr list` to browse — wait for a specific PR.

Extract the PR number. If given a full URL, parse the number from it.

## Step 2 — Fetch PR Data

Run in parallel:
```bash
gh pr view <number>
gh pr diff <number>
```

No `--repo` flag — run from within the project directory so `gh` auto-detects the repo.

Capture:
- PR title, author, description, base branch
- Full diff output

If the diff is very large (>2000 lines), focus on the most impactful files. Note in
the output that the review covers a subset and which files were skipped.

## Step 3 — Load Project Conventions

Read the consumer project's `CLAUDE.md` from the repo root. This grounds the review
in actual project rules rather than generic advice.

Look for:
- MUST/NEVER rules
- Architecture patterns and layer conventions
- Error handling expectations
- Naming conventions
- Testing requirements

If no `CLAUDE.md` exists, note it and proceed with general best practices only.

## Step 4 — Delegate to Consumer Skills

Attempt to invoke each known delegate skill against the diff. These skills are defined
by the consumer project — they may or may not exist. The review adapts based on what's
available.

### Architecture: `/clean-architecture`

If available, apply its rules to the diff. Flag any violation it would catch — layer
violations, dependency direction, naming conventions, structural patterns. Cite the
specific rule when reporting a finding.

If not available, skip. Track as "skipped".

### Testing: `/testing-patterns`

If available, apply its rules to any test files in the diff. Flag violations in test
structure, naming, coverage gaps, mock usage, assertion patterns. Cite the specific
rule when reporting a finding.

If not available, skip. Track as "skipped".

### Verification: `/verify`

If available, run it as a final validation pass after the review is drafted. Report
any failures as additional findings.

If not available, skip. Track as "skipped".

**How to check if a delegate skill exists:** attempt to invoke it. If the skill is not
found or not registered, the system will indicate it's unavailable. That's the signal
to skip and move on — don't error, don't retry.

## Step 5 — General Code Quality Analysis

This section always runs, regardless of which delegate skills are available. Analyze
the diff for:

- **Correctness** — logic errors, off-by-one, null safety, race conditions, missing
  error handling
- **Security** — injection risks, hardcoded secrets, unsafe deserialization, missing
  auth checks, OWASP top 10
- **Performance** — N+1 queries, unbounded loops, missing pagination, unnecessary
  allocations in hot paths
- **API contract** — breaking changes to public interfaces, missing migration steps
- **Naming and clarity** — misleading names, dead code, overly complex logic that
  could be simplified

Skip categories with nothing to flag. Only report real issues — not style preferences
or nitpicks unless they violate a rule from CLAUDE.md.

## Step 6 — Output Findings

Produce the review in this exact format. Number findings sequentially across all
categories. Only include sections with real findings.

```markdown
# 🤖 Claude Code Review

**PR #<number>**: <title>
**Author**: <author>

## 1. [Short title] — [Severity: High/Medium/Low]
[One sentence: what's wrong and where (file:line if possible).]
[One sentence: why it matters.]
[Fix or recommendation, with code snippet if helpful.]

## 2. ...

---

**Verdict:** [merge-ready / needs minor fixes / needs rework] — [one sentence why]
```

**Severity guide:**
- **High** — crash/data-loss risk, security issue, hard NEVER rule violation
- **Medium** — architecture convention violation, test gap in critical path,
  subtle correctness bug
- **Low** — code quality, readability, minor convention deviation

If zero findings across all categories, say so directly:
`**Verdict:** merge-ready — no issues found.`

**Skipped delegate skills:** If any delegate skills were unavailable, append after
the verdict:

```markdown
> **Note:** The following review skills were not available in this project and
> were skipped: /clean-architecture, /testing-patterns. Define these skills in
> your project to get deeper coverage in those areas.
```

Only list the ones that were actually skipped.

## Step 7 — Filter with User

List each finding number and title, then ask:

```
Which findings to keep? (e.g. 1,3,5 or 'all' or 'none')
```

Wait for response. Rebuild the final review with only selected findings,
renumbered sequentially. Recalculate the verdict based on kept findings.

## Step 8 — Post to GitHub

Show the final review, then ask:

```
Post this as a comment on PR #<number>? (yes/no)
```

If yes:
```bash
gh pr comment <number> --body "<final review markdown>"
```

If no, output the final review as markdown for the user to copy.

## Style

Terse. No filler. Fragments OK. Cite exact file and line when possible. Quote exact
convention text from CLAUDE.md when calling out a violation — don't paraphrase.
