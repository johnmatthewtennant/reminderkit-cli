---
name: apple-reminders
description: Interact with Apple Reminders on macOS — create, read, update, complete, delete reminders, and manage folders, lists, sections, subtasks, and tags. Use when creating, adding, listing, getting, updating, completing, deleting, searching, or managing reminders, reminder folders, reminder lists, subtasks, sections, or tags in Apple Reminders.
allowed-tools:
  - Bash(reminderkit *)
---

# ReminderKit CLI

Command-line interface for Apple Reminders. Built on the private ReminderKit framework, which enables folders, subtasks, sections, and tags — none of which are fully supported by AppleScript or the public EventKit API. All output is JSON. Read the help text below for usage instructions.

## Folders

Apple Reminders calls list groups “folders.” Use the `folder` command names in
new automation; `group` aliases are accepted for compatibility with the
underlying ReminderKit terminology.

```bash
reminderkit folders
reminderkit create-folder --name <folder-name>
reminderkit rename-folder --old-name <old-name> --new-name <new-name>
reminderkit delete-folder --name <folder-name>  # folder must be empty
reminderkit move-list --name <list-name> --folder <folder-name>
reminderkit move-list --name <list-name> --remove-from-folder
```

Aliases: `groups` and `list-groups` for `folders`; `create-group`,
`rename-group`, and `delete-group` for their folder equivalents; `--group` for
`move-list --folder`.

`reminderkit folders` returns each folder with `name`, `id`, `uri`, and a
`lists` array. `reminderkit lists` adds `folder`, `folderId`, and `folderUri`
when a list belongs to a folder. Moving a list between accounts is not
supported. Move every child list out before deleting a folder.

## `reminderkit --help` (auto-executed)

!`reminderkit --help 2>&1`
