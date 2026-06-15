#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# test-worktree.sh — Repoint the q-skills marketplace at a git worktree so you
# can manually test plugin changes before merging them to main.
#
# WHY
#   Both Claude config dirs (~/.claude and ~/.claude-personal) install the
#   workflow-kit and dev-toolkit plugins from the q-skills marketplace, which
#   is sourced from the *main* checkout at the repo root. To exercise unmerged
#   changes you must point the marketplace at a worktree, reinstall the plugins,
#   then restart Claude Code.
#
# WHAT IT DOES (`use`)
#   For each target config dir:
#     1. Uninstall workflow-kit@q-skills and dev-toolkit@q-skills (user scope).
#     2. Remove the q-skills marketplace (all scopes).
#     3. Re-add the q-skills marketplace from the chosen worktree path.
#     4. Reinstall both plugins from that marketplace.
#   Restart Claude Code afterward to load the relinked plugins.
#
#   `restore` does the same but repoints back at the repo root (main checkout).
#
# USAGE
#   ./scripts/test-worktree.sh use [worktree-path]   # omit to pick interactively
#   ./scripts/test-worktree.sh restore               # back to repo root
#   ./scripts/test-worktree.sh status                # show current wiring
#   ./scripts/test-worktree.sh help
#
# TARGET CONFIG DIRS: ~/.claude  ~/.claude-personal
# AVAILABLE PLUGINS:  workflow-kit  dev-toolkit
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Shared constants
# ---------------------------------------------------------------------------

ROOT="$(git rev-parse --show-toplevel)"
MARKETPLACE_NAME="q-skills"
PLUGINS=("workflow-kit" "dev-toolkit")

# Claude config dirs to operate on, as "label:path" pairs. The default dir is
# selected by Claude when CLAUDE_CONFIG_DIR is unset; the personal dir is an
# alternate profile.
CONFIG_DIRS=(
    "claude:$HOME/.claude"
    "claude-personal:$HOME/.claude-personal"
)

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

# Print message to stderr and exit 1.
die() {
    echo "error: $*" >&2
    exit 1
}

# Print full help text to stdout and exit 0 (explicit help request).
help() {
    cat <<EOF
test-worktree.sh — Repoint the q-skills marketplace at a worktree for testing.

USAGE
  ./scripts/test-worktree.sh <subcommand> [args]
  ./scripts/test-worktree.sh help | -h | --help

SUBCOMMANDS
  use [worktree-path]
      Relink the q-skills marketplace to <worktree-path> in every target
      config dir, then reinstall the plugins. If the path is omitted, pick
      from the repo's git worktrees interactively. The path must be a
      directory containing .claude-plugin/marketplace.json.

  restore
      Relink the q-skills marketplace back to the repo root ($ROOT)
      — i.e. the main checkout — and reinstall the plugins.

  status
      Show, per config dir, the q-skills marketplace source and the installed
      versions of each plugin.

TARGET CONFIG DIRS
  ~/.claude  ~/.claude-personal

AVAILABLE PLUGINS
  ${PLUGINS[*]}

AFTER RUNNING
  Restart Claude Code so the relinked plugins are reloaded.

EXAMPLES
  ./scripts/test-worktree.sh use ../q-skills-feature-x
  ./scripts/test-worktree.sh use
  ./scripts/test-worktree.sh restore
  ./scripts/test-worktree.sh status
EOF
    exit 0
}

# Print usage hint to stderr and exit non-zero (misuse / unknown subcommand).
usage() {
    cat >&2 <<EOF
Usage: test-worktree.sh <subcommand> [args]

Subcommands:
  use [worktree-path]   Relink marketplace to a worktree and reinstall plugins
  restore               Relink marketplace back to the repo root
  status                Show marketplace source and plugin versions per config dir

Run 'test-worktree.sh help' for full documentation.
EOF
    exit 1
}

# Die with a clear message if claude is not found on PATH.
require_tools() {
    command -v claude &>/dev/null \
        || die "required tool 'claude' not found on PATH"
}

# Run a claude subcommand against a specific config dir.
#   claude_in <config-dir> <claude-args...>
claude_in() {
    local dir="$1"; shift
    CLAUDE_CONFIG_DIR="$dir" claude "$@"
}

# Echo the absolute path of $1, dying if it is not a directory containing a
# marketplace manifest at .claude-plugin/marketplace.json.
resolve_marketplace_path() {
    local path="$1"
    [[ -d "$path" ]] || die "not a directory: $path"
    local abs
    abs="$(cd "$path" && pwd)" || die "cannot resolve path: $path"
    [[ -f "$abs/.claude-plugin/marketplace.json" ]] \
        || die "no .claude-plugin/marketplace.json found under: $abs"
    echo "$abs"
}

# Interactively pick a worktree path from `git worktree list`. Echoes the
# chosen absolute path on stdout; all prompts go to stderr.
pick_worktree() {
    local paths=()
    local line
    while IFS= read -r line; do
        # `git worktree list --porcelain` emits "worktree <abs-path>" lines.
        [[ "$line" == worktree\ * ]] && paths+=("${line#worktree }")
    done < <(git worktree list --porcelain)

    [[ ${#paths[@]} -gt 0 ]] || die "no git worktrees found"

    echo "Select a worktree to test:" >&2
    local choice
    select choice in "${paths[@]}"; do
        [[ -n "$choice" ]] && { echo "$choice"; return 0; }
        echo "Invalid selection. Try again." >&2
    done
}

# ---------------------------------------------------------------------------
# Core: relink the marketplace to $1 across all config dirs and reinstall.
# ---------------------------------------------------------------------------

relink() {
    local source="$1"
    local pair label dir plugin

    for pair in "${CONFIG_DIRS[@]}"; do
        label="${pair%%:*}"
        dir="${pair#*:}"

        if [[ ! -d "$dir" ]]; then
            echo "── $label ($dir): not present, skipping" >&2
            continue
        fi

        echo "── $label ($dir)" >&2

        # 1. Uninstall plugins (tolerate "not installed").
        for plugin in "${PLUGINS[@]}"; do
            echo "   uninstall $plugin@$MARKETPLACE_NAME" >&2
            claude_in "$dir" plugin uninstall "$plugin@$MARKETPLACE_NAME" \
                --scope user -y &>/dev/null || true
        done

        # 2. Remove the marketplace from every scope (tolerate absence).
        echo "   remove marketplace $MARKETPLACE_NAME" >&2
        claude_in "$dir" plugin marketplace remove "$MARKETPLACE_NAME" \
            &>/dev/null || true

        # 3. Re-add the marketplace from the chosen source.
        echo "   add marketplace $MARKETPLACE_NAME -> $source" >&2
        claude_in "$dir" plugin marketplace add "$source" --scope user \
            || die "failed to add marketplace from $source ($label)"

        # 4. Reinstall plugins.
        for plugin in "${PLUGINS[@]}"; do
            echo "   install $plugin@$MARKETPLACE_NAME" >&2
            claude_in "$dir" plugin install "$plugin@$MARKETPLACE_NAME" \
                --scope user \
                || die "failed to install $plugin@$MARKETPLACE_NAME ($label)"
        done
    done

    echo >&2
    echo "Done. Marketplace '$MARKETPLACE_NAME' now sourced from:" >&2
    echo "  $source" >&2
    echo "Restart Claude Code to load the relinked plugins." >&2
}

# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------

cmd_use() {
    local path="${1:-}"
    if [[ -z "$path" ]]; then
        path="$(pick_worktree)"
    fi
    local source
    source="$(resolve_marketplace_path "$path")"

    [[ "$source" != "$ROOT" ]] \
        || echo "note: $source is the repo root (main checkout), not a worktree" >&2

    relink "$source"
}

cmd_restore() {
    relink "$ROOT"
}

cmd_status() {
    local pair label dir
    for pair in "${CONFIG_DIRS[@]}"; do
        label="${pair%%:*}"
        dir="${pair#*:}"

        echo "── $label ($dir)"
        if [[ ! -d "$dir" ]]; then
            echo "   not present"
            continue
        fi

        echo "   marketplace:"
        claude_in "$dir" plugin marketplace list 2>/dev/null \
            | grep -A1 "$MARKETPLACE_NAME" | sed 's/^/   /' \
            || echo "   (none)"

        echo "   plugins:"
        claude_in "$dir" plugin list 2>/dev/null \
            | grep -A2 "@$MARKETPLACE_NAME" | sed 's/^/   /' \
            || echo "   (none installed)"
        echo
    done
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

require_tools

case "${1:-}" in
    use)            shift; cmd_use "$@" ;;
    restore)        shift; cmd_restore ;;
    status)         shift; cmd_status ;;
    help|-h|--help) help ;;
    "")             usage ;;
    *)              echo "error: unknown subcommand '${1}'" >&2; echo >&2; usage ;;
esac
