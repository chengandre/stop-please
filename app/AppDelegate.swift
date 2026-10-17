import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController!
    private var chooser: GroupChooser!
    private var pill: ConfirmationPill!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A second instance would run a second helper whose override windows could
        // overlap with this one's.
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier!).count > 1 {
            NSApp.terminate(nil)
            return
        }
        let helper = HelperClient(
            script: Bundle.main.url(forResource: "perl_helper", withExtension: "pl")!,
            library: Bundle.main.privateFrameworksURL!.appending(path: "libNowPlayingPerlHelper.dylib"))
        let coordinator = Coordinator(helper: helper)
        let icons = AppIconCache()
        menuBar = MenuBarController(coordinator: coordinator, icons: icons)
        let chooser = GroupChooser(icons: icons)
        chooser.onPick = { id in Task { await coordinator.resume(groupID: id) } }
        coordinator.onChooseGroup = { chooser.show(coordinator.groups) }
        self.chooser = chooser
        let pill = ConfirmationPill(icons: icons)
        coordinator.onConfirm = { pill.show($0) }
        self.pill = pill
        registerGlobalShortcut {
            // A press while the chooser is open is ignored (BUILD_GUIDE §10.5).
            guard !chooser.isOpen else { return }
            Task { await coordinator.shortcutPressed() }
        }
        Task { await helper.start() }
    }
}
