import AppKit

/// The status item and its menu (BUILD_GUIDE §10.3). Opening the menu shows the
/// last known state at once and refreshes the list; the menu is rebuilt whenever
/// the coordinator changes, also while it is open.
///
/// Text on the right edge is drawn by AppKit so that it lines up with ⌘Q: states
/// and "Resume" are badges, the shortcut is a key equivalent.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    /// Longer titles end in "…": about 30 Latin or 15 Chinese characters.
    private static let maxTitleWidth: CGFloat = 220

    /// Group times keep their width as the digits change.
    private static let timeFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize,
                                                                   weight: .regular)

    /// A dot in the image column, so per-source messages line up with the route
    /// warning's ⚠.
    private static let messageDot: NSImage = {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.midX - 2, y: rect.midY - 2, width: 4, height: 4)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()

    /// The orange ⚠ of the route warning and "Accessibility Needed…".
    private static let warningImage = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                              accessibilityDescription: "Warning")?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemOrange]))

    private let coordinator: Coordinator
    private let shortcuts: ShortcutController
    private let settings: SettingsWindow
    private let icons: AppIconCache
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    /// The group row showing "Resume"; cleared when the highlight moves.
    private weak var highlightedGroupItem: NSMenuItem?

    init(coordinator: Coordinator, shortcuts: ShortcutController, settings: SettingsWindow, icons: AppIconCache) {
        self.coordinator = coordinator
        self.shortcuts = shortcuts
        self.settings = settings
        self.icons = icons
        super.init()
        // A template image from the asset catalog; its shadow is partly transparent.
        let icon = NSImage(named: "MenuBarIcon")!
        icon.accessibilityDescription = "Pause Playing"
        statusItem.button?.image = icon
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        coordinator.onChange = { [weak self] in self?.rebuild() }
        shortcuts.onChange = { [weak self] in self?.rebuild() }
        rebuild()
    }

    func menuWillOpen(_ menu: NSMenu) {
        shortcuts.update()
        Task { await coordinator.refresh() }
    }

    private func rebuild() {
        menu.removeAllItems()
        highlightedGroupItem = nil

        // A broken route makes the last list meaningless; Retry is offered below.
        let routeBroken = coordinator.routeWarning?.canRetry == true

        menu.addItem(.sectionHeader(title: "Now Playing"))
        if routeBroken {
            menu.addItem(infoItem("Now Playing unavailable"))
        } else if coordinator.sources.isEmpty {
            menu.addItem(infoItem("Nothing in Now Playing"))
        } else {
            for source in coordinator.sources {
                menu.addItem(sourceItem(source))
            }
        }
        menu.addItem(.separator())
        let canPause = !routeBroken && coordinator.sources.contains { $0.state == "Playing" }
        let pauseAllItem = actionItem("Pause All Playing", #selector(pauseAll), enabled: !coordinator.isBusy && canPause)
        // Shows the active shortcut. The keyboard one is a key equivalent, drawn like
        // ⌘Q; while the menu is open it also triggers Pause All, which is what the
        // shortcut does while something is playing. Play/Pause is a system event,
        // not a character, so the media-key shortcut is a badge instead.
        if shortcuts.mediaKeyActive {
            pauseAllItem.badge = NSMenuItemBadge(string: shortcuts.mediaKeyBadge)
        } else {
            pauseAllItem.keyEquivalent = shortcuts.keyboardShortcut.keyEquivalent
            pauseAllItem.keyEquivalentModifierMask = shortcuts.keyboardShortcut.modifiers
        }
        menu.addItem(pauseAllItem)

        if !coordinator.groups.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Resume"))
            for group in coordinator.groups {
                menu.addItem(groupItem(group))
            }
        }

        if !coordinator.messages.isEmpty || coordinator.routeWarning != nil {
            menu.addItem(.separator())
            for message in coordinator.messages {
                let item = infoItem(message)
                item.image = Self.messageDot
                menu.addItem(item)
            }
            if let warning = coordinator.routeWarning {
                let item = infoItem(warning.text)
                item.image = Self.warningImage
                menu.addItem(item)
                if warning.canRetry {
                    menu.addItem(actionItem("Retry", #selector(retry), enabled: true))
                }
            }
        }

        if shortcuts.accessibilityNeeded {
            menu.addItem(.separator())
            let item = actionItem("Accessibility Needed…", #selector(requestAccessibility), enabled: true)
            item.image = Self.warningImage
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let settingsItem = actionItem("Settings…", #selector(openSettings), enabled: true)
        settingsItem.keyEquivalent = ","
        menu.addItem(settingsItem)
        menu.addItem(withTitle: "Quit Pause Playing", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    /// The app's icon, the title (the app name when there is none), and the state.
    /// Only Playing and Paused sources with a client bundle can be clicked.
    private func sourceItem(_ source: Source) -> NSMenuItem {
        let name = source.appName ?? source.clientBundle ?? "pid \(source.pid)"
        let text = if let title = source.title, !title.isEmpty { shorten(title) } else { name }
        let canCommand = source.id != nil && ["Playing", "Paused"].contains(source.state)
        let item = actionItem(text, #selector(playOrPause(_:)), enabled: !coordinator.isBusy && canCommand)
        item.image = icons.icon(source.appBundle, size: 26)
        item.representedObject = source.id
        item.badge = NSMenuItemBadge(string: source.state)
        return item
    }

    /// "15:42" plus one icon per app. "Resume" appears while it is highlighted
    /// (`menu(_:willHighlight:)`), and the tooltip lists the titles.
    private func groupItem(_ group: PausedGroup) -> NSMenuItem {
        let title = NSMutableAttributedString(string: group.timeText + "  ",
                                              attributes: [.font: Self.timeFont])
        for source in group.sources {
            let icon = NSTextAttachment()
            icon.image = icons.icon(source.appBundle, size: 16)
            // Centered on the digits rather than sitting on the baseline.
            icon.bounds = NSRect(x: 0, y: (Self.timeFont.capHeight - 16) / 2, width: 16, height: 16)
            title.append(NSAttributedString(attachment: icon))
            title.append(NSAttributedString(string: " ", attributes: [.font: Self.timeFont]))
        }
        let item = actionItem("", #selector(resumeGroup(_:)), enabled: !coordinator.isBusy)
        item.attributedTitle = title
        item.representedObject = group.id
        item.toolTip = group.sources.map { label($0.name, $0.titleAtPause) }.joined(separator: "\n")
        return item
    }

    /// Changing an item while the menu is open shows only after `itemChanged`.
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        if let previous = highlightedGroupItem {
            previous.badge = nil
            menu.itemChanged(previous)
            highlightedGroupItem = nil
        }
        if let item, item.representedObject is PausedGroup.ID {
            item.badge = NSMenuItemBadge(string: "Resume")
            menu.itemChanged(item)
            highlightedGroupItem = item
        }
    }

    /// "Spotify — To My Youth", with long titles shortened.
    private func label(_ name: String, _ title: String?) -> String {
        guard let title, !title.isEmpty else { return name }
        return "\(name) — \(shorten(title))"
    }

    /// Cut at a drawn width rather than a character count, so a Chinese title does
    /// not make the menu twice as wide as a Latin one.
    private func shorten(_ title: String) -> String {
        let font = NSFont.menuFont(ofSize: 0)
        func width(_ text: String) -> CGFloat {
            NSAttributedString(string: text, attributes: [.font: font]).size().width
        }
        guard width(title) > Self.maxTitleWidth else { return title }
        // Binary search for the longest prefix that fits with the ellipsis.
        var fits = 0, tooLong = title.count
        while tooLong - fits > 1 {
            let middle = (fits + tooLong) / 2
            if width(String(title.prefix(middle)) + "…") <= Self.maxTitleWidth {
                fits = middle
            } else {
                tooLong = middle
            }
        }
        return title.prefix(fits).trimmingCharacters(in: .whitespaces) + "…"
    }

    private func infoItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func actionItem(_ title: String, _ action: Selector, enabled: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        return item
    }

    @objc private func pauseAll() {
        Task { await coordinator.pauseAll() }
    }

    @objc private func playOrPause(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? SourceID else { return }
        Task { await coordinator.playOrPause(id) }
    }

    /// The group is found by id, not position: groups can change while a request runs.
    @objc private func resumeGroup(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? PausedGroup.ID else { return }
        Task { await coordinator.resume(groupID: id) }
    }

    @objc private func retry() {
        Task { await coordinator.retry() }
    }

    @objc private func requestAccessibility() {
        shortcuts.requestAccessibility()
    }

    @objc private func openSettings() {
        settings.show()
    }
}
