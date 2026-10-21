import AppKit
import Carbon.HIToolbox
import os
import SwiftUI

private let logger = Logger(subsystem: "com.andrecheng.StopPlease", category: "shortcut")

/// "Stop Please! Settings": launch at login, which shortcut is chosen and a
/// recorder for each, and Export Log…. Opening it activates the app so that the
/// window can take keys; it has no Dock icon either way.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let recorder: ShortcutRecorder
    private let launchAtLogin: LaunchAtLogin

    init(shortcuts: ShortcutController, launchAtLogin: LaunchAtLogin) {
        recorder = ShortcutRecorder(shortcuts: shortcuts)
        self.launchAtLogin = launchAtLogin
        window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        super.init()
        window.title = "Stop Please! Settings"
        // Sized by the view, also when the Accessibility box appears or goes.
        let logExport = LogExport(shortcuts: shortcuts, launchAtLogin: launchAtLogin)
        let hosting = NSHostingView(rootView: SettingsView(shortcuts: shortcuts, recorder: recorder,
                                                           launchAtLogin: launchAtLogin, logExport: logExport))
        window.contentView = hosting
        // Sized now, so that the first `center()` uses the real size.
        window.setContentSize(hosting.fittingSize)
        window.isReleasedWhenClosed = false
        window.delegate = self
    }

    func show() {
        if !window.isVisible {
            window.center()
        }
        // Clicking the status menu does not make this app active, so, as for
        // setup, the cooperative `activate()` would leave the window behind.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// The login item may have been switched in System Settings meanwhile.
    func windowDidBecomeKey(_ notification: Notification) {
        launchAtLogin.refresh()
    }

    /// Closing the window, or another window taking key, ends a recording unsaved.
    func windowDidResignKey(_ notification: Notification) {
        recorder.stop()
    }

    /// A refusal explains the last recording; it is stale when the window reopens.
    func windowWillClose(_ notification: Notification) {
        recorder.refusal = nil
    }
}

/// Records one shortcut at a time. A local event monitor sees every key and
/// modifier change before the window does (SwiftUI never sees a press and release
/// of modifiers alone), and consumes them so that no key reaches a control.
///
/// - Keyboard: the first key press ends the recording. Esc cancels; Space,
///   Return, Tab, the arrows, and a press without ⌘, ⌃, or ⌥ are refused.
/// - Media key: the modifiers held at the most are saved once all are released.
///   Esc cancels. Play/Pause is not a key press, so it never reaches the monitor.
///
/// A click anywhere ends a recording unsaved; a click on a recorder field then
/// starts recording that one.
@MainActor @Observable
final class ShortcutRecorder {
    enum Target {
        case keyboard, mediaKey
    }

    private(set) var target: Target?
    /// ⌃⌥⇧⌘ held now, shown live in the field.
    private(set) var held: NSEvent.ModifierFlags = []
    /// Why the last keyboard recording was refused, until the next one starts or
    /// the window closes.
    var refusal: String?

    private let shortcuts: ShortcutController
    /// Every modifier held since the media-key recording started.
    @ObservationIgnored private var peak: NSEvent.ModifierFlags = []
    @ObservationIgnored private var monitor: Any?

    init(shortcuts: ShortcutController) {
        self.shortcuts = shortcuts
    }

    func start(_ target: Target) {
        stop()
        self.target = target
        refusal = nil
        held = []
        peak = []
        shortcuts.beginRecording()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown]) {
            [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return consumed ? nil : event
        }
    }

    func stop() {
        guard target != nil else { return }
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        target = nil
        held = []
        shortcuts.endRecording()
    }

    /// True to consume the event.
    private func handle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .flagsChanged:
            held = event.modifierFlags.intersection(.shortcutModifiers)
            peak.formUnion(held)
            if target == .mediaKey, held.isEmpty, !peak.isEmpty {
                shortcuts.record(mediaKeyModifiers: peak)
                stop()
            }
            return true
        case .keyDown:
            if Int(event.keyCode) == kVK_Escape {
                stop()
            } else if target == .keyboard {
                finishKeyboard(KeyboardShortcut(keyCode: Int(event.keyCode),
                                                modifiers: event.modifierFlags.intersection(.shortcutModifiers)))
            }
            return true
        default:
            stop()
            return false
        }
    }

    private func finishKeyboard(_ shortcut: KeyboardShortcut) {
        let kept = "Kept \(shortcuts.keyboardShortcut.name)."
        if shortcut.keyName == nil {
            refusal = "Use a letter, number, symbol, or F-key. \(kept)"
        } else if shortcut.modifiers.isDisjoint(with: KeyboardShortcut.requiredModifiers) {
            refusal = "Needs ⌘, ⌃, or ⌥. \(kept)"
        } else {
            shortcuts.record(shortcut)
        }
        if let refusal {
            logger.notice("Refused key \(shortcut.keyCode) with \(shortcut.modifiers.symbols, privacy: .public): \(refusal, privacy: .public)")
        }
        stop()
    }
}

private struct SettingsView: View {
    let shortcuts: ShortcutController
    let recorder: ShortcutRecorder
    let launchAtLogin: LaunchAtLogin
    let logExport: LogExport

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup(title: "General") {
                Toggle("Launch at login", isOn: Binding(get: { launchAtLogin.isEnabled }, set: { launchAtLogin.set($0) }))
                    .toggleStyle(.checkbox)
            }
            VStack(alignment: .leading, spacing: 10) {
                SettingsGroup(title: "Shortcut") {
                    VStack(alignment: .leading, spacing: 12) {
                        keyboardRow
                        Divider()
                        mediaKeyRow
                    }
                }
                Text("Only the chosen shortcut responds. Both recordings are kept.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            SettingsGroup(title: "Troubleshooting") {
                HStack {
                    Text("Save the recent log to attach to a bug report.")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    Button("Export Log…") { logExport.export() }
                        .disabled(logExport.isExporting)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var keyboardRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                RadioButton(title: "Keyboard", isOn: shortcuts.choice == .keyboard) { shortcuts.choose(.keyboard) }
                Spacer()
                let recording = recorder.target == .keyboard
                RecorderField(text: recording ? heldText("Type shortcut") : shortcuts.keyboardShortcut.name,
                              isPlaceholder: recording && recorder.held.isEmpty, isRecording: recording) {
                    recorder.start(.keyboard)
                }
                ResetButton(help: "Restore \(KeyboardShortcut.standard.name)") { shortcuts.restoreKeyboardShortcut() }
                    .disabled(shortcuts.keyboardShortcut == .standard)
            }
            Caption(text: keyboardCaption.text, isError: keyboardCaption.isError)
        }
    }

    private var keyboardCaption: (text: String, isError: Bool) {
        if recorder.target == .keyboard {
            return ("Press a combination with ⌘, ⌃, or ⌥. Esc cancels.", false)
        }
        if let refusal = recorder.refusal {
            return (refusal, true)
        }
        return ("Include ⌘, ⌃, or ⌥. Media keys are ignored.", false)
    }

    private var mediaKeyRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                RadioButton(title: "Media key", isOn: shortcuts.choice == .mediaKey) { shortcuts.choose(.mediaKey) }
                Spacer()
                let recording = recorder.target == .mediaKey
                RecorderField(text: recording ? heldText("Hold modifiers") : shortcuts.mediaKeyModifiers.symbols,
                              isPlaceholder: recording && recorder.held.isEmpty, isRecording: recording) {
                    recorder.start(.mediaKey)
                }
                Text("+ Play/Pause")
                ResetButton(help: "Restore \(ShortcutController.standardMediaKeyModifiers.symbols) + Play/Pause") {
                    shortcuts.restoreMediaKeyModifiers()
                }
                .disabled(shortcuts.mediaKeyModifiers == ShortcutController.standardMediaKeyModifiers)
            }
            Caption(text: mediaKeyCaption, isError: false)
            if shortcuts.choice == .mediaKey {
                accessibilityStatus
                    .padding(.leading, 20)
                    .padding(.top, 4)
            }
        }
    }

    private var mediaKeyCaption: String {
        guard recorder.target == .mediaKey else {
            return "Hold modifiers, then release to save. Play/Pause is fixed."
        }
        if recorder.held.isEmpty {
            return "Hold modifiers, then release to save. Esc cancels."
        }
        return "Release to save \(recorder.held.symbols) + Play/Pause."
    }

    @ViewBuilder private var accessibilityStatus: some View {
        if shortcuts.accessibilityNeeded {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Needs Accessibility. \(shortcuts.keyboardShortcut.name) works until it's granted.")
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Open System Settings…") { shortcuts.requestAccessibility() }
            }
            .font(.callout)
            .padding(8)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        } else {
            Label {
                Text("Accessibility granted")
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    /// The modifiers held while recording, or `placeholder` before any.
    private func heldText(_ placeholder: String) -> String {
        recorder.held.isEmpty ? placeholder : recorder.held.symbols
    }
}

/// A titled box, one per kind of setting.
private struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        GroupBox {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        } label: {
            Text(title).font(.headline)
        }
    }
}

/// Under a row's radio title.
private struct Caption: View {
    let text: String
    let isError: Bool

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(isError ? Color.red : Color.secondary)
            .padding(.leading, 20)
    }
}

/// A field showing a shortcut; clicking it records. While recording it has a
/// focus ring.
private struct RecorderField: View {
    let text: String
    let isPlaceholder: Bool
    let isRecording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .foregroundStyle(isPlaceholder ? Color.secondary : Color.primary)
                .frame(minWidth: 100)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isRecording ? Color(nsColor: .keyboardFocusIndicatorColor) : Color(nsColor: .separatorColor),
                                      lineWidth: isRecording ? 3 : 1)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A square after a recorder field that restores its default; dimmed while the
/// default is recorded. Its click also ends a recording, as any click does.
private struct ResetButton: View {
    let help: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.counterclockwise")
                .foregroundStyle(isEnabled ? Color.primary : Color.secondary.opacity(0.5))
                .frame(width: 24, height: 24)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// A native radio button, for Settings and setup. The two choices are separate
/// views, so AppKit does not group them; the state comes from the choice instead.
struct RadioButton: NSViewRepresentable {
    let title: String
    let isOn: Bool
    let action: () -> Void

    func makeNSView(context: Context) -> NSButton {
        NSButton(radioButtonWithTitle: title, target: context.coordinator, action: #selector(Coordinator.clicked))
    }

    func updateNSView(_ button: NSButton, context: Context) {
        button.state = isOn ? .on : .off
        button.isEnabled = context.environment.isEnabled
        context.coordinator.action = action
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func clicked() {
            action()
        }
    }
}
