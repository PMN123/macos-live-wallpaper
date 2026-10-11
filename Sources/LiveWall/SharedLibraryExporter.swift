import Foundation
import LiveWallShared
import notify

/// One Video Library entry to export: its stable id and the user's file.
struct LibraryExportItem: Equatable {
    var id: String
    var source: URL
}

/// Exports LiveWall's Video Library for the wallpaper extension (see LiveWallShared), so
/// System Settings shows one tile per video: each video as an APFS clone in library/
/// (`<UUID>.<ext>`), a still beside it (`<same UUID>.png`, at most 640 px), and
/// library.json listing them, posting the library notification after each write.
///
/// - Incremental: a video is cloned once, and again only when its file changed (size or
///   modification date); a new clone gets a new name. library.json is rewritten as
///   clones and stills land (at most every `checkpointInterval`), so a large library
///   fills in progressively. A newer export supersedes a running one between videos.
/// - A video whose file has gone (moved, deleted, its volume unmounted) keeps its
///   existing clone and tile until it is removed from the library.
/// - Only files this exporter names are deleted: clones and stills in library/ that
///   library.json no longer lists (after `cleanupDelay`, by when the extension has moved
///   on), and its own temporary files. The user's videos are only ever read.
/// - While system wallpaper mode is off (SystemWallpaperBridge) only removals are
///   applied (`removalsOnly`): a video removed from the library loses its tile and, after
///   cleanup, its clone, but nothing is cloned or made, and nothing is written unless an
///   earlier export wrote library.json. `cancel()` stops a running export between
///   videos when the mode turns off.
///
/// Work runs on a private serial queue. The directory, notification name and queue are
/// parameters so tests can use a scratch directory and a private notification name.
final class SharedLibraryExporter {
    let directory: URL
    let notification: String
    let cleanupDelay: TimeInterval
    let checkpointInterval: TimeInterval

    private let queue: DispatchQueue
    private let log: (String) -> Void
    private let lock = NSLock()
    /// The latest request; nil after `cancel()`.
    private var desired: Request?
    private var generation = 0

    private struct Request {
        var items: [LibraryExportItem]
        var removalsOnly: Bool
    }

    // Confined to `queue`.
    private var written: SharedLibrary?
    private var loadedFromDisk = false
    private var cleanupWork: DispatchWorkItem?
    /// Clones whose still could not be made this session; not retried on every export.
    private var failedStills = Set<String>()

    init(directory: URL = SharedWallpaper.defaultDirectory(),
         notification: String = SharedWallpaper.Notification.library,
         cleanupDelay: TimeInterval = 10,
         checkpointInterval: TimeInterval = 1.5,
         queue: DispatchQueue = DispatchQueue(label: "com.praniil.livewall.shared-library", qos: .utility),
         log: @escaping (String) -> Void) {
        self.directory = directory
        self.notification = notification
        self.cleanupDelay = cleanupDelay
        self.checkpointInterval = checkpointInterval
        self.queue = queue
        self.log = log
    }

    var libraryDirectory: URL { SharedWallpaper.libraryDirectory(in: directory) }
    var libraryURL: URL { directory.appendingPathComponent(SharedWallpaper.libraryFileName, isDirectory: false) }

    /// Export in the background. `completion` runs on the exporter's queue once this (or
    /// a newer) export has finished or handed over to a newer one. `removalsOnly` (system
    /// wallpaper mode is off): only drop the entries `items` no longer lists from an
    /// existing library.json; clone nothing, make no stills.
    func export(_ items: [LibraryExportItem], removalsOnly: Bool = false, completion: (() -> Void)? = nil) {
        request(items, removalsOnly: removalsOnly)
        queue.async { [self] in
            reconcile()
            completion?()
        }
    }

    /// Export and wait (tests).
    func exportSync(_ items: [LibraryExportItem], removalsOnly: Bool = false) {
        request(items, removalsOnly: removalsOnly)
        queue.sync { reconcile() }
    }

    /// Stop a running export after the video in progress (system wallpaper mode turned
    /// off) and drop any queued one. What was already cloned is still listed, so a
    /// later export reuses it. Thread-safe.
    func cancel() {
        lock.lock()
        desired = nil
        generation += 1
        lock.unlock()
    }

    private func request(_ items: [LibraryExportItem], removalsOnly: Bool) {
        lock.lock()
        desired = Request(items: items, removalsOnly: removalsOnly)
        generation += 1
        lock.unlock()
    }

    /// The library last written (tests).
    func currentLibrary() -> SharedLibrary? {
        queue.sync { written }
    }

    /// Run any pending cleanup now (tests).
    func cleanupNow() {
        queue.sync {
            cleanupWork?.cancel()
            cleanupWork = nil
            removeUnreferencedFiles()
        }
    }

    // MARK: - Reconcile (queue)

    private struct Work {
        var index: Int
        var item: LibraryExportItem
        /// The path as the library lists it (the entry's `source`).
        var listed: String
        /// The file to read: `listed` with symbolic links resolved.
        var source: URL
        var modified: Double
        /// Clone the file (new, or changed since its clone); otherwise only the still.
        var clone: Bool
    }

    private func reconcile() {
        lock.lock()
        let request = desired
        let pass = generation
        lock.unlock()
        guard let request else { return }
        let want = request.items

        let fm = FileManager.default
        if !request.removalsOnly {
            do {
                try fm.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
            } catch {
                log("shared library directory unavailable: \(error.localizedDescription)")
                return
            }
        }
        if !loadedFromDisk {
            loadedFromDisk = true
            written = fm.contents(atPath: libraryURL.path).flatMap { try? SharedLibrary.decode($0) }
            removeUnreferencedFiles()
        }
        if request.removalsOnly {
            // Never the first write: only an export with the mode on creates library.json.
            guard let written, fm.fileExists(atPath: libraryURL.path) else { return }
            let kept = Set(want.map(\.id))
            writeLibrary(written.videos.filter { kept.contains($0.id) })
            return
        }

        let previous = Dictionary((written?.videos ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var slots = [SharedLibraryEntry?](repeating: nil, count: want.count)
        var work: [Work] = []
        for (index, item) in want.enumerated() {
            // Matched by the path exactly as the library lists it: standardizing or
            // resolving links is not stable for a file that has gone (Foundation drops a
            // leading /private only for paths that exist).
            let listed = item.source.path
            let source = item.source.resolvingSymlinksInPath()
            let attributes = Self.fileAttributes(source)
            let name = SharedVideoNames.displayName(forFileName: item.source.lastPathComponent)
            if var old = previous[item.id], old.source == listed,
               let cloneURL = old.videoURL(inLibrary: libraryDirectory),
               let clone = Self.fileAttributes(cloneURL) {
                old.name = name
                if let thumbnail = old.thumbnailURL(inLibrary: libraryDirectory), !fm.fileExists(atPath: thumbnail.path) {
                    old.thumbnail = nil
                }
                slots[index] = old // keeps its tile while a newer clone is made
                if let attributes, attributes.size != clone.size || abs(attributes.modified - old.modified) > 0.001 {
                    work.append(Work(index: index, item: item, listed: listed, source: source,
                                     modified: attributes.modified, clone: true))
                } else if old.thumbnail == nil, !failedStills.contains(old.file) {
                    work.append(Work(index: index, item: item, listed: listed, source: source,
                                     modified: old.modified, clone: false))
                }
            } else if let attributes {
                work.append(Work(index: index, item: item, listed: listed, source: source,
                                 modified: attributes.modified, clone: true))
            }
            // Otherwise the file is gone and there is no clone of it: no tile.
        }

        // Removals and renames take effect at once.
        var lastWrite = Date()
        write(slots)

        var cloned = 0
        var stills = 0
        for job in work {
            if isSuperseded(pass) {
                log(isCancelled ? "library export stopped: system wallpaper mode is off"
                                : "library export handed over to a newer one")
                break
            }
            var entry: SharedLibraryEntry
            if job.clone {
                guard let file = cloneVideo(from: job.source) else { continue }
                cloned += 1
                entry = SharedLibraryEntry(
                    id: job.item.id, file: file,
                    name: SharedVideoNames.displayName(forFileName: job.item.source.lastPathComponent),
                    thumbnail: nil, modified: job.modified, source: job.listed)
            } else if let existing = slots[job.index] {
                entry = existing
            } else {
                continue
            }
            let still = Self.stillName(for: entry.file)
            if VideoStill.writePNG(for: libraryDirectory.appendingPathComponent(entry.file),
                                   to: libraryDirectory.appendingPathComponent(still)) {
                entry.thumbnail = still
                stills += 1
            } else {
                failedStills.insert(entry.file)
                log("could not make a still for \(job.item.source.lastPathComponent)")
            }
            slots[job.index] = entry
            if Date().timeIntervalSince(lastWrite) >= checkpointInterval {
                write(slots)
                lastWrite = Date()
            }
        }
        write(slots)
        if cloned > 0 || stills > 0 {
            log("library exported: \(slots.compactMap { $0 }.count) of \(want.count) videos (\(cloned) cloned, \(stills) stills)")
        }
    }

    private func isSuperseded(_ pass: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation != pass
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return desired == nil
    }

    /// Write library.json if it changed, post the notification and schedule cleanup.
    private func write(_ slots: [SharedLibraryEntry?]) {
        writeLibrary(slots.compactMap { $0 })
    }

    private func writeLibrary(_ videos: [SharedLibraryEntry]) {
        let library = SharedLibrary(videos: videos)
        if library == written, FileManager.default.fileExists(atPath: libraryURL.path) { return }
        do {
            try library.encoded().write(to: libraryURL, options: .atomic)
        } catch {
            log("could not write \(SharedWallpaper.libraryFileName): \(error.localizedDescription)")
            return
        }
        written = library
        notify_post(notification)
        scheduleCleanup()
    }

    /// `<UUID>.<ext>` → `<UUID>.png`.
    static func stillName(for file: String) -> String {
        (file as NSString).deletingPathExtension + ".png"
    }

    private static func fileAttributes(_ url: URL) -> (size: Int64, modified: Double)? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
              values.isRegularFile == true else { return nil }
        return (Int64(values.fileSize ?? 0), values.contentModificationDate?.timeIntervalSince1970 ?? 0)
    }

    /// Copy `source` into library/ as `<UUID>.<ext>`: an APFS clone (no extra disk space,
    /// near-instant) on the same volume, a real copy across volumes. It lands under a
    /// hidden temporary name first, so the final name only ever refers to a complete file.
    private func cloneVideo(from source: URL) -> String? {
        let fm = FileManager.default
        var ext = source.pathExtension.lowercased()
        if ext.isEmpty || ext.count > 8 || !ext.allSatisfy({ $0.isLetter || $0.isNumber }) || ext == "png" {
            ext = "mov"
        }
        let file = "\(UUID().uuidString).\(ext)"
        let partial = libraryDirectory.appendingPathComponent(".\(file).partial")
        do {
            try? fm.removeItem(at: partial)
            try fm.copyItem(at: source, to: partial)
            try fm.moveItem(at: partial, to: libraryDirectory.appendingPathComponent(file))
            return file
        } catch {
            try? fm.removeItem(at: partial)
            log("could not copy \(source.lastPathComponent) into the shared library: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Cleanup (queue)

    private func scheduleCleanup() {
        cleanupWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.cleanupWork = nil
            self.removeUnreferencedFiles()
        }
        cleanupWork = work
        queue.asyncAfter(deadline: .now() + cleanupDelay, execute: work)
    }

    /// Delete clones and stills in library/ that the last written library.json does not
    /// list, and leftover temporary files. Only names of the exporter's own shape
    /// (`<UUID>.<ext>`, hidden `.partial` files) are considered; nothing else is touched.
    private func removeUnreferencedFiles() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: libraryDirectory.path) else { return }
        var keep = Set<String>()
        for entry in written?.videos ?? [] {
            keep.insert(entry.file)
            if let thumbnail = entry.thumbnail { keep.insert(thumbnail) }
        }
        for name in names {
            let isPartial = name.hasPrefix(".") && name.hasSuffix(".partial")
            let isStale = SharedWallpaper.isManagedVideoFileName(name) && !keep.contains(name)
            guard isPartial || isStale else { continue }
            do {
                try fm.removeItem(at: libraryDirectory.appendingPathComponent(name))
            } catch {
                log("could not remove library/\(name): \(error.localizedDescription)")
            }
        }
    }
}
