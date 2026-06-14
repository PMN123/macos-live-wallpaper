import AppKit
import AVFoundation
import ServiceManagement
import UniformTypeIdentifiers

/// The menu bar item — the app's entire UI.
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let engine: WallpaperEngine
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private lazy var libraryWC = LibraryWindowController(engine: engine)

    init(engine: WallpaperEngine) {
        self.engine = engine
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            configureStatusBarButton(button)
        }
        menu.delegate = self
        statusItem.menu = menu
        engine.onStateChange = { [weak self] in self?.rebuildMenu() }
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

    private func rebuildMenu() {
        menu.removeAllItems()
        let s = Settings.shared

        // Current video
        if let url = s.videoURL {
            let title = NSMenuItem(title: url.lastPathComponent, action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)

            let playPause = NSMenuItem(
                title: engine.isPlaying ? "Pause" : "Play",
                action: #selector(togglePlayPause), keyEquivalent: "p")
            playPause.target = self
            menu.addItem(playPause)
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

        // Toggles
        menu.addItem(toggle("Mute", #selector(toggleMute), on: s.muted))
        menu.addItem(toggle("Wallpaper in Menu Bar", #selector(toggleMenuBar), on: s.menuBarWallpaper))
        menu.addItem(toggle("Pause When Hidden", #selector(togglePauseWhenHidden), on: s.pauseWhenHidden))
        menu.addItem(toggle("Pause in Low Power Mode", #selector(togglePauseOnLowPower), on: s.pauseOnLowPower))

        menu.addItem(.separator())

        let login = toggle("Launch at Login", #selector(toggleLaunchAtLogin),
                           on: SMAppService.mainApp.status == .enabled)
        menu.addItem(login)

        if s.videoURL != nil {
            let stop = NSMenuItem(title: "Remove Wallpaper", action: #selector(stopWallpaper), keyEquivalent: "")
            stop.target = self
            menu.addItem(stop)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit LiveWall", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func toggle(_ title: String, _ action: Selector, on: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
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
        }
    }

    @objc private func showLibraryFromMenu() { showLibrary() }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        engine.load(url: url)
    }

    @objc private func togglePlayPause() { engine.togglePlayPause() }

    @objc private func toggleMute() { engine.setMuted(!Settings.shared.muted) }

    @objc private func toggleMenuBar() { engine.setMenuBarWallpaper(!Settings.shared.menuBarWallpaper) }

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
}
