# q-skills

Mono-repo for Claude Code plugins. Each plugin lives under `plugins/<name>/` with its own `skills/` directory.

## Plugin Structure

- `.claude-plugin/marketplace.json` — Marketplace registry pointing to plugins
- `plugins/<name>/.claude-plugin/plugin.json` — Per-plugin manifest
- `plugins/<name>/skills/` — Skills for each plugin

## Current Plugins

- `workflow-kit` — Plan → build pipeline (feature-plan, implement-plan, address-pr, pm; feature-plan supports handoff mode, and the skills share a `--worker` input; implement-plan orchestrates on Claude Code with swappable phase executors, has a built-in opus escalation rescue, and delegates PR creation to the consuming project's `/create-pr`; pm is the project manager that supervises every feature and standalone item in a repo, with resumable dossiers and background workers mirrored in herdr)
- `dev-toolkit` — Standalone dev utilities (notify-me, pr-review, pr-retro)

## Dependencies

Skills delegate to external tools that must exist in consumer projects:
- `/create-worktree`
- `/clean-architecture`
- `/verify`
- `/e2e` (optional)
- `/research` (optional)
- `/create-pr` (optional) — implement-plan's final step delegates PR creation here; skipped if absent
- `dev-toolkit` (optional) — `notify-me`, `pr-review`, and `pr-retro` enrich pm; it degrades gracefully when unavailable
- `herdr` (optional) — attach panes mirror pm workers; it degrades gracefully when unavailable
- `quota-axi` — quota-aware routing and the pm orchestrator gate
- `claude` CLI — pm background workers (`claude --bg`), attach, and agent status

This repo provides `/verify`, `/create-pr`, `/create-worktree`, and `/release` in `.claude/skills/` for its own changes.

See `examples/android/` for reference implementations targeting Kotlin/Compose/Hilt.
