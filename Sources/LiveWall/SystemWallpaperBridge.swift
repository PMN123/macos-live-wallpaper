import AppKit
import LiveWallShared
import notify
import os

/// macOS 26+: hands playback to LiveWall's system wallpaper extension.
///
/// - Dormant until system wallpaper mode is on (Settings.systemWallpaperEnabled): the
///   user chose "Use as System Wallpaper…", or picked the LiveWall tile (the extension
///   then reports active, or asks for the wallpaper with its `request` notification).
///   Until then nothing is cloned, decoded or written, and nothing polls.
/// - While on, publishes the engine's video, scaling and the user's Pause to the shared
///   directory (SharedWallpaperStore) on every change. Nothing else: LiveWall adds no
///   automatic pauses to the system wallpaper. macOS decides when it is drawn, as for
///   its own video wallpapers.
/// - Tracks whether LiveWall is the selected system wallpaper (the extension's Darwin
///   notifications plus a heartbeat in the notify state; stale after 20 s) and, while
///   it is, stands the engine down so the video is decoded once. The extension stays
///   active while the screen is locked, asleep or under a screen saver; it goes
///   inactive only when every desktop picked another wallpaper, or its process is gone.
///   Then the engine's windows come back after a grace period longer than the
///   heartbeat interval (pinging the extension first), and system wallpaper mode turns
///   off again. The engine's own pauses (locked, asleep, hidden…) govern those windows.
/// - Standing back up waits while nothing could show the engine's window: the screen
///   locked, the displays asleep, another user's session (WallpaperEngine
///   .isScreenUnavailable). Nobody can pick another wallpaper then, and WallpaperAgent
///   may drop the extension's surfaces in those states, so the extension going quiet is
///   no sign it was deselected. This only times LiveWall's own window; it never pauses
///   the system wallpaper. Unlock, wake and the session coming back re-run the check.
/// - Standing down is all or nothing across displays: the extension reports one
///   process-wide status, not which displays it draws.
///
/// Created only on macOS 26 or later; nothing here runs on older systems.
final class SystemWallpaperBridge {
    /// The extension's Darwin notification names. Tests pass private names so they
    /// never talk to a real extension.
    struct Notifications {
        var active = SharedWallpaper.Notification.active
        var inactive = SharedWallpaper.Notification.inactive
        var ping = SharedWallpaper.Notification.ping
        var request = SharedWallpaper.Notification.request
    }

    private static let logger = Logger(subsystem: "com.praniil.livewall", category: "system-wallpaper")

    private let engine: WallpaperEngine
    private let store: SharedWallpaperStore
    private let names: Notifications
    /// Wait this long after the extension goes quiet before rebuilding the windows, so
    /// a display reconfigure or a re-pick (brief gaps in liveness) costs nothing.
    /// Longer than the heartbeat interval, so a stray "inactive" is contradicted by the
    /// next beat before anything is rebuilt.
    private let standUpGrace: TimeInterval

    private var stateToken: Int32 = NOTIFY_TOKEN_INVALID
    private var activeToken: Int32 = NOTIFY_TOKEN_INVALID
    private var inactiveToken: Int32 = NOTIFY_TOKEN_INVALID
    private var requestToken: Int32 = NOTIFY_TOKEN_INVALID
    private var lastActiveNotification: Date?
    private var lastInactiveNotification: Date?
    private var timer: Timer?
    private var standUpWork: DispatchWorkItem?
    private var lastPublication: WallpaperPublication?
    private var lastScreenUnavailable = false
    private var started = false

    /// LiveWall is the selected system wallpaper (the extension reports active), whether
    /// or not macOS is drawing it right now.
    private(set) var isExtensionActive = false
    /// Called on the main thread when `isExtensionActive` changes.
    var onStatusChange: (() -> Void)?
    /// The heartbeat poll is running (diagnostics, tests).
    var isPolling: Bool { timer != nil }

    init(engine: WallpaperEngine,
         store: SharedWallpaperStore? = nil,
         notifications: Notifications = Notifications(),
         standUpGrace: TimeInterval = SharedWallpaper.heartbeatInterval + 1) {
        self.engine = engine
        self.store = store ?? SharedWallpaperStore(log: { SystemWallpaperBridge.logger.notice("\($0, privacy: .public)") })
        self.names = notifications
        self.standUpGrace = standUpGrace
    }

    /// Start tracking (and, while system wallpaper mode is on, publishing). Call before
    /// restoring the last video, so a running extension is detected first and the
    /// engine never opens a window it would close.
    func start() {
        guard !started else { return }
        started = true

        notify_register_check(names.active, &stateToken)
        notify_register_dispatch(names.active, &activeToken, .main) { [weak self] _ in
            self?.lastActiveNotification = Date()
            self?.evaluate()
        }
        notify_register_dispatch(names.inactive, &inactiveToken, .main) { [weak self] _ in
            self?.lastInactiveNotification = Date()
            self?.evaluate()
        }
        notify_register_dispatch(names.request, &requestToken, .main) { [weak self] _ in
            // The LiveWall tile is on screen with nothing to show.
            self?.enableSystemWallpaperMode(reason: "the wallpaper extension asked for the video")
        }

        lastScreenUnavailable = engine.isScreenUnavailable
        engine.addStateObserver { [weak self] in
            guard let self else { return }
            self.publishCurrentState()
            // Unlock, wake or the session coming back: a deferred stand-up can go ahead.
            let unavailable = self.engine.isScreenUnavailable
            if unavailable != self.lastScreenUnavailable {
                self.lastScreenUnavailable = unavailable
                self.evaluate()
            }
        }

        evaluate()
        // Ask a running extension to report now rather than at its next heartbeat.
        notify_post(names.ping)
        // Nothing is published until the engine has a video (or the user removes it):
        // at launch the last video is restored right after this.
    }

    /// Turn system wallpaper mode on (if it is not already) and publish the current
    /// state, so the extension has the video at once.
    func enableSystemWallpaperMode(reason: String) {
        if !Settings.shared.systemWallpaperEnabled {
            Settings.shared.systemWallpaperEnabled = true
            Self.logger.notice("system wallpaper mode on: \(reason, privacy: .public)")
        }
        publishCurrentState(force: true)
    }

    /// LiveWall is quitting: the extension keeps playing on its own, with the user's
    /// own Pause (the only pause LiveWall ever publishes). Puts the latest state on disk
    /// without waiting long behind a clone or thumbnail still in progress.
    func applicationWillTerminate() {
        guard Settings.shared.systemWallpaperEnabled else { return }
        let publication = engine.publication
        guard isPublishable(publication) else { return }
        store.publishForTermination(publication)
    }

    // MARK: - Publishing

    /// "No video" is published only when the user removed the wallpaper. Before the
    /// last video is restored at launch (or when its file has gone missing) the engine
    /// has no video either, and publishing that would blank a wallpaper the extension
    /// can keep playing from its own clone.
    private func isPublishable(_ publication: WallpaperPublication) -> Bool {
        publication.videoURL != nil || engine.videoWasRemoved
    }

    /// Publish the engine's state while system wallpaper mode is on. `force` publishes
    /// even if nothing changed since the last publication (mode just turned on).
    private func publishCurrentState(force: Bool = false) {
        guard Settings.shared.systemWallpaperEnabled else { return }
        let publication = engine.publication
        guard isPublishable(publication), force || publication != lastPublication else { return }
        lastPublication = publication
        store.publish(publication)
    }

    // MARK: - Liveness

    /// The extension's latest sign of life, or nil if it said it went inactive since.
    private func latestHeartbeat() -> Date? {
        var beat = lastActiveNotification
        var value: UInt64 = 0
        if stateToken != NOTIFY_TOKEN_INVALID,
           notify_get_state(stateToken, &value) == NOTIFY_STATUS_OK, value > 0 {
            let stateBeat = Date(timeIntervalSince1970: TimeInterval(value))
            if beat.map({ stateBeat > $0 }) ?? true {
                beat = stateBeat
            }
        }
        guard let beat else { return nil }
        if let inactive = lastInactiveNotification, inactive >= beat {
            return nil
        }
        return beat
    }

    private var heartbeatIsFresh: Bool {
        guard let beat = latestHeartbeat() else { return false }
        return Date().timeIntervalSince(beat) <= SharedWallpaper.heartbeatStaleAfter
    }

    private func evaluate() {
        defer { updatePolling() }
        let active = heartbeatIsFresh
        if active != isExtensionActive {
            isExtensionActive = active
            Self.logger.notice("system wallpaper extension \(active ? "active" : "inactive", privacy: .public)")
            onStatusChange?()
        }

        if active {
            standUpWork?.cancel()
            standUpWork = nil
            if !Settings.shared.systemWallpaperEnabled {
                // The user picked the LiveWall tile without LiveWall's menu.
                enableSystemWallpaperMode(reason: "LiveWall is the selected wallpaper")
            }
            if !engine.isStandingDown {
                engine.setStandingDown(true)
            }
            return
        }

        guard engine.isStandingDown, standUpWork == nil else { return }
        // Decide once LiveWall's window could be seen again (see the type comment).
        guard !engine.isScreenUnavailable else { return }
        // A live extension answers a ping with a beat at once, which cancels this.
        notify_post(names.ping)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.standUpWork = nil
            guard !self.heartbeatIsFresh, self.engine.isStandingDown, !self.engine.isScreenUnavailable else { return }
            Self.logger.notice("system wallpaper extension stopped; resuming LiveWall's own window")
            self.engine.setStandingDown(false)
            // Another wallpaper was picked (or the extension is gone): stop sharing the
            // video until the LiveWall tile is in use again.
            Settings.shared.systemWallpaperEnabled = false
            Self.logger.notice("system wallpaper mode off")
            self.updatePolling()
        }
        standUpWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + standUpGrace, execute: work)
    }

    /// Poll the heartbeat only while it matters: the extension reports active, or the
    /// engine is standing down. Otherwise an extension coming up posts `active` itself.
    private func updatePolling() {
        let needed = isExtensionActive || engine.isStandingDown
        if needed, timer == nil {
            let poll = Timer(timeInterval: SharedWallpaper.heartbeatInterval, repeats: true) { [weak self] _ in
                self?.evaluate()
            }
            poll.tolerance = 1
            RunLoop.main.add(poll, forMode: .common)
            timer = poll
        } else if !needed, let poll = timer {
            poll.invalidate()
            timer = nil
        }
    }

    // MARK: - "Use as System Wallpaper…"

    private static let wallpaperSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")

    /// Turn system wallpaper mode on, register and enable the extension if needed, open
    /// System Settings > Wallpaper and tell the user what to pick there. LiveWall never
    /// edits the wallpaper store.
    func useAsSystemWallpaper() {
        enableSystemWallpaperMode(reason: "Use as System Wallpaper…")
        let bundleURL = Bundle.main.bundleURL
        let appexURL = bundleURL
            .appendingPathComponent("Contents/Extensions/LiveWallWallpaper.appex", isDirectory: true)
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = ExtensionRegistration.ensureEnabled(appexURL: appexURL)
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                if case let .failed(message) = outcome {
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "Couldn’t enable LiveWall’s system wallpaper"
                    alert.informativeText = message
                    alert.runModal()
                    return
                }
                if let url = Self.wallpaperSettingsURL {
                    NSWorkspace.shared.open(url)
                }
                let alert = NSAlert()
                alert.messageText = "Choose LiveWall in Wallpaper settings"
                var text = "In System Settings › Wallpaper, pick the “LiveWall” tile, then turn on “Show on all Spaces”. "
                text += "With more than one display, pick LiveWall for every display: while it plays as the system wallpaper, LiveWall closes its own window on all of them.\n\n"
                text += "macOS then plays your video as the real wallpaper, including behind the menu bar and on the lock screen, without sound.\n\n"
                text += "To go back, pick any other wallpaper there."
                if case .registered = outcome {
                    text += "\n\nIf the LiveWall tile isn’t listed yet, quit System Settings and open it again."
                }
                if case let .otherCopy(path) = outcome {
                    text += "\n\nmacOS is using the wallpaper extension of another LiveWall copy:\n\(path)\nDelete that copy, or unregister it in Terminal with: pluginkit -r \"\(path)\""
                }
                if !Self.isInApplicationsFolder(bundleURL) {
                    text += "\n\nLiveWall is running from \(bundleURL.deletingLastPathComponent().path). macOS plays the wallpaper from this copy, so keep it there, or install LiveWall in Applications and choose this again from that copy."
                }
                alert.informativeText = text
                alert.runModal()
            }
        }
    }

    private static func isInApplicationsFolder(_ bundleURL: URL) -> Bool {
        let path = bundleURL.resolvingSymlinksInPath().path
        let userApplications = SharedWallpaper.realHomeDirectory().appendingPathComponent("Applications").path
        return path.hasPrefix("/Applications/") || path.hasPrefix(userApplications + "/")
    }
}

/// Registers LiveWall's wallpaper extension with PlugInKit, only when needed:
/// re-registering an extension that is already enabled can make macOS drop it for
/// a while.
enum ExtensionRegistration {
    enum Outcome {
        case alreadyEnabled
        /// Enabled now (it was registered but disabled).
        case enabled
        /// Added from this app bundle and enabled.
        case registered
        /// PlugInKit uses another copy of the extension (path), even after this one was
        /// added: for example a build folder registered before installing.
        case otherCopy(String)
        case failed(String)
    }

    /// What `pluginkit -m -v -i <id>` reports for the extension.
    struct Registration: Equatable {
        /// Elected for use ("+").
        var enabled: Bool
        /// The registered bundle's path, when listed.
        var path: String?
    }

    private static let pluginkit = URL(fileURLWithPath: "/usr/bin/pluginkit")

    static func ensureEnabled(appexURL: URL) -> Outcome {
        let id = SharedWallpaper.extensionBundleID
        let ours = canonicalPath(appexURL.path)
        if let current = registration(of: id), current.path.map(canonicalPath) ?? ours == ours {
            // This copy is the registered one.
            if current.enabled {
                return .alreadyEnabled
            }
            _ = run(["-e", "use", "-i", id])
            return registration(of: id)?.enabled == true ? .enabled : .failed("PlugInKit did not enable \(id).")
        }

        // Not registered, or registered from another copy: add this one.
        guard FileManager.default.fileExists(atPath: appexURL.path) else {
            return .failed("This copy of LiveWall has no wallpaper extension. Build it with ./build.sh and run LiveWall from that build.")
        }
        let add = run(["-a", appexURL.path])
        guard add.status == 0 else {
            return .failed("pluginkit could not register the extension: \(add.output.isEmpty ? "exit \(add.status)" : add.output)")
        }
        _ = run(["-e", "use", "-i", id])
        guard let after = registration(of: id) else {
            return .failed("PlugInKit did not list the extension after registering it.")
        }
        if let path = after.path, canonicalPath(path) != ours {
            return .otherCopy(path)
        }
        return after.enabled ? .registered : .failed("The extension was registered but PlugInKit did not enable it.")
    }

    /// `pluginkit -m -v -i <id>` prints one line per match, led by its election ("+" in
    /// use, "-" ignored, "=" superseded, "!" debugging) and ending with the bundle path.
    private static func registration(of id: String) -> Registration? {
        parseRegistration(run(["-m", "-v", "-i", id]).output, id: id)
    }

    /// Parse `pluginkit -m -v` output. Prefers the elected line when several copies are
    /// listed. Internal for tests.
    static func parseRegistration(_ output: String, id: String) -> Registration? {
        let lines = output.split(separator: "\n").map(String.init).filter { $0.contains(id) }
        guard let line = lines.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("+") }) ?? lines.first else {
            return nil
        }
        let enabled = line.trimmingCharacters(in: .whitespaces).hasPrefix("+")
        let fields = line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
        var path = fields.last(where: { $0.hasPrefix("/") })
        if path == nil, let slash = line.firstIndex(of: "/") {
            path = line[slash...].trimmingCharacters(in: .whitespaces)
        }
        return Registration(enabled: enabled, path: path)
    }

    private static func canonicalPath(_ path: String) -> String {
        var result = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        while result.count > 1, result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }

    private static func run(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = pluginkit
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, output)
    }
}
