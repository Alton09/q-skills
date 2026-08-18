# q-skills

A collection of project-agnostic Claude Code plugins for structured development workflows.

## Plugins

### workflow-kit

Project-agnostic Claude Code plugins for the full feature lifecycle: structured planning, verified implementation, and PR review.

**Skills included:**

| Skill | Command | Description |
|-------|---------|-------------|
| feature-plan | `/workflow-kit:feature-plan` | Create structured implementation plans with phases, tasks, and acceptance criteria |
| implement-plan | `/workflow-kit:implement-plan` | Execute a plan end-to-end with dependency-graph parallel phases, two-tier verification, an opus escalation rescue, a post-plan review + auto-fix, and draft PR creation — stacked one-PR-per-layer when the change exceeds 500 production lines |

#### Composable Skills

workflow-kit skills delegate to project-local skills that you supply. These must exist in
your project's `.claude/skills/` before running implement-plan or feature-plan:

| Skill | Required | Contract |
|---|---|---|
| `/verify` | Required | Run quality gates; return `pass` or `fail` with raw output verbatim on failure |
| `/create-worktree` | Required | Create an isolated git worktree and branch; return its path |
| `/clean-architecture` | Required | Load layer rules and naming conventions into context |
| `/research` | **Optional** | Look up latest API docs for a given surface; return findings as text. Skipped gracefully if absent. |

implement-plan's final step pushes the branch and opens **draft** pull requests via the `gh`
CLI (authenticated `gh auth status` required). Stacked PRs additionally need the
[`github/gh-stack`](https://github.com/github/gh-stack) extension — without it the PRs are
still chained by base branch, just without GitHub's stack UI. Set `CREATE_PR=false` to stop
at the local worktree branch instead.

See [`examples/android/`](examples/android/) for a working reference implementation targeting
Kotlin, Gradle KTS, Jetpack Compose, Hilt, and Clean Architecture. Copy and adapt those
skills as a starting point for your own project.

### dev-toolkit

Standalone dev utilities that work independently of any planning pipeline.

**Skills included:**

| Skill | Command | Description |
|-------|---------|-------------|
| pr-review | `/dev-toolkit:pr-review` | Project-aware GitHub PR review with focused, numbered findings |
| skill-sharpener | `/dev-toolkit:skill-sharpener` | Analyze session transcripts to find and fix skill friction |
| notify-me | `/dev-toolkit:notify-me` | Send macOS system notifications during long-running tasks (macOS only) |

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
/dev-toolkit:skill-sharpener    # Improve skills from session data
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
        implement-plan/       # Plan execution skill (opus escalation rescue + stacked PR creation)
    dev-toolkit/
      .claude-plugin/
        plugin.json           # Plugin manifest (v1.0.0)
      skills/
        pr-review/            # GitHub PR review skill
        skill-sharpener/      # Skill improvement skill
        notify-me/            # macOS notification skill
```

## License

See [LICENSE](LICENSE) for details.
