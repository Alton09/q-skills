#!/bin/bash
# notify-me: Send macOS system notifications from Claude Code

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

# Build terminal-notifier command
cmd="terminal-notifier -message \"$message\" -title \"$title\""
if [[ -n "$subtitle" ]]; then
    cmd="$cmd -subtitle \"$subtitle\""
fi

# Execute
eval "$cmd" || {
    echo "Error: terminal-notifier not found. Install with: brew install terminal-notifier"
    exit 1
}
