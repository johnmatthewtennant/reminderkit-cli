// Test infrastructure — not produced by generate-cli.py

// --- Tests ---

// Helper: spawn the CLI binary with given args and assert it exits non-zero.
// Returns 1 on PASS (command exited non-zero), 0 on FAIL.
static int assertCliExitsNonZero(const char *testName, const char *argv[]) {
    // Resolve our own binary path
    char execPath[PATH_MAX];
    uint32_t size = sizeof(execPath);
    if (_NSGetExecutablePath(execPath, &size) != 0) {
        fprintf(stderr, "  FAIL (%s: could not get executable path)\n", testName);
        return 0;
    }
    char realPath[PATH_MAX];
    if (!realpath(execPath, realPath)) {
        fprintf(stderr, "  FAIL (%s: could not resolve executable path)\n", testName);
        return 0;
    }

    // Build argv with binary path as argv[0]
    // Count args
    int argc = 0;
    while (argv[argc]) argc++;
    const char *spawnArgv[argc + 2];
    spawnArgv[0] = realPath;
    for (int i = 0; i <= argc; i++) spawnArgv[i + 1] = argv[i]; // includes trailing NULL

    // Redirect stdout and stderr to /dev/null
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);

    pid_t pid;
    extern char **environ;
    int spawnErr = posix_spawn(&pid, realPath, &actions, NULL, (char *const *)spawnArgv, environ);
    posix_spawn_file_actions_destroy(&actions);

    if (spawnErr != 0) {
        fprintf(stderr, "  FAIL (%s: posix_spawn failed: %s)\n", testName, strerror(spawnErr));
        return 0;
    }

    // Wait with timeout (10 seconds)
    int status;
    for (int i = 0; i < 100; i++) {
        pid_t result = waitpid(pid, &status, WNOHANG);
        if (result == pid) {
            if (WIFEXITED(status) && WEXITSTATUS(status) != 0) {
                return 1; // PASS: exited non-zero
            } else {
                fprintf(stderr, "  FAIL (%s: expected non-zero exit, got %d)\n", testName,
                    WIFEXITED(status) ? WEXITSTATUS(status) : -1);
                return 0;
            }
        } else if (result < 0) {
            fprintf(stderr, "  FAIL (%s: waitpid error: %s)\n", testName, strerror(errno));
            return 0;
        }
        usleep(100000); // 100ms
    }
    // Timeout — kill and fail
    kill(pid, SIGKILL);
    waitpid(pid, &status, 0);
    fprintf(stderr, "  FAIL (%s: timed out after 10s)\n", testName);
    return 0;
}

// --- Test Helpers ---

// Capture stdout from a block into an NSData buffer.
// Uses a temp file to avoid pipe buffer deadlocks on large output.
static NSData *captureStdout(void (^block)(void)) {
    fflush(stdout);
    char tmpl[] = "/tmp/remcli-test-XXXXXX";
    int tmpfd = mkstemp(tmpl);
    if (tmpfd < 0) return nil;
    unlink(tmpl);

    int savedStdout = dup(STDOUT_FILENO);
    if (savedStdout < 0) { close(tmpfd); return nil; }
    if (dup2(tmpfd, STDOUT_FILENO) < 0) { close(tmpfd); close(savedStdout); return nil; }
    close(tmpfd);

    block();
    fflush(stdout);

    tmpfd = dup(STDOUT_FILENO);
    if (tmpfd < 0) { dup2(savedStdout, STDOUT_FILENO); close(savedStdout); return nil; }
    if (dup2(savedStdout, STDOUT_FILENO) < 0) { close(tmpfd); close(savedStdout); return nil; }
    close(savedStdout);

    lseek(tmpfd, 0, SEEK_SET);
    NSMutableData *buf = [NSMutableData data];
    char tmp[4096];
    ssize_t n;
    while ((n = read(tmpfd, tmp, sizeof(tmp))) > 0) {
        [buf appendBytes:tmp length:n];
    }
    close(tmpfd);
    return buf;
}

// Parse captured stdout as JSON. Returns nil on failure.
// Logs parse errors to stderr for debuggability.
static id parseJSONFromData(NSData *data) {
    if (!data || data.length == 0) return nil;
    NSError *err = nil;
    id result = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (err) fprintf(stderr, "  JSON parse error: %s\n", [[err localizedDescription] UTF8String]);
    return result;
}

// Capture stdout from a block that reads from stdin, feeding stdinStr as input.
static NSData *captureStdoutWithStdin(NSString *stdinStr, void (^block)(void)) {
    fflush(stdout);
    fflush(stdin);
    int stdinPipe[2];
    if (pipe(stdinPipe) < 0) return nil;
    NSData *inputData = [stdinStr dataUsingEncoding:NSUTF8StringEncoding];
    write(stdinPipe[1], inputData.bytes, inputData.length);
    close(stdinPipe[1]);
    int savedStdin = dup(STDIN_FILENO);
    dup2(stdinPipe[0], STDIN_FILENO);
    close(stdinPipe[0]);
    NSData *result = captureStdout(block);
    dup2(savedStdin, STDIN_FILENO);
    close(savedStdin);
    return result;
}

// Check that a JSON array contains at least one dict with the given key.
static BOOL jsonArrayHasKey(NSArray *arr, NSString *key) {
    for (NSDictionary *item in arr) {
        if ([item isKindOfClass:[NSDictionary class]] && item[key] != nil) return YES;
    }
    return NO;
}

// Check that ALL dicts in a JSON array have the given key.
static BOOL jsonArrayAllHaveKey(NSArray *arr, NSString *key) {
    if (arr.count == 0) return NO;
    for (id item in arr) {
        if (![item isKindOfClass:[NSDictionary class]] || ((NSDictionary *)item)[key] == nil) return NO;
    }
    return YES;
}

// Find the first dict in a JSON array with a matching value for a key.
static NSDictionary *jsonArrayFind(NSArray *arr, NSString *key, NSString *value) {
    for (id item in arr) {
        if ([item isKindOfClass:[NSDictionary class]]) {
            id v = ((NSDictionary *)item)[key];
            if ([v isKindOfClass:[NSString class]] && [v isEqualToString:value]) return item;
        }
    }
    return nil;
}

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

    // Test 2: cmdLists (verify JSON output shape)
    fprintf(stderr, "Test 2: cmdLists JSON shape...\n");
    {
        __block int r = -1;
        NSData *out = captureStdout(^{ r = cmdLists(store); });
        if (r != 0) { fprintf(stderr, "  FAIL (returned %d)\n", r); failed++; }
        else {
            id json = parseJSONFromData(out);
            if (![json isKindOfClass:[NSArray class]]) {
                fprintf(stderr, "  FAIL (not a JSON array)\n"); failed++;
            } else if (!jsonArrayAllHaveKey(json, @"name") || !jsonArrayAllHaveKey(json, @"id")) {
                fprintf(stderr, "  FAIL (not all items have 'name' and 'id')\n"); failed++;
            } else if (!jsonArrayFind(json, @"name", testListName)) {
                fprintf(stderr, "  FAIL (test list not found in output)\n"); failed++;
            } else { fprintf(stderr, "  PASS\n"); passed++; }
        }
    }

    // Test 3: cmdAdd
    fprintf(stderr, "Test 3: cmdAdd...\n");
    { int r = cmdAdd(store, parentTitle, testListName, @{@"notes": @"Test notes", @"priority": @"5"}); if (r==0) { fprintf(stderr, "  PASS\n"); passed++; } else { fprintf(stderr, "  FAIL\n"); failed++; } }

    // Test 4: cmdGet (verify JSON output shape)
    fprintf(stderr, "Test 4: cmdGet JSON shape...\n");
    {
        __block int r = -1;
        NSData *out = captureStdout(^{ r = cmdGet(store, parentTitle, testListName); });
        if (r != 0) { fprintf(stderr, "  FAIL (returned %d)\n", r); failed++; }
        else {
            id json = parseJSONFromData(out);
            if (![json isKindOfClass:[NSDictionary class]]) {
                fprintf(stderr, "  FAIL (not a JSON object)\n"); failed++;
            } else {
                NSDictionary *dict = json;
                BOOL ok = dict[@"title"] && dict[@"id"] && dict[@"completed"] != nil
                    && dict[@"priority"] != nil && dict[@"createdAt"] && dict[@"modifiedAt"];
                if (ok) { fprintf(stderr, "  PASS\n"); passed++; }
                else { fprintf(stderr, "  FAIL (missing expected fields)\n"); failed++; }
            }
        }
    }

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

    // Test 13: cmdList (verify JSON output shape)
    fprintf(stderr, "Test 13: cmdList JSON shape...\n");
    {
        __block int r = -1;
        NSData *out = captureStdout(^{ r = cmdList(store, testListName, NO); });
        if (r != 0) { fprintf(stderr, "  FAIL (returned %d)\n", r); failed++; }
        else {
            id json = parseJSONFromData(out);
            if (![json isKindOfClass:[NSArray class]]) {
                fprintf(stderr, "  FAIL (not a JSON array)\n"); failed++;
            } else if (!jsonArrayAllHaveKey(json, @"title") || !jsonArrayAllHaveKey(json, @"id")
                    || !jsonArrayAllHaveKey(json, @"completed") || !jsonArrayAllHaveKey(json, @"priority")) {
                fprintf(stderr, "  FAIL (not all items have expected fields)\n"); failed++;
            } else if (!jsonArrayFind(json, @"title", parentTitle)) {
                fprintf(stderr, "  FAIL (parent reminder not found in output)\n"); failed++;
            } else { fprintf(stderr, "  PASS\n"); passed++; }
        }
    }

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

    // Test 17: cmdSubtasks (verify JSON output shape)
    fprintf(stderr, "Test 17: cmdSubtasks JSON shape...\n");
    {
        __block int r = -1;
        NSData *out = captureStdout(^{ r = cmdSubtasks(store, parentTitle, testListName); });
        if (r != 0) { fprintf(stderr, "  FAIL (returned %d)\n", r); failed++; }
        else {
            id json = parseJSONFromData(out);
            if (![json isKindOfClass:[NSArray class]]) {
                fprintf(stderr, "  FAIL (not a JSON array)\n"); failed++;
            } else {
                NSArray *arr = json;
                if (arr.count == 0) {
                    fprintf(stderr, "  FAIL (empty array, expected subtasks)\n"); failed++;
                } else if (!jsonArrayAllHaveKey(arr, @"title") || !jsonArrayAllHaveKey(arr, @"id")) {
                    fprintf(stderr, "  FAIL (subtask items missing expected fields)\n"); failed++;
                } else if (!jsonArrayFind(arr, @"title", childTitle)) {
                    fprintf(stderr, "  FAIL (child reminder not found in subtasks)\n"); failed++;
                } else { fprintf(stderr, "  PASS\n"); passed++; }
            }
        }
    }

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

    // Test 28: findReminders returns multiple matches (substring search)
    fprintf(stderr, "Test 28: findReminders multiple matches...\n");
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

    // Error path tests (not found, invalid args)
    // Uses posix_spawn to invoke the CLI binary directly, avoiding fork-safety
    // issues with Objective-C runtime. Each test spawns a fresh process with
    // a 10-second timeout via assertCliExitsNonZero().

    // Test 29: findReminderByID returns nil for nonexistent ID
    fprintf(stderr, "Test 29: findReminderByID not found...\n");
    {
        id notFound = findReminderByID(store, @"__nonexistent_id_999__");
        if (!notFound) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (should be nil)\n"); failed++; }
    }

    // Test 30: get exits non-zero for nonexistent title
    fprintf(stderr, "Test 30: get error path (not found)...\n");
    {
        const char *args[] = {"get", "--title", "__nonexistent_reminder_999__", "--list", [testListName UTF8String], NULL};
        if (assertCliExitsNonZero("get not found", args)) { fprintf(stderr, "  PASS\n"); passed++; }
        else { failed++; }
    }

    // Test 31: update exits non-zero for nonexistent ID
    fprintf(stderr, "Test 31: update error path (not found)...\n");
    {
        const char *args[] = {"update", "--id", "__nonexistent_id_999__", NULL};
        if (assertCliExitsNonZero("update not found", args)) { fprintf(stderr, "  PASS\n"); passed++; }
        else { failed++; }
    }

    // Test 32: complete exits non-zero for nonexistent ID
    fprintf(stderr, "Test 32: complete error path (not found)...\n");
    {
        const char *args[] = {"complete", "--id", "__nonexistent_id_999__", NULL};
        if (assertCliExitsNonZero("complete not found", args)) { fprintf(stderr, "  PASS\n"); passed++; }
        else { failed++; }
    }

    // Test 33: delete exits non-zero for nonexistent ID
    fprintf(stderr, "Test 33: delete error path (not found)...\n");
    {
        const char *args[] = {"delete", "--id", "__nonexistent_id_999__", NULL};
        if (assertCliExitsNonZero("delete not found", args)) { fprintf(stderr, "  PASS\n"); passed++; }
        else { failed++; }
    }

    // Test 34: update exits non-zero for conflicting --parent-id and --remove-parent
    fprintf(stderr, "Test 34: update error path (conflicting parent flags)...\n");
    {
        id rem34 = findReminder(store, parentTitle, testListName);
        if (!rem34) { fprintf(stderr, "  FAIL (test reminder not found)\n"); failed++; }
        else {
            NSString *rem34ID = objectIDToString(((id (*)(id, SEL))objc_msgSend)(rem34, sel_registerName("objectID")));
            const char *args[] = {"update", "--id", [rem34ID UTF8String], "--parent-id", "some-id", "--remove-parent", NULL};
            if (assertCliExitsNonZero("update conflicting parent flags", args)) { fprintf(stderr, "  PASS\n"); passed++; }
            else { failed++; }
        }
    }

    // Test 35: update exits non-zero for conflicting --url and --clear-url
    fprintf(stderr, "Test 35: update error path (conflicting url flags)...\n");
    {
        id rem35 = findReminder(store, parentTitle, testListName);
        if (!rem35) { fprintf(stderr, "  FAIL (test reminder not found)\n"); failed++; }
        else {
            NSString *rem35ID = objectIDToString(((id (*)(id, SEL))objc_msgSend)(rem35, sel_registerName("objectID")));
            const char *args[] = {"update", "--id", [rem35ID UTF8String], "--url", "http://example.com", "--clear-url", NULL};
            if (assertCliExitsNonZero("update conflicting url flags", args)) { fprintf(stderr, "  PASS\n"); passed++; }
            else { failed++; }
        }
    }

    // Test 36: add-tag exits non-zero without required --tag
    fprintf(stderr, "Test 36: add-tag error path (missing --tag)...\n");
    {
        const char *args[] = {"add-tag", "--id", "some-id", NULL};
        if (assertCliExitsNonZero("add-tag missing --tag", args)) { fprintf(stderr, "  PASS\n"); passed++; }
        else { failed++; }
    }

    // Test 37: add exits non-zero without required --title
    fprintf(stderr, "Test 37: add error path (missing --title)...\n");
    {
        const char *args[] = {"add", "--list", "SomeList", NULL};
        if (assertCliExitsNonZero("add missing --title", args)) { fprintf(stderr, "  PASS\n"); passed++; }
        else { failed++; }
    }

    // --- Batch Tests ---

    // Test 38: batch add
    fprintf(stderr, "Test 38: batch add...\n");
    {
        NSString *batchJSON = [NSString stringWithFormat:@"["
            @"{\"op\":\"add\",\"title\":\"__batch_test_1__\",\"list\":\"%@\",\"notes\":\"initial notes\"},"
            @"{\"op\":\"add\",\"title\":\"__batch_test_2__\",\"list\":\"%@\"}"
            @"]", testListName, testListName];
        __block int r = -1;
        NSData *out = captureStdoutWithStdin(batchJSON, ^{ r = cmdBatch(store); });
        if (r != 0) { fprintf(stderr, "  FAIL (returned %d)\n", r); failed++; }
        else {
            id json = parseJSONFromData(out);
            if (![json isKindOfClass:[NSArray class]] || [(NSArray *)json count] != 2) {
                fprintf(stderr, "  FAIL (expected 2-element array)\n"); failed++;
            } else {
                id b1 = findReminder(store, @"__batch_test_1__", testListName);
                id b2 = findReminder(store, @"__batch_test_2__", testListName);
                if (b1 && b2) { fprintf(stderr, "  PASS\n"); passed++; }
                else { fprintf(stderr, "  FAIL (reminders not found)\n"); failed++; }
            }
        }
    }

    // Test 39: batch append-notes
    fprintf(stderr, "Test 39: batch append-notes...\n");
    {
        id rem39 = findReminder(store, @"__batch_test_1__", testListName);
        if (!rem39) { fprintf(stderr, "  FAIL (not found)\n"); failed++; }
        else {
            NSString *rem39ID = objectIDToString(((id (*)(id, SEL))objc_msgSend)(rem39, sel_registerName("objectID")));
            NSString *batchJSON = [NSString stringWithFormat:@"[{\"op\":\"update\",\"id\":\"%@\",\"append-notes\":\"appended line\"}]", rem39ID];
            __block int r = -1;
            captureStdoutWithStdin(batchJSON, ^{ r = cmdBatch(store); });
            if (r != 0) { fprintf(stderr, "  FAIL (returned %d)\n", r); failed++; }
            else {
                id updated = findReminder(store, @"__batch_test_1__", testListName);
                NSString *notes = ((id (*)(id, SEL))objc_msgSend)(updated, sel_registerName("notesAsString"));
                if (notes && [notes containsString:@"initial notes"] && [notes containsString:@"appended line"]) {
                    fprintf(stderr, "  PASS\n"); passed++;
                } else { fprintf(stderr, "  FAIL (notes=%s)\n", [notes UTF8String]); failed++; }
            }
        }
    }

    // Test 40: batch add-tag
    fprintf(stderr, "Test 40: batch add-tag...\n");
    {
        id rem40 = findReminder(store, @"__batch_test_1__", testListName);
        if (!rem40) { fprintf(stderr, "  FAIL (not found)\n"); failed++; }
        else {
            NSString *rem40ID = objectIDToString(((id (*)(id, SEL))objc_msgSend)(rem40, sel_registerName("objectID")));
            NSString *batchJSON = [NSString stringWithFormat:@"[{\"op\":\"add-tag\",\"id\":\"%@\",\"tag\":\"batch-test-tag\"}]", rem40ID];
            __block int r = -1;
            captureStdoutWithStdin(batchJSON, ^{ r = cmdBatch(store); });
            if (r != 0) { fprintf(stderr, "  FAIL (returned %d)\n", r); failed++; }
            else {
                id updated = findReminder(store, @"__batch_test_1__", testListName);
                NSSet *tags = ((id (*)(id, SEL))objc_msgSend)(updated, sel_registerName("hashtags"));
                BOOL found = NO;
                for (id tag in tags) {
                    NSString *name = ((id (*)(id, SEL))objc_msgSend)(tag, sel_registerName("name"));
                    if ([name isEqualToString:@"batch-test-tag"]) { found = YES; break; }
                }
                if (found) { fprintf(stderr, "  PASS\n"); passed++; }
                else { fprintf(stderr, "  FAIL (tag not found)\n"); failed++; }
            }
        }
    }

    // Test 41: batch remove-tag
    fprintf(stderr, "Test 41: batch remove-tag...\n");
    {
        id rem41 = findReminder(store, @"__batch_test_1__", testListName);
        if (!rem41) { fprintf(stderr, "  FAIL (not found)\n"); failed++; }
        else {
            NSString *rem41ID = objectIDToString(((id (*)(id, SEL))objc_msgSend)(rem41, sel_registerName("objectID")));
            NSString *batchJSON = [NSString stringWithFormat:@"[{\"op\":\"remove-tag\",\"id\":\"%@\",\"tag\":\"batch-test-tag\"}]", rem41ID];
            __block int r = -1;
            captureStdoutWithStdin(batchJSON, ^{ r = cmdBatch(store); });
            if (r != 0) { fprintf(stderr, "  FAIL (returned %d)\n", r); failed++; }
            else {
                id updated = findReminder(store, @"__batch_test_1__", testListName);
                NSSet *tags = ((id (*)(id, SEL))objc_msgSend)(updated, sel_registerName("hashtags"));
                BOOL found = NO;
                for (id tag in tags) {
                    NSString *name = ((id (*)(id, SEL))objc_msgSend)(tag, sel_registerName("name"));
                    if ([name isEqualToString:@"batch-test-tag"]) { found = YES; break; }
                }
                if (!found) { fprintf(stderr, "  PASS\n"); passed++; }
                else { fprintf(stderr, "  FAIL (tag still exists)\n"); failed++; }
            }
        }
    }

    // Test 42: batch delete
    fprintf(stderr, "Test 42: batch delete...\n");
    {
        id b1 = findReminder(store, @"__batch_test_1__", testListName);
        id b2 = findReminder(store, @"__batch_test_2__", testListName);
        if (!b1 || !b2) { fprintf(stderr, "  FAIL (not found)\n"); failed++; }
        else {
            NSString *b1ID = objectIDToString(((id (*)(id, SEL))objc_msgSend)(b1, sel_registerName("objectID")));
            NSString *b2ID = objectIDToString(((id (*)(id, SEL))objc_msgSend)(b2, sel_registerName("objectID")));
            NSString *batchJSON = [NSString stringWithFormat:@"[{\"op\":\"delete\",\"id\":\"%@\"},{\"op\":\"delete\",\"id\":\"%@\"}]", b1ID, b2ID];
            __block int r = -1;
            captureStdoutWithStdin(batchJSON, ^{ r = cmdBatch(store); });
            if (r != 0) { fprintf(stderr, "  FAIL (returned %d)\n", r); failed++; }
            else { fprintf(stderr, "  PASS\n"); passed++; }
        }
    }

    // Cleanup
    // Test 43: cmdDelete child
    fprintf(stderr, "Test 43: cmdDelete child...\n");
    {
        id rem38 = findReminder(store, childTitle, testListName);
        NSString *rem38ID = objectIDToString(((id (*)(id, SEL))objc_msgSend)(rem38, sel_registerName("objectID")));
        int r = cmdDelete(store, testListName, rem38ID);
        if (r==0) { fprintf(stderr, "  PASS\n"); passed++; } else { fprintf(stderr, "  FAIL\n"); failed++; }
    }

    // Test 44: cmdDelete parent
    fprintf(stderr, "Test 44: cmdDelete parent...\n");
    {
        id rem39 = findReminder(store, parentTitle, testListName);
        NSString *rem39ID = objectIDToString(((id (*)(id, SEL))objc_msgSend)(rem39, sel_registerName("objectID")));
        int r = cmdDelete(store, testListName, rem39ID);
        if (r==0) { fprintf(stderr, "  PASS\n"); passed++; } else { fprintf(stderr, "  FAIL\n"); failed++; }
    }

    // Test 45: cmdDeleteList
    fprintf(stderr, "Test 45: cmdDeleteList...\n");
    { int r = cmdDeleteList(store, testListName); if (r==0) {
        id gone = findList(store, testListName);
        if (!gone) { fprintf(stderr, "  PASS\n"); passed++; } else { fprintf(stderr, "  FAIL (still exists)\n"); failed++; }
    } else { fprintf(stderr, "  FAIL\n"); failed++; } }

    fprintf(stderr, "\nResults: %d passed, %d failed\n", passed, failed);
    return failed > 0 ? 1 : 0;
}


