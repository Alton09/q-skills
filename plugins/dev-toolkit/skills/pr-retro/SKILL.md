---
name: pr-retro
description: |
  Post-merge retrospective: mine a PR's comments, CI history, and all linked
  Claude Code sessions for improvements to skills, harness guardrails, and
  lint or architecture rules.

  Use this skill whenever the user wants to:
  - do a retro on a PR ("retro on PR 123", "post-merge retro", "what did we
    learn from this PR");
  - improve skills or guardrails from a PR ("sharpen my skills from this PR",
    "improve the harness from this PR", "any konsist rules from PR 432?");
  - use retrospective phrases ("sharpen my skills", "skill retro", "tune my
    skills") when a PR number or URL is mentioned;
  - act on a SessionStart nudge about a merged PR (text like "PR #N merged
    with no retro. Run /dev-toolkit:pr-retro N").

  Also trigger when the user pastes a merged-PR URL and asks to learn from it.

  Output is a terminal proposal the user approves before anything is written.
---

# pr-retro

Mine a merged PR's comments, CI history, and linked sessions for improvements
to skills, harness settings, lint rules, and guardrails. Propose edits.
Let the user approve before writing anything.

## Arguments

`/dev-toolkit:pr-retro [<number|url>] [--skip <number>]`

- No number: use `gh pr view --json number` for the current branch. If none,
  list unretro'd merged PRs with the same query as the nudge hook and ask which.
- `--skip N`: append N to the `done` file and stop.

## Why This Exists

Skills, verify gates, lint rules, and CLAUDE.md entries are durable. A single
bad instruction compounds across every future session. Merged PRs are the
richest signal source: they contain human reviewer comments, CI failures that
slipped past local verification, and session transcripts showing exactly where
the toolchain misfired. Raw signal is noisy, so this skill gathers evidence,
presents a numbered proposal, and lets the human decide.

## Principles

**Bias toward fewer, better edits.** One precise change beats five speculative
ones. If an edit is not clearly justified, skip it and say why.

**Quote evidence.** Every proposed edit cites a specific moment — a PR comment
link, a session id with timestamp, or a CI run url. No evidence, no proposal.

**Explain the why.** Don't just say "add MUST X". Explain why the current
instruction fails, what the change addresses, and why it won't overfit to this
one PR.

**Don't oversteer.** Skills worsen when they accumulate rigid ALWAYS/NEVER
rules from one-off corrections. Prefer reframing intent over adding constraints.

**Respect scope.** If the friction was outside what the skill is supposed to
do, note it and move on.

## Signals

**Strong signals (likely worth acting on):**
- A human PR reviewer asked for a change.
- CI failed after local verification reported green.
- An orchestrator or rescue worker fixed something by hand that a skill or gate
  should have caught.
- The plan prescribed the wrong thing (route to the planner skill or template).
- An environment quirk broke a tool call silently (e.g. aliased `grep`
  swallowing flags).
- The user corrected the assistant immediately after a skill ran.
- A skill instruction ignored a constraint stated in the user's prompt.
- Tool errors directly traceable to skill instructions (wrong path, flag, command).
- The user repeated or rephrased the same request after the skill ran.

**Weak signals (might be skill, might be user):**
- User changed scope mid-task.
- User asked tangential questions.
- Skill produced output but user chose a different option.

**Not signals (ignore):**
- Normal back-and-forth refinement.
- User asking for explanations.
- Tool errors from environment (network, permissions) unrelated to skill
  instructions.
- Bot-only PR comments with no human follow-up.

## Workflow

### Step 1: Resolve the PR and gather evidence

```
gh pr view <n> --json number,url,title,body,headRefName,baseRefName,state,createdAt,mergedAt,commits
gh api repos/{owner}/{repo}/pulls/<n>/comments --paginate
gh api repos/{owner}/{repo}/issues/<n>/comments --paginate
gh api repos/{owner}/{repo}/pulls/<n>/reviews --paginate
gh run list --branch <headRefName> --json databaseId,conclusion,name,createdAt,headSha
```

For each failed CI run: `gh run view <id> --log-failed`, truncated to the
decisive lines. A run that failed and later passed is a signal; the final green
does not erase it. Rank human reviewer comments above bot comments.

The skill also works on an open PR. Say so, and note that findings may be
incomplete.

### Step 2: Find the sessions

Search every project dir under `~/.claude/projects/`, not only the current
project's dir. Use `command grep -rl --include='*.jsonl'` — `grep` may be
aliased in the user's shell and plain `grep` can silently swallow flags.

Worktree sessions live in their own encoded project dirs; include dirs whose
encoded name contains the head branch name.

Search each JSONL for: the PR URL, `pull/<n>`, the head branch name, any
plan-file path named in the PR body, and the worktree dir name. Never search
for a bare `#<n>` alone; it matches unrelated text.

For each matching JSONL, show:
- session id, project dir, mtime, size
- first non-meta user prompt (one line)
- guessed role: plan, implement, review-fix, prior-retro, or other

Present the list and let the user deselect sessions before reading. Read
prior-retro sessions only to avoid repeating their findings.

### Step 3: Digest

Run `python3 ${CLAUDE_SKILL_DIR}/scripts/digest.py <jsonl>` for each selected
session. If `CLAUDE_SKILL_DIR` is unset, resolve the skill directory from the
"Base directory for this skill" line in the context.

If the combined digest output is over roughly 150 KB, spawn one subagent per
session with `model: sonnet`. Each subagent returns signals with short verbatim
quotes and timestamps, not a general summary.

### Step 4: Extract signals

Apply the strong/weak/not-signal lists above. For each strong signal capture:
- session id and timestamp (or PR comment link)
- one-to-two line verbatim quote
- what the skill or gate could have done differently

### Step 5: Route each finding to the cheapest preventing layer

Use this layer ladder, most mechanical first:

1. **Lint or architecture rule** — runs on every build, catches the issue
   before a human ever sees it.
2. **Verify or test gate** — catches it before the PR is opened.
3. **Hook or settings.json** — enforces it at session boundary.
4. **Project skill** — guides the model during the task.
5. **CLAUDE.md or AGENTS.md** — sets context for every session in the repo.
6. **User auto-memory** — persists a personal preference across all projects.
7. **Planner or plan template** — prevents the wrong plan from being written.
8. **Upstream plugin** — a skill namespaced `plugin:skill` or resolved under
   `~/.claude/plugins/`.

A rule that runs on every build beats an instruction a model may skip. Prefer
layer 1 over layer 4, layer 4 over layer 6.

**Ownership classes:**
- **Project-owned:** files in this repo. The skill edits these on a branch
  from `origin/main`.
- **User-owned:** `~/.claude` memory and settings. Edited in place, not on a
  branch.
- **Upstream:** any skill namespaced `plugin:skill`, or resolved under
  `~/.claude/plugins/`. List only — include evidence and the suggested change,
  but do not edit those files.

State file path: `~/.claude/pr-retro/<owner>__<repo>/done` (one PR number per
line). The nudge hook writes `baseline` and `last-check` in the same directory.

### Step 6: Lint rule proposals

Detect the stack from build files: Konsist, detekt, ktlint, ArchUnit, Android
Lint, ESLint, ruff, Semgrep, or others.

For each finding that can be checked mechanically, write the concrete rule in
the project's existing style, plus its test if the stack has rule tests. For
each rule include:
- what it checks;
- its exceptions list;
- whether it would have caught this PR (e.g. "Yes — `ShoppingCartBuildSchedulerImplTest`
  imports `WorkManagerTestInitHelper` without `SynchronousExecutor`").

A lint rule is its own numbered finding, so the user can approve it separately
from any matching skill-text change.

If the project has no lint stack, say so. Do not propose adding one unless
there are two or more enforceable findings.

### Step 7: Proposal (terminal text)

Open with one line per source that was read (sessions, PR endpoints, CI runs).

Sections, in order:
1. **Skills** — project-skill edits
2. **Guardrails and harness** — verify gates, hooks, settings.json,
   CLAUDE.md / AGENTS.md, user memory
3. **Lint rules** — concrete rule code
4. **Upstream** — listed only, with evidence and suggested change
5. **Not recommended** — signals examined and rejected, with reason

Number findings continuously across all sections. Each finding gives:
- evidence: a verbatim quote plus its source (session id + timestamp, or PR
  comment link)
- root cause
- layer (from the ladder above)
- the exact edit
- why it won't overfit to this PR

End with: "Which edits should I apply? e.g. 1, 3 or all"

### Step 8: Apply

After the user approves:
1. `git fetch origin`, then create branch `pr-retro/<n>` from `origin/main`.
   The PR has merged, so local `main` may be stale.
2. Memory edits (`~/.claude`) go in place, not on the branch.
3. Make minimal edits — don't rewrite sections that weren't flagged.
4. Run the project's format check on touched files. For new lint rules, run
   the rule against the current codebase (or `/verify` when present) and
   report any violations already on `main` rather than silently widening the
   exceptions list.
5. Report any pre-existing failure found along the way. Do not fix it without
   separate approval.
6. Do not commit. Offer the project's `/create-pr` if it exists.
7. Finish with a table: number | file | change.

### Step 9: Mark done

Append `<n>` to `~/.claude/pr-retro/<owner>__<repo>/done`, creating the
directory if missing, when the user approved at least one edit, answered
"none", or used `--skip`.

## Edge Cases

- **No sessions found:** run on PR evidence only and say so.
- **No PR comments and no CI failures:** rely on the sessions.
- **Nothing strong:** report "no findings" and still mark the PR done.
- **A skill file is in the plugin cache** (`~/.claude/plugins/`): treat it as
  upstream — list the finding and the suggested change, but do not edit it.
- **PR is open:** run normally, note that findings may be incomplete.

## `scripts/digest.py`

Standard library only. Usage:

```
python3 scripts/digest.py <session.jsonl> [--full]
```

Default output keeps:
- user messages (truncated to 1500 characters);
- assistant text (800 characters);
- `Skill` tool invocations with their args;
- `AskUserQuestion` answers (tool results whose content contains
  "have been answered");
- tool results with `is_error: true`.

`--full` also prints one line per tool call showing `command`, `file_path`, or
`description` (whichever is present).

Each output line is prefixed `[HH:MM:SS]` from the event's `timestamp` field.
Lines that fail to parse are silently skipped.
