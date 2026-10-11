// LiveWallWallpaper — the System Settings > Wallpaper section this provider contributes.
//
// Adapted from Phosphene (https://github.com/kageroumado/phosphene), MIT License, © 2026 kageroumado
// Source: PhospheneExtension/SettingsProvider.swift at commit db03edf. See THIRD_PARTY_NOTICES.md.
//
// One group ("LiveWall"). Its first tile, "Current Video", has the choice configuration
// "current" (UTF-8 bytes): it always means "whatever LiveWall is playing", chosen in the
// LiveWall app, as the single "LiveWall" tile did before. Then one tile per video of
// LiveWall's Video Library (library.json), whose configuration is the entry's id: that
// tile keeps its video whatever LiveWall's menu picks. Thumbnails are copies of the
// host's stills in the extension container (SettingsTiles.swift), or generated art.
// Never serve an empty group: on macOS 26.6 the agent caches this response on disk and
// reuses it on every Settings launch, so a cached empty group hides the section until a
// reinstall or OS update (Phosphene issue #27). The Current Video tile is always there.
//
// This file is the pure part (no container or shared-directory access), so it can be
// checked against the real WallpaperSettingsViewModelsXPC on its own.

import Foundation
import LiveWallShared

enum LiveWallChoice {
    static let currentID = SharedChoice.current
    static let groupID = "livewall"
    static let contextMenuInfoID = "livewall-info"
    static let libraryMenuInfoID = "livewall-library-info"
}

/// One tile of the LiveWall group.
struct TileSpec: Equatable {
    /// The choice configuration: "current" or a library entry id.
    var configuration: String
    /// The label under the tile, and the only name the pane shows for it.
    var title: String
    /// The choice descriptor's name. The macOS 26.6 agent type does not keep it (checked
    /// by archiving the real WallpaperSettingsViewModelsXPC); sent for older shapes.
    var choiceName: String
    var description: String
    var thumbnailURL: URL
    var contextMenuTitle: String

    /// Changes whenever the agent's copy of this tile would be out of date.
    var signature: String {
        "\(configuration)|\(title)|\(thumbnailURL.lastPathComponent)"
    }
}

/// The tiles: Current Video first, then each library video in library order.
func makeTileSpecs(currentThumbnail: URL, library: [SharedLibraryEntry],
                   thumbnail: (SharedLibraryEntry) -> URL) -> [TileSpec] {
    var tiles = [TileSpec(
        configuration: LiveWallChoice.currentID,
        title: "Current Video",
        choiceName: "LiveWall \u{2014} Current Video",
        description: "The video playing in LiveWall",
        thumbnailURL: currentThumbnail,
        contextMenuTitle: "Choose the video in LiveWall\u{2019}s menu"
    )]
    var seen: Set<String> = [LiveWallChoice.currentID]
    for entry in library where seen.insert(entry.id).inserted {
        tiles.append(TileSpec(
            configuration: entry.id,
            title: entry.name,
            choiceName: entry.name,
            description: "From LiveWall\u{2019}s Video Library",
            thumbnailURL: thumbnail(entry),
            contextMenuTitle: "Add or remove videos in LiveWall\u{2019}s Video Library"
        ))
    }
    return tiles
}

/// The view models for a provider id and its tiles, remapped to
/// WallpaperSettingsViewModelsXPC. Nil when there are no tiles (never an empty group).
func makeSettingsViewModelsXPC(bundleID: String, tiles: [TileSpec]) -> AnyObject? {
    guard let viewModels = makeSettingsViewModels(bundleID: bundleID, tiles: tiles) else { return nil }
    return remapToRealXPC(viewModels)
}

func makeSettingsViewModels(bundleID: String, tiles: [TileSpec]) -> SettingsViewModels? {
    guard !tiles.isEmpty else { return nil } // never serve an empty group
    let provider = ChoiceProviderID(rawValue: bundleID)

    let items = tiles.enumerated().map { index, tile -> SettingsItem in
        let menuID = tile.configuration == LiveWallChoice.currentID
            ? LiveWallChoice.contextMenuInfoID : LiveWallChoice.libraryMenuInfoID
        let menu = ContextMenu(items: [
            ContextMenuItem(id: ContextMenuItemID(id: menuID), localizedTitle: tile.contextMenuTitle, isDestructive: false),
        ])
        let choiceID = ChoiceID(
            id: tile.configuration,
            descriptor: ChoiceIDDescriptor(
                provider: provider,
                identifier: tile.configuration,
                files: [],
                configuration: Data(tile.configuration.utf8)
            )
        )
        return SettingsItem(
            id: choiceID,
            localizedName: tile.title,
            thumbnail: .image(url: tile.thumbnailURL),
            choice: ChoiceDescriptor(
                id: choiceID,
                provider: provider,
                identifier: tile.configuration,
                name: tile.choiceName,
                localizedDescription: tile.description,
                thumbnail: .image(url: tile.thumbnailURL),
                isDownloaded: true,
                options: []
            ),
            contentBadge: .video,
            showInTopLevel: true,
            sortOrder: index,
            // Not `.removable`: the pane force-unwraps a removable item's choiceRequest,
            // which a provider tile does not have (Phosphene). Videos are removed in
            // LiveWall's Video Library instead.
            disposability: .none,
            contextMenu: menu
        )
    }

    let groupMenu = ContextMenu(items: [
        ContextMenuItem(
            id: ContextMenuItemID(id: LiveWallChoice.libraryMenuInfoID),
            localizedTitle: "Add or remove videos in LiveWall\u{2019}s Video Library",
            isDestructive: false
        ),
    ])
    let group = SettingsGroup(
        id: GroupID(id: LiveWallChoice.groupID),
        items: items,
        localizedName: "LiveWall",
        disposability: .none,
        sortOrder: -100,
        sortID: GroupSortID(id: "com.apple.wallpaper.aerials"),
        allChoiceID: nil,
        shouldHideItemLabels: false,
        contextMenu: groupMenu,
        thumbnail: nil
    )

    let viewModel = SettingsViewModel(groups: [group], refreshPolicy: .default, isModificationDisabled: false)
    // Desktop picker only. A surface in idle presentation holds its frame (see
    // SurfaceAgentState.shouldPlay) because idle means another screen saver covers the
    // wallpaper, and the agent's requests carry nothing that tells LiveWall's own screen
    // saver apart from someone else's. Offered in the Screen Saver picker too (as
    // Phosphene does, telling the two apart by reading the wallpaper store), LiveWall as
    // the screen saver would show a frozen frame.
    return SettingsViewModels(desktop: viewModel, screenSaver: nil)
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
