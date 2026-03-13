# reminderkit-cli

A command-line interface for Apple Reminders, built on the private ReminderKit framework.

Supports full CRUD on reminders, lists, sections, subtasks, and tags — with JSON output for scripting.

## Requirements

- macOS (tested on macOS 15+)
- Xcode Command Line Tools (`xcode-select --install`)

## Install

```bash
brew install johnmatthewtennant/tap/reminderkit-cli
```

### Build from source

```bash
git clone https://github.com/johnmatthewtennant/reminderkit-cli.git
cd reminderkit-cli
make
```

This produces a `reminderkit` binary in the current directory. Move it to your PATH if desired.

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

## Claude Code Skill

Install the skill so Claude Code can use reminderkit automatically:

```bash
mkdir -p ~/.agents/skills/apple-reminders && curl -sL https://raw.githubusercontent.com/johnmatthewtennant/reminderkit-cli/master/.agents/skills/apple-reminders/SKILL.md -o ~/.agents/skills/apple-reminders/SKILL.md && ln -sfn ~/.agents/skills/apple-reminders ~/.claude/skills/apple-reminders
```

## Private API Notice

This tool uses Apple's private `ReminderKit.framework`. It is not endorsed by Apple and may break with any macOS update. Use at your own risk.
