// LiveWallShared — the contract between LiveWall (the host app) and its system
// wallpaper extension (LiveWallWallpaper.appex, macOS 26+).
//
// The host owns a shared directory, ~/Library/Application Support/LiveWall/Wallpaper/:
//   state.json       what to play (SharedWallpaperState), written atomically by the host
//   <UUID>.<ext>     the current video, an APFS clone of the user's file
//   thumbnail.png    a still of the current video for the System Settings tile
//   extension.log    the extension's own log (plus extension.1.log after rotation)
// After each write the host posts `Notification.state`. The extension reports whether
// LiveWall is the selected desktop wallpaper with `active` / `inactive` (whether or not
// macOS is drawing it right now: locked, asleep and screen-saver states do not count
// as inactive), and keeps a heartbeat (unix time) in the notify state of `active`. It
// counts as active only while it can show what the host published; a selected surface
// with nothing to show posts `request` instead. `ping` asks it to report again.
//
// The only pause the host publishes is the user's own (reason "user"). macOS decides
// when the system wallpaper is drawn; LiveWall adds no automatic pauses to it.
//
// The host writes nothing here until the user turns system wallpaper mode on (its
// menu, or picking the LiveWall tile).
//
// The extension is sandboxed; its temporary exception
// (Resources/LiveWallWallpaper.entitlements) grants exactly `homeRelativePath`.

import Foundation

public enum SharedWallpaper {
    /// Bundle identifier of the wallpaper extension.
    public static let extensionBundleID = "com.praniil.livewall.wallpaper"

    /// The shared directory, relative to the user's real home directory.
    public static let homeRelativePath = "Library/Application Support/LiveWall/Wallpaper"

    public static let stateFileName = "state.json"
    public static let thumbnailFileName = "thumbnail.png"
    public static let logFileName = "extension.log"
    public static let rotatedLogFileName = "extension.1.log"

    /// Darwin notification names (notify(3)).
    public enum Notification {
        /// Host → extension: state.json (or the files it names) changed.
        public static let state = "com.praniil.livewall.wallpaper.state"
        /// Extension → host: LiveWall is the selected wallpaper of a desktop. Its notify
        /// state holds the latest heartbeat as unix seconds.
        public static let active = "com.praniil.livewall.wallpaper.active"
        /// Extension → host: no desktop has LiveWall selected any more.
        public static let inactive = "com.praniil.livewall.wallpaper.inactive"
        /// Host → extension: report your status again.
        public static let ping = "com.praniil.livewall.wallpaper.ping"
        /// Extension → host: a desktop has LiveWall selected but nothing LiveWall
        /// published can be shown (no readable state.json or video yet), so it reports
        /// inactive.
        /// The user picked the LiveWall tile: the host turns system wallpaper mode on
        /// and publishes.
        public static let request = "com.praniil.livewall.wallpaper.request"
    }

    /// How often the extension refreshes its heartbeat while active.
    public static let heartbeatInterval: TimeInterval = 5
    /// A heartbeat older than this means the extension is gone (crashed, killed, or
    /// deselected without a clean `inactive`).
    public static let heartbeatStaleAfter: TimeInterval = 20

    /// The user's real home directory. Inside the App Sandbox `NSHomeDirectory()` is
    /// the container, so read the password database instead.
    public static func realHomeDirectory() -> URL {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            let path = String(cString: dir)
            if !path.isEmpty {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    /// ~/Library/Application Support/LiveWall/Wallpaper/ under the real home.
    public static func defaultDirectory() -> URL {
        realHomeDirectory().appendingPathComponent(homeRelativePath, isDirectory: true)
    }

    /// A plain single path component: no separators, no `.`/`..`, no control
    /// characters. Every file name read from state.json must pass this before use.
    public static func isSafeFileName(_ name: String) -> Bool {
        if name.isEmpty || name == "." || name == ".." || name.hasPrefix(".") { return false }
        if name.contains("/") || name.contains("\\") || name.contains(":") { return false }
        if name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) { return false }
        return (name as NSString).lastPathComponent == name
    }

    /// Whether `name` has the shape the host gives video files: `<UUID>.<ext>`. Only
    /// such files are ever deleted by the host's cleanup.
    public static func isManagedVideoFileName(_ name: String) -> Bool {
        guard isSafeFileName(name) else { return false }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        return !ext.isEmpty && ext.count <= 8 && UUID(uuidString: base) != nil
    }
}

/// Scaling mode, as the host's menu offers it.
public enum SharedGravity: String, Codable, Equatable {
    case fill
    case fit
    case stretch
}

/// The extension's instructions. Written atomically by the host as state.json.
public struct SharedWallpaperState: Codable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    /// Identifier of the current video (a fresh UUID per published file); nil when the
    /// user removed the wallpaper in LiveWall.
    public var videoID: String?
    /// File name of the current video inside the shared directory, `<videoID>.<ext>`.
    public var file: String?
    public var gravity: SharedGravity
    /// Whether the host wants playback held. `pauseReasons` says why.
    public var paused: Bool
    /// Machine-readable reasons. The host publishes only "user" (Pause in its menu), and
    /// the extension honours only that.
    public var pauseReasons: [String]
    /// Host bookkeeping: the path the current file was cloned from, so relaunching the
    /// host with the same video does not re-clone it. The extension ignores it.
    public var source: String?

    public init(version: Int = SharedWallpaperState.currentVersion,
                videoID: String? = nil,
                file: String? = nil,
                gravity: SharedGravity = .fill,
                paused: Bool = false,
                pauseReasons: [String] = [],
                source: String? = nil) {
        self.version = version
        self.videoID = videoID
        self.file = file
        self.gravity = gravity
        self.paused = paused
        self.pauseReasons = pauseReasons
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case version, videoID, file, gravity, paused, pauseReasons, source
    }

    /// Lenient decoding: a missing or unknown field falls back to its default, so a
    /// host/extension version skew degrades instead of failing outright.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? Self.currentVersion
        videoID = try? c.decodeIfPresent(String.self, forKey: .videoID)
        file = try? c.decodeIfPresent(String.self, forKey: .file)
        gravity = (try? c.decodeIfPresent(SharedGravity.self, forKey: .gravity)) ?? .fill
        paused = (try? c.decodeIfPresent(Bool.self, forKey: .paused)) ?? false
        pauseReasons = (try? c.decodeIfPresent([String].self, forKey: .pauseReasons)) ?? []
        source = try? c.decodeIfPresent(String.self, forKey: .source)
    }

    /// The video's URL inside `directory`, or nil when there is none or the stored name
    /// is not a safe plain file name.
    public func videoURL(in directory: URL) -> URL? {
        guard let file, SharedWallpaper.isSafeFileName(file) else { return nil }
        return directory.appendingPathComponent(file, isDirectory: false)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> SharedWallpaperState {
        try JSONDecoder().decode(SharedWallpaperState.self, from: data)
    }
}
