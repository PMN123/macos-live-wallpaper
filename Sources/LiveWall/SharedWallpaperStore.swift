import AVFoundation
import Foundation
import ImageIO
import LiveWallShared
import notify

/// What LiveWall wants the system wallpaper extension to play.
struct WallpaperPublication: Equatable {
    var videoURL: URL?
    var gravity: SharedGravity
    var paused: Bool
    var pauseReasons: [String]
}

/// Writes the shared directory the wallpaper extension reads (see LiveWallShared):
/// the video as an APFS clone named `<UUID>.<ext>`, state.json, and a thumbnail.png
/// still for the System Settings tile, posting the state notification after state.json
/// and again once a new video's still is written.
///
/// Work runs on a private serial queue; a newer publication supersedes pending ones.
/// The directory, notification name and queue are parameters so tests can use a
/// scratch directory, a private notification name and a queue they can hold up.
///
/// Used only while system wallpaper mode is on (SystemWallpaperBridge): a clone across
/// volumes is a real copy, and each new video costs a thumbnail decode.
final class SharedWallpaperStore {
    let directory: URL
    let stateNotification: String
    /// Superseded video files are deleted this long after a switch, by when the
    /// extension (which re-reads state.json on the notification) has moved on.
    let cleanupDelay: TimeInterval

    private let queue: DispatchQueue
    private let log: (String) -> Void
    private let lock = NSLock()
    private var desired: WallpaperPublication?
    /// Held around every write of state.json: the queue's reconcile and the termination
    /// patch (main thread) never interleave a read-modify-write.
    private let stateWriteLock = NSLock()

    // Confined to `queue`.
    private var current: SharedWallpaperState?
    private var loadedFromDisk = false
    private var cleanupWork: DispatchWorkItem?

    init(directory: URL = SharedWallpaper.defaultDirectory(),
         stateNotification: String = SharedWallpaper.Notification.state,
         cleanupDelay: TimeInterval = 10,
         queue: DispatchQueue = DispatchQueue(label: "com.praniil.livewall.shared-wallpaper", qos: .utility),
         log: @escaping (String) -> Void) {
        self.directory = directory
        self.stateNotification = stateNotification
        self.cleanupDelay = cleanupDelay
        self.queue = queue
        self.log = log
    }

    var stateURL: URL { directory.appendingPathComponent(SharedWallpaper.stateFileName, isDirectory: false) }
    var thumbnailURL: URL { directory.appendingPathComponent(SharedWallpaper.thumbnailFileName, isDirectory: false) }

    /// Publish in the background. `completion` runs on the store's queue once this (or a
    /// newer) publication is on disk.
    func publish(_ publication: WallpaperPublication, completion: (() -> Void)? = nil) {
        lock.lock()
        desired = publication
        lock.unlock()
        queue.async { [self] in
            reconcile()
            completion?()
        }
    }

    /// Publish and wait (tests).
    func publishSync(_ publication: WallpaperPublication) {
        lock.lock()
        desired = publication
        lock.unlock()
        queue.sync { reconcile() }
    }

    /// App termination: put `publication`'s pause and scaling state on disk without
    /// waiting more than `timeout` behind a clone or a thumbnail decode. If the queue is
    /// still busy then, state.json's pause and scaling fields are patched in place; a
    /// busy reconcile that still gets to write takes the same fields from this
    /// publication (see reconcile). Returns whether the queue finished in time.
    @discardableResult
    func publishForTermination(_ publication: WallpaperPublication, timeout: TimeInterval = 1) -> Bool {
        lock.lock()
        desired = publication
        lock.unlock()
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in
            reconcile()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .success {
            return true
        }
        log("still busy at quit; writing the pause state into \(SharedWallpaper.stateFileName) directly")
        patchPauseState(publication)
        return false
    }

    /// The state last written, read on the store's queue (tests).
    func currentState() -> SharedWallpaperState? {
        queue.sync { current }
    }

    /// Run any pending cleanup now (tests).
    func cleanupNow() {
        queue.sync {
            cleanupWork?.cancel()
            cleanupWork = nil
            removeStaleFiles(keeping: current?.file)
        }
    }

    // MARK: - Reconcile (queue)

    private func reconcile() {
        lock.lock()
        let want = desired
        lock.unlock()
        guard let want else { return }

        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            log("shared wallpaper directory unavailable: \(error.localizedDescription)")
            return
        }
        if !loadedFromDisk {
            loadedFromDisk = true
            current = readStateFromDisk()
            removeStaleFiles(keeping: current?.file)
        }

        var next = current ?? SharedWallpaperState()
        next.version = SharedWallpaperState.currentVersion
        next.gravity = want.gravity
        next.paused = want.paused
        next.pauseReasons = want.pauseReasons

        var videoChanged = false
        /// A new clone whose still is written after state.json, so a video switch never
        /// waits on the frame decode (seconds when the hardware decoder is busy).
        var needsThumbnail: String?
        if let source = want.videoURL {
            let sourcePath = source.standardizedFileURL.path
            if !isCurrentClone(of: sourcePath, in: next) {
                if let file = cloneVideo(from: source) {
                    // Drop the old still first, so the tile never pairs a new video with it;
                    // until the new one lands the extension shows its generated art.
                    try? fm.removeItem(at: thumbnailURL)
                    next.videoID = (file as NSString).deletingPathExtension
                    next.file = file
                    next.source = sourcePath
                    videoChanged = true
                    needsThumbnail = file
                    log("published video \(source.lastPathComponent) as \(file)")
                } else if let file = next.file, !fm.fileExists(atPath: directory.appendingPathComponent(file).path) {
                    // The previous clone is gone too; say so rather than point at nothing.
                    next.videoID = nil
                    next.file = nil
                    next.source = nil
                    videoChanged = true
                    try? fm.removeItem(at: thumbnailURL)
                }
            }
        } else if next.file != nil || next.videoID != nil {
            next.videoID = nil
            next.file = nil
            next.source = nil
            videoChanged = true
            try? fm.removeItem(at: thumbnailURL)
            log("published: no video")
        }

        // Pause and scaling come from the newest publication, which may have arrived
        // while a clone was copying (app termination relies on this).
        lock.lock()
        let latest = desired ?? want
        lock.unlock()
        next.gravity = latest.gravity
        next.paused = latest.paused
        next.pauseReasons = latest.pauseReasons

        stateWriteLock.lock()
        if next == current, fm.fileExists(atPath: stateURL.path) {
            stateWriteLock.unlock()
            return
        }
        do {
            try next.encoded().write(to: stateURL, options: .atomic)
        } catch {
            stateWriteLock.unlock()
            log("could not write \(stateURL.lastPathComponent): \(error.localizedDescription)")
            return
        }
        current = next
        stateWriteLock.unlock()
        notify_post(stateNotification)
        if videoChanged {
            scheduleCleanup()
        }
        // Post again once the still is in place: the extension re-reads and updates the
        // Settings tile. (Newer publications wait on this queue, so `file` is current.)
        if let file = needsThumbnail, writeThumbnail(for: directory.appendingPathComponent(file)) {
            notify_post(stateNotification)
        }
    }

    /// Rewrite only the pause and scaling fields of the state on disk (termination).
    private func patchPauseState(_ publication: WallpaperPublication) {
        stateWriteLock.lock()
        defer { stateWriteLock.unlock() }
        guard let data = FileManager.default.contents(atPath: stateURL.path),
              var state = try? SharedWallpaperState.decode(data) else { return }
        state.gravity = publication.gravity
        state.paused = publication.paused
        state.pauseReasons = publication.pauseReasons
        do {
            try state.encoded().write(to: stateURL, options: .atomic)
        } catch {
            log("could not write \(stateURL.lastPathComponent): \(error.localizedDescription)")
            return
        }
        notify_post(stateNotification)
    }

    private func readStateFromDisk() -> SharedWallpaperState? {
        guard let data = FileManager.default.contents(atPath: stateURL.path) else { return nil }
        return try? SharedWallpaperState.decode(data)
    }

    /// Whether `state` already points at an intact clone of `sourcePath`.
    private func isCurrentClone(of sourcePath: String, in state: SharedWallpaperState) -> Bool {
        guard state.source == sourcePath, let url = state.videoURL(in: directory) else { return false }
        let fm = FileManager.default
        guard let cloneSize = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
              let sourceSize = (try? fm.attributesOfItem(atPath: sourcePath))?[.size] as? NSNumber else { return false }
        return cloneSize == sourceSize
    }

    /// Copy `source` into the directory as `<UUID>.<ext>`. On APFS `copyItem` makes a
    /// clone (no extra disk space, near-instant); across volumes it is a real copy. The
    /// copy lands under a hidden temporary name first, so the final name only ever
    /// refers to a complete file.
    private func cloneVideo(from source: URL) -> String? {
        let fm = FileManager.default
        var ext = source.pathExtension.lowercased()
        if ext.isEmpty || ext.count > 8 || !ext.allSatisfy({ $0.isLetter || $0.isNumber }) {
            ext = "mov"
        }
        let file = "\(UUID().uuidString).\(ext)"
        let partial = directory.appendingPathComponent(".\(file).partial")
        let destination = directory.appendingPathComponent(file)
        do {
            try? fm.removeItem(at: partial)
            try fm.copyItem(at: source, to: partial)
            try fm.moveItem(at: partial, to: destination)
            return file
        } catch {
            try? fm.removeItem(at: partial)
            log("could not copy \(source.lastPathComponent) into the shared directory: \(error.localizedDescription)")
            return nil
        }
    }

    /// A still at about 1 s, at most 640 px on its longest side, as thumbnail.png.
    @discardableResult
    private func writeThumbnail(for videoURL: URL) -> Bool {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        let tolerance = CMTime(value: 1, timescale: 2)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        var image = Self.generateImage(generator, at: CMTime(value: 1, timescale: 1))
        if image == nil {
            image = Self.generateImage(generator, at: .zero) // clips shorter than a second
        }
        guard let image else {
            try? FileManager.default.removeItem(at: thumbnailURL)
            log("could not make a thumbnail for \(videoURL.lastPathComponent)")
            return false
        }
        let partial = directory.appendingPathComponent(".\(SharedWallpaper.thumbnailFileName).partial")
        guard let destination = CGImageDestinationCreateWithURL(partial as CFURL, "public.png" as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), rename(partial.path, thumbnailURL.path) == 0 else {
            try? FileManager.default.removeItem(at: partial)
            log("could not write \(SharedWallpaper.thumbnailFileName)")
            return false
        }
        return true
    }

    private final class ImageBox {
        var image: CGImage?
    }

    private static func generateImage(_ generator: AVAssetImageGenerator, at time: CMTime) -> CGImage? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ImageBox()
        generator.generateCGImageAsynchronously(for: time) { image, _, _ in
            box.image = image
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 15) == .success else { return nil }
        return box.image
    }

    // MARK: - Cleanup (queue)

    private func scheduleCleanup() {
        cleanupWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.cleanupWork = nil
            self.removeStaleFiles(keeping: self.current?.file)
        }
        cleanupWork = work
        queue.asyncAfter(deadline: .now() + cleanupDelay, execute: work)
    }

    /// Delete video files LiveWall made (`<UUID>.<ext>`) other than `keep`, and leftover
    /// temporary files. Nothing else in the directory is ever touched.
    private func removeStaleFiles(keeping keep: String?) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names {
            let isPartial = name.hasPrefix(".") && name.hasSuffix(".partial")
            let isStaleVideo = SharedWallpaper.isManagedVideoFileName(name) && name != keep
            guard isPartial || isStaleVideo else { continue }
            do {
                try fm.removeItem(at: directory.appendingPathComponent(name))
            } catch {
                log("could not remove \(name): \(error.localizedDescription)")
            }
        }
    }
}
