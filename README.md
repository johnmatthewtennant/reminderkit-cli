# reminderkit-cli

CLI for Apple Reminders via the private ReminderKit framework. Supports subtasks, sections, and tags — none of which are available through AppleScript or EventKit. JSON output.

## Install

```bash
brew install johnmatthewtennant/tap/reminderkit-cli
reminderkit install-skill
```

## Claude Code

```
/apple-reminders
```

## CLI

```
reminderkit lists
reminderkit list (<name> | --name <name>)
reminderkit get (<title> | --title <title>) [--list <name>]
reminderkit add (<title> | --title <title>) [--list <name>] [--notes <value>]
reminderkit update (<title> | --title <title> | --id <id>) [--list <name>] [--notes <value>] [--parent-title <title>] [--to-list <name>]
reminderkit complete (<title> | --title <title> | --id <id>) [--list <name>]
reminderkit delete (<title> | --title <title> | --id <id>) [--list <name>]
reminderkit subtasks (<title> | --title <title>) [--list <name>]
reminderkit batch                          # JSON on stdin
reminderkit --help                         # full usage
```

## Output shape

By default, every command that emits a reminder/list JSON object produces a
token-efficient shape:

- **IDs are bare UUIDs** (36 chars). The full `x-apple-reminderkit://...`
  URL is also emitted under a parallel `uri` key. For the reminder's list
  reference it's `listId` (UUID) + `listUri` (URL), and similarly
  `parentId`/`parentUri` for a subtask's parent.
- **Default-valued fields are omitted**. Specifically:
  `allDay=false`, `completed=false`, `flagged=0`, `isOverdue=false`,
  `isRecurrent=false`, `priority=0`, and empty `hashtags` are NOT emitted.
  Non-default values are always included.

Two flags shape the output further (accepted by any command that produces JSON):

- `--fields id,title,notes` — emit ONLY the listed fields, in order.
  Precedence: `--fields` wins if both `--fields` and `--full` are passed.
- `--full` — emit all fields including defaults, and use the legacy
  emoji-wrapped `id` format (for byte-for-byte compat with pre-ergonomic
  scripts), additionally adding a new `uuid` field. Fields `uri` / `listUri`
  are suppressed in `--full` mode.

`--id` accepts EITHER a bare UUID or any form containing one (legacy emoji
URL, naked `x-apple-reminderkit://` URL, mixed case, etc.).

### Migration for pre-ergonomic script callers

To restore the previous output exactly (minus a new, additive `uuid` key),
pass `--full`. See `CONTRACT.md` for the full contract.

## Private API Notice

Uses Apple's private `ReminderKit.framework`. Not endorsed by Apple. May break with macOS updates.
