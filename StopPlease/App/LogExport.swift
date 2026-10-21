import AppKit
import ApplicationServices
import OSLog

private let logger = Logger(subsystem: "com.andrecheng.StopPlease", category: "app")

/// "Export Log…" in Settings: the app's entries from the system log, after a
/// header written at export time, saved as a text file to attach to a bug
/// report. The entries are `notice` and above, which macOS keeps on disk for
/// hours to days depending on how busy the Mac is; `info` lines stay only in
/// memory and were seen gone within the hour.
///
/// A file looks like:
///
///     Stop Please 0.1 (1)
///     macOS Version 15.5 (Build 24F74)
///     Exported 2026-01-15 14:03:12 +0000
///     Shortcut: media key (⇧ Play/Pause, active); keyboard ⌃⌥⌘P
///     Accessibility: granted
///     Launch at login: on
///     42 entries since 2026-01-14 09:12:40
///
///     2026-01-14 09:12:40.118  notice  login  Register: status enabled
@MainActor @Observable
final class LogExport {
    /// "0.1 (1)": the version and the build number.
    static var appVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
    }

    /// "Version 15.5 (Build 24F74)".
    static var macOSVersion: String { ProcessInfo.processInfo.operatingSystemVersionString }

    /// The system log may hold less; this only bounds the read.
    private nonisolated static let window: TimeInterval = 7 * 24 * 3600

    private(set) var isExporting = false

    private let shortcuts: ShortcutController
    private let launchAtLogin: LaunchAtLogin

    init(shortcuts: ShortcutController, launchAtLogin: LaunchAtLogin) {
        self.shortcuts = shortcuts
        self.launchAtLogin = launchAtLogin
    }

    func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "StopPlease-log-\(Date().formatted(.iso8601.year().month().day())).txt"
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isExporting = true
        launchAtLogin.refresh()
        let settings = settingsLines()
        // Reading the store can take seconds.
        Task.detached(priority: .userInitiated) {
            let result = Result { try Self.read() }
            await MainActor.run { self.finish(result, settings: settings, to: url) }
        }
    }

    private func finish(_ result: Result<(lines: [String], first: Date?), any Error>, settings: [String], to url: URL) {
        isExporting = false
        do {
            let (lines, first) = try result.get()
            let since = first.map { "since \(Self.timestamp($0))" } ?? "in the system log"
            let header = ["Stop Please \(Self.appVersion)", "macOS \(Self.macOSVersion)",
                          "Exported \(Self.timestamp(Date(), withZone: true))"]
                + settings + ["\(lines.count) entries \(since)"]
            try (header + [""] + lines).joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
            logger.notice("Exported \(lines.count) log entries")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            logger.error("Log export failed: \(String(describing: error), privacy: .public)")
            NSAlert(error: error).runModal()
        }
    }

    /// The settings that most often explain a report.
    private func settingsLines() -> [String] {
        let mediaKey = "\(shortcuts.mediaKeyModifiers.symbols) Play/Pause"
        let shortcut = switch shortcuts.choice {
        case .keyboard: "Shortcut: keyboard \(shortcuts.keyboardShortcut.name); media key \(mediaKey)"
        case .mediaKey: "Shortcut: media key (\(mediaKey), \(shortcuts.mediaKeyActive ? "active" : "not active")); keyboard \(shortcuts.keyboardShortcut.name)"
        }
        return [shortcut,
                "Accessibility: \(AXIsProcessTrusted() ? "granted" : "not granted")",
                "Launch at login: \(launchAtLogin.isEnabled ? "on" : "off")"]
    }

    /// One formatted line per entry, oldest first, and the oldest entry's time.
    private nonisolated static func read() throws -> (lines: [String], first: Date?) {
        let store = try OSLogStore.local()
        let start = store.position(date: Date().addingTimeInterval(-window))
        let subsystem = Bundle.main.bundleIdentifier!
        let entries = try store.getEntries(at: start, matching: NSPredicate(format: "subsystem == %@", subsystem))
            .compactMap { $0 as? OSLogEntryLog }
        let lines = entries.map {
            "\(timestamp($0.date))  \(levelName($0.level))  \($0.category)  \($0.composedMessage)"
        }
        return (lines, entries.first?.date)
    }

    private nonisolated static func timestamp(_ date: Date, withZone: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = withZone ? "yyyy-MM-dd HH:mm:ss Z" : "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.string(from: date)
    }

    private nonisolated static func levelName(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: "debug"
        case .info: "info"
        case .notice: "notice"
        case .error: "error"
        case .fault: "fault"
        default: "level \(level.rawValue)"
        }
    }
}
