import AppKit
import AVFoundation

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
final class WallpaperEngine: NSObject {
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var windows: [WallpaperWindow] = []

    /// User pressed pause in the menu.
    private(set) var userPaused = false
    /// Set while the system says we shouldn't burn cycles (locked, asleep, hidden, low power).
    private var systemPauseReasons = Set<String>()

    var onStateChange: (() -> Void)?
    var hasVideo: Bool { player != nil }

    private static let pauseReasonNames: [(reason: String, name: String)] = [
        ("hidden", "Wallpaper Hidden"), ("lowPower", "Low Power Mode"),
        ("displaySleep", "Display Asleep"), ("locked", "Screen Locked"),
        ("inactiveSession", "Another User Active"),
    ]

    /// Why the system is holding playback, for display in the menu; nil when it isn't.
    var systemPauseDescription: String? {
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
        // Stop the outgoing video explicitly so its audio/decode can't overlap the new one.
        player?.pause()

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        let newPlayer = AVQueuePlayer()
        newPlayer.isMuted = Settings.shared.muted
        newPlayer.preventsDisplaySleepDuringVideoPlayback = false
        newPlayer.actionAtItemEnd = .advance
        looper = AVPlayerLooper(player: newPlayer, templateItem: item)
        player = newPlayer

        Settings.shared.videoURL = url
        Settings.shared.addRecent(url)

        rebuildWindows()
        userPaused = false
        applyPlaybackState()
    }

    func stop() {
        player?.pause()
        looper = nil
        player = nil
        windows.forEach { $0.orderOut(nil) }
        windows = []
        Settings.shared.videoURL = nil
        onStateChange?()
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
    }

    private func applyPlaybackState() {
        guard let player else { return }
        let shouldPlay = !userPaused && systemPauseReasons.isEmpty
        if shouldPlay {
            if player.rate == 0 { player.play() }
        } else {
            if player.rate != 0 { player.pause() }
        }
        onStateChange?()
    }

    private func setSystemPause(_ reason: String, _ active: Bool) {
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
        guard hasVideo else { return }
        rebuildWindows()
        applyPlaybackState()
    }

    @objc private func occlusionChanged(_ note: Notification) {
        guard Settings.shared.pauseWhenHidden,
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

    /// Re-evaluate the occlusion pause after the user flips the setting.
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
