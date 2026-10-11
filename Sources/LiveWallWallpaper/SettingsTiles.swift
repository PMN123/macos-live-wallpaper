// LiveWallWallpaper — the tiles of the LiveWall group as they are now, with their
// thumbnails copied into the extension container.
//
// Adapted from Phosphene (https://github.com/kageroumado/phosphene), MIT License, © 2026 kageroumado
// Source: PhospheneExtension/SettingsProvider.swift at commit db03edf. See THIRD_PARTY_NOTICES.md.

import Foundation
import LiveWallShared

/// The provider id the tiles are published under.
var settingsProviderBundleID: String {
    Bundle.main.bundleIdentifier ?? SharedWallpaper.extensionBundleID
}

/// The tiles for the current state.json and library.json, thumbnails in place. Nil only
/// when not even the Current Video tile's thumbnail can be produced. Lifecycle queue.
@available(macOS 26.0, *)
func currentTileSpecs() -> [TileSpec]? {
    dispatchPrecondition(condition: .onQueue(Lifecycle.queue))
    let store = SharedStateStore.shared
    guard let current = TileThumbnail.url(key: store.thumbnailKey, source: store.thumbnailURL) else {
        return nil
    }
    let library = LibraryStore.shared
    return makeTileSpecs(currentThumbnail: current, library: library.library.videos) { entry in
        TileThumbnail.url(key: library.thumbnailKey(for: entry), source: library.thumbnailURL(for: entry)) ?? current
    }
}

/// Build the settings view models and remap them to WallpaperSettingsViewModelsXPC.
/// Lifecycle queue (tile thumbnails may be copied).
@available(macOS 26.0, *)
func buildSettingsViewModelsXPC() -> AnyObject? {
    guard let tiles = currentTileSpecs() else {
        extensionError("  [Settings] could not produce the tile thumbnail")
        return nil
    }
    return makeSettingsViewModelsXPC(bundleID: settingsProviderBundleID, tiles: tiles)
}

/// Tile thumbnails live in the extension container's Documents directory, which
/// WallpaperAgent and the Settings pane are known to read (M1). Each is a copy of one of
/// the host's stills (thumbnail.png for Current Video, library/<UUID>.png for a library
/// video) named after a key that includes the still's file stamp, so a new still gets a
/// new URL and the agent's cached view model cannot keep showing the old one.
///
/// Serving tiles never deletes older thumbnails: the agent's cache and other
/// connections may still point at them. They are removed only after a push has sent
/// every live connection the current set (SettingsPush).
@available(macOS 26.0, *)
enum TileThumbnail {
    private static let prefix = "livewall-tile-"
    private static let defaultName = "livewall-tile-default.png"
    /// Left behind by milestone M1.
    private static let legacyNames = ["livewall-m1-tile.png"]

    private static var documents: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents", isDirectory: true)
    }

    /// The thumbnail to serve for a still identified by `key` at `source`: a copy in the
    /// container, or the generated art when there is no still (nil key) or it cannot be
    /// read. Lifecycle queue.
    static func url(key: String?, source: URL?) -> URL? {
        let fm = FileManager.default
        let docs = documents
        do {
            try fm.createDirectory(at: docs, withIntermediateDirectories: true)
        } catch {
            extensionError("  [Tile] could not create \(docs.path): \(error.localizedDescription)")
            return nil
        }

        if let key, let source {
            let url = docs.appendingPathComponent("\(prefix)\(sanitized(key)).png")
            if fm.fileExists(atPath: url.path) {
                return url
            }
            // Re-encoded rather than copied byte for byte: only a decodable image
            // reaches the agent.
            if let image = loadImage(at: source, maxPixelSize: 640) {
                if writePNGAtomically(image, to: url) {
                    return url
                }
                extensionError("  [Tile] could not write \(url.lastPathComponent)")
            }
        }
        let url = docs.appendingPathComponent(defaultName)
        if fm.fileExists(atPath: url.path) {
            return url
        }
        if let art = FallbackArt.image(width: 480, height: 270), writePNGAtomically(art, to: url) {
            return url
        }
        return nil
    }

    /// Delete every tile thumbnail but `keep` (and the default art). Lifecycle queue.
    static func removeStale(keeping keep: Set<String>) {
        let fm = FileManager.default
        let docs = documents
        guard let names = try? fm.contentsOfDirectory(atPath: docs.path) else { return }
        for name in names where !keep.contains(name) && name != defaultName
            && ((name.hasPrefix(prefix) && name.hasSuffix(".png")) || legacyNames.contains(name)) {
            try? fm.removeItem(at: docs.appendingPathComponent(name))
        }
    }

    private static func sanitized(_ key: String) -> String {
        String(key.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? Character($0) : "_" })
    }
}
