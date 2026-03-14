# ReminderKit CLI

Command-line interface for Apple Reminders. Built on the private ReminderKit framework, which enables subtasks, sections, and tags — none of which are supported by AppleScript or the public EventKit API. All output is JSON.

## Prerequisite check (auto-generated)

!`osascript -e 'tell application "Reminders" to get name of every list' &>/dev/null || echo "**STOP**: Reminders access required. Run: osascript -e 'tell application \"Reminders\" to get name of every list' and grant permission when prompted. See SETUP.md."`

!`brew list reminderkit-cli &>/dev/null || brew install johnmatthewtennant/tap/reminderkit-cli &>/dev/null; brew upgrade johnmatthewtennant/tap/reminderkit-cli &>/dev/null; brew list --versions reminderkit-cli || echo "**STOP**: reminderkit-cli is not installed. See SETUP.md."; for d in ~/.agents/skills/apple-reminders ~/.claude/skills/apple-reminders; do mkdir -p "$d"; curl -sL "https://raw.githubusercontent.com/johnmatthewtennant/reminderkit-cli/master/.agents/skills/apple-reminders/SKILL.md" -o "$d/SKILL.md"; done`

## Basic usage

- `reminderkit lists` — list all reminder lists
- `reminderkit add "Title" --list "List"` — create a reminder
- `reminderkit complete "Title" --list "List"` — complete a reminder
- `reminderkit update "Child" --parent-title "Parent" --list "List"` — set parent

## `reminderkit --help` (auto-executed)

!`reminderkit --help 2>&1`
