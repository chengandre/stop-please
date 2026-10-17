import AppKit
import SwiftUI

/// The translucent pill near the bottom center of the screen with the mouse pointer
/// after every group-level action (BUILD_GUIDE §10.10, mockups H1–H5): app icons
/// and one word, sized like the chooser. It fades after about 1.5 s, never takes
/// focus, and lets clicks through. A new action replaces it and restarts the timer.
@MainActor
final class ConfirmationPill {
    private static let height: CGFloat = 66

    private let icons: AppIconCache
    private let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: true)
    private let hosting: NSHostingView<PillView>
    private var hideTask: Task<Void, Never>?
    /// Counts shows, so a fade that finishes after a newer show leaves it alone.
    private var shown = 0

    init(icons: AppIconCache) {
        self.icons = icons
        hosting = NSHostingView(rootView: PillView(confirmation: Confirmation(text: "", apps: []), icons: icons))
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        // The app is never active, so hiding on deactivation could only misfire.
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let material = NSVisualEffectView.floatingPanelBackground(cornerRadius: Self.height / 2)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: material.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: material.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: material.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: material.bottomAnchor),
        ])
        panel.contentView = material
    }

    func show(_ confirmation: Confirmation) {
        hosting.rootView = PillView(confirmation: confirmation, icons: icons)
        let width = hosting.fittingSize.width
        // Above the Dock, at about the height the mockups show it.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main!
        let visible = screen.visibleFrame
        panel.setFrame(NSRect(x: visible.midX - width / 2, y: visible.minY + visible.height * 0.12,
                              width: width, height: Self.height), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        panel.invalidateShadow()

        shown += 1
        let generation = shown
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.fadeOut(generation)
        }
    }

    private func fadeOut(_ generation: Int) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.shown == generation else { return }
                self.panel.orderOut(nil)
            }
        }
    }
}

private struct PillView: View {
    let confirmation: Confirmation
    let icons: AppIconCache

    var body: some View {
        HStack(spacing: 15) {
            HStack(spacing: 6) {
                if confirmation.apps.isEmpty {
                    // Nothing changed or nothing was sent (H5).
                    Image(systemName: "pause.circle")
                        .font(.system(size: 39))
                        .foregroundStyle(.secondary)
                        .frame(width: 48, height: 48)
                } else {
                    ForEach(Array(confirmation.apps.enumerated()), id: \.offset) { _, app in
                        icon(app)
                    }
                }
            }
            Text(confirmation.text)
                .font(.system(size: 21, weight: .semibold))
        }
        .padding(EdgeInsets(top: 9, leading: 9, bottom: 9, trailing: 24))
    }

    /// A source that did not change is dimmed with an amber "!"; the menu says why.
    private func icon(_ app: Confirmation.App) -> some View {
        Image(nsImage: icons.icon(app.appBundle, size: 48))
            .opacity(app.failed ? 0.4 : 1)
            .overlay(alignment: .bottomTrailing) {
                if app.failed {
                    Image(systemName: "exclamationmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .orange)
                        .font(.system(size: 21, weight: .bold))
                        .offset(x: 5, y: 5)
                }
            }
    }
}
