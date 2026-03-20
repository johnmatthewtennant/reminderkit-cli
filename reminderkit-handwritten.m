// Handwritten commands — not produced by generate-cli.py

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
            if (!op[@"id"] || ![op[@"id"] isKindOfClass:[NSString class]] || [op[@"id"] length] == 0) {
                errorExit([NSString stringWithFormat:@"Operation %lu (%@) requires id", (unsigned long)i, opType]);
            }
        } else {
            if (!op[@"title"]) {
                errorExit([NSString stringWithFormat:@"Operation %lu (add) requires title", (unsigned long)i]);
            }
        }
        // Require tag for add-tag/remove-tag ops
        if ([opType isEqualToString:@"add-tag"] || [opType isEqualToString:@"remove-tag"]) {
            if (!op[@"tag"] || ![op[@"tag"] isKindOfClass:[NSString class]] || [op[@"tag"] length] == 0) {
                errorExit([NSString stringWithFormat:@"Operation %lu (%@) requires tag", (unsigned long)i, opType]);
            }
        }
        // Validate conflicting flags
        if ([opType isEqualToString:@"update"]) {
            if (op[@"url"] && op[@"clear-url"]) {
                errorExit([NSString stringWithFormat:@"Operation %lu: cannot use url and clear-url together", (unsigned long)i]);
            }
            if (op[@"parent-id"] && op[@"remove-parent"]) {
                errorExit([NSString stringWithFormat:@"Operation %lu: cannot use parent-id and remove-parent together", (unsigned long)i]);
            }
        }
        // Validate field types
        if (op[@"id"] && ![op[@"id"] isKindOfClass:[NSString class]]) {
            errorExit([NSString stringWithFormat:@"Operation %lu: id must be a string", (unsigned long)i]);
        }
        if (op[@"tag"] && ![op[@"tag"] isKindOfClass:[NSString class]]) {
            errorExit([NSString stringWithFormat:@"Operation %lu: tag must be a string", (unsigned long)i]);
        }
        if (op[@"title"] && ![op[@"title"] isKindOfClass:[NSString class]]) {
            errorExit([NSString stringWithFormat:@"Operation %lu: title must be a string", (unsigned long)i]);
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
            if (op[@"completed"]) {
                BOOL val = [op[@"completed"] isEqualToString:@"true"];
                ((void (*)(id, SEL, BOOL))objc_msgSend)(newRem, sel_registerName("setCompleted:"), val);
            }

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
                if (op[@"append-notes"]) {
                    NSString *existing = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("notesAsString"));
                    NSString *combined;
                    if (existing && [existing length] > 0) {
                        combined = [NSString stringWithFormat:@"%@\n%@", existing, op[@"append-notes"]];
                    } else {
                        combined = op[@"append-notes"];
                    }
                    ((void (*)(id, SEL, id))objc_msgSend)(changeItem, sel_registerName("setNotesAsString:"), combined);
                } else if (op[@"notes"]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(changeItem, sel_registerName("setNotesAsString:"), op[@"notes"]);
                }
                if (op[@"priority"]) ((void (*)(id, SEL, NSUInteger))objc_msgSend)(changeItem, sel_registerName("setPriority:"), [op[@"priority"] integerValue]);
                if (op[@"flagged"]) ((void (*)(id, SEL, NSInteger))objc_msgSend)(changeItem, sel_registerName("setFlagged:"), [op[@"flagged"] integerValue]);
                if (op[@"completed"]) {
                    BOOL val = [op[@"completed"] isEqualToString:@"true"];
                    ((void (*)(id, SEL, BOOL))objc_msgSend)(changeItem, sel_registerName("setCompleted:"), val);
                }
                if (op[@"due-date"]) ((void (*)(id, SEL, id))objc_msgSend)(changeItem, sel_registerName("setDueDateComponents:"), stringToDateComps(op[@"due-date"]));
                if (op[@"start-date"]) ((void (*)(id, SEL, id))objc_msgSend)(changeItem, sel_registerName("setStartDateComponents:"), stringToDateComps(op[@"start-date"]));
                if (op[@"url"]) { NSURL *u = [NSURL URLWithString:op[@"url"]]; if (u) { id attCtx = ((id (*)(id, SEL))objc_msgSend)(changeItem, sel_registerName("attachmentContext")); ((void (*)(id, SEL, id))objc_msgSend)(attCtx, sel_registerName("setURLAttachmentWithURL:"), u); } }
                if (op[@"clear-url"]) {
                    id attCtx = ((id (*)(id, SEL))objc_msgSend)(changeItem, sel_registerName("attachmentContext"));
                    ((void (*)(id, SEL))objc_msgSend)(attCtx, sel_registerName("removeURLAttachments"));
                }
                if (op[@"remove-parent"]) ((void (*)(id, SEL))objc_msgSend)(changeItem, sel_registerName("removeFromParentReminder"));
                if (op[@"remove-from-list"]) ((void (*)(id, SEL))objc_msgSend)(changeItem, sel_registerName("removeFromList"));

                // Reparent: parent-id
                if (op[@"parent-id"]) {
                    NSString *parentID = op[@"parent-id"];
                    id parentRem = findReminderByID(store, parentID);
                    if (!parentRem) errorExit([NSString stringWithFormat:@"Parent not found with id: %@", parentID]);
                    id parentObjID = ((id (*)(id, SEL))objc_msgSend)(parentRem, sel_registerName("objectID"));
                    if ([objectIDToString(remObjID) isEqualToString:objectIDToString(parentObjID)]) {
                        errorExit(@"Cannot set a reminder as its own parent");
                    }
                    id remListID = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("listID"));
                    id targetList = findListByObjectID(store, remListID);
                    if (!targetList) errorExit(@"Could not find list for reparenting");
                    id listCI = ((id (*)(id, SEL, id))objc_msgSend)(
                        saveReq, sel_registerName("updateList:"), targetList);
                    reparentChangeItem(store, saveReq, listCI, changeItem, parentID);
                }

                // Move to different list: to-list
                NSString *toListName = op[@"to-list"];
                if (toListName) {
                    id destList = findList(store, toListName);
                    if (!destList) errorExit([NSString stringWithFormat:@"Destination list not found: %@", toListName]);
                    id destListCI = ((id (*)(id, SEL, id))objc_msgSend)(
                        saveReq, sel_registerName("updateList:"), destList);
                    Class REMReminderCIClass = NSClassFromString(@"REMReminderChangeItem");
                    id moveCI = ((id (*)(id, SEL, id, id))objc_msgSend)(
                        [REMReminderCIClass alloc],
                        sel_registerName("initWithReminderChangeItem:insertIntoListChangeItem:"),
                        changeItem, destListCI);
                    if (!moveCI) errorExit(@"Failed to create move operation");
                }

                [results addObject:@{@"op": @"update", @"id": remIDStr ?: @"", @"status": @"ok"}];

            } else if ([opType isEqualToString:@"add-tag"]) {
                id hashtagCtx = ((id (*)(id, SEL))objc_msgSend)(changeItem, sel_registerName("hashtagContext"));
                if (!hashtagCtx) errorExit(@"Failed to get hashtag context");
                ((void (*)(id, SEL, NSUInteger, id))objc_msgSend)(
                    hashtagCtx, sel_registerName("addHashtagWithType:name:"), (NSUInteger)0, op[@"tag"]);
                [results addObject:@{@"op": @"add-tag", @"id": remIDStr ?: @"", @"tag": op[@"tag"], @"status": @"ok"}];

            } else if ([opType isEqualToString:@"remove-tag"]) {
                NSSet *tags = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName("hashtags"));
                id tagToRemove = nil;
                for (id tag in tags) {
                    NSString *name = ((id (*)(id, SEL))objc_msgSend)(tag, sel_registerName("name"));
                    if ([name isEqualToString:op[@"tag"]]) { tagToRemove = tag; break; }
                }
                if (!tagToRemove) errorExit([NSString stringWithFormat:@"Tag not found: %@", op[@"tag"]]);
                id hashtagCtx = ((id (*)(id, SEL))objc_msgSend)(changeItem, sel_registerName("hashtagContext"));
                ((void (*)(id, SEL, id))objc_msgSend)(hashtagCtx, sel_registerName("removeHashtag:"), tagToRemove);
                [results addObject:@{@"op": @"remove-tag", @"id": remIDStr ?: @"", @"tag": op[@"tag"], @"status": @"ok"}];
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
