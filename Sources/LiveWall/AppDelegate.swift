import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let engine = WallpaperEngine()
    private var statusMenu: StatusMenuController!
    /// macOS 26+: hands playback to the system wallpaper extension when it is selected.
    private var systemWallpaper: SystemWallpaperBridge?
    /// A video opened before launch finished (dropped on the icon, `open -a`): AppKit
    /// delivers it before applicationDidFinishLaunching, which loads it once the bridge
    /// has started, instead of the saved video.
    private var didFinishLaunching = false
    private var launchURL: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if #available(macOS 26.0, *) {
            systemWallpaper = SystemWallpaperBridge(engine: engine)
        }
        statusMenu = StatusMenuController(engine: engine, systemWallpaper: systemWallpaper)
        // Before restoring the video: if the extension is already drawing the desktop,
        // the engine stands down first instead of opening a window it would close.
        systemWallpaper?.start()
        didFinishLaunching = true

        if let url = launchURL {
            launchURL = nil
            engine.load(url: url)
        } else if let url = Settings.shared.videoURL {
            // Restore last wallpaper, if it still exists.
            if FileManager.default.fileExists(atPath: url.path) {
                engine.load(url: url)
            } else {
                Settings.shared.videoURL = nil
            }
        } else {
            // No saved video — open the library so first-time users aren't stuck
            // behind an invisible menu-bar-only UI.
            statusMenu.showLibrary()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        systemWallpaper?.applicationWillTerminate()
    }

    // Allow opening a video by dropping it on the app icon / `open -a LiveWall video.mp4`.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        guard didFinishLaunching else {
            launchURL = url
            return
        }
        engine.load(url: url)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
