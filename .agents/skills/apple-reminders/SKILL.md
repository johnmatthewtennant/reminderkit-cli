# ReminderKit CLI

Command-line interface for Apple Reminders. Built on the private ReminderKit framework, which enables subtasks, sections, and tags — none of which are supported by AppleScript or the public EventKit API. All output is JSON.

## Installation Status (auto-generated)

!`if brew list reminderkit-cli &>/dev/null; then v=$(brew list --versions reminderkit-cli | awk '{print $2}'); brew upgrade johnmatthewtennant/tap/reminderkit-cli &>/dev/null; nv=$(brew list --versions reminderkit-cli | awk '{print $2}'); if [ "$v" != "$nv" ]; then echo "updated $v → $nv"; else echo "$v (latest)"; fi; else brew install johnmatthewtennant/tap/reminderkit-cli &>/dev/null && echo "installed $(brew list --versions reminderkit-cli | awk '{print $2}')"; fi`

## Usage

!`reminderkit --help 2>&1`
