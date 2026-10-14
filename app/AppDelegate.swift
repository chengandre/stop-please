import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let helper = HelperClient(
        script: Bundle.main.url(forResource: "perl_helper", withExtension: "pl")!,
        library: Bundle.main.privateFrameworksURL!.appending(path: "libNowPlayingPerlHelper.dylib"))
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "pause.circle", accessibilityDescription: "Pause Playing")

        let menu = NSMenu()
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        Task { await helper.start() }
    }
}
