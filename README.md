# reminderkit-cli

CLI for Apple Reminders via the private ReminderKit framework. Supports subtasks, sections, and tags — none of which are available through AppleScript or EventKit. JSON output.

## Install

```bash
brew install johnmatthewtennant/tap/reminderkit-cli
reminderkit install-skill
```

## Claude Code

```
/apple-reminders
```

## CLI

```
reminderkit lists
reminderkit list <name>
reminderkit get <title> [--list <name>]
reminderkit add <title> [--list <name>] [--notes <value>]
reminderkit update <title> [--list <name>] [--title <value>] [--notes <value>] [--parent-title <title>] [--to-list <name>]
reminderkit complete <title> [--list <name>]
reminderkit delete <title> [--list <name>]
reminderkit subtasks <title> [--list <name>]
reminderkit batch                          # JSON on stdin
reminderkit --help                         # full usage
```

## Private API Notice

Uses Apple's private `ReminderKit.framework`. Not endorsed by Apple. May break with macOS updates.
