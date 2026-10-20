import os
import ServiceManagement

private let logger = Logger(subsystem: "com.andrecheng.StopPlease", category: "login")

/// "Launch at login" in Settings (BUILD_GUIDE §12): the app as its own login item
/// through `SMAppService.mainApp`, listed in System Settings → General → Login
/// Items. macOS holds the state rather than user defaults, because the user can
/// also switch it there; Settings reads it again whenever it becomes key.
@MainActor @Observable
final class LaunchAtLogin {
    private(set) var status = SMAppService.mainApp.status

    var isEnabled: Bool { status == .enabled }

    func refresh() {
        let status = SMAppService.mainApp.status
        if status != self.status {
            logger.info("Status \(status.name, privacy: .public)")
        }
        self.status = status
    }

    /// A call that does not throw can still leave it short of enabled, e.g.
    /// `.requiresApproval`, so the status read afterwards is what the checkbox shows.
    func set(_ enabled: Bool) {
        let call = enabled ? "Register" : "Unregister"
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            status = SMAppService.mainApp.status
            logger.info("\(call, privacy: .public): status \(self.status.name, privacy: .public)")
        } catch {
            status = SMAppService.mainApp.status
            logger.error("\(call, privacy: .public) failed: \(error.localizedDescription, privacy: .public); status \(self.status.name, privacy: .public)")
        }
    }
}

private extension SMAppService.Status {
    var name: String {
        switch self {
        case .notRegistered: "notRegistered"
        case .enabled: "enabled"
        case .requiresApproval: "requiresApproval"
        case .notFound: "notFound"
        @unknown default: "unknown \(rawValue)"
        }
    }
}
