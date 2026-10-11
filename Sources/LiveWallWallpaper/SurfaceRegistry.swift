// LiveWallWallpaper — one hosted surface (remote CAContext + layer tree + renderer) per
// WallpaperID.
//
// Adapted from Phosphene (https://github.com/kageroumado/phosphene), MIT License, © 2026 kageroumado
// Sources: PhospheneExtension/SurfaceRegistry.swift and the Lifecycle queue / teardown
// grace in WallpaperXPCHandler.swift at commit db03edf. See THIRD_PARTY_NOTICES.md.
//
// Each WallpaperID (a Space, the lock-screen surface, a Settings preview) gets its own
// CAContext: WallpaperAgent hosts a context in only one CALayerHost at a time, so
// sharing one context across surfaces blacks out the others (Phosphene commit 420a9f2).

import Foundation
import QuartzCore

/// Process-wide serialization for wallpaper lifecycle work. Every connection gets its
/// own handler, but the agent multiplexes desktop, Settings-preview and thumbnail
/// connections; funnelling acquire/update/invalidate/snapshot, the host's state
/// notifications and the liveness heartbeat through one serial queue keeps an
/// invalidate from slipping between the halves of an acquire. All registry and store
/// state is touched only on this queue, so it needs no lock.
enum Lifecycle {
    static let queue = DispatchQueue(label: "com.praniil.livewall.wallpaper.lifecycle")

    /// Grace between an invalidate and the actual teardown. A re-acquire of the same
    /// WallpaperID (display wake, quick Space revisit) cancels it, so the context and its
    /// last frame survive and nothing flashes gray. The renderer pauses at once.
    static let teardownGrace: TimeInterval = 10
}

/// WallpaperAgent's view of one surface, and the two rules LiveWall derives from it:
/// whether LiveWall is the selected wallpaper of a desktop there (Liveness) and whether
/// to play. LiveWall follows only macOS's own signals here; it adds no pauses of its
/// own beyond the user's Pause in LiveWall's menu. A plain value, so the rules can be
/// checked on their own.
struct SurfaceAgentState: Equatable {
    /// A System Settings preview: never a desktop.
    var isPreview: Bool
    /// Presentation mode: "default" (a desktop), "locked" (the lock screen) or "idle"
    /// (another screen saver covers it, or the Settings picker idles its preview; the
    /// tile is not offered as a screen saver, see SettingsProvider).
    private(set) var mode: String
    /// activityState suspended: the agent is not compositing the surface (nobody can see
    /// it, e.g. the display is asleep or another Space is showing).
    private(set) var suspended: Bool
    /// Invalidated by the agent (another wallpaper picked, the Space or display gone,
    /// and possibly display sleep); a re-acquire clears it.
    var invalidated = false
    /// The agent has shown the surface as a desktop (presentation mode default, not a
    /// preview) at least once, or the surface replaces one that was a desktop on the
    /// same display (DesktopDisplayMemory). A lock-screen-only surface never has.
    private(set) var hasBeenDesktop = false

    /// `inheritsDesktop`: a fresh surface on a display where LiveWall was a desktop
    /// until the agent tore that surface down (DesktopDisplayMemory). It counts as a
    /// desktop at once, even when acquired on the lock screen.
    init(isPreview: Bool, mode: String = "default", suspended: Bool = false, inheritsDesktop: Bool = false) {
        self.isPreview = isPreview
        self.mode = mode
        self.suspended = suspended
        hasBeenDesktop = inheritsDesktop && !isPreview
        noteDesktop()
    }

    /// The agent's latest presentation mode and activity state.
    mutating func update(mode: String, suspended: Bool) {
        self.mode = mode
        self.suspended = suspended
        noteDesktop()
    }

    private mutating func noteDesktop() {
        if mode == "default", !isPreview {
            hasBeenDesktop = true
        }
    }

    /// LiveWall is the selected wallpaper of this desktop, whether or not the agent is
    /// drawing it right now: suspension and the locked and idle modes come and go, and
    /// only an invalidate deselects it. The agent may also invalidate while the displays
    /// sleep, so Liveness holds an active status through display sleep instead of
    /// reading every invalidate as the user picking another wallpaper.
    var isSelectedDesktop: Bool {
        !isPreview && hasBeenDesktop && !invalidated
    }

    /// Play while the agent composites the surface (not suspended, not invalidated, not
    /// idle under another screen saver), including on the lock screen, unless the user
    /// paused in LiveWall's menu.
    func shouldPlay(hasVideo: Bool, userPaused: Bool) -> Bool {
        hasVideo && !userPaused && !suspended && !invalidated && mode != "idle"
    }
}

/// The displays on which LiveWall has been a selected desktop since Liveness last
/// confirmed a deselection. The agent can tear a surface down (an invalidate whose
/// grace ran out, e.g. during a long display sleep) and later acquire a fresh one for
/// the same display directly in the locked mode (waking to the lock screen). Without
/// this memory that surface would not count as a desktop until the unlock, and LiveWall
/// would bring its own window back for the whole lock screen. Keyed by display ID (an
/// acquire without one uses 0). A plain value, so the rule can be checked on its own.
struct DesktopDisplayMemory: Equatable {
    private(set) var displays = Set<UInt32>()

    private static func key(_ displayID: UInt32?) -> UInt32 { displayID ?? 0 }

    /// Remember the display of a selected desktop surface.
    mutating func note(_ agent: SurfaceAgentState, displayID: UInt32?) {
        if agent.isSelectedDesktop {
            displays.insert(Self.key(displayID))
        }
    }

    func remembers(_ displayID: UInt32?) -> Bool {
        displays.contains(Self.key(displayID))
    }

    /// The agent state of a newly created surface: a non-preview surface on a remembered
    /// display inherits the desktop status.
    func freshState(isPreview: Bool, mode: String, suspended: Bool, displayID: UInt32?) -> SurfaceAgentState {
        SurfaceAgentState(isPreview: isPreview, mode: mode, suspended: suspended,
                          inheritsDesktop: !isPreview && remembers(displayID))
    }

    /// Liveness confirmed a deselection (the displays awake, no selected desktop left).
    mutating func forgetAll() {
        displays.removeAll()
    }
}

@available(macOS 26.0, *)
final class HostedSurface {
    let wallpaperID: UUID
    let context: NSObject // CAContext (private class, held as NSObject)
    let contextId: UInt32
    let rootLayer: CALayer
    let renderer: VideoRenderer
    let displayID: UInt32?
    var destSize: CGSize
    var scaleFactor: CGFloat
    /// The agent's view of the surface: preview or not, presentation mode, suspension,
    /// invalidation.
    var agent: SurfaceAgentState
    var teardown: DispatchWorkItem?
    /// The play state last sent to the renderer.
    var playing = false

    init(wallpaperID: UUID, context: NSObject, contextId: UInt32, rootLayer: CALayer,
         renderer: VideoRenderer, displayID: UInt32?, agent: SurfaceAgentState,
         destSize: CGSize, scaleFactor: CGFloat) {
        self.wallpaperID = wallpaperID
        self.context = context
        self.contextId = contextId
        self.rootLayer = rootLayer
        self.renderer = renderer
        self.displayID = displayID
        self.agent = agent
        self.destSize = destSize
        self.scaleFactor = scaleFactor
    }

    var isPreview: Bool {
        get { agent.isPreview }
        set { agent.isPreview = newValue }
    }

    /// Invalidated by the agent; torn down when `teardown` fires unless re-acquired.
    var invalidated: Bool {
        get { agent.invalidated }
        set { agent.invalidated = newValue }
    }

    var label: String {
        "\(wallpaperID.uuidString.prefix(8))\(isPreview ? " (preview)" : "")"
    }
}

@available(macOS 26.0, *)
final class SurfaceRegistry {
    static let shared = SurfaceRegistry()
    private init() {}

    private var surfaces: [UUID: HostedSurface] = [:]
    private var desktopDisplays = DesktopDisplayMemory()

    func surface(for id: UUID) -> HostedSurface? {
        dispatchPrecondition(condition: .onQueue(Lifecycle.queue))
        return surfaces[id]
    }

    func install(_ surface: HostedSurface) {
        dispatchPrecondition(condition: .onQueue(Lifecycle.queue))
        surfaces[surface.wallpaperID] = surface
    }

    var all: [HostedSurface] {
        dispatchPrecondition(condition: .onQueue(Lifecycle.queue))
        return Array(surfaces.values)
    }

    var count: Int {
        dispatchPrecondition(condition: .onQueue(Lifecycle.queue))
        return surfaces.count
    }

    /// The agent's view of every surface.
    var agentStates: [SurfaceAgentState] {
        dispatchPrecondition(condition: .onQueue(Lifecycle.queue))
        return surfaces.values.map(\.agent)
    }

    /// LiveWall is the selected wallpaper of at least one desktop (see
    /// SurfaceAgentState.isSelectedDesktop), drawn right now or not.
    var hasSelectedDesktopSurface: Bool {
        dispatchPrecondition(condition: .onQueue(Lifecycle.queue))
        return surfaces.values.contains { $0.agent.isSelectedDesktop }
    }

    /// The agent state for a surface about to be created (DesktopDisplayMemory).
    func freshAgentState(isPreview: Bool, mode: String, suspended: Bool, displayID: UInt32?) -> SurfaceAgentState {
        dispatchPrecondition(condition: .onQueue(Lifecycle.queue))
        return desktopDisplays.freshState(isPreview: isPreview, mode: mode, suspended: suspended, displayID: displayID)
    }

    /// Record the displays of the selected desktop surfaces. Liveness calls this on
    /// every recompute, i.e. after every acquire, update, invalidate and teardown.
    func rememberSelectedDesktops() {
        dispatchPrecondition(condition: .onQueue(Lifecycle.queue))
        for surface in surfaces.values {
            desktopDisplays.note(surface.agent, displayID: surface.displayID)
        }
    }

    /// A deselection is confirmed: keep only the displays that still have a selected
    /// desktop surface.
    func forgetDeselectedDisplays() {
        dispatchPrecondition(condition: .onQueue(Lifecycle.queue))
        desktopDisplays.forgetAll()
        rememberSelectedDesktops()
    }

    /// Play or hold one surface (SurfaceAgentState.shouldPlay): with a video, unless the
    /// user paused in LiveWall's menu, while the agent composites it outside the
    /// screen-saver slot. The lock screen plays.
    func reconcilePlayback(_ surface: HostedSurface) {
        dispatchPrecondition(condition: .onQueue(Lifecycle.queue))
        let store = SharedStateStore.shared
        let play = surface.agent.shouldPlay(hasVideo: store.videoURL != nil, userPaused: store.isUserPaused)
        guard play != surface.playing else { return }
        surface.playing = play
        surface.renderer.setPlaying(play)
        traceLog("  [Surface \(surface.label)] \(play ? "PLAY" : "HOLD") (mode \(surface.agent.mode), suspended \(surface.agent.suspended), user paused \(store.isUserPaused), video \(store.videoURL != nil))")
    }

    /// Fan a state.json change out to every surface.
    func applySharedState(videoChanged: Bool, gravityChanged: Bool) {
        dispatchPrecondition(condition: .onQueue(Lifecycle.queue))
        let store = SharedStateStore.shared
        for surface in surfaces.values {
            if videoChanged {
                surface.renderer.load(store.videoURL, synchronously: false)
            }
            if gravityChanged {
                surface.renderer.setGravity(store.gravity)
            }
            reconcilePlayback(surface)
        }
    }

    /// Pause an invalidated surface now and tear it down after the grace period.
    func scheduleTeardown(_ surface: HostedSurface) {
        dispatchPrecondition(condition: .onQueue(Lifecycle.queue))
        surface.teardown?.cancel()
        surface.invalidated = true
        reconcilePlayback(surface)
        let id = surface.wallpaperID
        let work = DispatchWorkItem { [weak self] in
            guard let self, let current = self.surfaces[id], current.invalidated else { return }
            self.tearDown(id)
            extensionLog("  [Teardown] grace elapsed for \(current.label) → context \(current.contextId) invalidated (\(self.surfaces.count) left)")
            Liveness.shared.recompute()
        }
        surface.teardown = work
        Lifecycle.queue.asyncAfter(deadline: .now() + Lifecycle.teardownGrace, execute: work)
    }

    /// A re-acquire within the grace period keeps the surface.
    func cancelTeardown(_ surface: HostedSurface) {
        dispatchPrecondition(condition: .onQueue(Lifecycle.queue))
        guard surface.invalidated || surface.teardown != nil else { return }
        surface.teardown?.cancel()
        surface.teardown = nil
        surface.invalidated = false
        extensionLog("  [Teardown] cancelled for \(surface.label) (re-acquired)")
    }

    /// Stop the renderer, detach the tree and invalidate the context so the render
    /// server frees it. Dropping the reference is not enough: the agent's CALayerHost
    /// keeps the tree resident until the context is invalidated ("escalating gray").
    @discardableResult
    func tearDown(_ id: UUID) -> HostedSurface? {
        dispatchPrecondition(condition: .onQueue(Lifecycle.queue))
        guard let removed = surfaces.removeValue(forKey: id) else { return nil }
        removed.teardown?.cancel()
        removed.teardown = nil
        removed.renderer.stop()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CARemote.setLayer(nil, on: removed.context)
        CATransaction.commit()
        CARemote.invalidate(removed.context)
        CATransaction.flush()
        return removed
    }

    /// Stable per-display UUID for the rare acquire that carries no WallpaperID, so such
    /// acquires still collapse to one context per display instead of minting new ones.
    static func fallbackSurfaceUUID(forDisplay displayID: UInt32) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", displayID))
            ?? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    }
}
