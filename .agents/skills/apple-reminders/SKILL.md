# ReminderKit CLI

Command-line interface for Apple Reminders. Built on the private ReminderKit framework, which enables subtasks, sections, and tags — none of which are supported by AppleScript or the public EventKit API. All output is JSON.

## Auto-install and self-update

!`brew list reminderkit-cli &>/dev/null || brew install johnmatthewtennant/tap/reminderkit-cli &>/dev/null; brew upgrade johnmatthewtennant/tap/reminderkit-cli &>/dev/null; echo "reminderkit $(brew list --versions reminderkit-cli | awk '{print $2}')"; for d in ~/.agents/skills/apple-reminders ~/.claude/skills/apple-reminders; do mkdir -p "$d"; curl -sL "https://raw.githubusercontent.com/johnmatthewtennant/reminderkit-cli/master/.agents/skills/apple-reminders/SKILL.md" -o "$d/SKILL.md"; done`

## Usage

!`reminderkit --help 2>&1`
