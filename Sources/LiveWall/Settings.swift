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
        /// Library path → stable entry id (a UUID string), the System Settings tile's
        /// configuration in system wallpaper mode.
        static let libraryIDs = "videoLibraryIDs"
        static let muted = "muted"
        static let pauseWhenHidden = "pauseWhenHidden"
        static let pauseOnLowPower = "pauseOnLowPower"
        static let gravity = "videoGravity"
        static let systemWallpaper = "systemWallpaperEnabled"
        /// Left behind by the removed menu-bar wallpaper feature.
        static let legacy = ["menuBarWallpaper", "savedDesktopImages"]
    }

    private init() {
        d.register(defaults: [
            Key.muted: true,
            Key.pauseWhenHidden: true,
            Key.pauseOnLowPower: true,
            Key.gravity: AVLayerVideoGravity.resizeAspectFill.rawValue,
        ])
        Key.legacy.forEach(d.removeObject(forKey:))
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

    /// Posted (main thread) after the Video Library gained or lost videos.
    static let libraryDidChange = Notification.Name("com.praniil.livewall.libraryDidChange")

    /// The user-curated set of videos shown in the drag-and-drop Library window.
    var library: [URL] {
        get { (d.stringArray(forKey: Key.library) ?? []).map { URL(fileURLWithPath: $0) } }
        set { d.set(newValue.map(\.path), forKey: Key.library) }
    }

    /// Append videos to the library, preserving order and skipping duplicates. Returns
    /// how many were new.
    @discardableResult
    func addToLibrary(_ urls: [URL]) -> Int {
        var list = library
        var existing = Set(list.map(\.path))
        var added = 0
        for url in urls where existing.insert(url.path).inserted {
            list.append(url)
            added += 1
        }
        guard added > 0 else { return 0 }
        library = list
        _ = libraryEntries // assign ids to the new entries
        NotificationCenter.default.post(name: Self.libraryDidChange, object: nil)
        return added
    }

    func removeFromLibrary(_ url: URL) {
        let list = library
        guard list.contains(where: { $0.path == url.path }) else { return }
        library = list.filter { $0.path != url.path }
        var ids = d.dictionary(forKey: Key.libraryIDs) as? [String: String] ?? [:]
        ids[url.path] = nil
        d.set(ids, forKey: Key.libraryIDs)
        NotificationCenter.default.post(name: Self.libraryDidChange, object: nil)
    }

    /// The library with each video's stable id, assigning (and saving) ids for videos
    /// that have none yet. Ids of videos no longer in the library are dropped.
    var libraryEntries: [(id: String, url: URL)] {
        let list = library
        let stored = d.dictionary(forKey: Key.libraryIDs) as? [String: String] ?? [:]
        var ids: [String: String] = [:]
        var used = Set<String>()
        let entries: [(id: String, url: URL)] = list.map { url in
            var id = stored[url.path].flatMap { UUID(uuidString: $0)?.uuidString } ?? UUID().uuidString
            if !used.insert(id).inserted {
                id = UUID().uuidString
                used.insert(id)
            }
            ids[url.path] = id
            return (id, url)
        }
        if ids != stored {
            d.set(ids, forKey: Key.libraryIDs)
        }
        return entries
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

    /// macOS 26+: system wallpaper mode is in use, so LiveWall shares its video with the
    /// wallpaper extension. Off until the user chooses "Use as System Wallpaper…" or
    /// picks the LiveWall tile; off again once LiveWall resumes its own window because
    /// another wallpaper was picked.
    var systemWallpaperEnabled: Bool {
        get { d.bool(forKey: Key.systemWallpaper) }
        set { d.set(newValue, forKey: Key.systemWallpaper) }
    }
}
