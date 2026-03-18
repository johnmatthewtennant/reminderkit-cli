# Plan: Support Linking Reminders to Apple Notes

## Research Session

Session: dispatched agent (planning task for reminder 08958443-E99A)

## Summary

This plan describes how to enable reminderkit-cli users to link a reminder to an Apple Note by storing an `applenotes://` URL in the reminder's URL field. The existing `--url` flag already accepts `applenotes://` URLs with zero code changes (Option 1: docs-only). This plan also proposes convenience features for a better UX (Option 2: enhanced).

**Option 1 (docs-only, ship now):** Document the workflow in the skill file. No code changes. Works today.

**Option 2 (enhanced UX):** Add `link-note` command, `linkedNoteId` output field, `--clear-url` flag, and tests.

## Research Findings

### How reminderkit-cli handles URLs today

The reminder URL is stored via the `attachmentContext` mechanism in ReminderKit:

- **Reading:** `reminderToDict()` (line 268-277 in `reminderkit.m`) reads the URL from `attachmentContext -> urlAttachments[0] -> url`
- **Writing (add):** `cmdAdd()` (line 698-699) sets it via `attachmentContext -> setURLAttachmentWithURL:`
- **Writing (update):** `cmdUpdate()` (line 975-976) sets it via the same `attachmentContext` path on the change item
- **CLI flag:** `--url <value>` on both `add` and `update` commands
- **JSON output:** Exposed as `"url"` in all reminder JSON output

There is also an `icsUrl` property on REMReminder (seen in `generate-cli.py` line 63) and a `setIcsUrl:` setter (line 77), but the manually-maintained `reminderkit.m` uses the `attachmentContext` approach instead. Both refer to the same underlying URL attachment -- the `attachmentContext` route is the canonical one used by Apple's Reminders app UI.

**Known limitation:** `--url ""` does NOT clear an existing URL. `[NSURL URLWithString:@""]` returns nil, so the `setURLAttachmentWithURL:` call is skipped and the existing URL remains. This needs to be fixed as part of Option 2.

### How notekit-cli handles applenotes:// URLs

Based on the notekit-cli codebase (specifically `thoughts/shared/plans/add-note-linking.md`):

- **URL format:** `applenotes://showNote?identifier=<NOTE_UUID>`
- **Generation:** `notekit get-link --id <note-id>` returns the `applenotes://` URL
- **The URL is just a regular URL** -- no special framework integration needed on the consumer side
- **The `ICAppURLUtilities` class** in the NotesShared framework handles URL generation/parsing, but that is only needed by notekit-cli, not by consumers of the URL

### Can applenotes:// URLs be stored in a reminder's URL field?

**Yes.** Verified experimentally: creating a test reminder with `--url "applenotes://showNote?identifier=test123"` works correctly. The URL is stored and returned in JSON output. The Reminders app shows it as a clickable link. When clicked on macOS, it opens Apple Notes to the linked note (assuming the note exists).

### Is there a deeper framework integration?

**No.** ReminderKit has no built-in concept of "linked notes." There is no `noteID` property, no `linkedNote` relationship, and no special integration between ReminderKit and NotesShared frameworks. The URL attachment field is the standard mechanism Apple uses for linking reminders to external resources (web pages, files, etc.) and it works equally well for `applenotes://` URLs.

The Reminders app itself uses the URL field when you drag a note onto a reminder -- it stores an `applenotes://` URL.

## Option 1: Docs-Only (No Code Changes)

Update the reminderkit skill file to document how to link a reminder to a note:

```bash
# Get the note's link URL
NOTE_URL=$(notekit get-link --id "<note-id>" | jq -r '.url')

# Set it on the reminder
reminderkit update --id "<reminder-id>" --url "$NOTE_URL"

# Or when creating a new reminder
reminderkit add --title "Review meeting notes" --url "$NOTE_URL"
```

This works today with zero code changes. The only gap is URL clearing (see Option 2).

## Option 2: Enhanced UX (Code Changes)

### Phase 1: Fix URL clearing with `--clear-url` flag

**File:** `reminderkit.m`

**Problem:** `--url ""` silently no-ops because `[NSURL URLWithString:@""]` returns nil. There is no way to clear an existing URL from a reminder.

**Solution:** Add a `--clear-url` flag to the `update` command that removes the URL attachment.

**Mutual exclusion:** If both `--url` and `--clear-url` are provided, error out immediately with: `"Cannot use --url and --clear-url together"`. Check this before any save logic executes.

In `cmdUpdate()`, add the mutual-exclusion check before the existing `--url` handling:

```objc
if (opts[@"url"] && opts[@"clear-url"]) {
    errorExit(@"Cannot use --url and --clear-url together");
}
```

Then, after the existing `--url` handling (around line 976), add the clear logic:

```objc
if (opts[@"clear-url"]) {
    id attCtx = ((id (*)(id, SEL))objc_msgSend)(
        changeItem, sel_registerName("attachmentContext"));
    ((void (*)(id, SEL, id))objc_msgSend)(
        attCtx, sel_registerName("setURLAttachmentWithURL:"), nil);
}
```

**Integration points in the codebase:**

1. **`main()` boolean-flag parser** (line 1656-1662): The CLI parser only treats explicitly listed flags as no-value booleans. All other `--flags` consume the next argv token as their value. `--clear-url` must be added to the boolean-flag branch alongside `remove-parent`, `remove-from-list`, `help`, `claude`, `agents`, and `force`:
   ```objc
   if ([flag isEqualToString:@"include-completed"] ||
       [flag isEqualToString:@"remove-parent"] ||
       [flag isEqualToString:@"remove-from-list"] ||
       [flag isEqualToString:@"clear-url"] ||  // <-- add this
       [flag isEqualToString:@"help"] ||
       ...
   ```
   Without this, `--clear-url` will try to consume the next argument as its value, breaking argument parsing.
2. **`cmdBatch()` validKeys set** (around line 1096): Add `@"clear-url"` to the `validKeys` NSSet so batch update operations accept this key. Add the same mutual-exclusion check in the batch update path:
   ```objc
   if (op[@"url"] && op[@"clear-url"]) {
       errorExit(@"Cannot use 'url' and 'clear-url' together in batch update");
   }
   ```
   Then add the clear logic after the existing batch URL handling (around line 1227):
   ```objc
   if (op[@"clear-url"]) {
       id attCtx = ((id (*)(id, SEL))objc_msgSend)(changeItem, sel_registerName("attachmentContext"));
       ((void (*)(id, SEL, id))objc_msgSend)(attCtx, sel_registerName("setURLAttachmentWithURL:"), nil);
   }
   ```

Add to `usage()`:

```
reminderkit update --id <id> [...] [--clear-url]
```

### Phase 2: Add `link-note` convenience command

**File:** `reminderkit.m`

Add a new command that takes a reminder ID and a note identifier, constructs the `applenotes://` URL, and sets it on the reminder by delegating to the existing `cmdUpdate` logic.

```
reminderkit link-note --id <reminder-id> --note-id <note-identifier>
```

Implementation approach -- delegate to `cmdUpdate` to avoid duplicating save logic:

```objc
static int cmdLinkNote(id store, NSString *remId, NSString *noteId) {
    // Construct the applenotes:// URL using NSURLComponents for proper encoding
    NSURLComponents *comps = [[NSURLComponents alloc] init];
    comps.scheme = @"applenotes";
    comps.host = @"showNote";
    comps.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"identifier" value:noteId]
    ];
    NSString *urlStr = [comps string];
    if (!urlStr) errorExit(@"Failed to construct note URL from note-id");

    // Delegate to cmdUpdate with the constructed URL
    // This reuses all existing ID resolution, save request, and output logic
    return cmdUpdate(store, nil, @{@"id": remId, @"url": urlStr});
}
```

Key design decisions:
- **No note existence verification.** The URL field is just a string -- consistent with how `--url` works today (no validation of web URLs either). If the note does not exist, clicking the link in Reminders shows "Note not found" in Apple Notes.
- **Uses `NSURLComponents`** for proper URL construction with percent-encoding, rather than naive string concatenation. This handles note IDs with special characters correctly.
- **Delegates to `cmdUpdate`** rather than duplicating the save request / change item / attachment context logic. This ensures `link-note` benefits from any future improvements to `cmdUpdate`.

Add to `main()` command dispatch:

```objc
} else if ([command isEqualToString:@"link-note"]) {
    if (!opts[@"id"]) errorExit(@"link-note requires --id");
    if (!opts[@"note-id"]) errorExit(@"link-note requires --note-id");
    return cmdLinkNote(store, opts[@"id"], opts[@"note-id"]);
}
```

Add to `usage()`:

```
reminderkit link-note --id <id> --note-id <note-identifier>
```

### Phase 3: Detect note links in output

**File:** `reminderkit.m`, function `reminderToDict()`

When the URL is an `applenotes://` URL, add a `linkedNoteId` field to the JSON output by parsing the identifier using `NSURLComponents`:

```objc
// After existing URL reading (line 274):
if (attUrl) {
    dict[@"url"] = [attUrl absoluteString];
    // Detect applenotes:// note links and extract note ID
    if ([[attUrl scheme] isEqualToString:@"applenotes"]
        && [[attUrl host] isEqualToString:@"showNote"]) {
        NSURLComponents *comps = [NSURLComponents componentsWithURL:attUrl
            resolvingAgainstBaseURL:NO];
        for (NSURLQueryItem *item in comps.queryItems) {
            if ([item.name isEqualToString:@"identifier"] && item.value.length > 0) {
                dict[@"linkedNoteId"] = item.value;
                break;
            }
        }
    }
}
```

**Backward compatibility note:** The `linkedNoteId` field is additive -- it only appears when the URL is an `applenotes://showNote` URL. Existing consumers that do not expect this field will simply ignore it (standard JSON behavior). The `url` field continues to be present as before.

### Phase 4: Tests

Add to `cmdTest()` in `reminderkit.m`. The test suite already exists and uses in-process testing with cleanup.

**Executable path for subprocess tests:** Resolve the current executable path at the start of the test function using `_NSGetExecutablePath` (already used elsewhere in the codebase). Shell-escape the path using `NSString stringWithFormat` with single-quote wrapping to handle paths containing spaces:

```objc
char exePath[PATH_MAX];
uint32_t exeSize = sizeof(exePath);
_NSGetExecutablePath(exePath, &exeSize);
realpath(exePath, exePath);
NSString *quotedExe = [NSString stringWithFormat:@"'%s'",
    [[[NSString stringWithUTF8String:exePath]
      stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]
     UTF8String]];
```

**Happy path tests:**

1. **Create reminder with note URL:** Create a reminder with `--url "applenotes://showNote?identifier=FAKE-NOTE-ID"`. Verify the output contains both `"url"` with the full URL and `"linkedNoteId"` with `"FAKE-NOTE-ID"`.
2. **Update reminder with note URL:** Update the test reminder's URL to `"applenotes://showNote?identifier=OTHER-NOTE-ID"`. Verify `linkedNoteId` changes to `"OTHER-NOTE-ID"`.
3. **link-note command:** Use `link-note --id <test-id> --note-id YET-ANOTHER-ID`. Verify the URL is `applenotes://showNote?identifier=YET-ANOTHER-ID` and `linkedNoteId` is `"YET-ANOTHER-ID"`.
4. **Clear URL:** Use `update --id <test-id> --clear-url`. Verify the `url` and `linkedNoteId` fields are absent from the output.
5. **Non-note URL:** Create a reminder with `--url "https://example.com"`. Verify `url` is present but `linkedNoteId` is absent.

**Negative tests (subprocess via `system()`):**

Use the shell-escaped executable path (resolved above) to shell out for error-case tests that call `exit(1)`:

6. **link-note with missing --note-id:** Run `system("<quotedExe> link-note --id VALID 2>/dev/null")` and assert exit code != 0.
7. **link-note with missing --id:** Run `system("<quotedExe> link-note --note-id VALID 2>/dev/null")` and assert exit code != 0.
8. **link-note with invalid reminder ID:** Run `link-note --id NONEXISTENT --note-id FAKE` via subprocess and assert exit code != 0.

**Conflict tests:**

9. **--url and --clear-url together (CLI):** Run `system("<quotedExe> update --id VALID --url 'https://x.com' --clear-url 2>/dev/null")` and assert exit code != 0.
10. **url and clear-url together (batch):** Provide a batch JSON with `[{"op": "update", "id": "VALID", "url": "https://x.com", "clear-url": true}]` via stdin and assert exit code != 0.

**Edge case tests:**

11. **Malformed applenotes:// URL:** Create a reminder with `--url "applenotes://other?foo=bar"` (not a `showNote` URL). Verify `url` is present but `linkedNoteId` is absent.
12. **applenotes:// URL without identifier param:** Create a reminder with `--url "applenotes://showNote"` (no query string). Verify `url` is present but `linkedNoteId` is absent.

**Cleanup:** Delete all test reminders and the test list created during these tests.

### Phase 5: Update usage and skill documentation

- Add `link-note` and `--clear-url` to `usage()` in `reminderkit.m`
- Update the skill file (`.agents/skills/apple-reminders/SKILL.md`) to document:
  - The `link-note` command
  - The `linkedNoteId` output field
  - The `--clear-url` flag
  - Example workflow for linking a reminder to a note

## Summary of Changes

| File | Change | Effort |
|------|--------|--------|
| `reminderkit.m` -- `cmdUpdate()` | Add `--clear-url` flag with mutual-exclusion check against `--url` | Small |
| `reminderkit.m` -- `cmdBatch()` | Add `clear-url` to `validKeys`, mutual-exclusion check, and clear logic | Small |
| `reminderkit.m` -- `reminderToDict()` | Add `linkedNoteId` parsing from `applenotes://` URLs using `NSURLComponents` | Small |
| `reminderkit.m` -- new `cmdLinkNote()` | Convenience command delegating to `cmdUpdate` | Small |
| `reminderkit.m` -- `usage()` | Add `link-note` command and `--clear-url` flag | Small |
| `reminderkit.m` -- `main()` | Add command dispatch for `link-note` | Small |
| `reminderkit.m` -- `cmdTest()` | Add note linking tests (happy path, negative, conflict, edge cases) | Medium |
| Skill file | Document note linking workflow | Small |

## Estimated Effort

Small-to-medium change. The core insight is that the existing `--url` field already works for `applenotes://` URLs -- no framework changes needed. Option 1 is zero code. Option 2 adds approximately 50-70 lines of new code for `cmdLinkNote`, `linkedNoteId` parsing, `--clear-url` with mutual-exclusion, and batch support, plus approximately 100-120 lines of tests.

## Key Architectural Decision

**URL field, not deeper integration.** ReminderKit has no native note-linking concept. The URL attachment field is the same mechanism Apple's own Reminders app uses when linking to notes, web pages, or other content. This approach is:

- Consistent with how Apple's first-party apps work
- Simple to implement (URL is just a string)
- Forward-compatible (if Apple adds native note linking, the URL format will likely remain the same)
- Already functional today with zero code changes (just use `--url`)
