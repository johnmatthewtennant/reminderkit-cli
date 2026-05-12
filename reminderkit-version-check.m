// Version checks and background Homebrew upgrades.

static NSString * const ReminderkitCurrentVersion = @"0.5.49";
static NSString * const ReminderkitFormulaURL = @"https://raw.githubusercontent.com/johnmatthewtennant/homebrew-tap/master/Formula/reminderkit-cli.rb";
static NSString * const ReminderkitFormulaTap = @"johnmatthewtennant/tap/reminderkit-cli";
static NSString * const ReminderkitFormulaName = @"reminderkit-cli";
static NSString * const ReminderkitCommandName = @"reminderkit";

static NSString *parseFormulaVersion(NSString *formulaBody) {
    __block NSString *version = nil;
    [formulaBody enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([trimmed hasPrefix:@"version \""]) {
            NSString *rest = [trimmed substringFromIndex:[@"version \"" length]];
            NSRange closing = [rest rangeOfString:@"\""];
            if (closing.location != NSNotFound) {
                version = [rest substringToIndex:closing.location];
                *stop = YES;
            }
        }

        NSRange tagRange = [trimmed rangeOfString:@"archive/refs/tags/v"];
        if (tagRange.location != NSNotFound) {
            NSUInteger start = tagRange.location + tagRange.length;
            NSString *rest = [trimmed substringFromIndex:start];
            NSRange end = [rest rangeOfString:@".tar.gz"];
            if (end.location != NSNotFound) {
                version = [rest substringToIndex:end.location];
                *stop = YES;
            }
        }
    }];
    return version;
}

static NSString *latestKnownVersion(NSTimeInterval timeout) {
    NSURL *url = [NSURL URLWithString:ReminderkitFormulaURL];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setTimeoutInterval:timeout];

    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    __block NSData *data = nil;
    __block NSURLResponse *response = nil;
    __block NSError *error = nil;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithRequest:request
        completionHandler:^(NSData *taskData, NSURLResponse *taskResponse, NSError *taskError) {
            data = taskData;
            response = taskResponse;
            error = taskError;
            dispatch_semaphore_signal(sema);
        }];
    [task resume];

    dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, (int64_t)((timeout + 1) * NSEC_PER_SEC));
    if (dispatch_semaphore_wait(sema, deadline) != 0) {
        [task cancel];
        return nil;
    }

    if (error || !data) return nil;
    if ([response isKindOfClass:[NSHTTPURLResponse class]] &&
        [(NSHTTPURLResponse *)response statusCode] != 200) {
        return nil;
    }

    NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!body) return nil;
    return parseFormulaVersion(body);
}

static BOOL isOutdated(NSString *current, NSString *latest) {
    NSArray *currentParts = [current componentsSeparatedByString:@"."];
    NSArray *latestParts = [latest componentsSeparatedByString:@"."];
    NSUInteger maxCount = MAX([currentParts count], [latestParts count]);

    for (NSUInteger i = 0; i < maxCount; i++) {
        NSInteger c = i < [currentParts count] ? [currentParts[i] integerValue] : 0;
        NSInteger l = i < [latestParts count] ? [latestParts[i] integerValue] : 0;
        if (l > c) return YES;
        if (l < c) return NO;
    }
    return NO;
}

static NSString *outdatedWarning(NSString *latest) {
    if (!latest || !isOutdated(ReminderkitCurrentVersion, latest)) return nil;
    return [NSString stringWithFormat:
        @"reminderkit %@ is outdated. Latest: %@. Run: brew upgrade %@",
        ReminderkitCurrentVersion, latest, ReminderkitFormulaTap];
}

static BOOL shouldAttemptUpgrade(NSDate *now, NSDate *lastAttempt) {
    if (!lastAttempt) return YES;
    return [now timeIntervalSinceDate:lastAttempt] >= 24 * 3600;
}

static BOOL isBrewManagedInstall(void) {
    NSString *exePath = [[NSBundle mainBundle] executablePath];
    if (!exePath) return NO;
    NSString *resolved = [exePath stringByResolvingSymlinksInPath];
    NSString *cellarPath = [NSString stringWithFormat:@"/Cellar/%@/", ReminderkitFormulaName];
    return [resolved containsString:cellarPath];
}

static NSString *shellSingleQuote(NSString *value) {
    return [NSString stringWithFormat:@"'%@'",
        [value stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

static void attemptBackgroundUpgrade(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *tmpDir = [[fm temporaryDirectory] URLByAppendingPathComponent:ReminderkitCommandName isDirectory:YES];
    [fm createDirectoryAtURL:tmpDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *logFile = [tmpDir URLByAppendingPathComponent:@"upgrade.log"];

    NSDictionary *attrs = [fm attributesOfItemAtPath:[logFile path] error:nil];
    NSDate *mtime = attrs[NSFileModificationDate];
    if (!shouldAttemptUpgrade([NSDate date], mtime)) return;
    if (!isBrewManagedInstall()) return;

    [fm createFileAtPath:[logFile path] contents:nil attributes:nil];

    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/bin/sh"];
    NSString *script = [NSString stringWithFormat:
        @"HOMEBREW_NO_AUTO_UPDATE=1 brew upgrade %@ >%@ 2>&1 &",
        ReminderkitFormulaTap, shellSingleQuote([logFile path])];
    [task setArguments:@[@"-c", script]];
    [task setStandardInput:[NSFileHandle fileHandleWithNullDevice]];
    [task setStandardOutput:[NSFileHandle fileHandleWithNullDevice]];
    [task setStandardError:[NSFileHandle fileHandleWithNullDevice]];
    @try {
        [task launch];
    } @catch (__unused NSException *exception) {
    }
}

static int cmdVersion(BOOL skipCheck) {
    printf("reminderkit %s\n", [ReminderkitCurrentVersion UTF8String]);
    if (!skipCheck) {
        NSString *latest = latestKnownVersion(2);
        NSString *warning = outdatedWarning(latest);
        if (warning) fprintf(stderr, "%s\n", [warning UTF8String]);
    }
    return 0;
}
