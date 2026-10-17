import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The floating panel a shortcut press opens when several groups are saved
/// (BUILD_GUIDE §10.5): mockups C1–C3 with a small app title instead of the
/// header, sized and selected, with larger icons. The newest group starts selected. ↑/↓ move,
/// Tab and ⇧Tab cycle, Enter or a click resumes, and Esc, a click outside, or
/// opening the menu dismisses it without changes.
///
/// The panel takes keys without activating the app, so the app the user was in
/// stays in front and gets the keys back when the panel closes.
@MainActor
final class GroupChooser: NSObject, NSWindowDelegate {
    /// Called with the picked group after the panel has closed.
    var onPick: (PausedGroup.ID) -> Void = { _ in }

    private let icons: AppIconCache
    private let panel = ChooserPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: true)
    private let selection = ChooserSelection()
    private let hosting: NSHostingView<ChooserView>
    private var groups: [PausedGroup] = []

    var isOpen: Bool { panel.isVisible }

    init(icons: AppIconCache) {
        self.icons = icons
        hosting = NSHostingView(rootView: ChooserView(groups: [], selection: selection, icons: icons, onPick: { _ in }))
        super.init()
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // The app is never active, so hiding on deactivation could only misfire.
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.onKeyDown = { [weak self] event in self?.handleKey(event) }

        let material = NSVisualEffectView()
        material.material = .menu
        material.blendingMode = .behindWindow
        // Otherwise the material draws as inactive (flat) in an app that is never active.
        material.state = .active
        material.maskImage = Self.roundedMask(radius: 20)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: material.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: material.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: material.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: material.bottomAnchor),
        ])
        panel.contentView = material

        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    /// Show `groups` (newest first) centered on the screen with the mouse pointer.
    func show(_ groups: [PausedGroup]) {
        self.groups = groups
        selection.index = 0
        hosting.rootView = ChooserView(groups: groups, selection: selection, icons: icons) { [weak self] id in
            self?.pick(id)
        }
        let size = hosting.fittingSize
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main!
        let visible = screen.visibleFrame
        panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                              width: size.width, height: size.height), display: true)
        panel.makeKeyAndOrderFront(nil)
        // The shadow follows the rounded mask only once it is drawn.
        panel.invalidateShadow()
    }

    /// A click outside the panel takes key away from it.
    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    /// Every key press is handled here; other keys do nothing.
    private func handleKey(_ event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_UpArrow:
            selection.index = max(selection.index - 1, 0)
        case kVK_DownArrow:
            selection.index = min(selection.index + 1, groups.count - 1)
        case kVK_Tab:
            let step = event.modifierFlags.contains(.shift) ? -1 : 1
            selection.index = (selection.index + step + groups.count) % groups.count
        case kVK_Return, kVK_ANSI_KeypadEnter:
            pick(groups[selection.index].id)
        case kVK_Escape:
            close()
        default:
            break
        }
    }

    private func pick(_ id: PausedGroup.ID) {
        close()
        onPick(id)
    }

    private func close() {
        panel.orderOut(nil)
    }

    /// A stretchable rounded rectangle, so the material's corners are clipped.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// Becomes key without activating the app, and takes every key press before the
/// hosted SwiftUI view does, so Tab and the arrows never move focus inside it.
private final class ChooserPanel: NSPanel {
    var onKeyDown: (NSEvent) -> Void = { _ in }

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            onKeyDown(event)
        } else {
            super.sendEvent(event)
        }
    }
}

/// The selected row, changed by keys and by hovering.
@MainActor @Observable
private final class ChooserSelection {
    var index = 0
}

private struct ChooserView: View {
    let groups: [PausedGroup]
    let selection: ChooserSelection
    let icons: AppIconCache
    let onPick: (PausedGroup.ID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Pause Playing")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(EdgeInsets(top: 0, leading: 8, bottom: 6, trailing: 0))
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                row(group, selected: index == selection.index)
                    .onHover { inside in
                        if inside { selection.index = index }
                    }
                    .onTapGesture { onPick(group.id) }
            }
        }
        .padding(16)
        // Wider only when a group has many apps.
        .frame(minWidth: 240)
    }

    /// "15:42" plus one icon per app, like the menu's group rows. The selected row
    /// has an accent outline over a light accent fill.
    private func row(_ group: PausedGroup, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Text(group.timeText)
                .font(.system(size: 14, weight: selected ? .semibold : .regular))
                .monospacedDigit()
                .frame(width: 44, alignment: .leading)
            HStack(spacing: 4) {
                ForEach(group.sources, id: \.id) { source in
                    Image(nsImage: icons.icon(source.appBundle, size: 32))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 48)
        .background(selected ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 1.5)
            }
        }
        .contentShape(Rectangle())
    }
}
