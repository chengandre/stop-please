import AppKit
import os
import SwiftUI

private let logger = Logger(subsystem: "com.andrecheng.StopPlease", category: "shortcut")

/// First-launch setup (BUILD_GUIDE §10.4, mockups F1–F3): choose the media-key
/// shortcut or the keyboard shortcut, each shown as recorded. Shown at launch
/// until the `setupDone` user default is set.
///
/// Continue with the keyboard closes the window. Continue with the media key
/// asks for Accessibility and waits in the window until the grant arrives; the
/// button becomes Done. Closing the window before Continue chooses the keyboard
/// shortcut, so that setup does not return at every launch.
@MainActor
final class SetupWindow: NSObject, NSWindowDelegate {
    private static let doneKey = "setupDone"

    private let shortcuts: ShortcutController
    private let window: NSWindow
    private let state = SetupState()

    init(shortcuts: ShortcutController) {
        self.shortcuts = shortcuts
        window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        super.init()
        window.title = "Stop Please!"
        let hosting = NSHostingView(rootView: SetupView(shortcuts: shortcuts, state: state,
                                                        onContinue: { [weak self] in self?.continuePressed() },
                                                        onDone: { [weak self] in self?.window.close() }))
        window.contentView = hosting
        // Sized now, so that `center()` uses the real size.
        window.setContentSize(hosting.fittingSize)
        window.isReleasedWhenClosed = false
        window.delegate = self
    }

    func showIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.doneKey) else { return }
        logger.info("Setup shown")
        window.center()
        // Since macOS 14 `activate()` only succeeds when the app in front yields,
        // and nothing yields to a menu-bar app at launch, so the window would open
        // behind that app. The deprecated form still brings it forward on macOS
        // 15.8 (PERL_HELPER.md, "Setup gate").
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard !UserDefaults.standard.bool(forKey: Self.doneKey) else { return }
        logger.info("Setup closed before Continue")
        finish(.keyboard)
    }

    private func continuePressed() {
        finish(state.selection)
        if state.selection == .keyboard {
            window.close()
        } else {
            state.waiting = true
        }
    }

    private func finish(_ choice: ShortcutController.Choice) {
        UserDefaults.standard.set(true, forKey: Self.doneKey)
        logger.info("Setup done: \(choice.rawValue, privacy: .public)")
        shortcuts.choose(choice)
    }
}

@MainActor @Observable
private final class SetupState {
    /// The media key is selected first (F1).
    var selection: ShortcutController.Choice = .mediaKey
    /// After Continue with the media key: waiting for the grant, or granted (F2, F3).
    var waiting = false
}

private struct SetupView: View {
    let shortcuts: ShortcutController
    let state: SetupState
    let onContinue: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            // A placeholder until the app has an icon.
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            VStack(spacing: 4) {
                Text("Choose your shortcut").font(.title2.bold())
                Text("One shortcut pauses everything playing, and later resumes it.")
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 10) {
                ChoiceCard(title: shortcuts.mediaKeyModifiers.names + " + Play/Pause",
                           isOn: state.selection == .mediaKey) {
                    state.selection = .mediaKey
                } content: {
                    mediaKeyDetail
                }
                ChoiceCard(title: "Keyboard shortcut " + shortcuts.keyboardShortcut.name,
                           isOn: state.selection == .keyboard) {
                    state.selection = .keyboard
                } content: {
                    Text("No permission needed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // After Continue the choice is made; Settings can change it.
                .disabled(state.waiting)
            }
            HStack {
                Spacer()
                if state.waiting {
                    Button("Done", action: onDone).keyboardShortcut(.defaultAction)
                } else {
                    Button("Continue", action: onContinue).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var mediaKeyDetail: some View {
        if !state.waiting {
            Text("Needs Accessibility, so that Stop Please can take the key before your player does.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if shortcuts.accessibilityNeeded {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Waiting for Accessibility…")
                    Spacer(minLength: 8)
                    Button("Open System Settings") { shortcuts.requestAccessibility() }
                }
                Text("\(shortcuts.keyboardShortcut.name) works until then.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        } else {
            Label {
                Text("Accessibility granted")
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            .font(.callout)
        }
    }
}

/// A radio card: the selected one has an accent outline, and a click anywhere on
/// it selects it.
private struct ChoiceCard<Content: View>: View {
    let title: String
    let isOn: Bool
    let select: () -> Void
    @ViewBuilder let content: Content

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            RadioButton(title: title, isOn: isOn, action: select)
            content.padding(.leading, 20)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isOn ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isOn ? 2 : 1)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .opacity(isEnabled ? 1 : 0.5)
    }
}
