#!/bin/bash
# notify-me: Send system notifications from Claude Code (macOS and Linux)

set -e

# Read message from first arg or stdin
if [[ $# -gt 0 ]]; then
    message="$1"
    title="${2:-Claude Code}"
    subtitle="$3"
else
    message=$(cat)
    title="Claude Code"
    subtitle=""
fi

# Validate message
if [[ -z "$message" ]]; then
    echo "Usage: /notify-me \"message\" [title] [subtitle]"
    exit 1
fi

# Build the backend command as an argument array so the text is passed literally
os=$(uname -s)
case "$os" in
    Darwin)
        if ! command -v terminal-notifier >/dev/null 2>&1; then
            echo "Error: terminal-notifier not found. Install with: brew install terminal-notifier" >&2
            exit 1
        fi
        cmd=(terminal-notifier -message "$message" -title "$title")
        if [[ -n "$subtitle" ]]; then
            cmd+=(-subtitle "$subtitle")
        fi
        ;;
    Linux)
        if ! command -v notify-send >/dev/null 2>&1; then
            echo "Error: notify-send not found. Install with: sudo apt install libnotify-bin (Debian/Ubuntu) or the libnotify package (Fedora/Arch)" >&2
            exit 1
        fi
        # notify-send has no subtitle, so fold it into the body
        body="$message"
        if [[ -n "$subtitle" ]]; then
            body="$subtitle — $message"
        fi
        cmd=(notify-send "$title" "$body")
        ;;
    *)
        echo "Error: unsupported OS '$os'. notify-me supports macOS (Darwin) and Linux." >&2
        exit 1
        ;;
esac

# Execute
"${cmd[@]}"
