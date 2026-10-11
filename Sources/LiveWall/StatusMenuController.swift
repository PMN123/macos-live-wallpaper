import AppKit
import AVFoundation
import ServiceManagement
import UniformTypeIdentifiers

/// The menu bar item — the app's entire UI.
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let engine: WallpaperEngine
    /// Present on macOS 26 and later only.
    private let systemWallpaper: SystemWallpaperBridge?
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private lazy var libraryWC = LibraryWindowController(engine: engine, systemWallpaper: systemWallpaper)
    /// Shown in the menu until it next closes: a video picked in LiveWall changes no
    /// desktop, because each uses a fixed library tile (once per launch).
    private var showFixedTileHint = false
    /// The open menu shows that hint.
    private var menuShowsFixedTileHint = false

    init(engine: WallpaperEngine, systemWallpaper: SystemWallpaperBridge?) {
        self.engine = engine
        self.systemWallpaper = systemWallpaper
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            configureStatusBarButton(button)
        }
        menu.delegate = self
        statusItem.menu = menu
        engine.addStateObserver { [weak self] in self?.rebuildMenu() }
        systemWallpaper?.onStatusChange = { [weak self] in
            self?.rebuildMenu()
            self?.libraryWC.systemWallpaperStatusChanged()
        }
        rebuildMenu()
    }

    /// Picks the first SF Symbol that exists on this OS, marks it template (required
    /// for menu-bar contrast), and falls back to a text glyph if none load.
    private func configureStatusBarButton(_ button: NSStatusBarButton) {
        let candidates = ["sparkles.tv", "tv", "sparkles", "play.rectangle"]
        for name in candidates {
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: "LiveWall") {
                image.isTemplate = true
                button.image = image
                return
            }
        }
        button.title = "✦"
    }

    /// Opens the Video Library window — used on first launch and from the menu.
    func showLibrary() { libraryWC.show() }

    // MARK: - Menu construction

    func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu() }

    func menuWillOpen(_ menu: NSMenu) {
        menuShowsFixedTileHint = showFixedTileHint
    }

    /// Clears the hint once a menu showing it closes (not the close that comes with the
    /// pick that armed it).
    func menuDidClose(_ menu: NSMenu) {
        guard menuShowsFixedTileHint else { return }
        menuShowsFixedTileHint = false
        showFixedTileHint = false
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        let s = Settings.shared

        // Current video
        if let url = s.videoURL {
            let title = NSMenuItem(title: url.lastPathComponent, action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)

            // Shows the user's intent; a system hold is explained on its own line.
            let playPause = NSMenuItem(
                title: engine.userPaused ? "Play" : "Pause",
                action: #selector(togglePlayPause), keyEquivalent: "p")
            playPause.target = self
            menu.addItem(playPause)

            // Never while standing down: the system wallpaper has no automatic pauses of
            // LiveWall's (systemPauseDescription is nil then).
            if !engine.userPaused, let reason = engine.systemPauseDescription {
                let held = NSMenuItem(title: "Paused: \(reason)", action: nil, keyEquivalent: "")
                held.isEnabled = false
                menu.addItem(held)
            }
        }

        // System wallpaper mode (macOS 26+): who is drawing the desktop.
        if let systemWallpaper {
            let status: String?
            if systemWallpaper.isExtensionActive {
                status = systemWallpaper.playingSummary.map { "Playing as system wallpaper: \($0)" }
                    ?? "Playing as system wallpaper"
            } else if engine.isStandingDown {
                // The extension went quiet; LiveWall's window comes back after a short
                // grace period unless it reports again.
                status = "System wallpaper idle"
            } else if engine.isShowingWindows {
                status = "Using LiveWall window"
            } else {
                status = nil
            }
            if let status {
                let line = NSMenuItem(title: status, action: nil, keyEquivalent: "")
                line.isEnabled = false
                menu.addItem(line)
            }
            if showFixedTileHint {
                let hint = NSMenuItem(title: Self.fixedTileHint, action: nil, keyEquivalent: "")
                hint.isEnabled = false
                menu.addItem(hint)
            }
        }

        let library = NSMenuItem(title: "Video Library…", action: #selector(showLibraryFromMenu), keyEquivalent: "l")
        library.target = self
        menu.addItem(library)

        let choose = NSMenuItem(title: "Choose Video…", action: #selector(chooseVideo), keyEquivalent: "o")
        choose.target = self
        menu.addItem(choose)

        // Recents
        let recents = s.recents
        if !recents.isEmpty {
            let recentMenu = NSMenu()
            for url in recents where FileManager.default.fileExists(atPath: url.path) {
                let item = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = url
                item.state = (url.path == s.videoURL?.path) ? .on : .off
                recentMenu.addItem(item)
            }
            let recentRoot = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
            menu.addItem(recentRoot)
            menu.setSubmenu(recentMenu, for: recentRoot)
        }

        menu.addItem(.separator())

        // Scaling
        let scalingMenu = NSMenu()
        let modes: [(String, AVLayerVideoGravity)] = [
            ("Fill Screen", .resizeAspectFill),
            ("Fit to Screen", .resizeAspect),
            ("Stretch", .resize),
        ]
        for (name, gravity) in modes {
            let item = NSMenuItem(title: name, action: #selector(setGravity(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = gravity.rawValue
            item.state = (s.gravity == gravity) ? .on : .off
            scalingMenu.addItem(item)
        }
        let scalingRoot = NSMenuItem(title: "Scaling", action: nil, keyEquivalent: "")
        menu.addItem(scalingRoot)
        menu.setSubmenu(scalingMenu, for: scalingRoot)

        // Toggles. While the system wallpaper plays (engine standing down) macOS alone
        // decides when it is drawn; the automatic pauses apply only to LiveWall's own
        // window, so they are shown disabled and say so.
        let windowOnly = engine.isStandingDown
        let suffix = windowOnly ? " (LiveWall window only)" : ""
        menu.addItem(toggle("Mute", #selector(toggleMute), on: s.muted))
        menu.addItem(toggle("Pause When Hidden" + suffix,
                            windowOnly ? nil : #selector(togglePauseWhenHidden), on: s.pauseWhenHidden))
        menu.addItem(toggle("Pause in Low Power Mode" + suffix,
                            windowOnly ? nil : #selector(togglePauseOnLowPower), on: s.pauseOnLowPower))

        menu.addItem(.separator())

        let login = toggle("Launch at Login", #selector(toggleLaunchAtLogin),
                           on: SMAppService.mainApp.status == .enabled)
        menu.addItem(login)

        if systemWallpaper != nil {
            let useSystem = NSMenuItem(title: "Use as System Wallpaper…", action: #selector(useAsSystemWallpaper),
                                       keyEquivalent: "")
            useSystem.target = self
            menu.addItem(useSystem)
        }

        if s.videoURL != nil {
            let stop = NSMenuItem(title: "Remove Wallpaper", action: #selector(stopWallpaper), keyEquivalent: "")
            stop.target = self
            menu.addItem(stop)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit LiveWall", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    /// Why a video picked in LiveWall did not change the desktop.
    static let fixedTileHint = "Picks here change only the “Current Video” wallpaper tile"

    /// The user picked a video in LiveWall: if no desktop follows LiveWall's pick, say so
    /// the next time the menu opens (once per launch).
    private func noteUserPickedVideo() {
        if systemWallpaper?.shouldHintFixedTiles() == true {
            showFixedTileHint = true
            rebuildMenu()
        }
    }

    /// A checkmark item. With no action it is shown disabled (the menu auto-enables
    /// items, so an action-less item cannot be chosen) but keeps its checkmark.
    private func toggle(_ title: String, _ action: Selector?, on: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = action == nil ? nil : self
        item.isEnabled = action != nil
        item.state = on ? .on : .off
        return item
    }

    // MARK: - Actions

    @objc func chooseVideo() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Video"
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            engine.load(url: url)
            noteUserPickedVideo()
        }
    }

    @objc private func showLibraryFromMenu() { showLibrary() }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        engine.load(url: url)
        noteUserPickedVideo()
    }

    @objc private func togglePlayPause() { engine.togglePlayPause() }

    @objc private func toggleMute() { engine.setMuted(!Settings.shared.muted) }

    @objc private func setGravity(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        engine.setGravity(AVLayerVideoGravity(rawValue: raw))
    }

    @objc private func togglePauseWhenHidden() {
        Settings.shared.pauseWhenHidden.toggle()
        engine.refreshOcclusionState()
    }

    @objc private func togglePauseOnLowPower() {
        Settings.shared.pauseOnLowPower.toggle()
        engine.refreshPowerState()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func stopWallpaper() { engine.stop() }

    @objc private func useAsSystemWallpaper() { systemWallpaper?.useAsSystemWallpaper() }
}
