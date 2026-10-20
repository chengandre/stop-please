import AppKit
import ApplicationServices
import os

private let logger = Logger(subsystem: "com.andrecheng.StopPlease", category: "shortcut")

/// Decides which shortcut runs a press (BUILD_GUIDE §10.4): the keyboard shortcut,
/// or the media-key shortcut when it is chosen and macOS allows its tap. Only the
/// active one is installed, so the other reaches other apps as usual.
///
/// Saved in user defaults: `shortcut` (`keyboard`, the default, or `mediaKey`),
/// `keyboardKeyCode` and `keyboardModifiers` (default ⌃⌥⌘P), and
/// `mediaKeyModifiers` (default ⇧). Modifiers are `NSEvent.ModifierFlags` raw
/// values.
///
/// A revoke must remove the tap before the next click: macOS keeps a revoked tap
/// in the event stream and holds each event it subscribes to, mouse-button events
/// included, until the tap times out after seconds (PERL_HELPER.md, "Media-key
/// gate"). So while the media key is chosen the grant is checked every second,
/// shortly after every Accessibility change notice, and when the menu opens.
@MainActor @Observable
final class ShortcutController {
    enum Choice: String {
        case keyboard, mediaKey
    }

    /// After timeouts the tap is created again at most this many times within
    /// `timeoutWindow`; one more timeout leaves it off until the Accessibility
    /// list changes or the app relaunches. Caps the freezes if macOS ever allows
    /// a tap it then holds events for.
    private static let timeoutsAllowed = 2
    private static let timeoutWindow: TimeInterval = 30

    private(set) var choice: Choice
    private(set) var keyboardShortcut: KeyboardShortcut
    private(set) var mediaKeyModifiers: NSEvent.ModifierFlags
    private(set) var mediaKeyActive = false
    /// While Settings records a shortcut, presses do nothing, and the keyboard
    /// shortcut is unregistered so that its keys reach the recorder.
    private(set) var isRecording = false
    /// Called whenever what the menu shows changes.
    @ObservationIgnored var onChange: () -> Void = {}

    private let action: () -> Void
    private let keyboard = GlobalShortcut()
    private let mediaKey: MediaKeyTap
    /// Until Accessibility has been seen granted, `AXIsProcessTrusted` decides
    /// whether to try the tap: hops saw a tap created before the first grant show
    /// macOS's "would like to control this Mac" dialog. After that, creating a
    /// tap decides, since `AXIsProcessTrusted` can keep a stale answer.
    @ObservationIgnored private var grantedOnce = false
    @ObservationIgnored private var recentTimeouts: [Date] = []
    @ObservationIgnored private var stoppedAfterTimeouts = false
    /// The last probe answer, so that only changes are logged.
    @ObservationIgnored private var lastProbe: Bool?
    /// The prompt adds the app to the Accessibility list only while it has no
    /// entry, and only once per launch (AltTab, Mac Mouse Fix), so it is asked
    /// at most once per run, as hops does.
    @ObservationIgnored private var askedThisRun = false
    /// The grant checks run only while the media key is chosen.
    @ObservationIgnored private var grantObserver: NSObjectProtocol?
    @ObservationIgnored private var grantTimer: Timer?

    /// The media-key shortcut as the menu shows it, e.g. "⇧⏯".
    var mediaKeyBadge: String { mediaKeyModifiers.symbols + "⏯" }

    /// Shown in the menu and Settings while the media-key shortcut is chosen but
    /// its tap is off.
    var accessibilityNeeded: Bool { choice == .mediaKey && !mediaKeyActive }

    private var mediaKeyName: String { mediaKeyModifiers.symbols + " Play/Pause" }

    init(action: @escaping () -> Void) {
        let defaults = UserDefaults.standard
        choice = Choice(rawValue: defaults.string(forKey: "shortcut") ?? "") ?? .keyboard
        if let keyCode = defaults.object(forKey: "keyboardKeyCode") as? Int,
           let modifiers = defaults.object(forKey: "keyboardModifiers") as? Int {
            keyboardShortcut = KeyboardShortcut(keyCode: keyCode, modifiers: NSEvent.ModifierFlags(rawValue: UInt(modifiers)))
        } else {
            keyboardShortcut = .standard
        }
        let mediaKeyModifiers = (defaults.object(forKey: "mediaKeyModifiers") as? Int)
            .map { NSEvent.ModifierFlags(rawValue: UInt($0)) } ?? .shift
        self.mediaKeyModifiers = mediaKeyModifiers
        self.action = action
        mediaKey = MediaKeyTap(modifiers: mediaKeyModifiers)
        keyboard.action = { [weak self] in
            guard let self else { return }
            pressed(keyboardShortcut.name)
        }
        mediaKey.action = { [weak self] in
            guard let self else { return }
            pressed(mediaKeyName)
        }
        mediaKey.onDisabled = { [weak self] byTimeout in self?.tapDisabled(byTimeout: byTimeout) }
        logger.info("Chosen \(self.choice.rawValue, privacy: .public): \(self.keyboardShortcut.name, privacy: .public), \(self.mediaKeyName, privacy: .public)")
        registerKeyboard()
        // A launch never asks for Accessibility: setup asks when it chooses the
        // media key, and later "Accessibility Needed…" does.
        guard choice == .mediaKey else { return }
        startGrantChecks()
        update()
    }

    /// From setup and Settings. Choosing the media key asks for Accessibility the
    /// first time in a run unless it looks granted, also when it is already the
    /// choice: setup may confirm the saved choice.
    func choose(_ newChoice: Choice) {
        if newChoice == .mediaKey, !askedThisRun, !AXIsProcessTrusted() {
            requestAccessibility()
        }
        guard newChoice != choice else { return }
        choice = newChoice
        UserDefaults.standard.set(newChoice.rawValue, forKey: "shortcut")
        logger.info("Chosen \(newChoice.rawValue, privacy: .public)")
        switch newChoice {
        case .mediaKey:
            recentTimeouts = []
            stoppedAfterTimeouts = false
            startGrantChecks()
            update()
        case .keyboard:
            stopGrantChecks()
            if mediaKeyActive {
                mediaKey.stop()
                setMediaKeyActive(false)
            }
        }
        onChange()
    }

    func beginRecording() {
        isRecording = true
        keyboard.unregister()
        logger.info("Recording started")
    }

    func endRecording() {
        isRecording = false
        if !mediaKeyActive {
            registerKeyboard()
        }
        logger.info("Recording ended")
        onChange()
    }

    /// While recording.
    func record(_ shortcut: KeyboardShortcut) {
        keyboardShortcut = shortcut
        UserDefaults.standard.set(shortcut.keyCode, forKey: "keyboardKeyCode")
        UserDefaults.standard.set(Int(shortcut.modifiers.rawValue), forKey: "keyboardModifiers")
        logger.info("Recorded \(shortcut.name, privacy: .public)")
    }

    /// While recording.
    func record(mediaKeyModifiers modifiers: NSEvent.ModifierFlags) {
        mediaKeyModifiers = modifiers
        mediaKey.modifiers = modifiers
        UserDefaults.standard.set(Int(modifiers.rawValue), forKey: "mediaKeyModifiers")
        logger.info("Recorded \(self.mediaKeyName, privacy: .public)")
    }

    /// "Accessibility Needed…" and the Open System Settings buttons of setup and
    /// Settings: the first time in a run, macOS's prompt, whose Open System
    /// Settings button lists the app (switched off) and opens the pane; after
    /// that, the pane. An app removed from the list after the prompt was used
    /// comes back when it relaunches.
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

    private func pressed(_ name: String) {
        guard !isRecording else {
            logger.info("Pressed \(name, privacy: .public) while recording; ignored")
            return
        }
        logger.info("Pressed \(name, privacy: .public)")
        action()
    }

    /// `com.apple.accessibility.api` is undocumented and arrives when any app's
    /// Accessibility switch changes, before tccd has written the change (AltTab),
    /// so the checks follow it by 0.1 s and 0.5 s. Removing the app from the list
    /// may post nothing; the one-second check covers that.
    private func startGrantChecks() {
        grantObserver = DistributedNotificationCenter.default().addObserver(
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
        grantTimer = timer
    }

    private func stopGrantChecks() {
        if let grantObserver {
            DistributedNotificationCenter.default().removeObserver(grantObserver)
        }
        grantObserver = nil
        grantTimer?.invalidate()
        grantTimer = nil
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
            registerKeyboard()
        }
        logger.info("Active shortcut: \(active ? self.mediaKeyName : self.keyboardShortcut.name, privacy: .public)")
        onChange()
    }

    /// Not while recording: the recorder needs the keys, and `endRecording`
    /// registers it.
    private func registerKeyboard() {
        guard !isRecording else { return }
        keyboard.register(keyboardShortcut)
    }
}
