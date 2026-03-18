# Plan: Add `--parent-id` support to the `add` command

## Goal

Allow `reminderkit add --title "Subtask" --parent-id <id>` to create a subtask in one step, instead of requiring a create-then-update workflow.

## Background

The `--parent-id` flag is already implemented on the `update` command (lines 622-717 of `reminderkit.m`). The `add` command (lines 361-421) already accepts optional flags like `--notes`, `--priority`, `--flagged`, `--due-date`, `--start-date`, and `--url`, but not `--parent-id`.

The arg parser (line 1310+) is generic — it puts all `--key value` pairs into an `opts` dictionary that gets passed to command handlers. So `--parent-id` will automatically be parsed into `opts[@"parent-id"]` without any parser changes.

## File to modify

`/Users/jtennant/Development/reminderkit-cli/reminderkit.m`

## Changes

### 1. Extract a shared reparenting helper function

To avoid duplicating reparenting logic between `cmdAdd`, `cmdUpdate`, and batch `add`, extract a helper function. Place it before `cmdAdd` (around line 360):

```objc
// Shared helper: reparent a reminder change item under a parent.
static void reparentChangeItem(id store, id saveReq, id listCI, id childCI, NSString *parentID) {
    id parentRem = findReminderByID(store, parentID);
    if (!parentRem) errorExit([NSString stringWithFormat:@"Parent not found with id: %@", parentID]);

    id parentCI = ((id (*)(id, SEL, id))objc_msgSend)(
        saveReq, sel_registerName("updateReminder:"), parentRem);

    ((void (*)(id, SEL, id, id))objc_msgSend)(
        listCI, sel_registerName("_reassignReminderChangeItem:withParentReminderChangeItem:"),
        childCI, parentCI);
}
```

Also extract a helper to find a list object by its objectID (used in both `cmdAdd` and `cmdUpdate` for reparenting):

```objc
// Find list by objectID string. Returns nil if not found.
static id findListByObjectID(id store, id targetObjID) {
    NSArray *allLists = fetchLists(store);
    for (id l in allLists) {
        id lID = ((id (*)(id, SEL))objc_msgSend)(l, sel_registerName("objectID"));
        if ([objectIDToString(lID) isEqualToString:objectIDToString(targetObjID)]) {
            return l;
        }
    }
    return nil;
}
```

### 2. Add list-derivation logic and `--parent-id` handling to `cmdAdd` (lines 361-421)

The key issue is that when `--parent-id` is provided, the new reminder must be created in the same list as the parent. The current code picks the list at line 362 before knowing about `--parent-id`.

**Modify the list resolution at the top of `cmdAdd`** to handle `--parent-id`:

Replace lines 362-371 with logic that:
1. If `--parent-id` is present and `--list` is absent: look up the parent reminder, derive its list, and use that.
2. If `--parent-id` is present and `--list` is also present: look up the parent, check its list matches the specified list. If they differ, `errorExit(@"--parent-id and --list conflict: parent is in a different list")`.
3. If `--parent-id` is absent: use existing behavior (listName or first list).

```objc
static int cmdAdd(id store, NSString *title, NSString *listName, NSDictionary *opts) {
    id list = nil;
    NSString *parentID = opts[@"parent-id"];

    if (parentID) {
        // Look up parent to derive/validate list
        id parentRem = findReminderByID(store, parentID);
        if (!parentRem) errorExit([NSString stringWithFormat:@"Parent not found with id: %@", parentID]);

        id parentListID = ((id (*)(id, SEL))objc_msgSend)(parentRem, sel_registerName("listID"));
        list = findListByObjectID(store, parentListID);
        if (!list) errorExit(@"Could not find parent's list");

        // If --list was also specified, validate it matches
        if (listName) {
            id specifiedList = findList(store, listName);
            if (!specifiedList) errorExit([NSString stringWithFormat:@"List not found: %@", listName]);
            id specListID = ((id (*)(id, SEL))objc_msgSend)(specifiedList, sel_registerName("objectID"));
            if (![objectIDToString(specListID) isEqualToString:objectIDToString(parentListID)]) {
                errorExit(@"--parent-id and --list conflict: parent is in a different list. Omit --list to auto-derive from parent.");
            }
        }
    } else {
        list = listName ? findList(store, listName) : [fetchLists(store) firstObject];
    }
    if (!list) errorExit(@"No list found");

    // ... rest of cmdAdd unchanged (saveReq, listCI, newRem creation, optional properties) ...
```

Then, after the `url` handling (after line 408) and before the save call (line 411), add the reparenting call using the shared helper:

```objc
    // Reparent: --parent-id
    if (opts[@"parent-id"]) {
        reparentChangeItem(store, saveReq, listCI, newRem, opts[@"parent-id"]);
    }
```

### 3. Update `cmdUpdate` to use the shared helpers (required)

Replace the reparenting body in lines 683-717 of `cmdUpdate` with calls to the shared helpers. The self-parenting check (lines 688-693) remains inline since it is specific to update:

```objc
    // Reparent: --parent-id
    if (parentID) {
        // Validate no self-parenting (update-specific)
        id remObjID = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("objectID"));
        id parentRem = findReminderByID(store, parentID);
        if (!parentRem) errorExit([NSString stringWithFormat:@"Parent not found with id: %@", parentID]);
        id parentObjID = ((id (*)(id, SEL))objc_msgSend)(parentRem, sel_registerName("objectID"));
        if ([objectIDToString(remObjID) isEqualToString:objectIDToString(parentObjID)]) {
            errorExit(@"Cannot set a reminder as its own parent");
        }

        // Get the list for reparenting using shared helper
        id remListID = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("listID"));
        id targetList = findListByObjectID(store, remListID);
        if (!targetList) errorExit(@"Could not find list for reparenting");

        id listCI = ((id (*)(id, SEL, id))objc_msgSend)(
            saveReq, sel_registerName("updateList:"), targetList);

        reparentChangeItem(store, saveReq, listCI, changeItem, parentID);
    }
```

Note: `findReminderByID` is called twice (once for self-parenting validation, once inside `reparentChangeItem`). This is acceptable since it is a simple lookup, and keeping the helper's interface clean is more important than avoiding the redundant call.

### 4. Add `--parent-id` support to batch `add` ops (required, around line 860)

The batch command's `add` handler (lines 860-879) must support `--parent-id` with the same semantics as `cmdAdd`. The critical change is that list resolution must happen **before** `addReminderWithTitle:toListChangeItem:`, not after. This mirrors how `cmdAdd` resolves the list before creating the reminder.

Replace the existing batch `add` block (lines 860-879) with:

```objc
        if ([opType isEqualToString:@"add"]) {
            id list = nil;
            NSString *batchParentID = op[@"parent-id"];

            if (batchParentID) {
                // Derive/validate list from parent, same as cmdAdd
                id batchParentRem = findReminderByID(store, batchParentID);
                if (!batchParentRem) errorExit([NSString stringWithFormat:@"Parent not found with id: %@", batchParentID]);
                id batchParentListID = ((id (*)(id, SEL))objc_msgSend)(batchParentRem, sel_registerName("listID"));
                list = findListByObjectID(store, batchParentListID);
                if (!list) errorExit(@"Batch add: could not find parent's list");

                if (opList) {
                    // If list was explicitly specified, validate it matches parent's list
                    id specifiedList = findList(store, opList);
                    if (!specifiedList) errorExit([NSString stringWithFormat:@"List not found: %@", opList]);
                    id specListID = ((id (*)(id, SEL))objc_msgSend)(specifiedList, sel_registerName("objectID"));
                    if (![objectIDToString(specListID) isEqualToString:objectIDToString(batchParentListID)]) {
                        errorExit(@"Batch add: parent is in a different list than the specified list");
                    }
                }
            } else {
                list = opList ? findList(store, opList) : [fetchLists(store) firstObject];
            }
            if (!list) errorExit(@"No list found for add operation");

            id listCI = ((id (*)(id, SEL, id))objc_msgSend)(
                saveReq, sel_registerName("updateList:"), list);
            id newRem = ((id (*)(id, SEL, id, id))objc_msgSend)(
                saveReq, sel_registerName("addReminderWithTitle:toListChangeItem:"),
                opTitle, listCI);
            if (!newRem) errorExit([NSString stringWithFormat:@"Failed to create: %@", opTitle]);

            // Apply optional properties on the new reminder change item
            if (op[@"notes"]) ((void (*)(id, SEL, id))objc_msgSend)(newRem, sel_registerName("setNotesAsString:"), op[@"notes"]);
            if (op[@"priority"]) ((void (*)(id, SEL, NSUInteger))objc_msgSend)(newRem, sel_registerName("setPriority:"), [op[@"priority"] integerValue]);
            if (op[@"flagged"]) ((void (*)(id, SEL, NSInteger))objc_msgSend)(newRem, sel_registerName("setFlagged:"), [op[@"flagged"] integerValue]);
            if (op[@"due-date"]) ((void (*)(id, SEL, id))objc_msgSend)(newRem, sel_registerName("setDueDateComponents:"), stringToDateComps(op[@"due-date"]));
            if (op[@"start-date"]) ((void (*)(id, SEL, id))objc_msgSend)(newRem, sel_registerName("setStartDateComponents:"), stringToDateComps(op[@"start-date"]));
            if (op[@"url"]) { NSURL *u = [NSURL URLWithString:op[@"url"]]; if (u) { id attCtx = ((id (*)(id, SEL))objc_msgSend)(newRem, sel_registerName("attachmentContext")); ((void (*)(id, SEL, id))objc_msgSend)(attCtx, sel_registerName("setURLAttachmentWithURL:"), u); } }

            // Reparent if parent-id specified
            if (batchParentID) {
                reparentChangeItem(store, saveReq, listCI, newRem, batchParentID);
            }

            [results addObject:@{@"op": @"add", @"title": opTitle, @"status": @"ok"}];
```

Key difference from the previous revision: the list is resolved **before** `addReminderWithTitle:toListChangeItem:`, so the child is created in the correct list from the start. This avoids relying on cross-list reparenting side effects.

### 5. Update the usage string (line 1279)

Change:
```
  reminderkit add --title <title> [--list <name>] [--notes <value>] [--completed <value>] [--priority <value>] [--flagged <value>] [--due-date <value>] [--start-date <value>] [--url <value>]
```
To:
```
  reminderkit add --title <title> [--list <name>] [--notes <value>] [--completed <value>] [--priority <value>] [--flagged <value>] [--due-date <value>] [--start-date <value>] [--url <value>] [--parent-id <id>]
```

## Testing

After building (`make`), run the following tests.

### Happy path test

```bash
# Create a parent reminder and capture its ID from JSON output
PARENT_JSON=$(reminderkit add --title "Test Parent $(date +%s)" --list "Reminders")
PARENT_ID=$(echo "$PARENT_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

# Create a child in one step (no --list, should auto-derive from parent)
CHILD_JSON=$(reminderkit add --title "Test Child $(date +%s)" --parent-id "$PARENT_ID")
CHILD_ID=$(echo "$CHILD_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

# Verify it shows as a subtask
PARENT_TITLE=$(echo "$PARENT_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['title'])")
SUBTASKS=$(reminderkit subtasks --title "$PARENT_TITLE" --list "Reminders")
echo "$SUBTASKS" | python3 -c "import sys,json; tasks=json.load(sys.stdin); assert len(tasks)==1, f'Expected 1 subtask, got {len(tasks)}'; print('Subtask verified')"

# Clean up
reminderkit delete --id "$CHILD_ID"
reminderkit delete --id "$PARENT_ID"
```

### Negative/edge-case tests

```bash
# 1. Invalid parent ID should error
OUTPUT=$(reminderkit add --title "Orphan $(date +%s)" --parent-id "nonexistent-id-12345" 2>&1) || true
echo "$OUTPUT" | grep -q "Parent not found" && echo "PASS: invalid parent ID" || echo "FAIL: expected parent-not-found error"

# 2. --parent-id with conflicting --list should error
# First create a temporary test list
reminderkit create-list --name "TestConflictList_$(date +%s)"
TEST_LIST_NAME=$(reminderkit lists | python3 -c "import sys,json; lists=json.load(sys.stdin); print([l['name'] for l in lists if 'TestConflictList_' in l['name']][0])")
PARENT_JSON=$(reminderkit add --title "Test Parent Conflict $(date +%s)" --list "Reminders")
PARENT_ID=$(echo "$PARENT_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
OUTPUT=$(reminderkit add --title "Cross-list child $(date +%s)" --list "$TEST_LIST_NAME" --parent-id "$PARENT_ID" 2>&1) || true
echo "$OUTPUT" | grep -q "conflict" && echo "PASS: list conflict detected" || echo "FAIL: expected conflict error"
# Clean up
reminderkit delete --id "$PARENT_ID"
reminderkit delete-list --name "$TEST_LIST_NAME"

# 3. --parent-id with matching --list should succeed
PARENT_JSON=$(reminderkit add --title "Test Parent Match $(date +%s)" --list "Reminders")
PARENT_ID=$(echo "$PARENT_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
CHILD_JSON=$(reminderkit add --title "Same-list child $(date +%s)" --list "Reminders" --parent-id "$PARENT_ID")
CHILD_ID=$(echo "$CHILD_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
echo "PASS: matching list with parent-id succeeded"
reminderkit delete --id "$CHILD_ID"
reminderkit delete --id "$PARENT_ID"
```

### Batch test

```bash
# Create parent
PARENT_JSON=$(reminderkit add --title "Batch Parent $(date +%s)" --list "Reminders")
PARENT_ID=$(echo "$PARENT_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
PARENT_TITLE=$(echo "$PARENT_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['title'])")

# Batch-add a child with parent-id
BATCH_CHILD_TITLE="Batch Child $(date +%s)"
BATCH_RESULT=$(echo "[{\"op\":\"add\",\"title\":\"$BATCH_CHILD_TITLE\",\"list\":\"Reminders\",\"parent-id\":\"$PARENT_ID\"}]" | reminderkit batch)
echo "$BATCH_RESULT" | python3 -c "import sys,json; r=json.load(sys.stdin); assert r[0]['status']=='ok', f'Batch failed: {r}'; print('Batch add succeeded')"

# Verify subtask relationship
SUBTASKS=$(reminderkit subtasks --title "$PARENT_TITLE" --list "Reminders")
SUBTASK_COUNT=$(echo "$SUBTASKS" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
[ "$SUBTASK_COUNT" = "1" ] && echo "PASS: batch subtask verified" || echo "FAIL: expected 1 subtask, got $SUBTASK_COUNT"

# Get child ID for cleanup
CHILD_ID=$(echo "$SUBTASKS" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")
reminderkit delete --id "$CHILD_ID"
reminderkit delete --id "$PARENT_ID"
```

### Batch test: list derivation from parent (no `list` field)

```bash
# Create a temporary non-default list
TS=$(date +%s)
TEST_LIST="TestBatchDerive_$TS"
reminderkit create-list --name "$TEST_LIST"

# Create parent in the non-default list
PARENT_JSON=$(reminderkit add --title "Derive Parent $TS" --list "$TEST_LIST")
PARENT_ID=$(echo "$PARENT_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
PARENT_TITLE=$(echo "$PARENT_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['title'])")

# Batch-add a child with parent-id but NO list field — should derive from parent
BATCH_RESULT=$(echo "[{\"op\":\"add\",\"title\":\"Derive Child $TS\",\"parent-id\":\"$PARENT_ID\"}]" | reminderkit batch)
echo "$BATCH_RESULT" | python3 -c "import sys,json; r=json.load(sys.stdin); assert r[0]['status']=='ok', f'Batch failed: {r}'; print('Batch add (no list) succeeded')"

# Verify subtask relationship in the non-default list
SUBTASKS=$(reminderkit subtasks --title "$PARENT_TITLE" --list "$TEST_LIST")
SUBTASK_COUNT=$(echo "$SUBTASKS" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
[ "$SUBTASK_COUNT" = "1" ] && echo "PASS: batch list-derivation verified" || echo "FAIL: expected 1 subtask in $TEST_LIST, got $SUBTASK_COUNT"

# Clean up
CHILD_ID=$(echo "$SUBTASKS" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")
reminderkit delete --id "$CHILD_ID"
reminderkit delete --id "$PARENT_ID"
reminderkit delete-list --name "$TEST_LIST"
```

### Existing tests

```bash
reminderkit test
```

Ensure all existing tests still pass.
