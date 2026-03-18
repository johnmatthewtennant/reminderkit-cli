# Plan: Fix title matching with curly/smart apostrophes

## Session

cursor://file/Users/jtennant/.claude/projects/-Users-jtennant-Development/f9262730-1dfc-4b43-a9a1-6ecea86fa404/subagents/agent-a7d84a3ebb960908e.jsonl

## Problem

`reminderkit get --title "What's up"` fails when the reminder's actual title in Apple Reminders contains a curly/smart apostrophe (U+2019) instead of a straight apostrophe (U+0027). This is because Apple Reminders automatically converts straight apostrophes to curly ones when users type in the Reminders app.

The comparison in `findReminder()` uses `[t isEqualToString:title]` which is byte-level -- curly and straight apostrophes don't match.

The same issue affects `findList()` for list name matching.

## Root Cause

In `reminderkit.m`:
- **Line 146** (`findReminder`): `if ([t isEqualToString:title]) return rem;`
- **Line 112** (`findList`): `if ([listName isEqualToString:name]) return list;`

Both use exact string comparison. When the CLI user types a straight apostrophe but the stored title has a curly one (or vice versa), the match fails.

## Proposed Fix

### 1. Add a normalization helper function (in `reminderkit.m`)

Add a `normalizeQuotes()` function near the top of the file (after the existing helpers around line 60):

```objc
static NSString *normalizeQuotes(NSString *str) {
    if (!str) return nil;
    // Normalize curly single quotes / apostrophes to straight
    NSString *result = [str stringByReplacingOccurrencesOfString:@"\u2018" withString:@"'"];  // left single quote
    result = [result stringByReplacingOccurrencesOfString:@"\u2019" withString:@"'"];          // right single quote (apostrophe)
    return result;
}
```

Scope is limited to single-quote normalization only. Double-quote normalization is excluded unless explicitly needed and tested.

### 2. Update `findReminder()` -- two-pass matching (line ~133-150)

Use exact match first, then normalized fallback. This prevents selecting the wrong record if both curly and straight variants exist as separate reminders.

Change the function to:

```objc
static id findReminder(id store, NSString *title, NSString *listName) {
    NSArray *lists;
    if (listName) {
        id list = findList(store, listName);
        if (!list) errorExit([NSString stringWithFormat:@"List not found: %@", listName]);
        lists = @[list];
    } else {
        lists = fetchLists(store);
    }
    // Pass 1: exact match
    for (id list in lists) {
        NSArray *rems = fetchReminders(store, list, YES);
        for (id rem in rems) {
            NSString *t = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("titleAsString"));
            if ([t isEqualToString:title]) return rem;
        }
    }
    // Pass 2: normalized fallback (curly apostrophes -> straight)
    NSString *normalizedTitle = normalizeQuotes(title);
    for (id list in lists) {
        NSArray *rems = fetchReminders(store, list, YES);
        for (id rem in rems) {
            NSString *t = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("titleAsString"));
            if ([normalizeQuotes(t) isEqualToString:normalizedTitle]) return rem;
        }
    }
    return nil;
}
```

Note: the query title is normalized once outside the loop for efficiency.

### 3. Update `findList()` -- two-pass matching (line ~107-115)

Same two-pass strategy:

```objc
static id findList(id store, NSString *name) {
    NSArray *lists = fetchLists(store);
    // Pass 1: exact match
    for (id list in lists) {
        id storage = ((id (*)(id, SEL))objc_msgSend)(list, sel_registerName("storage"));
        NSString *listName = ((id (*)(id, SEL))objc_msgSend)(storage, sel_registerName("name"));
        if ([listName isEqualToString:name]) return list;
    }
    // Pass 2: normalized fallback
    NSString *normalizedName = normalizeQuotes(name);
    for (id list in lists) {
        id storage = ((id (*)(id, SEL))objc_msgSend)(list, sel_registerName("storage"));
        NSString *listName = ((id (*)(id, SEL))objc_msgSend)(storage, sel_registerName("name"));
        if ([normalizeQuotes(listName) isEqualToString:normalizedName]) return list;
    }
    return nil;
}
```

### 4. Update `generate-cli.py` (keep in sync)

Apply the same changes to the generator script:
- Add `normalizeQuotes` helper in the generated code template
- Update `findReminder` and `findList` to use two-pass matching

### 5. Add tests (required)

Add test cases in the `cmdTest` function:

**Test A: findReminder normalized fallback**
- Create a reminder with a curly apostrophe in its title (use `@"\u2019"` in Objective-C string literal)
- Verify `findReminder()` finds it using a straight apostrophe query
- Clean up

**Test B: findList normalized fallback**
- Create a list with a curly apostrophe in its name
- Verify `findList()` finds it using a straight apostrophe query
- Clean up

**Test C: exact match takes priority over normalized -- reminder collision case**
- Create two reminders: one with straight apostrophe, one with curly apostrophe in the title
- Query with straight apostrophe -- verify it finds the straight-apostrophe one (exact match wins)
- Query with curly apostrophe -- verify it finds the curly-apostrophe one (exact match wins)
- Clean up

**Test D: exact match takes priority over normalized -- list collision case**
- Create two lists: one with straight apostrophe (e.g. `Bob's List`), one with curly apostrophe (`Bob\u2019s List`)
- Verify `findList()` with straight apostrophe query returns the straight-apostrophe list
- Verify `findList()` with curly apostrophe query returns the curly-apostrophe list
- Clean up both lists

## Files to Change

1. `/Users/jtennant/Development/reminderkit-cli/reminderkit.m` -- primary source (manually maintained)
2. `/Users/jtennant/Development/reminderkit-cli/generate-cli.py` -- generator (keep in sync)

## Build and Test

```bash
cd ~/Development/reminderkit-cli
make clean && make
./reminderkit test
```

Then manually verify:
```bash
# Create a reminder with a curly apostrophe (use $'...' for zsh Unicode)
./reminderkit add --title $'Test\u2019s apostrophe' --list "Reminders CLI"
# Try to fetch it with a straight apostrophe
./reminderkit get --title "Test's apostrophe" --list "Reminders CLI"
# Clean up (delete the test reminder by ID from the get output)
```

Also validate generator sync:
```bash
make remkit-inspect generate
git diff reminderkit.m  # should show no unexpected drift
```

## Risk Assessment

Low risk. The two-pass strategy ensures:
1. Existing exact matches continue to work identically (pass 1)
2. Only when no exact match is found does normalized matching kick in (pass 2)
3. Stored titles are never modified -- normalization is comparison-only
4. If both curly and straight variants exist as separate items, exact match wins
