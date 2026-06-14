import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let engine = WallpaperEngine()
    private var statusMenu: StatusMenuController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusMenu = StatusMenuController(engine: engine)

        // Restore last wallpaper, if it still exists.
        if let url = Settings.shared.videoURL {
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

    // Allow opening a video by dropping it on the app icon / `open -a LiveWall video.mp4`.
    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first {
            engine.load(url: url)
        }
    }

    // Put the user's real desktop picture back if the menu-bar effect was running.
    func applicationWillTerminate(_ notification: Notification) {
        engine.prepareForTermination()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
