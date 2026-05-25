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
| skill-sharpener | `/workflow-kit:skill-sharpener` | Analyze session transcripts to find and fix skill friction |
| notify-me | `/workflow-kit:notify-me` | Send macOS system notifications during long-running tasks |

## Installation

### From GitHub

```bash
claude plugin marketplace add github:Alton09/q-skills
claude plugin install workflow-kit
```

### From local clone

1. Clone the repo:

```bash
git clone https://github.com/Alton09/q-skills.git ~/Workspace/q-skills
```

2. Add the local directory as a marketplace:

```bash
claude plugin marketplace add /path/to/q-skills
claude plugin install workflow-kit
```

3. Reload plugins in Claude Code:

```
/reload-plugins
```

Run `/doctor` to confirm no errors.

## Usage

After installation, skills are available as slash commands:

```
/workflow-kit:feature-plan      # Plan a feature
/workflow-kit:implement-plan    # Execute a plan
/workflow-kit:skill-sharpener   # Improve skills from session data
/workflow-kit:notify-me         # Send macOS notification
```

## Project Structure

```
q-skills/
  .claude-plugin/
    plugin.json               # Plugin manifest
    marketplace.json          # Marketplace registry
  plugins/
    workflow-kit/
      plugin.json               # Plugin manifest (per-plugin)
      skills/
        feature-plan/         # Feature planning skill
        implement-plan/       # Plan execution skill
        skill-sharpener/      # Skill improvement skill
        notify-me/            # macOS notification skill
```

## Dependencies

Some skills delegate to external tools that must exist in the consumer project:

- `/create-worktree` — worktree creation (used by implement-plan)
- `/clean-architecture` — architecture rules (used by implement-plan, feature-plan)
- `/verify` — quality verification (used by implement-plan)

## License

See [LICENSE](LICENSE) for details.
