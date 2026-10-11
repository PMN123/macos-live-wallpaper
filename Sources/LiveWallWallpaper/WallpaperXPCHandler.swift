// LiveWallWallpaper — the object WallpaperAgent calls over XPC.
//
// Adapted from Phosphene (https://github.com/kageroumado/phosphene), MIT License, © 2026 kageroumado
// Sources: PhospheneExtension/WallpaperXPCHandler.swift and SnapshotCreation.swift at
// commit db03edf. See THIRD_PARTY_NOTICES.md.

import AVFoundation
import Foundation
import IOSurface
import LiveWallShared
import QuartzCore
import WallpaperPrivate

@available(macOS 26.0, *)
final class WallpaperXPCHandler: NSObject, WallpaperExtensionXPCProtocol {
    /// Proxy for calling WallpaperAgent (updateSettingsViewModels, invalidateSnapshots).
    /// Assigned in accept(connection:), cleared from the invalidation handler, read from
    /// XPC callbacks, so it is lock-protected.
    private let agentProxyLock = NSLock()
    private var _agentProxy: WallpaperExtensionProxyXPCProtocol?
    var agentProxy: WallpaperExtensionProxyXPCProtocol? {
        get { agentProxyLock.lock(); defer { agentProxyLock.unlock() }; return _agentProxy }
        set { agentProxyLock.lock(); defer { agentProxyLock.unlock() }; _agentProxy = newValue }
    }

    /// PID of the peer on this connection (agent vs. Settings preview vs. thumbnails).
    var connectionPID: Int32 = -1

    // MARK: - Lifecycle

    func acquire(withId id: Any?, request: Any?, reply: @escaping (Any?, Error?) -> Void) {
        Lifecycle.queue.async { self.acquireBody(id: id, request: request, reply: reply) }
    }

    private func acquireBody(id: Any?, request: Any?, reply: @escaping (Any?, Error?) -> Void) {
        // Destination geometry, preview flag and choice, read from the request's private
        // Swift payload via Mirror: WallpaperCreationRequestXPC.rawValue.{destination,
        // isPreview, descriptor.configuration}.
        var destSize = CGSize(width: 2_560, height: 1_440) // fallback
        var scaleFactor: CGFloat = 2.0
        var isPreview = false
        var displayID: UInt32?
        var choiceConfiguration: String?
        if let reqObj = request as? NSObject {
            for child in Mirror(reflecting: reqObj).children {
                for prop in Mirror(reflecting: child.value).children {
                    if prop.label == "destination" {
                        for destProp in Mirror(reflecting: prop.value).children {
                            if destProp.label == "size", let size = destProp.value as? CGSize {
                                destSize = size
                            } else if destProp.label == "scaleFactor", let sf = destProp.value as? CGFloat {
                                scaleFactor = sf
                            } else if destProp.label == "directDisplayID", let did = destProp.value as? UInt32 {
                                displayID = did
                            }
                        }
                    } else if prop.label == "isPreview", let preview = prop.value as? Bool {
                        isPreview = preview
                    } else if prop.label == "descriptor" {
                        if let data = mirrorFindProperty("configuration", in: prop.value) as? Data, !data.isEmpty {
                            choiceConfiguration = String(decoding: data, as: UTF8.self)
                        }
                    }
                }
            }
        }

        let surfaceUUID = extractWallpaperUUID(fromID: id) ?? SurfaceRegistry.fallbackSurfaceUUID(forDisplay: displayID ?? 0)
        let registry = SurfaceRegistry.shared
        // The creation request also carries the initial state; a surface acquired while
        // suspended must start held rather than wait for the first update.
        var initialMode = "default"
        var initialActivity = "active"
        if let request {
            if let value = mirrorFindProperty("presentationMode", in: request) { initialMode = enumCaseName(value) }
            if let value = mirrorFindProperty("activityState", in: request) { initialActivity = enumCaseName(value) }
        }
        let startSuspended = initialActivity.contains("suspended")
        extensionLog("=== ACQUIRE (pid \(connectionPID)) === surface \(surfaceUUID.uuidString) display \(displayID.map(String.init) ?? "nil") size \(destSize) @\(scaleFactor)x preview \(isPreview) choice \(choiceConfiguration ?? "nil") mode \(initialMode) activity \(initialActivity)")
        traceLog("  acquire request: \(describeXPCPayload(request))")

        // Pick up a state change whose notification was missed (e.g. while not running).
        let store = SharedStateStore.shared
        store.refresh(reason: "acquire")

        // ---- REUSE: this WallpaperID already has a context ----
        if let existing = registry.surface(for: surfaceUUID) {
            registry.cancelTeardown(existing)
            existing.isPreview = isPreview
            if existing.destSize != destSize || existing.scaleFactor != scaleFactor {
                existing.destSize = destSize
                existing.scaleFactor = scaleFactor
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                existing.rootLayer.frame = CGRect(origin: .zero, size: destSize)
                existing.rootLayer.contentsScale = scaleFactor
                CATransaction.commit()
                CATransaction.flush()
                existing.renderer.resize(to: destSize, scale: scaleFactor)
                extensionLog("  REUSE context \(existing.contextId) — geometry changed, re-framed")
            } else {
                extensionLog("  REUSE context \(existing.contextId)")
            }
            existing.agent.update(mode: initialMode, suspended: startSuspended)
            registry.reconcilePlayback(existing)
            Liveness.shared.noteAgentReport(isPreview: isPreview, mode: initialMode, suspended: startSuspended)
            guard let replyObj = createRemoteContextXPC(contextId: existing.contextId) else {
                reply(nil, makeError(3, "Failed to build WallpaperRemoteContextXPC"))
                return
            }
            reply(replyObj, nil)
            Liveness.shared.recompute()
            return
        }

        // ---- CREATE: first acquire for this WallpaperID ----
        guard let (context, contextId) = CARemote.makeRemoteContext(displayID: displayID) else {
            extensionError("  ERROR: remote CAContext creation failed — failing acquire")
            reply(nil, makeError(4, "Failed to create remote CAContext"))
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let rootLayer = CALayer()
        rootLayer.frame = CGRect(origin: .zero, size: destSize)
        rootLayer.contentsScale = scaleFactor
        rootLayer.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        rootLayer.isOpaque = true
        CARemote.setLayer(rootLayer, on: context)
        CATransaction.commit()
        CATransaction.flush()

        // Seed the layer with the tile thumbnail so the very first composite is never
        // empty; the video's first frame replaces it.
        let seed = loadImage(at: store.thumbnailURL)
        guard let renderer = VideoRenderer(rootLayer: rootLayer, gravity: store.gravity, seed: seed) else {
            extensionError("  ERROR: renderer creation failed — failing acquire")
            CARemote.invalidate(context)
            reply(nil, makeError(6, "Failed to create the video renderer"))
            return
        }
        let agent = registry.freshAgentState(isPreview: isPreview, mode: initialMode, suspended: startSuspended,
                                             displayID: displayID)
        if agent.isSelectedDesktop, initialMode != "default" {
            extensionLog("  display \(displayID.map(String.init) ?? "nil") showed LiveWall as a desktop before → this \(initialMode) surface counts as a desktop")
        }
        let surface = HostedSurface(
            wallpaperID: surfaceUUID, context: context, contextId: contextId, rootLayer: rootLayer,
            renderer: renderer, displayID: displayID, agent: agent,
            destSize: destSize, scaleFactor: scaleFactor
        )
        registry.install(surface)
        Liveness.shared.noteAgentReport(isPreview: isPreview, mode: initialMode, suspended: startSuspended)

        // Up to the first enqueued frame before replying: the agent shows whatever the
        // context holds the moment it hosts it.
        renderer.load(store.videoURL, synchronously: true)
        registry.reconcilePlayback(surface)

        guard let replyObj = createRemoteContextXPC(contextId: contextId) else {
            registry.tearDown(surfaceUUID)
            reply(nil, makeError(3, "Failed to build WallpaperRemoteContextXPC"))
            return
        }
        extensionLog("  CREATED context \(contextId) renderer #\(renderer.debugID) for \(surface.label) (\(registry.count) surface(s)) video \(store.videoURL?.lastPathComponent ?? "none")")
        reply(replyObj, nil)
        Liveness.shared.recompute()
    }

    func update(withId id: Any?, request: Any?, reply: @escaping (Error?) -> Void) {
        Lifecycle.queue.async { self.updateBody(id: id, request: request, reply: reply) }
    }

    /// The agent's presentation mode (default, locked, idle) and activity state for one
    /// surface (or all, when the id is not one of ours).
    private func updateBody(id: Any?, request: Any?, reply: @escaping (Error?) -> Void) {
        var modeName = "default"
        var activityName = "active"
        var activityDetail = "active"
        if let request {
            if let value = mirrorFindProperty("presentationMode", in: request) {
                modeName = enumCaseName(value)
            }
            if let value = mirrorFindProperty("activityState", in: request) {
                activityName = enumCaseName(value)
                activityDetail = String(describing: value)
            }
        }
        let suspended = activityName.contains("suspended")

        let uuid = extractWallpaperUUID(fromID: id)
        let registry = SurfaceRegistry.shared
        let targets: [HostedSurface]
        if let uuid, let surface = registry.surface(for: uuid) {
            targets = [surface]
        } else {
            targets = registry.all
        }

        extensionLog("=== UPDATE (pid \(connectionPID)) === surface \(uuid.map { String($0.uuidString.prefix(8)) } ?? "unknown → all") mode \(modeName) activity \(activityDetail) (\(targets.count) surface(s))")
        traceLog("  update request: \(describeXPCPayload(request))")

        for surface in targets {
            surface.agent.update(mode: modeName, suspended: suspended)
            registry.reconcilePlayback(surface)
        }
        Liveness.shared.noteAgentReport(isPreview: targets.allSatisfy(\.isPreview), mode: modeName, suspended: suspended)
        Liveness.shared.recompute()
        reply(nil)
    }

    func invalidate(withId id: Any?, reply: @escaping (Error?) -> Void) {
        Lifecycle.queue.async { self.invalidateBody(id: id, reply: reply) }
    }

    private func invalidateBody(id: Any?, reply: @escaping (Error?) -> Void) {
        let registry = SurfaceRegistry.shared
        guard let uuid = extractWallpaperUUID(fromID: id) else {
            extensionLog("=== INVALIDATE (pid \(connectionPID)) === no UUID in id → ignored (\(registry.count) surface(s) kept)")
            reply(nil)
            return
        }
        guard let surface = registry.surface(for: uuid) else {
            extensionLog("=== INVALIDATE (pid \(connectionPID)) === surface \(uuid.uuidString) unknown → ignored")
            reply(nil)
            return
        }
        registry.scheduleTeardown(surface)
        extensionLog("=== INVALIDATE (pid \(connectionPID)) === \(surface.label) → held; teardown in \(Int(Lifecycle.teardownGrace)) s unless re-acquired")
        Liveness.shared.recompute()
        reply(nil)
    }

    func snapshot(withId id: Any?, reply: @escaping (Any?, Error?) -> Void) {
        Lifecycle.queue.async {
            let registry = SurfaceRegistry.shared
            let surface = extractWallpaperUUID(fromID: id).flatMap { registry.surface(for: $0) }
                ?? registry.all.first { !$0.isPreview }
            let store = SharedStateStore.shared
            let pixels = snapshotPixelSize(destSize: surface?.destSize, scale: surface?.scaleFactor)
            let source = surface?.renderer.currentFrameSource() ?? store.videoURL.map { (url: $0, time: CMTime.zero) }
            let gravity = store.state.gravity
            let thumbnailURL = store.thumbnailURL
            let pid = self.connectionPID
            makeVideoSnapshot(source: source, pixelWidth: pixels.width, pixelHeight: pixels.height, gravity: gravity,
                              fallbackImageURL: thumbnailURL) { snapshot, what in
                extensionLog("=== SNAPSHOT (pid \(pid)) === \(snapshot != nil ? what : "nil")")
                reply(snapshot, nil)
            }
        }
    }

    // MARK: - Settings

    func provideSettingsViewModels(withContentTypes types: Any?, reply: @escaping (Any?, Error?) -> Void) {
        extensionLog("=== PROVIDE SETTINGS VIEW MODELS (pid \(connectionPID)) === types: \(describeXPCPayload(types))")
        // Serialized with the rest of the lifecycle: several connections can ask at once
        // and a build may copy the tile thumbnail.
        Lifecycle.queue.async {
            if let result = buildSettingsViewModelsXPC() {
                extensionLog("  [Settings] replying with \(NSStringFromClass(type(of: result)))")
                reply(result, nil)
            } else {
                // Never fall back to an empty group: the agent caches the answer on disk
                // and an empty group hides the section until the cache is rebuilt.
                extensionError("  [Settings] build failed — replying with an error, not an empty group")
                reply(nil, makeError(5, "Failed to build settings view models"))
            }
        }
    }

    // MARK: - Choices

    func addChoiceRequest(withChoiceRequest _: Any?, onBehalfOfProcess _: Any?, reply: @escaping (Any?, Error?) -> Void) {
        extensionLog("=== ADD CHOICE REQUEST === (ignored)")
        reply(nil, nil)
    }

    func removeChoiceRequest(withChoiceRequest _: Any?, reply: @escaping (Error?) -> Void) {
        extensionLog("=== REMOVE CHOICE REQUEST === (ignored)")
        reply(nil)
    }

    func selectedChoicesDidChange(for id: Any?, reply: @escaping (Error?) -> Void) {
        extensionLog("=== SELECTED CHOICES DID CHANGE === \(describeXPCPayload(id))")
        // Have the picker re-fetch snapshots (Phosphene does the same).
        agentProxy?.invalidateSnapshots { error in
            if let error {
                extensionError("  invalidateSnapshots error: \(error)")
            }
        }
        reply(nil)
    }

    func invokeContextMenuAction(withMenuItemID menuItemID: Any?, groupItemID _: Any?, reply: @escaping (Error?) -> Void) {
        extensionLog("=== CONTEXT MENU ACTION === \(describeBounded(menuItemID))")
        reply(nil)
    }

    // MARK: - Downloads

    func isChoiceDownloaded(with _: Any?, reply: @escaping (NSNumber?, Error?) -> Void) {
        traceLog("isChoiceDownloaded → true")
        reply(NSNumber(value: true), nil)
    }

    func download(withChoiceID _: Any?, reply: @escaping (Error?) -> Void) -> Any? {
        traceLog("download (no-op)")
        reply(nil)
        return nil
    }

    func pauseDownload(for _: Any?, reply: @escaping (Error?) -> Void) {
        reply(nil)
    }

    func cancelDownload(for _: Any?, reply: @escaping (Error?) -> Void) {
        reply(nil)
    }

    func resumeDownload(for _: Any?, reply: @escaping (Error?) -> Void) {
        reply(nil)
    }

    func removeDownload(for _: Any?, reply: @escaping (Error?) -> Void) {
        extensionLog("=== REMOVE DOWNLOAD === (ignored: the video is managed in LiveWall)")
        reply(nil)
    }

    // MARK: - Migration

    func migrateSelectedChoice(for _: Any?, reply: @escaping (Any?, Error?) -> Void) {
        traceLog("migrateSelectedChoice (no-op)")
        reply(nil, nil)
    }

    func migrate(from _: Any?, to _: Any?, reply: @escaping (Error?) -> Void) {
        traceLog("migrate (no-op)")
        reply(nil)
    }

    // MARK: - Shuffle

    func skipShuffledContent(withId _: Any?, reply: @escaping (Error?) -> Void) {
        traceLog("skipShuffledContent (no-op)")
        reply(nil)
    }

    func canSkipShuffledContent(withId _: Any?, reply: @escaping (Bool, Error?) -> Void) {
        traceLog("canSkipShuffledContent → false")
        reply(false, nil)
    }

    // MARK: - Debug & notifications

    func handleDebugRequest(for _: Any?, reply: @escaping (Any?, Error?) -> Void) {
        traceLog("handleDebugRequest (no-op)")
        reply(nil, nil)
    }

    func handleNotification(withNamed name: Any?, reply: @escaping (Error?) -> Void) {
        extensionLog("=== NOTIFICATION === \(describeBounded(name))")
        reply(nil)
    }
}

private func makeError(_ code: Int, _ message: String) -> NSError {
    NSError(domain: "com.praniil.livewall.wallpaper", code: code, userInfo: [NSLocalizedDescriptionKey: message])
}

/// The private Swift payload of an XPC wrapper (`box` / `rawValue`), described for logs.
/// The wrapper NSObjects themselves only print their address.
func describeXPCPayload(_ value: Any?) -> String {
    guard let value else { return "nil" }
    if let payload = Mirror(reflecting: value).children.first?.value {
        return describeBounded(payload)
    }
    return describeBounded(value)
}

/// Snapshot size in pixels: the surface's backing size, longest side capped at 4096.
func snapshotPixelSize(destSize: CGSize?, scale: CGFloat?) -> (width: Int, height: Int) {
    var w = (destSize?.width ?? 1_920) * (scale ?? 2)
    var h = (destSize?.height ?? 1_080) * (scale ?? 2)
    if w <= 0 || h <= 0 {
        w = 3_840
        h = 2_160
    }
    let longest = max(w, h)
    if longest > 4_096 {
        let factor = 4_096 / longest
        w *= factor
        h *= factor
    }
    return (max(Int(w.rounded()), 16), max(Int(h.rounded()), 16))
}

/// A WallpaperSnapshotXPC of the frame on screen (`source`), so lock and transition
/// snapshots match the live wallpaper instead of going gray. Falls back to the tile
/// thumbnail, then to the fallback art. `completion` runs exactly once, on an arbitrary
/// queue, with a short description of what was used.
func makeVideoSnapshot(source: (url: URL, time: CMTime)?, pixelWidth: Int, pixelHeight: Int,
                       gravity: SharedGravity, fallbackImageURL: URL,
                       completion: @escaping (AnyObject?, String) -> Void) {
    func fallback(_ why: String) {
        if let image = loadImage(at: fallbackImageURL),
           let snapshot = makeSnapshotXPC(image: image, pixelWidth: pixelWidth, pixelHeight: pixelHeight, gravity: gravity) {
            completion(snapshot, "thumbnail (\(why))")
        } else if let art = FallbackArt.image(width: 1_920, height: 1_080),
                  let snapshot = makeSnapshotXPC(image: art, pixelWidth: pixelWidth, pixelHeight: pixelHeight, gravity: .fill) {
            completion(snapshot, "fallback art (\(why))")
        } else {
            completion(nil, why)
        }
    }
    guard let source else {
        fallback("no video")
        return
    }
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source.url))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: pixelWidth, height: pixelHeight)
    // Within half a second is close enough for a snapshot and avoids an exact-frame decode.
    let tolerance = CMTime(value: 1, timescale: 2)
    generator.requestedTimeToleranceBefore = tolerance
    generator.requestedTimeToleranceAfter = tolerance
    let time = source.time.isNumeric ? source.time : .zero
    generator.generateCGImageAsynchronously(for: time) { image, _, error in
        withExtendedLifetime(generator) {}
        guard let image else {
            fallback(error?.localizedDescription ?? "no frame")
            return
        }
        if let snapshot = makeSnapshotXPC(image: image, pixelWidth: pixelWidth, pixelHeight: pixelHeight, gravity: gravity) {
            completion(snapshot, "frame at \(String(format: "%.2f", time.seconds)) s (\(pixelWidth)x\(pixelHeight))")
        } else {
            fallback("IOSurface")
        }
    }
}
