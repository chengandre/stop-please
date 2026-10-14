import Carbon.HIToolbox
import os

private let logger = Logger(subsystem: "com.andrecheng.PausePlaying", category: "shortcut")

/// The action for the one registered shortcut. The Carbon callback is a C function
/// and cannot capture it.
@MainActor private var shortcutAction: () -> Void = {}

/// Register ⌃⌥⌘P system-wide (BUILD_GUIDE §6.5). Carbon hot keys need no
/// Accessibility or Input Monitoring permission. While the app runs, other apps
/// no longer receive the combination.
@MainActor
func registerToggleShortcut(_ action: @escaping () -> Void) {
    shortcutAction = action
    var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
        // Hot key events arrive on the main thread's application event target.
        MainActor.assumeIsolated { shortcutAction() }
        return noErr
    }, 1, &pressed, nil, nil)
    var hotKey: EventHotKeyRef?
    let hotKeyStatus = RegisterEventHotKey(
        UInt32(kVK_ANSI_P), UInt32(controlKey | optionKey | cmdKey),
        EventHotKeyID(signature: OSType(0x5041_5553), id: 1),  // "PAUS"
        GetApplicationEventTarget(), 0, &hotKey)
    if handlerStatus != noErr || hotKeyStatus != noErr {
        // eventHotKeyExistsErr (-9878): another app already owns the combination.
        logger.error("Shortcut ⌃⌥⌘P unavailable: handler \(handlerStatus), hot key \(hotKeyStatus)")
    }
}
