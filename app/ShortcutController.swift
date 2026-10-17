import AppKit
import ApplicationServices
import os

private let logger = Logger(subsystem: "com.andrecheng.PausePlaying", category: "shortcut")

/// Decides which shortcut runs a press (BUILD_GUIDE §10.4): the keyboard shortcut,
/// or the media-key shortcut when it is chosen and macOS allows its tap. Only the
/// active one is installed, so the other reaches other apps as usual.
///
/// The choice is the `shortcut` user default, `keyboard` (the default) or
/// `mediaKey`; Settings sets it in Phase 11 step 2.
///
/// A revoke must remove the tap before the next click: macOS keeps a revoked tap
/// in the event stream and holds each event it subscribes to, mouse-button events
/// included, until the tap times out after seconds (PERL_HELPER.md, "Media-key
/// gate"). So while the media key is chosen the grant is checked every second,
/// shortly after every Accessibility change notice, and when the menu opens.
@MainActor
final class ShortcutController {
    enum Choice: String {
        case keyboard, mediaKey
    }

    /// Recorded in Settings from Phase 11 step 2.
    private static let mediaKeyModifiers: NSEvent.ModifierFlags = .shift
    private static let mediaKeyName = symbols(mediaKeyModifiers) + " Play/Pause"
    /// After timeouts the tap is created again at most this many times within
    /// `timeoutWindow`; one more timeout leaves it off until the Accessibility
    /// list changes or the app relaunches. Caps the freezes if macOS ever allows
    /// a tap it then holds events for.
    private static let timeoutsAllowed = 2
    private static let timeoutWindow: TimeInterval = 30

    let choice: Choice
    /// Called whenever what the menu shows changes.
    var onChange: () -> Void = {}

    private let keyboard: GlobalShortcut
    private let mediaKey: MediaKeyTap
    private(set) var mediaKeyActive = false
    /// Until Accessibility has been seen granted, `AXIsProcessTrusted` decides
    /// whether to try the tap: hops saw a tap created before the first grant show
    /// macOS's "would like to control this Mac" dialog. After that, creating a
    /// tap decides, since `AXIsProcessTrusted` can keep a stale answer.
    private var grantedOnce = false
    private var recentTimeouts: [Date] = []
    private var stoppedAfterTimeouts = false
    /// The last probe answer, so that only changes are logged.
    private var lastProbe: Bool?
    /// The prompt adds the app to the Accessibility list only while it has no
    /// entry, and only once per launch (AltTab, Mac Mouse Fix), so it is asked
    /// at most once per run, as hops does.
    private var askedThisRun = false

    /// The media-key shortcut as the menu shows it, e.g. "⇧⏯".
    var mediaKeyBadge: String { Self.symbols(mediaKey.modifiers) + "⏯" }

    /// Shown in the menu while the media-key shortcut is chosen but its tap is off.
    var accessibilityNeeded: Bool { choice == .mediaKey && !mediaKeyActive }

    init(action: @escaping () -> Void) {
        choice = Choice(rawValue: UserDefaults.standard.string(forKey: "shortcut") ?? "") ?? .keyboard
        keyboard = GlobalShortcut {
            logger.info("Pressed ⌃⌥⌘P")
            action()
        }
        mediaKey = MediaKeyTap(modifiers: Self.mediaKeyModifiers) {
            logger.info("Pressed \(Self.mediaKeyName, privacy: .public)")
            action()
        }
        logger.info("Chosen \(self.choice.rawValue, privacy: .public)")
        keyboard.register()
        guard choice == .mediaKey else { return }
        mediaKey.onDisabled = { [weak self] byTimeout in self?.tapDisabled(byTimeout: byTimeout) }
        // Phase 11 step 3 moves this to the moment setup chooses the media key.
        if !AXIsProcessTrusted() {
            requestAccessibility()
        }
        watchGrant()
        update()
    }

    /// "Accessibility Needed…": the first time in a run, macOS's prompt, whose
    /// Open System Settings button lists the app (switched off) and opens the
    /// pane; after that, the pane. An app removed from the list after the prompt
    /// was used comes back when it relaunches.
    func requestAccessibility() {
        if askedThisRun {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        } else {
            askedThisRun = true
            logger.info("Asking for Accessibility")
            // The key is `kAXTrustedCheckOptionPrompt`, a global var Swift 6 rejects.
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
    }

    /// `com.apple.accessibility.api` is undocumented and arrives when any app's
    /// Accessibility switch changes, before tccd has written the change (AltTab),
    /// so the checks follow it by 0.1 s and 0.5 s. Removing the app from the list
    /// may post nothing; the one-second check covers that.
    private func watchGrant() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            logger.info("Accessibility list changed")
            Task { @MainActor in
                self?.recentTimeouts = []
                self?.stoppedAfterTimeouts = false
                try? await Task.sleep(for: .milliseconds(100))
                self?.update()
                try? await Task.sleep(for: .milliseconds(400))
                self?.update()
            }
        }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        // Common modes, so checks continue while the menu is open.
        RunLoop.main.add(timer, forMode: .common)
    }

    /// While the tap runs, removes it if a probe says macOS no longer allows it.
    /// While it is off, creates it if macOS allows it: the creation is the check.
    func update() {
        guard choice == .mediaKey else { return }
        if mediaKeyActive {
            if !probe() {
                mediaKey.stop()
                setMediaKeyActive(false)
            }
        } else if !stoppedAfterTimeouts, grantedOnce || AXIsProcessTrusted(), mediaKey.start() {
            grantedOnce = true
            setMediaKeyActive(true)
        }
    }

    private func probe() -> Bool {
        let started = Date()
        let permitted = MediaKeyTap.canCreateTap()
        if permitted != lastProbe {
            let milliseconds = Date().timeIntervalSince(started) * 1000
            logger.info("Probe \(permitted ? "permitted" : "refused", privacy: .public) in \(milliseconds, format: .fixed(precision: 1)) ms")
            lastProbe = permitted
        }
        return permitted
    }

    /// macOS turned the tap off. It is removed rather than turned back on, and
    /// created again on the next turn of the run loop only if macOS allows it,
    /// within the timeout limit.
    private func tapDisabled(byTimeout: Bool) {
        mediaKey.stop()
        setMediaKeyActive(false)
        if byTimeout {
            let now = Date()
            recentTimeouts = recentTimeouts.filter { now.timeIntervalSince($0) < Self.timeoutWindow } + [now]
            if recentTimeouts.count > Self.timeoutsAllowed {
                stoppedAfterTimeouts = true
                logger.error("\(self.recentTimeouts.count) timeouts in \(Int(Self.timeoutWindow)) s; media key off until the Accessibility list changes")
            }
        }
        // Not from inside the removed tap's callback.
        Task { @MainActor [weak self] in self?.update() }
    }

    private func setMediaKeyActive(_ active: Bool) {
        mediaKeyActive = active
        if active {
            keyboard.unregister()
        } else {
            keyboard.register()
        }
        logger.info("Active shortcut: \(active ? Self.mediaKeyName : "⌃⌥⌘P", privacy: .public)")
        onChange()
    }

    /// "⌃⇧" for control and shift, in the order macOS menus use.
    private static func symbols(_ modifiers: NSEvent.ModifierFlags) -> String {
        [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { modifiers.contains($0.0) }
            .map(\.1)
            .joined()
    }
}
