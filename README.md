# q-skills

A collection of Claude Code plugins for structured development workflows.

## Plugins

### workflow-kit

Structured implementation planning and feature development skills.

**Skills included:**

| Skill | Command | Description |
|-------|---------|-------------|
| feature-plan | `/workflow-kit:feature-plan` | Create structured implementation plans with phases, tasks, and acceptance criteria |
| implement-plan | `/workflow-kit:implement-plan` | Execute a plan end-to-end with quality verification and task tracking |
| deep-dive | `/workflow-kit:deep-dive` | Rescue a stuck phase with a stronger-model sub-agent when implement-plan hits 3x verify failure |

### dev-toolkit

Standalone dev utilities that work independently of any planning pipeline.

**Skills included:**

| Skill | Command | Description |
|-------|---------|-------------|
| pr-review | `/dev-toolkit:pr-review` | Project-aware GitHub PR review with focused, numbered findings |
| skill-sharpener | `/dev-toolkit:skill-sharpener` | Analyze session transcripts to find and fix skill friction |
| notify-me | `/dev-toolkit:notify-me` | Send macOS system notifications during long-running tasks |

## Installation

1. Clone the repo:

```bash
git clone https://github.com/Alton09/q-skills.git ~/Workspace/q-skills
```

2. Add the local directory as a marketplace and install each plugin:

```bash
claude plugin marketplace add /path/to/q-skills
claude plugin install workflow-kit
claude plugin install dev-toolkit
```

3. Reload plugins in Claude Code:

```
/reload-plugins
```

Run `/doctor` to confirm no errors.

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
/workflow-kit:deep-dive         # Rescue a stuck phase with a stronger model
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
        plugin.json           # Plugin manifest (v0.6.0)
      skills/
        feature-plan/         # Feature planning skill
        implement-plan/       # Plan execution skill
        deep-dive/            # Stuck-phase rescue skill
    dev-toolkit/
      .claude-plugin/
        plugin.json           # Plugin manifest (v0.1.0)
      skills/
        pr-review/            # GitHub PR review skill
        skill-sharpener/      # Skill improvement skill
        notify-me/            # macOS notification skill
```

## Dependencies

workflow-kit skills delegate to project-local skills that you supply. These must exist in
your project's `.claude/skills/` before running implement-plan or feature-plan:

| Skill | Required | Contract |
|---|---|---|
| `/verify` | Required | Run quality gates; return `pass` or `fail` with raw output verbatim on failure |
| `/create-worktree` | Required | Create an isolated git worktree and branch; return its path |
| `/clean-architecture` | Required | Load layer rules and naming conventions into context |
| `/research` | **Optional** | Look up latest API docs for a given surface; return findings as text. Skipped gracefully if absent. |

See [`examples/android/`](examples/android/) for a working reference implementation targeting
Kotlin, Gradle KTS, Jetpack Compose, Hilt, and Clean Architecture. Copy and adapt those
skills as a starting point for your own project.

## License

See [LICENSE](LICENSE) for details.
