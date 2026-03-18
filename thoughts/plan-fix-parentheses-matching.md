# Plan: Full generator-runtime parity (fixes parentheses matching and prevents regression)

## Session

(Session file not found in this environment)

## Problem

Reminder titles containing parentheses cannot be reliably matched by the CLI. The bug report example: a reminder titled "Add installation instructions to readme (single command...)" fails to match when passed as a CLI argument.

The root cause is that `generate-cli.py` is significantly out of sync with the manually-evolved `reminderkit.m`. Running `make generate` would regress the CLI to a broken state that lacks id-based mutations, `link-note`, `--clear-url`, `--parent-id` on add, positional arg rejection, and correct batch validation.

## Root Cause Analysis

The compiled `reminderkit.m` has been manually updated with multiple features and safety improvements that `generate-cli.py` does not produce. The specific parentheses bug occurred because positional args were still accepted -- zsh interprets unquoted parentheses as glob patterns, causing "bad pattern" errors or incorrect argument splitting.

## Scope: Full generator-to-runtime parity

The following runtime features exist in `reminderkit.m` but are missing from or stale in `generate-cli.py`:

### A. Positional arg rejection (commit `8643a59`)
- Generator still accepts positional args for title, name, tag, section
- Runtime rejects all positional args with an error message

### B. Id-based mutation commands
Generator function signatures vs runtime:

| Command | Generator (stale) | Runtime (current) |
|---------|------------------|-------------------|
| `cmdUpdate` | `(store, title, listName, opts)` | `(store, listName, opts)` -- id in opts |
| `cmdComplete` | `(store, title, listName, remID)` | `(store, listName, remID)` -- id-only |
| `cmdDelete` | `(store, title, listName, remID)` | `(store, listName, remID)` -- id-only |
| `cmdAddTag` | `(store, title, tagName, listName)` | `(store, remID, tagName)` -- id-only |
| `cmdRemoveTag` | `(store, title, tagName, listName)` | `(store, remID, tagName)` -- id-only |

### C. New commands and flags not in generator
- `cmdLinkNote(store, remId, noteId)` -- links a reminder to an Apple Note via URL
- `--clear-url` boolean flag on `update` -- clears URL and linked note
- `--url` / `--clear-url` conflict detection
- `--parent-id` on `cmdAdd` -- creates a subtask in one step
- `--parent-id` on `cmdUpdate` with reparenting logic
- `--to-list` on `cmdUpdate` -- moves reminder to different list
- `--append-notes` on `cmdUpdate`

### D. Boolean flags list
Generator has: `--include-completed`, `--remove-parent`, `--remove-from-list`, `--help`
Runtime adds: `--clear-url`, `--claude`, `--agents`, `--force`

### E. Stale `parent-title` support
Generator still has `--parent-title` paths in:
- `cmdUpdate` (line 646)
- Generated tests (line 1017)
- Usage text (line 1230)
- Batch valid keys (line 843)

Runtime has removed `parent-title` entirely -- only `parent-id` is supported.

### F. Batch command (`cmdBatch`) drift
Generator batch logic:
- Allows title-based mutations for non-add ops
- Includes `parent-title` in valid keys
- Has stale valid key set

Runtime batch logic:
- Requires `id` for all non-add operations (complete, update, delete)
- Has updated valid key set: `@[@"op", @"title", @"id", @"list", @"notes", @"append-notes", @"completed", @"priority", @"flagged", @"due-date", @"start-date", @"url", @"clear-url", @"remove-parent", @"remove-from-list", @"parent-id", @"to-list"]`
- No `parent-title` support
- Batch add supports `parent-id` with list derivation from parent

### G. Tests
Generator tests still use title-based mutations. Runtime tests use id-based patterns and include tests for `link-note`, `--clear-url`, `--parent-id`, `--url`/`--clear-url` conflict, and error paths.

## Proposed Fix

### Step 1: Update mutation command generation to id-based (required)

Update `generate-cli.py` to generate id-based mutation commands matching `reminderkit.m`:

1. **`cmdUpdate`**: Remove `title` parameter. Change signature to `(store, listName, opts)`. The id comes from `opts[@"id"]`. Remove `findReminder` fallback. Remove `parent-title` handling -- only `parent-id` supported.

2. **`cmdComplete`**: Remove `title` parameter. Change signature to `(store, listName, remID)`. Use `findReminderByID` only.

3. **`cmdDelete`**: Remove `title` parameter. Change signature to `(store, listName, remID)`. Use `findReminderByID` only.

4. **`cmdAddTag`**: Change signature from `(store, title, tagName, listName)` to `(store, remID, tagName)`. Use `findReminderByID` only.

5. **`cmdRemoveTag`**: Same change as `cmdAddTag`.

### Step 2: Add `cmdLinkNote` to generator (required)

Add the `cmdLinkNote` function that:
1. Takes `(store, remId, noteId)`
2. Constructs an `applenotes://showNote?identifier=<noteId>` URL using `NSURLComponents`
3. Delegates to `cmdUpdate` with the constructed URL

Reference: `reminderkit.m` lines 817-830.

### Step 3: Add `--clear-url` and conflict handling to `cmdUpdate` (required)

In the generated `cmdUpdate`:
1. Add conflict check: if both `opts[@"url"]` and `opts[@"clear-url"]` are set, call `errorExit`
2. Add `--clear-url` handling: set URL attachment to nil via `attachmentContext`

Reference: `reminderkit.m` lines 710-711, 769-773.

### Step 4: Add `--parent-id` to `cmdAdd` (required)

Update the generated `cmdAdd` to support `--parent-id`:
1. If `opts[@"parent-id"]` is set, find the parent reminder by ID
2. Derive the list from the parent's list (if `--list` not specified)
3. After creating the reminder, call the reparent helper

Reference: `reminderkit.m` lines 415-500.

### Step 5: Add reparent helper and `--to-list` to `cmdUpdate` (required)

1. Add `reparentChangeItem` helper function
2. Add `--parent-id` handling in `cmdUpdate`
3. Add `--to-list` handling in `cmdUpdate`

Reference: `reminderkit.m` lines 676-813.

### Step 6: Sync `cmdBatch` with runtime (required)

Update the generator's batch command to match `reminderkit.m` lines 867-1060:

1. **Update valid key set**: Match the runtime set: `op, title, id, list, notes, append-notes, completed, priority, flagged, due-date, start-date, url, clear-url, remove-parent, remove-from-list, parent-id, to-list`

2. **Remove `parent-title`** from valid keys -- only `parent-id` is supported

3. **Require `id` for non-add operations**: For `complete`, `update`, `delete` batch ops, require `op[@"id"]` and use `findReminderByID`. Remove title-based fallback for mutations.

4. **Add `parent-id` support for batch add**: If `op[@"parent-id"]` is set, find parent by ID, derive list from parent, reparent after creation.

5. **Add `clear-url` handling for batch update**: If `op[@"clear-url"]` is set, clear URL attachment. Add `url`/`clear-url` conflict check.

6. **Add `to-list` handling for batch update**: If present, use the same logic as `cmdUpdate`.

### Step 7: Remove all `parent-title` paths (required)

Explicitly remove `parent-title` support from the generator everywhere:
- `cmdUpdate` generated code (line 646)
- Conflict check between `parent-id` and `parent-title` (line 649-652)
- Batch valid keys (line 843)
- Generated test code (line 1017)
- Usage text (line 1230)

Only `parent-id` should remain.

### Step 8: Add positional arg rejection to generator (required)

After the argument parsing loop in the generated `main()`, add the rejection block that errors on any positional args (except for batch/lists/install-skill/test/help commands).

### Step 9: Update boolean flags list (required)

Add `--clear-url`, `--claude`, `--agents`, `--force` to the boolean flags list in the generator.

### Step 10: Update command dispatch in generator (required)

Update all command dispatch entries to match runtime:
- `get`, `subtasks`, `add`: require `kwTitle`, no positional fallback
- `update`: require `opts[@"id"]`
- `link-note`: require `opts[@"id"]` + `opts[@"note-id"]`
- `complete`, `delete`: require `opts[@"id"]`
- `add-tag`, `remove-tag`: require `opts[@"id"]` + `kwTag`
- `list`, `list-sections`, `create-list`, `delete-list`: require `kwName`
- `create-section`: require `kwName` + `kwSection`
- `rename-list`: require `kwOldName` + `kwNewName`

### Step 11: Update usage() in generator (required)

Update the generated usage/help text to match `reminderkit.m` lines 1700-1720:
- All commands use `--flag` syntax only
- Include `link-note --id --note-id`
- Include `--parent-id`, `--to-list`, `--clear-url` on update
- Include `--parent-id` on add
- Include `install-skill` with `--claude`, `--agents`, `--force`

### Step 12: Sync generator tests (required)

Update the test generation code to match `reminderkit.m` test patterns:
- Use id-based mutations (find by title, extract ID, mutate by ID)
- Add test for `link-note` command
- Add test for `--clear-url`
- Add test for `--url`/`--clear-url` conflict (subprocess)
- Add test for `--parent-id` on add
- Add test for `link-note` missing `--note-id` (subprocess error path)
- Remove any tests that use `parent-title`

Reference: `reminderkit.m` lines 1030-1570.

### Step 13: Add special character test case (recommended)

Add a test that:
1. Creates a reminder with parentheses in the title: `@"__remcli_test_parens (hello)__"`
2. Verifies `findReminder()` returns it
3. Cleans up using the ID

### Step 14: Update documentation (required)

Update `README.md`:
- All examples use `--flag` syntax only (no positional args)
- `--id` required for mutations
- Document `link-note` command
- Document `--clear-url`, `--parent-id`, `--to-list` options
- Remove any examples using positional title args or `parent-title`

### Step 15: Verify full parity (required)

```bash
cd ~/Development/reminderkit-cli

# Save current binary
cp reminderkit reminderkit.bak

# Regenerate from updated generator
make generate

# Run full test suite
./reminderkit test

# Behavioral assertions — top-level commands:
# 1. Positional args rejected
./reminderkit get "some title" 2>&1 | grep "unexpected argument"

# 2. Mutation commands require --id
./reminderkit complete --title "test" 2>&1 | grep "Error"
./reminderkit delete --title "test" 2>&1 | grep "Error"
./reminderkit update --title "test" 2>&1 | grep "Error"

# 3. Tag commands require --id + --tag
./reminderkit add-tag --tag "foo" 2>&1 | grep "Error"
./reminderkit add-tag --id "foo" 2>&1 | grep "Error"

# 4. link-note requires --id + --note-id
./reminderkit link-note --id "foo" 2>&1 | grep "Error"
./reminderkit link-note --note-id "foo" 2>&1 | grep "Error"

# 5. --url + --clear-url conflict
./reminderkit update --id "foo" --url "https://x.com" --clear-url 2>&1 | grep -i "cannot"

# 6. Parentheses in titles work
./reminderkit add --title "Test (parens)" --list "Reminders CLI"
./reminderkit get --title "Test (parens)" --list "Reminders CLI"
# Clean up via ID

# Behavioral assertions — batch:
# 7. Batch non-add ops reject missing id
echo '[{"op":"complete","title":"test"}]' | ./reminderkit batch 2>&1 | grep -i "error\|id"

# 8. Batch rejects parent-title as unknown key
echo '[{"op":"add","title":"test","parent-title":"foo"}]' | ./reminderkit batch 2>&1 | grep -i "unknown\|invalid"

# 9. Batch add with parent-id (functional test -- requires real reminders)

# If all pass, remove backup
rm reminderkit.bak
```

## Files to Change

1. `/Users/jtennant/Development/reminderkit-cli/generate-cli.py` -- full sync with current `.m` behavior
2. `/Users/jtennant/Development/reminderkit-cli/reminderkit.m` -- regenerated from updated generator (via `make generate`)
3. `/Users/jtennant/Development/reminderkit-cli/README.md` -- update docs to reflect all current features

## Risk Assessment

**Medium risk.** The generator changes touch command signatures, dispatch logic, batch validation, tests, and help text. The primary risk is introducing regressions during the large sync. Mitigations:
- The current `reminderkit.m` serves as the reference implementation for every change
- Keep a backup of the current working binary
- Run the full test suite after regeneration
- Verify behavioral assertions manually (both top-level and batch)
- Changes are additive (bringing generator up to parity), not architectural

## Out of Scope

- Adding prefix/fuzzy matching (separate feature request)
- Adding curly apostrophe normalization (separate plan at `thoughts/plan-fix-curly-apostrophe-matching.md`)
