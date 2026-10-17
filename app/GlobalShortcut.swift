import Carbon.HIToolbox
import os

private let logger = Logger(subsystem: "com.andrecheng.PausePlaying", category: "shortcut")

/// The action for the keyboard shortcut. The Carbon callback is a C function and
/// cannot capture it, so there is only one `GlobalShortcut`.
@MainActor private var shortcutAction: () -> Void = {}

/// ⌃⌥⌘P system-wide (BUILD_GUIDE §6.5, §10.1). Carbon hot keys need no
/// Accessibility or Input Monitoring permission. While it is registered, other
/// apps no longer receive the combination.
@MainActor
final class GlobalShortcut {
    private var hotKey: EventHotKeyRef?

    init(action: @escaping () -> Void) {
        shortcutAction = action
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            // Hot key events arrive on the main thread's application event target.
            MainActor.assumeIsolated { shortcutAction() }
            return noErr
        }, 1, &pressed, nil, nil)
        if status != noErr {
            logger.error("Shortcut handler unavailable: \(status)")
        }
    }

    func register() {
        guard hotKey == nil else { return }
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_P), UInt32(controlKey | optionKey | cmdKey),
            EventHotKeyID(signature: OSType(0x5041_5553), id: 1),  // "PAUS"
            GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr {
            // eventHotKeyExistsErr (-9878): another app already owns the combination.
            logger.error("Shortcut ⌃⌥⌘P unavailable: hot key \(status)")
        }
    }

    func unregister() {
        guard let hotKey else { return }
        UnregisterEventHotKey(hotKey)
        self.hotKey = nil
    }
}
