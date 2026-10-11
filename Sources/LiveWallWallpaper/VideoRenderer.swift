// LiveWallWallpaper — plays the shared video into one hosted surface.
//
// Adapted from Phosphene (https://github.com/kageroumado/phosphene), MIT License, © 2026 kageroumado
// Source: PhospheneExtension/VideoRenderer.swift at commit db03edf. See THIRD_PARTY_NOTICES.md.
// Changes: no rate ramps, frame-rate variants or shuffle; the video can change or go
// away (fallback art) for the life of the layer; loop retiming lives in LoopRetimer;
// every decoder flush (video change, deep-pause wake, error recovery) waits for its
// completion before enqueuing; the track's rotation is applied to the layer.
//
// AVPlayerLayer renders nothing inside a remote CAContext, so each surface gets an
// AVSampleBufferDisplayLayer fed straight from AVAssetReader(outputSettings: nil):
// H.264/HEVC samples pass through compressed and the layer decodes them in hardware.
// Looping is gapless (the next reader is preloaded and its samples retimed). Pausing
// stops the control timebase; after 30 s paused the readers are released ("deep
// pause") and rebuilt where playback stopped.
//
// The display layer lives as long as its surface. A new AVSampleBufferDisplayLayer
// added to a context WallpaperAgent already hosts does not composite (Phosphene), so a
// video change is fed into the same layer after a decoder flush that keeps the old
// frame on screen until the new video's first frame replaces it.
//
// A flush is asynchronous and discards everything enqueued before its completion runs,
// and two overlapping flushes corrupt the renderer. So at most one is ever in flight
// (`flushInFlight`), nothing is enqueued until its completion, and a video change that
// arrives meanwhile is coalesced into one more restart.

import AVFoundation
import CoreMedia
import ObjectiveC
import QuartzCore

/// Call AVSampleBufferDisplayLayer's private `_setDisallowsVideoLayerDisplayCompositing:`
/// (a BOOL setter Apple's WallpaperExtensionKit sets on every display layer). Resolved
/// through the runtime and a no-op if it disappears. Stops the layer painting opaque
/// black before its first frame.
private func setDisallowsVideoLayerDisplayCompositing(_ layer: CALayer, _ flag: Bool) {
    let sel = NSSelectorFromString("_setDisallowsVideoLayerDisplayCompositing:")
    guard layer.responds(to: sel),
          let imp = class_getMethodImplementation(type(of: layer), sel) else { return }
    typealias SetBoolFn = @convention(c) (AnyObject, Selector, ObjCBool) -> Void
    unsafeBitCast(imp, to: SetBoolFn.self)(layer, sel, ObjCBool(flag))
}

/// The next sample buffer that carries media. With `outputSettings: nil` the reader
/// also emits zero-sample marker buffers: an empty one before the first frame, then a
/// drain marker and an end-of-media marker (kCMSampleBufferAttachmentKey_PermanentEmptyMedia)
/// after the last. Feeding those to the display layer would make the "first frame"
/// an empty marker and announce end of stream at every loop boundary, so they are
/// skipped; every real sample carries its own format description.
func copyNextMediaSample(from output: AVAssetReaderTrackOutput) -> CMSampleBuffer? {
    while let sample = output.copyNextSampleBuffer() {
        if CMSampleBufferGetNumSamples(sample) > 0 {
            return sample
        }
    }
    return nil
}

/// The layer transform that shows a track upright, from the track's preferred
/// transform: its rotation snapped to a quarter turn (mirroring is ignored). The
/// preferred transform is defined in the video's top-left-origin space, where a
/// positive angle turns clockwise; layers here are bottom-left-origin, where a positive
/// angle turns counterclockwise, so the angle changes sign.
func layerOrientation(forPreferredTransform t: CGAffineTransform) -> CGAffineTransform {
    let quarterTurns = Int((atan2(t.b, t.a) / (.pi / 2)).rounded())
    switch ((quarterTurns % 4) + 4) % 4 {
    case 1: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 0)  // 90° clockwise on screen
    case 2: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 0, ty: 0) // 180°
    case 3: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0)  // 90° counterclockwise
    default: return .identity
    }
}

@available(macOS 26.0, *)
final class VideoRenderer {
    private static let counterLock = NSLock()
    private static var counter = 0

    /// Process-wide id, so log lines can be attributed to one renderer.
    let debugID: Int
    let displayLayer: AVSampleBufferDisplayLayer
    let timebase: CMTimebase
    private let renderer: AVSampleBufferVideoRenderer
    private let queue: DispatchQueue

    /// How long a paused surface's clock runs after its first frame: a display layer
    /// whose clock stops at time 0 before it has shown a frame never shows one.
    private static let firstFrameRunway: TimeInterval = 0.25
    /// Paused this long, the readers and decoder state are released.
    private static let deepPauseDelay: TimeInterval = 30
    /// Consecutive decoder failures tolerated before the renderer gives up and holds
    /// the last frame (a corrupt file must not spin).
    private static let maxRecoveries = 3

    /// The display layer's geometry: the surface size (points) and the rotation that
    /// shows the current video upright. Set from the lifecycle queue (resize) and the
    /// renderer queue (video changes); the lock also serializes the layer updates.
    private let geometryLock = NSLock()
    private var surfaceSize: CGSize
    private var orientation: CGAffineTransform = .identity

    // Everything below is confined to `queue`.
    private var asset: AVURLAsset?
    private var videoTrack: AVAssetTrack?
    /// The layer orientation for `asset`, applied when its first frame is enqueued.
    private var assetOrientation: CGAffineTransform = .identity
    private var isRunning = true
    /// A video pipeline has run on this layer, so a change of video needs a flush.
    private var pipelineStarted = false
    private var showingFallback = false
    /// The logical play state; the timebase rate follows it.
    private var wantsPlay = false
    private var currentReader: AVAssetReader?
    private var currentOutput: AVAssetReaderTrackOutput?
    private var nextReader: AVAssetReader?
    private var nextOutput: AVAssetReaderTrackOutput?
    /// A decoder flush is in flight (see the header). A video change arriving meanwhile
    /// sets `restartPending`; a wake or a recovery needs nothing more, because the
    /// in-flight flush's completion rebuilds the pipeline anyway.
    private var flushInFlight = false
    private var restartPending = false
    private var retimer = LoopRetimer()
    private var deepPauseTimer: DispatchSourceTimer?
    /// Bumped to cancel a pending first-frame hold.
    private var holdGeneration = 0
    private var samplesThisPass = 0
    private var emptyPasses = 0
    private var recoveries = 0

    #if LIVEWALL_HARNESS
    /// Test hook: every sample handed to the display layer, in enqueue order.
    var onEnqueue: ((CMSampleBuffer) -> Void)?
    /// Test hook: a decoder flush was requested (true) or its completion runs (false),
    /// on the renderer's queue.
    var onFlush: ((Bool) -> Void)?
    /// Test hook: release the readers now, as the deep-pause timer would (while paused).
    func harnessEnterDeepPause() { queue.sync { enterDeepPause() } }
    /// Test hook: recover as after a decoder failure.
    func harnessRecover() { queue.async { [self] in recoverFromError() } }
    /// Test hook: whether the readers are released (deep pause).
    var harnessIsDeepPaused: Bool { queue.sync { currentReader == nil } }
    #endif

    /// Build the layer under `rootLayer` and show `seed` (if any) at once. Call inside
    /// the surface's acquire, before the reply.
    init?(rootLayer: CALayer, gravity: AVLayerVideoGravity, seed: CGImage?) {
        var tb: CMTimebase?
        guard CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
                                              sourceClock: CMClockGetHostTimeClock(),
                                              timebaseOut: &tb) == noErr,
              let tb else { return nil }
        Self.counterLock.lock()
        Self.counter += 1
        debugID = Self.counter
        Self.counterLock.unlock()

        timebase = tb
        displayLayer = AVSampleBufferDisplayLayer()
        renderer = displayLayer.sampleBufferRenderer
        queue = DispatchQueue(label: "com.praniil.livewall.wallpaper.renderer.\(debugID)", qos: .userInitiated)
        surfaceSize = rootLayer.bounds.size

        // Rate 0 until the first frame is enqueued, so it is not judged late.
        CMTimebaseSetTime(timebase, time: .zero)
        CMTimebaseSetRate(timebase, rate: 0)

        displayLayer.videoGravity = gravity
        displayLayer.contentsScale = rootLayer.contentsScale
        // Opaque: a non-opaque layer blends every frame against what's behind it and
        // visibly blinks while the compositor rebuilds it during a Space switch.
        displayLayer.isOpaque = true
        displayLayer.controlTimebase = timebase
        setDisallowsVideoLayerDisplayCompositing(displayLayer, true)

        // Install and seed in one action-free transaction (no implicit fade-in), then
        // flush: for a remote context only a flush pushes the tree to the render server.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateGeometry()
        rootLayer.addSublayer(displayLayer)
        if let seed, let still = makeStillSampleBuffer(from: seed) {
            setDisplayImmediately(still)
            renderer.enqueue(still)
        }
        CATransaction.commit()
        CATransaction.flush()
        traceLog("  [Renderer #\(debugID)] created (seed \(seed.map { "\($0.width)x\($0.height)" } ?? "none"))")
    }

    // MARK: - Control (any thread)

    /// Show `url`, or the fallback art for nil. `synchronously` runs up to the first
    /// enqueued frame before returning, so an acquire can reply onto a context that
    /// already holds the video.
    func load(_ url: URL?, synchronously: Bool) {
        if synchronously {
            queue.sync { switchVideo(to: url) }
        } else {
            queue.async { [self] in switchVideo(to: url) }
        }
    }

    func setPlaying(_ play: Bool) {
        queue.async { [self] in applyPlaying(play) }
    }

    func setGravity(_ gravity: AVLayerVideoGravity) {
        guard displayLayer.videoGravity != gravity else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.videoGravity = gravity
        CATransaction.commit()
        CATransaction.flush()
    }

    /// Re-frame the layer for a new destination geometry (points) and backing scale.
    func resize(to size: CGSize, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateGeometry(size: size)
        displayLayer.contentsScale = scale
        CATransaction.commit()
        CATransaction.flush()
    }

    /// Stop for good and detach the layer. Must not be called on the renderer's queue.
    func stop() {
        queue.sync {
            isRunning = false
            holdGeneration += 1
            cancelDeepPause()
            releaseReaders()
            CMTimebaseSetRate(timebase, rate: 0)
            traceLog("  [Renderer #\(debugID)] stopped")
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.removeFromSuperlayer()
        CATransaction.commit()
        CATransaction.flush()
    }

    /// The video being shown and the position in it, for snapshots.
    func currentFrameSource() -> (url: URL, time: CMTime)? {
        queue.sync {
            guard let asset else { return nil }
            return (asset.url, retimer.clipTime(forTimelineTime: CMTimebaseGetTime(timebase)))
        }
    }

    // MARK: - Geometry (any thread)

    /// Record a new surface size and/or orientation, then frame the display layer for
    /// both: centred on the surface, rotated, and for a quarter turn with its bounds
    /// swapped so the rotated layer still covers the surface. Call inside an
    /// action-free transaction; the caller flushes.
    private func updateGeometry(size: CGSize? = nil, orientation newOrientation: CGAffineTransform? = nil) {
        geometryLock.lock()
        defer { geometryLock.unlock() }
        if let size { surfaceSize = size }
        if let newOrientation { orientation = newOrientation }
        let quarterTurn = abs(orientation.b) > abs(orientation.a)
        // `frame` is undefined under a non-identity transform; set bounds and position.
        displayLayer.setAffineTransform(.identity)
        displayLayer.bounds = CGRect(origin: .zero, size: quarterTurn
            ? CGSize(width: surfaceSize.height, height: surfaceSize.width)
            : surfaceSize)
        displayLayer.position = CGPoint(x: surfaceSize.width / 2, y: surfaceSize.height / 2)
        displayLayer.setAffineTransform(orientation)
    }

    #if LIVEWALL_HARNESS
    /// Test hook: the transform and bounds currently applied to the display layer.
    var harnessGeometry: (transform: CGAffineTransform, bounds: CGRect) {
        geometryLock.lock()
        defer { geometryLock.unlock() }
        return (displayLayer.affineTransform(), displayLayer.bounds)
    }
    #endif

    // MARK: - Video changes (queue)

    private func switchVideo(to url: URL?) {
        guard isRunning else { return }
        guard let url else {
            guard asset != nil || !showingFallback else { return }
            asset = nil
            videoTrack = nil
            assetOrientation = .identity
            extensionLog("  [Renderer #\(debugID)] no video → fallback art")
            if pipelineStarted { restart() } else { showFallback() }
            return
        }
        if asset?.url == url { return }
        let newAsset = AVURLAsset(url: url)
        guard let track = Self.loadFirstVideoTrackBlocking(newAsset) else {
            extensionError("  [Renderer #\(debugID)] no readable video track in \(url.lastPathComponent)")
            if asset == nil, !showingFallback { showFallback() }
            return
        }
        asset = newAsset
        videoTrack = track
        assetOrientation = layerOrientation(forPreferredTransform: Self.loadPreferredTransformBlocking(track))
        recoveries = 0
        emptyPasses = 0
        let rotated = assetOrientation.isIdentity ? "" : " (shown turned \(Self.describe(assetOrientation)))"
        extensionLog("  [Renderer #\(debugID)] video → \(url.lastPathComponent)\(rotated)\(pipelineStarted ? " (in-place switch)" : "")")
        if pipelineStarted { restart() } else { beginPlayback() }
    }

    /// First video on this layer: no flush needed. Enqueue the first frame and push it
    /// to the render server before returning.
    private func beginPlayback() {
        guard let asset, let videoTrack, let (reader, output) = makeReader(asset, videoTrack) else {
            extensionError("  [Renderer #\(debugID)] could not create an asset reader")
            if !showingFallback { showFallback() }
            return
        }
        reader.startReading()
        pipelineStarted = true
        showingFallback = false
        retimer.reset()
        CMTimebaseSetTime(timebase, time: .zero)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateGeometry(orientation: assetOrientation)
        if let first = copyNextMediaSample(from: output) {
            retimer.record(first)
            samplesThisPass = 1
            enqueue(first)
        }
        CATransaction.commit()
        CATransaction.flush()
        currentReader = reader
        currentOutput = output
        startClock()
        prepareNextReader()
        feed()
    }

    /// Restart on the current `asset` (or the fallback art) from time 0 after an
    /// asynchronous decoder flush that keeps the displayed frame. Serialized: a restart
    /// requested during a flush coalesces into one more restart to the latest video.
    private func restart() {
        if flushInFlight {
            restartPending = true
            return
        }
        // Freeze the clock so frames of the new video are not judged late.
        CMTimebaseSetRate(timebase, rate: 0)
        holdGeneration += 1
        cancelDeepPause()
        releaseReaders()
        beginFlush(removingDisplayedImage: false) { [weak self] in self?.afterRestartFlush() }
    }

    private func afterRestartFlush() {
        guard isRunning else { return }
        guard let asset, let videoTrack else {
            showFallback()
            return
        }
        guard let (reader, output) = makeReader(asset, videoTrack) else {
            extensionError("  [Renderer #\(debugID)] could not create an asset reader for \(asset.url.lastPathComponent)")
            return
        }
        reader.startReading()
        currentReader = reader
        currentOutput = output
        retimer.reset()
        CMTimebaseSetTime(timebase, time: .zero)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateGeometry(orientation: assetOrientation)
        // DisplayImmediately: replaces the held frame as soon as it decodes, whatever
        // the clock is doing (a change can land while paused).
        if let first = copyNextMediaSample(from: output) {
            setDisplayImmediately(first)
            retimer.record(first)
            samplesThisPass = 1
            enqueue(first)
        }
        CATransaction.commit()
        CATransaction.flush()
        showingFallback = false
        startClock()
        prepareNextReader()
        feed()
    }

    private func showFallback() {
        guard let image = FallbackArt.image(width: 1_920, height: 1_080),
              let still = makeStillSampleBuffer(from: image) else { return }
        setDisplayImmediately(still)
        CMTimebaseSetRate(timebase, rate: 0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateGeometry(orientation: .identity)
        renderer.enqueue(still)
        CATransaction.commit()
        CATransaction.flush()
        showingFallback = true
    }

    /// Run the clock after a first frame: at rate 1, then held again shortly if paused.
    private func startClock() {
        CMTimebaseSetRate(timebase, rate: 1)
        if !wantsPlay {
            holdAfterFirstFrame()
            scheduleDeepPause()
        }
    }

    // MARK: - Flushes (queue)

    /// Flush the decoder and run `completion` on the queue once the flush is done; only
    /// then may samples be enqueued again. A video change requested in between
    /// supersedes `completion` with one more restart. The caller has checked
    /// `flushInFlight` and released the readers.
    private func beginFlush(removingDisplayedImage: Bool, then completion: @escaping () -> Void) {
        flushInFlight = true
        #if LIVEWALL_HARNESS
        onFlush?(true)
        #endif
        renderer.flush(removingDisplayedImage: removingDisplayedImage) { [weak self] in
            guard let self else { return }
            self.queue.async {
                self.flushInFlight = false
                #if LIVEWALL_HARNESS
                self.onFlush?(false)
                #endif
                if self.restartPending {
                    self.restartPending = false
                    self.restart()
                    return
                }
                completion()
            }
        }
    }

    // MARK: - Play / pause (queue)

    private func applyPlaying(_ play: Bool) {
        guard isRunning, play != wantsPlay else { return }
        wantsPlay = play
        if play {
            cancelDeepPause()
            holdGeneration += 1
            // Without a video, or mid-flush (the flush completion sets the clock), the
            // logical state is all that changes.
            guard pipelineStarted, asset != nil, !flushInFlight else { return }
            if currentReader == nil {
                // Deep-pause wake: the clock starts once the rebuilt pipeline's first
                // frame is enqueued, after the flush.
                recreatePlayback(seamless: true)
            } else {
                CMTimebaseSetRate(timebase, rate: 1)
            }
        } else {
            CMTimebaseSetRate(timebase, rate: 0)
            scheduleDeepPause()
        }
    }

    private func holdAfterFirstFrame() {
        holdGeneration += 1
        let generation = holdGeneration
        queue.asyncAfter(deadline: .now() + Self.firstFrameRunway) { [weak self] in
            guard let self, self.isRunning, !self.wantsPlay, generation == self.holdGeneration else { return }
            CMTimebaseSetRate(self.timebase, rate: 0)
        }
    }

    private func scheduleDeepPause() {
        cancelDeepPause()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.deepPauseDelay)
        timer.setEventHandler { [weak self] in self?.enterDeepPause() }
        deepPauseTimer = timer
        timer.resume()
    }

    private func cancelDeepPause() {
        deepPauseTimer?.cancel()
        deepPauseTimer = nil
    }

    private func enterDeepPause() {
        deepPauseTimer = nil
        guard isRunning, !wantsPlay, currentReader != nil, !flushInFlight else { return }
        releaseReaders()
        extensionLog("  [Renderer #\(debugID)] deep pause — released the asset readers")
    }

    private func releaseReaders() {
        renderer.stopRequestingMediaData()
        currentReader?.cancelReading()
        nextReader?.cancelReading()
        currentReader = nil
        currentOutput = nil
        nextReader = nil
        nextOutput = nil
    }

    /// Rebuild the readers after a decoder flush. `seamless` (deep-pause wake, or a
    /// decoder that needs a reset): continue from the paused position and keep the held
    /// frame on screen. Otherwise (decoder error): clear the frame and start over at 0.
    /// The clock is held until the first frame is enqueued, then follows `wantsPlay`.
    private func recreatePlayback(seamless: Bool) {
        // An in-flight flush rebuilds the pipeline when it completes.
        guard !flushInFlight, asset != nil else { return }
        CMTimebaseSetRate(timebase, rate: 0)
        holdGeneration += 1
        cancelDeepPause()
        releaseReaders()

        let now = CMTimebaseGetTime(timebase)
        let continuing = seamless && now.isNumeric && now > .zero
        let resume = continuing ? retimer.resumePoint(forTimelineTime: now) : nil
        beginFlush(removingDisplayedImage: !continuing) { [weak self] in
            self?.afterRecreateFlush(continuingAt: continuing ? now : nil, resume: resume)
        }
    }

    private func afterRecreateFlush(continuingAt now: CMTime?, resume: (clipTime: CMTime, offset: CMTime)?) {
        guard isRunning, let asset, let videoTrack else { return }
        guard let (reader, output) = makeReader(asset, videoTrack, from: resume?.clipTime) else {
            extensionError("  [Renderer #\(debugID)] could not recreate the asset reader")
            return
        }
        reader.startReading()
        currentReader = reader
        currentOutput = output
        if let now, let resume {
            retimer.resume(atTimelineTime: now, offset: resume.offset)
        } else {
            retimer.reset()
            CMTimebaseSetTime(timebase, time: .zero)
        }
        // DisplayImmediately: replaces the held frame (or the cleared layer) as soon as
        // the resume point's keyframe decodes.
        if let first = copyNextMediaSample(from: output) {
            let timed = retimer.retime(first)
            setDisplayImmediately(timed)
            samplesThisPass = 1
            enqueue(timed)
        }
        traceLog("  [Renderer #\(debugID)] readers rebuilt (\(now.map { "continuing at \(String(format: "%.2f", $0.seconds)) s" } ?? "from 0"))")
        if now != nil {
            // The clock resumes at the paused position, or stays held if a pause arrived
            // during the flush.
            if wantsPlay {
                CMTimebaseSetRate(timebase, rate: 1)
            } else {
                scheduleDeepPause()
            }
        } else {
            startClock()
        }
        prepareNextReader()
        feed()
    }

    private func recoverFromError() {
        // A flush in flight rebuilds the pipeline anyway, and two must not overlap.
        guard isRunning, !flushInFlight else { return }
        recoveries += 1
        guard recoveries <= Self.maxRecoveries else {
            extensionError("  [Renderer #\(debugID)] decoder keeps failing — holding the last frame")
            return
        }
        recreatePlayback(seamless: false)
    }

    // MARK: - Readers and the feed loop (queue)

    private func makeReader(_ asset: AVURLAsset, _ track: AVAssetTrack,
                            from start: CMTime? = nil) -> (AVAssetReader, AVAssetReaderTrackOutput)? {
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        if let start, start > .zero {
            reader.timeRange = CMTimeRange(start: start, duration: .positiveInfinity)
        }
        // nil settings: compressed samples pass straight through to the display layer.
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        return (reader, output)
    }

    /// Build the next pass's reader ahead of time, so the loop boundary has no gap.
    private func prepareNextReader() {
        queue.async { [weak self] in
            guard let self, self.isRunning, !self.flushInFlight,
                  let asset = self.asset, let track = self.videoTrack else { return }
            if let (reader, output) = self.makeReader(asset, track) {
                self.nextReader = reader
                self.nextOutput = output
            }
        }
    }

    /// The current pass ran out: continue with the preloaded reader on a shifted
    /// timeline (no flush, no clock reset).
    private func endOfPass() {
        guard isRunning, !flushInFlight, asset != nil else { return }
        if samplesThisPass == 0 {
            emptyPasses += 1
            if emptyPasses >= 2 {
                let status = currentReader?.status.rawValue ?? -1
                extensionError("  [Renderer #\(debugID)] reader produced no samples (status \(status), \(currentReader?.error?.localizedDescription ?? "no error")) — holding the last frame")
                return
            }
        } else {
            emptyPasses = 0
            recoveries = 0
        }
        retimer.beginNextPass()
        if let reader = nextReader, let output = nextOutput {
            currentReader = reader
            currentOutput = output
        } else if let asset, let videoTrack, let (reader, output) = makeReader(asset, videoTrack) {
            currentReader = reader
            currentOutput = output
        } else {
            extensionError("  [Renderer #\(debugID)] could not create the next loop's reader")
            return
        }
        nextReader = nil
        nextOutput = nil
        samplesThisPass = 0
        currentReader?.startReading()
        prepareNextReader()
        feed()
    }

    private func feed() {
        renderer.requestMediaDataWhenReady(on: queue) { [weak self] in
            guard let self else { return }
            guard self.isRunning, !self.flushInFlight else {
                self.renderer.stopRequestingMediaData()
                return
            }
            if self.renderer.status == .failed {
                extensionError("  [Renderer #\(self.debugID)] decoder failed: \(self.renderer.error?.localizedDescription ?? "unknown") — recovering")
                self.renderer.stopRequestingMediaData()
                // requestMediaDataWhenReady is not reentrant.
                self.queue.async { self.recoverFromError() }
                return
            }
            if self.renderer.requiresFlushToResumeDecoding {
                // The decoder was reset under us (it can't continue mid-GOP): rebuild
                // from the current position after a proper, awaited flush.
                extensionLog("  [Renderer #\(self.debugID)] decoder needs a flush to resume — rebuilding")
                self.renderer.stopRequestingMediaData()
                self.queue.async { self.recreatePlayback(seamless: true) }
                return
            }
            while self.renderer.isReadyForMoreMediaData {
                guard let output = self.currentOutput else {
                    self.renderer.stopRequestingMediaData()
                    return
                }
                if let sample = copyNextMediaSample(from: output) {
                    self.samplesThisPass += 1
                    self.enqueue(self.retimer.retime(sample))
                } else {
                    self.renderer.stopRequestingMediaData()
                    self.queue.async { self.endOfPass() }
                    return
                }
            }
        }
    }

    private func enqueue(_ sample: CMSampleBuffer) {
        #if LIVEWALL_HARNESS
        onEnqueue?(sample)
        #endif
        renderer.enqueue(sample)
    }

    // MARK: - Track loading

    private final class TrackBox: @unchecked Sendable {
        var track: AVAssetTrack?
        var transform = CGAffineTransform.identity
    }

    /// Load the first video track synchronously. Called only on the renderer's own
    /// queue, which blocks while AVFoundation loads on its internal queue; local files
    /// load in a few milliseconds.
    private static func loadFirstVideoTrackBlocking(_ asset: AVURLAsset) -> AVAssetTrack? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = TrackBox()
        asset.loadTracks(withMediaType: .video) { tracks, error in
            box.track = tracks?.first
            if let error {
                extensionError("  [Renderer] loading tracks of \(asset.url.lastPathComponent) failed: \(error.localizedDescription)")
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 10) == .success else {
            extensionError("  [Renderer] loading tracks of \(asset.url.lastPathComponent) timed out")
            return nil
        }
        return box.track
    }

    /// The track's preferred transform (identity if it cannot be loaded). Renderer queue,
    /// like loadFirstVideoTrackBlocking.
    private static func loadPreferredTransformBlocking(_ track: AVAssetTrack) -> CGAffineTransform {
        let semaphore = DispatchSemaphore(value: 0)
        let box = TrackBox()
        Task {
            box.transform = (try? await track.load(.preferredTransform)) ?? .identity
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 5) == .success else {
            extensionError("  [Renderer] loading the preferred transform timed out — assuming upright")
            return .identity
        }
        return box.transform
    }

    private static func describe(_ t: CGAffineTransform) -> String {
        switch Int((atan2(t.b, t.a) * 180 / .pi).rounded()) {
        case -90: return "90° clockwise"
        case 90: return "90° counterclockwise"
        default: return "180°"
        }
    }
}
