# reminderkit-cli output contract

This document specifies the shape of the JSON emitted by every command that
returns a reminder, list, or section. Scripts and agents should rely on this
contract, not on incidental output details.

## Default (v2) output

- `id` is a bare UUID, 36 chars, uppercase (e.g. `706D8583-A718-4644-9056-E79D9C8E9625`).
- `uri` carries the canonical `x-apple-reminderkit://REMCDReminder/<UUID>` URL
  (without an emoji prefix and without surrounding angle brackets).
- References to other objects use parallel keys:
    - the list reference: `listId` (bare UUID) + `listUri` (URL)
    - the parent reminder reference: `parentId` + `parentUri`
- Default-valued fields are OMITTED entirely to reduce output size:

| field         | default | omitted when |
|---------------|---------|--------------|
| `allDay`      | `false` | value is false |
| `completed`   | `false` | value is false |
| `flagged`     | `0`     | value is 0 |
| `isOverdue`   | `false` | value is false |
| `isRecurrent` | `false` | value is false |
| `priority`    | `0`     | value is 0 |
| `hashtags`    | `[]`    | array is empty |

  Non-default values are always included. Any nil/null optional field is
  already omitted (e.g. no `notes` key when the reminder has no notes).

## `--fields <csv>` projection

When `--fields` is passed, the output includes ONLY the listed fields, in
the order specified. Order is preserved in the serialised JSON.

Example: `reminderkit list --name X --fields id,title` emits

```json
[
  { "id": "...", "title": "..." },
  ...
]
```

If both `--fields` and `--full` are passed, `--fields` wins.

## `--full` (legacy byte-compat) output

When `--full` is passed, the output is byte-for-byte identical to the
pre-ergonomic (v1) CLI output PLUS a single new `uuid` key alongside `id`:

- `id` is the legacy emoji-URL-wrapped form
  (`🎅~<x-apple-reminderkit://REMCDReminder/<UUID>>`) exactly as NSManagedObjectID
  renders it.
- `listID` (capitalised) carries the same legacy form for the list.
- All default-valued fields are emitted explicitly.
- `uri`, `listUri`, `parentUri`, `listId`, `parentId` are NOT emitted in
  `--full` mode to preserve the exact original byte stream.
- `uuid` (new, additive) carries the bare UUID for the reminder itself, so
  v1 scripts can migrate by reading `uuid` without breaking.

## Input: `--id` accepts either form

Every subcommand that takes `--id` accepts ANY of the following:

- Bare UUID: `706D8583-A718-4644-9056-E79D9C8E9625` (any case; output is
  always uppercase)
- Legacy emoji-URL form: `🎅~<x-apple-reminderkit://REMCDReminder/706D...>`
- Naked URL form: `x-apple-reminderkit://REMCDReminder/706D...`

The CLI normalises internally by extracting the 36-char UUID and matching on
that. Wrapping/unwrapping around EventKit is handled by the CLI.

## Shell quoting

The bare-UUID default was chosen specifically because it's safe to pass
unquoted through shells. The legacy emoji-URL form contains `<`, `>`, `://`,
and other characters that require quoting. Prefer bare UUIDs in new scripts.
