import AppKit
import os

private let logger = Logger(subsystem: "com.andrecheng.PausePlaying", category: "shortcut")

/// An active event tap that swallows Play/Pause pressed with exactly `modifiers`
/// and runs `action` instead (BUILD_GUIDE §10.4). Every other press, plain
/// Play/Pause included, passes on to the player. Needs Accessibility: without it
/// the tap cannot be created (PERL_HELPER.md, "Event-tap spike").
@MainActor
final class MediaKeyTap {
    /// Only these take part in the match: Caps Lock and fn are ignored, and so are
    /// device bits such as the `0x100` one keyboard adds to every event.
    private static let matchedModifiers: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
    /// `NX_SUBTYPE_AUX_CONTROL_BUTTONS`: media keys.
    private static let mediaKeySubtype: Int16 = 8
    /// `NX_KEYTYPE_PLAY`.
    private static let playKey = 16

    let modifiers: NSEvent.ModifierFlags
    private let action: () -> Void
    /// Called when macOS turned the tap off; true for a timeout. The tap is left
    /// off: turning it back on after a revoke froze every click (PERL_HELPER.md,
    /// "Media-key gate").
    var onDisabled: (_ byTimeout: Bool) -> Void = { _ in }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// A key-down was swallowed, so its key-up is too, even if the modifiers were
    /// released first: a stray key-up should not reach the player.
    private var swallowingKeyUp = false

    init(modifiers: NSEvent.ModifierFlags, action: @escaping () -> Void) {
        self.modifiers = modifiers
        self.action = action
    }

    /// Whether macOS still lets this process create an active tap, which it does
    /// only with Accessibility. Decided afresh each time, unlike
    /// `AXIsProcessTrusted`, whose cache a revoke can leave stale (AltTab,
    /// `src/macos/SystemPermissions.swift`). The probe asks for no events and is
    /// never added to a run loop, so no event passes through it or waits on it
    /// (hops, `crates/input-event/src/accessibility.rs`).
    static func canCreateTap() -> Bool {
        guard let probe = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .defaultTap,
            eventsOfInterest: 0, callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
            userInfo: nil)
        else { return false }
        CGEvent.tapEnable(tap: probe, enable: false)
        CFMachPortInvalidate(probe)
        return true
    }

    /// Creates the tap unless it is running. False when macOS refuses it.
    func start() -> Bool {
        guard tap == nil else { return true }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << NSEvent.EventType.systemDefined.rawValue),
            callback: { _, type, event, userInfo in
                // The tap's run-loop source is on the main run loop.
                let swallow = MainActor.assumeIsolated {
                    Unmanaged<MediaKeyTap>.fromOpaque(userInfo!).takeUnretainedValue().handle(type, event)
                }
                return swallow ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        // Common modes, so the tap keeps working while the menu is open.
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.tap = tap
        self.source = source
        logger.info("Media-key tap created")
        return true
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        CFMachPortInvalidate(tap)
        self.tap = nil
        source = nil
        swallowingKeyUp = false
        logger.info("Media-key tap removed")
    }

    /// True to swallow the event. Acts on key-down and ignores repeats.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let byTimeout = type == .tapDisabledByTimeout
            logger.info("Media-key tap disabled by \(byTimeout ? "timeout" : "user input", privacy: .public)")
            onDisabled(byTimeout)
            return false
        }
        guard let event = NSEvent(cgEvent: event), event.subtype.rawValue == Self.mediaKeySubtype,
              event.data1 >> 16 & 0xFFFF == Self.playKey
        else { return false }
        // data1: key code in the high 16 bits, 0xA down / 0xB up, bit 0 repeat.
        switch event.data1 >> 8 & 0xFF {
        case 0xA where event.modifierFlags.intersection(Self.matchedModifiers) == modifiers:
            swallowingKeyUp = true
            if event.data1 & 1 == 0 { action() }
            return true
        case 0xB where swallowingKeyUp:
            swallowingKeyUp = false
            return true
        default:
            return false
        }
    }
}
