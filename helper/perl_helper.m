#import <AppKit/AppKit.h>
#import <dlfcn.h>

// Loaded into /usr/bin/perl (signing identifier com.apple.perl) by perl_helper.pl.
// mediaremoted's read-access predicate has a com.apple. identity branch; this
// helper tests whether that host process receives the full Now Playing list.
//
// Contracts below were read from the arm64e disassembly of the installed
// MediaRemote on macOS 15.8 (24H23); see docs/PERL_HELPER.md.
typedef void (*GetClientsFn)(dispatch_queue_t, void (^)(NSArray *clients, NSError *error));
typedef void (*GetClientFn)(dispatch_queue_t, void (^)(id client, NSError *error));
typedef id (*GetLocalOriginFn)(void);
typedef id (*PathCreateFn)(id origin, id client, id player);
// The caller's completion receives only the state; daemon errors are logged internally.
typedef void (*GetStateFn)(id path, dispatch_queue_t, void (^)(uint32_t state));
typedef NSString *(*StateDescriptionFn)(uint32_t state);
typedef void (*GetInfoFn)(id path, BOOL artwork, dispatch_queue_t, void (^)(CFDictionaryRef info, void *unused));
typedef NSString *(*CommandDescriptionFn)(uint32_t command);
typedef void (*SendFn)(uint32_t command, NSDictionary *options, id path, uint32_t appOptions,
                       dispatch_queue_t, void (^)(id result));
// Fire-and-forget; nil clears. The daemon handler makes the named client's default
// player eligible and sets it as the local origin's override (now playing) client.
typedef void (*SetOverrideFn)(NSString *bundleIdentifier);

static const int64_t kTimeoutSeconds = 8;

static struct {
    GetClientsFn getClients;
    GetClientFn getCurrentClient;
    GetLocalOriginFn localOrigin;
    PathCreateFn createPath;
    GetStateFn getState;
    StateDescriptionFn stateDescription;
    GetInfoFn getInfo;
    CommandDescriptionFn commandDescription;
    SendFn send;
    SetOverrideFn setOverride;
} MR;

static dispatch_queue_t replyQueue;

/// Write one object as a single JSON line; serve-mode replies are newline-delimited.
static void emit(NSDictionary *object) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:&error];
    if (!data) {
        fprintf(stderr, "Could not encode output: %s\n", error.description.UTF8String);
        exit(1);
    }
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

/// One-shot modes only: report the error and end the process.
__attribute__((noreturn)) static void fail(NSString *message) {
    emit(@{@"error": message});
    exit(1);
}

/// The error object of a failed serve reply, e.g.
///     {"code": "timeout", "message": "MRMediaRemoteGetNowPlayingClients timed out"}
static NSDictionary *replyError(NSString *code, NSString *message) {
    return @{@"code": code, @"message": message};
}

static BOOL loadMediaRemote(void) {
    void *handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (!handle) return NO;
    MR.getClients = (GetClientsFn)dlsym(handle, "MRMediaRemoteGetNowPlayingClients");
    MR.getCurrentClient = (GetClientFn)dlsym(handle, "MRMediaRemoteGetNowPlayingClient");
    MR.localOrigin = (GetLocalOriginFn)dlsym(handle, "MRMediaRemoteGetLocalOrigin");
    MR.createPath = (PathCreateFn)dlsym(handle, "MRNowPlayingPlayerPathCreate");
    MR.getState = (GetStateFn)dlsym(handle, "MRMediaRemoteGetPlaybackStateForPlayer");
    MR.stateDescription = (StateDescriptionFn)dlsym(handle, "MRMediaRemoteCopyPlaybackStateDescription");
    MR.getInfo = (GetInfoFn)dlsym(handle, "MRMediaRemoteGetNowPlayingInfoForPlayer");
    MR.commandDescription = (CommandDescriptionFn)dlsym(handle, "MRMediaRemoteCopyCommandDescription");
    MR.send = (SendFn)dlsym(handle, "MRMediaRemoteSendCommandToPlayerWithResult");
    MR.setOverride = (SetOverrideFn)dlsym(handle, "MRMediaRemoteSetOverriddenNowPlayingApplication");
    return MR.getClients && MR.getCurrentClient && MR.localOrigin && MR.createPath && MR.getState &&
           MR.stateDescription && MR.getInfo && MR.commandDescription && MR.send && MR.setOverride;
}

/// Run one asynchronous MediaRemote request and wait for its reply.
/// Returns NO on timeout. The late reply may still run afterwards, which is safe in the
/// long-running serve mode only while completion blocks write nothing but their own
/// `__block` variables before calling `done`.
static BOOL await(void (^request)(dispatch_block_t done)) {
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    request(^{ dispatch_semaphore_signal(semaphore); });
    return dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, kTimeoutSeconds * NSEC_PER_SEC)) == 0;
}

/// Every Now Playing client, or nil with `*error` set to a reply error.
static NSArray *nowPlayingClients(NSDictionary **error) {
    __block NSArray *clients = nil;
    __block NSError *clientsError = nil;
    BOOL replied = await(^(dispatch_block_t done) {
        MR.getClients(replyQueue, ^(NSArray *result, NSError *error) {
            clients = [result copy];
            clientsError = error;
            done();
        });
    });
    if (!replied) {
        *error = replyError(@"timeout", @"MRMediaRemoteGetNowPlayingClients timed out");
    } else if (clientsError) {
        *error = replyError(@"mediaRemoteError",
                            [NSString stringWithFormat:@"MRMediaRemoteGetNowPlayingClients error: %@", clientsError]);
    } else if (!clients) {
        *error = replyError(@"mediaRemoteError", @"MRMediaRemoteGetNowPlayingClients returned nil with nil error");
    }
    return *error ? nil : clients;
}

static NSString *stringValue(id object, NSString *key) {
    id value = [object respondsToSelector:NSSelectorFromString(key)] ? [object valueForKey:key] : nil;
    return value ? [value description] : nil;
}

/// One record per Now Playing client. Title is diagnostic only, never identity.
/// Electron apps can report a generic client bundle, so the running application
/// for the client PID is recorded alongside it.
///
/// Example (YouTube Music, 13 October 2026):
///     {"bundleIdentifier": "Electron", "displayName": null, "pid": 1332,
///      "applicationBundleIdentifier": "com.github.th-ch.youtube-music",
///      "applicationName": "YouTube Music",
///      "playerPath": "origin-Mac-1280262988/client-Electron-1332/player-(null)",
///      "state": 2, "stateDescription": "Paused", "title": "...", "playbackRate": 0}
static NSDictionary *describeClient(id client, id path) {
    NSMutableDictionary *record = [NSMutableDictionary dictionary];
    pid_t pid = [[client valueForKey:@"processIdentifier"] intValue];
    NSRunningApplication *application = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    record[@"applicationBundleIdentifier"] = application.bundleIdentifier ?: NSNull.null;
    record[@"applicationName"] = application.localizedName ?: NSNull.null;
    record[@"bundleIdentifier"] = stringValue(client, @"bundleIdentifier") ?: NSNull.null;
    record[@"parentApplicationBundleIdentifier"] =
        stringValue(client, @"parentApplicationBundleIdentifier") ?: NSNull.null;
    record[@"displayName"] = stringValue(client, @"displayName") ?: NSNull.null;
    record[@"pid"] = @(pid);
    record[@"client"] = [client description];
    record[@"playerPath"] = [path description];

    __block uint32_t state = 0;
    BOOL stateReplied = await(^(dispatch_block_t done) {
        MR.getState(path, replyQueue, ^(uint32_t result) {
            state = result;
            done();
        });
    });
    record[@"state"] = stateReplied ? @(state) : NSNull.null;
    record[@"stateDescription"] = stateReplied ? (MR.stateDescription(state) ?: NSNull.null) : @"timeout";

    __block NSDictionary *info = nil;
    BOOL infoReplied = await(^(dispatch_block_t done) {
        MR.getInfo(path, NO, replyQueue, ^(CFDictionaryRef result, __unused void *unused) {
            info = result ? [(__bridge NSDictionary *)result copy] : nil;
            done();
        });
    });
    record[@"title"] = infoReplied ? (info[@"kMRMediaRemoteNowPlayingInfoTitle"] ?: NSNull.null) : @"timeout";
    record[@"playbackRate"] = infoReplied ? (info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"] ?: NSNull.null)
                                          : @"timeout";
    return record;
}

/// The system's current Now Playing client: where untargeted commands go.
static NSDictionary *currentClient(void) {
    __block id current = nil;
    __block NSError *currentError = nil;
    BOOL replied = await(^(dispatch_block_t done) {
        MR.getCurrentClient(replyQueue, ^(id client, NSError *error) {
            current = client;
            currentError = error;
            done();
        });
    });
    return @{
        @"currentClientBundleIdentifier": replied ? (stringValue(current, @"bundleIdentifier") ?: NSNull.null)
                                                  : @"timeout",
        @"currentClientPid": replied ? ([current valueForKey:@"processIdentifier"] ?: NSNull.null) : @"timeout",
        @"currentClientError": currentError ? currentError.description : NSNull.null,
    };
}

/// Snapshot of every client plus the system's current Now Playing client, so a
/// command result can be compared against which source was the global target.
static NSDictionary *snapshot(NSArray *clients, NSArray *paths) {
    NSMutableArray *sources = [NSMutableArray array];
    for (NSUInteger index = 0; index < clients.count; index++) {
        NSMutableDictionary *record = [describeClient(clients[index], paths[index]) mutableCopy];
        record[@"index"] = @(index);
        [sources addObject:record];
    }
    NSMutableDictionary *output = [currentClient() mutableCopy];
    output[@"capturedAt"] = [[NSISO8601DateFormatter new] stringFromDate:[NSDate date]];
    output[@"sources"] = sources;
    return output;
}

static NSArray *pathsForClients(NSArray *clients) {
    id origin = MR.localOrigin();
    NSMutableArray *paths = [NSMutableArray array];
    // Same construction Control Center uses: local origin, client, nil player.
    for (id client in clients) [paths addObject:MR.createPath(origin, client, nil)];
    return paths;
}

static void runList(void) {
    NSDictionary *error = nil;
    NSArray *clients = nowPlayingClients(&error);
    if (!clients) fail(error[@"message"]);
    NSMutableDictionary *output = [snapshot(clients, pathsForClients(clients)) mutableCopy];
    output[@"mode"] = @"list";
    output[@"clientCount"] = @(clients.count);
    output[@"operatingSystem"] = NSProcessInfo.processInfo.operatingSystemVersionString;
    output[@"hostExecutable"] = NSProcessInfo.processInfo.arguments.firstObject ?: NSNull.null;
    emit(output);
}

/// Send one explicit Play, Pause, or NextTrack to the client with this PID, recording every
/// source before and after. PID selects within one listing; it is not a stored identity.
///
/// With `override`, the target's client bundle is first set as the Now Playing
/// override, because the daemon redirects this caller's targeted commands to the
/// current Now Playing player. The override is always cleared afterwards.
static void runSend(NSString *action, pid_t pid, BOOL override) {
    // MRMediaRemoteCommand values with MediaRemote's own description for each;
    // the description is checked before anything is sent.
    NSDictionary<NSString *, NSArray *> *commands = @{
        @"play": @[@0, @"Play"], @"pause": @[@1, @"Pause"], @"next": @[@4, @"NextTrack"],
    };
    if (!commands[action]) fail(@"Action must be play, pause, or next");
    uint32_t command = [commands[action][0] unsignedIntValue];
    NSString *commandName = MR.commandDescription(command);
    if (![commandName isEqualToString:commands[action][1]]) {
        fail([NSString stringWithFormat:@"Command %u describes itself as %@, not %@. Nothing sent.",
                                        command, commandName, commands[action][1]]);
    }

    NSDictionary *error = nil;
    NSArray *clients = nowPlayingClients(&error);
    if (!clients) fail(error[@"message"]);
    NSArray *paths = pathsForClients(clients);
    NSIndexSet *matches = [clients indexesOfObjectsPassingTest:^BOOL(id client, __unused NSUInteger index, __unused BOOL *stop) {
        return [[client valueForKey:@"processIdentifier"] intValue] == pid;
    }];
    if (matches.count != 1) {
        fail([NSString stringWithFormat:@"Expected exactly one client with PID %d; found %lu. Nothing sent.",
                                        pid, (unsigned long)matches.count]);
    }
    NSUInteger target = matches.firstIndex;
    NSDictionary *before = snapshot(clients, paths);

    // The daemon looks the override up by *client* bundle; for Electron apps that is
    // the generic "Electron" (the real application bundle was not found, 13 October).
    NSString *overrideBundle = stringValue(clients[target], @"bundleIdentifier");
    // The client bundle matches the code-signing identifier; ad-hoc Electron builds
    // keep the default "Electron", so two such sources make the override ambiguous.
    NSUInteger sharing = [clients indexesOfObjectsPassingTest:^BOOL(id client, __unused NSUInteger index, __unused BOOL *stop) {
        return [stringValue(client, @"bundleIdentifier") isEqualToString:overrideBundle];
    }].count;
    if (override && sharing != 1) {
        fail([NSString stringWithFormat:@"%lu Now Playing sources share client bundle %@; the override is ambiguous. Nothing sent.",
                                        (unsigned long)sharing, overrideBundle]);
    }
    NSDictionary *currentDuringOverride = (id)NSNull.null;
    NSDictionary *currentAfterClear = (id)NSNull.null;
    if (override) {
        MR.setOverride(overrideBundle);
        [NSThread sleepForTimeInterval:0.3];
        currentDuringOverride = currentClient();
        // An override that did not take effect (unknown bundle, or a shared bundle
        // resolving to another process) would send the command to the wrong source.
        if (![currentDuringOverride[@"currentClientPid"] isEqual:@(pid)]) {
            MR.setOverride(nil);
            fail([NSString stringWithFormat:@"Override %@ made PID %@ current, not %d. Override cleared; nothing sent.",
                                            overrideBundle, currentDuringOverride[@"currentClientPid"], pid]);
        }
    }
    __block NSString *result = nil;
    BOOL replied = await(^(dispatch_block_t done) {
        MR.send(command, @{}, paths[target], 0, replyQueue, ^(id commandResult) {
            result = [commandResult description];
            done();
        });
    });
    if (override) {
        MR.setOverride(nil);
        [NSThread sleepForTimeInterval:0.3];
        currentAfterClear = currentClient();
    }
    // Commands apply asynchronously; allow the player and daemon to settle.
    [NSThread sleepForTimeInterval:1.5];
    NSArray *afterClients = nowPlayingClients(&error);
    if (!afterClients) fail(error[@"message"]);
    emit(@{
        @"mode": override ? @"override-send" : @"send",
        @"overrideBundleIdentifier": override ? overrideBundle : NSNull.null,
        @"currentDuringOverride": currentDuringOverride,
        @"currentAfterOverrideCleared": currentAfterClear,
        @"action": action,
        @"commandDescription": commandName,
        @"targetPid": @(pid),
        @"targetIndex": @(target),
        @"targetPlayerPath": [paths[target] description],
        @"commandResult": replied ? (result ?: NSNull.null) : @"timeout",
        @"before": before,
        @"after": snapshot(afterClients, pathsForClients(afterClients)),
    });
}

/// Serve reply body for {"op": "list"}: the protocol's compact view of a snapshot.
/// `current` is null when no client is current. Identity is pid + clientBundle; the
/// other fields are for display.
///
/// Example:
///     {"current": {"pid": 1334, "clientBundle": "com.spotify.client"},
///      "sources": [{"pid": 1332, "clientBundle": "Electron",
///                   "appBundle": "com.github.th-ch.youtube-music", "appName": "YouTube Music",
///                   "state": "Paused", "title": "..."}]}
static NSDictionary *listReply(NSDictionary **error) {
    NSArray *clients = nowPlayingClients(error);
    if (!clients) return nil;
    NSDictionary *full = snapshot(clients, pathsForClients(clients));
    if ([full[@"currentClientPid"] isEqual:@"timeout"]) {
        *error = replyError(@"timeout", @"MRMediaRemoteGetNowPlayingClient timed out");
        return nil;
    }
    NSMutableArray *sources = [NSMutableArray array];
    for (NSDictionary *source in full[@"sources"]) {
        [sources addObject:@{
            @"pid": source[@"pid"],
            @"clientBundle": source[@"bundleIdentifier"],
            @"appBundle": source[@"applicationBundleIdentifier"],
            @"appName": source[@"applicationName"],
            @"state": source[@"stateDescription"],
            @"title": source[@"title"],
        }];
    }
    id current = full[@"currentClientPid"] == NSNull.null
        ? NSNull.null
        : @{@"pid": full[@"currentClientPid"], @"clientBundle": full[@"currentClientBundleIdentifier"]};
    return @{@"current": current, @"sources": sources};
}

/// Answer one request line. Every reply echoes the request's "id" (null if unreadable):
///     {"id": 1, "ok": true, ...reply body}
///     {"id": 1, "ok": false, "error": {"code": "badRequest", "message": "..."}}
static NSDictionary *handleRequest(NSData *line) {
    id request = [NSJSONSerialization JSONObjectWithData:line options:0 error:NULL];
    if (![request isKindOfClass:NSDictionary.class]) {
        return @{@"id": NSNull.null, @"ok": @NO, @"error": replyError(@"badRequest", @"Request must be a JSON object")};
    }
    id requestID = request[@"id"] ?: NSNull.null;
    NSDictionary *error = nil;
    NSDictionary *body = nil;
    if ([request[@"op"] isEqual:@"list"]) {
        body = listReply(&error);
    } else {
        error = replyError(@"badRequest", [NSString stringWithFormat:@"Unknown op %@", request[@"op"]]);
    }
    if (!body) return @{@"id": requestID, @"ok": @NO, @"error": error};
    NSMutableDictionary *reply = [body mutableCopy];
    reply[@"id"] = requestID;
    reply[@"ok"] = @YES;
    return reply;
}

/// Long-running mode: one JSON request per stdin line, one JSON reply per stdout line,
/// handled one at a time on this thread. Returns when stdin closes.
static void runServe(void) {
    emit(@{@"event": @"ready", @"protocol": @1,
           @"operatingSystem": NSProcessInfo.processInfo.operatingSystemVersionString});
    char *line = NULL;
    size_t capacity = 0;
    ssize_t length;
    while ((length = getline(&line, &capacity, stdin)) > 0) {
        @autoreleasepool {
            NSData *data = [NSData dataWithBytesNoCopy:line length:(NSUInteger)length freeWhenDone:NO];
            emit(handleRequest(data));
        }
    }
    free(line);
}

/// Installed as a Perl XSUB; the interpreter and CV arguments are unused.
/// Perl passes the request in environment variables and this function exits the process.
void npt_main(__unused void *interpreter, __unused void *cv) {
    @autoreleasepool {
        replyQueue = dispatch_queue_create("NowPlayingAPITest.perl-helper", DISPATCH_QUEUE_SERIAL);
        NSDictionary<NSString *, NSString *> *environment = NSProcessInfo.processInfo.environment;
        NSString *mode = environment[@"NPT_MODE"];
        if (!loadMediaRemote()) {
            NSString *message = @"Could not load MediaRemote or resolve a required symbol";
            if (![mode isEqualToString:@"serve"]) fail(message);
            emit(@{@"event": @"fatal", @"error": replyError(@"mediaRemoteUnavailable", message)});
            exit(1);
        }
        if ([mode isEqualToString:@"serve"]) {
            runServe();
        } else if ([mode isEqualToString:@"list"]) {
            runList();
        } else if (([mode isEqualToString:@"send"] || [mode isEqualToString:@"override-send"]) &&
                   environment[@"NPT_ACTION"] && environment[@"NPT_PID"].intValue > 0) {
            runSend(environment[@"NPT_ACTION"], environment[@"NPT_PID"].intValue,
                    [mode isEqualToString:@"override-send"]);
        } else {
            fail(@"Unknown mode");
        }
    }
    exit(0);
}
