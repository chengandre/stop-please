import AppKit
import Carbon.HIToolbox
import os

private let logger = Logger(subsystem: "com.andrecheng.PausePlaying", category: "shortcut")

extension NSEvent.ModifierFlags {
    /// The modifiers a shortcut is made of. Caps Lock, fn, and device bits such as
    /// the `0x100` one keyboard adds to every event are not part of it.
    static let shortcutModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    /// In the order macOS menus use.
    private static let named: [(flag: NSEvent.ModifierFlags, symbol: String, name: String)] = [
        (.control, "⌃", "Control"), (.option, "⌥", "Option"), (.shift, "⇧", "Shift"), (.command, "⌘", "Command"),
    ]

    /// "⌃⇧" for control and shift.
    var symbols: String {
        Self.named.filter { contains($0.flag) }.map(\.symbol).joined()
    }

    /// "Control + Shift", as setup spells the media-key shortcut out.
    var names: String {
        Self.named.filter { contains($0.flag) }.map(\.name).joined(separator: " + ")
    }
}

/// The keyboard shortcut (BUILD_GUIDE §10.4): a virtual key code and ⌃⌥⇧⌘. Saved
/// as a key code, so its name follows the keyboard layout.
struct KeyboardShortcut: Equatable {
    static let standard = KeyboardShortcut(keyCode: kVK_ANSI_P, modifiers: [.control, .option, .command])
    /// A recorded shortcut needs at least one of these, so that it cannot take
    /// over a key used for typing.
    static let requiredModifiers: NSEvent.ModifierFlags = [.command, .control, .option]

    /// F1 to F20; the codes are not consecutive.
    private static let functionKeys = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    let keyCode: Int
    let modifiers: NSEvent.ModifierFlags

    /// "P", "1", "=", or "F5"; nil for a key that cannot be a shortcut: Space,
    /// Return, Tab, Delete, Esc, the arrows, and the other navigation keys.
    var keyName: String? {
        if let index = Self.functionKeys.firstIndex(of: keyCode) {
            return "F\(index + 1)"
        }
        return character?.uppercased()
    }

    /// "⌃⌥⌘P", as the menu and Settings show it.
    var name: String { modifiers.symbols + (keyName ?? "?") }

    /// The menu item's key equivalent, drawn like ⌘Q.
    var keyEquivalent: String {
        if let index = Self.functionKeys.firstIndex(of: keyCode) {
            return String(Character(UnicodeScalar(NSF1FunctionKey + index)!))
        }
        return character ?? ""
    }

    var carbonModifiers: UInt32 {
        var flags = 0
        if modifiers.contains(.control) { flags |= controlKey }
        if modifiers.contains(.option) { flags |= optionKey }
        if modifiers.contains(.shift) { flags |= shiftKey }
        if modifiers.contains(.command) { flags |= cmdKey }
        return UInt32(flags)
    }

    /// What the key types without modifiers in the current ASCII-capable layout,
    /// the one macOS also uses for ⌘ shortcuts, so that a Chinese input source
    /// still names the key "P". Nil when that is a control character or white
    /// space.
    private var character: String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layout = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(layout).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { bytes in
            UCKeyTranslate(bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress, UInt16(keyCode),
                           UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                           OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState, 4, &length, &characters)
        }
        guard status == noErr, length > 0 else { return nil }
        let text = String(utf16CodeUnits: characters, count: length)
        let typed = text.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0)
        }
        return typed ? text : nil
    }
}

/// The keyboard shortcut system-wide (BUILD_GUIDE §6.5, §10.1). Carbon hot keys
/// need no Accessibility or Input Monitoring permission.
///
/// Registered shared, as the common shortcut libraries do: if another app has the
/// same combination, both get the press. Only exclusive registrations can refuse
/// each other, and hardly any app makes one, so a conflict is not detected
/// (BUILD_GUIDE §10.4; PERL_HELPER.md, "Settings gate").
@MainActor
final class GlobalShortcut {
    var action: () -> Void = {}
    private var hotKey: EventHotKeyRef?

    init() {
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            // Hot key events arrive on the main thread's application event target.
            MainActor.assumeIsolated {
                Unmanaged<GlobalShortcut>.fromOpaque(userData!).takeUnretainedValue().action()
            }
            return noErr
        }, 1, &pressed, Unmanaged.passUnretained(self).toOpaque(), nil)
        if status != noErr {
            logger.error("Shortcut handler unavailable: \(status)")
        }
    }

    /// Does nothing while one is registered.
    func register(_ shortcut: KeyboardShortcut) {
        guard hotKey == nil else { return }
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode), shortcut.carbonModifiers,
            EventHotKeyID(signature: OSType(0x5041_5553), id: 1),  // "PAUS"
            GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr {
            logger.error("Shortcut \(shortcut.name, privacy: .public) unavailable: hot key \(status)")
        }
    }

    func unregister() {
        guard let hotKey else { return }
        UnregisterEventHotKey(hotKey)
        self.hotKey = nil
    }
}
