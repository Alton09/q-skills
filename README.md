# q-skills

A collection of project-agnostic Claude Code plugins for structured development workflows.

## Plugins

### workflow-kit

Project-agnostic Claude Code plugins for the full feature lifecycle: structured planning, verified implementation, and PR review.

**Skills included:**

| Skill | Command | Description |
|-------|---------|-------------|
| feature-plan | `/workflow-kit:feature-plan` | Create structured implementation plans with phases, tasks, and acceptance criteria |
| implement-plan | `/workflow-kit:implement-plan` | Execute a plan end-to-end with dependency-graph parallel phases, two-tier verification, an opus escalation rescue, and a post-plan review + auto-fix, then a draft PR opened via the project's `/create-pr` |

#### Composable Skills

workflow-kit skills delegate to project-local skills that you supply. These must exist in
your project's `.claude/skills/` before running implement-plan or feature-plan:

| Skill | Required | Contract |
|---|---|---|
| `/verify` | Required | Run quality gates; return `pass` or `fail` with raw output verbatim on failure |
| `/create-worktree` | Required | Create an isolated git worktree and branch; return its path |
| `/clean-architecture` | Required | Load layer rules and naming conventions into context |
| `/research` | **Optional** | Look up latest API docs for a given surface; return findings as text. Skipped gracefully if absent. |
| `/create-pr` | **Optional** | Open a **draft** PR for the finished worktree branch, non-interactively, include the report at the supplied plan-file path in the PR body, and return its URL. implement-plan delegates here; skipped gracefully if absent. |

See [`examples/android/`](examples/android/) for a working reference implementation targeting
Kotlin, Gradle KTS, Jetpack Compose, Hilt, and Clean Architecture. Copy and adapt those
skills as a starting point for your own project.

### dev-toolkit

Standalone dev utilities that work independently of any planning pipeline.

**Skills included:**

| Skill | Command | Description |
|-------|---------|-------------|
| pr-review | `/dev-toolkit:pr-review` | Project-aware GitHub PR review with focused, numbered findings |
| pr-retro | `/dev-toolkit:pr-retro` | Post-merge retro: mine PR comments, CI and linked sessions for skill, harness and lint-rule improvements. |
| notify-me | `/dev-toolkit:notify-me` | Send macOS system notifications during long-running tasks (macOS only) |

#### SessionStart Nudge Hook

`dev-toolkit` includes a SessionStart hook that nudges you when a merged PR has not yet been retrospectively analyzed. When you start a session in a GitHub repository where you have authored merged PRs, the hook checks for any that have not yet been analyzed with `/dev-toolkit:pr-retro` or skipped, and displays:

```
PR #432 "Feature name" merged with no retro. Run /dev-toolkit:pr-retro 432, or /dev-toolkit:pr-retro --skip 432.
```

The hook queries GitHub at most once per hour per repository, and fails silently if offline or if `gh` is not installed. To opt out of nudges, set the environment variable `PR_RETRO_NUDGE=0`.

Per-repository state is stored in `~/.claude/pr-retro/<owner>__<repo>/`, including a baseline timestamp and the list of PRs already retro'd or skipped.

## Installation

1. Add the marketplace directly from GitHub (no clone required):

```bash
claude plugin marketplace add Alton09/q-skills
```

   The `owner/repo` shorthand above works, as does the full URL:

```bash
claude plugin marketplace add https://github.com/Alton09/q-skills
```

2. Install each plugin:

```bash
claude plugin install workflow-kit
claude plugin install dev-toolkit
```

3. Reload plugins in Claude Code:

```
/reload-plugins
```

Run `/doctor` to confirm no errors.

### Local development install

Developing the plugins locally? Point the marketplace at your working copy instead:

```bash
git clone https://github.com/Alton09/q-skills.git ~/Workspace/q-skills
claude plugin marketplace add ~/Workspace/q-skills
claude plugin install workflow-kit
claude plugin install dev-toolkit
```

## Swappable phase executors

`implement-plan` always orchestrates from Claude Code; an executor changes only the
harness used for an individual phase, retry, review, or fix worker. Keeping scheduling,
worktrees, pacing, gate verification, notifications, and decisions in Claude Code avoids
the foreign-orchestrator failures observed in F1–F5 while still allowing worker choice.

The default is Claude workers. Select the shipped pi worker tiers for one run with:

```bash
PHASE_EXECUTOR=pi
```

`PHASE_EXECUTOR` accepts `claude` (the default), `pi`, or `codex`, and sets all phase-tier
defaults for that executor. `PHASE_MODEL_LIGHT`, `PHASE_MODEL_STANDARD`, and
`PHASE_MODEL_DEEP` can instead select each tier independently with an `executor:model`
address; an unprefixed model means `claude:<model>`. The shipped tier defaults are:

| `PHASE_EXECUTOR` | Light | Standard | Deep |
|---|---|---|---|
| `claude` (default) | `claude:haiku` | `claude:sonnet` | `claude:opus` |
| `pi` | `pi:opencode-go/minimax-m3` | `pi:opencode-go/glm-5.3` | `pi:opencode-go/qwen3.8-max` |
| `codex` | `codex:gpt-5.6-luna` | `codex:gpt-5.6-terra` | `codex:gpt-5.6-sol` |

An explicit `PHASE_MODEL_*` setting overrides the shorthand for that tier. The
per-worker wall-clock budget, `PHASE_TIME_BUDGET`, defaults to 30 minutes.

For pi, install the `pi` CLI and authenticate its `opencode-go` provider. For Codex,
install the Codex CLI and sign in with a ChatGPT plan. The orchestrator creates the
per-worktree `.agents/skills` link Codex needs; no manual skill-link setup is required.

`VERIFY_AGENT_MODEL` defaults to `claude:sonnet` (use `claude:haiku` only for a
deterministic exit-code gate). `REVIEW_EXECUTOR` normally follows `PHASE_EXECUTOR`, except
Codex phases default their review to Claude; `REVIEW_MODEL` defaults to `claude:opus`,
`pi:opencode-go/grok-4.6`, or `codex:gpt-5.6-sol` for the selected review executor.
Reviewers should differ from each implementer by executor or model family whenever the
configured pool permits it, and a Codex reviewer cannot review a Codex implementer.

Foreign workers may not cover device work during their warm self-verify: Codex workers
skip that half, while pi workers may or may not run it. The independent gate covers device
criteria in either case.

Pi's flat-rate accounting is retail-equivalent value, not metered cash; its provider
five-hour cap is the binding limit. Codex reports tokens and plan-window share, not dollars;
ChatGPT Plus has both five-hour and weekly windows.

## Updating

```bash
# Check your exact plugin identifier
claude plugins list

# Update using the name shown (e.g. workflow-kit@q-skills)
claude plugins update workflow-kit@<marketplace-name>
claude plugins update dev-toolkit@<marketplace-name>
```

Restart Claude Code after updating to apply changes.

## Usage

After installation, skills are available as slash commands:

```
/workflow-kit:feature-plan      # Plan a feature
/workflow-kit:implement-plan    # Execute a plan
/dev-toolkit:pr-review          # Review a GitHub PR
/dev-toolkit:pr-retro           # Post-merge retrospective on PR comments, CI, and linked sessions
/dev-toolkit:notify-me          # Send macOS notification
```

## Project Structure

```
q-skills/
  .claude-plugin/
    marketplace.json          # Marketplace registry (lists both plugins)
  plugins/
    workflow-kit/
      .claude-plugin/
        plugin.json           # Plugin manifest (v1.1.0)
      skills/
        feature-plan/         # Feature planning skill
        implement-plan/       # Plan execution skill (with built-in opus escalation rescue)
    dev-toolkit/
      .claude-plugin/
        plugin.json           # Plugin manifest (v1.0.0)
      skills/
        pr-review/            # GitHub PR review skill
        pr-retro/             # Post-merge retrospective skill
        notify-me/            # macOS notification skill
      hooks/
        hooks.json            # SessionStart hook for nudging unretro'd PRs
        pr-retro-nudge.sh     # Nudge script
```

## License

See [LICENSE](LICENSE) for details.
