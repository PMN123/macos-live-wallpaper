// LiveWallShared — the contract between LiveWall (the host app) and its system
// wallpaper extension (LiveWallWallpaper.appex, macOS 26+).
//
// The host owns a shared directory, ~/Library/Application Support/LiveWall/Wallpaper/:
//   state.json       what to play (SharedWallpaperState), written atomically by the host
//   <UUID>.<ext>     the current video, an APFS clone of the user's file
//   thumbnail.png    a still of the current video for the System Settings tile
//   library.json     LiveWall's Video Library (SharedLibrary), written atomically by the
//                    host: one System Settings tile per entry
//   library/         the library's videos (<UUID>.<ext>, APFS clones) and their stills
//                    (<same UUID>.png); every name comes from library.json
//   playing.json     written atomically by the extension: what each desktop plays
//                    ([SharedPlayingSurface])
//   extension.log    the extension's own log (plus extension.1.log after rotation)
// After each write of state.json the host posts `Notification.state`; after each write
// of library.json, `Notification.library`; the extension posts `Notification.playing`
// after each write of playing.json.
//
// Tiles: the "current" tile (choice configuration "current") plays whatever state.json
// names, as before. Each library tile's configuration is its entry's `id`, a UUID the
// host keeps per library entry, so a re-export keeps the tile. A surface whose entry is
// gone or unreadable plays the current video instead (SharedChoice.resolve). Scaling and
// the user's Pause come from state.json for every surface.
//
// The extension reports whether
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
    public static let libraryFileName = "library.json"
    /// Subdirectory holding the library's clones and stills.
    public static let libraryDirectoryName = "library"
    public static let playingFileName = "playing.json"

    /// `directory`/library/.
    public static func libraryDirectory(in directory: URL) -> URL {
        directory.appendingPathComponent(libraryDirectoryName, isDirectory: true)
    }

    /// Darwin notification names (notify(3)).
    public enum Notification {
        /// Host → extension: state.json (or the files it names) changed.
        public static let state = "com.praniil.livewall.wallpaper.state"
        /// Host → extension: library.json (or the files it names) changed.
        public static let library = "com.praniil.livewall.wallpaper.library"
        /// Extension → host: playing.json changed.
        public static let playing = "com.praniil.livewall.wallpaper.playing"
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
    /// host with the same video does not re-clone it. The extension uses only its file
    /// name, for the video's title in playing.json.
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

// MARK: - Video Library

/// One video of LiveWall's Video Library, as exported for the extension.
public struct SharedLibraryEntry: Codable, Equatable {
    /// Stable per library entry (a UUID string); the tile's choice configuration.
    public var id: String
    /// The clone inside library/, `<UUID>.<ext>`. A new clone (the source changed) gets a
    /// new name, so surfaces playing the old one switch over.
    public var file: String
    /// Display title (SharedVideoNames.displayName).
    public var name: String
    /// The still inside library/, `<UUID of file>.png`; nil when none could be made.
    public var thumbnail: String?
    /// The source file's modification date (unix seconds) when it was cloned.
    public var modified: Double
    /// Host bookkeeping: the path the clone was made from. The extension ignores it.
    public var source: String?

    public init(id: String, file: String, name: String, thumbnail: String? = nil,
                modified: Double = 0, source: String? = nil) {
        self.id = id
        self.file = file
        self.name = name
        self.thumbnail = thumbnail
        self.modified = modified
        self.source = source
    }

    /// The entry's names are what the host writes: a UUID id, a managed video file name
    /// and a plain thumbnail file name. Anything else is dropped on decode.
    public var isWellFormed: Bool {
        UUID(uuidString: id) != nil
            && SharedWallpaper.isManagedVideoFileName(file)
            && (thumbnail.map { SharedWallpaper.isManagedVideoFileName($0) && $0.hasSuffix(".png") } ?? true)
    }

    public func videoURL(inLibrary libraryDirectory: URL) -> URL? {
        guard SharedWallpaper.isManagedVideoFileName(file) else { return nil }
        return libraryDirectory.appendingPathComponent(file, isDirectory: false)
    }

    public func thumbnailURL(inLibrary libraryDirectory: URL) -> URL? {
        guard let thumbnail, SharedWallpaper.isManagedVideoFileName(thumbnail) else { return nil }
        return libraryDirectory.appendingPathComponent(thumbnail, isDirectory: false)
    }
}

/// library.json. Written atomically by the host while system wallpaper mode is on; while
/// it is off, only to drop videos removed from LiveWall's library.
public struct SharedLibrary: Codable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    /// In the order of LiveWall's Video Library.
    public var videos: [SharedLibraryEntry]

    public init(version: Int = SharedLibrary.currentVersion, videos: [SharedLibraryEntry] = []) {
        self.version = version
        self.videos = videos
    }

    private enum CodingKeys: String, CodingKey {
        case version, videos
    }

    /// Lenient: an unreadable or malformed entry (unsafe names, a non-UUID id, a repeated
    /// id) is dropped rather than failing the whole file.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? Self.currentVersion
        let raw = (try? c.decodeIfPresent([Lenient<SharedLibraryEntry>].self, forKey: .videos)) ?? []
        var seen = Set<String>()
        videos = raw.compactMap(\.value).filter { $0.isWellFormed && seen.insert($0.id).inserted }
    }

    public func entry(id: String) -> SharedLibraryEntry? {
        videos.first { $0.id == id }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> SharedLibrary {
        try JSONDecoder().decode(SharedLibrary.self, from: data)
    }
}

/// Decodes to nil instead of throwing.
private struct Lenient<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

// MARK: - What the system wallpaper plays

/// One desktop surface LiveWall is the selected wallpaper of, as the extension reports
/// it in playing.json.
public struct SharedPlayingSurface: Codable, Hashable, Comparable {
    /// The display's CGDirectDisplayID (0 when the agent did not say).
    public var display: UInt32
    /// The tile in effect there: a library entry id, or "current" for the Current Video
    /// tile and for a tile whose library video is gone or unreadable (it plays the
    /// current video, SharedChoice.resolve). Hosts treat an id they do not know as
    /// "current" too.
    public var choice: String
    /// Title of the video shown there; nil when there is none.
    public var videoName: String?

    public init(display: UInt32, choice: String, videoName: String?) {
        self.display = display
        self.choice = choice
        self.videoName = videoName
    }

    /// The library entry id this desktop plays, or nil when it follows LiveWall's current
    /// video: the Current Video tile, or an id `libraryIDs` (the host's library) no
    /// longer has.
    public func fixedTileID(libraryIDs: Set<String>) -> String? {
        libraryIDs.contains(choice) ? choice : nil
    }

    public static func < (a: SharedPlayingSurface, b: SharedPlayingSurface) -> Bool {
        if a.display != b.display { return a.display < b.display }
        if a.choice != b.choice { return a.choice < b.choice }
        return (a.videoName ?? "") < (b.videoName ?? "")
    }

    public static func encode(_ surfaces: [SharedPlayingSurface]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(surfaces)
    }

    /// Lenient: malformed elements are dropped.
    public static func decode(_ data: Data) -> [SharedPlayingSurface] {
        ((try? JSONDecoder().decode([Lenient<SharedPlayingSurface>].self, from: data)) ?? []).compactMap(\.value)
    }
}

// MARK: - Choosing a surface's video

/// What one surface plays.
public struct SharedVideoResolution: Equatable {
    /// The file to play; nil shows the fallback still.
    public var url: URL?
    /// The library entry played; nil when the surface plays the current video.
    public var entry: SharedLibraryEntry?
    /// The surface's tile names a library entry that is gone or unreadable, so it plays
    /// the current video instead.
    public var fellBack: Bool

    public init(url: URL?, entry: SharedLibraryEntry? = nil, fellBack: Bool = false) {
        self.url = url
        self.entry = entry
        self.fellBack = fellBack
    }
}

public enum SharedChoice {
    /// Configuration of the tile that plays whatever LiveWall's menu picked.
    public static let current = "current"

    /// A tile's choice configuration as a string: "current" when absent, empty or not a
    /// plausible id.
    public static func normalized(_ configuration: String?) -> String {
        guard let configuration, !configuration.isEmpty, configuration.count <= 64,
              configuration.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F }) else { return current }
        return configuration
    }

    /// The video for a surface whose tile is `choice`: "current" plays `currentVideo`
    /// (state.json's clone, already checked readable); a library id plays that entry's
    /// clone. An unknown id, or an entry whose clone is not readable, falls back to
    /// `currentVideo`, and with none of that the surface shows the fallback still.
    public static func resolve(choice: String?, library: SharedLibrary, libraryDirectory: URL,
                               currentVideo: URL?, isReadable: (URL) -> Bool) -> SharedVideoResolution {
        let choice = normalized(choice)
        guard choice != current else { return SharedVideoResolution(url: currentVideo) }
        if let entry = library.entry(id: choice), let url = entry.videoURL(inLibrary: libraryDirectory), isReadable(url) {
            return SharedVideoResolution(url: url, entry: entry)
        }
        return SharedVideoResolution(url: currentVideo, fellBack: true)
    }

    /// The tile a surface reports in playing.json: its own, or "current" when its library
    /// video is gone or unreadable and it plays the current video instead.
    public static func inEffect(choice: String, video: SharedVideoResolution) -> String {
        video.fellBack ? current : normalized(choice)
    }
}

// MARK: - Display names

public enum SharedVideoNames {
    /// Download-site tags that wallpaper files often end with ("-moewalls-com").
    private static let siteTags = ["moewalls", "motionbgs", "wallpaperwaifu", "mylivewallpapers"]

    /// Short words left lowercase inside a title ("Gojo vs Sukuna", "Across the Spider Verse").
    private static let minorWords: Set<String> = ["a", "an", "and", "at", "for", "in", "of", "on", "the", "to", "vs", "with"]

    /// A title for a video file: the name without its extension, without a trailing
    /// download-site tag and without noise tokens (long random ids, long numbers),
    /// dashes and underscores as spaces. Words are capitalised, short letter+digit
    /// codes are uppercased ("gt3" → "GT3", "4k" → "4K"), and minor words stay
    /// lowercase after the first word. Falls back to the bare name.
    public static func displayName(forFileName fileName: String) -> String {
        let base = (fileName as NSString).deletingPathExtension
        var words = base.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " }).map(String.init)
        // "…-moewalls-com", "…_moewalls", "…-moewalls.com"
        func isTag(_ word: String) -> Bool {
            let word = word.lowercased()
            return siteTags.contains(word) || siteTags.contains { word == "\($0).com" }
        }
        if words.count > 2, words[words.count - 1].lowercased() == "com", isTag(words[words.count - 2]) {
            words.removeLast(2)
        } else if words.count > 1, isTag(words[words.count - 1]) {
            words.removeLast()
        }
        // Download ids ("S74xpMHCNRoHCZ3") and long numbers ("131941") say nothing.
        func isNoise(_ word: String) -> Bool {
            let hasDigit = word.contains(where: \.isNumber), hasLetter = word.contains(where: \.isLetter)
            if hasDigit && !hasLetter { return word.count >= 5 }
            return hasDigit && hasLetter && word.count >= 10
        }
        let kept = words.filter { !isNoise($0) }
        if !kept.isEmpty { words = kept }
        let title = words.enumerated().map { index, word -> String in
            let lower = word.lowercased()
            if index > 0, minorWords.contains(lower) { return lower }
            if word.count <= 5, word.contains(where: \.isNumber), word.contains(where: \.isLetter) { return word.uppercased() }
            return word.prefix(1).uppercased() + word.dropFirst()
        }.joined(separator: " ")
        return title.isEmpty ? (base.isEmpty ? fileName : base) : title
    }
}
