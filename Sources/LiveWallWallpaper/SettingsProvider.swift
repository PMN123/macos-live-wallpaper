// LiveWallWallpaper — the System Settings > Wallpaper section this provider contributes.
//
// Adapted from Phosphene (https://github.com/kageroumado/phosphene), MIT License, © 2026 kageroumado
// Source: PhospheneExtension/SettingsProvider.swift at commit db03edf. See THIRD_PARTY_NOTICES.md.
//
// One group ("LiveWall") with one tile ("LiveWall") whose choice configuration is the
// UTF-8 bytes "current": the tile always means "whatever LiveWall is playing", and the
// video itself is chosen in the LiveWall app. Its thumbnail is a copy of the host's
// thumbnail.png (or generated art when there is none).
// Never serve an empty group: on macOS 26.6 the agent caches this response on disk and
// reuses it on every Settings launch, so a cached empty group hides the section until a
// reinstall or OS update (Phosphene issue #27).

import Foundation
import LiveWallShared

enum LiveWallChoice {
    static let currentID = "current"
    static let groupID = "livewall"
    static let contextMenuInfoID = "livewall-info"
}

/// Build the settings view models and remap them to WallpaperSettingsViewModelsXPC.
/// Lifecycle queue (the tile thumbnail may be copied). `thumbnailURL` defaults to the
/// current tile.
@available(macOS 26.0, *)
func buildSettingsViewModelsXPC(thumbnailURL: URL? = nil) -> AnyObject? {
    let bundleID = Bundle.main.bundleIdentifier ?? SharedWallpaper.extensionBundleID
    guard let thumbnailURL = thumbnailURL ?? TileThumbnail.currentURL() else {
        extensionError("  [Settings] could not produce the tile thumbnail")
        return nil
    }
    return makeSettingsViewModelsXPC(bundleID: bundleID, thumbnailURL: thumbnailURL)
}

/// The view models for a given provider id and tile thumbnail (separate so the
/// archive/remap path can be exercised without touching the container).
func makeSettingsViewModelsXPC(bundleID: String, thumbnailURL: URL) -> AnyObject? {
    let menu = ContextMenu(items: [
        ContextMenuItem(
            id: ContextMenuItemID(id: LiveWallChoice.contextMenuInfoID),
            localizedTitle: "Choose the video in LiveWall\u{2019}s menu",
            isDestructive: false
        ),
    ])

    let choiceID = ChoiceID(
        id: LiveWallChoice.currentID,
        descriptor: ChoiceIDDescriptor(
            provider: ChoiceProviderID(rawValue: bundleID),
            identifier: LiveWallChoice.currentID,
            files: [],
            configuration: Data(LiveWallChoice.currentID.utf8)
        )
    )

    let item = SettingsItem(
        id: choiceID,
        localizedName: "LiveWall",
        thumbnail: .image(url: thumbnailURL),
        choice: ChoiceDescriptor(
            id: choiceID,
            provider: ChoiceProviderID(rawValue: bundleID),
            identifier: LiveWallChoice.currentID,
            name: "LiveWall",
            localizedDescription: "The video playing in LiveWall",
            thumbnail: .image(url: thumbnailURL),
            isDownloaded: true,
            options: []
        ),
        contentBadge: .video,
        showInTopLevel: true,
        sortOrder: 0,
        // Not `.removable`: the pane force-unwraps a removable item's choiceRequest,
        // which a provider tile does not have (Phosphene).
        disposability: .none,
        contextMenu: menu
    )

    let group = SettingsGroup(
        id: GroupID(id: LiveWallChoice.groupID),
        items: [item],
        localizedName: "LiveWall",
        disposability: .none,
        sortOrder: -100,
        sortID: GroupSortID(id: "com.apple.wallpaper.aerials"),
        allChoiceID: nil,
        shouldHideItemLabels: false,
        contextMenu: menu,
        thumbnail: nil
    )
    guard !group.items.isEmpty else { return nil } // never serve an empty group

    let viewModel = SettingsViewModel(groups: [group], refreshPolicy: .default, isModificationDisabled: false)
    // Desktop picker only. A surface in idle presentation holds its frame (see
    // SurfaceAgentState.shouldPlay) because idle means another screen saver covers the
    // wallpaper, and the agent's requests carry nothing that tells LiveWall's own screen
    // saver apart from someone else's. Offered in the Screen Saver picker too (as
    // Phosphene does, telling the two apart by reading the wallpaper store), LiveWall as
    // the screen saver would show a frozen frame.
    return remapToRealXPC(SettingsViewModels(desktop: viewModel, screenSaver: nil))
}

/// The tile thumbnail lives in the extension container's Documents directory, which
/// WallpaperAgent and the Settings pane are known to read (M1). It is a copy of the
/// host's thumbnail.png named after the video and file stamp, so a new video gets a new
/// URL and the agent's cached view model cannot keep showing the old still.
///
/// Serving a tile never deletes older ones: the agent's cache and other connections may
/// still point at them. They are removed only after a push has sent every live
/// connection the current one (SettingsPush).
@available(macOS 26.0, *)
enum TileThumbnail {
    private static let prefix = "livewall-tile-"
    private static let defaultName = "livewall-tile-default.png"
    /// Left behind by milestone M1.
    private static let legacyNames = ["livewall-m1-tile.png"]

    /// The URL to serve now. Lifecycle queue.
    static func currentURL() -> URL? {
        let fm = FileManager.default
        let docs = fm.homeDirectoryForCurrentUser.appendingPathComponent("Documents", isDirectory: true)
        do {
            try fm.createDirectory(at: docs, withIntermediateDirectories: true)
        } catch {
            extensionError("  [Tile] could not create \(docs.path): \(error.localizedDescription)")
            return nil
        }

        let store = SharedStateStore.shared
        var chosen: URL?
        if let key = store.thumbnailKey {
            let url = docs.appendingPathComponent("\(prefix)\(sanitized(key)).png")
            if fm.fileExists(atPath: url.path) {
                chosen = url
            } else if let image = loadImage(at: store.thumbnailURL, maxPixelSize: 640) {
                // Re-encoded rather than copied byte for byte: only a decodable image
                // reaches the agent.
                if writePNGAtomically(image, to: url) {
                    chosen = url
                } else {
                    extensionError("  [Tile] could not write \(url.lastPathComponent)")
                }
            }
        }
        if chosen == nil {
            let url = docs.appendingPathComponent(defaultName)
            if fm.fileExists(atPath: url.path) {
                chosen = url
            } else if let art = FallbackArt.image(width: 480, height: 270), writePNGAtomically(art, to: url) {
                chosen = url
            }
        }
        return chosen
    }

    /// Delete every tile but `keep` (and the default art). Lifecycle queue.
    static func removeStale(keeping keep: String) {
        let docs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents", isDirectory: true)
        removeStale(in: docs, keeping: keep)
    }

    private static func sanitized(_ key: String) -> String {
        String(key.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? Character($0) : "_" })
    }

    private static func removeStale(in docs: URL, keeping keep: String) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: docs.path) else { return }
        for name in names where name != keep && name != defaultName
            && ((name.hasPrefix(prefix) && name.hasSuffix(".png")) || legacyNames.contains(name)) {
            try? fm.removeItem(at: docs.appendingPathComponent(name))
        }
    }
}

/// Archive via LiveWallShimViewModelsXPC and decode the archive as the real private
/// WallpaperSettingsViewModelsXPC by remapping the class name.
///
/// Secure coding cannot be required: the point is a deliberate class substitution,
/// which secure coding forbids. It is safe because the archive never leaves this
/// function — produced and consumed in-process from values just constructed — so
/// there is no untrusted input. The decoded object goes straight back to the agent.
private func remapToRealXPC(_ viewModels: SettingsViewModels) -> AnyObject? {
    let shim = LiveWallShimViewModelsXPC(value: viewModels)

    let data: Data
    do {
        data = try NSKeyedArchiver.archivedData(withRootObject: shim, requiringSecureCoding: false)
    } catch {
        extensionError("  [Remap] archive failed: \(error)")
        return nil
    }

    guard let realClass = objc_getClass("WallpaperSettingsViewModelsXPC") as? AnyClass else {
        extensionError("  [Remap] WallpaperSettingsViewModelsXPC class not found")
        return nil
    }

    guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else {
        extensionError("  [Remap] failed to create unarchiver")
        return nil
    }
    unarchiver.requiresSecureCoding = false
    unarchiver.decodingFailurePolicy = .setErrorAndReturn
    unarchiver.setClass(realClass, forClassName: LiveWallShimViewModelsXPC.archivedClassName)

    let result = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey)
    if let error = unarchiver.error {
        extensionError("  [Remap] unarchive error: \(error)")
    }
    unarchiver.finishDecoding()

    guard let result else {
        extensionError("  [Remap] decoded result is nil")
        return nil
    }
    return result as AnyObject
}
