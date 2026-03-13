# reminderkit-cli

A command-line interface for Apple Reminders, built on the private ReminderKit framework.

Supports full CRUD on reminders, lists, sections, subtasks, and tags — with JSON output for scripting.

## Quickstart

```bash
curl -sL https://raw.githubusercontent.com/johnmatthewtennant/reminderkit-cli/master/install.sh | bash
```

Then in Claude Code:

```
/apple-reminders
```

## Requirements

- macOS (tested on macOS 15+)
- Xcode Command Line Tools (`xcode-select --install`)

### Build from source

```bash
git clone https://github.com/johnmatthewtennant/reminderkit-cli.git
cd reminderkit-cli
make
```

## Usage

```
reminderkit lists
reminderkit list <name> [--include-completed]
reminderkit get <title> [--list <name>]
reminderkit subtasks <title> [--list <name>]
reminderkit add <title> [--list <name>] [--title <value>] [--notes <value>] [--completed <value>] [--priority <value>] [--flagged <value>] [--due-date <value>] [--start-date <value>]
reminderkit update <title> [--list <name>] [--title <value>] [--notes <value>] [--completed <value>] [--priority <value>] [--flagged <value>] [--due-date <value>] [--start-date <value>] [--remove-parent] [--remove-from-list]
reminderkit complete <title> [--list <name>]
reminderkit delete <title> [--list <name>]
reminderkit add-tag <title> <tag-name> [--list <name>]
reminderkit remove-tag <title> <tag-name> [--list <name>]
reminderkit list-sections <list-name>
reminderkit create-section <list-name> <section-name>
reminderkit create-list <name>
reminderkit rename-list <old-name> <new-name>
reminderkit delete-list <name>
reminderkit add-subtask <parent> <child> [--list <name>]
reminderkit test
```

## Private API Notice

This tool uses Apple's private `ReminderKit.framework`. It is not endorsed by Apple and may break with any macOS update. Use at your own risk.
