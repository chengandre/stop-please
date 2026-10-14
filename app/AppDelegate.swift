import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController!

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
        menuBar = MenuBarController(coordinator: coordinator)
        registerToggleShortcut { Task { await coordinator.toggle() } }
        Task { await helper.start() }
    }
}
