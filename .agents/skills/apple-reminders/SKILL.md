---
name: apple-reminders
description: Interact with Apple Reminders on macOS — create, read, update, complete, delete reminders, and manage groups, lists, list views, sections, subtasks, and tags. Use when creating, adding, listing, getting, updating, completing, deleting, searching, or managing reminders, reminder groups, reminder lists, List or Columns views, subtasks, sections, or tags in Apple Reminders.
allowed-tools:
  - Bash(reminderkit *)
---

# ReminderKit CLI

Command-line interface for Apple Reminders. Built on the private ReminderKit framework, which enables groups, subtasks, sections, and tags — none of which are fully supported by AppleScript or the public EventKit API. All output is JSON. Read the help text below for usage instructions.

## Groups

Groups contain and order reminder lists.

```bash
reminderkit groups
reminderkit create-group --name <group-name>
reminderkit rename-group --old-name <old-name> --new-name <new-name>
reminderkit move-group --name <group-name> --position <N>
reminderkit move-list --name <list-name> --group <group-name> [--position <N>]
reminderkit move-list --name <list-name> --remove-from-group
reminderkit delete-group --name <group-name>                    # empty group
reminderkit delete-group --name <group-name> --keep-lists       # move children to account root
reminderkit delete-group --name <group-name> --delete-lists     # destructive: delete child lists
```

`reminderkit groups` returns each group with `name`, `id`, `uri`, and an
ordered `lists` array. `reminderkit lists` adds `group`, `groupId`, and
`groupUri` when a list belongs to a group. Positions are one-based. Moving a
list between accounts is not supported. Deleting with `--delete-lists` also
deletes reminders in those lists and must only be used when explicitly wanted.

## Sections

Reorder a list's sections (the columns in Columns view) using a one-based
position:

```bash
reminderkit move-section --name <list-name> --section <section-name> --position <N>
```

## `reminderkit --help` (auto-executed)

!`reminderkit --help 2>&1`
