# q-skills

Mono-repo for Claude Code plugins. Each plugin lives under `plugins/<name>/` with its own `skills/` directory.

## Plugin Structure

- `.claude-plugin/marketplace.json` — Marketplace registry pointing to plugins
- `plugins/<name>/.claude-plugin/plugin.json` — Per-plugin manifest
- `plugins/<name>/skills/` — Skills for each plugin

## Current Plugins

- `workflow-kit` — Plan → build pipeline (feature-plan, implement-plan; implement-plan has a built-in opus escalation rescue and delegates PR creation to `dev-toolkit:create-pr`)
- `dev-toolkit` — Standalone dev utilities (notify-me, pr-review, create-pr, skill-sharpener)

## Dependencies

Skills delegate to external tools that must exist in consumer projects:
- `/create-worktree`
- `/clean-architecture`
- `/verify`
- `/research` (optional)

See `examples/android/` for reference implementations targeting Kotlin/Compose/Hilt.
