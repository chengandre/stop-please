import AppKit

/// The status item and its menu (BUILD_GUIDE §6.4). Opening the menu shows the
/// last known state at once and refreshes the list; the menu is rebuilt whenever
/// the coordinator changes, also while it is open.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let coordinator: Coordinator
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    /// Enabled only while an entry is selected; updated by the checkboxes without a rebuild.
    private weak var resumeItem: NSMenuItem?

    init(coordinator: Coordinator) {
        self.coordinator = coordinator
        super.init()
        statusItem.button?.image = NSImage(systemSymbolName: "pause.circle", accessibilityDescription: "Pause Playing")
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        coordinator.onChange = { [weak self] in self?.rebuild() }
        rebuild()
    }

    func menuWillOpen(_ menu: NSMenu) {
        Task { await coordinator.refresh() }
    }

    private func rebuild() {
        menu.removeAllItems()

        menu.addItem(.sectionHeader(title: "Now Playing"))
        if coordinator.sources.isEmpty {
            menu.addItem(infoItem("Nothing in Now Playing"))
        }
        for source in coordinator.sources {
            let item = infoItem(label(source.appName ?? source.clientBundle ?? "pid \(source.pid)", source.title))
            item.badge = NSMenuItemBadge(string: source.state)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(actionItem("Pause All Playing", #selector(pauseAll),
                                enabled: !coordinator.isBusy && coordinator.sources.contains { $0.state == "Playing" }))

        if !coordinator.paused.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Paused by This App"))
            for (index, entry) in coordinator.paused.enumerated() {
                menu.addItem(checkboxItem(entry, tag: index))
            }
            let resume = actionItem("Resume Selected", #selector(resumeSelected), enabled: canResume)
            resumeItem = resume
            menu.addItem(resume)
        }

        if !coordinator.messages.isEmpty || coordinator.routeWarning != nil {
            menu.addItem(.separator())
            for message in coordinator.messages {
                menu.addItem(infoItem(message))
            }
            if let warning = coordinator.routeWarning {
                let item = infoItem(warning.text)
                item.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Warning")
                menu.addItem(item)
                if warning.canRetry {
                    menu.addItem(actionItem("Retry", #selector(retry), enabled: true))
                }
            }
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Pause Playing", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    private var canResume: Bool {
        !coordinator.isBusy && coordinator.paused.contains(where: \.selected)
    }

    /// "Spotify — To My Youth", with long titles shortened.
    private func label(_ name: String, _ title: String?) -> String {
        guard let title, !title.isEmpty else { return name }
        let short = title.count > 40 ? title.prefix(39) + "…" : Substring(title)
        return "\(name) — \(short)"
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

    /// A checkbox in a view, so clicking it keeps the menu open and several entries
    /// can be toggled in one opening. `tag` is the entry's index in
    /// `coordinator.paused`; every change to that list rebuilds the menu.
    private func checkboxItem(_ entry: PausedEntry, tag: Int) -> NSMenuItem {
        let checkbox = NSButton(checkboxWithTitle: label(entry.name, entry.titleAtPause),
                                target: self, action: #selector(toggleEntry(_:)))
        checkbox.state = entry.selected ? .on : .off
        checkbox.tag = tag
        checkbox.sizeToFit()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: checkbox.frame.width + 28, height: checkbox.frame.height + 6))
        checkbox.setFrameOrigin(NSPoint(x: 14, y: 3))
        view.addSubview(checkbox)
        let item = NSMenuItem()
        item.view = view
        return item
    }

    @objc private func toggleEntry(_ sender: NSButton) {
        coordinator.setSelected(sender.state == .on, for: coordinator.paused[sender.tag].id)
        resumeItem?.isEnabled = canResume
    }

    @objc private func pauseAll() {
        Task { await coordinator.pauseAll() }
    }

    @objc private func resumeSelected() {
        Task { await coordinator.resumeSelected() }
    }

    @objc private func retry() {
        Task { await coordinator.retry() }
    }
}
