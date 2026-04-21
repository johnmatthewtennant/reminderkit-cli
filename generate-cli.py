#!/usr/bin/env python3
"""
Generate reminderkit-generated.m from ReminderKit private API.

USAGE:
    python3 generate-cli.py > reminderkit-generated.m
    # Then: make reminderkit

MAINTENANCE:
    This generator produces reminderkit-generated.m — the config-driven
    Objective-C code for the reminders CLI. Handwritten commands live in
    reminderkit-handwritten.m, tests in reminderkit-tests.m, and the
    assembly file reminderkit.m #includes all three.

    To add a new READ property:
        1. Add an entry to REMINDER_READ_PROPS below
        2. Format: "objcPropertyName": ("jsonKey", "type_hint")
        3. Type hints: "string", "bool", "bool_getter", "int", "uint",
                       "date", "datecomps", "objid", "set_hashtags"
        4. Regenerate: make generate

    To add a new WRITE operation (setter):
        1. Add an entry to REMINDER_WRITE_OPS below
        2. Format: "cli-flag": ("setterSelector:", "arg_type")
        3. Arg types: "string", "bool", "int", "uint", "datecomps"
        4. For no-arg methods (like removeFromParentReminder), add to SPECIAL_WRITE_OPS
        5. Regenerate

    To discover new properties/methods:
        make remkit-inspect && ./remkit-inspect 2>&1 | less

    Architecture:
        remkit-inspect.m           ->  dumps ObjC runtime properties/methods (discovery tool)
        generate-cli.py            ->  generates reminderkit-generated.m from config dicts (this file)
        reminderkit-generated.m    ->  AUTO-GENERATED, do not edit manually
        reminderkit-handwritten.m  ->  manually maintained commands
        reminderkit-tests.m        ->  test infrastructure
        reminderkit.m              ->  assembly file (#includes the above three + usage/main)
        Makefile                   ->  builds everything, `make generate` regenerates
"""


# --- Configuration ---

# Properties to expose on REMReminder (read)
# Maps property name -> (json_key, type_hint)
# type_hint: "string", "bool", "int", "uint", "date", "objid", "set_hashtags", "datecomps"
# Note: "url" is read via attachmentContext, not icsUrl
#
# Omit-when-default: fields whose default (zero/false/empty) value is suppressed
# from the output dict unless --full is passed. This is the "smart defaults"
# contract consumed by scripts; see CONTRACT.md.
#
# The "objid" type is split into two emitted fields: "<jsonKey>" (bare UUID)
# and "<jsonKey>Uri"/"uri" (x-apple-reminderkit:// URL). For the main object
# the keys are literally "id" + "uri"; for referenced objects (listID, parent)
# we use "<camelCase>Id" + "<camelCase>Uri" to avoid key collisions.
REMINDER_READ_PROPS = {
    "titleAsString":      ("title",          "string"),
    "notesAsString":      ("notes",          "string"),
    "completed":          ("completed",      "bool_getter"),  # getter is isCompleted
    "priority":           ("priority",       "uint"),
    "flagged":            ("flagged",        "int"),
    "allDay":             ("allDay",         "bool"),
    "isOverdue":          ("isOverdue",      "bool"),
    "isRecurrent":        ("isRecurrent",    "bool"),
    "objectID":           ("id",             "objid_self"),
    "listID":             ("listId",         "objid_ref"),
    "parentReminderID":   ("parentId",       "objid_ref"),
    "dueDateComponents":  ("dueDate",        "datecomps"),
    "startDateComponents":("startDate",      "datecomps"),
    "creationDate":       ("createdAt",      "date"),
    "lastModifiedDate":   ("modifiedAt",     "date"),
    "completionDate":     ("completedAt",    "date"),
    "hashtags":           ("hashtags",       "set_hashtags"),
    "timeZone":           ("timeZone",       "string"),
    "assignmentContext":  ("assignments",    "assignment_context"),
}

# Fields to omit from default output when they hold their default/zero value.
# (All set of json keys — applied in reminderToDict.)
OMIT_WHEN_DEFAULT = {
    "allDay",       # false
    "completed",    # false
    "flagged",      # 0
    "isOverdue",    # false
    "isRecurrent",  # false
    "priority",     # 0
    "hashtags",     # empty array (already suppressed but documented)
}

# Setters to expose on REMReminderChangeItem (write via update command)
# Maps cli_flag -> (setter_method, arg_type)
# arg_type: "string", "bool", "uint", "int", "datecomps", "url"
# Note: "url" setter uses attachmentContext, not setIcsUrl:
REMINDER_WRITE_OPS = {
    "title":        ("setTitleAsString:",       "string"),
    "notes":        ("setNotesAsString:",       "string"),
    "completed":    ("setCompleted:",           "bool"),
    "priority":     ("setPriority:",            "uint"),
    "flagged":      ("setFlagged:",             "bool"),
    "due-date":     ("setDueDateComponents:",   "datecomps"),
    "start-date":   ("setStartDateComponents:", "datecomps"),
    "url":          (None,                      "url"),  # handled specially
}

# Special write operations (not simple setters)
SPECIAL_WRITE_OPS = {
    "remove-parent": "removeFromParentReminder",
    "remove-from-list": "removeFromList",
}


def generate_header():
    return '''// AUTO-GENERATED by generate-cli.py — do not edit manually

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <mach-o/dyld.h>
#include <unistd.h>
#include <sys/wait.h>
#include <spawn.h>
#include <fcntl.h>

// --- Framework Loading ---

static Class REMStoreClass;
static Class REMSaveRequestClass;
static Class REMListSectionCIClass;

static void loadFramework(void) {
    [[NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/ReminderKit.framework"] load];
    REMStoreClass = NSClassFromString(@"REMStore");
    REMSaveRequestClass = NSClassFromString(@"REMSaveRequest");
    REMListSectionCIClass = NSClassFromString(@"REMListSectionChangeItem");
}

static id getStore(void) {
    return ((id (*)(id, SEL, BOOL))objc_msgSend)(
        [REMStoreClass alloc], sel_registerName("initUserInteractive:"), YES);
}

// --- Helpers ---

static void errorExit(NSString *msg) {
    fprintf(stderr, "Error: %s\\n", [msg UTF8String]);
    exit(1);
}

static BOOL parseBoolString(NSString *str) {
    NSString *lower = [str lowercaseString];
    return [lower isEqualToString:@"true"] || [lower isEqualToString:@"1"] || [lower isEqualToString:@"yes"];
}

static NSString *objectIDToString(id objID) {
    if (!objID) return nil;
    return [objID description];
}

// --- ID Output Mode (omit-when-default, field projection, full mode) ---
// Populated from CLI flags in main(). Shared by reminderToDict + helpers.
static BOOL gOutputFull = NO;               // --full
static NSArray *gOutputFields = nil;        // --fields id,title,notes,...
static BOOL gOutputLegacyID = NO;           // batch results keep old id format

// NSManagedObjectID description looks like:
//   "🎅~<x-apple-reminderkit://REMCDReminder/706D8583-A718-4644-9056-E79D9C8E9625>"
// Extract the canonical x-callback-url form (no emoji, no angle brackets).
static NSString *objectIDToURI(id objID) {
    if (!objID) return nil;
    NSString *desc = [objID description];
    if (!desc) return nil;
    // Find the first '<' and the matching '>' at the end.
    NSRange lt = [desc rangeOfString:@"<"];
    NSRange gt = [desc rangeOfString:@">" options:NSBackwardsSearch];
    if (lt.location != NSNotFound && gt.location != NSNotFound && gt.location > lt.location) {
        return [desc substringWithRange:NSMakeRange(lt.location + 1, gt.location - lt.location - 1)];
    }
    // Fallback: if the string already starts with the scheme, return as-is.
    if ([desc hasPrefix:@"x-apple-reminderkit://"]) return desc;
    return desc;
}

// Extract the bare UUID (last path component) from an NSManagedObjectID.
// Returns nil if no UUID-shaped token is found.
static NSString *objectIDToUUID(id objID) {
    if (!objID) return nil;
    NSString *uri = objectIDToURI(objID);
    if (!uri) return nil;
    NSArray *parts = [uri componentsSeparatedByString:@"/"];
    if (parts.count == 0) return nil;
    NSString *tail = [parts lastObject];
    // Strip any stray trailing '>' just in case.
    if ([tail hasSuffix:@">"]) tail = [tail substringToIndex:tail.length - 1];
    // Validate UUID shape (36 chars with dashes).
    if (tail.length == 36 && [tail characterAtIndex:8] == '-') return [tail uppercaseString];
    return nil;
}

// Build the full legacy id string (with emoji prefix) from an NSManagedObjectID.
// This is the exact byte-for-byte representation scripts using pre-v2 output
// would see. Only used in --full mode for the "id" field.
static NSString *objectIDToLegacyString(id objID) {
    return objectIDToString(objID);
}

// Accept either a bare UUID or any form that contains one ("706D...", the full
// emoji-URL wrapped form, the naked x-apple-reminderkit:// URL, etc.). Returns
// the uppercased bare UUID, or nil if the input doesn't look like one.
static NSString *normalizeIDInput(NSString *input) {
    if (!input || input.length == 0) return nil;
    // If the whole input is already a UUID, short-circuit.
    if (input.length == 36 && [input characterAtIndex:8] == '-') {
        return [input uppercaseString];
    }
    // Otherwise scan for a UUID-shaped token (36 chars, dash positions 8/13/18/23).
    NSCharacterSet *hex = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF-"];
    NSUInteger n = input.length;
    for (NSUInteger i = 0; i + 36 <= n; i++) {
        BOOL ok = YES;
        for (NSUInteger j = 0; j < 36; j++) {
            unichar c = [input characterAtIndex:i + j];
            if (![hex characterIsMember:c]) { ok = NO; break; }
            if ((j == 8 || j == 13 || j == 18 || j == 23) && c != '-') { ok = NO; break; }
            if (j != 8 && j != 13 && j != 18 && j != 23 && c == '-') { ok = NO; break; }
        }
        if (ok) return [[input substringWithRange:NSMakeRange(i, 36)] uppercaseString];
    }
    return nil;
}

// Add a key to a shaped dict's field order (used when callers add new keys
// after shaping, e.g. subtasks, listName). No-op if not a shaped dict.
static void addFieldIfRequested(NSMutableDictionary *dict, NSString *key, id value) {
    if (!value) return;
    if (gOutputFields && gOutputFields.count > 0) {
        if (![gOutputFields containsObject:key]) return;  // not requested, drop
        dict[key] = value;
        NSMutableArray *order = dict[@"__fieldOrder__"];
        if ([order isKindOfClass:[NSMutableArray class]] && ![order containsObject:key]) {
            [order addObject:key];
        }
        return;
    }
    dict[key] = value;
}

// --- Field projection helper ---
// Apply gOutputFields / gOutputFull / OMIT_WHEN_DEFAULT to a fully-populated dict.
// When gOutputFields is set we return an ordered dict containing only the requested
// keys (preserving user-specified order, values taken from src).
// When gOutputFull is NO and gOutputFields is nil, we apply the omit-when-default rules.
// Omit-when-default rules (only relevant when --full is NOT set):
//   allDay=false, completed=false, flagged=0, isOverdue=false,
//   isRecurrent=false, priority=0, hashtags=[]
static id applyOutputShape(NSDictionary *src) {
    // --fields takes precedence over --full
    if (gOutputFields && gOutputFields.count > 0) {
        // Preserve order via a plain NSMutableDictionary plus a sibling order array
        // that printJSON's sortedKeys would otherwise destroy. We therefore use
        // NSJSONWritingSortedKeys=NO and build an NSMutableDictionary that the
        // printer renders in insertion order. See printJSON below.
        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        NSMutableArray *order = [NSMutableArray array];
        for (NSString *field in gOutputFields) {
            id v = src[field];
            if (v) {
                out[field] = v;
                [order addObject:field];
            }
        }
        out[@"__fieldOrder__"] = order;  // printer reads and strips this
        return out;
    }
    if (gOutputFull) return src;  // all fields including defaults

    // Default: omit-when-default
    NSMutableDictionary *out = [src mutableCopy];
    if ([out[@"allDay"] isKindOfClass:[NSNumber class]] && ![out[@"allDay"] boolValue]) [out removeObjectForKey:@"allDay"];
    if ([out[@"completed"] isKindOfClass:[NSNumber class]] && ![out[@"completed"] boolValue]) [out removeObjectForKey:@"completed"];
    if ([out[@"isOverdue"] isKindOfClass:[NSNumber class]] && ![out[@"isOverdue"] boolValue]) [out removeObjectForKey:@"isOverdue"];
    if ([out[@"isRecurrent"] isKindOfClass:[NSNumber class]] && ![out[@"isRecurrent"] boolValue]) [out removeObjectForKey:@"isRecurrent"];
    if ([out[@"priority"] isKindOfClass:[NSNumber class]] && [out[@"priority"] integerValue] == 0) [out removeObjectForKey:@"priority"];
    if ([out[@"flagged"] isKindOfClass:[NSNumber class]] && [out[@"flagged"] integerValue] == 0) [out removeObjectForKey:@"flagged"];
    if ([out[@"hashtags"] isKindOfClass:[NSArray class]] && [(NSArray *)out[@"hashtags"] count] == 0) [out removeObjectForKey:@"hashtags"];
    return out;
}

static NSString *dateToISO(NSDate *date) {
    if (!date) return nil;
    NSISO8601DateFormatter *fmt = [[NSISO8601DateFormatter alloc] init];
    return [fmt stringFromDate:date];
}

static NSString *dateCompsToString(NSDateComponents *comps) {
    if (!comps) return nil;
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDate *date = [cal dateFromComponents:comps];
    if (date) return dateToISO(date);
    // Fallback: manual formatting
    return [NSString stringWithFormat:@"%04ld-%02ld-%02ld",
        (long)[comps year], (long)[comps month], (long)[comps day]];
}

static NSDateComponents *stringToDateComps(NSString *str) {
    // Parse ISO date string like "2026-03-15" or "2026-03-15T10:00:00"
    NSDateComponents *comps = [[NSDateComponents alloc] init];
    NSArray *parts = [str componentsSeparatedByString:@"T"];
    NSArray *dateParts = [parts[0] componentsSeparatedByString:@"-"];
    if (dateParts.count >= 3) {
        comps.year = [dateParts[0] integerValue];
        comps.month = [dateParts[1] integerValue];
        comps.day = [dateParts[2] integerValue];
    }
    if (parts.count > 1) {
        NSArray *timeParts = [parts[1] componentsSeparatedByString:@":"];
        if (timeParts.count >= 2) {
            comps.hour = [timeParts[0] integerValue];
            comps.minute = [timeParts[1] integerValue];
        }
    }
    return comps;
}

static NSString *normalizeQuotes(NSString *str) {
    if (!str) return nil;
    NSString *result = [str stringByReplacingOccurrencesOfString:@"\\u2018" withString:@"'"];
    result = [result stringByReplacingOccurrencesOfString:@"\\u2019" withString:@"'"];
    return result;
}

// Strip any internal "__fieldOrder__" markers from a JSON-ready structure.
// Returns a new object tree. Used by printJSON before serialisation.
static id stripFieldOrderMarkers(id obj) {
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *src = obj;
        NSMutableDictionary *dst = [NSMutableDictionary dictionary];
        for (NSString *k in src) {
            if ([k isEqualToString:@"__fieldOrder__"]) continue;
            dst[k] = stripFieldOrderMarkers(src[k]);
        }
        return dst;
    }
    if ([obj isKindOfClass:[NSArray class]]) {
        NSMutableArray *dst = [NSMutableArray array];
        for (id e in obj) [dst addObject:stripFieldOrderMarkers(e)];
        return dst;
    }
    return obj;
}

// Serialize JSON manually when any top-level or nested dict has a
// __fieldOrder__ marker, so we can preserve insertion order. Otherwise
// fall back to NSJSONSerialization (sorted keys for stability).
static NSString *jsonIndent(NSUInteger lvl) {
    NSMutableString *s = [NSMutableString string];
    for (NSUInteger i = 0; i < lvl; i++) [s appendString:@"  "];
    return s;
}

// Return the JSON-escaped string body (INCLUDING surrounding quotes).
// Example: jsonEscapeQuoted(@"he\\"llo") -> "\\"he\\\\\\"llo\\""
static NSString *jsonEscapeQuoted(NSString *s) {
    NSError *e = nil;
    NSData *d = [NSJSONSerialization dataWithJSONObject:@[s] options:0 error:&e];
    if (!d) return @"\\"\\"";
    NSString *full = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    // full looks like ["..."], strip the outer brackets only
    if (full.length >= 4) return [full substringWithRange:NSMakeRange(1, full.length - 2)];
    return @"\\"\\"";
}

static void jsonWriteValue(NSMutableString *out, id v, NSUInteger lvl, BOOL hasOrder);

static void jsonWriteDict(NSMutableString *out, NSDictionary *d, NSUInteger lvl, BOOL hasOrder) {
    NSArray *keys;
    NSArray *orderMarker = d[@"__fieldOrder__"];
    if ([orderMarker isKindOfClass:[NSArray class]]) {
        keys = orderMarker;
    } else {
        // Sort keys for stability, matching NSJSONWritingSortedKeys.
        keys = [[d allKeys] sortedArrayUsingSelector:@selector(compare:)];
    }
    if (keys.count == 0) { [out appendString:@"{\\n\\n"]; [out appendString:jsonIndent(lvl)]; [out appendString:@"}"]; return; }
    [out appendString:@"{\\n"];
    NSUInteger idx = 0;
    for (NSString *k in keys) {
        if ([k isEqualToString:@"__fieldOrder__"]) continue;
        id v = d[k];
        if (!v) continue;
        [out appendString:jsonIndent(lvl + 1)];
        [out appendString:jsonEscapeQuoted(k)];
        [out appendString:@" : "];
        jsonWriteValue(out, v, lvl + 1, hasOrder);
        // We don't easily know if there's a next key; append comma+newline unconditionally
        // and strip the trailing ,\\n below.
        [out appendString:@",\\n"];
        idx++;
    }
    // Strip trailing ",\\n"
    if (idx > 0 && [out hasSuffix:@",\\n"]) [out deleteCharactersInRange:NSMakeRange(out.length - 2, 2)];
    [out appendString:@"\\n"];
    [out appendString:jsonIndent(lvl)];
    [out appendString:@"}"];
}

static void jsonWriteArray(NSMutableString *out, NSArray *a, NSUInteger lvl, BOOL hasOrder) {
    if (a.count == 0) { [out appendString:@"[]"]; return; }
    [out appendString:@"[\\n"];
    for (NSUInteger i = 0; i < a.count; i++) {
        [out appendString:jsonIndent(lvl + 1)];
        jsonWriteValue(out, a[i], lvl + 1, hasOrder);
        if (i + 1 < a.count) [out appendString:@","];
        [out appendString:@"\\n"];
    }
    [out appendString:jsonIndent(lvl)];
    [out appendString:@"]"];
}

static void jsonWriteValue(NSMutableString *out, id v, NSUInteger lvl, BOOL hasOrder) {
    if ([v isKindOfClass:[NSDictionary class]]) { jsonWriteDict(out, v, lvl, hasOrder); return; }
    if ([v isKindOfClass:[NSArray class]]) { jsonWriteArray(out, v, lvl, hasOrder); return; }
    if ([v isKindOfClass:[NSString class]]) {
        [out appendString:jsonEscapeQuoted(v)];
        return;
    }
    if ([v isKindOfClass:[NSNumber class]]) {
        NSNumber *n = v;
        // Objective-C: @YES/@NO are NSNumbers; detect via objCType.
        const char *t = [n objCType];
        if (t[0] == 'c' || t[0] == 'B') { [out appendString:[n boolValue] ? @"true" : @"false"]; return; }
        [out appendString:[n stringValue]];
        return;
    }
    if (v == [NSNull null] || !v) { [out appendString:@"null"]; return; }
    // Fallback: serialize via NSJSONSerialization in a wrapper array.
    NSError *e = nil;
    NSData *d = [NSJSONSerialization dataWithJSONObject:@[v] options:0 error:&e];
    if (d) {
        NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
        if (s.length >= 2) { [out appendString:[s substringWithRange:NSMakeRange(1, s.length - 2)]]; return; }
    }
    [out appendString:@"null"];
}

// Recursively walk and set hasOrder=YES if any dict has __fieldOrder__.
static BOOL hasFieldOrderMarker(id obj) {
    if ([obj isKindOfClass:[NSDictionary class]]) {
        if (((NSDictionary *)obj)[@"__fieldOrder__"]) return YES;
        for (id v in [(NSDictionary *)obj allValues]) {
            if (hasFieldOrderMarker(v)) return YES;
        }
    } else if ([obj isKindOfClass:[NSArray class]]) {
        for (id v in (NSArray *)obj) if (hasFieldOrderMarker(v)) return YES;
    }
    return NO;
}

static void printJSON(id obj) {
    if (hasFieldOrderMarker(obj)) {
        NSMutableString *out = [NSMutableString string];
        jsonWriteValue(out, obj, 0, YES);
        printf("%s\\n", [out UTF8String]);
        return;
    }
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:obj
        options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:&error];
    if (error) errorExit([error localizedDescription]);
    printf("%s\\n", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
}

// --- List Helpers ---

static NSArray *fetchLists(id store) {
    NSError *error = nil;
    NSArray *lists = ((id (*)(id, SEL, id*))objc_msgSend)(
        store, sel_registerName("fetchEligibleDefaultListsWithError:"), &error);
    if (error) {
        if ([[error domain] isEqualToString:@"NSCocoaErrorDomain"] && [error code] == 4097) {
            fprintf(stderr, "Error: Reminders access denied.\\n\\n");
            fprintf(stderr, "Your terminal app needs permission to access Reminders.\\n\\n");
            fprintf(stderr, "1. Grant permission (triggers macOS prompt):\\n");
            fprintf(stderr, "   osascript -e 'tell application \\"Reminders\\" to get name of every list'\\n\\n");
            fprintf(stderr, "2. If previously denied, reset first, then re-run step 1:\\n");
            fprintf(stderr, "   tccutil reset Reminders <bundle-id>\\n\\n");
            fprintf(stderr, "   Find your terminal's bundle ID:\\n");
            fprintf(stderr, "   osascript -e 'id of app \\"iTerm\\"'  (replace iTerm with your terminal app name)\\n\\n");
            fprintf(stderr, "3. Then retry: reminderkit lists\\n");
            exit(1);
        }
        errorExit([NSString stringWithFormat:@"Failed to fetch lists: %@", error]);
    }
    return lists;
}

static id findList(id store, NSString *name) {
    NSArray *lists = fetchLists(store);
    for (id list in lists) {
        id storage = ((id (*)(id, SEL))objc_msgSend)(list, sel_registerName("storage"));
        NSString *listName = ((id (*)(id, SEL))objc_msgSend)(storage, sel_registerName("name"));
        if ([listName isEqualToString:name]) return list;
    }
    // Normalized fallback: retry with curly quotes normalized to straight quotes
    NSString *normalizedName = normalizeQuotes(name);
    for (id list in lists) {
        id storage = ((id (*)(id, SEL))objc_msgSend)(list, sel_registerName("storage"));
        NSString *listName = ((id (*)(id, SEL))objc_msgSend)(storage, sel_registerName("name"));
        if ([normalizeQuotes(listName) isEqualToString:normalizedName]) return list;
    }
    return nil;
}

static NSArray *fetchReminders(id store, id list, BOOL includeCompleted) {
    id listObjID = ((id (*)(id, SEL))objc_msgSend)(list, sel_registerName("objectID"));
    NSError *error = nil;
    NSArray *all = ((id (*)(id, SEL, id, id*))objc_msgSend)(
        store, sel_registerName("fetchRemindersForEventKitBridgingWithListIDs:error:"),
        @[listObjID], &error);
    if (error) errorExit([NSString stringWithFormat:@"Failed to fetch reminders: %@", error]);
    if (includeCompleted) return all;
    NSMutableArray *incomplete = [NSMutableArray array];
    for (id rem in all) {
        BOOL done = ((BOOL (*)(id, SEL))objc_msgSend)(rem, sel_registerName("isCompleted"));
        if (!done) [incomplete addObject:rem];
    }
    return incomplete;
}

static id findReminder(id store, NSString *title, NSString *listName) {
    NSArray *lists;
    if (listName) {
        id list = findList(store, listName);
        if (!list) errorExit([NSString stringWithFormat:@"List not found: %@", listName]);
        lists = @[list];
    } else {
        lists = fetchLists(store);
    }
    for (id list in lists) {
        NSArray *rems = fetchReminders(store, list, YES);
        for (id rem in rems) {
            NSString *t = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("titleAsString"));
            if ([t isEqualToString:title]) return rem;
        }
    }
    // Normalized fallback: retry with curly quotes normalized to straight quotes
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

static NSString *normalizeURL(NSString *url) {
    // Strip trailing slash for comparison
    while ([url hasSuffix:@"/"]) {
        url = [url substringToIndex:url.length - 1];
    }
    return [url lowercaseString];
}

static NSArray *findReminders(id store, NSString *title, NSString *listName) {
    NSArray *lists;
    if (listName) {
        id list = findList(store, listName);
        if (!list) errorExit([NSString stringWithFormat:@"List not found: %@", listName]);
        lists = @[list];
    } else {
        lists = fetchLists(store);
    }
    NSMutableArray *results = [NSMutableArray array];
    NSString *normalizedTitle = normalizeQuotes(title);
    NSString *lowerTitle = [normalizedTitle lowercaseString];
    for (id list in lists) {
        NSArray *rems = fetchReminders(store, list, NO);
        for (id rem in rems) {
            NSString *t = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("titleAsString"));
            if (!t) continue;
            NSString *lowerT = [[normalizeQuotes(t) lowercaseString] copy];
            if ([lowerT rangeOfString:lowerTitle].location != NSNotFound) {
                [results addObject:rem];
            }
        }
    }
    return results;
}

static NSArray *findRemindersByURL(id store, NSString *url, NSString *listName) {
    NSArray *lists;
    if (listName) {
        id list = findList(store, listName);
        if (!list) errorExit([NSString stringWithFormat:@"List not found: %@", listName]);
        lists = @[list];
    } else {
        lists = fetchLists(store);
    }
    NSMutableArray *results = [NSMutableArray array];
    NSString *normalizedSearch = normalizeURL(url);
    for (id list in lists) {
        NSArray *rems = fetchReminders(store, list, NO);
        for (id rem in rems) {
            @try {
                id attCtx = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("attachmentContext"));
                if (!attCtx) continue;
                NSArray *urlAtts = ((id (*)(id, SEL))objc_msgSend)(attCtx, sel_registerName("urlAttachments"));
                if (urlAtts.count == 0) continue;
                NSURL *attUrl = ((id (*)(id, SEL))objc_msgSend)(urlAtts[0], sel_registerName("url"));
                if (!attUrl) continue;
                NSString *normalizedAtt = normalizeURL([attUrl absoluteString]);
                if ([normalizedAtt isEqualToString:normalizedSearch]) {
                    [results addObject:rem];
                }
            } @catch (NSException *e) {}
        }
    }
    return results;
}

static id findReminderByID(id store, NSString *idString) {
    if (!idString) return nil;
    // Accept EITHER a bare UUID or any form that contains one (emoji-URL
    // wrapped, naked scheme URL, etc.). We normalize both sides.
    NSString *normalizedInput = normalizeIDInput(idString);
    NSArray *lists = fetchLists(store);
    for (id list in lists) {
        NSArray *rems = fetchReminders(store, list, YES);
        for (id rem in rems) {
            id objID = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("objectID"));
            NSString *uuid = objectIDToUUID(objID);
            if (normalizedInput && uuid && [uuid isEqualToString:normalizedInput]) return rem;
            // Fallback for legacy exact-match (emoji-URL form or scheme URL)
            NSString *idStr = objectIDToString(objID);
            if (idStr && [idStr isEqualToString:idString]) return rem;
        }
    }
    return nil;
}

static id requireUniqueReminder(id store, NSString *title, NSString *listName) {
    NSArray *matches = findReminders(store, title, listName);
    if (matches.count == 0) {
        errorExit([NSString stringWithFormat:@"Reminder not found: %@", title]);
    }
    if (matches.count > 1) {
        NSMutableString *msg = [NSMutableString stringWithFormat:@"Multiple reminders match '%@'. Use --id to specify:\\n", title];
        for (id rem in matches) {
            NSString *t = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("titleAsString"));
            id objID = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("objectID"));
            NSString *idStr = objectIDToString(objID);
            [msg appendFormat:@"  - \\"%@\\" (id: %@)\\n", t, idStr];
        }
        errorExit(msg);
    }
    return matches[0];
}
'''


def generate_reminder_to_dict():
    """Generate the reminderToDict function from REMINDER_READ_PROPS."""
    lines = [
        'static NSMutableDictionary *reminderToDict(id rem) {',
        '    NSMutableDictionary *dict = [NSMutableDictionary dictionary];',
        '',
    ]

    for prop, (json_key, type_hint) in REMINDER_READ_PROPS.items():
        sel = prop
        if type_hint == "string":
            lines.append(f'    @try {{')
            lines.append(f'        NSString *val_{json_key} = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("{sel}"));')
            lines.append(f'        if (val_{json_key}) dict[@"{json_key}"] = val_{json_key};')
            lines.append(f'    }} @catch (NSException *e) {{}}')
        elif type_hint == "bool":
            lines.append(f'    @try {{')
            lines.append(f'        BOOL val_{json_key} = ((BOOL (*)(id, SEL))objc_msgSend)(rem, sel_registerName("{sel}"));')
            lines.append(f'        dict[@"{json_key}"] = @(val_{json_key});')
            lines.append(f'    }} @catch (NSException *e) {{}}')
        elif type_hint == "bool_getter":
            lines.append(f'    @try {{')
            lines.append(f'        BOOL val_{json_key} = ((BOOL (*)(id, SEL))objc_msgSend)(rem, sel_registerName("isCompleted"));')
            lines.append(f'        dict[@"{json_key}"] = @(val_{json_key});')
            lines.append(f'    }} @catch (NSException *e) {{}}')
        elif type_hint == "uint":
            lines.append(f'    @try {{')
            lines.append(f'        NSUInteger val_{json_key} = ((NSUInteger (*)(id, SEL))objc_msgSend)(rem, sel_registerName("{sel}"));')
            lines.append(f'        dict[@"{json_key}"] = @(val_{json_key});')
            lines.append(f'    }} @catch (NSException *e) {{}}')
        elif type_hint == "int":
            lines.append(f'    @try {{')
            lines.append(f'        NSInteger val_{json_key} = ((NSInteger (*)(id, SEL))objc_msgSend)(rem, sel_registerName("{sel}"));')
            lines.append(f'        dict[@"{json_key}"] = @(val_{json_key});')
            lines.append(f'    }} @catch (NSException *e) {{}}')
        elif type_hint == "objid_self":
            # In default (v2) mode: bare UUID under "id", new "uri" field with scheme URL.
            # In --full mode: exact legacy bytes under "id" (emoji-wrapped form) + new
            # "uuid" field with bare UUID. Suppress "uri" in --full for byte-compat.
            lines.append(f'    @try {{')
            lines.append(f'        id val_{json_key} = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("{sel}"));')
            lines.append(f'        if (val_{json_key}) {{')
            lines.append(f'            if (gOutputFull) {{')
            lines.append(f'                dict[@"{json_key}"] = objectIDToLegacyString(val_{json_key});')
            lines.append(f'                NSString *_uuid = objectIDToUUID(val_{json_key});')
            lines.append(f'                if (_uuid) dict[@"uuid"] = _uuid;')
            lines.append(f'            }} else {{')
            lines.append(f'                NSString *_uuid = objectIDToUUID(val_{json_key});')
            lines.append(f'                dict[@"{json_key}"] = _uuid ?: objectIDToString(val_{json_key});')
            lines.append(f'                NSString *_uri = objectIDToURI(val_{json_key});')
            lines.append(f'                if (_uri) dict[@"uri"] = _uri;')
            lines.append(f'            }}')
            lines.append(f'        }}')
            lines.append(f'    }} @catch (NSException *e) {{}}')
        elif type_hint == "objid_ref":
            # In default (v2) mode: bare UUID under "<key>Id" + x-callback URL under "<key>Uri".
            # In --full mode: legacy emoji form under the original "<key>ID" key (byte-compat),
            # no Uri, no Id suffix field.
            base = json_key[:-2] if json_key.endswith("Id") else json_key
            uri_key = base + "Uri"
            legacy_key = base + "ID"  # pre-v2 camelCase was listID / parentID
            lines.append(f'    @try {{')
            lines.append(f'        id val_{json_key} = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("{sel}"));')
            lines.append(f'        if (val_{json_key}) {{')
            lines.append(f'            if (gOutputFull) {{')
            lines.append(f'                dict[@"{legacy_key}"] = objectIDToLegacyString(val_{json_key});')
            lines.append(f'            }} else {{')
            lines.append(f'                NSString *_uuid = objectIDToUUID(val_{json_key});')
            lines.append(f'                dict[@"{json_key}"] = _uuid ?: objectIDToString(val_{json_key});')
            lines.append(f'                NSString *_uri = objectIDToURI(val_{json_key});')
            lines.append(f'                if (_uri) dict[@"{uri_key}"] = _uri;')
            lines.append(f'            }}')
            lines.append(f'        }}')
            lines.append(f'    }} @catch (NSException *e) {{}}')
        elif type_hint == "objid":
            lines.append(f'    @try {{')
            lines.append(f'        id val_{json_key} = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("{sel}"));')
            lines.append(f'        if (val_{json_key}) dict[@"{json_key}"] = objectIDToString(val_{json_key});')
            lines.append(f'    }} @catch (NSException *e) {{}}')
        elif type_hint == "date":
            lines.append(f'    @try {{')
            lines.append(f'        NSDate *val_{json_key} = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("{sel}"));')
            lines.append(f'        if (val_{json_key}) dict[@"{json_key}"] = dateToISO(val_{json_key});')
            lines.append(f'    }} @catch (NSException *e) {{}}')
        elif type_hint == "datecomps":
            lines.append(f'    @try {{')
            lines.append(f'        NSDateComponents *val_{json_key} = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("{sel}"));')
            lines.append(f'        if (val_{json_key}) dict[@"{json_key}"] = dateCompsToString(val_{json_key});')
            lines.append(f'    }} @catch (NSException *e) {{}}')
        elif type_hint == "set_hashtags":
            lines.append(f'    @try {{')
            lines.append(f'        NSSet *tags = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("hashtags"));')
            lines.append(f'        if (tags && tags.count > 0) {{')
            lines.append(f'            NSMutableArray *tagNames = [NSMutableArray array];')
            lines.append(f'            for (id tag in tags) {{')
            lines.append(f'                NSString *name = ((id (*)(id, SEL))objc_msgSend)(tag, sel_registerName("name"));')
            lines.append(f'                if (name) [tagNames addObject:name];')
            lines.append(f'            }}')
            lines.append(f'            dict[@"{json_key}"] = tagNames;')
            lines.append(f'        }}')
            lines.append(f'    }} @catch (NSException *e) {{}}')
        elif type_hint == "assignment_context":
            lines.append(f'    @try {{')
            lines.append(f'        id assignCtx = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("assignmentContext"));')
            lines.append(f'        if (assignCtx) {{')
            lines.append(f'            NSSet *assignSet = ((id (*)(id, SEL))objc_msgSend)(assignCtx, sel_registerName("assignments"));')
            lines.append(f'            if (assignSet && assignSet.count > 0) {{')
            lines.append(f'                NSMutableArray *assignArr = [NSMutableArray array];')
            lines.append(f'                for (id a in assignSet) {{')
            lines.append(f'                    NSMutableDictionary *aDict = [NSMutableDictionary dictionary];')
            lines.append(f'                    @try {{')
            lines.append(f'                        id assigneeID = ((id (*)(id, SEL))objc_msgSend)(a, sel_registerName("assigneeID"));')
            lines.append(f'                        if (assigneeID) aDict[@"assigneeID"] = objectIDToString(assigneeID);')
            lines.append(f'                    }} @catch (NSException *e2) {{}}')
            lines.append(f'                    @try {{')
            lines.append(f'                        id originatorID = ((id (*)(id, SEL))objc_msgSend)(a, sel_registerName("originatorID"));')
            lines.append(f'                        if (originatorID) aDict[@"originatorID"] = objectIDToString(originatorID);')
            lines.append(f'                    }} @catch (NSException *e2) {{}}')
            lines.append(f'                    @try {{')
            lines.append(f'                        NSInteger status = ((NSInteger (*)(id, SEL))objc_msgSend)(a, sel_registerName("status"));')
            lines.append(f'                        aDict[@"status"] = @(status);')
            lines.append(f'                    }} @catch (NSException *e2) {{}}')
            lines.append(f'                    @try {{')
            lines.append(f'                        NSDate *assignedDate = ((id (*)(id, SEL))objc_msgSend)(a, sel_registerName("assignedDate"));')
            lines.append(f'                        if (assignedDate) aDict[@"assignedDate"] = dateToISO(assignedDate);')
            lines.append(f'                    }} @catch (NSException *e2) {{}}')
            lines.append(f'                    if (aDict.count > 0) [assignArr addObject:aDict];')
            lines.append(f'                }}')
            lines.append(f'                dict[@"{json_key}"] = assignArr;')
            lines.append(f'            }}')
            lines.append(f'        }}')
            lines.append(f'    }} @catch (NSException *e) {{}}')
        lines.append('')

    # URL is read via attachmentContext
    lines.append('    @try {')
    lines.append('        id attCtx = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("attachmentContext"));')
    lines.append('        if (attCtx) {')
    lines.append('            NSArray *urlAtts = ((id (*)(id, SEL))objc_msgSend)(attCtx, sel_registerName("urlAttachments"));')
    lines.append('            if (urlAtts.count > 0) {')
    lines.append('                NSURL *attUrl = ((id (*)(id, SEL))objc_msgSend)(urlAtts[0], sel_registerName("url"));')
    lines.append('                if (attUrl) {')
    lines.append('                    dict[@"url"] = [attUrl absoluteString];')
    lines.append('                    // Extract linkedNoteId from applenotes://showNote?identifier=UUID URLs')
    lines.append('                    if ([[[attUrl scheme] lowercaseString] isEqualToString:@"applenotes"] && [[[attUrl host] lowercaseString] isEqualToString:@"shownote"]) {')
    lines.append('                        NSURLComponents *comps = [NSURLComponents componentsWithURL:attUrl resolvingAgainstBaseURL:NO];')
    lines.append('                        for (NSURLQueryItem *item in comps.queryItems) {')
    lines.append('                            if ([item.name isEqualToString:@"identifier"] && item.value) {')
    lines.append('                                dict[@"linkedNoteId"] = item.value;')
    lines.append('                                break;')
    lines.append('                            }')
    lines.append('                        }')
    lines.append('                    }')
    lines.append('                }')
    lines.append('            }')
    lines.append('        }')
    lines.append('    } @catch (NSException *e) {}')
    lines.append('')

    lines.append('    // Apply --fields / --full / omit-when-default shaping before returning.')
    lines.append('    id shaped = applyOutputShape(dict);')
    lines.append('    if ([shaped isKindOfClass:[NSMutableDictionary class]]) return (NSMutableDictionary *)shaped;')
    lines.append('    NSMutableDictionary *m = [shaped mutableCopy];')
    lines.append('    return m;')
    lines.append('}')
    return '\n'.join(lines)


def generate_commands():
    """Generate the command implementations."""
    return '''
// --- Commands ---

static int cmdLists(id store) {
    NSArray *lists = fetchLists(store);
    NSMutableArray *result = [NSMutableArray array];
    for (id list in lists) {
        id storage = ((id (*)(id, SEL))objc_msgSend)(list, sel_registerName("storage"));
        NSString *name = ((id (*)(id, SEL))objc_msgSend)(storage, sel_registerName("name"));
        id objID = ((id (*)(id, SEL))objc_msgSend)(list, sel_registerName("objectID"));
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        if (name) d[@"name"] = name;
        if (objID) {
            if (gOutputFull) {
                // Exact legacy bytes for byte-compat, plus "uuid" as a new addition.
                d[@"id"] = objectIDToLegacyString(objID) ?: @"";
                NSString *uuid = objectIDToUUID(objID);
                if (uuid) d[@"uuid"] = uuid;
            } else {
                NSString *uuid = objectIDToUUID(objID);
                d[@"id"] = uuid ?: (objectIDToString(objID) ?: @"");
                NSString *uri = objectIDToURI(objID);
                if (uri) d[@"uri"] = uri;
            }
        }
        [result addObject:(NSDictionary *)applyOutputShape(d)];
    }
    printJSON(result);
    return 0;
}

static NSSet *parseCommaSeparatedTags(NSString *tagStr) {
    if (!tagStr || tagStr.length == 0) return nil;
    NSArray *parts = [tagStr componentsSeparatedByString:@","];
    NSMutableSet *tags = [NSMutableSet set];
    for (NSString *part in parts) {
        NSString *trimmed = [part stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (trimmed.length > 0) [tags addObject:trimmed];
    }
    return tags.count > 0 ? tags : nil;
}

static NSSet *getTagNames(id rem) {
    @try {
        NSSet *tags = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("hashtags"));
        if (!tags || tags.count == 0) return [NSSet set];
        NSMutableSet *names = [NSMutableSet set];
        for (id tag in tags) {
            NSString *name = ((id (*)(id, SEL))objc_msgSend)(tag, sel_registerName("name"));
            if (name) [names addObject:name];
        }
        return names;
    } @catch (NSException *e) {
        return [NSSet set];
    }
}

static int cmdList(id store, NSString *listName, BOOL includeCompleted, NSString *tagFilter, NSString *excludeTagFilter, BOOL hasURL, NSString *notesContains) {
    id list = findList(store, listName);
    if (!list) errorExit([NSString stringWithFormat:@"List not found: %@", listName]);
    NSArray *rems = fetchReminders(store, list, includeCompleted);

    NSSet *includeTags = parseCommaSeparatedTags(tagFilter);
    NSSet *excludeTags = parseCommaSeparatedTags(excludeTagFilter);
    NSString *lowerNotesFilter = notesContains ? [notesContains lowercaseString] : nil;

    NSMutableArray *result = [NSMutableArray array];
    for (id rem in rems) {
        if (hasURL) {
            @try {
                id attCtx = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("attachmentContext"));
                if (!attCtx) continue;
                NSArray *urlAtts = ((id (*)(id, SEL))objc_msgSend)(attCtx, sel_registerName("urlAttachments"));
                if (!urlAtts || urlAtts.count == 0) continue;
            } @catch (NSException *e) { continue; }
        }
        if (includeTags || excludeTags) {
            NSSet *remTags = getTagNames(rem);
            if (includeTags && ![includeTags intersectsSet:remTags]) continue;
            if (excludeTags && [excludeTags intersectsSet:remTags]) continue;
        }
        if (lowerNotesFilter) {
            @try {
                NSString *notes = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("notesAsString"));
                if (!notes || [[notes lowercaseString] rangeOfString:lowerNotesFilter].location == NSNotFound) continue;
            } @catch (NSException *e) { continue; }
        }
        [result addObject:reminderToDict(rem)];
    }
    printJSON(result);
    return 0;
}

static int cmdListAll(id store, BOOL includeCompleted, NSString *tagFilter, NSString *excludeTagFilter, BOOL hasURL, NSString *notesContains) {
    NSArray *lists = fetchLists(store);
    NSSet *includeTags = parseCommaSeparatedTags(tagFilter);
    NSSet *excludeTags = parseCommaSeparatedTags(excludeTagFilter);
    NSString *lowerNotesFilter = notesContains ? [notesContains lowercaseString] : nil;

    NSMutableArray *result = [NSMutableArray array];
    for (id list in lists) {
        id storage = ((id (*)(id, SEL))objc_msgSend)(list, sel_registerName("storage"));
        NSString *name = ((id (*)(id, SEL))objc_msgSend)(storage, sel_registerName("name"));
        NSArray *rems = fetchReminders(store, list, includeCompleted);
        for (id rem in rems) {
            if (hasURL) {
                @try {
                    id attCtx = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("attachmentContext"));
                    if (!attCtx) continue;
                    NSArray *urlAtts = ((id (*)(id, SEL))objc_msgSend)(attCtx, sel_registerName("urlAttachments"));
                    if (!urlAtts || urlAtts.count == 0) continue;
                } @catch (NSException *e) { continue; }
            }
            if (includeTags || excludeTags) {
                NSSet *remTags = getTagNames(rem);
                if (includeTags && ![includeTags intersectsSet:remTags]) continue;
                if (excludeTags && [excludeTags intersectsSet:remTags]) continue;
            }
            if (lowerNotesFilter) {
                @try {
                    NSString *notes = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("notesAsString"));
                    if (!notes || [[notes lowercaseString] rangeOfString:lowerNotesFilter].location == NSNotFound) continue;
                } @catch (NSException *e) { continue; }
            }
            NSMutableDictionary *dict = [reminderToDict(rem) mutableCopy];
            addFieldIfRequested(dict, @"listName", name ?: @"");
            [result addObject:dict];
        }
    }
    printJSON(result);
    return 0;
}

static int cmdGetByID(id store, NSString *remID) {
    id rem = findReminderByID(store, remID);
    if (!rem) errorExit([NSString stringWithFormat:@"Reminder not found with id: %@", remID]);

    NSMutableDictionary *dict = [reminderToDict(rem) mutableCopy];

    // Add subtasks
    id parentObjID = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("objectID"));
    NSString *parentIDStr = objectIDToString(parentObjID);
    id listID = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("listID"));
    NSError *error = nil;
    NSArray *allInList = ((id (*)(id, SEL, id, id*))objc_msgSend)(
        store, sel_registerName("fetchRemindersForEventKitBridgingWithListIDs:error:"),
        @[listID], &error);

    NSMutableArray *subtasks = [NSMutableArray array];
    for (id sub in allInList) {
        id pid = ((id (*)(id, SEL))objc_msgSend)(sub, sel_registerName("parentReminderID"));
        if (pid && [objectIDToString(pid) isEqualToString:parentIDStr]) {
            [subtasks addObject:reminderToDict(sub)];
        }
    }
    if (subtasks.count > 0) addFieldIfRequested(dict, @"subtasks", subtasks);

    printJSON(dict);
    return 0;
}

static int cmdGet(id store, NSString *title, NSString *listName, NSString *urlFilter, NSString *tagFilter, NSString *excludeTagFilter, BOOL filterHasURL, NSString *notesContains) {
    NSArray *matches;
    if (urlFilter) {
        matches = findRemindersByURL(store, urlFilter, listName);
        if (title) {
            // Filter by both URL and title
            NSString *normalizedTitle = normalizeQuotes(title);
            NSString *lowerTitle = [normalizedTitle lowercaseString];
            NSMutableArray *filtered = [NSMutableArray array];
            for (id rem in matches) {
                NSString *t = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("titleAsString"));
                if (!t) continue;
                NSString *lowerT = [[normalizeQuotes(t) lowercaseString] copy];
                if ([lowerT rangeOfString:lowerTitle].location != NSNotFound) {
                    [filtered addObject:rem];
                }
            }
            matches = filtered;
        }
    } else if (title) {
        matches = findReminders(store, title, listName);
    } else {
        // No title or URL - fetch all reminders across lists
        NSArray *lists;
        if (listName) {
            id list = findList(store, listName);
            if (!list) errorExit([NSString stringWithFormat:@"List not found: %@", listName]);
            lists = @[list];
        } else {
            lists = fetchLists(store);
        }
        NSMutableArray *all = [NSMutableArray array];
        for (id list in lists) {
            NSArray *rems = fetchReminders(store, list, NO);
            [all addObjectsFromArray:rems];
        }
        matches = all;
    }

    // Apply tag, has-url, and notes-contains filters
    NSSet *includeTags = parseCommaSeparatedTags(tagFilter);
    NSSet *excludeTags = parseCommaSeparatedTags(excludeTagFilter);
    NSString *lowerNotesFilter = notesContains ? [notesContains lowercaseString] : nil;
    if (filterHasURL || includeTags || excludeTags || lowerNotesFilter) {
        NSMutableArray *filtered = [NSMutableArray array];
        for (id rem in matches) {
            if (filterHasURL) {
                @try {
                    id attCtx = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("attachmentContext"));
                    if (!attCtx) continue;
                    NSArray *urlAtts = ((id (*)(id, SEL))objc_msgSend)(attCtx, sel_registerName("urlAttachments"));
                    if (!urlAtts || urlAtts.count == 0) continue;
                } @catch (NSException *e) { continue; }
            }
            if (includeTags || excludeTags) {
                NSSet *remTags = getTagNames(rem);
                if (includeTags && ![includeTags intersectsSet:remTags]) continue;
                if (excludeTags && [excludeTags intersectsSet:remTags]) continue;
            }
            if (lowerNotesFilter) {
                @try {
                    NSString *notes = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("notesAsString"));
                    if (!notes || [[notes lowercaseString] rangeOfString:lowerNotesFilter].location == NSNotFound) continue;
                } @catch (NSException *e) { continue; }
            }
            [filtered addObject:rem];
        }
        matches = filtered;
    }

    if (matches.count == 0) {
        // Filter-only queries (no title/url) return empty array instead of error
        if (!title && !urlFilter) {
            printJSON(@[]);
            return 0;
        }
        NSString *desc = urlFilter ? urlFilter : title;
        errorExit([NSString stringWithFormat:@"No reminders found matching: %@", desc]);
    }

    // Skip expensive subtask expansion for bulk filter-only searches
    BOOL expandSubtasks = (title || urlFilter);
    NSMutableDictionary *listCache = expandSubtasks ? [NSMutableDictionary dictionary] : nil;
    NSMutableArray *resultArray = [NSMutableArray array];
    for (id rem in matches) {
        NSMutableDictionary *dict = [reminderToDict(rem) mutableCopy];

        if (expandSubtasks) {
            // Add subtasks (cached per list to avoid redundant fetches)
            id parentObjID = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("objectID"));
            NSString *parentIDStr = objectIDToString(parentObjID);
            id listID = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("listID"));
            NSString *listKey = objectIDToString(listID);
            NSArray *allInList = listCache[listKey];
            if (!allInList) {
                NSError *error = nil;
                allInList = ((id (*)(id, SEL, id, id*))objc_msgSend)(
                    store, sel_registerName("fetchRemindersForEventKitBridgingWithListIDs:error:"),
                    @[listID], &error);
                if (allInList) listCache[listKey] = allInList;
            }

            NSMutableArray *subtasks = [NSMutableArray array];
            for (id sub in allInList ?: @[]) {
                id pid = ((id (*)(id, SEL))objc_msgSend)(sub, sel_registerName("parentReminderID"));
                if (pid && [objectIDToString(pid) isEqualToString:parentIDStr]) {
                    [subtasks addObject:reminderToDict(sub)];
                }
            }
            if (subtasks.count > 0) addFieldIfRequested(dict, @"subtasks", subtasks);
        }

        [resultArray addObject:dict];
    }

    if (resultArray.count == 1) {
        printJSON(resultArray[0]);
    } else {
        printJSON(resultArray);
    }
    return 0;
}

static int cmdSubtasks(id store, NSString *title, NSString *listName) {
    id rem = requireUniqueReminder(store, title, listName);

    id parentObjID = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("objectID"));
    NSString *parentIDStr = objectIDToString(parentObjID);
    id listID = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("listID"));
    NSError *error = nil;
    NSArray *allInList = ((id (*)(id, SEL, id, id*))objc_msgSend)(
        store, sel_registerName("fetchRemindersForEventKitBridgingWithListIDs:error:"),
        @[listID], &error);

    NSMutableArray *subtasks = [NSMutableArray array];
    for (id sub in allInList) {
        id pid = ((id (*)(id, SEL))objc_msgSend)(sub, sel_registerName("parentReminderID"));
        if (pid && [objectIDToString(pid) isEqualToString:parentIDStr]) {
            [subtasks addObject:reminderToDict(sub)];
        }
    }
    printJSON(subtasks);
    return 0;
}

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

    // Get the list change item from save request
    id saveReq = ((id (*)(id, SEL, id))objc_msgSend)(
        [REMSaveRequestClass alloc], sel_registerName("initWithStore:"), store);

    id listCI = ((id (*)(id, SEL, id))objc_msgSend)(
        saveReq, sel_registerName("updateList:"), list);

    id newRem = ((id (*)(id, SEL, id, id))objc_msgSend)(
        saveReq, sel_registerName("addReminderWithTitle:toListChangeItem:"),
        title, listCI);

    if (!newRem) errorExit(@"Failed to create reminder");

    // Apply optional properties
''' + generate_add_setters() + '''

    // Reparent: --parent-id
    if (opts[@"parent-id"]) {
        reparentChangeItem(store, saveReq, listCI, newRem, opts[@"parent-id"]);
    }

    NSError *error = nil;
    ((BOOL (*)(id, SEL, id*))objc_msgSend)(
        saveReq, sel_registerName("saveSynchronouslyWithError:"), &error);
    if (error) errorExit([NSString stringWithFormat:@"Save failed: %@", error]);

    // Re-fetch and return — use the resolved list name for accurate lookup
    // (when --parent-id is used without --list, listName is nil but list was derived from parent)
    NSString *resolvedListName = listName;
    if (!resolvedListName) {
        id listStorage = ((id (*)(id, SEL))objc_msgSend)(list, sel_registerName("storage"));
        resolvedListName = ((id (*)(id, SEL))objc_msgSend)(listStorage, sel_registerName("name"));
    }
    id created = findReminder(store, title, resolvedListName);
    if (created) printJSON(reminderToDict(created));
    else fprintf(stderr, "Created (but could not re-fetch)\\n");
    return 0;
}

static int cmdCreateList(id store, NSString *name) {
    // Get default account from the first list
    NSArray *lists = fetchLists(store);
    if (lists.count == 0) errorExit(@"No accounts found");
    id account = ((id (*)(id, SEL))objc_msgSend)(lists[0], sel_registerName("account"));

    id saveReq = ((id (*)(id, SEL, id))objc_msgSend)(
        [REMSaveRequestClass alloc], sel_registerName("initWithStore:"), store);

    id accountCI = ((id (*)(id, SEL, id))objc_msgSend)(
        saveReq, sel_registerName("updateAccount:"), account);

    id newList = ((id (*)(id, SEL, id, id, id))objc_msgSend)(
        saveReq, sel_registerName("addListWithName:toAccountChangeItem:listObjectID:"),
        name, accountCI, nil);

    if (!newList) errorExit(@"Failed to create list");

    NSError *error = nil;
    ((BOOL (*)(id, SEL, id*))objc_msgSend)(
        saveReq, sel_registerName("saveSynchronouslyWithError:"), &error);
    if (error) errorExit([NSString stringWithFormat:@"Save failed: %@", error]);

    printJSON(@{@"name": name, @"created": @YES});
    return 0;
}

static int cmdRenameList(id store, NSString *oldName, NSString *newName) {
    id list = findList(store, oldName);
    if (!list) errorExit([NSString stringWithFormat:@"List not found: %@", oldName]);

    id saveReq = ((id (*)(id, SEL, id))objc_msgSend)(
        [REMSaveRequestClass alloc], sel_registerName("initWithStore:"), store);

    id listCI = ((id (*)(id, SEL, id))objc_msgSend)(
        saveReq, sel_registerName("updateList:"), list);

    id storage = ((id (*)(id, SEL))objc_msgSend)(listCI, sel_registerName("storage"));
    ((void (*)(id, SEL, id))objc_msgSend)(storage, sel_registerName("setName:"), newName);

    NSError *error = nil;
    ((BOOL (*)(id, SEL, id*))objc_msgSend)(
        saveReq, sel_registerName("saveSynchronouslyWithError:"), &error);
    if (error) errorExit([NSString stringWithFormat:@"Save failed: %@", error]);

    printJSON(@{@"oldName": oldName, @"newName": newName, @"renamed": @YES});
    return 0;
}

static int cmdDeleteList(id store, NSString *name) {
    id list = findList(store, name);
    if (!list) errorExit([NSString stringWithFormat:@"List not found: %@", name]);

    id saveReq = ((id (*)(id, SEL, id))objc_msgSend)(
        [REMSaveRequestClass alloc], sel_registerName("initWithStore:"), store);

    id listCI = ((id (*)(id, SEL, id))objc_msgSend)(
        saveReq, sel_registerName("updateList:"), list);

    ((void (*)(id, SEL))objc_msgSend)(listCI, sel_registerName("removeFromParent"));

    NSError *error = nil;
    ((BOOL (*)(id, SEL, id*))objc_msgSend)(
        saveReq, sel_registerName("saveSynchronouslyWithError:"), &error);
    if (error) errorExit([NSString stringWithFormat:@"Save failed: %@", error]);

    printJSON(@{@"name": name, @"deleted": @YES});
    return 0;
}

static int cmdAddTag(id store, NSString *remID, NSString *tagName) {
    id rem = findReminderByID(store, remID);
    if (!rem) errorExit([NSString stringWithFormat:@"Reminder not found with id: %@", remID]);

    // Check if tag already exists (idempotent add)
    NSSet *existingTags = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("hashtags"));
    if (existingTags) {
        for (id tag in existingTags) {
            NSString *name = ((id (*)(id, SEL))objc_msgSend)(tag, sel_registerName("name"));
            if ([name isEqualToString:tagName]) {
                // Tag already exists, return current state (no-op)
                printJSON(reminderToDict(rem));
                return 0;
            }
        }
    }

    id saveReq = ((id (*)(id, SEL, id))objc_msgSend)(
        [REMSaveRequestClass alloc], sel_registerName("initWithStore:"), store);

    id changeItem = ((id (*)(id, SEL, id))objc_msgSend)(
        saveReq, sel_registerName("updateReminder:"), rem);

    id hashtagCtx = ((id (*)(id, SEL))objc_msgSend)(changeItem, sel_registerName("hashtagContext"));
    if (!hashtagCtx) errorExit(@"Failed to get hashtag context");

    // type 0 = normal tag
    ((void (*)(id, SEL, NSUInteger, id))objc_msgSend)(
        hashtagCtx, sel_registerName("addHashtagWithType:name:"), (NSUInteger)0, tagName);

    NSError *error = nil;
    ((BOOL (*)(id, SEL, id*))objc_msgSend)(
        saveReq, sel_registerName("saveSynchronouslyWithError:"), &error);
    if (error) errorExit([NSString stringWithFormat:@"Save failed: %@", error]);

    id updated = findReminderByID(store, remID);
    if (updated) printJSON(reminderToDict(updated));
    else printJSON(@{@"id": remID, @"tagAdded": tagName});
    return 0;
}

static int cmdRemoveTag(id store, NSString *remID, NSString *tagName) {
    id rem = findReminderByID(store, remID);
    if (!rem) errorExit([NSString stringWithFormat:@"Reminder not found with id: %@", remID]);

    id saveReq = ((id (*)(id, SEL, id))objc_msgSend)(
        [REMSaveRequestClass alloc], sel_registerName("initWithStore:"), store);

    id changeItem = ((id (*)(id, SEL, id))objc_msgSend)(
        saveReq, sel_registerName("updateReminder:"), rem);

    id hashtagCtx = ((id (*)(id, SEL))objc_msgSend)(changeItem, sel_registerName("hashtagContext"));
    if (!hashtagCtx) errorExit(@"Failed to get hashtag context");

    // Find the hashtag object by name from the reminder's existing hashtags
    NSSet *tags = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("hashtags"));
    id tagToRemove = nil;
    for (id tag in tags) {
        NSString *name = ((id (*)(id, SEL))objc_msgSend)(tag, sel_registerName("name"));
        if ([name isEqualToString:tagName]) { tagToRemove = tag; break; }
    }
    if (!tagToRemove) errorExit([NSString stringWithFormat:@"Tag not found: %@", tagName]);

    ((void (*)(id, SEL, id))objc_msgSend)(hashtagCtx, sel_registerName("removeHashtag:"), tagToRemove);

    NSError *error = nil;
    ((BOOL (*)(id, SEL, id*))objc_msgSend)(
        saveReq, sel_registerName("saveSynchronouslyWithError:"), &error);
    if (error) errorExit([NSString stringWithFormat:@"Save failed: %@", error]);

    id updated = findReminderByID(store, remID);
    if (updated) printJSON(reminderToDict(updated));
    else printJSON(@{@"id": remID, @"tagRemoved": tagName});
    return 0;
}

static int cmdListSections(id store, NSString *listName) {
    id list = findList(store, listName);
    if (!list) errorExit([NSString stringWithFormat:@"List not found: %@", listName]);

    // Try to fetch sections from the list
    NSMutableArray *result = [NSMutableArray array];
    @try {
        id sections = ((id (*)(id, SEL))objc_msgSend)(list, sel_registerName("sections"));
        if (sections) {
            for (id section in sections) {
                NSString *name = ((id (*)(id, SEL))objc_msgSend)(section, sel_registerName("canonicalName"));
                id objID = ((id (*)(id, SEL))objc_msgSend)(section, sel_registerName("objectID"));
                NSMutableDictionary *d = [NSMutableDictionary dictionary];
                if (name) d[@"name"] = name;
                if (objID) {
                    if (gOutputFull) {
                        d[@"id"] = objectIDToLegacyString(objID) ?: @"";
                        NSString *uuid = objectIDToUUID(objID);
                        if (uuid) d[@"uuid"] = uuid;
                    } else {
                        NSString *uuid = objectIDToUUID(objID);
                        d[@"id"] = uuid ?: (objectIDToString(objID) ?: @"");
                        NSString *uri = objectIDToURI(objID);
                        if (uri) d[@"uri"] = uri;
                    }
                }
                [result addObject:d];
            }
        }
    } @catch (NSException *e) {
        fprintf(stderr, "Warning: could not enumerate sections: %s\\n", [[e reason] UTF8String]);
    }
    printJSON(result);
    return 0;
}

static int cmdCreateSection(id store, NSString *listName, NSString *sectionName) {
    id list = findList(store, listName);
    if (!list) errorExit([NSString stringWithFormat:@"List not found: %@", listName]);

    id saveReq = ((id (*)(id, SEL, id))objc_msgSend)(
        [REMSaveRequestClass alloc], sel_registerName("initWithStore:"), store);

    id listCI = ((id (*)(id, SEL, id))objc_msgSend)(
        saveReq, sel_registerName("updateList:"), list);

    // Create a new section change item
    id newSection = ((id (*)(id, SEL, id, id, id))objc_msgSend)(
        [REMListSectionCIClass alloc],
        sel_registerName("initWithObjectID:displayName:insertIntoListChangeItem:"),
        nil, sectionName, listCI);

    if (!newSection) errorExit(@"Failed to create section");

    NSError *error = nil;
    ((BOOL (*)(id, SEL, id*))objc_msgSend)(
        saveReq, sel_registerName("saveSynchronouslyWithError:"), &error);
    if (error) errorExit([NSString stringWithFormat:@"Save failed: %@", error]);

    printJSON(@{@"list": listName, @"section": sectionName, @"created": @YES});
    return 0;
}
'''


def generate_link_note_command():
    """Generate the link-note command."""
    return '''
static int cmdLinkNote(id store, NSString *remId, NSString *noteId) {
    // Construct applenotes:// URL
    NSURLComponents *comps = [[NSURLComponents alloc] init];
    comps.scheme = @"applenotes";
    comps.host = @"showNote";
    comps.queryItems = @[[NSURLQueryItem queryItemWithName:@"identifier" value:noteId]];
    NSString *urlStr = [comps string];

    // Delegate to cmdUpdate with the constructed URL
    return cmdUpdate(store, nil, @{@"id": remId, @"url": urlStr});
}
'''


def generate_update_command():
    """Generate the update command with all setter flags."""
    lines = [
        'static int cmdUpdate(id store, NSString *listName, NSDictionary *opts) {',
        '    NSString *remID = opts[@"id"];',
        '    id rem = findReminderByID(store, remID);',
        '    if (!rem) errorExit([NSString stringWithFormat:@"Reminder not found with id: %@", remID]);',
        '',
        '    // Validate conflicting URL flags',
        '    if (opts[@"url"] && opts[@"clear-url"]) {',
        '        errorExit(@"Cannot use --url and --clear-url together");',
        '    }',
        '',
        '    // Validate conflicting parent flags',
        '    NSString *parentID = opts[@"parent-id"];',
        '    BOOL removeParent = opts[@"remove-parent"] != nil;',
        '    if (parentID && removeParent) {',
        '        errorExit(@"Cannot specify both --parent-id and --remove-parent");',
        '    }',
        '',
        '    id saveReq = ((id (*)(id, SEL, id))objc_msgSend)(',
        '        [REMSaveRequestClass alloc], sel_registerName("initWithStore:"), store);',
        '',
        '    id changeItem = ((id (*)(id, SEL, id))objc_msgSend)(',
        '        saveReq, sel_registerName("updateReminder:"), rem);',
        '',
    ]

    # Generate setter applications
    for flag, (setter, arg_type) in REMINDER_WRITE_OPS.items():
        if flag == "url":
            continue  # handled specially below
        if arg_type == "string":
            if flag == "notes":
                # Handle append-notes for the notes field
                lines.append(f'    if (opts[@"append-notes"]) {{')
                lines.append(f'        NSString *existing = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("notesAsString"));')
                lines.append(f'        NSString *combined;')
                lines.append(f'        if (existing && [existing length] > 0) {{')
                lines.append(f'            combined = [NSString stringWithFormat:@"%@\\n%@", existing, opts[@"append-notes"]];')
                lines.append(f'        }} else {{')
                lines.append(f'            combined = opts[@"append-notes"];')
                lines.append(f'        }}')
                lines.append(f'        ((void (*)(id, SEL, id))objc_msgSend)(changeItem, sel_registerName("{setter}"), combined);')
                lines.append(f'    }} else if (opts[@"{flag}"]) {{')
            else:
                lines.append(f'    if (opts[@"{flag}"]) {{')
            lines.append(f'        ((void (*)(id, SEL, id))objc_msgSend)(changeItem, sel_registerName("{setter}"), opts[@"{flag}"]);')
            lines.append(f'    }}')
        elif arg_type == "bool":
            lines.append(f'    if (opts[@"{flag}"]) {{')
            lines.append(f'        BOOL val = parseBoolString(opts[@"{flag}"]);')
            lines.append(f'        ((void (*)(id, SEL, BOOL))objc_msgSend)(changeItem, sel_registerName("{setter}"), val);')
            lines.append(f'    }}')
        elif arg_type == "uint":
            lines.append(f'    if (opts[@"{flag}"]) {{')
            lines.append(f'        NSUInteger val = [opts[@"{flag}"] integerValue];')
            lines.append(f'        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(changeItem, sel_registerName("{setter}"), val);')
            lines.append(f'    }}')
        elif arg_type == "int":
            lines.append(f'    if (opts[@"{flag}"]) {{')
            lines.append(f'        NSInteger val = [opts[@"{flag}"] integerValue];')
            lines.append(f'        ((void (*)(id, SEL, NSInteger))objc_msgSend)(changeItem, sel_registerName("{setter}"), val);')
            lines.append(f'    }}')
        elif arg_type == "datecomps":
            lines.append(f'    if (opts[@"{flag}"]) {{')
            lines.append(f'        NSDateComponents *comps = stringToDateComps(opts[@"{flag}"]);')
            lines.append(f'        ((void (*)(id, SEL, id))objc_msgSend)(changeItem, sel_registerName("{setter}"), comps);')
            lines.append(f'    }}')

    # URL setter via attachmentContext
    lines.append('    if (opts[@"url"]) {')
    lines.append('        NSURL *url = [NSURL URLWithString:opts[@"url"]];')
    lines.append('        if (url) {')
    lines.append('            id attCtx = ((id (*)(id, SEL))objc_msgSend)(changeItem, sel_registerName("attachmentContext"));')
    lines.append('            ((void (*)(id, SEL, id))objc_msgSend)(attCtx, sel_registerName("setURLAttachmentWithURL:"), url);')
    lines.append('        }')
    lines.append('    }')
    lines.append('    if (opts[@"clear-url"]) {')
    lines.append('        id attCtx = ((id (*)(id, SEL))objc_msgSend)(changeItem, sel_registerName("attachmentContext"));')
    lines.append('        ((void (*)(id, SEL))objc_msgSend)(attCtx, sel_registerName("removeURLAttachments"));')
    lines.append('    }')

    # Special operations
    for flag, method in SPECIAL_WRITE_OPS.items():
        lines.append(f'    if (opts[@"{flag}"]) {{')
        lines.append(f'        ((void (*)(id, SEL))objc_msgSend)(changeItem, sel_registerName("{method}"));')
        lines.append(f'    }}')

    # Reparenting via --parent-id
    lines.extend([
        '',
        '    // Reparent: --parent-id',
        '    if (parentID) {',
        '        // Validate no self-parenting (update-specific)',
        '        id remObjID = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("objectID"));',
        '        id parentRem = findReminderByID(store, parentID);',
        '        if (!parentRem) errorExit([NSString stringWithFormat:@"Parent not found with id: %@", parentID]);',
        '        id parentObjID = ((id (*)(id, SEL))objc_msgSend)(parentRem, sel_registerName("objectID"));',
        '        if ([objectIDToString(remObjID) isEqualToString:objectIDToString(parentObjID)]) {',
        '            errorExit(@"Cannot set a reminder as its own parent");',
        '        }',
        '',
        '        // Get the list for reparenting using shared helper',
        '        id remListID = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("listID"));',
        '        id targetList = findListByObjectID(store, remListID);',
        '        if (!targetList) errorExit(@"Could not find list for reparenting");',
        '',
        '        id listCI = ((id (*)(id, SEL, id))objc_msgSend)(',
        '            saveReq, sel_registerName("updateList:"), targetList);',
        '',
        '        reparentChangeItem(store, saveReq, listCI, changeItem, parentID);',
        '    }',
    ])

    # Move to different list via --to-list
    lines.extend([
        '',
        '    // Move to different list: --to-list',
        '    NSString *toListName = opts[@"to-list"];',
        '    if (toListName) {',
        '        id destList = findList(store, toListName);',
        '        if (!destList) errorExit([NSString stringWithFormat:@"Destination list not found: %@", toListName]);',
        '',
        '        id destListCI = ((id (*)(id, SEL, id))objc_msgSend)(',
        '            saveReq, sel_registerName("updateList:"), destList);',
        '',
        '        // Use initWithReminderChangeItem:insertIntoListChangeItem: to move',
        '        Class REMReminderCIClass = NSClassFromString(@"REMReminderChangeItem");',
        '        id moveCI = ((id (*)(id, SEL, id, id))objc_msgSend)(',
        '            [REMReminderCIClass alloc],',
        '            sel_registerName("initWithReminderChangeItem:insertIntoListChangeItem:"),',
        '            changeItem, destListCI);',
        '        if (!moveCI) errorExit(@"Failed to create move operation");',
        '    }',
    ])

    lines.extend([
        '',
        '    NSError *error = nil;',
        '    ((BOOL (*)(id, SEL, id*))objc_msgSend)(',
        '        saveReq, sel_registerName("saveSynchronouslyWithError:"), &error);',
        '    if (error) errorExit([NSString stringWithFormat:@"Save failed: %@", error]);',
        '',
        '    // Re-fetch and return updated state',
        '    id updated = findReminderByID(store, remID);',
        '    if (updated) printJSON(reminderToDict(updated));',
        '    else fprintf(stderr, "Updated successfully\\n");',
        '    return 0;',
        '}',
    ])
    return '\n'.join(lines)


def generate_add_setters():
    """Generate the optional property setters for the add command."""
    lines = []
    for flag, (setter, arg_type) in REMINDER_WRITE_OPS.items():
        if flag == "title":
            continue  # Title is already set via addReminderWithTitle:
        if flag == "url":
            lines.append(f'    if (opts[@"url"]) {{')
            lines.append(f'        NSURL *url = [NSURL URLWithString:opts[@"url"]];')
            lines.append(f'        if (url) {{')
            lines.append(f'            id attCtx = ((id (*)(id, SEL))objc_msgSend)(newRem, sel_registerName("attachmentContext"));')
            lines.append(f'            ((void (*)(id, SEL, id))objc_msgSend)(attCtx, sel_registerName("setURLAttachmentWithURL:"), url);')
            lines.append(f'        }}')
            lines.append(f'    }}')
            continue
        if arg_type == "string":
            lines.append(f'    if (opts[@"{flag}"]) {{')
            lines.append(f'        ((void (*)(id, SEL, id))objc_msgSend)(newRem, sel_registerName("{setter}"), opts[@"{flag}"]);')
            lines.append(f'    }}')
        elif arg_type == "bool":
            lines.append(f'    if (opts[@"{flag}"]) {{')
            lines.append(f'        BOOL val = parseBoolString(opts[@"{flag}"]);')
            lines.append(f'        ((void (*)(id, SEL, BOOL))objc_msgSend)(newRem, sel_registerName("{setter}"), val);')
            lines.append(f'    }}')
        elif arg_type == "uint":
            lines.append(f'    if (opts[@"{flag}"]) {{')
            lines.append(f'        NSUInteger val = [opts[@"{flag}"] integerValue];')
            lines.append(f'        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(newRem, sel_registerName("{setter}"), val);')
            lines.append(f'    }}')
        elif arg_type == "int":
            lines.append(f'    if (opts[@"{flag}"]) {{')
            lines.append(f'        NSInteger val = [opts[@"{flag}"] integerValue];')
            lines.append(f'        ((void (*)(id, SEL, NSInteger))objc_msgSend)(newRem, sel_registerName("{setter}"), val);')
            lines.append(f'    }}')
        elif arg_type == "datecomps":
            lines.append(f'    if (opts[@"{flag}"]) {{')
            lines.append(f'        NSDateComponents *comps = stringToDateComps(opts[@"{flag}"]);')
            lines.append(f'        ((void (*)(id, SEL, id))objc_msgSend)(newRem, sel_registerName("{setter}"), comps);')
            lines.append(f'    }}')
    return '\n'.join(lines)


# --- Legacy emitters (not called by main(), kept for re-scaffolding) ---

def generate_batch_command():
    return '''
static int cmdBatch(id store) {
    // Read JSON from stdin (max 1MB)
    NSFileHandle *input = [NSFileHandle fileHandleWithStandardInput];
    NSData *inputData = [input readDataToEndOfFile];
    if (inputData.length > 1024 * 1024) {
        errorExit(@"Batch input exceeds 1MB limit");
    }
    if (inputData.length == 0) {
        errorExit(@"No input provided on stdin");
    }

    NSError *parseError = nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:inputData options:0 error:&parseError];
    if (parseError) errorExit([NSString stringWithFormat:@"Invalid JSON: %@", parseError]);
    if (![parsed isKindOfClass:[NSArray class]]) errorExit(@"Expected JSON array");

    NSArray *ops = (NSArray *)parsed;
    NSSet *validOps = [NSSet setWithArray:@[@"add", @"complete", @"update", @"delete",
        @"add-tag", @"remove-tag"]];
    NSSet *validKeys = [NSSet setWithArray:@[@"op", @"title", @"id", @"list",
        @"notes", @"append-notes", @"priority", @"flagged", @"completed",
        @"due-date", @"start-date", @"url", @"clear-url", @"remove-parent", @"remove-from-list",
        @"parent-id", @"to-list", @"tag"]];

    // Validate all operations first
    for (NSUInteger i = 0; i < ops.count; i++) {
        if (![ops[i] isKindOfClass:[NSDictionary class]]) {
            errorExit([NSString stringWithFormat:@"Operation %lu is not an object", (unsigned long)i]);
        }
        NSDictionary *op = ops[i];
        NSString *opType = op[@"op"];
        if (!opType || ![validOps containsObject:opType]) {
            errorExit([NSString stringWithFormat:@"Operation %lu has invalid op: %@", (unsigned long)i, opType ?: @"(missing)"]);
        }
        // Check for unknown keys
        for (NSString *key in op) {
            if (![validKeys containsObject:key]) {
                errorExit([NSString stringWithFormat:@"Operation %lu has unknown key: %@", (unsigned long)i, key]);
            }
        }
        // Require id for non-add ops
        if (![opType isEqualToString:@"add"]) {
            if (!op[@"id"] || [op[@"id"] length] == 0) {
                errorExit([NSString stringWithFormat:@"Operation %lu (%@) requires id", (unsigned long)i, opType]);
            }
        } else {
            if (!op[@"title"]) {
                errorExit([NSString stringWithFormat:@"Operation %lu (add) requires title", (unsigned long)i]);
            }
        }
    }

    // Create single save request
    id saveReq = ((id (*)(id, SEL, id))objc_msgSend)(
        [REMSaveRequestClass alloc], sel_registerName("initWithStore:"), store);

    NSMutableArray *results = [NSMutableArray array];

    for (NSDictionary *op in ops) {
        NSString *opType = op[@"op"];
        NSString *opTitle = op[@"title"];
        NSString *opID = op[@"id"];
        NSString *opList = op[@"list"];

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

        } else {
            // Find the reminder by ID
            id rem = findReminderByID(store, opID);
            if (!rem) errorExit([NSString stringWithFormat:@"Reminder not found with id: %@", opID]);

            id remObjID = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("objectID"));
            NSString *remIDStr = objectIDToString(remObjID);

            id changeItem = ((id (*)(id, SEL, id))objc_msgSend)(
                saveReq, sel_registerName("updateReminder:"), rem);

            if ([opType isEqualToString:@"complete"]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(changeItem, sel_registerName("setCompleted:"), YES);
                [results addObject:@{@"op": @"complete", @"id": remIDStr ?: @"", @"status": @"ok"}];

            } else if ([opType isEqualToString:@"delete"]) {
                ((void (*)(id, SEL))objc_msgSend)(changeItem, sel_registerName("removeFromList"));
                [results addObject:@{@"op": @"delete", @"id": remIDStr ?: @"", @"status": @"ok"}];

            } else if ([opType isEqualToString:@"update"]) {
                if (op[@"title"]) ((void (*)(id, SEL, id))objc_msgSend)(changeItem, sel_registerName("setTitleAsString:"), op[@"title"]);
                if (op[@"notes"]) ((void (*)(id, SEL, id))objc_msgSend)(changeItem, sel_registerName("setNotesAsString:"), op[@"notes"]);
                if (op[@"priority"]) ((void (*)(id, SEL, NSUInteger))objc_msgSend)(changeItem, sel_registerName("setPriority:"), [op[@"priority"] integerValue]);
                if (op[@"flagged"]) ((void (*)(id, SEL, NSInteger))objc_msgSend)(changeItem, sel_registerName("setFlagged:"), [op[@"flagged"] integerValue]);
                if (op[@"completed"]) {
                    BOOL val = [op[@"completed"] isEqualToString:@"true"];
                    ((void (*)(id, SEL, BOOL))objc_msgSend)(changeItem, sel_registerName("setCompleted:"), val);
                }
                if (op[@"due-date"]) ((void (*)(id, SEL, id))objc_msgSend)(changeItem, sel_registerName("setDueDateComponents:"), stringToDateComps(op[@"due-date"]));
                if (op[@"start-date"]) ((void (*)(id, SEL, id))objc_msgSend)(changeItem, sel_registerName("setStartDateComponents:"), stringToDateComps(op[@"start-date"]));
                if (op[@"url"]) { NSURL *u = [NSURL URLWithString:op[@"url"]]; if (u) { id attCtx = ((id (*)(id, SEL))objc_msgSend)(changeItem, sel_registerName("attachmentContext")); ((void (*)(id, SEL, id))objc_msgSend)(attCtx, sel_registerName("setURLAttachmentWithURL:"), u); } }
                if (op[@"remove-parent"]) ((void (*)(id, SEL))objc_msgSend)(changeItem, sel_registerName("removeFromParentReminder"));
                if (op[@"remove-from-list"]) ((void (*)(id, SEL))objc_msgSend)(changeItem, sel_registerName("removeFromList"));
                [results addObject:@{@"op": @"update", @"id": remIDStr ?: @"", @"status": @"ok"}];
            }
        }
    }

    NSError *error = nil;
    ((BOOL (*)(id, SEL, id*))objc_msgSend)(
        saveReq, sel_registerName("saveSynchronouslyWithError:"), &error);
    if (error) errorExit([NSString stringWithFormat:@"Save failed: %@", error]);

    printJSON(results);
    return 0;
}
'''



def generate_delete_command():
    return '''
static int cmdDelete(id store, NSString *remID) {
    id rem = findReminderByID(store, remID);
    if (!rem) errorExit([NSString stringWithFormat:@"Reminder not found with id: %@", remID]);

    id saveReq = ((id (*)(id, SEL, id))objc_msgSend)(
        [REMSaveRequestClass alloc], sel_registerName("initWithStore:"), store);

    id changeItem = ((id (*)(id, SEL, id))objc_msgSend)(
        saveReq, sel_registerName("updateReminder:"), rem);

    ((void (*)(id, SEL))objc_msgSend)(changeItem, sel_registerName("removeFromList"));

    NSError *error = nil;
    ((BOOL (*)(id, SEL, id*))objc_msgSend)(
        saveReq, sel_registerName("saveSynchronouslyWithError:"), &error);
    if (error) errorExit([NSString stringWithFormat:@"Save failed: %@", error]);

    printJSON(@{@"id": remID, @"deleted": @YES});
    return 0;
}
'''


def generate_complete_command():
    return '''
static int cmdComplete(id store, NSString *remID) {
    id rem = findReminderByID(store, remID);
    if (!rem) errorExit([NSString stringWithFormat:@"Reminder not found with id: %@", remID]);

    id saveReq = ((id (*)(id, SEL, id))objc_msgSend)(
        [REMSaveRequestClass alloc], sel_registerName("initWithStore:"), store);

    id changeItem = ((id (*)(id, SEL, id))objc_msgSend)(
        saveReq, sel_registerName("updateReminder:"), rem);

    ((void (*)(id, SEL, BOOL))objc_msgSend)(changeItem, sel_registerName("setCompleted:"), YES);

    NSError *error = nil;
    ((BOOL (*)(id, SEL, id*))objc_msgSend)(
        saveReq, sel_registerName("saveSynchronouslyWithError:"), &error);
    if (error) errorExit([NSString stringWithFormat:@"Save failed: %@", error]);

    printJSON(@{@"id": remID, @"completed": @YES});
    return 0;
}
'''


def generate_install_skill_command():
    return '''
// --- Install Skill ---

static int cmdInstallSkill(BOOL installClaude, BOOL installAgents, BOOL force) {
    char execPath[PATH_MAX];
    uint32_t size = sizeof(execPath);
    if (_NSGetExecutablePath(execPath, &size) != 0) {
        fprintf(stderr, "Error: could not determine executable path\\n");
        return 1;
    }
    char realPath[PATH_MAX];
    if (!realpath(execPath, realPath)) {
        fprintf(stderr, "Error: could not resolve executable path\\n");
        return 1;
    }

    NSString *binaryPath = [NSString stringWithUTF8String:realPath];
    NSString *binDir = [binaryPath stringByDeletingLastPathComponent];

    NSArray *candidates = @[
        [[binDir stringByDeletingLastPathComponent] stringByAppendingPathComponent:@".agents/skills/apple-reminders/SKILL.md"],
        [[binDir stringByAppendingPathComponent:@".."] stringByAppendingPathComponent:@".agents/skills/apple-reminders/SKILL.md"],
        [binDir stringByAppendingPathComponent:@".agents/skills/apple-reminders/SKILL.md"],
    ];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *sourcePath = nil;
    for (NSString *candidate in candidates) {
        NSString *resolved = [candidate stringByStandardizingPath];
        if ([fm fileExistsAtPath:resolved]) {
            sourcePath = resolved;
            break;
        }
    }

    if (!sourcePath) {
        fprintf(stderr, "Error: could not find SKILL.md relative to binary at %s\\n", realPath);
        fprintf(stderr, "Searched:\\n");
        for (NSString *candidate in candidates) {
            fprintf(stderr, "  %s\\n", [[candidate stringByStandardizingPath] UTF8String]);
        }
        return 1;
    }

    NSString *home = NSHomeDirectory();

    NSMutableArray *targetDirs = [NSMutableArray array];
    if (installClaude) [targetDirs addObject:[home stringByAppendingPathComponent:@".claude/skills/apple-reminders"]];
    if (installAgents) [targetDirs addObject:[home stringByAppendingPathComponent:@".agents/skills/apple-reminders"]];

    NSError *error = nil;
    int failures = 0;
    for (NSString *dir in targetDirs) {
        NSString *path = [dir stringByAppendingPathComponent:@"SKILL.md"];
        if ([fm fileExistsAtPath:path]) {
            if (!force) {
                fprintf(stderr, "Error: %s already exists (use --force to overwrite)\\n", [path UTF8String]);
                failures++;
                continue;
            }
            [fm removeItemAtPath:path error:nil];
        }
        if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&error]) {
            fprintf(stderr, "Error: could not create directory %s: %s\\n",
                [dir UTF8String], [[error localizedDescription] UTF8String]);
            failures++;
            continue;
        }
        if (![fm createSymbolicLinkAtPath:path withDestinationPath:sourcePath error:&error]) {
            fprintf(stderr, "Error: could not create symlink: %s\\n",
                [[error localizedDescription] UTF8String]);
            failures++;
            continue;
        }
        printf("Installed skill: %s -> %s\\n", [path UTF8String], [sourcePath UTF8String]);
    }

    return failures > 0 ? 1 : 0;
}
'''


def generate_usage():
    return '''
static void usage(void) {
    fprintf(stderr, "Usage:\\n");
    fprintf(stderr, "  reminderkit lists\\n");
    fprintf(stderr, "  reminderkit list --name <name> [--include-completed] [--tag <tags>] [--exclude-tag <tags>] [--has-url]\\n");
    fprintf(stderr, "  reminderkit search [--title <title>] [--url <url>] [--list <name>] [--tag <tags>] [--exclude-tag <tags>] [--has-url]\\n");
    fprintf(stderr, "  reminderkit search --id <id>\\n");
    fprintf(stderr, "  reminderkit get [--title <title>] [--url <url>] [--list <name>] [--tag <tags>] [--exclude-tag <tags>] [--has-url]  (alias for search)\\n");
    fprintf(stderr, "  reminderkit get --id <id>\\n");
    fprintf(stderr, "  reminderkit subtasks --title <title> [--list <name>]\\n");
    fprintf(stderr, "  reminderkit add --title <title> [--list <name>] [--notes <value>] [--completed <value>] [--priority <value>] [--flagged <value>] [--due-date <value>] [--start-date <value>] [--url <value>] [--parent-id <id>]\\n");
    fprintf(stderr, "  reminderkit update --id <id> [--title <value>] [--list <name>] [--notes <value>] [--append-notes <value>] [--completed <value>] [--priority <value>] [--flagged <value>] [--due-date <value>] [--start-date <value>] [--url <value>] [--clear-url] [--remove-parent] [--remove-from-list] [--parent-id <id>] [--to-list <name>]\\n");
    fprintf(stderr, "  reminderkit complete --id <id> [--list <name>]\\n");
    fprintf(stderr, "  reminderkit delete --id <id> [--list <name>]\\n");
    fprintf(stderr, "  reminderkit add-tag --id <id> --tag <tag-name>\\n");
    fprintf(stderr, "  reminderkit remove-tag --id <id> --tag <tag-name>\\n");
    fprintf(stderr, "  reminderkit link-note --id <id> --note-id <note-id>\\n");
    fprintf(stderr, "  reminderkit list-sections --name <list-name>\\n");
    fprintf(stderr, "  reminderkit create-section --name <list-name> --section <section-name>\\n");
    fprintf(stderr, "  reminderkit create-list --name <name>\\n");
    fprintf(stderr, "  reminderkit rename-list --old-name <old-name> --new-name <new-name>\\n");
    fprintf(stderr, "  reminderkit delete-list --name <name>\\n");
    fprintf(stderr, "  reminderkit batch  (reads JSON array from stdin)\\n");
    fprintf(stderr, "\\n  Output shaping (applies to any command that returns JSON):\\n");
    fprintf(stderr, "    --fields <csv>      comma-separated list of fields to emit (preserves order)\\n");
    fprintf(stderr, "    --full              emit all fields including default-valued ones; use legacy emoji id\\n");
    fprintf(stderr, "                        (default: omit default-valued fields; emit bare-UUID id + uri)\\n");
    fprintf(stderr, "  IDs: --id accepts either a bare UUID or the full x-apple-reminderkit:// form\\n");
    fprintf(stderr, "\\n  Skill management:\\n");
    fprintf(stderr, "  reminderkit install-skill [--claude] [--agents] [--force]\\n");
    fprintf(stderr, "\\n  Testing:\\n");
    fprintf(stderr, "  reminderkit test\\n");
    fprintf(stderr, "\\n  Report issues:\\n");
    fprintf(stderr, "  gh api repos/johnmatthewtennant/reminderkit-cli/issues --method POST -f title=\\"...\\" -f body=\\"...\\"\\n");
}
'''


def generate_main():
    return '''
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) { usage(); return 1; }

        loadFramework();

        NSString *command = [NSString stringWithUTF8String:argv[1]];

        // Parse arguments
        NSMutableArray *positional = [NSMutableArray array];
        NSMutableDictionary *opts = [NSMutableDictionary dictionary];
        BOOL includeCompleted = NO;
        BOOL hasURL = NO;

        for (int i = 2; i < argc; i++) {
            NSString *arg = [NSString stringWithUTF8String:argv[i]];
            if ([arg hasPrefix:@"--"]) {
                NSString *flag = [arg substringFromIndex:2];
                if ([flag isEqualToString:@"include-completed"] ||
                    [flag isEqualToString:@"remove-parent"] ||
                    [flag isEqualToString:@"remove-from-list"] ||
                    [flag isEqualToString:@"help"] ||
                    [flag isEqualToString:@"clear-url"] ||
                    [flag isEqualToString:@"has-url"] ||
                    [flag isEqualToString:@"all"] ||
                    [flag isEqualToString:@"claude"] ||
                    [flag isEqualToString:@"agents"] ||
                    [flag isEqualToString:@"force"] ||
                    [flag isEqualToString:@"full"]) {
                    if ([flag isEqualToString:@"include-completed"]) includeCompleted = YES;
                    if ([flag isEqualToString:@"has-url"]) hasURL = YES;
                    opts[flag] = @"true";
                } else if (i + 1 < argc) {
                    opts[flag] = [NSString stringWithUTF8String:argv[++i]];
                }
            } else {
                [positional addObject:arg];
            }
        }

        NSString *kwTitle = opts[@"title"];
        NSString *kwName = opts[@"name"];
        NSString *kwTag = opts[@"tag"];
        NSString *kwSection = opts[@"section"];
        NSString *kwOldName = opts[@"old-name"];
        NSString *kwNewName = opts[@"new-name"];

        NSString *listName = opts[@"list"];
        id store = getStore();

        // Reject unexpected positional arguments
        if (positional.count > 0 &&
            ![command isEqualToString:@"batch"] &&
            ![command isEqualToString:@"lists"] &&
            ![command isEqualToString:@"install-skill"] &&
            ![command isEqualToString:@"test"] &&
            ![command isEqualToString:@"help"] &&
            ![command isEqualToString:@"--help"] &&
            ![command isEqualToString:@"-h"]) {
            fprintf(stderr, "Error: unexpected argument '%s'. All arguments must use --flag syntax.\\n", [positional[0] UTF8String]);
            usage();
            return 1;
        }

        if ([command isEqualToString:@"lists"]) {
            return cmdLists(store);

        } else if ([command isEqualToString:@"list"]) {
            if (!kwName) { fprintf(stderr, "Error: --name required\\n"); usage(); return 1; }
            return cmdList(store, kwName, includeCompleted, opts[@"tag"], opts[@"exclude-tag"], hasURL);

        } else if ([command isEqualToString:@"search"] || [command isEqualToString:@"get"]) {
            if (opts[@"id"] && [opts[@"id"] length] > 0) {
                return cmdGetByID(store, opts[@"id"]);
            }
            if (!kwTitle && !opts[@"url"] && !kwTag && !opts[@"exclude-tag"] && !hasURL && !listName) { fprintf(stderr, "Error: --title, --url, --id, --tag, --exclude-tag, --has-url, or --list required\\n"); usage(); return 1; }
            return cmdGet(store, kwTitle, listName, opts[@"url"], kwTag, opts[@"exclude-tag"], hasURL);

        } else if ([command isEqualToString:@"subtasks"]) {
            if (!kwTitle) { fprintf(stderr, "Error: --title required\\n"); usage(); return 1; }
            return cmdSubtasks(store, kwTitle, listName);

        } else if ([command isEqualToString:@"add"]) {
            if (!kwTitle) { fprintf(stderr, "Error: --title required\\n"); usage(); return 1; }
            return cmdAdd(store, kwTitle, listName, opts);

        } else if ([command isEqualToString:@"update"]) {
            if (!opts[@"id"] || [opts[@"id"] length] == 0) { fprintf(stderr, "Error: --id required\\n"); usage(); return 1; }
            return cmdUpdate(store, listName, opts);

        } else if ([command isEqualToString:@"complete"]) {
            if (!opts[@"id"] || [opts[@"id"] length] == 0) { fprintf(stderr, "Error: --id required\\n"); usage(); return 1; }
            return cmdComplete(store, opts[@"id"]);

        } else if ([command isEqualToString:@"delete"]) {
            if (!opts[@"id"] || [opts[@"id"] length] == 0) { fprintf(stderr, "Error: --id required\\n"); usage(); return 1; }
            return cmdDelete(store, opts[@"id"]);

        } else if ([command isEqualToString:@"batch"]) {
            return cmdBatch(store);

        } else if ([command isEqualToString:@"add-tag"]) {
            if (!opts[@"id"] || [opts[@"id"] length] == 0) { fprintf(stderr, "Error: --id required\\n"); usage(); return 1; }
            if (!kwTag) { fprintf(stderr, "Error: --tag required\\n"); usage(); return 1; }
            return cmdAddTag(store, opts[@"id"], kwTag);

        } else if ([command isEqualToString:@"remove-tag"]) {
            if (!opts[@"id"] || [opts[@"id"] length] == 0) { fprintf(stderr, "Error: --id required\\n"); usage(); return 1; }
            if (!kwTag) { fprintf(stderr, "Error: --tag required\\n"); usage(); return 1; }
            return cmdRemoveTag(store, opts[@"id"], kwTag);

        } else if ([command isEqualToString:@"link-note"]) {
            if (!opts[@"id"] || [opts[@"id"] length] == 0) { fprintf(stderr, "Error: --id required\\n"); usage(); return 1; }
            if (!opts[@"note-id"] || [opts[@"note-id"] length] == 0) { fprintf(stderr, "Error: --note-id required\\n"); usage(); return 1; }
            return cmdLinkNote(store, opts[@"id"], opts[@"note-id"]);

        } else if ([command isEqualToString:@"list-sections"]) {
            if (!kwName) { fprintf(stderr, "Error: --name required\\n"); usage(); return 1; }
            return cmdListSections(store, kwName);

        } else if ([command isEqualToString:@"create-section"]) {
            if (!kwName || !kwSection) { fprintf(stderr, "Error: --name and --section required\\n"); usage(); return 1; }
            return cmdCreateSection(store, kwName, kwSection);

        } else if ([command isEqualToString:@"create-list"]) {
            if (!kwName) { fprintf(stderr, "Error: --name required\\n"); usage(); return 1; }
            return cmdCreateList(store, kwName);

        } else if ([command isEqualToString:@"rename-list"]) {
            if (!kwOldName || !kwNewName) { fprintf(stderr, "Error: --old-name and --new-name required\\n"); usage(); return 1; }
            return cmdRenameList(store, kwOldName, kwNewName);

        } else if ([command isEqualToString:@"delete-list"]) {
            if (!kwName) { fprintf(stderr, "Error: --name required\\n"); usage(); return 1; }
            return cmdDeleteList(store, kwName);

        } else if ([command isEqualToString:@"install-skill"]) {
            BOOL wantClaude = [opts[@"claude"] isEqualToString:@"true"];
            BOOL wantAgents = [opts[@"agents"] isEqualToString:@"true"];
            BOOL force = [opts[@"force"] isEqualToString:@"true"];
            if (!wantClaude && !wantAgents) { wantClaude = YES; wantAgents = YES; }
            return cmdInstallSkill(wantClaude, wantAgents, force);

        } else if ([command isEqualToString:@"test"]) {
            return cmdTest(store);

        } else if ([command isEqualToString:@"help"] || [command isEqualToString:@"--help"] || [command isEqualToString:@"-h"]) {
            usage();
            return 0;

        } else {
            fprintf(stderr, "Unknown command: %s\\n", [command UTF8String]);
            usage();
            return 1;
        }
    }
}
'''


def main():
    """Generate reminderkit-generated.m — only the config-driven portions.

    Handwritten commands, tests, usage, and main() live in separate files
    (reminderkit-handwritten.m, reminderkit-tests.m, reminderkit.m) and are
    not produced by this generator.
    """
    output = []
    output.append(generate_header())
    output.append('')
    output.append('// --- Reminder Serialization (generated from REMINDER_READ_PROPS) ---')
    output.append('')
    output.append(generate_reminder_to_dict())
    output.append('')
    output.append(generate_commands())
    output.append('')
    output.append('// --- Update Command (generated from REMINDER_WRITE_OPS) ---')
    output.append('')
    output.append(generate_update_command())
    output.append('')
    output.append(generate_complete_command())
    output.append('')
    output.append(generate_delete_command())
    output.append('')
    output.append('// --- Link Note Command ---')
    output.append(generate_link_note_command())

    print('\n'.join(output))


if __name__ == '__main__':
    main()
