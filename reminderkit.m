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

static NSString *normalizeQuotes(NSString *str) {
    if (!str) return nil;
    NSString *result = [str stringByReplacingOccurrencesOfString:@"\u2018" withString:@"'"];
    result = [result stringByReplacingOccurrencesOfString:@"\u2019" withString:@"'"];
    return result;
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
    // Pass 1: exact match
    for (id list in lists) {
        id storage = ((id (*)(id, SEL))objc_msgSend)(list, sel_registerName("storage"));
        NSString *listName = ((id (*)(id, SEL))objc_msgSend)(storage, sel_registerName("name"));
        if ([listName isEqualToString:name]) return list;
    }
    // Pass 2: normalized fallback (curly apostrophes -> straight)
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

static id requireUniqueReminder(id store, NSString *title, NSString *listName) {
    NSArray *matches = findReminders(store, title, listName);
    if (matches.count == 0) {
        errorExit([NSString stringWithFormat:@"Reminder not found: %@", title]);
    }
    if (matches.count > 1) {
        NSMutableString *msg = [NSMutableString stringWithFormat:@"Multiple reminders match '%@'. Use --id to specify:\n", title];
        for (id rem in matches) {
            NSString *t = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("titleAsString"));
            id objID = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("objectID"));
            NSString *idStr = objectIDToString(objID);
            [msg appendFormat:@"  - \"%@\" (id: %@)\n", t, idStr];
        }
        errorExit(msg);
    }
    return matches[0];
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
        id attCtx = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("attachmentContext"));
        if (attCtx) {
            NSArray *urlAtts = ((id (*)(id, SEL))objc_msgSend)(attCtx, sel_registerName("urlAttachments"));
            if (urlAtts.count > 0) {
                NSURL *attUrl = ((id (*)(id, SEL))objc_msgSend)(urlAtts[0], sel_registerName("url"));
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
            }
        }
    } @catch (NSException *e) {}

    // --- Newly exposed properties ---

    // recurrenceRules
    @try {
        NSArray *rules = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("recurrenceRules"));
        if (rules && rules.count > 0) {
            NSMutableArray *rulesArr = [NSMutableArray array];
            for (id rule in rules) {
                NSMutableDictionary *ruleDict = [NSMutableDictionary dictionary];
                @try {
                    long long freq = ((long long (*)(id, SEL))objc_msgSend)(rule, sel_registerName("frequency"));
                    // frequency: 0=daily, 1=weekly, 2=monthly, 3=yearly
                    NSArray *freqNames = @[@"daily", @"weekly", @"monthly", @"yearly"];
                    if (freq >= 0 && freq < (long long)freqNames.count) {
                        ruleDict[@"frequency"] = freqNames[freq];
                    } else {
                        ruleDict[@"frequency"] = @(freq);
                    }
                } @catch (NSException *e) {}
                @try {
                    long long interval = ((long long (*)(id, SEL))objc_msgSend)(rule, sel_registerName("interval"));
                    ruleDict[@"interval"] = @(interval);
                } @catch (NSException *e) {}
                @try {
                    NSArray *daysOfWeek = ((id (*)(id, SEL))objc_msgSend)(rule, sel_registerName("daysOfTheWeek"));
                    if (daysOfWeek && daysOfWeek.count > 0) {
                        NSMutableArray *days = [NSMutableArray array];
                        for (id day in daysOfWeek) {
                            NSMutableDictionary *dayDict = [NSMutableDictionary dictionary];
                            @try {
                                long long weekday = ((long long (*)(id, SEL))objc_msgSend)(day, sel_registerName("dayOfTheWeek"));
                                // EKWeekday: 1=Sunday, 2=Monday, ..., 7=Saturday
                                dayDict[@"dayOfTheWeek"] = @(weekday);
                            } @catch (NSException *e) {}
                            @try {
                                long long weekNum = ((long long (*)(id, SEL))objc_msgSend)(day, sel_registerName("weekNumber"));
                                if (weekNum != 0) dayDict[@"weekNumber"] = @(weekNum);
                            } @catch (NSException *e) {}
                            if (dayDict.count > 0) [days addObject:dayDict];
                        }
                        if (days.count > 0) ruleDict[@"daysOfTheWeek"] = days;
                    }
                } @catch (NSException *e) {}
                @try {
                    NSArray *daysOfMonth = ((id (*)(id, SEL))objc_msgSend)(rule, sel_registerName("daysOfTheMonth"));
                    if (daysOfMonth && daysOfMonth.count > 0) ruleDict[@"daysOfTheMonth"] = daysOfMonth;
                } @catch (NSException *e) {}
                @try {
                    NSArray *daysOfYear = ((id (*)(id, SEL))objc_msgSend)(rule, sel_registerName("daysOfTheYear"));
                    if (daysOfYear && daysOfYear.count > 0) ruleDict[@"daysOfTheYear"] = daysOfYear;
                } @catch (NSException *e) {}
                @try {
                    NSArray *weeksOfYear = ((id (*)(id, SEL))objc_msgSend)(rule, sel_registerName("weeksOfTheYear"));
                    if (weeksOfYear && weeksOfYear.count > 0) ruleDict[@"weeksOfTheYear"] = weeksOfYear;
                } @catch (NSException *e) {}
                @try {
                    NSArray *monthsOfYear = ((id (*)(id, SEL))objc_msgSend)(rule, sel_registerName("monthsOfTheYear"));
                    if (monthsOfYear && monthsOfYear.count > 0) ruleDict[@"monthsOfTheYear"] = monthsOfYear;
                } @catch (NSException *e) {}
                @try {
                    NSArray *setPositions = ((id (*)(id, SEL))objc_msgSend)(rule, sel_registerName("setPositions"));
                    if (setPositions && setPositions.count > 0) ruleDict[@"setPositions"] = setPositions;
                } @catch (NSException *e) {}
                @try {
                    id recEnd = ((id (*)(id, SEL))objc_msgSend)(rule, sel_registerName("recurrenceEnd"));
                    if (recEnd) {
                        NSMutableDictionary *endDict = [NSMutableDictionary dictionary];
                        @try {
                            NSDate *endDate = ((id (*)(id, SEL))objc_msgSend)(recEnd, sel_registerName("endDate"));
                            if (endDate) endDict[@"endDate"] = dateToISO(endDate);
                        } @catch (NSException *e) {}
                        @try {
                            NSUInteger count = ((NSUInteger (*)(id, SEL))objc_msgSend)(recEnd, sel_registerName("occurrenceCount"));
                            if (count > 0) endDict[@"occurrenceCount"] = @(count);
                        } @catch (NSException *e) {}
                        if (endDict.count > 0) ruleDict[@"recurrenceEnd"] = endDict;
                    }
                } @catch (NSException *e) {}
                if (ruleDict.count > 0) [rulesArr addObject:ruleDict];
            }
            if (rulesArr.count > 0) dict[@"recurrenceRules"] = rulesArr;
        }
    } @catch (NSException *e) {}

    // alarms
    @try {
        NSArray *alarms = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("alarms"));
        if (alarms && alarms.count > 0) {
            NSMutableArray *alarmsArr = [NSMutableArray array];
            for (id alarm in alarms) {
                NSMutableDictionary *alarmDict = [NSMutableDictionary dictionary];
                @try {
                    NSString *uid = ((id (*)(id, SEL))objc_msgSend)(alarm, sel_registerName("alarmUID"));
                    if (uid) alarmDict[@"uid"] = uid;
                } @catch (NSException *e) {}
                @try {
                    NSDate *ackDate = ((id (*)(id, SEL))objc_msgSend)(alarm, sel_registerName("acknowledgedDate"));
                    if (ackDate) alarmDict[@"acknowledgedDate"] = dateToISO(ackDate);
                } @catch (NSException *e) {}
                @try {
                    id trigger = ((id (*)(id, SEL))objc_msgSend)(alarm, sel_registerName("trigger"));
                    if (trigger) {
                        BOOL isTemporal = ((BOOL (*)(id, SEL))objc_msgSend)(trigger, sel_registerName("isTemporal"));
                        if (isTemporal) {
                            alarmDict[@"type"] = @"date";
                            @try {
                                NSDateComponents *comps = ((id (*)(id, SEL))objc_msgSend)(trigger, sel_registerName("dateComponents"));
                                if (comps) alarmDict[@"date"] = dateCompsToString(comps);
                            } @catch (NSException *e) {}
                        } else {
                            alarmDict[@"type"] = @"location";
                            @try {
                                id loc = ((id (*)(id, SEL))objc_msgSend)(trigger, sel_registerName("structuredLocation"));
                                if (loc) {
                                    NSMutableDictionary *locDict = [NSMutableDictionary dictionary];
                                    @try {
                                        NSString *title = ((id (*)(id, SEL))objc_msgSend)(loc, sel_registerName("title"));
                                        if (title) locDict[@"title"] = title;
                                    } @catch (NSException *e) {}
                                    @try {
                                        double lat = ((double (*)(id, SEL))objc_msgSend)(loc, sel_registerName("latitude"));
                                        double lon = ((double (*)(id, SEL))objc_msgSend)(loc, sel_registerName("longitude"));
                                        locDict[@"latitude"] = @(lat);
                                        locDict[@"longitude"] = @(lon);
                                    } @catch (NSException *e) {}
                                    @try {
                                        double radius = ((double (*)(id, SEL))objc_msgSend)(loc, sel_registerName("radius"));
                                        if (radius > 0) locDict[@"radius"] = @(radius);
                                    } @catch (NSException *e) {}
                                    @try {
                                        NSString *address = ((id (*)(id, SEL))objc_msgSend)(loc, sel_registerName("address"));
                                        if (address) locDict[@"address"] = address;
                                    } @catch (NSException *e) {}
                                    alarmDict[@"location"] = locDict;
                                }
                            } @catch (NSException *e) {}
                            @try {
                                long long prox = ((long long (*)(id, SEL))objc_msgSend)(trigger, sel_registerName("proximity"));
                                // proximity: 1=enter, 2=leave
                                if (prox == 1) alarmDict[@"proximity"] = @"enter";
                                else if (prox == 2) alarmDict[@"proximity"] = @"leave";
                                else alarmDict[@"proximity"] = @(prox);
                            } @catch (NSException *e) {}
                        }
                    }
                } @catch (NSException *e) {}
                if (alarmDict.count > 0) [alarmsArr addObject:alarmDict];
            }
            if (alarmsArr.count > 0) dict[@"alarms"] = alarmsArr;
        }
    } @catch (NSException *e) {}

    // attachments (file and image — URL attachments already exposed as "url" above)
    @try {
        id attCtx2 = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("attachmentContext"));
        if (attCtx2) {
            NSMutableArray *fileAttsArr = [NSMutableArray array];
            @try {
                NSArray *fileAtts = ((id (*)(id, SEL))objc_msgSend)(attCtx2, sel_registerName("fileAttachments"));
                for (id att in fileAtts) {
                    NSMutableDictionary *attDict = [NSMutableDictionary dictionary];
                    attDict[@"type"] = @"file";
                    @try {
                        NSURL *fileURL = ((id (*)(id, SEL))objc_msgSend)(att, sel_registerName("fileURL"));
                        if (fileURL) attDict[@"fileURL"] = [fileURL absoluteString];
                    } @catch (NSException *e) {}
                    @try {
                        NSUInteger fileSize = ((NSUInteger (*)(id, SEL))objc_msgSend)(att, sel_registerName("fileSize"));
                        attDict[@"fileSize"] = @(fileSize);
                    } @catch (NSException *e) {}
                    @try {
                        NSString *uti = ((id (*)(id, SEL))objc_msgSend)(att, sel_registerName("uti"));
                        if (uti) attDict[@"uti"] = uti;
                    } @catch (NSException *e) {}
                    [fileAttsArr addObject:attDict];
                }
            } @catch (NSException *e) {}
            @try {
                NSArray *imgAtts = ((id (*)(id, SEL))objc_msgSend)(attCtx2, sel_registerName("imageAttachments"));
                for (id att in imgAtts) {
                    NSMutableDictionary *attDict = [NSMutableDictionary dictionary];
                    attDict[@"type"] = @"image";
                    @try {
                        NSUInteger w = ((NSUInteger (*)(id, SEL))objc_msgSend)(att, sel_registerName("width"));
                        NSUInteger h = ((NSUInteger (*)(id, SEL))objc_msgSend)(att, sel_registerName("height"));
                        attDict[@"width"] = @(w);
                        attDict[@"height"] = @(h);
                    } @catch (NSException *e) {}
                    @try {
                        NSString *uti = ((id (*)(id, SEL))objc_msgSend)(att, sel_registerName("uti"));
                        if (uti) attDict[@"uti"] = uti;
                    } @catch (NSException *e) {}
                    [fileAttsArr addObject:attDict];
                }
            } @catch (NSException *e) {}
            if (fileAttsArr.count > 0) dict[@"attachments"] = fileAttsArr;
        }
    } @catch (NSException *e) {}

    // assignments
    @try {
        NSSet *assignments = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("assignments"));
        if (assignments && assignments.count > 0) {
            NSMutableArray *assignArr = [NSMutableArray array];
            for (id assignment in assignments) {
                NSMutableDictionary *aDict = [NSMutableDictionary dictionary];
                @try {
                    id assigneeID = ((id (*)(id, SEL))objc_msgSend)(assignment, sel_registerName("assigneeID"));
                    if (assigneeID) aDict[@"assigneeID"] = objectIDToString(assigneeID);
                } @catch (NSException *e) {}
                @try {
                    id originatorID = ((id (*)(id, SEL))objc_msgSend)(assignment, sel_registerName("originatorID"));
                    if (originatorID) aDict[@"originatorID"] = objectIDToString(originatorID);
                } @catch (NSException *e) {}
                @try {
                    long long status = ((long long (*)(id, SEL))objc_msgSend)(assignment, sel_registerName("status"));
                    aDict[@"status"] = @(status);
                } @catch (NSException *e) {}
                @try {
                    NSDate *assignedDate = ((id (*)(id, SEL))objc_msgSend)(assignment, sel_registerName("assignedDate"));
                    if (assignedDate) aDict[@"assignedDate"] = dateToISO(assignedDate);
                } @catch (NSException *e) {}
                if (aDict.count > 0) [assignArr addObject:aDict];
            }
            if (assignArr.count > 0) dict[@"assignments"] = assignArr;
        }
    } @catch (NSException *e) {}

    // displayDate
    @try {
        id dispDate = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("displayDate"));
        if (dispDate) {
            NSMutableDictionary *ddDict = [NSMutableDictionary dictionary];
            @try {
                NSDate *date = ((id (*)(id, SEL))objc_msgSend)(dispDate, sel_registerName("date"));
                if (date) ddDict[@"date"] = dateToISO(date);
            } @catch (NSException *e) {}
            @try {
                BOOL allDay = ((BOOL (*)(id, SEL))objc_msgSend)(dispDate, sel_registerName("isAllDay"));
                ddDict[@"allDay"] = @(allDay);
            } @catch (NSException *e) {}
            @try {
                NSTimeZone *tz = ((id (*)(id, SEL))objc_msgSend)(dispDate, sel_registerName("timeZone"));
                if (tz) ddDict[@"timeZone"] = [tz name];
            } @catch (NSException *e) {}
            if (ddDict.count > 0) dict[@"displayDate"] = ddDict;
        }
    } @catch (NSException *e) {}

    // icsDisplayOrder
    @try {
        NSUInteger order = ((NSUInteger (*)(id, SEL))objc_msgSend)(rem, sel_registerName("icsDisplayOrder"));
        dict[@"icsDisplayOrder"] = @(order);
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
    NSArray *matches = findReminders(store, title, listName);
    if (matches.count == 0) errorExit([NSString stringWithFormat:@"Reminder not found: %@", title]);

    NSMutableArray *resultArray = [NSMutableArray array];
    for (id rem in matches) {
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
        if (url) {
            id attCtx = ((id (*)(id, SEL))objc_msgSend)(newRem, sel_registerName("attachmentContext"));
            ((void (*)(id, SEL, id))objc_msgSend)(attCtx, sel_registerName("setURLAttachmentWithURL:"), url);
        }
    }

    // Reparent: --parent-id
    if (opts[@"parent-id"]) {
        reparentChangeItem(store, saveReq, listCI, newRem, opts[@"parent-id"]);
    }

    NSError *error = nil;
    BOOL saved = ((BOOL (*)(id, SEL, id*))objc_msgSend)(
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

    // Validate conflicting URL flags
    if (opts[@"url"] && opts[@"clear-url"]) {
        errorExit(@"Cannot use --url and --clear-url together");
    }

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
    if (opts[@"append-notes"]) {
        NSString *existing = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("notesAsString"));
        NSString *combined;
        if (existing && [existing length] > 0) {
            combined = [NSString stringWithFormat:@"%@\n%@", existing, opts[@"append-notes"]];
        } else {
            combined = opts[@"append-notes"];
        }
        ((void (*)(id, SEL, id))objc_msgSend)(changeItem, sel_registerName("setNotesAsString:"), combined);
    } else if (opts[@"notes"]) {
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
        if (url) {
            id attCtx = ((id (*)(id, SEL))objc_msgSend)(changeItem, sel_registerName("attachmentContext"));
            ((void (*)(id, SEL, id))objc_msgSend)(attCtx, sel_registerName("setURLAttachmentWithURL:"), url);
        }
    }
    if (opts[@"clear-url"]) {
        id attCtx = ((id (*)(id, SEL))objc_msgSend)(changeItem, sel_registerName("attachmentContext"));
        ((void (*)(id, SEL))objc_msgSend)(attCtx, sel_registerName("removeURLAttachments"));
    }
    if (opts[@"remove-parent"]) {
        ((void (*)(id, SEL))objc_msgSend)(changeItem, sel_registerName("removeFromParentReminder"));
    }
    if (opts[@"remove-from-list"]) {
        ((void (*)(id, SEL))objc_msgSend)(changeItem, sel_registerName("removeFromList"));
    }

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
    return cmdUpdate(store, nil, @{@"id": remId, @"url": urlStr});
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
        @"due-date", @"start-date", @"url", @"clear-url", @"remove-parent", @"remove-from-list",
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
                BOOL clearUrl = [op[@"clear-url"] boolValue];
                if (op[@"url"] && clearUrl) {
                    errorExit(@"Cannot use 'url' and 'clear-url' together in batch update");
                }
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
                if (clearUrl) { id attCtx = ((id (*)(id, SEL))objc_msgSend)(changeItem, sel_registerName("attachmentContext")); ((void (*)(id, SEL))objc_msgSend)(attCtx, sel_registerName("removeURLAttachments")); }
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

    // Test 2: cmdLists
    fprintf(stderr, "Test 2: cmdLists...\n");
    { int r = cmdLists(store); if (r==0) { fprintf(stderr, "  PASS\n"); passed++; } else { fprintf(stderr, "  FAIL\n"); failed++; } }

    // Test 3: cmdAdd
    fprintf(stderr, "Test 3: cmdAdd...\n");
    { int r = cmdAdd(store, parentTitle, testListName, @{@"notes": @"Test notes", @"priority": @"5"}); if (r==0) { fprintf(stderr, "  PASS\n"); passed++; } else { fprintf(stderr, "  FAIL\n"); failed++; } }

    // Test 4: cmdGet
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

    // Test 8: Verify parent-child
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

    // Test 10: Verify tag
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

    // Test 12: cmdComplete
    fprintf(stderr, "Test 12: cmdComplete...\n");
    {
        id rem12 = findReminder(store, childTitle, testListName);
        NSString *rem12ID = objectIDToString(((id (*)(id, SEL))objc_msgSend)(rem12, sel_registerName("objectID")));
        int r = cmdComplete(store, testListName, rem12ID);
        if (r==0) { fprintf(stderr, "  PASS\n"); passed++; } else { fprintf(stderr, "  FAIL\n"); failed++; }
    }

    // Test 13: cmdList
    fprintf(stderr, "Test 13: cmdList...\n");
    { int r = cmdList(store, testListName, NO); if (r==0) { fprintf(stderr, "  PASS\n"); passed++; } else { fprintf(stderr, "  FAIL\n"); failed++; } }

    // Test 14: JSON shape
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

    // Test 15: Rename via update
    fprintf(stderr, "Test 15: Rename via update...\n");
    {
        NSString *renamedTitle = @"__remcli_test_renamed__";
        id rem15 = findReminder(store, parentTitle, testListName);
        NSString *rem15ID = objectIDToString(((id (*)(id, SEL))objc_msgSend)(rem15, sel_registerName("objectID")));
        int r = cmdUpdate(store, testListName, @{@"id": rem15ID, @"title": renamedTitle});
        if (r == 0) {
            id found = findReminder(store, renamedTitle, testListName);
            if (found) {
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
                cmdRenameList(store, renamedList, testListName);
                fprintf(stderr, "  PASS\n"); passed++;
            } else { fprintf(stderr, "  FAIL (not found after rename)\n"); failed++; }
        } else { fprintf(stderr, "  FAIL\n"); failed++; }
    }

    // Test 17: cmdSubtasks
    fprintf(stderr, "Test 17: cmdSubtasks...\n");
    { int r = cmdSubtasks(store, parentTitle, testListName); if (r==0) { fprintf(stderr, "  PASS\n"); passed++; } else { fprintf(stderr, "  FAIL\n"); failed++; } }

    // Test 18: Error path (not found)
    fprintf(stderr, "Test 18: Error path (not found)...\n");
    {
        id notFound = findReminder(store, @"__nonexistent_reminder_999__", testListName);
        if (!notFound) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (should be nil)\n"); failed++; }
    }

    // Test 19: Error path (list not found)
    fprintf(stderr, "Test 19: Error path (list not found)...\n");
    {
        id notFound = findList(store, @"__nonexistent_list_999__");
        if (!notFound) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (should be nil)\n"); failed++; }
    }

    // Test 20: --append-notes
    fprintf(stderr, "Test 20: cmdUpdate --append-notes...\n");
    {
        id rem20 = findReminder(store, parentTitle, testListName);
        NSString *rem20ID = objectIDToString(((id (*)(id, SEL))objc_msgSend)(rem20, sel_registerName("objectID")));
        int r = cmdUpdate(store, testListName, @{@"id": rem20ID, @"append-notes": @"Appended line"});
        if (r==0) { fprintf(stderr, "  PASS\n"); passed++; } else { fprintf(stderr, "  FAIL\n"); failed++; }
    }

    // Test 21: Verify append-notes
    fprintf(stderr, "Test 21: Verify append-notes...\n");
    {
        id rem = findReminder(store, parentTitle, testListName);
        NSString *notes = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("notesAsString"));
        if ([notes isEqualToString:@"Updated\nAppended line"]) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (notes=%s)\n", [notes UTF8String]); failed++; }
    }

    // Test 22: cmdAdd with --parent-id
    fprintf(stderr, "Test 22: cmdAdd with --parent-id...\n");
    {
        NSString *addParentChildTitle = @"__remcli_test_add_parent_child__";
        id parentRem22 = findReminder(store, parentTitle, testListName);
        NSString *parentID22 = objectIDToString(((id (*)(id, SEL))objc_msgSend)(parentRem22, sel_registerName("objectID")));
        int r = cmdAdd(store, addParentChildTitle, nil, @{@"parent-id": parentID22});
        if (r == 0) {
            id child22 = findReminder(store, addParentChildTitle, testListName);
            if (child22) {
                id childPID22 = ((id (*)(id, SEL))objc_msgSend)(child22, sel_registerName("parentReminderID"));
                id parentOID22 = ((id (*)(id, SEL))objc_msgSend)(parentRem22, sel_registerName("objectID"));
                if (childPID22 && [objectIDToString(childPID22) isEqualToString:objectIDToString(parentOID22)]) {
                    fprintf(stderr, "  PASS\n"); passed++;
                } else { fprintf(stderr, "  FAIL (not parented correctly)\n"); failed++; }
                NSString *child22ID = objectIDToString(((id (*)(id, SEL))objc_msgSend)(child22, sel_registerName("objectID")));
                cmdDelete(store, testListName, child22ID);
            } else { fprintf(stderr, "  FAIL (child not found in test list)\n"); failed++; }
        } else { fprintf(stderr, "  FAIL (cmdAdd returned %d)\n", r); failed++; }
    }

    // Test 23: Parentheses in title
    fprintf(stderr, "Test 23: Parentheses in title...\n");
    {
        NSString *parensTitle = @"__remcli_test_parens (hello)__";
        int r = cmdAdd(store, parensTitle, testListName, @{});
        if (r == 0) {
            id found = findReminder(store, parensTitle, testListName);
            if (found) {
                fprintf(stderr, "  PASS\n"); passed++;
                NSString *foundID = objectIDToString(((id (*)(id, SEL))objc_msgSend)(found, sel_registerName("objectID")));
                cmdDelete(store, testListName, foundID);
            } else { fprintf(stderr, "  FAIL (not found after create)\n"); failed++; }
        } else { fprintf(stderr, "  FAIL (cmdAdd returned %d)\n", r); failed++; }
    }

    // Test 24: findReminder normalized fallback (curly apostrophe)
    fprintf(stderr, "Test 24: findReminder normalized fallback...\n");
    {
        NSString *curlyTitle = @"Test\u2019s curly apostrophe";
        NSString *straightTitle = @"Test's curly apostrophe";
        int r = cmdAdd(store, curlyTitle, testListName, @{});
        if (r == 0) {
            id found = findReminder(store, straightTitle, testListName);
            if (found) {
                fprintf(stderr, "  PASS\n"); passed++;
            } else { fprintf(stderr, "  FAIL (not found via normalized match)\n"); failed++; }
            id rem24c = findReminder(store, curlyTitle, testListName);
            if (rem24c) {
                NSString *rem24cID = objectIDToString(((id (*)(id, SEL))objc_msgSend)(rem24c, sel_registerName("objectID")));
                cmdDelete(store, testListName, rem24cID);
            }
        } else { fprintf(stderr, "  FAIL (could not create reminder)\n"); failed++; }
    }

    // Test 25: findList normalized fallback (curly apostrophe)
    fprintf(stderr, "Test 25: findList normalized fallback...\n");
    {
        NSString *curlyListName25 = @"__test_list\u2019s__";
        NSString *straightListName25 = @"__test_list's__";
        int r = cmdCreateList(store, curlyListName25);
        if (r == 0) {
            id found = findList(store, straightListName25);
            if (found) {
                fprintf(stderr, "  PASS\n"); passed++;
            } else { fprintf(stderr, "  FAIL (not found via normalized match)\n"); failed++; }
            cmdDeleteList(store, curlyListName25);
        } else { fprintf(stderr, "  FAIL (could not create list)\n"); failed++; }
    }

    // Test 26: exact match takes priority -- reminder collision
    fprintf(stderr, "Test 26: Exact match priority (reminder)...\n");
    {
        NSString *straightTitle26 = @"Bob's reminder";
        NSString *curlyTitle26 = @"Bob\u2019s reminder";
        int r1 = cmdAdd(store, straightTitle26, testListName, @{@"notes": @"straight"});
        int r2 = cmdAdd(store, curlyTitle26, testListName, @{@"notes": @"curly"});
        if (r1 == 0 && r2 == 0) {
            id foundStraight = findReminder(store, straightTitle26, testListName);
            NSString *notesStraight = foundStraight ? ((id (*)(id, SEL))objc_msgSend)(foundStraight, sel_registerName("notesAsString")) : nil;
            id foundCurly = findReminder(store, curlyTitle26, testListName);
            NSString *notesCurly = foundCurly ? ((id (*)(id, SEL))objc_msgSend)(foundCurly, sel_registerName("notesAsString")) : nil;
            if ([notesStraight isEqualToString:@"straight"] && [notesCurly isEqualToString:@"curly"]) {
                fprintf(stderr, "  PASS\n"); passed++;
            } else {
                fprintf(stderr, "  FAIL (straight notes=%s, curly notes=%s)\n",
                    [notesStraight UTF8String], [notesCurly UTF8String]); failed++;
            }
        } else { fprintf(stderr, "  FAIL (could not create reminders)\n"); failed++; }
        id rem26a = findReminder(store, straightTitle26, testListName);
        if (rem26a) { NSString *id26a = objectIDToString(((id (*)(id, SEL))objc_msgSend)(rem26a, sel_registerName("objectID"))); cmdDelete(store, testListName, id26a); }
        id rem26b = findReminder(store, curlyTitle26, testListName);
        if (rem26b) { NSString *id26b = objectIDToString(((id (*)(id, SEL))objc_msgSend)(rem26b, sel_registerName("objectID"))); cmdDelete(store, testListName, id26b); }
    }

    // Test 27: exact match takes priority -- list collision
    fprintf(stderr, "Test 27: Exact match priority (list)...\n");
    {
        NSString *straightListName27 = @"__test Bob's List__";
        NSString *curlyListName27 = @"__test Bob\u2019s List__";
        int r1 = cmdCreateList(store, straightListName27);
        int r2 = cmdCreateList(store, curlyListName27);
        if (r1 == 0 && r2 == 0) {
            id foundStraight = findList(store, straightListName27);
            id foundCurly = findList(store, curlyListName27);
            if (foundStraight && foundCurly) {
                id straightStorage = ((id (*)(id, SEL))objc_msgSend)(foundStraight, sel_registerName("storage"));
                NSString *straightName = ((id (*)(id, SEL))objc_msgSend)(straightStorage, sel_registerName("name"));
                id curlyStorage = ((id (*)(id, SEL))objc_msgSend)(foundCurly, sel_registerName("storage"));
                NSString *curlyName = ((id (*)(id, SEL))objc_msgSend)(curlyStorage, sel_registerName("name"));
                if ([straightName isEqualToString:straightListName27] && [curlyName isEqualToString:curlyListName27]) {
                    fprintf(stderr, "  PASS\n"); passed++;
                } else { fprintf(stderr, "  FAIL (wrong list matched)\n"); failed++; }
            } else { fprintf(stderr, "  FAIL (could not find lists)\n"); failed++; }
        } else { fprintf(stderr, "  FAIL (could not create lists)\n"); failed++; }
        cmdDeleteList(store, straightListName27);
        cmdDeleteList(store, curlyListName27);
    }

    // --- Note linking tests ---

    // Test 28: Create reminder with applenotes:// URL, verify linkedNoteId
    fprintf(stderr, "Test 28: Add with applenotes:// URL...\n");
    {
        NSString *noteTitle28 = @"__remcli_test_note_url__";
        int r = cmdAdd(store, noteTitle28, testListName, @{@"url": @"applenotes://showNote?identifier=FAKE-NOTE-ID"});
        if (r == 0) {
            id rem = findReminder(store, noteTitle28, testListName);
            NSDictionary *dict = reminderToDict(rem);
            if ([dict[@"url"] isEqualToString:@"applenotes://showNote?identifier=FAKE-NOTE-ID"]
                && [dict[@"linkedNoteId"] isEqualToString:@"FAKE-NOTE-ID"]) {
                fprintf(stderr, "  PASS\n"); passed++;
            } else { fprintf(stderr, "  FAIL (url=%s, linkedNoteId=%s)\n", [dict[@"url"] UTF8String], [dict[@"linkedNoteId"] UTF8String]); failed++; }
        } else { fprintf(stderr, "  FAIL (cmdAdd returned %d)\n", r); failed++; }
    }

    // Test 29: Update reminder with different note URL
    fprintf(stderr, "Test 29: Update with applenotes:// URL...\n");
    {
        id rem29 = findReminder(store, @"__remcli_test_note_url__", testListName);
        NSString *rem29ID = objectIDToString(((id (*)(id, SEL))objc_msgSend)(rem29, sel_registerName("objectID")));
        int r = cmdUpdate(store, testListName, @{@"id": rem29ID, @"url": @"applenotes://showNote?identifier=OTHER-NOTE-ID"});
        if (r == 0) {
            id updated = findReminderByID(store, rem29ID);
            NSDictionary *dict = reminderToDict(updated);
            if ([dict[@"linkedNoteId"] isEqualToString:@"OTHER-NOTE-ID"]) {
                fprintf(stderr, "  PASS\n"); passed++;
            } else { fprintf(stderr, "  FAIL (linkedNoteId=%s)\n", [dict[@"linkedNoteId"] UTF8String]); failed++; }
        } else { fprintf(stderr, "  FAIL\n"); failed++; }
    }

    // Test 30: link-note command
    fprintf(stderr, "Test 30: link-note command...\n");
    {
        id rem30 = findReminder(store, @"__remcli_test_note_url__", testListName);
        NSString *rem30ID = objectIDToString(((id (*)(id, SEL))objc_msgSend)(rem30, sel_registerName("objectID")));
        int r = cmdLinkNote(store, rem30ID, @"YET-ANOTHER-ID");
        if (r == 0) {
            id updated = findReminderByID(store, rem30ID);
            NSDictionary *dict = reminderToDict(updated);
            if ([dict[@"url"] isEqualToString:@"applenotes://showNote?identifier=YET-ANOTHER-ID"]
                && [dict[@"linkedNoteId"] isEqualToString:@"YET-ANOTHER-ID"]) {
                fprintf(stderr, "  PASS\n"); passed++;
            } else { fprintf(stderr, "  FAIL (url=%s, linkedNoteId=%s)\n", [dict[@"url"] UTF8String], [dict[@"linkedNoteId"] UTF8String]); failed++; }
        } else { fprintf(stderr, "  FAIL\n"); failed++; }
    }

    // Test 31: clear-url removes URL and linkedNoteId
    fprintf(stderr, "Test 31: --clear-url...\n");
    {
        id rem31 = findReminder(store, @"__remcli_test_note_url__", testListName);
        NSString *rem31ID = objectIDToString(((id (*)(id, SEL))objc_msgSend)(rem31, sel_registerName("objectID")));
        int r = cmdUpdate(store, testListName, @{@"id": rem31ID, @"clear-url": @"true"});
        if (r == 0) {
            id updated = findReminderByID(store, rem31ID);
            NSDictionary *dict = reminderToDict(updated);
            if (dict[@"url"] == nil && dict[@"linkedNoteId"] == nil) {
                fprintf(stderr, "  PASS\n"); passed++;
            } else { fprintf(stderr, "  FAIL (url=%s, linkedNoteId=%s)\n", [dict[@"url"] UTF8String], [dict[@"linkedNoteId"] UTF8String]); failed++; }
        } else { fprintf(stderr, "  FAIL\n"); failed++; }
    }

    // Test 32: Non-note URL should not have linkedNoteId
    fprintf(stderr, "Test 32: Non-note URL has no linkedNoteId...\n");
    {
        id rem32 = findReminder(store, @"__remcli_test_note_url__", testListName);
        NSString *rem32ID = objectIDToString(((id (*)(id, SEL))objc_msgSend)(rem32, sel_registerName("objectID")));
        int r = cmdUpdate(store, testListName, @{@"id": rem32ID, @"url": @"https://example.com"});
        if (r == 0) {
            id updated = findReminderByID(store, rem32ID);
            NSDictionary *dict = reminderToDict(updated);
            if (dict[@"url"] != nil && dict[@"linkedNoteId"] == nil) {
                fprintf(stderr, "  PASS\n"); passed++;
            } else { fprintf(stderr, "  FAIL (url=%s, linkedNoteId=%s)\n", [dict[@"url"] UTF8String], [dict[@"linkedNoteId"] UTF8String]); failed++; }
        } else { fprintf(stderr, "  FAIL\n"); failed++; }
    }

    // Test 33: Malformed applenotes:// URL (not showNote) has no linkedNoteId
    fprintf(stderr, "Test 33: Malformed applenotes:// URL...\n");
    {
        id rem33 = findReminder(store, @"__remcli_test_note_url__", testListName);
        NSString *rem33ID = objectIDToString(((id (*)(id, SEL))objc_msgSend)(rem33, sel_registerName("objectID")));
        int r = cmdUpdate(store, testListName, @{@"id": rem33ID, @"url": @"applenotes://other?foo=bar"});
        if (r == 0) {
            id updated = findReminderByID(store, rem33ID);
            NSDictionary *dict = reminderToDict(updated);
            if (dict[@"url"] != nil && dict[@"linkedNoteId"] == nil) {
                fprintf(stderr, "  PASS\n"); passed++;
            } else { fprintf(stderr, "  FAIL (linkedNoteId should be nil)\n"); failed++; }
        } else { fprintf(stderr, "  FAIL\n"); failed++; }
    }

    // Test 34: applenotes:// URL without identifier param has no linkedNoteId
    fprintf(stderr, "Test 34: applenotes://showNote without identifier...\n");
    {
        id rem34 = findReminder(store, @"__remcli_test_note_url__", testListName);
        NSString *rem34ID = objectIDToString(((id (*)(id, SEL))objc_msgSend)(rem34, sel_registerName("objectID")));
        int r = cmdUpdate(store, testListName, @{@"id": rem34ID, @"url": @"applenotes://showNote"});
        if (r == 0) {
            id updated = findReminderByID(store, rem34ID);
            NSDictionary *dict = reminderToDict(updated);
            if (dict[@"url"] != nil && dict[@"linkedNoteId"] == nil) {
                fprintf(stderr, "  PASS\n"); passed++;
            } else { fprintf(stderr, "  FAIL (linkedNoteId should be nil)\n"); failed++; }
        } else { fprintf(stderr, "  FAIL\n"); failed++; }
    }

    // Test 35: --url and --clear-url together (conflict, subprocess)
    fprintf(stderr, "Test 35: --url and --clear-url conflict...\n");
    {
        char exePath[PATH_MAX];
        uint32_t exeSize = sizeof(exePath);
        _NSGetExecutablePath(exePath, &exeSize);
        realpath(exePath, exePath);
        NSString *quotedExe = [NSString stringWithFormat:@"'%s'",
            [[[NSString stringWithUTF8String:exePath]
              stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]
             UTF8String]];
        NSString *cmd35 = [NSString stringWithFormat:@"%@ update --id VALID --url 'https://x.com' --clear-url 2>/dev/null", quotedExe];
        int r = system([cmd35 UTF8String]);
        if (r != 0) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (should have errored)\n"); failed++; }
    }

    // Test 36: link-note missing --note-id (subprocess)
    fprintf(stderr, "Test 36: link-note missing --note-id...\n");
    {
        char exePath[PATH_MAX];
        uint32_t exeSize = sizeof(exePath);
        _NSGetExecutablePath(exePath, &exeSize);
        realpath(exePath, exePath);
        NSString *quotedExe = [NSString stringWithFormat:@"'%s'",
            [[[NSString stringWithUTF8String:exePath]
              stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]
             UTF8String]];
        NSString *cmd36 = [NSString stringWithFormat:@"%@ link-note --id VALID 2>/dev/null", quotedExe];
        int r = system([cmd36 UTF8String]);
        if (r != 0) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (should have errored)\n"); failed++; }
    }

    // Test 37: link-note missing --id (subprocess)
    fprintf(stderr, "Test 37: link-note missing --id...\n");
    {
        char exePath[PATH_MAX];
        uint32_t exeSize = sizeof(exePath);
        _NSGetExecutablePath(exePath, &exeSize);
        realpath(exePath, exePath);
        NSString *quotedExe = [NSString stringWithFormat:@"'%s'",
            [[[NSString stringWithUTF8String:exePath]
              stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]
             UTF8String]];
        NSString *cmd37 = [NSString stringWithFormat:@"%@ link-note --note-id FAKE 2>/dev/null", quotedExe];
        int r = system([cmd37 UTF8String]);
        if (r != 0) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (should have errored)\n"); failed++; }
    }

    // Clean up note test reminder
    {
        id remClean = findReminder(store, @"__remcli_test_note_url__", testListName);
        if (remClean) {
            NSString *remCleanID = objectIDToString(((id (*)(id, SEL))objc_msgSend)(remClean, sel_registerName("objectID")));
            cmdDelete(store, testListName, remCleanID);
        }
    }

    // Test 38: findReminders returns multiple matches (substring search)
    fprintf(stderr, "Test 38: findReminders multiple matches...\n");
    {
        NSString *searchTitle2 = @"__remcli_test_parent_searchdup__";
        cmdAdd(store, searchTitle2, testListName, @{});
        NSArray *matches = findReminders(store, @"__remcli_test_parent", testListName);
        if (matches.count >= 2) {
            fprintf(stderr, "  PASS (found %lu matches)\n", (unsigned long)matches.count);
            passed++;
        } else {
            fprintf(stderr, "  FAIL (expected >=2, got %lu)\n", (unsigned long)matches.count);
            failed++;
        }
        // Clean up the extra reminder
        id dup = findReminder(store, searchTitle2, testListName);
        if (dup) {
            NSString *dupID = objectIDToString(((id (*)(id, SEL))objc_msgSend)(dup, sel_registerName("objectID")));
            cmdDelete(store, testListName, dupID);
        }
    }

    // Cleanup
    // Test 39: cmdDelete child
    fprintf(stderr, "Test 39: cmdDelete child...\n");
    {
        id rem39 = findReminder(store, childTitle, testListName);
        NSString *rem39ID = objectIDToString(((id (*)(id, SEL))objc_msgSend)(rem39, sel_registerName("objectID")));
        int r = cmdDelete(store, testListName, rem39ID);
        if (r==0) { fprintf(stderr, "  PASS\n"); passed++; } else { fprintf(stderr, "  FAIL\n"); failed++; }
    }

    // Test 40: cmdDelete parent
    fprintf(stderr, "Test 40: cmdDelete parent...\n");
    {
        id rem40 = findReminder(store, parentTitle, testListName);
        NSString *rem40ID = objectIDToString(((id (*)(id, SEL))objc_msgSend)(rem40, sel_registerName("objectID")));
        int r = cmdDelete(store, testListName, rem40ID);
        if (r==0) { fprintf(stderr, "  PASS\n"); passed++; } else { fprintf(stderr, "  FAIL\n"); failed++; }
    }

    // Test 41: cmdDeleteList
    fprintf(stderr, "Test 41: cmdDeleteList...\n");
    { int r = cmdDeleteList(store, testListName); if (r==0) {
        id gone = findList(store, testListName);
        if (!gone) { fprintf(stderr, "  PASS\n"); passed++; } else { fprintf(stderr, "  FAIL (still exists)\n"); failed++; }
    } else { fprintf(stderr, "  FAIL\n"); failed++; } }

    fprintf(stderr, "\nResults: %d passed, %d failed\n", passed, failed);
    return failed > 0 ? 1 : 0;
}



// --- Install Skill ---

static int cmdInstallSkill(BOOL installClaude, BOOL installAgents, BOOL force) {
    char execPath[PATH_MAX];
    uint32_t size = sizeof(execPath);
    if (_NSGetExecutablePath(execPath, &size) != 0) {
        fprintf(stderr, "Error: could not determine executable path\n");
        return 1;
    }
    char realPath[PATH_MAX];
    if (!realpath(execPath, realPath)) {
        fprintf(stderr, "Error: could not resolve executable path\n");
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
        fprintf(stderr, "Error: could not find SKILL.md relative to binary at %s\n", realPath);
        fprintf(stderr, "Searched:\n");
        for (NSString *candidate in candidates) {
            fprintf(stderr, "  %s\n", [[candidate stringByStandardizingPath] UTF8String]);
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
                fprintf(stderr, "Error: %s already exists (use --force to overwrite)\n", [path UTF8String]);
                failures++;
                continue;
            }
            [fm removeItemAtPath:path error:nil];
        }
        if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&error]) {
            fprintf(stderr, "Error: could not create directory %s: %s\n",
                [dir UTF8String], [[error localizedDescription] UTF8String]);
            failures++;
            continue;
        }
        if (![fm createSymbolicLinkAtPath:path withDestinationPath:sourcePath error:&error]) {
            fprintf(stderr, "Error: could not create symlink: %s\n",
                [[error localizedDescription] UTF8String]);
            failures++;
            continue;
        }
        printf("Installed skill: %s -> %s\n", [path UTF8String], [sourcePath UTF8String]);
    }

    return failures > 0 ? 1 : 0;
}


// --- Usage ---

static void usage(void) {
    fprintf(stderr, "Usage:\n");
    fprintf(stderr, "  reminderkit lists\n");
    fprintf(stderr, "  reminderkit list --name <name> [--include-completed]\n");
    fprintf(stderr, "  reminderkit search --title <title> [--list <name>]\n");
    fprintf(stderr, "  reminderkit get --title <title> [--list <name>]  (alias for search)\n");
    fprintf(stderr, "  reminderkit subtasks --title <title> [--list <name>]\n");
    fprintf(stderr, "  reminderkit add --title <title> [--list <name>] [--notes <value>] [--completed <value>] [--priority <value>] [--flagged <value>] [--due-date <value>] [--start-date <value>] [--url <value>] [--parent-id <id>]\n");
    fprintf(stderr, "  reminderkit update --id <id> [--list <name>] [--notes <value>] [--append-notes <value>] [--completed <value>] [--priority <value>] [--flagged <value>] [--due-date <value>] [--start-date <value>] [--url <value>] [--clear-url] [--remove-parent] [--remove-from-list] [--parent-id <id>] [--to-list <name>]\n");
    fprintf(stderr, "  reminderkit link-note --id <id> --note-id <note-identifier>\n");
    fprintf(stderr, "  reminderkit complete --id <id> [--list <name>]\n");
    fprintf(stderr, "  reminderkit delete --id <id> [--list <name>]\n");
    fprintf(stderr, "  reminderkit add-tag --id <id> --tag <tag-name>\n");
    fprintf(stderr, "  reminderkit remove-tag --id <id> --tag <tag-name>\n");
    fprintf(stderr, "  reminderkit link-note --id <id> --note-id <note-id>\n");
    fprintf(stderr, "  reminderkit list-sections --name <list-name>\n");
    fprintf(stderr, "  reminderkit create-section --name <list-name> --section <section-name>\n");
    fprintf(stderr, "  reminderkit create-list --name <name>\n");
    fprintf(stderr, "  reminderkit rename-list --old-name <old-name> --new-name <new-name>\n");
    fprintf(stderr, "  reminderkit delete-list --name <name>\n");
    fprintf(stderr, "  reminderkit batch  (reads JSON array from stdin)\n");
    fprintf(stderr, "\n  Skill management:\n");
    fprintf(stderr, "  reminderkit install-skill [--claude] [--agents] [--force]\n");
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
                    [flag isEqualToString:@"clear-url"] ||
                    [flag isEqualToString:@"help"] ||
                    [flag isEqualToString:@"clear-url"] ||
                    [flag isEqualToString:@"claude"] ||
                    [flag isEqualToString:@"agents"] ||
                    [flag isEqualToString:@"force"]) {
                    if ([flag isEqualToString:@"include-completed"]) includeCompleted = YES;
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
            fprintf(stderr, "Error: unexpected argument '%s'. All arguments must use --flag syntax.\n", [positional[0] UTF8String]);
            usage();
            return 1;
        }

        if ([command isEqualToString:@"lists"]) {
            return cmdLists(store);

        } else if ([command isEqualToString:@"list"]) {
            if (!kwName) { fprintf(stderr, "Error: --name required\n"); usage(); return 1; }
            return cmdList(store, kwName, includeCompleted);

        } else if ([command isEqualToString:@"search"] || [command isEqualToString:@"get"]) {
            if (!kwTitle) { fprintf(stderr, "Error: --title required\n"); usage(); return 1; }
            return cmdGet(store, kwTitle, listName);

        } else if ([command isEqualToString:@"subtasks"]) {
            if (!kwTitle) { fprintf(stderr, "Error: --title required\n"); usage(); return 1; }
            return cmdSubtasks(store, kwTitle, listName);

        } else if ([command isEqualToString:@"add"]) {
            if (!kwTitle) { fprintf(stderr, "Error: --title required\n"); usage(); return 1; }
            return cmdAdd(store, kwTitle, listName, opts);

        } else if ([command isEqualToString:@"update"]) {
            if (!opts[@"id"] || [opts[@"id"] length] == 0) { fprintf(stderr, "Error: --id required\n"); usage(); return 1; }
            return cmdUpdate(store, listName, opts);

        } else if ([command isEqualToString:@"link-note"]) {
            if (!opts[@"id"] || [opts[@"id"] length] == 0) { fprintf(stderr, "Error: link-note requires --id\n"); usage(); return 1; }
            if (!opts[@"note-id"] || [opts[@"note-id"] length] == 0) { fprintf(stderr, "Error: link-note requires --note-id\n"); usage(); return 1; }
            return cmdLinkNote(store, opts[@"id"], opts[@"note-id"]);

        } else if ([command isEqualToString:@"complete"]) {
            if (!opts[@"id"] || [opts[@"id"] length] == 0) { fprintf(stderr, "Error: --id required\n"); usage(); return 1; }
            return cmdComplete(store, listName, opts[@"id"]);

        } else if ([command isEqualToString:@"delete"]) {
            if (!opts[@"id"] || [opts[@"id"] length] == 0) { fprintf(stderr, "Error: --id required\n"); usage(); return 1; }
            return cmdDelete(store, listName, opts[@"id"]);

        } else if ([command isEqualToString:@"batch"]) {
            return cmdBatch(store);

        } else if ([command isEqualToString:@"add-tag"]) {
            if (!opts[@"id"] || [opts[@"id"] length] == 0) { fprintf(stderr, "Error: --id required\n"); usage(); return 1; }
            if (!kwTag) { fprintf(stderr, "Error: --tag required\n"); usage(); return 1; }
            return cmdAddTag(store, opts[@"id"], kwTag);

        } else if ([command isEqualToString:@"remove-tag"]) {
            if (!opts[@"id"] || [opts[@"id"] length] == 0) { fprintf(stderr, "Error: --id required\n"); usage(); return 1; }
            if (!kwTag) { fprintf(stderr, "Error: --tag required\n"); usage(); return 1; }
            return cmdRemoveTag(store, opts[@"id"], kwTag);

        } else if ([command isEqualToString:@"link-note"]) {
            if (!opts[@"id"] || [opts[@"id"] length] == 0) { fprintf(stderr, "Error: --id required\n"); usage(); return 1; }
            if (!opts[@"note-id"] || [opts[@"note-id"] length] == 0) { fprintf(stderr, "Error: --note-id required\n"); usage(); return 1; }
            return cmdLinkNote(store, opts[@"id"], opts[@"note-id"]);

        } else if ([command isEqualToString:@"list-sections"]) {
            if (!kwName) { fprintf(stderr, "Error: --name required\n"); usage(); return 1; }
            return cmdListSections(store, kwName);

        } else if ([command isEqualToString:@"create-section"]) {
            if (!kwName || !kwSection) { fprintf(stderr, "Error: --name and --section required\n"); usage(); return 1; }
            return cmdCreateSection(store, kwName, kwSection);

        } else if ([command isEqualToString:@"create-list"]) {
            if (!kwName) { fprintf(stderr, "Error: --name required\n"); usage(); return 1; }
            return cmdCreateList(store, kwName);

        } else if ([command isEqualToString:@"rename-list"]) {
            if (!kwOldName || !kwNewName) { fprintf(stderr, "Error: --old-name and --new-name required\n"); usage(); return 1; }
            return cmdRenameList(store, kwOldName, kwNewName);

        } else if ([command isEqualToString:@"delete-list"]) {
            if (!kwName) { fprintf(stderr, "Error: --name required\n"); usage(); return 1; }
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
            fprintf(stderr, "Unknown command: %s\n", [command UTF8String]);
            usage();
            return 1;
        }
    }
}

