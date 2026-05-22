# qualls-core

Claude Code plugin for implementation planning and code generation.

Core reusable skill: `implement-plan` for structured feature development.

## Local Installation

### 1. Clone the repo

```bash
git clone https://github.com/Alton09/claude-skill-core.git ~/Workspace/claude-skill-core
```

### 2. Register the marketplace in `~/.claude/settings.json`

Add to `extraKnownMarketplaces`:

```json
"extraKnownMarketplaces": {
  "qualls-core": {
    "source": {
      "source": "directory",
      "path": "/path/to/claude-skill-core"
    }
  }
}
```

Replace `/path/to/claude-skill-core` with your actual clone path.

### 3. Install the plugin

Add to `installedPlugins` in `~/.claude/settings.json`:

```json
"installedPlugins": {
  "qualls-core@qualls-core": true
}
```

### 4. Verify the marketplace key matches

The key in `extraKnownMarketplaces` must be `qualls-core` — this must match the `@marketplace`
suffix in `installedPlugins`. A mismatch causes "Plugin not found in marketplace" errors.
Claude Code also caches a `known_marketplaces.json` file; if you see this error after setup,
check that the key there is also `qualls-core` (not `qualls-core-marketplace` or similar).

### 5. Reload plugins

Run `/reload-plugins` in Claude Code. Run `/doctor` to confirm no errors.

Skills are then available as `/qualls-core:implement-plan`.
