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
- `reminderkit add --title "Title" --list "List"` — create a reminder
- `reminderkit complete --id <id>` — complete a reminder
- `reminderkit list --name "List"` — list reminders in a list
- `reminderkit list --name "List" --has-url` — list only reminders that have a URL set
- `reminderkit list --name "List" --tag "tag1,tag2"` — list only reminders with any of the specified tags
- `reminderkit list --name "List" --exclude-tag "tag1,tag2"` — list reminders excluding those with any of the specified tags
- `reminderkit get --title "Title" --list "List"` — find a reminder by title
- `reminderkit get --url <url> [--list "List"]` — find a reminder by URL field (normalizes trailing slashes)
- `reminderkit get --id <id>` — fetch a reminder by ID (faster, no list scan needed)

## Linking reminders to Apple Notes

Link a reminder to an Apple Note using the `link-note` command:

```bash
reminderkit link-note --id <reminder-id> --note-id <note-identifier>
```

Or manually with `--url`:

```bash
# Get the note's link URL
NOTE_URL=$(notekit get-link --id "<note-id>" | jq -r '.url')

# Set it on the reminder
reminderkit update --id "<reminder-id>" --url "$NOTE_URL"
```

When a reminder's URL is an `applenotes://showNote` URL, the JSON output includes a `linkedNoteId` field with the note identifier:

```json
{
  "url": "applenotes://showNote?identifier=NOTE-UUID",
  "linkedNoteId": "NOTE-UUID"
}
```

To clear a reminder's URL:

```bash
reminderkit update --id <id> --clear-url
```

## Assigning reminders on shared lists

List who can be assigned on a shared list:

```bash
reminderkit list-sharees --name "Shared List"
```

Assign a reminder to a sharee:

```bash
reminderkit assign --id <reminder-id> --assignee-id <sharee-id>
```

Unassign a specific person or remove all assignments:

```bash
# Remove specific assignee
reminderkit unassign --id <reminder-id> --assignee-id <sharee-id>

# Remove all assignments
reminderkit unassign --id <reminder-id>
```

The `assignments` field appears in reminder JSON output when assignments exist:

```json
{
  "assignments": [
    {
      "assigneeID": "...",
      "originatorID": "...",
      "status": 0,
      "assignedDate": "2026-03-20T13:00:00Z"
    }
  ]
}
```

## `reminderkit --help` (auto-executed)

!`brew list --versions reminderkit-cli && reminderkit help 2>&1 || echo "reminderkit-cli is not installed"`
