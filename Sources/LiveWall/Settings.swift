import Foundation
import AVFoundation

/// UserDefaults-backed app settings.
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    private enum Key {
        static let videoPath = "videoPath"
        static let recents = "recentVideos"
        static let library = "videoLibrary"
        static let muted = "muted"
        static let pauseWhenHidden = "pauseWhenHidden"
        static let pauseOnLowPower = "pauseOnLowPower"
        static let menuBarWallpaper = "menuBarWallpaper"
        static let gravity = "videoGravity"
    }

    private init() {
        d.register(defaults: [
            Key.muted: true,
            Key.pauseWhenHidden: true,
            Key.pauseOnLowPower: true,
            Key.menuBarWallpaper: true,
            Key.gravity: AVLayerVideoGravity.resizeAspectFill.rawValue,
        ])
    }

    var videoURL: URL? {
        get { d.string(forKey: Key.videoPath).map { URL(fileURLWithPath: $0) } }
        set { d.set(newValue?.path, forKey: Key.videoPath) }
    }

    var recents: [URL] {
        get { (d.stringArray(forKey: Key.recents) ?? []).map { URL(fileURLWithPath: $0) } }
        set { d.set(newValue.map(\.path), forKey: Key.recents) }
    }

    func addRecent(_ url: URL) {
        var list = recents.filter { $0.path != url.path }
        list.insert(url, at: 0)
        recents = Array(list.prefix(5))
    }

    /// The user-curated set of videos shown in the drag-and-drop Library window.
    var library: [URL] {
        get { (d.stringArray(forKey: Key.library) ?? []).map { URL(fileURLWithPath: $0) } }
        set { d.set(newValue.map(\.path), forKey: Key.library) }
    }

    /// Append videos to the library, preserving order and skipping duplicates.
    func addToLibrary(_ urls: [URL]) {
        var list = library
        let existing = Set(list.map(\.path))
        for url in urls where !existing.contains(url.path) {
            list.append(url)
        }
        library = list
    }

    func removeFromLibrary(_ url: URL) {
        library = library.filter { $0.path != url.path }
    }

    /// When on, live video frames are fed to the system desktop picture so the
    /// menu bar samples them — making the bar a continuation of the wallpaper.
    /// When off (or on quit) LiveWall leaves a static still of the video instead.
    var menuBarWallpaper: Bool {
        get { d.bool(forKey: Key.menuBarWallpaper) }
        set { d.set(newValue, forKey: Key.menuBarWallpaper) }
    }

    var muted: Bool {
        get { d.bool(forKey: Key.muted) }
        set { d.set(newValue, forKey: Key.muted) }
    }

    var pauseWhenHidden: Bool {
        get { d.bool(forKey: Key.pauseWhenHidden) }
        set { d.set(newValue, forKey: Key.pauseWhenHidden) }
    }

    var pauseOnLowPower: Bool {
        get { d.bool(forKey: Key.pauseOnLowPower) }
        set { d.set(newValue, forKey: Key.pauseOnLowPower) }
    }

    var gravity: AVLayerVideoGravity {
        get { AVLayerVideoGravity(rawValue: d.string(forKey: Key.gravity) ?? "") }
        set { d.set(newValue.rawValue, forKey: Key.gravity) }
    }
}
