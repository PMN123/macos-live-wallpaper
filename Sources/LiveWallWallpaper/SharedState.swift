// LiveWallWallpaper — what to play, as the LiveWall app publishes it.
//
// The host writes state.json, the video clone and thumbnail.png into the shared
// directory and posts com.praniil.livewall.wallpaper.state. This store re-reads the
// state on that notification (and on every acquire, in case one was missed) and fans
// the changes out to the hosted surfaces, the Settings tile and the snapshot cache.
// Confined to Lifecycle.queue.

import AppKit
import AVFoundation
import Foundation
import LiveWallShared
import notify

@available(macOS 26.0, *)
final class SharedStateStore {
    static let shared = SharedStateStore()

    /// What changed in the latest reload.
    struct Change {
        var video = false
        var gravity = false
        /// The user's Pause (isUserPaused).
        var paused = false
        var thumbnail = false

        var any: Bool { video || gravity || paused || thumbnail }
    }

    /// The directory the host's files are read from: the shared directory, or, if only
    /// it holds a state.json, the container fallback `Documents/Wallpaper/` (for a host
    /// switched to Phosphene-style container deployment should the sandbox exception
    /// ever not be honoured).
    private(set) var directory: URL = SharedWallpaper.defaultDirectory()
    private(set) var state = SharedWallpaperState()
    private(set) var videoURL: URL?
    /// The last reload read and decoded state.json (a decode error keeps the previous
    /// state and this flag).
    private(set) var stateRead = false
    private var thumbnailStamp: String?
    private var stateToken: Int32 = NOTIFY_TOKEN_INVALID
    private var pingToken: Int32 = NOTIFY_TOKEN_INVALID
    private var started = false

    private init() {}

    var gravity: AVLayerVideoGravity {
        switch state.gravity {
        case .fill: return .resizeAspectFill
        case .fit: return .resizeAspect
        case .stretch: return .resize
        }
    }

    var thumbnailURL: URL {
        directory.appendingPathComponent(SharedWallpaper.thumbnailFileName, isDirectory: false)
    }

    /// Title of the current video (from the name of the file the host cloned), for
    /// playing.json; nil when there is none.
    var currentVideoName: String? {
        guard videoURL != nil else { return nil }
        guard let source = state.source, !source.isEmpty else { return "LiveWall" }
        return SharedVideoNames.displayName(forFileName: (source as NSString).lastPathComponent)
    }

    /// A selected desktop shows what LiveWall published: its video, or deliberately nothing
    /// after the user removed the wallpaper in LiveWall. Otherwise (no state.json yet,
    /// the shared directory not readable, the video not readable) it shows only the
    /// fallback art, and LiveWall must keep its own window.
    var canShowPublishedWallpaper: Bool {
        Self.canShow(stateRead: stateRead, state: state, videoURL: videoURL)
    }

    static func canShow(stateRead: Bool, state: SharedWallpaperState, videoURL: URL?) -> Bool {
        if videoURL != nil { return true }
        return stateRead && state.videoID == nil && state.file == nil
    }

    /// The user paused in LiveWall's menu: the only pause the system wallpaper takes
    /// from LiveWall. Any other reason in state.json (an older LiveWall published its
    /// automatic pauses) is ignored; macOS decides when the wallpaper is drawn.
    var isUserPaused: Bool { Self.isUserPaused(state) }

    static func isUserPaused(_ state: SharedWallpaperState) -> Bool {
        state.paused && state.pauseReasons.contains("user")
    }

    /// Register for the host's notifications and load the current state. Lifecycle queue.
    func start() {
        dispatchPrecondition(condition: .onQueue(Lifecycle.queue))
        guard !started else { return }
        started = true

        let stateStatus = notify_register_dispatch(SharedWallpaper.Notification.state, &stateToken, Lifecycle.queue) { _ in
            SharedStateStore.shared.refresh(reason: "state notification")
        }
        let pingStatus = notify_register_dispatch(SharedWallpaper.Notification.ping, &pingToken, Lifecycle.queue) { _ in
            extensionLog("[Liveness] ping from LiveWall")
            Liveness.shared.report()
        }
        if stateStatus != NOTIFY_STATUS_OK || pingStatus != NOTIFY_STATUS_OK {
            extensionError("[State] notify registration failed (state \(stateStatus), ping \(pingStatus))")
        }

        _ = reload()
        let fm = FileManager.default
        let stateReadable = fm.isReadableFile(atPath: directory.appendingPathComponent(SharedWallpaper.stateFileName).path)
        extensionLog("[State] directory \(directory.path) — exists \(fm.fileExists(atPath: directory.path)), state.json readable \(stateReadable), log → \(FileLog.shared.currentPath)")
        extensionLog("[State] video \(state.file ?? "none") gravity \(state.gravity.rawValue) paused \(state.paused) \(state.pauseReasons)")
        Liveness.shared.recompute()
    }

    /// Re-read and apply. Lifecycle queue.
    func refresh(reason: String) {
        dispatchPrecondition(condition: .onQueue(Lifecycle.queue))
        let change = reload()
        if change.any {
            extensionLog("[State] \(reason): video \(state.file ?? "none")\(change.video ? " (changed)" : "") gravity \(state.gravity.rawValue) paused \(state.paused) \(state.pauseReasons)")
            SurfaceRegistry.shared.applySharedState(videoChanged: change.video, gravityChanged: change.gravity)
            if change.video {
                SettingsPush.invalidateSnapshots()
            }
            if change.video || change.thumbnail {
                SettingsPush.scheduleRefresh()
            }
        }
        // Whether the desktop shows LiveWall's video can change with any reload.
        Liveness.shared.recompute()
    }

    /// Read state.json and the thumbnail's stamp; returns what differs from before.
    private func reload() -> Change {
        dispatchPrecondition(condition: .onQueue(Lifecycle.queue))
        directory = Self.resolveDirectory()
        let fm = FileManager.default
        var next = SharedWallpaperState()
        var read = false
        let stateURL = directory.appendingPathComponent(SharedWallpaper.stateFileName, isDirectory: false)
        if let data = fm.contents(atPath: stateURL.path) {
            do {
                next = try SharedWallpaperState.decode(data)
                read = true
            } catch {
                extensionError("[State] state.json unreadable (\(error.localizedDescription)) — keeping the previous state")
                next = state
                read = stateRead
            }
        }
        var nextURL = next.videoURL(in: directory)
        if let url = nextURL, !fm.isReadableFile(atPath: url.path) {
            extensionError("[State] video file \(url.lastPathComponent) is not readable")
            nextURL = nil
        }

        let stamp: String? = {
            guard let attrs = try? fm.attributesOfItem(atPath: thumbnailURL.path) else { return nil }
            let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
            return "\(Int(modified * 1_000))-\(size)"
        }()

        var change = Change()
        change.video = nextURL != videoURL
        change.gravity = next.gravity != state.gravity
        change.paused = Self.isUserPaused(next) != Self.isUserPaused(state)
        change.thumbnail = stamp != thumbnailStamp
        state = next
        videoURL = nextURL
        stateRead = read
        thumbnailStamp = stamp
        return change
    }

    /// Identifies the current thumbnail (videoID + file stamp) for the tile cache.
    var thumbnailKey: String? {
        guard let thumbnailStamp else { return nil }
        let video = state.videoID.map { String($0.prefix(8)) } ?? "none"
        return "\(video)-\(thumbnailStamp)"
    }

    private static func resolveDirectory() -> URL {
        let shared = SharedWallpaper.defaultDirectory()
        let container = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Wallpaper", isDirectory: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: shared.appendingPathComponent(SharedWallpaper.stateFileName).path) {
            return shared
        }
        if fm.fileExists(atPath: container.appendingPathComponent(SharedWallpaper.stateFileName).path) {
            return container
        }
        return shared
    }
}

/// Liveness's decisions as a value: whether LiveWall counts as the selected desktop
/// wallpaper, given the surfaces, the shared state and display sleep. Liveness (below)
/// adds the side effects: the heartbeat, the notifications, the debounce timer. A plain
/// value, so event sequences can be checked on their own.
///
/// Active means a desktop surface is selected (SurfaceAgentState.isSelectedDesktop),
/// whether or not the agent draws it right now: a locked screen, a sleeping display or
/// a screen saver suspends or idles the surface but changes nothing here. Inactive
/// means every desktop surface was invalidated (another wallpaper picked) while the
/// displays were awake. A selected surface that can show only the fallback art (nothing
/// published yet, or the shared files unreadable) does not count.
///
/// Display sleep is only an input to this status, never a pause: WallpaperAgent may
/// invalidate (and, after the teardown grace, lose) surfaces while the displays sleep,
/// and nobody can pick another wallpaper then, so an active status holds until the
/// displays wake. After a wake the agent gets as long as a teardown grace to re-acquire
/// before an empty registry reads as a deselection, and a surface it acquires fresh on
/// the lock screen inherits the desktop status of its display (DesktopDisplayMemory).
struct LivenessState: Equatable {
    /// Surfaces can go briefly to zero during a Space switch or display reconfigure;
    /// only report inactive if that lasts.
    static let inactiveDebounce: TimeInterval = 2
    /// After the displays wake, how long the agent gets to re-acquire the surfaces it
    /// invalidated or tore down while they slept.
    static let wakeSettle: TimeInterval = Lifecycle.teardownGrace

    /// What the owner should do after an evaluation.
    enum Step: Equatable {
        /// Just became active: report it.
        case becomeActive
        /// Active and stays so: cancel a pending inactive.
        case stayActive
        /// Active but no longer selected: report inactive if that lasts this long (a
        /// debounce already running keeps its own deadline).
        case debounceInactive(TimeInterval)
        /// Inactive and stays so.
        case none
    }

    private(set) var isActive = false
    /// The displays are asleep (screensDidSleep until screensDidWake).
    private(set) var displaysAsleep = false
    /// When the displays last woke.
    private(set) var wokeAt: Date?

    /// The rule: LiveWall is the selected wallpaper of a desktop, and that desktop can
    /// show what LiveWall published. `holdThroughSleep` keeps the status whatever the
    /// surfaces say.
    static func shouldBeActive(_ surfaces: [SurfaceAgentState], canShowPublished: Bool,
                               holdThroughSleep: Bool = false) -> Bool {
        canShowPublished && (holdThroughSleep || surfaces.contains { $0.isSelectedDesktop })
    }

    /// How long "not selected" must last before reporting inactive: the usual debounce,
    /// or, within `wakeSettle` of the displays waking, the rest of that settle time.
    static func inactiveDelay(sinceWake: TimeInterval?) -> TimeInterval {
        guard let sinceWake, sinceWake >= 0, sinceWake < wakeSettle else { return inactiveDebounce }
        return max(inactiveDebounce, wakeSettle - sinceWake)
    }

    /// Already active while the displays sleep: an invalidate now is no deselection.
    var holdsThroughSleep: Bool { isActive && displaysAsleep }

    func shouldBeActive(_ surfaces: [SurfaceAgentState], canShowPublished: Bool) -> Bool {
        Self.shouldBeActive(surfaces, canShowPublished: canShowPublished, holdThroughSleep: holdsThroughSleep)
    }

    /// Re-derive after any input changed.
    mutating func evaluate(_ surfaces: [SurfaceAgentState], canShowPublished: Bool, now: Date) -> Step {
        if shouldBeActive(surfaces, canShowPublished: canShowPublished) {
            guard !isActive else { return .stayActive }
            isActive = true
            return .becomeActive
        }
        guard isActive else { return .none }
        return .debounceInactive(Self.inactiveDelay(sinceWake: wokeAt.map { now.timeIntervalSince($0) }))
    }

    /// The inactive debounce ran out: go inactive if still not selected (never while
    /// the displays sleep). Returns whether it went inactive.
    mutating func settle(_ surfaces: [SurfaceAgentState], canShowPublished: Bool) -> Bool {
        guard isActive, !shouldBeActive(surfaces, canShowPublished: canShowPublished) else { return false }
        isActive = false
        return true
    }

    /// screensDidSleep / screensDidWake. Returns whether anything changed.
    mutating func setDisplaysAsleep(_ asleep: Bool, now: Date) -> Bool {
        guard asleep != displaysAsleep else { return false }
        displaysAsleep = asleep
        if !asleep {
            wokeAt = now
        }
        return true
    }

    /// The agent just reported a non-preview surface in default mode, not suspended: it
    /// is drawing a desktop, so the displays are awake even if the wake notification was
    /// missed. Returns whether that cleared the asleep flag.
    mutating func noteAgentReport(isPreview: Bool, mode: String, suspended: Bool, now: Date) -> Bool {
        guard displaysAsleep, !isPreview, mode == "default", !suspended else { return false }
        return setDisplaysAsleep(false, now: now)
    }
}

/// Tells LiveWall whether it is the selected desktop wallpaper (LivenessState):
/// Darwin notifications plus a heartbeat (unix seconds) in the notify state of the
/// `active` name. LiveWall stands its own window down while this reports active; a
/// process that is gone stops beating. A selected surface that can show only the
/// fallback art asks LiveWall to publish instead. Lifecycle queue.
@available(macOS 26.0, *)
final class Liveness {
    static let shared = Liveness()

    private var activeToken: Int32 = NOTIFY_TOKEN_INVALID
    private var state = LivenessState()
    /// A desktop surface is selected but shows only the fallback art.
    private var isWaitingForHost = false
    /// Active only because of the sleep hold (for the log).
    private var isHoldingThroughSleep = false
    private var heartbeat: DispatchSourceTimer?
    private var pendingInactive: DispatchWorkItem?
    private var setStateFailureLogged = false
    /// Main thread only.
    private var sleepObservers: [NSObjectProtocol] = []

    private init() {}

    func start() {
        dispatchPrecondition(condition: .onQueue(Lifecycle.queue))
        let status = notify_register_check(SharedWallpaper.Notification.active, &activeToken)
        if status != NOTIFY_STATUS_OK {
            extensionError("[Liveness] notify_register_check failed (\(status))")
        }
        // A fresh process is not active until a desktop surface is acquired.
        setHeartbeat(0)
        DispatchQueue.main.async { self.observeDisplaySleep() }
    }

    /// Display sleep and wake, as liveness inputs only (never a pause). Main thread.
    private func observeDisplaySleep() {
        guard sleepObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        sleepObservers = [
            center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { _ in
                Lifecycle.queue.async { Liveness.shared.setDisplaysAsleep(true) }
            },
            center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in
                Lifecycle.queue.async { Liveness.shared.setDisplaysAsleep(false) }
            },
        ]
    }

    private func setDisplaysAsleep(_ asleep: Bool) {
        dispatchPrecondition(condition: .onQueue(Lifecycle.queue))
        guard state.setDisplaysAsleep(asleep, now: Date()) else { return }
        if asleep {
            extensionLog("[Liveness] displays asleep — \(state.isActive ? "holding ACTIVE until they wake (an invalidate now is no deselection)" : "inactive")")
        } else {
            extensionLog("[Liveness] displays awake — the agent gets \(Int(LivenessState.wakeSettle)) s to re-acquire before LiveWall counts as deselected")
        }
        recompute()
    }

    /// See LivenessState.noteAgentReport. Callers recompute afterwards.
    func noteAgentReport(isPreview: Bool, mode: String, suspended: Bool) {
        dispatchPrecondition(condition: .onQueue(Lifecycle.queue))
        if state.noteAgentReport(isPreview: isPreview, mode: mode, suspended: suspended, now: Date()) {
            extensionLog("[Liveness] the agent is drawing a desktop — displays awake")
        }
    }

    /// A selected desktop can show what LiveWall published: the current video (or its
    /// deliberate absence), or the library video its tile names.
    private var canShowPublished: Bool {
        SharedStateStore.shared.canShowPublishedWallpaper || SurfaceRegistry.shared.hasSelectedDesktopPlayingLibraryVideo
    }

    /// Re-derive the status from the surfaces and the shared state, and report what each
    /// desktop plays. Lifecycle queue.
    func recompute() {
        dispatchPrecondition(condition: .onQueue(Lifecycle.queue))
        defer { PlayingReport.shared.update() }
        let registry = SurfaceRegistry.shared
        registry.rememberSelectedDesktops()
        let selected = registry.hasSelectedDesktopSurface
        let store = SharedStateStore.shared
        let canShow = canShowPublished
        let waiting = selected && !canShow
        if waiting != isWaitingForHost {
            isWaitingForHost = waiting
            if waiting {
                extensionLog("[Liveness] LiveWall is the selected wallpaper but its video can't be shown (state.json read \(store.stateRead), video \(store.state.file ?? "none"), readable \(store.videoURL != nil)) — not reporting active; asking LiveWall to publish")
                notify_post(SharedWallpaper.Notification.request)
            }
        }
        let holding = state.holdsThroughSleep && !selected && canShow
        if holding != isHoldingThroughSleep {
            isHoldingThroughSleep = holding
            if holding {
                extensionLog("[Liveness] no selected desktop surface while the displays sleep — staying ACTIVE until they wake")
            }
        }
        switch state.evaluate(registry.agentStates, canShowPublished: canShow, now: Date()) {
        case .becomeActive:
            pendingInactive?.cancel()
            pendingInactive = nil
            extensionLog("[Liveness] ACTIVE — LiveWall is the selected desktop wallpaper")
            beat()
            startHeartbeat()
        case .stayActive:
            pendingInactive?.cancel()
            pendingInactive = nil
        case let .debounceInactive(delay):
            guard pendingInactive == nil else { break }
            let work = DispatchWorkItem { [weak self] in self?.goInactiveIfStillIdle() }
            pendingInactive = work
            Lifecycle.queue.asyncAfter(deadline: .now() + delay, execute: work)
        case .none:
            break
        }
    }

    /// Answer a ping: repeat the current status. An inactive process leaves the shared
    /// heartbeat alone: it already cleared it when it went inactive, and clearing it again
    /// would clobber another, active extension process's beat.
    func report() {
        dispatchPrecondition(condition: .onQueue(Lifecycle.queue))
        if state.isActive {
            beat()
        } else {
            notify_post(SharedWallpaper.Notification.inactive)
            if isWaitingForHost {
                notify_post(SharedWallpaper.Notification.request)
            }
        }
    }

    private func goInactiveIfStillIdle() {
        pendingInactive = nil
        guard state.settle(SurfaceRegistry.shared.agentStates, canShowPublished: canShowPublished) else { return }
        heartbeat?.cancel()
        heartbeat = nil
        setHeartbeat(0)
        notify_post(SharedWallpaper.Notification.inactive)
        // The displays are awake (the sleep hold would have kept the status), so the
        // displays without a selected desktop surface really were deselected.
        SurfaceRegistry.shared.forgetDeselectedDisplays()
        extensionLog("[Liveness] INACTIVE — \(isWaitingForHost ? "LiveWall's video can't be shown" : "no desktop has LiveWall selected")")
    }

    private func startHeartbeat() {
        heartbeat?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: Lifecycle.queue)
        let interval = SharedWallpaper.heartbeatInterval
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self, self.state.isActive else { return }
            self.beat()
        }
        heartbeat = timer
        timer.resume()
    }

    private func beat() {
        setHeartbeat(UInt64(Date().timeIntervalSince1970))
        notify_post(SharedWallpaper.Notification.active)
    }

    private func setHeartbeat(_ value: UInt64) {
        guard activeToken != NOTIFY_TOKEN_INVALID else { return }
        let status = notify_set_state(activeToken, value)
        if status != NOTIFY_STATUS_OK, !setStateFailureLogged {
            setStateFailureLogged = true
            extensionError("[Liveness] notify_set_state failed (\(status)) — LiveWall falls back to the notifications alone")
        }
    }
}
