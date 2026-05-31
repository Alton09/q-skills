---
name: notify-me
description: Send macOS system notifications from Claude Code. Use this skill whenever you need to notify the user of task completion, status updates, or important events — especially when blocking on long-running operations. Triggers on /notify-me, /notify, or /send notification. Examples: "notify me when the build finishes", "send a notification saying tests passed", "i want a mac notification with this status".
---

# notify-me

Send native macOS system notifications to alert the user during long-running tasks or important state changes.

## Usage

### Basic notification
```
/notify-me "Build complete!"
```

### With custom title
```
/notify-me "Tests passed" "CI Pipeline"
```

### With title and subtitle
```
/notify-me "Deployment finished" "Production" "12:34 PM"
```

### From stdin
```
echo "Task done" | /notify-me
```

## Arguments

| Argument | Type | Required | Default | Description |
|----------|------|----------|---------|-------------|
| message | string | Yes | — | Notification body text |
| title | string | No | "Claude Code" | Notification title |
| subtitle | string | No | — | Optional subtitle for secondary context |

## When to use this skill

- **Task completion alerts**: Notify when long-running builds, tests, or deployments finish
- **Status updates**: Send intermediate checkpoints during multi-step workflows
- **Blocking operations**: Alert when waiting for user input or external system response
- **Error conditions**: Notify on failures that need immediate attention

## Implementation

`notify-me.sh` wraps macOS's `terminal-notifier` command to display native notifications. The script reads the message from the first argument or stdin, constructs the notification command, and executes it.

## Dependencies

**Required:** `terminal-notifier` (macOS utility)

Install with:
```bash
brew install terminal-notifier
```

## Notes

- macOS only (uses native Notification Center)
- Non-blocking — fires notification and returns immediately
- No network required — local system notifications only
