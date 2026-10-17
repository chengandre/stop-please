import AppKit
import UniformTypeIdentifiers

/// App icons by bundle ID, shared by the menu and the chooser. The menu is rebuilt
/// on every refresh, and the lookup reads the app bundle from disk.
@MainActor
final class AppIconCache {
    private var icons: [String: NSImage] = [:]

    /// The icon of the app with this bundle ID, or the generic app icon. Looked up
    /// by bundle, so it stays after the app quits.
    func icon(_ bundle: String?, size: CGFloat) -> NSImage {
        var icon = NSWorkspace.shared.icon(for: .applicationBundle)
        if let bundle {
            if let cached = icons[bundle] {
                icon = cached
            } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
                icon = NSWorkspace.shared.icon(forFile: url.path)
                icons[bundle] = icon
            }
        }
        // Sized on a copy: the cached image is shared by every size.
        let sized = icon.copy() as! NSImage
        sized.size = NSSize(width: size, height: size)
        return sized
    }
}
