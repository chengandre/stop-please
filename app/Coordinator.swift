import AppKit
import os

private let logger = Logger(subsystem: "com.andrecheng.PausePlaying", category: "coordinator")

/// One source in a saved group, as it was when this app paused it.
struct PausedSource {
    let id: SourceID
    let name: String
    let titleAtPause: String?
}

/// The sources one Pause All paused (BUILD_GUIDE §10.2). It never changes after it
/// is created: resuming either removes it or keeps it whole for a retry.
struct PausedGroup: Identifiable {
    let id = UUID()
    let pausedAt: Date
    let sources: [PausedSource]
}

/// Something wrong with the route itself rather than with one source.
struct RouteWarning {
    let text: String
    /// The helper stopped for good; the menu offers Retry.
    let canRetry: Bool
}

/// Turns menu actions and shortcut presses into helper requests and keeps the
/// groups of sources this app paused (BUILD_GUIDE §10.1, §10.2). A group holds
/// only sources this app paused, so resuming never starts something that was
/// already paused before Pause All.
@MainActor
final class Coordinator {
    private static let maxGroups = 3

    private let helper: HelperClient
    /// Called after every change the menu shows.
    var onChange: () -> Void = {}

    /// The last listed sources, for display.
    private(set) var sources: [Source] = []
    /// Newest first, at most `maxGroups`. In memory only: identity is per process,
    /// so it would not survive an app relaunch anyway.
    private(set) var groups: [PausedGroup] = []
    /// Per-source problems from the last action, e.g. "Zen didn't respond". Kept
    /// until the next action.
    private(set) var messages: [String] = []
    /// Recomputed by every request.
    private(set) var routeWarning: RouteWarning?
    private(set) var isBusy = false

    init(helper: HelperClient) {
        self.helper = helper
    }

    func refresh() async {
        do {
            try await updateSources()
        } catch {
            report(error)
        }
        onChange()
    }

    func pauseAll() async {
        await perform {
            try await updateSources()
            try await pausePlaying()
        }
    }

    func resume(groupID: PausedGroup.ID) async {
        await perform {
            guard let group = groups.first(where: { $0.id == groupID }) else { return }
            try await resume(group)
        }
    }

    /// The shortcut (BUILD_GUIDE §10.1): pause whatever is playing; otherwise resume
    /// a group; otherwise do what the Play/Pause key would. Carbon has already
    /// swallowed the press, so the last case is handled here.
    func shortcutPressed() async {
        await perform {
            let current = try await updateSources()
            if sources.contains(where: { $0.state == "Playing" && $0.id != nil }) {
                try await pausePlaying()
            } else if let newest = groups.first {
                // The newest group until the chooser picks one (Phase 10).
                try await resume(newest)
            } else if let current {
                // With no current source nothing is sent, so Music.app never opens.
                try await play(current)
            }
        }
    }

    func retry() async {
        await helper.restart()
        await refresh()
    }

    /// Run one user action: one at a time, clearing the last action's messages, and
    /// turning a failed request into the route warning.
    private func perform(_ action: () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        messages = []
        defer {
            isBusy = false
            onChange()
        }
        do {
            try await action()
        } catch {
            report(error)
        }
    }

    /// Pause every Playing source in `sources` and save the ones that paused as the
    /// newest group, evicting the oldest beyond `maxGroups`.
    private func pausePlaying() async throws {
        let playing = sources.filter { $0.state == "Playing" }
        for source in playing where source.id == nil {
            messages.append("Can't control \(displayName(source))")
        }
        let targets = playing.compactMap(\.id)
        guard !targets.isEmpty else { return }
        let results = try await helper.command(.pause, targets: targets)
        log("Pause All", results)
        var paused: [PausedSource] = []
        for source in playing {
            guard let id = source.id, let result = results[id] else { continue }
            if result.outcome == .done {
                paused.append(PausedSource(id: id, name: displayName(source), titleAtPause: source.title))
            } else if let message = message(for: result.outcome, name: displayName(source)) {
                messages.append(message)
            }
        }
        // A source that will not pause must not create a group on every press and
        // evict the real ones.
        guard !paused.isEmpty else { return }
        groups.insert(PausedGroup(pausedAt: .now, sources: paused), at: 0)
        if groups.count > Self.maxGroups {
            groups.removeLast()
        }
        logger.info("Saved a group of \(paused.count) sources; \(self.groups.count) groups saved")
    }

    /// Play every source of `group`; the helper plays only those still Paused. The
    /// group is removed once something resumed or nothing is left to do, and kept
    /// for a retry when every attempt failed. A request that fails throws before
    /// this decision, so the group is kept then too.
    private func resume(_ group: PausedGroup) async throws {
        let results = try await helper.command(.play, targets: group.sources.map(\.id))
        routeWarning = nil
        log("Resume", results)
        for source in group.sources {
            if let result = results[source.id], let message = message(for: result.outcome, name: source.name) {
                messages.append(message)
            }
        }
        let outcomes = results.values.map(\.outcome)
        let finished = outcomes.contains(.done) || outcomes.allSatisfy { $0 == .skipped || $0 == .notFound }
        if finished {
            groups.removeAll { $0.id == group.id }
        }
        logger.info("Group \(finished ? "removed" : "kept for retry", privacy: .public); \(self.groups.count) groups saved")
    }

    /// Play the current source, as the Play/Pause key would with nothing saved.
    private func play(_ current: SourceID) async throws {
        let results = try await helper.command(.play, targets: [current])
        log("Play current", results)
        let name = sources.first { $0.id == current }.map(displayName) ?? current.clientBundle
        if let result = results[current], let message = message(for: result.outcome, name: name) {
            messages.append(message)
        }
    }

    /// List, and return the current source.
    ///
    /// An empty list while apps in saved groups are still running is the sign that
    /// macOS closed the read access (BUILD_GUIDE §5). It is only a warning: an app
    /// can also leave Now Playing while running, e.g. when the browser tab that was
    /// paused is closed.
    @discardableResult
    private func updateSources() async throws -> SourceID? {
        let list = try await helper.list()
        sources = list.sources
        routeWarning = nil
        let groupedRunning = groups.contains { group in
            group.sources.contains { NSRunningApplication(processIdentifier: $0.id.pid) != nil }
        }
        if sources.isEmpty, groupedRunning {
            routeWarning = RouteWarning(
                text: "Now Playing is empty while paused apps are still running. macOS may have blocked access.",
                canRetry: false)
        }
        return list.current
    }

    private func report(_ error: any Error) {
        logger.error("Request failed: \(String(describing: error), privacy: .public)")
        routeWarning = switch error as? HelperError {
        case .routeBroken(let reason):
            RouteWarning(text: "Can't reach Now Playing: \(reason).", canRetry: true)
        case .helperExited:
            RouteWarning(text: "The helper stopped and was restarted. Try again.", canRetry: false)
        case .failed(code: "timeout", _):
            RouteWarning(text: "Now Playing didn't answer in time. Try again.", canRetry: false)
        case .failed(_, let message):
            RouteWarning(text: "Now Playing request failed: \(message)", canRetry: false)
        case nil:
            RouteWarning(text: "Unexpected reply from the helper.", canRetry: false)
        }
    }

    private func message(for outcome: TargetResult.Outcome, name: String) -> String? {
        switch outcome {
        case .done, .skipped: nil
        case .notFound: "\(name) is no longer available"
        case .ambiguousBundle: "Can't control \(name) while another app with the same identity is playing"
        case .overrideNotHonored: "macOS didn't let this app switch to \(name)"
        case .noStateChange: "\(name) didn't respond"
        }
    }

    private func displayName(_ source: Source) -> String {
        source.appName ?? source.clientBundle ?? "pid \(source.pid)"
    }

    private func log(_ action: String, _ results: [SourceID: TargetResult]) {
        let summary = results.map { "\($0.key.clientBundle)[\($0.key.pid)] \($0.value.outcome) \($0.value.state ?? "-")" }
        logger.info("\(action, privacy: .public): \(summary.joined(separator: ", "), privacy: .public)")
    }
}
