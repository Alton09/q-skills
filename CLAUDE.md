# qualls-core Plugin

Claude Code plugin for structured implementation planning.

## Usage

```
/qualls-core:implement-plan
```

Invoke in any project to create structured implementation plans and execute phased development.

## Plugin Structure

- `.claude-plugin/plugin.json` — Plugin manifest
- `.claude-plugin/marketplace.json` — Marketplace metadata
- `skills/implement-plan/` — Core skill implementation

## Installation

```bash
claude plugin install qualls-core@qualls-core --scope user
```

## Dependencies

Skill delegates to external tools that must exist in consumer projects:
- `/create-worktree`
- `/clean-architecture`
- `/verify`
- `/notify-me`
