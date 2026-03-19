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
reminderkit list (<name> | --name <name>)
reminderkit get (<title> | --title <title>) [--list <name>]
reminderkit add (<title> | --title <title>) [--list <name>] [--notes <value>]
reminderkit update (<title> | --title <title> | --id <id>) [--list <name>] [--notes <value>] [--parent <title>] [--parent-id <id>] [--to-list <name>]
reminderkit complete (<title> | --title <title> | --id <id>) [--list <name>]
reminderkit delete (<title> | --title <title> | --id <id>) [--list <name>]
reminderkit subtasks (<title> | --title <title>) [--list <name>]
reminderkit batch                          # JSON on stdin
reminderkit --help                         # full usage
```

## Private API Notice

Uses Apple's private `ReminderKit.framework`. Not endorsed by Apple. May break with macOS updates.
