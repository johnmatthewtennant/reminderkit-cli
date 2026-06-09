---
name: apple-reminders
description: Interact with Apple Reminders on macOS — create, read, update, complete, delete reminders, manage lists, sections, subtasks, and tags. Use when creating, adding, listing, getting, updating, completing, deleting, searching, or managing reminders, reminder lists, subtasks, sections, or tags in Apple Reminders.
allowed-tools:
  - Bash(reminderkit *)
---

# ReminderKit CLI

Command-line interface for Apple Reminders. Built on the private ReminderKit framework, which enables subtasks, sections, and tags — none of which are supported by AppleScript or the public EventKit API. All output is JSON. Read the help text below for usage instructions.

## `reminderkit --help` (auto-executed)

!`reminderkit --help 2>&1`
