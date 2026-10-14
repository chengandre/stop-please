#import <AppKit/AppKit.h>
#import <dlfcn.h>

// Loaded into /usr/bin/perl (signing identifier com.apple.perl) by perl_helper.pl.
// mediaremoted's read-access predicate has a com.apple. identity branch, so this host
// process receives the full Now Playing list. Its targeted commands are still redirected
// to the current Now Playing player, which is why commands use the override.
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
// MRMediaRemoteCommand values; checked against MediaRemote's own descriptions at startup.
static const uint32_t kPlayCommand = 0;
static const uint32_t kPauseCommand = 1;

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

/// Write one object as a single JSON line; replies are newline-delimited.
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

/// The error object of a failed reply or fatal event, e.g.
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
/// Returns NO on timeout. The late reply may still run afterwards, which is safe in this
/// long-running process only while completion blocks write nothing but their own
/// `__block` variables before calling `done`, and callers read those only on success.
static BOOL await(void (^request)(dispatch_block_t done)) {
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    request(^{ dispatch_semaphore_signal(semaphore); });
    return dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, kTimeoutSeconds * NSEC_PER_SEC)) == 0;
}

/// Re-evaluate `condition` every 10 ms until it holds or `timeout` passes.
static BOOL waitUntil(NSTimeInterval timeout, BOOL (^condition)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    do {
        if (condition()) return YES;
        [NSThread sleepForTimeInterval:0.01];
    } while ([deadline timeIntervalSinceNow] > 0);
    return condition();
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

static pid_t clientPid(id client) {
    return [[client valueForKey:@"processIdentifier"] intValue];
}

static NSArray *pathsForClients(NSArray *clients) {
    id origin = MR.localOrigin();
    NSMutableArray *paths = [NSMutableArray array];
    // Same construction Control Center uses: local origin, client, nil player.
    for (id client in clients) [paths addObject:MR.createPath(origin, client, nil)];
    return paths;
}

/// MediaRemote's name for the player's state ("Playing", "Paused", ...), or nil on timeout.
static NSString *playbackState(id path) {
    __block uint32_t state = 0;
    BOOL replied = await(^(dispatch_block_t done) {
        MR.getState(path, replyQueue, ^(uint32_t result) {
            state = result;
            done();
        });
    });
    if (!replied) return nil;
    return MR.stateDescription(state) ?: [NSString stringWithFormat:@"%u", state];
}

/// The system's current Now Playing client (nil when none), where untargeted commands go.
/// Returns NO on timeout.
static BOOL currentClient(id *client) {
    __block id current = nil;
    BOOL replied = await(^(dispatch_block_t done) {
        MR.getCurrentClient(replyQueue, ^(id result, __unused NSError *error) {
            current = result;
            done();
        });
    });
    *client = replied ? current : nil;
    return replied;
}

/// One `list` source, or nil on timeout. Title is for display only, never identity.
/// Electron apps can report a generic client bundle, so the running application for
/// the client PID is reported alongside it.
///
/// Example (YouTube Music):
///     {"pid": 1332, "clientBundle": "Electron",
///      "appBundle": "com.github.th-ch.youtube-music", "appName": "YouTube Music",
///      "state": "Paused", "title": "..."}
static NSDictionary *describeSource(id client, id path) {
    NSString *state = playbackState(path);
    if (!state) return nil;
    __block NSString *title = nil;
    BOOL replied = await(^(dispatch_block_t done) {
        MR.getInfo(path, NO, replyQueue, ^(CFDictionaryRef info, __unused void *unused) {
            title = [((__bridge NSDictionary *)info)[@"kMRMediaRemoteNowPlayingInfoTitle"] copy];
            done();
        });
    });
    if (!replied) return nil;
    pid_t pid = clientPid(client);
    NSRunningApplication *application = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    return @{
        @"pid": @(pid),
        @"clientBundle": stringValue(client, @"bundleIdentifier") ?: NSNull.null,
        @"appBundle": application.bundleIdentifier ?: NSNull.null,
        @"appName": application.localizedName ?: NSNull.null,
        @"state": state,
        @"title": title ?: NSNull.null,
    };
}

/// Reply body for {"op": "list"}. `current` is null when no client is current.
/// Identity is pid + clientBundle; the other source fields are for display.
///
/// Example:
///     {"current": {"pid": 1334, "clientBundle": "com.spotify.client"},
///      "sources": [<describeSource record>, ...]}
static NSDictionary *listReply(NSDictionary **error) {
    NSArray *clients = nowPlayingClients(error);
    if (!clients) return nil;
    NSArray *paths = pathsForClients(clients);
    NSMutableArray *sources = [NSMutableArray array];
    for (NSUInteger index = 0; index < clients.count; index++) {
        NSDictionary *source = describeSource(clients[index], paths[index]);
        if (!source) {
            *error = replyError(@"timeout", @"Playback state or info request timed out");
            return nil;
        }
        [sources addObject:source];
    }
    id current = nil;
    if (!currentClient(&current)) {
        *error = replyError(@"timeout", @"MRMediaRemoteGetNowPlayingClient timed out");
        return nil;
    }
    return @{
        @"current": current ? @{@"pid": @(clientPid(current)),
                                @"clientBundle": stringValue(current, @"bundleIdentifier") ?: NSNull.null}
                            : NSNull.null,
        @"sources": sources,
    };
}

/// Reply body for {"op": "command"}: explicit Play or Pause to each target, in order.
/// Results follow the target order:
///     {"results": [{"pid": 1334, "outcome": "done", "route": "override", "state": "Paused"},
///                  {"pid": 1332, "outcome": "notFound"}]}
///
/// Every target is resolved and prechecked in one listing before anything is sent, so a
/// route-level error (nil with `*error`) means nothing was sent. After that, a MediaRemote
/// timeout only makes its own target fail a check.
static NSDictionary *commandReply(NSString *action, NSArray<NSDictionary *> *targets, NSDictionary **error) {
    BOOL pause = [action isEqualToString:@"pause"];
    uint32_t command = pause ? kPauseCommand : kPlayCommand;
    NSString *requiredState = pause ? @"Playing" : @"Paused";
    NSString *expectedState = pause ? @"Paused" : @"Playing";

    // Resolve: exactly one listed client with this pid AND client bundle.
    // Precheck: the source is in the state the action applies to.
    NSArray *clients = nowPlayingClients(error);
    if (!clients) return nil;
    NSArray *paths = pathsForClients(clients);
    NSMutableArray<NSMutableDictionary *> *results = [NSMutableArray array];
    // Per result: the resolved client's index, or NSNotFound when nothing will be sent.
    NSMutableArray<NSNumber *> *clientIndexes = [NSMutableArray array];
    for (NSDictionary *target in targets) {
        NSMutableDictionary *result = [@{@"pid": target[@"pid"]} mutableCopy];
        NSIndexSet *matches = [clients indexesOfObjectsPassingTest:^BOOL(id client, __unused NSUInteger index, __unused BOOL *stop) {
            return clientPid(client) == [target[@"pid"] intValue] &&
                   [stringValue(client, @"bundleIdentifier") isEqualToString:target[@"clientBundle"]];
        }];
        NSUInteger clientIndex = NSNotFound;
        if (matches.count != 1) {
            result[@"outcome"] = @"notFound";
        } else {
            NSString *state = playbackState(paths[matches.firstIndex]);
            if (!state) {
                *error = replyError(@"timeout", @"MRMediaRemoteGetPlaybackStateForPlayer timed out");
                return nil;
            }
            if ([state isEqualToString:requiredState]) {
                clientIndex = matches.firstIndex;
            } else {
                result[@"outcome"] = @"skipped";
                result[@"state"] = state;
            }
        }
        [results addObject:result];
        [clientIndexes addObject:@(clientIndex)];
    }

    // Route and send, one target at a time. The current client is read fresh per target
    // because an earlier command in the group can change it.
    NSMutableDictionary<NSNumber *, id> *awaitingState = [NSMutableDictionary dictionary];  // result index → path
    for (NSUInteger index = 0; index < results.count; index++) {
        NSUInteger clientIndex = clientIndexes[index].unsignedIntegerValue;
        if (clientIndex == NSNotFound) continue;
        NSMutableDictionary *result = results[index];
        id client = clients[clientIndex];
        pid_t pid = clientPid(client);
        NSString *bundle = stringValue(client, @"bundleIdentifier");
        // The daemon redirects this host's targeted commands to the current Now Playing
        // player, so a target that is already current is reached without the override.
        id current = nil;
        BOOL direct = currentClient(&current) && clientPid(current) == pid;
        if (!direct) {
            // The override is looked up by client bundle; a shared bundle (e.g. two ad-hoc
            // "Electron" apps) could make the wrong process current.
            NSUInteger sharing = [clients indexesOfObjectsPassingTest:^BOOL(id other, __unused NSUInteger i, __unused BOOL *stop) {
                return [stringValue(other, @"bundleIdentifier") isEqualToString:bundle];
            }].count;
            if (sharing != 1) {
                result[@"outcome"] = @"ambiguousBundle";
                continue;
            }
        }
        result[@"route"] = direct ? @"direct" : @"override";
        if (!direct) {
            MR.setOverride(bundle);
            BOOL honored = waitUntil(1.0, ^BOOL {
                id overridden = nil;
                return currentClient(&overridden) && clientPid(overridden) == pid;
            });
            if (!honored) {
                MR.setOverride(nil);
                result[@"outcome"] = @"overrideNotHonored";
                continue;
            }
        }
        // A send that times out may still apply; the state check below decides.
        await(^(dispatch_block_t done) {
            MR.send(command, @{}, paths[clientIndex], 0, replyQueue, ^(__unused id commandResult) { done(); });
        });
        if (!direct) MR.setOverride(nil);
        awaitingState[@(index)] = paths[clientIndex];
    }

    // One polled state check for every target that was sent to.
    waitUntil(3.0, ^BOOL {
        for (NSNumber *index in awaitingState.allKeys) {
            NSString *state = playbackState(awaitingState[index]);
            if (state) results[index.unsignedIntegerValue][@"state"] = state;
            if ([state isEqualToString:expectedState]) {
                results[index.unsignedIntegerValue][@"outcome"] = @"done";
                [awaitingState removeObjectForKey:index];
            }
        }
        return awaitingState.count == 0;
    });
    for (NSNumber *index in awaitingState) results[index.unsignedIntegerValue][@"outcome"] = @"noStateChange";
    return @{@"results": results};
}

/// Whether `targets` is [{"pid": <number>, "clientBundle": <string>}, ...].
static BOOL validTargets(id targets) {
    if (![targets isKindOfClass:NSArray.class]) return NO;
    for (id target in targets) {
        if (![target isKindOfClass:NSDictionary.class] || ![target[@"pid"] isKindOfClass:NSNumber.class] ||
            ![target[@"clientBundle"] isKindOfClass:NSString.class]) {
            return NO;
        }
    }
    return YES;
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
    } else if ([request[@"op"] isEqual:@"command"]) {
        if (([request[@"action"] isEqual:@"play"] || [request[@"action"] isEqual:@"pause"]) &&
            validTargets(request[@"targets"])) {
            body = commandReply(request[@"action"], request[@"targets"], &error);
        } else {
            error = replyError(@"badRequest", @"command needs action play or pause and targets [{pid, clientBundle}]");
        }
    } else {
        error = replyError(@"badRequest", [NSString stringWithFormat:@"Unknown op %@", request[@"op"]]);
    }
    if (!body) return @{@"id": requestID, @"ok": @NO, @"error": error};
    NSMutableDictionary *reply = [body mutableCopy];
    reply[@"id"] = requestID;
    reply[@"ok"] = @YES;
    return reply;
}

/// One JSON request per stdin line, one JSON reply per stdout line, handled one at a
/// time on this thread. Returns when stdin closes.
static void runServe(void) {
    // A crash inside an earlier helper's override window leaves the override set, and a
    // nil from this new process does not clear it (docs/PERL_HELPER.md). Setting and
    // clearing it from one process does; the leftover target is the current client.
    id current = nil;
    if (currentClient(&current) && current) {
        MR.setOverride(stringValue(current, @"bundleIdentifier"));
        MR.setOverride(nil);
    }
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
/// Serves requests until stdin closes, then exits the process. A startup failure is
/// reported as a `fatal` event instead of `ready`.
void npt_main(__unused void *interpreter, __unused void *cv) {
    @autoreleasepool {
        replyQueue = dispatch_queue_create("NowPlayingAPITest.perl-helper", DISPATCH_QUEUE_SERIAL);
        NSDictionary *fatal = nil;
        if (!loadMediaRemote()) {
            fatal = replyError(@"mediaRemoteUnavailable", @"Could not load MediaRemote or resolve a required symbol");
        } else if (![MR.commandDescription(kPlayCommand) isEqualToString:@"Play"] ||
                   ![MR.commandDescription(kPauseCommand) isEqualToString:@"Pause"]) {
            fatal = replyError(@"unexpectedCommandValues", @"MediaRemote commands 0 and 1 are not Play and Pause");
        }
        if (fatal) {
            emit(@{@"event": @"fatal", @"error": fatal});
            exit(1);
        }
        runServe();
    }
    exit(0);
}
