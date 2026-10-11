import AppKit
import AVFoundation
import LiveWallShared

/// A borderless window pinned at desktop level, behind icons, on every Space.
final class WallpaperWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        isOpaque = true
        hasShadow = false
        backgroundColor = .black
        isReleasedWhenClosed = false
        animationBehavior = .none
        setFrame(screen.frame, display: true)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Layer-hosting view whose backing layer is an AVPlayerLayer; geometry stays in sync automatically.
final class PlayerView: NSView {
    let playerLayer: AVPlayerLayer

    init(player: AVPlayer, gravity: AVLayerVideoGravity) {
        playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = gravity
        super.init(frame: .zero)
        layer = playerLayer
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// One shared player drives an AVPlayerLayer per screen — a single decode pipeline
/// no matter how many displays are attached.
///
/// On macOS 26+ the engine can stand down: while LiveWall's system wallpaper extension
/// is the selected wallpaper (see SystemWallpaperBridge), the windows are closed and
/// the player released, so the video is decoded once, by the extension. The engine
/// still tracks the current video, scaling and the user's Pause, which the bridge
/// relays. The automatic pauses (hidden, Low Power Mode, display sleep, screen lock,
/// another user) apply only to the engine's own windows: macOS alone decides when the
/// system wallpaper is drawn.
final class WallpaperEngine: NSObject {
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var windows: [WallpaperWindow] = []

    /// The video being shown (by the engine's windows or, standing down, by the extension).
    private(set) var currentURL: URL?
    /// The system wallpaper extension is drawing the desktop; no windows, no player.
    private(set) var isStandingDown = false
    /// The user removed the wallpaper ("Remove Wallpaper"), as opposed to no video having
    /// been loaded yet this launch. Only then is "no video" worth telling the extension.
    private(set) var videoWasRemoved = false

    /// User pressed pause in the menu.
    private(set) var userPaused = false
    /// Set while the system says we shouldn't burn cycles (locked, asleep, hidden, low
    /// power). Tracked while standing down too, so the windows come back in the right
    /// state, but never relayed to the system wallpaper.
    private var systemPauseReasons = Set<String>()

    private var stateObservers: [() -> Void] = []
    var hasVideo: Bool { currentURL != nil }
    /// LiveWall's own wallpaper windows are up.
    var isShowingWindows: Bool { !windows.isEmpty }

    /// Called on the main thread after any change to the video, playback or pause state.
    func addStateObserver(_ observer: @escaping () -> Void) {
        stateObservers.append(observer)
    }

    private func notifyStateChange() {
        stateObservers.forEach { $0() }
    }

    private static let pauseReasonNames: [(reason: String, name: String)] = [
        ("hidden", "Wallpaper Hidden"), ("lowPower", "Low Power Mode"),
        ("displaySleep", "Display Asleep"), ("locked", "Screen Locked"),
        ("inactiveSession", "Another User Active"),
    ]

    /// Nothing on screen could show LiveWall's own window right now: the screen is
    /// locked, the displays are asleep, or another user's session is active. Tracked
    /// while standing down too. The bridge uses it only to time standing back up; it is
    /// never a pause of the system wallpaper.
    var isScreenUnavailable: Bool {
        !systemPauseReasons.isDisjoint(with: ["locked", "displaySleep", "inactiveSession"])
    }

    /// Why the system is holding LiveWall's own window, for display in the menu; nil
    /// when it isn't, and while standing down (the system wallpaper has no automatic
    /// pauses of LiveWall's).
    var systemPauseDescription: String? {
        guard !isStandingDown else { return nil }
        let active = Self.pauseReasonNames.filter { systemPauseReasons.contains($0.reason) }.map(\.name)
        return active.isEmpty ? nil : active.joined(separator: ", ")
    }

    override init() {
        super.init()

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(screensChanged),
                       name: NSApplication.didChangeScreenParametersNotification, object: nil)
        nc.addObserver(self, selector: #selector(occlusionChanged(_:)),
                       name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        nc.addObserver(self, selector: #selector(powerStateChanged),
                       name: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil)

        let wnc = NSWorkspace.shared.notificationCenter
        wnc.addObserver(self, selector: #selector(screensDidSleep),
                        name: NSWorkspace.screensDidSleepNotification, object: nil)
        wnc.addObserver(self, selector: #selector(screensDidWake),
                        name: NSWorkspace.screensDidWakeNotification, object: nil)
        // Fast user switching: don't keep decoding while another user has the screen.
        wnc.addObserver(self, selector: #selector(sessionResigned),
                        name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        wnc.addObserver(self, selector: #selector(sessionBecameActive),
                        name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)

        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(screenLocked),
                        name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        dnc.addObserver(self, selector: #selector(screenUnlocked),
                        name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)

        // The power notification only reports changes, so seed the state at launch.
        if Settings.shared.pauseOnLowPower && ProcessInfo.processInfo.isLowPowerModeEnabled {
            systemPauseReasons.insert("lowPower")
        }
    }

    // MARK: - Loading

    func load(url: URL) {
        currentURL = url
        videoWasRemoved = false
        Settings.shared.videoURL = url
        Settings.shared.addRecent(url)
        userPaused = false

        if isStandingDown {
            // The extension plays it; the bridge publishes the change.
            applyPlaybackState()
            return
        }
        makePlayer(for: url)
        rebuildWindows()
        applyPlaybackState()
    }

    func stop() {
        releasePlayer()
        currentURL = nil
        videoWasRemoved = true
        Settings.shared.videoURL = nil
        notifyStateChange()
    }

    private func makePlayer(for url: URL) {
        // Stop the outgoing video explicitly so its audio/decode can't overlap the new one.
        player?.pause()

        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        let newPlayer = AVQueuePlayer()
        newPlayer.isMuted = Settings.shared.muted
        newPlayer.preventsDisplaySleepDuringVideoPlayback = false
        newPlayer.actionAtItemEnd = .advance
        looper = AVPlayerLooper(player: newPlayer, templateItem: item)
        player = newPlayer
    }

    private func releasePlayer() {
        player?.pause()
        looper = nil
        player = nil
        windows.forEach { $0.orderOut(nil) }
        windows = []
    }

    // MARK: - System wallpaper hand-off (macOS 26+)

    /// Close the windows and release the player while LiveWall is the selected system
    /// wallpaper; rebuild and resume, under the engine's own pauses, when it no longer is.
    func setStandingDown(_ standDown: Bool) {
        guard standDown != isStandingDown else { return }
        isStandingDown = standDown
        // "hidden" is the occlusion of the engine's own windows, which are closed while
        // standing down and rebuilt (and re-checked) when it stands up.
        systemPauseReasons.remove("hidden")
        if standDown {
            releasePlayer()
        } else if let url = currentURL {
            makePlayer(for: url)
            rebuildWindows()
        }
        applyPlaybackState()
    }

    /// What the system wallpaper extension should show: the current video, scaling, and
    /// the user's own Pause. Only that: LiveWall adds no pauses to the system wallpaper,
    /// which macOS stops drawing by itself whenever it cannot be seen.
    var publication: WallpaperPublication {
        WallpaperPublication(
            videoURL: currentURL,
            gravity: Self.sharedGravity(Settings.shared.gravity),
            paused: userPaused,
            pauseReasons: userPaused ? ["user"] : []
        )
    }

    private static func sharedGravity(_ gravity: AVLayerVideoGravity) -> SharedGravity {
        switch gravity {
        case .resizeAspect: return .fit
        case .resize: return .stretch
        default: return .fill
        }
    }

    // MARK: - Playback control

    /// Flips the user's intent, independent of any system pause — so "Pause" during
    /// Low Power Mode sticks, and "Play" is never a silent no-op.
    func togglePlayPause() {
        userPaused.toggle()
        applyPlaybackState()
    }

    func setMuted(_ muted: Bool) {
        Settings.shared.muted = muted
        player?.isMuted = muted
    }

    func setGravity(_ gravity: AVLayerVideoGravity) {
        Settings.shared.gravity = gravity
        for window in windows {
            (window.contentView as? PlayerView)?.playerLayer.videoGravity = gravity
        }
        notifyStateChange()
    }

    private func applyPlaybackState() {
        if let player {
            let shouldPlay = !userPaused && systemPauseReasons.isEmpty
            if shouldPlay {
                if player.rate == 0 { player.play() }
            } else {
                if player.rate != 0 { player.pause() }
            }
        }
        notifyStateChange()
    }

    /// Internal so tests can set a reason directly.
    func setSystemPause(_ reason: String, _ active: Bool) {
        if active { systemPauseReasons.insert(reason) } else { systemPauseReasons.remove(reason) }
        applyPlaybackState()
    }

    // MARK: - Windows

    private func rebuildWindows() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        guard let player else { return }

        for screen in NSScreen.screens {
            let window = WallpaperWindow(screen: screen)
            window.contentView = PlayerView(player: player, gravity: Settings.shared.gravity)
            window.orderFront(nil)
            windows.append(window)
        }
    }

    // MARK: - System events

    @objc private func screensChanged() {
        guard player != nil, !isStandingDown else { return }
        rebuildWindows()
        applyPlaybackState()
    }

    @objc private func occlusionChanged(_ note: Notification) {
        guard Settings.shared.pauseWhenHidden, !isStandingDown,
              let window = note.object as? WallpaperWindow, windows.contains(window) else { return }
        let anyVisible = windows.contains { $0.occlusionState.contains(.visible) }
        setSystemPause("hidden", !anyVisible)
    }

    @objc private func powerStateChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            self.setSystemPause("lowPower", Settings.shared.pauseOnLowPower && lowPower)
        }
    }

    /// Re-evaluate the low-power pause after the user flips the setting.
    func refreshPowerState() { powerStateChanged() }

    /// Re-evaluate the occlusion pause after the user flips the setting. Standing down
    /// there are no windows, so nothing is hidden.
    func refreshOcclusionState() {
        guard Settings.shared.pauseWhenHidden else {
            setSystemPause("hidden", false)
            return
        }
        let anyVisible = windows.contains { $0.occlusionState.contains(.visible) }
        setSystemPause("hidden", !anyVisible && !windows.isEmpty)
    }

    @objc private func screensDidSleep() { setSystemPause("displaySleep", true) }
    @objc private func screensDidWake() { setSystemPause("displaySleep", false) }
    @objc private func screenLocked() { setSystemPause("locked", true) }
    @objc private func screenUnlocked() { setSystemPause("locked", false) }
    @objc private func sessionResigned() { setSystemPause("inactiveSession", true) }
    @objc private func sessionBecameActive() { setSystemPause("inactiveSession", false) }
}
