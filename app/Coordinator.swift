import AppKit
import os

private let logger = Logger(subsystem: "com.andrecheng.PausePlaying", category: "coordinator")

/// One source this app paused, kept so it can be resumed later.
struct PausedEntry {
    let id: SourceID
    let name: String
    let titleAtPause: String?
    /// Included in the next Resume Selected.
    var selected = true
}

/// Something wrong with the route itself rather than with one source.
struct RouteWarning {
    let text: String
    /// The helper stopped for good; the menu offers Retry.
    let canRetry: Bool
}

/// Turns menu actions into helper requests and remembers what this app paused
/// (BUILD_GUIDE §6.3). It remembers only sources it paused, so Resume never starts
/// something that was already paused before Pause All.
@MainActor
final class Coordinator {
    private let helper: HelperClient
    /// Called after every change the menu shows.
    var onChange: () -> Void = {}

    /// The last listed sources, for display.
    private(set) var sources: [Source] = []
    /// In pause order. In memory only: identity is per process, so it would not
    /// survive an app relaunch anyway.
    private(set) var paused: [PausedEntry] = []
    /// Per-source problems from the last Pause All or Resume Selected, e.g.
    /// "Zen didn't respond". Kept until the next action.
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
        guard !isBusy else { return }
        isBusy = true
        messages = []
        defer {
            isBusy = false
            onChange()
        }
        do {
            try await updateSources()
            let playing = sources.filter { $0.state == "Playing" }
            for source in playing where source.id == nil {
                messages.append("Can't control \(displayName(source))")
            }
            let targets = playing.compactMap(\.id)
            guard !targets.isEmpty else { return }
            let results = try await helper.command(.pause, targets: targets)
            log("Pause All", results)
            for source in playing {
                guard let id = source.id, let result = results[id] else { continue }
                if result.outcome == .done {
                    if !paused.contains(where: { $0.id == id }) {
                        paused.append(PausedEntry(id: id, name: displayName(source), titleAtPause: source.title))
                    }
                } else if let message = message(for: result.outcome, name: displayName(source)) {
                    messages.append(message)
                }
            }
        } catch {
            report(error)
        }
    }

    func resumeSelected() async {
        let selected = paused.filter(\.selected)
        guard !isBusy, !selected.isEmpty else { return }
        isBusy = true
        messages = []
        defer {
            isBusy = false
            onChange()
        }
        do {
            // The helper re-finds each entry and plays it only if it is still Paused.
            let results = try await helper.command(.play, targets: selected.map(\.id))
            routeWarning = nil
            log("Resume Selected", results)
            for entry in selected {
                guard let result = results[entry.id] else { continue }
                if let message = message(for: result.outcome, name: entry.name) {
                    messages.append(message)
                }
                // Nothing left to retry for these; the other outcomes stay so the user can.
                if [.done, .notFound, .skipped].contains(result.outcome) {
                    paused.removeAll { $0.id == entry.id }
                }
            }
        } catch {
            report(error)
        }
    }

    /// The shortcut: Resume Selected while this app holds paused entries, otherwise
    /// Pause All Playing. Refreshing first drops entries resumed or quit elsewhere,
    /// so they do not turn a press meant to pause into a resume that does nothing.
    func toggle() async {
        guard !isBusy else { return }
        await refresh()
        if paused.isEmpty {
            await pauseAll()
        } else {
            await resumeSelected()
        }
    }

    func setSelected(_ selected: Bool, for id: SourceID) {
        guard let index = paused.firstIndex(where: { $0.id == id }) else { return }
        paused[index].selected = selected
    }

    func retry() async {
        await helper.restart()
        await refresh()
    }

    /// List, then drop entries the user resumed or quit outside this app.
    ///
    /// An empty list while paused apps are still running is the sign that macOS
    /// closed the read access (BUILD_GUIDE §5); entries are kept then. It is only a
    /// warning: an app can also leave Now Playing while running, e.g. when the
    /// browser tab that was paused is closed.
    private func updateSources() async throws {
        sources = try await helper.list()
        routeWarning = nil
        if sources.isEmpty, paused.contains(where: { NSRunningApplication(processIdentifier: $0.id.pid) != nil }) {
            routeWarning = RouteWarning(
                text: "Now Playing is empty while paused apps are still running. macOS may have blocked access.",
                canRetry: false)
            return
        }
        // A browser can show Paused briefly right after resuming, but never Playing
        // while paused, so only Playing (or gone) drops an entry.
        let states = Dictionary(sources.compactMap { source in source.id.map { ($0, source.state) } },
                                uniquingKeysWith: { first, _ in first })
        paused.removeAll { states[$0.id] == nil || states[$0.id] == "Playing" }
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
