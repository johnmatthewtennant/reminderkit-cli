---
name: apple-reminders
description: Interact with Apple Reminders on macOS — create, read, update, complete, delete reminders, manage lists, sections, subtasks, and tags. Use when creating, adding, listing, getting, updating, completing, deleting, searching, or managing reminders, reminder lists, subtasks, sections, or tags in Apple Reminders.
allowed-tools:
  - Bash(brew list *)
  - Bash(brew outdated *)
  - Bash(reminderkit *)
metadata:
  author: jtennant
  version: "0.1.0"
---

# ReminderKit CLI

Command-line interface for Apple Reminders. Built on the private ReminderKit framework, which enables subtasks, sections, and tags — none of which are supported by AppleScript or the public EventKit API. All output is JSON.


## Prerequisite check (auto-generated)

!`brew list --versions reminderkit-cli || echo "STOP: reminderkit-cli is not installed. Run: brew install johnmatthewtennant/tap/reminderkit-cli. See SETUP.md."`

!`brew outdated reminderkit-cli 2>/dev/null || echo "STOP: reminderkit-cli is outdated. Run: brew upgrade reminderkit-cli. See SETUP.md."`

## Basic usage

- `reminderkit lists` — list all reminder lists
- `reminderkit add "Title" --list "List"` — create a reminder
- `reminderkit complete "Title" --list "List"` — complete a reminder
- `reminderkit update "Child" --parent-title "Parent" --list "List"` — set parent

## `reminderkit --help` (auto-executed)

!`brew list --versions reminderkit-cli && reminderkit help 2>&1 || echo "reminderkit-cli is not installed"`
