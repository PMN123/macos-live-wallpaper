// LiveWallWallpaper — LiveWall's Video Library as the host exports it, and the report
// of what each desktop plays.
//
// The host writes library.json and the clones and stills in library/ while system
// wallpaper mode is on, and posts com.praniil.livewall.wallpaper.library. Each library
// video is a tile in System Settings (SettingsProvider); a surface whose tile is a
// library video plays that clone (SharedChoice.resolve). The extension writes
// playing.json for the host's menu and Library window. Confined to Lifecycle.queue.

import Foundation
import LiveWallShared
import notify

@available(macOS 26.0, *)
final class LibraryStore {
    static let shared = LibraryStore()

    /// The entries whose clone is readable, in library order.
    private(set) var library = SharedLibrary()
    /// library/ inside the shared directory SharedStateStore reads.
    private(set) var directory = SharedWallpaper.libraryDirectory(in: SharedWallpaper.defaultDirectory())
    /// Entry id → its still's file stamp (modification time and size).
    private var thumbnailStamps: [String: String] = [:]
    private var token: Int32 = NOTIFY_TOKEN_INVALID
    private var started = false

    private init() {}

    /// Register for the host's library notification and load library.json. Call after
    /// SharedStateStore.start (it decides the directory). Lifecycle queue.
    func start() {
        dispatchPrecondition(condition: .onQueue(Lifecycle.queue))
        guard !started else { return }
        started = true
        let status = notify_register_dispatch(SharedWallpaper.Notification.library, &token, Lifecycle.queue) { _ in
            LibraryStore.shared.refresh(reason: "library notification")
        }
        if status != NOTIFY_STATUS_OK {
            extensionError("[Library] notify registration failed (\(status))")
        }
        _ = reload()
        extensionLog("[Library] \(library.videos.count) video(s) in \(directory.path)")
    }

    /// Re-read and apply: swap the surfaces whose video changed, refresh the tiles.
    /// Lifecycle queue.
    func refresh(reason: String) {
        dispatchPrecondition(condition: .onQueue(Lifecycle.queue))
        guard reload() else { return }
        extensionLog("[Library] \(reason): \(library.videos.count) video(s)")
        if SurfaceRegistry.shared.refreshVideos() {
            SettingsPush.invalidateSnapshots()
        }
        SettingsPush.scheduleRefresh()
        Liveness.shared.recompute()
    }

    /// The video for a surface whose tile is `choice` (see SharedChoice.resolve).
    func resolve(choice: String) -> SharedVideoResolution {
        SharedChoice.resolve(choice: choice, library: library, libraryDirectory: directory,
                             currentVideo: SharedStateStore.shared.videoURL,
                             isReadable: { FileManager.default.isReadableFile(atPath: $0.path) })
    }

    func thumbnailURL(for entry: SharedLibraryEntry) -> URL? {
        entry.thumbnailURL(inLibrary: directory)
    }

    /// Identifies an entry's still (id + file stamp) for the tile cache; nil without one.
    func thumbnailKey(for entry: SharedLibraryEntry) -> String? {
        thumbnailStamps[entry.id].map { "lib-\(entry.id)-\($0)" }
    }

    /// Read library.json; returns whether anything a tile or surface depends on changed.
    private func reload() -> Bool {
        dispatchPrecondition(condition: .onQueue(Lifecycle.queue))
        let base = SharedStateStore.shared.directory
        let nextDirectory = SharedWallpaper.libraryDirectory(in: base)
        let fm = FileManager.default
        var next = SharedLibrary()
        if let data = fm.contents(atPath: base.appendingPathComponent(SharedWallpaper.libraryFileName).path) {
            do {
                next = try SharedLibrary.decode(data)
            } catch {
                extensionError("[Library] library.json unreadable (\(error.localizedDescription)) — keeping the previous library")
                next = library
            }
        }
        next.videos = next.videos.filter { entry in
            guard let url = entry.videoURL(inLibrary: nextDirectory) else { return false }
            return fm.isReadableFile(atPath: url.path)
        }
        var stamps: [String: String] = [:]
        for entry in next.videos {
            guard let url = entry.thumbnailURL(inLibrary: nextDirectory),
                  let attributes = try? fm.attributesOfItem(atPath: url.path) else { continue }
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            stamps[entry.id] = "\(Int(modified * 1_000))-\(size)"
        }
        let changed = next != library || stamps != thumbnailStamps || nextDirectory != directory
        library = next
        thumbnailStamps = stamps
        directory = nextDirectory
        return changed
    }
}

/// Writes playing.json: the tile and video of each desktop LiveWall is the selected
/// wallpaper of (SurfaceRegistry.playingSurfaces), whenever that changes, then posts the
/// playing notification. A process that never had a desktop leaves the file alone, so it
/// cannot clobber the report of another extension process. Lifecycle queue.
@available(macOS 26.0, *)
final class PlayingReport {
    static let shared = PlayingReport()

    private var last: [SharedPlayingSurface]?
    private var hasReported = false
    private var failureLogged = false

    private init() {}

    func update() {
        dispatchPrecondition(condition: .onQueue(Lifecycle.queue))
        let surfaces = SurfaceRegistry.shared.playingSurfaces()
        guard surfaces != last else { return }
        guard hasReported || !surfaces.isEmpty else {
            last = surfaces
            return
        }
        let directory = SharedStateStore.shared.directory
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let url = directory.appendingPathComponent(SharedWallpaper.playingFileName, isDirectory: false)
        do {
            try SharedPlayingSurface.encode(surfaces).write(to: url, options: .atomic)
        } catch {
            if !failureLogged {
                failureLogged = true
                extensionError("[Playing] could not write \(url.lastPathComponent): \(error.localizedDescription)")
            }
            return
        }
        last = surfaces
        hasReported = true
        notify_post(SharedWallpaper.Notification.playing)
        let summary = surfaces.map { "display \($0.display): \($0.choice == SharedChoice.current ? "current" : String($0.choice.prefix(8))) → \($0.videoName ?? "none")" }
        extensionLog("[Playing] \(summary.isEmpty ? "no desktop" : summary.joined(separator: ", "))")
    }
}
