// reminderkit.m — assembled from generated + handwritten + test files
//
// Include order matters: each file depends on symbols from earlier includes.
//   1. generated  — provides helpers, framework loading, config-driven commands
//   2. handwritten — provides cmdBatch, cmdInstallSkill (uses helpers from generated)
//   3. tests       — provides cmdTest + test helpers (uses commands from both)
//
// usage() and main() follow the includes so they can reference all symbols.
#include "reminderkit-generated.m"
#include "reminderkit-handwritten.m"
#include "reminderkit-tests.m"

// --- Usage ---

static void usage(void) {
    fprintf(stderr, "Usage:\n");
    fprintf(stderr, "  reminderkit lists\n");
    fprintf(stderr, "  reminderkit list --name <name> [--include-completed] [--has-url] [--tag <tags>] [--exclude-tag <tags>] [--notes-contains <text>]\n");
    fprintf(stderr, "  reminderkit list --all [--include-completed] [--has-url] [--tag <tags>] [--exclude-tag <tags>] [--notes-contains <text>]\n");
    fprintf(stderr, "  reminderkit search [--title <title>] [--url <url>] [--list <name>] [--tag <tags>] [--exclude-tag <tags>] [--has-url] [--notes-contains <text>]\n");
    fprintf(stderr, "  reminderkit search --id <id>\n");
    fprintf(stderr, "  reminderkit get [--title <title>] [--url <url>] [--list <name>] [--tag <tags>] [--exclude-tag <tags>] [--has-url] [--notes-contains <text>]  (alias for search)\n");
    fprintf(stderr, "  reminderkit get --id <id>\n");
    fprintf(stderr, "  reminderkit subtasks --title <title> [--list <name>]\n");
    fprintf(stderr, "  reminderkit add --title <title> [--list <name>] [--notes <value|->] [--completed <value>] [--priority <value>] [--flagged <value>] [--due-date <value>] [--start-date <value>] [--url <value>] [--parent-id <id>]\n");
    fprintf(stderr, "  reminderkit update --id <id> [--title <value>] [--list <name>] [--notes <value|->] [--append-notes <value|->] [--completed <value>] [--priority <value>] [--flagged <value>] [--due-date <value>] [--start-date <value>] [--url <value>] [--clear-url] [--remove-parent] [--remove-from-list] [--parent-id <id>] [--to-list <name>]\n");
    fprintf(stderr, "    (use --notes - or --append-notes - to read from stdin, avoiding shell quoting issues)\n");
    fprintf(stderr, "  reminderkit complete --id <id>\n");
    fprintf(stderr, "  reminderkit delete --id <id>\n");
    fprintf(stderr, "  reminderkit add-tag --id <id> --tag <tag-name>\n");
    fprintf(stderr, "  reminderkit remove-tag --id <id> --tag <tag-name>\n");
    fprintf(stderr, "  reminderkit assign --id <id> --assignee-id <sharee-id>\n");
    fprintf(stderr, "  reminderkit unassign --id <id> [--assignee-id <sharee-id>]  (omit --assignee-id to remove all)\n");
    fprintf(stderr, "  reminderkit list-sharees --name <list-name>\n");
    fprintf(stderr, "  reminderkit link-note --id <id> --note-id <note-id>\n");
    fprintf(stderr, "  reminderkit list-sections --name <list-name>\n");
    fprintf(stderr, "  reminderkit create-section --name <list-name> --section <section-name>\n");
    fprintf(stderr, "  reminderkit create-list --name <name>\n");
    fprintf(stderr, "  reminderkit rename-list --old-name <old-name> --new-name <new-name>\n");
    fprintf(stderr, "  reminderkit delete-list --name <name>\n");
    fprintf(stderr, "  reminderkit batch  (reads JSON array from stdin)\n");
    fprintf(stderr, "    ops: add, update, complete, delete, add-tag, remove-tag\n");
    fprintf(stderr, "\n  Skill management:\n");
    fprintf(stderr, "  reminderkit install-skill [--claude] [--agents] [--force]\n");
    fprintf(stderr, "\n  Testing:\n");
    fprintf(stderr, "  reminderkit test\n");
    fprintf(stderr, "\n  Report issues:\n");
    fprintf(stderr, "  gh api repos/johnmatthewtennant/reminderkit-cli/issues --method POST -f title=\"...\" -f body=\"...\"\n");
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
                    [flag isEqualToString:@"force"]) {
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

        // Support --notes - and --append-notes - to read from stdin
        // This avoids shell quoting issues with special chars like <, >, ://
        for (NSString *stdinFlag in @[@"notes", @"append-notes"]) {
            if ([opts[stdinFlag] isEqualToString:@"-"]) {
                NSFileHandle *input = [NSFileHandle fileHandleWithStandardInput];
                NSData *inputData = [input readDataToEndOfFile];
                if (inputData.length == 0) {
                    fprintf(stderr, "Error: --%s - specified but no data on stdin\n", [stdinFlag UTF8String]);
                    return 1;
                }
                if (inputData.length > 1024 * 1024) {
                    fprintf(stderr, "Error: stdin input exceeds 1MB limit\n");
                    return 1;
                }
                NSString *stdinStr = [[NSString alloc] initWithData:inputData encoding:NSUTF8StringEncoding];
                if (!stdinStr) {
                    fprintf(stderr, "Error: stdin is not valid UTF-8\n");
                    return 1;
                }
                // Trim trailing newline (heredocs/echo add one)
                if ([stdinStr hasSuffix:@"\n"]) {
                    stdinStr = [stdinStr substringToIndex:stdinStr.length - 1];
                }
                opts[stdinFlag] = stdinStr;
            }
        }

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
            BOOL allLists = [opts[@"all"] isEqualToString:@"true"];
            if (allLists) {
                return cmdListAll(store, includeCompleted, opts[@"tag"], opts[@"exclude-tag"], hasURL, opts[@"notes-contains"]);
            }
            if (!kwName) { fprintf(stderr, "Error: --name or --all required\n"); usage(); return 1; }
            return cmdList(store, kwName, includeCompleted, opts[@"tag"], opts[@"exclude-tag"], hasURL, opts[@"notes-contains"]);

        } else if ([command isEqualToString:@"search"] || [command isEqualToString:@"get"]) {
            if (opts[@"id"] && [opts[@"id"] length] > 0) {
                return cmdGetByID(store, opts[@"id"]);
            }
            if (!kwTitle && !opts[@"url"] && !kwTag && !opts[@"exclude-tag"] && !hasURL && !listName && !opts[@"notes-contains"]) { fprintf(stderr, "Error: --title, --url, --id, --tag, --exclude-tag, --has-url, --notes-contains, or --list required\n"); usage(); return 1; }
            return cmdGet(store, kwTitle, listName, opts[@"url"], kwTag, opts[@"exclude-tag"], hasURL, opts[@"notes-contains"]);

        } else if ([command isEqualToString:@"subtasks"]) {
            if (!kwTitle) { fprintf(stderr, "Error: --title required\n"); usage(); return 1; }
            return cmdSubtasks(store, kwTitle, listName);

        } else if ([command isEqualToString:@"add"]) {
            if (!kwTitle) { fprintf(stderr, "Error: --title required\n"); usage(); return 1; }
            return cmdAdd(store, kwTitle, listName, opts);

        } else if ([command isEqualToString:@"update"]) {
            if (!opts[@"id"] || [opts[@"id"] length] == 0) { fprintf(stderr, "Error: --id required\n"); usage(); return 1; }
            return cmdUpdate(store, listName, opts);

        } else if ([command isEqualToString:@"complete"]) {
            if (!opts[@"id"] || [opts[@"id"] length] == 0) { fprintf(stderr, "Error: --id required\n"); usage(); return 1; }
            return cmdComplete(store, opts[@"id"]);

        } else if ([command isEqualToString:@"delete"]) {
            if (!opts[@"id"] || [opts[@"id"] length] == 0) { fprintf(stderr, "Error: --id required\n"); usage(); return 1; }
            return cmdDelete(store, opts[@"id"]);

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

        } else if ([command isEqualToString:@"assign"]) {
            if (!opts[@"id"] || [opts[@"id"] length] == 0) { fprintf(stderr, "Error: --id required\n"); usage(); return 1; }
            if (!opts[@"assignee-id"] || [opts[@"assignee-id"] length] == 0) { fprintf(stderr, "Error: --assignee-id required\n"); usage(); return 1; }
            return cmdAssign(store, opts[@"id"], opts[@"assignee-id"]);

        } else if ([command isEqualToString:@"unassign"]) {
            if (!opts[@"id"] || [opts[@"id"] length] == 0) { fprintf(stderr, "Error: --id required\n"); usage(); return 1; }
            return cmdUnassign(store, opts[@"id"], opts[@"assignee-id"]);

        } else if ([command isEqualToString:@"list-sharees"]) {
            if (!kwName) { fprintf(stderr, "Error: --name required\n"); usage(); return 1; }
            return cmdListSharees(store, kwName);

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
