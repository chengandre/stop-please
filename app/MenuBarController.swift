import AppKit

/// The status item and its menu (BUILD_GUIDE §10.3). Opening the menu shows the
/// last known state at once and refreshes the list; the menu is rebuilt whenever
/// the coordinator changes, also while it is open.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    /// Group times are 24-hour whatever the locale (BUILD_GUIDE §10.3).
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private let coordinator: Coordinator
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()

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

        if !coordinator.groups.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Resume"))
            for group in coordinator.groups {
                let time = Self.timeFormatter.string(from: group.pausedAt)
                let names = group.sources.map(\.name).joined(separator: ", ")
                let item = actionItem("\(time) — \(names)", #selector(resumeGroup(_:)), enabled: !coordinator.isBusy)
                item.representedObject = group.id
                item.toolTip = group.sources.map { label($0.name, $0.titleAtPause) }.joined(separator: "\n")
                menu.addItem(item)
            }
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

    @objc private func pauseAll() {
        Task { await coordinator.pauseAll() }
    }

    /// The group is found by id, not position: groups can change while a request runs.
    @objc private func resumeGroup(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? PausedGroup.ID else { return }
        Task { await coordinator.resume(groupID: id) }
    }

    @objc private func retry() {
        Task { await coordinator.retry() }
    }
}
