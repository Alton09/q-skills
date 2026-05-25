# claude-skill-core

Mono-repo for Claude Code plugins. Each plugin lives under `plugins/<name>/` with its own `skills/` directory.

## Plugin Structure

- `.claude-plugin/plugin.json` — Plugin manifest (stays at repo root for install discovery)
- `.claude-plugin/marketplace.json` — Marketplace registry pointing to plugins
- `plugins/<name>/skills/` — Skills for each plugin

## Current Plugins

- `qualls-core` — Structured implementation planning and feature development

## Dependencies

Skills delegate to external tools that must exist in consumer projects:
- `/create-worktree`
- `/clean-architecture`
- `/verify`
- `/notify-me`
