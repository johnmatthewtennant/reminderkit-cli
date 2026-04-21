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
- `reminderkit search --title "Title" --list "List"` — find a reminder by title
- `reminderkit search --url <url> [--list "List"]` — find a reminder by URL field (normalizes trailing slashes)
- `reminderkit search --id <id>` — fetch a reminder by ID (faster, no list scan needed)
- `reminderkit search --tag "tag1,tag2"` — search across all lists for reminders with any of the specified tags
- `reminderkit search --has-url` — search across all lists for reminders that have a URL set
- `reminderkit search --exclude-tag "tag1,tag2"` — search excluding reminders with any of the specified tags
- `reminderkit search --notes-contains "blocked_by: ABC123"` — search for reminders containing text in their notes (case-insensitive)
- `reminderkit list --name "List" --notes-contains "session: abc"` — list reminders in a list filtered by notes content
- `reminderkit search --tag "status-needs-human-review" --has-url` — combine filters (e.g., PRs needing review)
- `reminderkit search --title "bug" --tag "urgent"` — combine title search with tag filter
- `reminderkit update --id <id> --title "New Title"` — rename a reminder

## Output shaping

By default, reminder/list JSON uses bare UUIDs for `id` (safe to pass unquoted) and omits fields at their default values (`completed=false`, `priority=0`, etc.). A parallel `uri` key carries the full `x-apple-reminderkit://...` URL. Two flags tune the output:

- `--fields id,title,notes` — emit only the listed fields, in order. Use this to minimise tokens when scripting.
- `--full` — restore the pre-v2 output (legacy emoji-wrapped `id`, all default-valued fields, no `uri`). Adds a new `uuid` key for forward-compat.

`--id` accepts either a bare UUID or the legacy emoji-URL form interchangeably.

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

## Reading notes from stdin

Use `--notes -` or `--append-notes -` to read the value from stdin instead of a command-line argument. This avoids shell quoting issues with special characters like `<`, `>`, and `://` that appear in reminder IDs.

```bash
# Pipe notes content to avoid shell quoting issues
echo 'blocked_by: 🍄~<x-apple-reminderkit://REMCDReminder/UUID>' | reminderkit update --id "<id>" --append-notes -

# Multiline notes via heredoc piped to stdin
cat <<'EOF' | reminderkit add --title "My task" --list "List" --notes -
blocked_by: 🍄~<x-apple-reminderkit://REMCDReminder/UUID>
session: /path/to/session
EOF
```

This is the recommended approach when notes contain reminder IDs or other URL-like strings.

## `reminderkit --help` (auto-executed)

!`brew list --versions reminderkit-cli && reminderkit help 2>&1 || echo "reminderkit-cli is not installed"`
