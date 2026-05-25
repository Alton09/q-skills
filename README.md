# claude-skill-core

A collection of Claude Code plugins for structured development workflows.

## Plugins

### qualls-core

Structured implementation planning and feature development skills.

**Skills included:**

| Skill | Command | Description |
|-------|---------|-------------|
| feature-plan | `/qualls-core:feature-plan` | Create structured implementation plans with phases, tasks, and acceptance criteria |
| implement-plan | `/qualls-core:implement-plan` | Execute a plan end-to-end with quality verification and task tracking |
| skill-sharpener | `/qualls-core:skill-sharpener` | Analyze session transcripts to find and fix skill friction |
| notify-me | `/qualls-core:notify-me` | Send macOS system notifications during long-running tasks |

## Installation

### From GitHub

```bash
claude plugin install Alton09/claude-skill-core
```

### From local clone

1. Clone the repo:

```bash
git clone https://github.com/Alton09/claude-skill-core.git ~/Workspace/claude-skill-core
```

2. Register the marketplace in `~/.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "qualls-core": {
      "source": {
        "source": "directory",
        "path": "/path/to/claude-skill-core"
      }
    }
  },
  "installedPlugins": {
    "qualls-core@qualls-core": true
  }
}
```

Replace `/path/to/claude-skill-core` with your actual clone path.

3. Reload plugins in Claude Code:

```
/reload-plugins
```

Run `/doctor` to confirm no errors.

## Usage

After installation, skills are available as slash commands:

```
/qualls-core:feature-plan      # Plan a feature
/qualls-core:implement-plan    # Execute a plan
/qualls-core:skill-sharpener   # Improve skills from session data
/qualls-core:notify-me         # Send macOS notification
```

## Project Structure

```
claude-skill-core/
  .claude-plugin/
    plugin.json               # Plugin manifest
    marketplace.json          # Marketplace registry
  plugins/
    qualls-core/
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
