import Foundation
import os

private let logger = Logger(subsystem: "com.andrecheng.PausePlaying", category: "helper")

enum HelperError: Error {
    /// The helper answered `{"ok": false}`: `timeout`, `mediaRemoteError`, or
    /// `badRequest` (BUILD_GUIDE §3.2). A failed `command` sent nothing.
    case failed(code: String, message: String)
    /// The helper exited before replying; a new one is already starting.
    case helperExited
    /// The route is gone (BUILD_GUIDE §5). Every request fails until the app relaunches.
    case routeBroken(reason: String)
}

/// Owns the one long-running helper, `/usr/bin/perl perl_helper.pl <library>`,
/// spoken to with one JSON line per request and per reply (BUILD_GUIDE §3, §6.2).
///
/// The helper is restarted as soon as it exits, not on the next request: a crash
/// inside an override window keeps media keys on the command's target until a new
/// helper's startup releases the override. A helper that exits again within
/// `minimumUptimeAfterRestart` of a restart, or reports `fatal`, breaks the route.
actor HelperClient {
    private enum State {
        case stopped
        case starting(input: FileHandle)
        case ready(input: FileHandle)
        case broken(reason: String)
    }

    private static let perl = URL(filePath: "/usr/bin/perl")
    private static let minimumUptimeAfterRestart: TimeInterval = 10

    private let script: URL
    private let library: URL
    private var state = State.stopped
    /// Requests waiting for the helper to leave `starting`.
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []
    /// Raw reply lines by request id. The helper answers one request at a time, in order.
    private var pending: [Int: CheckedContinuation<Data, any Error>] = [:]
    private var nextRequestID = 1
    private var lastRestart: Date?

    init(script: URL, library: URL) {
        self.script = script
        self.library = library
        // A write to a helper that has just exited would raise SIGPIPE and kill the
        // app; ignored, the write throws EPIPE instead.
        signal(SIGPIPE, SIG_IGN)
    }

    func start() {
        if case .stopped = state { launch() }
    }

    /// Start a new helper after the route broke, e.g. from the menu's Retry.
    func restart() {
        guard case .broken = state else { return }
        lastRestart = nil
        launch()
    }

    func list() async throws -> [Source] {
        try await send(Request(op: "list"), replying: ListReply.self).sources
    }

    /// Explicit play or pause for each target, with each target's result. The
    /// helper re-finds every target in a fresh list, so stale identities come back
    /// `notFound` rather than reaching another app.
    func command(_ action: CommandAction, targets: [SourceID]) async throws -> [SourceID: TargetResult] {
        let reply = try await send(Request(op: "command", action: action, targets: targets), replying: CommandReply.self)
        // Results follow the target order.
        return Dictionary(uniqueKeysWithValues: zip(targets, reply.results))
    }

    private func send<Reply: Decodable>(_ request: Request, replying: Reply.Type) async throws -> Reply {
        let input = try await readyInput()
        var request = request
        request.id = nextRequestID
        nextRequestID += 1
        var line = try JSONEncoder().encode(request)
        line.append(0x0A)
        let reply = try await withCheckedThrowingContinuation { continuation in
            pending[request.id] = continuation
            do {
                try input.write(contentsOf: line)
            } catch {
                pending[request.id] = nil
                continuation.resume(throwing: HelperError.helperExited)
            }
        }
        let decoder = JSONDecoder()
        if let failure = try decoder.decode(ReplyStatus.self, from: reply).error {
            throw HelperError.failed(code: failure.code, message: failure.message)
        }
        return try decoder.decode(Reply.self, from: reply)
    }

    private func readyInput() async throws -> FileHandle {
        while true {
            switch state {
            case .stopped:
                launch()
            case .starting:
                await withCheckedContinuation { readyWaiters.append($0) }
            case .ready(let input):
                return input
            case .broken(let reason):
                throw HelperError.routeBroken(reason: reason)
            }
        }
    }

    private func setState(_ newState: State) {
        state = newState
        if case .starting = newState { return }
        for waiter in readyWaiters { waiter.resume() }
        readyWaiters.removeAll()
    }

    private func launch() {
        guard FileManager.default.isExecutableFile(atPath: Self.perl.path) else {
            return setState(.broken(reason: "\(Self.perl.path) is missing"))
        }
        let process = Process()
        process.executableURL = Self.perl
        process.arguments = [script.path, library.path]
        // PATH only: an inherited PERL5OPT or PERL5LIB would run other code in the helper.
        process.environment = ["PATH": "/usr/bin:/bin"]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        // Logging only; the end of stdout is what counts as the exit (`helperExited`),
        // so a `fatal` line is always handled before it.
        process.terminationHandler = { process in
            let how = process.terminationReason == .uncaughtSignal ? "signal" : "status"
            logger.info("Helper \(process.processIdentifier) exited with \(how, privacy: .public) \(process.terminationStatus)")
        }
        do {
            try process.run()
        } catch {
            return setState(.broken(reason: "Could not start the helper: \(error.localizedDescription)"))
        }
        logger.info("Helper \(process.processIdentifier) started")
        setState(.starting(input: input.fileHandleForWriting))

        Task {
            for await chunk in chunks(of: errors.fileHandleForReading) {
                logger.error("Helper stderr: \(String(decoding: chunk, as: UTF8.self), privacy: .public)")
            }
        }
        Task {
            // Split on newline bytes only: Foundation's line splitting also breaks at
            // U+2028, which JSON leaves unescaped inside strings such as titles.
            var buffer = Data()
            for await chunk in chunks(of: output.fileHandleForReading) {
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    received(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                }
            }
            helperExited()
        }
    }

    /// Everything read from `handle`, in order, until end of file. Uses
    /// `readabilityHandler` rather than `FileHandle.bytes`, whose blocking reads
    /// stalled the stdout reader while the stderr reader waited.
    private func chunks(of handle: FileHandle) -> AsyncStream<Data> {
        AsyncStream { continuation in
            handle.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    continuation.finish()
                } else {
                    continuation.yield(data)
                }
            }
        }
    }

    /// One event or reply line from the helper.
    private func received(_ line: Data) {
        let message: Message
        do {
            message = try JSONDecoder().decode(Message.self, from: line)
        } catch {
            logger.fault("Unreadable helper output: \(String(decoding: line, as: UTF8.self), privacy: .public)")
            return
        }
        switch message.event {
        case "ready":
            if case .starting(let input) = state {
                logger.info("Helper ready")
                setState(.ready(input: input))
            }
        case "fatal":
            let failure = message.error.map { "\($0.code): \($0.message)" } ?? "no error"
            logger.error("Helper fatal: \(failure, privacy: .public)")
            setState(.broken(reason: "MediaRemote is unavailable (\(failure))"))
        default:
            if let id = message.id {
                pending.removeValue(forKey: id)?.resume(returning: line)
            }
        }
    }

    private func helperExited() {
        for request in pending.values { request.resume(throwing: HelperError.helperExited) }
        pending.removeAll()
        // After `fatal`, a restart would fail the same way.
        if case .broken = state { return }
        if let lastRestart, Date.now.timeIntervalSince(lastRestart) < Self.minimumUptimeAfterRestart {
            logger.error("Helper exited again within \(Int(Self.minimumUptimeAfterRestart)) s of a restart")
            return setState(.broken(reason: "The helper keeps exiting"))
        }
        logger.error("Helper exited unexpectedly; restarting")
        lastRestart = .now
        launch()
    }
}

// Wire formats (BUILD_GUIDE §3.2).

private struct Request: Encodable {
    var id = 0
    let op: String
    var action: CommandAction?
    var targets: [SourceID]?
}

private struct Failure: Decodable {
    let code: String
    let message: String
}

/// Any line: `{"event": "ready", …}`, `{"event": "fatal", "error": …}`, or a reply `{"id": 1, "ok": …}`.
private struct Message: Decodable {
    let event: String?
    let id: Int?
    let error: Failure?
}

private struct ReplyStatus: Decodable {
    let error: Failure?
}

private struct ListReply: Decodable {
    let sources: [Source]
}

private struct CommandReply: Decodable {
    let results: [TargetResult]
}
