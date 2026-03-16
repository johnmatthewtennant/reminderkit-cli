// Originally scaffolded by generate-cli.py — now maintained manually

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <mach-o/dyld.h>

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
    fprintf(stderr, "Error: %s\n", [msg UTF8String]);
    exit(1);
}

static NSString *objectIDToString(id objID) {
    if (!objID) return nil;
    return [[objID description] stringByReplacingOccurrencesOfString:@"<" withString:@""]
        ? [objID description] : @"(unknown)";
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

static void printJSON(id obj) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:obj
        options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:&error];
    if (error) errorExit([error localizedDescription]);
    printf("%s\n", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
}

// --- List Helpers ---

static NSArray *fetchLists(id store) {
    NSError *error = nil;
    NSArray *lists = ((id (*)(id, SEL, id*))objc_msgSend)(
        store, sel_registerName("fetchEligibleDefaultListsWithError:"), &error);
    if (error) {
        if ([[error domain] isEqualToString:@"NSCocoaErrorDomain"] && [error code] == 4097) {
            fprintf(stderr, "Error: Reminders access denied.\n\n");
            fprintf(stderr, "Your terminal app needs permission to access Reminders.\n\n");
            fprintf(stderr, "1. Grant permission (triggers macOS prompt):\n");
            fprintf(stderr, "   osascript -e 'tell application \"Reminders\" to get name of every list'\n\n");
            fprintf(stderr, "2. If previously denied, reset first, then re-run step 1:\n");
            fprintf(stderr, "   tccutil reset Reminders <bundle-id>\n\n");
            fprintf(stderr, "   Find your terminal's bundle ID:\n");
            fprintf(stderr, "   osascript -e 'id of app \"iTerm\"'  (replace iTerm with your terminal app name)\n\n");
            fprintf(stderr, "3. Then retry: reminderkit lists\n");
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
    return nil;
}

static id findReminderByID(id store, NSString *idString) {
    NSArray *lists = fetchLists(store);
    for (id list in lists) {
        NSArray *rems = fetchReminders(store, list, YES);
        for (id rem in rems) {
            id objID = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("objectID"));
            NSString *idStr = objectIDToString(objID);
            if (idStr && [idStr isEqualToString:idString]) return rem;
        }
    }
    return nil;
}


// --- Reminder Serialization (generated from REMINDER_READ_PROPS) ---

static NSDictionary *reminderToDict(id rem) {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];

    @try {
        NSString *val_title = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("titleAsString"));
        if (val_title) dict[@"title"] = val_title;
    } @catch (NSException *e) {}

    @try {
        NSString *val_notes = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("notesAsString"));
        if (val_notes) dict[@"notes"] = val_notes;
    } @catch (NSException *e) {}

    @try {
        BOOL val_completed = ((BOOL (*)(id, SEL))objc_msgSend)(rem, sel_registerName("isCompleted"));
        dict[@"completed"] = @(val_completed);
    } @catch (NSException *e) {}

    @try {
        NSUInteger val_priority = ((NSUInteger (*)(id, SEL))objc_msgSend)(rem, sel_registerName("priority"));
        dict[@"priority"] = @(val_priority);
    } @catch (NSException *e) {}

    @try {
        NSInteger val_flagged = ((NSInteger (*)(id, SEL))objc_msgSend)(rem, sel_registerName("flagged"));
        dict[@"flagged"] = @(val_flagged);
    } @catch (NSException *e) {}

    @try {
        BOOL val_allDay = ((BOOL (*)(id, SEL))objc_msgSend)(rem, sel_registerName("allDay"));
        dict[@"allDay"] = @(val_allDay);
    } @catch (NSException *e) {}

    @try {
        BOOL val_isOverdue = ((BOOL (*)(id, SEL))objc_msgSend)(rem, sel_registerName("isOverdue"));
        dict[@"isOverdue"] = @(val_isOverdue);
    } @catch (NSException *e) {}

    @try {
        BOOL val_isRecurrent = ((BOOL (*)(id, SEL))objc_msgSend)(rem, sel_registerName("isRecurrent"));
        dict[@"isRecurrent"] = @(val_isRecurrent);
    } @catch (NSException *e) {}

    @try {
        id val_id = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("objectID"));
        if (val_id) dict[@"id"] = objectIDToString(val_id);
    } @catch (NSException *e) {}

    @try {
        id val_listID = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("listID"));
        if (val_listID) dict[@"listID"] = objectIDToString(val_listID);
    } @catch (NSException *e) {}

    @try {
        id val_parentID = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("parentReminderID"));
        if (val_parentID) dict[@"parentID"] = objectIDToString(val_parentID);
    } @catch (NSException *e) {}

    @try {
        NSDateComponents *val_dueDate = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("dueDateComponents"));
        if (val_dueDate) dict[@"dueDate"] = dateCompsToString(val_dueDate);
    } @catch (NSException *e) {}

    @try {
        NSDateComponents *val_startDate = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("startDateComponents"));
        if (val_startDate) dict[@"startDate"] = dateCompsToString(val_startDate);
    } @catch (NSException *e) {}

    @try {
        NSDate *val_createdAt = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("creationDate"));
        if (val_createdAt) dict[@"createdAt"] = dateToISO(val_createdAt);
    } @catch (NSException *e) {}

    @try {
        NSDate *val_modifiedAt = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("lastModifiedDate"));
        if (val_modifiedAt) dict[@"modifiedAt"] = dateToISO(val_modifiedAt);
    } @catch (NSException *e) {}

    @try {
        NSDate *val_completedAt = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("completionDate"));
        if (val_completedAt) dict[@"completedAt"] = dateToISO(val_completedAt);
    } @catch (NSException *e) {}

    @try {
        NSSet *tags = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("hashtags"));
        if (tags && tags.count > 0) {
            NSMutableArray *tagNames = [NSMutableArray array];
            for (id tag in tags) {
                NSString *name = ((id (*)(id, SEL))objc_msgSend)(tag, sel_registerName("name"));
                if (name) [tagNames addObject:name];
            }
            dict[@"hashtags"] = tagNames;
        }
    } @catch (NSException *e) {}

    @try {
        NSString *val_timeZone = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("timeZone"));
        if (val_timeZone) dict[@"timeZone"] = val_timeZone;
    } @catch (NSException *e) {}

    @try {
        NSURL *val_url = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("icsUrl"));
        if (val_url) dict[@"url"] = [val_url absoluteString];
    } @catch (NSException *e) {}

    return dict;
}


// --- Commands ---

static int cmdLists(id store) {
    NSArray *lists = fetchLists(store);
    NSMutableArray *result = [NSMutableArray array];
    for (id list in lists) {
        id storage = ((id (*)(id, SEL))objc_msgSend)(list, sel_registerName("storage"));
        NSString *name = ((id (*)(id, SEL))objc_msgSend)(storage, sel_registerName("name"));
        id objID = ((id (*)(id, SEL))objc_msgSend)(list, sel_registerName("objectID"));
        [result addObject:@{@"name": name ?: @"", @"id": objectIDToString(objID) ?: @""}];
    }
    printJSON(result);
    return 0;
}

static int cmdList(id store, NSString *listName, BOOL includeCompleted) {
    id list = findList(store, listName);
    if (!list) errorExit([NSString stringWithFormat:@"List not found: %@", listName]);
    NSArray *rems = fetchReminders(store, list, includeCompleted);
    NSMutableArray *result = [NSMutableArray array];
    for (id rem in rems) {
        [result addObject:reminderToDict(rem)];
    }
    printJSON(result);
    return 0;
}

static int cmdGet(id store, NSString *title, NSString *listName) {
    id rem = findReminder(store, title, listName);
    if (!rem) errorExit([NSString stringWithFormat:@"Reminder not found: %@", title]);

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
    if (subtasks.count > 0) dict[@"subtasks"] = subtasks;

    printJSON(dict);
    return 0;
}

static int cmdSubtasks(id store, NSString *title, NSString *listName) {
    id rem = findReminder(store, title, listName);
    if (!rem) errorExit([NSString stringWithFormat:@"Reminder not found: %@", title]);

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

static int cmdAdd(id store, NSString *title, NSString *listName, NSDictionary *opts) {
    id list = listName ? findList(store, listName) : [fetchLists(store) firstObject];
    if (!list) errorExit(@"No list found");

    id listChangeItem = nil;
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
    if (opts[@"notes"]) {
        ((void (*)(id, SEL, id))objc_msgSend)(newRem, sel_registerName("setNotesAsString:"), opts[@"notes"]);
    }
    if (opts[@"completed"]) {
        BOOL val = [opts[@"completed"] isEqualToString:@"true"];
        ((void (*)(id, SEL, BOOL))objc_msgSend)(newRem, sel_registerName("setCompleted:"), val);
    }
    if (opts[@"priority"]) {
        NSUInteger val = [opts[@"priority"] integerValue];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(newRem, sel_registerName("setPriority:"), val);
    }
    if (opts[@"flagged"]) {
        NSInteger val = [opts[@"flagged"] integerValue];
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(newRem, sel_registerName("setFlagged:"), val);
    }
    if (opts[@"due-date"]) {
        NSDateComponents *comps = stringToDateComps(opts[@"due-date"]);
        ((void (*)(id, SEL, id))objc_msgSend)(newRem, sel_registerName("setDueDateComponents:"), comps);
    }
    if (opts[@"start-date"]) {
        NSDateComponents *comps = stringToDateComps(opts[@"start-date"]);
        ((void (*)(id, SEL, id))objc_msgSend)(newRem, sel_registerName("setStartDateComponents:"), comps);
    }
    if (opts[@"url"]) {
        NSURL *url = [NSURL URLWithString:opts[@"url"]];
        if (url) ((void (*)(id, SEL, id))objc_msgSend)(newRem, sel_registerName("setIcsUrl:"), url);
    }

    NSError *error = nil;
    BOOL saved = ((BOOL (*)(id, SEL, id*))objc_msgSend)(
        saveReq, sel_registerName("saveSynchronouslyWithError:"), &error);
    if (error) errorExit([NSString stringWithFormat:@"Save failed: %@", error]);

    // Re-fetch and return
    id created = findReminder(store, title, listName);
    if (created) printJSON(reminderToDict(created));
    else fprintf(stderr, "Created (but could not re-fetch)\n");
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
    BOOL saved = ((BOOL (*)(id, SEL, id*))objc_msgSend)(
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
    BOOL saved = ((BOOL (*)(id, SEL, id*))objc_msgSend)(
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
    BOOL saved = ((BOOL (*)(id, SEL, id*))objc_msgSend)(
        saveReq, sel_registerName("saveSynchronouslyWithError:"), &error);
    if (error) errorExit([NSString stringWithFormat:@"Save failed: %@", error]);

    printJSON(@{@"name": name, @"deleted": @YES});
    return 0;
}

static int cmdAddTag(id store, NSString *remID, NSString *tagName) {
    id rem = findReminderByID(store, remID);
    if (!rem) errorExit([NSString stringWithFormat:@"Reminder not found with id: %@", remID]);

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
    BOOL saved = ((BOOL (*)(id, SEL, id*))objc_msgSend)(
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
    BOOL saved = ((BOOL (*)(id, SEL, id*))objc_msgSend)(
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
                if (objID) d[@"id"] = objectIDToString(objID);
                [result addObject:d];
            }
        }
    } @catch (NSException *e) {
        fprintf(stderr, "Warning: could not enumerate sections: %s\n", [[e reason] UTF8String]);
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

    id sectionsCtx = ((id (*)(id, SEL))objc_msgSend)(listCI, sel_registerName("sectionsContextChangeItem"));
    if (!sectionsCtx) errorExit(@"Failed to get sections context");

    id listObjID = ((id (*)(id, SEL))objc_msgSend)(list, sel_registerName("objectID"));

    // Create a new section change item
    id newSection = ((id (*)(id, SEL, id, id, id))objc_msgSend)(
        [REMListSectionCIClass alloc],
        sel_registerName("initWithObjectID:displayName:insertIntoListChangeItem:"),
        nil, sectionName, listCI);

    if (!newSection) errorExit(@"Failed to create section");

    NSError *error = nil;
    BOOL saved = ((BOOL (*)(id, SEL, id*))objc_msgSend)(
        saveReq, sel_registerName("saveSynchronouslyWithError:"), &error);
    if (error) errorExit([NSString stringWithFormat:@"Save failed: %@", error]);

    printJSON(@{@"list": listName, @"section": sectionName, @"created": @YES});
    return 0;
}


// --- Update Command (generated from REMINDER_WRITE_OPS) ---

static int cmdUpdate(id store, NSString *listName, NSDictionary *opts) {
    NSString *remID = opts[@"id"];
    id rem = findReminderByID(store, remID);
    if (!rem) errorExit([NSString stringWithFormat:@"Reminder not found with id: %@", remID]);

    // Validate conflicting parent flags
    NSString *parentID = opts[@"parent-id"];
    BOOL removeParent = opts[@"remove-parent"] != nil;
    if (parentID && removeParent) {
        errorExit(@"Cannot specify both --parent-id and --remove-parent");
    }

    id saveReq = ((id (*)(id, SEL, id))objc_msgSend)(
        [REMSaveRequestClass alloc], sel_registerName("initWithStore:"), store);

    id changeItem = ((id (*)(id, SEL, id))objc_msgSend)(
        saveReq, sel_registerName("updateReminder:"), rem);

    if (opts[@"title"]) {
        ((void (*)(id, SEL, id))objc_msgSend)(changeItem, sel_registerName("setTitleAsString:"), opts[@"title"]);
    }
    if (opts[@"notes"]) {
        ((void (*)(id, SEL, id))objc_msgSend)(changeItem, sel_registerName("setNotesAsString:"), opts[@"notes"]);
    }
    if (opts[@"completed"]) {
        BOOL val = [opts[@"completed"] isEqualToString:@"true"];
        ((void (*)(id, SEL, BOOL))objc_msgSend)(changeItem, sel_registerName("setCompleted:"), val);
    }
    if (opts[@"priority"]) {
        NSUInteger val = [opts[@"priority"] integerValue];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(changeItem, sel_registerName("setPriority:"), val);
    }
    if (opts[@"flagged"]) {
        NSInteger val = [opts[@"flagged"] integerValue];
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(changeItem, sel_registerName("setFlagged:"), val);
    }
    if (opts[@"due-date"]) {
        NSDateComponents *comps = stringToDateComps(opts[@"due-date"]);
        ((void (*)(id, SEL, id))objc_msgSend)(changeItem, sel_registerName("setDueDateComponents:"), comps);
    }
    if (opts[@"start-date"]) {
        NSDateComponents *comps = stringToDateComps(opts[@"start-date"]);
        ((void (*)(id, SEL, id))objc_msgSend)(changeItem, sel_registerName("setStartDateComponents:"), comps);
    }
    if (opts[@"url"]) {
        NSURL *url = [NSURL URLWithString:opts[@"url"]];
        if (url) ((void (*)(id, SEL, id))objc_msgSend)(changeItem, sel_registerName("setIcsUrl:"), url);
    }
    if (opts[@"remove-parent"]) {
        ((void (*)(id, SEL))objc_msgSend)(changeItem, sel_registerName("removeFromParentReminder"));
    }
    if (opts[@"remove-from-list"]) {
        ((void (*)(id, SEL))objc_msgSend)(changeItem, sel_registerName("removeFromList"));
    }

    // Reparent: --parent-id
    if (parentID) {
        id parentRem = findReminderByID(store, parentID);
        if (!parentRem) errorExit([NSString stringWithFormat:@"Parent not found with id: %@", parentID]);

        // Validate no self-parenting
        id remObjID = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("objectID"));
        id parentObjID = ((id (*)(id, SEL))objc_msgSend)(parentRem, sel_registerName("objectID"));
        if ([objectIDToString(remObjID) isEqualToString:objectIDToString(parentObjID)]) {
            errorExit(@"Cannot set a reminder as its own parent");
        }

        // Get the list for reparenting
        id remListID = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("listID"));
        NSArray *allLists = fetchLists(store);
        id targetList = nil;
        for (id l in allLists) {
            id lID = ((id (*)(id, SEL))objc_msgSend)(l, sel_registerName("objectID"));
            if ([objectIDToString(lID) isEqualToString:objectIDToString(remListID)]) {
                targetList = l;
                break;
            }
        }
        if (!targetList) errorExit(@"Could not find list for reparenting");

        id listCI = ((id (*)(id, SEL, id))objc_msgSend)(
            saveReq, sel_registerName("updateList:"), targetList);

        id parentCI = ((id (*)(id, SEL, id))objc_msgSend)(
            saveReq, sel_registerName("updateReminder:"), parentRem);

        ((void (*)(id, SEL, id, id))objc_msgSend)(
            listCI, sel_registerName("_reassignReminderChangeItem:withParentReminderChangeItem:"),
            changeItem, parentCI);
    }

    // Move to different list: --to-list
    NSString *toListName = opts[@"to-list"];
    if (toListName) {
        id destList = findList(store, toListName);
        if (!destList) errorExit([NSString stringWithFormat:@"Destination list not found: %@", toListName]);

        id destListCI = ((id (*)(id, SEL, id))objc_msgSend)(
            saveReq, sel_registerName("updateList:"), destList);

        // Use initWithReminderChangeItem:insertIntoListChangeItem: to move
        Class REMReminderCIClass = NSClassFromString(@"REMReminderChangeItem");
        id moveCI = ((id (*)(id, SEL, id, id))objc_msgSend)(
            [REMReminderCIClass alloc],
            sel_registerName("initWithReminderChangeItem:insertIntoListChangeItem:"),
            changeItem, destListCI);
        if (!moveCI) errorExit(@"Failed to create move operation");
    }

    NSError *error = nil;
    BOOL saved = ((BOOL (*)(id, SEL, id*))objc_msgSend)(
        saveReq, sel_registerName("saveSynchronouslyWithError:"), &error);
    if (error) errorExit([NSString stringWithFormat:@"Save failed: %@", error]);

    // Re-fetch and return updated state
    id updated = findReminderByID(store, remID);
    if (updated) printJSON(reminderToDict(updated));
    else fprintf(stderr, "Updated successfully\n");
    return 0;
}


static int cmdComplete(id store, NSString *listName, NSString *remID) {
    id rem = findReminderByID(store, remID);
    if (!rem) errorExit([NSString stringWithFormat:@"Reminder not found with id: %@", remID]);

    id saveReq = ((id (*)(id, SEL, id))objc_msgSend)(
        [REMSaveRequestClass alloc], sel_registerName("initWithStore:"), store);

    id changeItem = ((id (*)(id, SEL, id))objc_msgSend)(
        saveReq, sel_registerName("updateReminder:"), rem);

    ((void (*)(id, SEL, BOOL))objc_msgSend)(changeItem, sel_registerName("setCompleted:"), YES);

    NSError *error = nil;
    BOOL saved = ((BOOL (*)(id, SEL, id*))objc_msgSend)(
        saveReq, sel_registerName("saveSynchronouslyWithError:"), &error);
    if (error) errorExit([NSString stringWithFormat:@"Save failed: %@", error]);

    printJSON(@{@"id": remID, @"completed": @YES});
    return 0;
}



static int cmdDelete(id store, NSString *listName, NSString *remID) {
    id rem = findReminderByID(store, remID);
    if (!rem) errorExit([NSString stringWithFormat:@"Reminder not found with id: %@", remID]);

    id saveReq = ((id (*)(id, SEL, id))objc_msgSend)(
        [REMSaveRequestClass alloc], sel_registerName("initWithStore:"), store);

    id changeItem = ((id (*)(id, SEL, id))objc_msgSend)(
        saveReq, sel_registerName("updateReminder:"), rem);

    ((void (*)(id, SEL))objc_msgSend)(changeItem, sel_registerName("removeFromList"));

    NSError *error = nil;
    BOOL saved = ((BOOL (*)(id, SEL, id*))objc_msgSend)(
        saveReq, sel_registerName("saveSynchronouslyWithError:"), &error);
    if (error) errorExit([NSString stringWithFormat:@"Save failed: %@", error]);

    printJSON(@{@"id": remID, @"deleted": @YES});
    return 0;
}


// --- Batch Command ---

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
    NSSet *validOps = [NSSet setWithArray:@[@"add", @"complete", @"update", @"delete"]];
    NSSet *validKeys = [NSSet setWithArray:@[@"op", @"title", @"id", @"list",
        @"notes", @"priority", @"flagged", @"completed",
        @"due-date", @"start-date", @"url", @"remove-parent", @"remove-from-list",
        @"parent-id", @"to-list"]];

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
            id list = opList ? findList(store, opList) : [fetchLists(store) firstObject];
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
            if (op[@"url"]) { NSURL *u = [NSURL URLWithString:op[@"url"]]; if (u) ((void (*)(id, SEL, id))objc_msgSend)(newRem, sel_registerName("setIcsUrl:"), u); }

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
                if (op[@"url"]) { NSURL *u = [NSURL URLWithString:op[@"url"]]; if (u) ((void (*)(id, SEL, id))objc_msgSend)(changeItem, sel_registerName("setIcsUrl:"), u); }
                if (op[@"remove-parent"]) ((void (*)(id, SEL))objc_msgSend)(changeItem, sel_registerName("removeFromParentReminder"));
                if (op[@"remove-from-list"]) ((void (*)(id, SEL))objc_msgSend)(changeItem, sel_registerName("removeFromList"));
                [results addObject:@{@"op": @"update", @"id": remIDStr ?: @"", @"status": @"ok"}];
            }
        }
    }

    NSError *error = nil;
    BOOL saved = ((BOOL (*)(id, SEL, id*))objc_msgSend)(
        saveReq, sel_registerName("saveSynchronouslyWithError:"), &error);
    if (error) errorExit([NSString stringWithFormat:@"Save failed: %@", error]);

    printJSON(results);
    return 0;
}


// --- Tests ---

static int cmdTest(id store) {
    int passed = 0, failed = 0;
    NSString *testListName = @"__remcli_test_list__";
    NSString *parentTitle = @"__remcli_test_parent__";
    NSString *childTitle = @"__remcli_test_child__";

    // Cleanup leftover test data
    id oldList = findList(store, testListName);
    if (oldList) {
        NSArray *oldRems = fetchReminders(store, oldList, YES);
        id cleanReq = ((id (*)(id, SEL, id))objc_msgSend)(
            [REMSaveRequestClass alloc], sel_registerName("initWithStore:"), store);
        for (id oldRem in oldRems) {
            id ci = ((id (*)(id, SEL, id))objc_msgSend)(cleanReq, sel_registerName("updateReminder:"), oldRem);
            ((void (*)(id, SEL))objc_msgSend)(ci, sel_registerName("removeFromList"));
        }
        id listCI = ((id (*)(id, SEL, id))objc_msgSend)(cleanReq, sel_registerName("updateList:"), oldList);
        ((void (*)(id, SEL))objc_msgSend)(listCI, sel_registerName("removeFromParent"));
        ((BOOL (*)(id, SEL, id*))objc_msgSend)(cleanReq, sel_registerName("saveSynchronouslyWithError:"), nil);
        fprintf(stderr, "Cleaned up leftover test data\n");
    }

    // Test 1: cmdCreateList
    fprintf(stderr, "Test 1: cmdCreateList...\n");
    { int r = cmdCreateList(store, testListName); if (r==0) { fprintf(stderr, "  PASS\n"); passed++; } else { fprintf(stderr, "  FAIL\n"); failed++; return 1; } }

    // Test 2: cmdLists (call actual command, verify it returns without error)
    fprintf(stderr, "Test 2: cmdLists...\n");
    { int r = cmdLists(store); if (r==0) { fprintf(stderr, "  PASS\n"); passed++; } else { fprintf(stderr, "  FAIL\n"); failed++; } }

    // Test 3: cmdAdd (create reminder with notes and priority)
    fprintf(stderr, "Test 3: cmdAdd...\n");
    { int r = cmdAdd(store, parentTitle, testListName, @{@"notes": @"Test notes", @"priority": @"5"}); if (r==0) { fprintf(stderr, "  PASS\n"); passed++; } else { fprintf(stderr, "  FAIL\n"); failed++; } }

    // Test 4: cmdGet (call actual command)
    fprintf(stderr, "Test 4: cmdGet...\n");
    { int r = cmdGet(store, parentTitle, testListName); if (r==0) { fprintf(stderr, "  PASS\n"); passed++; } else { fprintf(stderr, "  FAIL\n"); failed++; } }

    // Test 5: cmdUpdate (change notes, priority, flagged)
    fprintf(stderr, "Test 5: cmdUpdate...\n");
    {
        id rem5 = findReminder(store, parentTitle, testListName);
        NSString *rem5ID = objectIDToString(((id (*)(id, SEL))objc_msgSend)(rem5, sel_registerName("objectID")));
        int r = cmdUpdate(store, testListName, @{@"id": rem5ID, @"notes": @"Updated", @"priority": @"1", @"flagged": @"1"});
        if (r==0) { fprintf(stderr, "  PASS\n"); passed++; } else { fprintf(stderr, "  FAIL\n"); failed++; }
    }

    // Test 6: Verify update
    fprintf(stderr, "Test 6: Verify update...\n");
    {
        id rem = findReminder(store, parentTitle, testListName);
        NSString *notes = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("notesAsString"));
        NSUInteger pri = ((NSUInteger (*)(id, SEL))objc_msgSend)(rem, sel_registerName("priority"));
        NSInteger flagged = ((NSInteger (*)(id, SEL))objc_msgSend)(rem, sel_registerName("flagged"));
        if ([notes isEqualToString:@"Updated"] && pri == 1 && flagged == 1) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (notes=%s pri=%lu flagged=%ld)\n", [notes UTF8String], (unsigned long)pri, (long)flagged); failed++; }
    }

    // Test 7: Add child reminder then reparent via update --parent-id
    fprintf(stderr, "Test 7: Add child + reparent via update --parent-id...\n");
    { int r = cmdAdd(store, childTitle, testListName, @{}); if (r==0) {
        id parentRem7 = findReminder(store, parentTitle, testListName);
        NSString *parentID7 = objectIDToString(((id (*)(id, SEL))objc_msgSend)(parentRem7, sel_registerName("objectID")));
        id childRem7 = findReminder(store, childTitle, testListName);
        NSString *childID7 = objectIDToString(((id (*)(id, SEL))objc_msgSend)(childRem7, sel_registerName("objectID")));
        int r2 = cmdUpdate(store, testListName, @{@"id": childID7, @"parent-id": parentID7});
        if (r2==0) { fprintf(stderr, "  PASS\n"); passed++; } else { fprintf(stderr, "  FAIL\n"); failed++; }
    } else { fprintf(stderr, "  FAIL\n"); failed++; } }

    // Test 8: cmdSubtasks (verify parent-child)
    fprintf(stderr, "Test 8: Verify parent-child...\n");
    {
        id child = findReminder(store, childTitle, testListName);
        id parent = findReminder(store, parentTitle, testListName);
        id childPID = child ? ((id (*)(id, SEL))objc_msgSend)(child, sel_registerName("parentReminderID")) : nil;
        id parentOID = parent ? ((id (*)(id, SEL))objc_msgSend)(parent, sel_registerName("objectID")) : nil;
        if (childPID && parentOID && [objectIDToString(childPID) isEqualToString:objectIDToString(parentOID)]) {
            fprintf(stderr, "  PASS\n"); passed++;
        } else { fprintf(stderr, "  FAIL\n"); failed++; }
    }

    // Test 9: cmdAddTag
    fprintf(stderr, "Test 9: cmdAddTag...\n");
    {
        id rem9 = findReminder(store, parentTitle, testListName);
        NSString *rem9ID = objectIDToString(((id (*)(id, SEL))objc_msgSend)(rem9, sel_registerName("objectID")));
        int r = cmdAddTag(store, rem9ID, @"test-tag");
        if (r==0) { fprintf(stderr, "  PASS\n"); passed++; } else { fprintf(stderr, "  FAIL\n"); failed++; }
    }

    // Test 10: Verify tag in reminderToDict
    fprintf(stderr, "Test 10: Verify tag...\n");
    {
        id rem = findReminder(store, parentTitle, testListName);
        NSDictionary *dict = reminderToDict(rem);
        NSArray *tags = dict[@"hashtags"];
        if (tags && [tags containsObject:@"test-tag"]) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL\n"); failed++; }
    }

    // Test 11: cmdRemoveTag
    fprintf(stderr, "Test 11: cmdRemoveTag...\n");
    {
        id rem11 = findReminder(store, parentTitle, testListName);
        NSString *rem11ID = objectIDToString(((id (*)(id, SEL))objc_msgSend)(rem11, sel_registerName("objectID")));
        int r = cmdRemoveTag(store, rem11ID, @"test-tag");
        if (r==0) { fprintf(stderr, "  PASS\n"); passed++; } else { fprintf(stderr, "  FAIL\n"); failed++; }
    }

    // Test 12: cmdComplete (complete child)
    fprintf(stderr, "Test 12: cmdComplete...\n");
    {
        id rem12 = findReminder(store, childTitle, testListName);
        NSString *rem12ID = objectIDToString(((id (*)(id, SEL))objc_msgSend)(rem12, sel_registerName("objectID")));
        int r = cmdComplete(store, testListName, rem12ID);
        if (r==0) { fprintf(stderr, "  PASS\n"); passed++; } else { fprintf(stderr, "  FAIL\n"); failed++; }
    }

    // Test 13: cmdList (call actual command)
    fprintf(stderr, "Test 13: cmdList...\n");
    { int r = cmdList(store, testListName, NO); if (r==0) { fprintf(stderr, "  PASS\n"); passed++; } else { fprintf(stderr, "  FAIL\n"); failed++; } }

    // Test 14: Verify JSON shape from reminderToDict
    fprintf(stderr, "Test 14: JSON shape...\n");
    {
        id rem = findReminder(store, parentTitle, testListName);
        NSDictionary *dict = reminderToDict(rem);
        BOOL hasTitle = dict[@"title"] != nil;
        BOOL hasNotes = dict[@"notes"] != nil;
        BOOL hasId = dict[@"id"] != nil;
        BOOL hasCompleted = dict[@"completed"] != nil;
        BOOL hasPriority = dict[@"priority"] != nil;
        BOOL hasCreatedAt = dict[@"createdAt"] != nil;
        BOOL hasModifiedAt = dict[@"modifiedAt"] != nil;
        if (hasTitle && hasNotes && hasId && hasCompleted && hasPriority && hasCreatedAt && hasModifiedAt) {
            fprintf(stderr, "  PASS\n"); passed++;
        } else {
            fprintf(stderr, "  FAIL (missing fields: title=%d notes=%d id=%d completed=%d priority=%d created=%d modified=%d)\n",
                hasTitle, hasNotes, hasId, hasCompleted, hasPriority, hasCreatedAt, hasModifiedAt); failed++;
        }
    }

    // Test 15: cmdUpdate --title (rename)
    fprintf(stderr, "Test 15: Rename via update...\n");
    {
        NSString *renamedTitle = @"__remcli_test_renamed__";
        id rem15 = findReminder(store, parentTitle, testListName);
        NSString *rem15ID = objectIDToString(((id (*)(id, SEL))objc_msgSend)(rem15, sel_registerName("objectID")));
        int r = cmdUpdate(store, testListName, @{@"id": rem15ID, @"title": renamedTitle});
        if (r == 0) {
            id found = findReminder(store, renamedTitle, testListName);
            if (found) {
                // Rename back
                cmdUpdate(store, testListName, @{@"id": rem15ID, @"title": parentTitle});
                fprintf(stderr, "  PASS\n"); passed++;
            } else { fprintf(stderr, "  FAIL (not found after rename)\n"); failed++; }
        } else { fprintf(stderr, "  FAIL\n"); failed++; }
    }

    // Test 16: cmdRenameList
    fprintf(stderr, "Test 16: cmdRenameList...\n");
    {
        NSString *renamedList = @"__remcli_test_list_renamed__";
        int r = cmdRenameList(store, testListName, renamedList);
        if (r == 0) {
            id found = findList(store, renamedList);
            if (found) {
                // Rename back
                cmdRenameList(store, renamedList, testListName);
                fprintf(stderr, "  PASS\n"); passed++;
            } else { fprintf(stderr, "  FAIL (not found after rename)\n"); failed++; }
        } else { fprintf(stderr, "  FAIL\n"); failed++; }
    }

    // Test 17: cmdSubtasks (call actual command)
    fprintf(stderr, "Test 17: cmdSubtasks...\n");
    { int r = cmdSubtasks(store, parentTitle, testListName); if (r==0) { fprintf(stderr, "  PASS\n"); passed++; } else { fprintf(stderr, "  FAIL\n"); failed++; } }

    // Test 18: Error path - find non-existent reminder
    fprintf(stderr, "Test 18: Error path (not found)...\n");
    {
        id notFound = findReminder(store, @"__nonexistent_reminder_999__", testListName);
        if (!notFound) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (should be nil)\n"); failed++; }
    }

    // Test 19: Error path - find non-existent list
    fprintf(stderr, "Test 19: Error path (list not found)...\n");
    {
        id notFound = findList(store, @"__nonexistent_list_999__");
        if (!notFound) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (should be nil)\n"); failed++; }
    }

    // Cleanup
    // Test 20: cmdDelete child
    fprintf(stderr, "Test 20: cmdDelete child...\n");
    {
        id rem20 = findReminder(store, childTitle, testListName);
        NSString *rem20ID = objectIDToString(((id (*)(id, SEL))objc_msgSend)(rem20, sel_registerName("objectID")));
        int r = cmdDelete(store, testListName, rem20ID);
        if (r==0) { fprintf(stderr, "  PASS\n"); passed++; } else { fprintf(stderr, "  FAIL\n"); failed++; }
    }

    // Test 21: cmdDelete parent
    fprintf(stderr, "Test 21: cmdDelete parent...\n");
    {
        id rem21 = findReminder(store, parentTitle, testListName);
        NSString *rem21ID = objectIDToString(((id (*)(id, SEL))objc_msgSend)(rem21, sel_registerName("objectID")));
        int r = cmdDelete(store, testListName, rem21ID);
        if (r==0) { fprintf(stderr, "  PASS\n"); passed++; } else { fprintf(stderr, "  FAIL\n"); failed++; }
    }

    // Test 22: cmdDeleteList
    fprintf(stderr, "Test 22: cmdDeleteList...\n");
    { int r = cmdDeleteList(store, testListName); if (r==0) {
        id gone = findList(store, testListName);
        if (!gone) { fprintf(stderr, "  PASS\n"); passed++; } else { fprintf(stderr, "  FAIL (still exists)\n"); failed++; }
    } else { fprintf(stderr, "  FAIL\n"); failed++; } }

    fprintf(stderr, "\nResults: %d passed, %d failed\n", passed, failed);
    return failed > 0 ? 1 : 0;
}


// --- Install Skill ---

static int cmdInstallSkill(void) {
    // Get path of currently running binary
    char execPath[PATH_MAX];
    uint32_t size = sizeof(execPath);
    if (_NSGetExecutablePath(execPath, &size) != 0) {
        fprintf(stderr, "Error: could not determine executable path\n");
        return 1;
    }

    // Resolve symlinks to get the real path
    char realPath[PATH_MAX];
    if (!realpath(execPath, realPath)) {
        fprintf(stderr, "Error: could not resolve executable path\n");
        return 1;
    }

    NSString *binaryPath = [NSString stringWithUTF8String:realPath];
    NSString *binDir = [binaryPath stringByDeletingLastPathComponent];

    // Try to find SKILL.md relative to the binary
    // Homebrew: /opt/homebrew/Cellar/reminderkit-cli/X.Y.Z/bin/reminderkit
    //   skill: /opt/homebrew/Cellar/reminderkit-cli/X.Y.Z/.agents/skills/apple-reminders/SKILL.md
    // Build dir: ./reminderkit  ->  ./.agents/skills/apple-reminders/SKILL.md
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
        fprintf(stderr, "Error: could not find SKILL.md relative to binary at %s\n", realPath);
        fprintf(stderr, "Searched:\n");
        for (NSString *candidate in candidates) {
            fprintf(stderr, "  %s\n", [[candidate stringByStandardizingPath] UTF8String]);
        }
        return 1;
    }

    // Create target directory
    NSString *home = NSHomeDirectory();
    NSString *targetDir = [home stringByAppendingPathComponent:@".claude/skills/apple-reminders"];
    NSString *targetPath = [targetDir stringByAppendingPathComponent:@"SKILL.md"];

    NSError *error = nil;
    if (![fm createDirectoryAtPath:targetDir withIntermediateDirectories:YES attributes:nil error:&error]) {
        fprintf(stderr, "Error: could not create directory %s: %s\n",
            [targetDir UTF8String], [[error localizedDescription] UTF8String]);
        return 1;
    }

    // Remove existing symlink or file
    if ([fm fileExistsAtPath:targetPath]) {
        [fm removeItemAtPath:targetPath error:nil];
    }

    // Create symlink
    if (![fm createSymbolicLinkAtPath:targetPath withDestinationPath:sourcePath error:&error]) {
        fprintf(stderr, "Error: could not create symlink: %s\n",
            [[error localizedDescription] UTF8String]);
        return 1;
    }

    printf("Installed skill: %s -> %s\n", [targetPath UTF8String], [sourcePath UTF8String]);
    return 0;
}


// --- Usage ---

static void usage(void) {
    fprintf(stderr, "Usage:\n");
    fprintf(stderr, "  reminderkit lists\n");
    fprintf(stderr, "  reminderkit list (<name> | --name <name>) [--include-completed]\n");
    fprintf(stderr, "  reminderkit get (<title> | --title <title>) [--list <name>]\n");
    fprintf(stderr, "  reminderkit subtasks (<title> | --title <title>) [--list <name>]\n");
    fprintf(stderr, "  reminderkit add (<title> | --title <title>) [--list <name>] [--notes <value>] [--completed <value>] [--priority <value>] [--flagged <value>] [--due-date <value>] [--start-date <value>] [--url <value>]\n");
    fprintf(stderr, "  reminderkit update --id <id> [--list <name>] [--notes <value>] [--completed <value>] [--priority <value>] [--flagged <value>] [--due-date <value>] [--start-date <value>] [--url <value>] [--remove-parent] [--remove-from-list] [--parent-id <id>] [--to-list <name>]\n");
    fprintf(stderr, "  reminderkit complete --id <id> [--list <name>]\n");
    fprintf(stderr, "  reminderkit delete --id <id> [--list <name>]\n");
    fprintf(stderr, "  reminderkit add-tag --id <id> (<tag-name> | --tag <tag-name>)\n");
    fprintf(stderr, "  reminderkit remove-tag --id <id> (<tag-name> | --tag <tag-name>)\n");
    fprintf(stderr, "  reminderkit list-sections (<list-name> | --name <list-name>)\n");
    fprintf(stderr, "  reminderkit create-section (<list-name> | --name <list-name>) (<section-name> | --section <section-name>)\n");
    fprintf(stderr, "  reminderkit create-list (<name> | --name <name>)\n");
    fprintf(stderr, "  reminderkit rename-list (<old-name> | --old-name <old-name>) (<new-name> | --new-name <new-name>)\n");
    fprintf(stderr, "  reminderkit delete-list (<name> | --name <name>)\n");
    fprintf(stderr, "  reminderkit batch  (reads JSON array from stdin)\n");
    fprintf(stderr, "\n  Skill management:\n");
    fprintf(stderr, "  reminderkit install-skill\n");
    fprintf(stderr, "\n  Testing:\n");
    fprintf(stderr, "  reminderkit test\n");
}


// --- Main ---

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) { usage(); return 1; }

        loadFramework();

        NSString *command = [NSString stringWithUTF8String:argv[1]];

        // Parse arguments
        NSMutableArray *positional = [NSMutableArray array];
        NSMutableDictionary *opts = [NSMutableDictionary dictionary];
        BOOL includeCompleted = NO;

        for (int i = 2; i < argc; i++) {
            NSString *arg = [NSString stringWithUTF8String:argv[i]];
            if ([arg hasPrefix:@"--"]) {
                NSString *flag = [arg substringFromIndex:2];
                if ([flag isEqualToString:@"include-completed"] ||
                    [flag isEqualToString:@"remove-parent"] ||
                    [flag isEqualToString:@"remove-from-list"] ||
                    [flag isEqualToString:@"help"]) {
                    if ([flag isEqualToString:@"include-completed"]) includeCompleted = YES;
                    opts[flag] = @"true";
                } else if (i + 1 < argc) {
                    opts[flag] = [NSString stringWithUTF8String:argv[++i]];
                }
            } else {
                [positional addObject:arg];
            }
        }

        // Resolve keyword args: --title, --name, --tag, --section, --old-name, --new-name
        // Keyword args take priority over positional args
        NSString *kwTitle = opts[@"title"];
        NSString *kwName = opts[@"name"];
        NSString *kwTag = opts[@"tag"];
        NSString *kwSection = opts[@"section"];
        NSString *kwOldName = opts[@"old-name"];
        NSString *kwNewName = opts[@"new-name"];

        NSString *listName = opts[@"list"];
        id store = getStore();

        if ([command isEqualToString:@"lists"]) {
            return cmdLists(store);

        } else if ([command isEqualToString:@"list"]) {
            NSString *name = kwName ?: (positional.count > 0 ? positional[0] : nil);
            if (!name) { fprintf(stderr, "Error: list name required\n"); usage(); return 1; }
            return cmdList(store, name, includeCompleted);

        } else if ([command isEqualToString:@"get"]) {
            NSString *title = kwTitle ?: (positional.count > 0 ? positional[0] : nil);
            if (!title) { fprintf(stderr, "Error: title required\n"); usage(); return 1; }
            return cmdGet(store, title, listName);

        } else if ([command isEqualToString:@"subtasks"]) {
            NSString *title = kwTitle ?: (positional.count > 0 ? positional[0] : nil);
            if (!title) { fprintf(stderr, "Error: title required\n"); usage(); return 1; }
            return cmdSubtasks(store, title, listName);

        } else if ([command isEqualToString:@"add"]) {
            NSString *title = kwTitle ?: (positional.count > 0 ? positional[0] : nil);
            if (!title) { fprintf(stderr, "Error: title required\n"); usage(); return 1; }
            return cmdAdd(store, title, listName, opts);

        } else if ([command isEqualToString:@"update"]) {
            if (!opts[@"id"] || [opts[@"id"] length] == 0) { fprintf(stderr, "Error: --id required\n"); usage(); return 1; }
            return cmdUpdate(store, listName, opts);

        } else if ([command isEqualToString:@"complete"]) {
            if (!opts[@"id"] || [opts[@"id"] length] == 0) { fprintf(stderr, "Error: --id required\n"); usage(); return 1; }
            return cmdComplete(store, listName, opts[@"id"]);

        } else if ([command isEqualToString:@"delete"]) {
            if (!opts[@"id"] || [opts[@"id"] length] == 0) { fprintf(stderr, "Error: --id required\n"); usage(); return 1; }
            return cmdDelete(store, listName, opts[@"id"]);

        } else if ([command isEqualToString:@"batch"]) {
            return cmdBatch(store);

        } else if ([command isEqualToString:@"add-tag"]) {
            NSString *tag = kwTag ?: (positional.count > 0 ? positional[0] : nil);
            if (!opts[@"id"] || [opts[@"id"] length] == 0) { fprintf(stderr, "Error: --id required\n"); usage(); return 1; }
            if (!tag) { fprintf(stderr, "Error: tag name required\n"); usage(); return 1; }
            return cmdAddTag(store, opts[@"id"], tag);

        } else if ([command isEqualToString:@"remove-tag"]) {
            NSString *tag = kwTag ?: (positional.count > 0 ? positional[0] : nil);
            if (!opts[@"id"] || [opts[@"id"] length] == 0) { fprintf(stderr, "Error: --id required\n"); usage(); return 1; }
            if (!tag) { fprintf(stderr, "Error: tag name required\n"); usage(); return 1; }
            return cmdRemoveTag(store, opts[@"id"], tag);

        } else if ([command isEqualToString:@"list-sections"]) {
            NSString *name = kwName ?: (positional.count > 0 ? positional[0] : nil);
            if (!name) { fprintf(stderr, "Error: list name required\n"); usage(); return 1; }
            return cmdListSections(store, name);

        } else if ([command isEqualToString:@"create-section"]) {
            NSString *name = kwName ?: (positional.count > 0 ? positional[0] : nil);
            NSString *section = kwSection ?: (positional.count > 1 ? positional[1] : nil);
            if (!name || !section) { fprintf(stderr, "Error: list name and section name required\n"); usage(); return 1; }
            return cmdCreateSection(store, name, section);

        } else if ([command isEqualToString:@"create-list"]) {
            NSString *name = kwName ?: (positional.count > 0 ? positional[0] : nil);
            if (!name) { fprintf(stderr, "Error: list name required\n"); usage(); return 1; }
            return cmdCreateList(store, name);

        } else if ([command isEqualToString:@"rename-list"]) {
            NSString *oldName = kwOldName ?: (positional.count > 0 ? positional[0] : nil);
            NSString *newName = kwNewName ?: (positional.count > 1 ? positional[1] : nil);
            if (!oldName || !newName) { fprintf(stderr, "Error: old and new names required\n"); usage(); return 1; }
            return cmdRenameList(store, oldName, newName);

        } else if ([command isEqualToString:@"delete-list"]) {
            NSString *name = kwName ?: (positional.count > 0 ? positional[0] : nil);
            if (!name) { fprintf(stderr, "Error: list name required\n"); usage(); return 1; }
            return cmdDeleteList(store, name);

        } else if ([command isEqualToString:@"install-skill"]) {
            return cmdInstallSkill();

        } else if ([command isEqualToString:@"test"]) {
            return cmdTest(store);

        } else if ([command isEqualToString:@"help"] || [command isEqualToString:@"--help"] || [command isEqualToString:@"-h"]) {
            usage();
            return 0;

        } else {
            fprintf(stderr, "Unknown command: %s\n", [command UTF8String]);
            usage();
            return 1;
        }
    }
}

