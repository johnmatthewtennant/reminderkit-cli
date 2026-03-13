#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

static void dumpProperties(Class cls) {
    unsigned int count = 0;
    objc_property_t *props = class_copyPropertyList(cls, &count);
    fprintf(stderr, "\n=== %s (%u properties) ===\n", class_getName(cls), count);
    for (unsigned int i = 0; i < count; i++) {
        const char *name = property_getName(props[i]);
        const char *attrs = property_getAttributes(props[i]);
        fprintf(stderr, "  %s  (%s)\n", name, attrs);
    }
    free(props);
}

static void dumpMethods(Class cls) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    fprintf(stderr, "\n=== %s (%u methods) ===\n", class_getName(cls), count);
    for (unsigned int i = 0; i < count; i++) {
        SEL sel = method_getName(methods[i]);
        fprintf(stderr, "  %s\n", sel_getName(sel));
    }
    free(methods);
}

int main() {
    @autoreleasepool {
        [[NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/ReminderKit.framework"] load];

        NSArray *classNames = @[
            @"REMReminder", @"REMList", @"REMStore",
            @"REMSaveRequest", @"REMReminderChangeItem",
            @"REMHashtag", @"REMHashtagLabel",
            @"REMListSection", @"REMReminderSubtaskContextChangeItem"
        ];

        for (NSString *name in classNames) {
            Class cls = NSClassFromString(name);
            if (cls) {
                dumpProperties(cls);
            } else {
                fprintf(stderr, "\n=== %s NOT FOUND ===\n", [name UTF8String]);
            }
        }

        // Also dump methods for key classes
        fprintf(stderr, "\n\n--- REMReminderChangeItem METHODS (looking for setters) ---\n");
        Class changeItemClass = NSClassFromString(@"REMReminderChangeItem");
        if (changeItemClass) {
            dumpMethods(changeItemClass);
        }

        fprintf(stderr, "\n\n--- REMSaveRequest METHODS ---\n");
        Class saveReqClass = NSClassFromString(@"REMSaveRequest");
        if (saveReqClass) {
            dumpMethods(saveReqClass);
        }

        fprintf(stderr, "\n\n--- REMListChangeItem METHODS ---\n");
        Class listCIClass = NSClassFromString(@"REMListChangeItem");
        if (listCIClass) {
            dumpMethods(listCIClass);
        }

        // Quick test: init store and fetch one reminder to inspect actual values
        fprintf(stderr, "\n\n--- LIVE REMINDER INSPECTION ---\n");
        Class REMStore = NSClassFromString(@"REMStore");
        id store = ((id (*)(id, SEL, BOOL))objc_msgSend)(
            [REMStore alloc], sel_registerName("initUserInteractive:"), YES);

        NSError *error = nil;
        NSArray *lists = ((id (*)(id, SEL, id*))objc_msgSend)(
            store, sel_registerName("fetchEligibleDefaultListsWithError:"), &error);

        if (lists.count > 0) {
            id list = lists[0];
            id storage = ((id (*)(id, SEL))objc_msgSend)(list, sel_registerName("storage"));
            NSString *listName = ((id (*)(id, SEL))objc_msgSend)(storage, sel_registerName("name"));
            fprintf(stderr, "First list: %s\n", [listName UTF8String]);

            id listObjID = ((id (*)(id, SEL))objc_msgSend)(list, sel_registerName("objectID"));
            NSArray *reminders = ((id (*)(id, SEL, id, id*))objc_msgSend)(
                store, sel_registerName("fetchRemindersForEventKitBridgingWithListIDs:error:"),
                @[listObjID], &error);

            if (reminders.count > 0) {
                id rem = reminders[0];
                fprintf(stderr, "First reminder class: %s\n", class_getName([rem class]));

                // Try common property names
                NSArray *tryProps = @[@"titleAsString", @"notes", @"body", @"priority",
                    @"completed", @"isCompleted", @"dueDate", @"dueDateComponents",
                    @"parentReminderID", @"hashtags", @"objectID",
                    @"creationDate", @"modificationDate", @"flagged"];

                for (NSString *prop in tryProps) {
                    @try {
                        id val = ((id (*)(id, SEL))objc_msgSend)(rem, sel_registerName([prop UTF8String]));
                        fprintf(stderr, "  %s = %s\n", [prop UTF8String],
                            val ? [[val description] UTF8String] : "(nil)");
                    } @catch (NSException *e) {
                        fprintf(stderr, "  %s = [EXCEPTION: %s]\n", [prop UTF8String],
                            [[e reason] UTF8String]);
                    }
                }
            }
        }
    }
    return 0;
}
