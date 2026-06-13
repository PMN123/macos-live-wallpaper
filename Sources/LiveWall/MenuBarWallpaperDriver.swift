import AppKit
import AVFoundation

/// Extends the live wallpaper into the system menu bar, and leaves a still frame
/// of the video as the desktop picture once the effect is switched off.
///
/// macOS owns the menu bar and only samples the *desktop-picture file* for its
/// background — it never bleeds arbitrary windows through (verified on macOS 26:
/// a full-screen desktop-level window does not show through the bar). So to make
/// the bar match the wallpaper, we grab the playing video's current frame a few
/// times a second and install it as the desktop picture. The full-screen
/// wallpaper window covers the real desktop, so that picture is only ever visible
/// *through* the menu bar — making the bar a seamless continuation of the
/// wallpaper, save for the system's own (unremovable) menu-bar tint.
///
/// When the effect is turned off (or the app quits) we don't try to restore the
/// previous wallpaper: on macOS 26 it may be an aerial/dynamic wallpaper the
/// public API can't read back. Instead we settle the desktop on a high-resolution
/// still frame of the video, so the wallpaper stays a static version of whatever
/// was playing. Requires menu-bar translucency (System Settings ▸ Accessibility ▸
/// Reduce Transparency = off); with it on the bar is opaque, so we leave the
/// desktop picture alone.
final class MenuBarWallpaperDriver {
    private weak var player: AVPlayer?
    private var asset: AVAsset?
    private var generator: AVAssetImageGenerator?
    private var timer: Timer?
    private var enabled = false
    private var playing = false
    private var inFlight = false
    private var fileToggle = false

    /// Live frames alternate between two files — reusing one URL makes AppKit skip
    /// the visual refresh. `still` is the higher-res frame left behind on exit.
    /// All live in Application Support, not a temp dir, so a crash can't strand the
    /// desktop on a file the system later purges.
    private let liveA: URL
    private let liveB: URL
    private let still: URL
    private let frameQueue = DispatchQueue(label: "com.praniil.livewall.menubar", qos: .utility)

    /// How often a fresh frame is pushed. `setDesktopImageURL` is a heavyweight
    /// system call, so this trades menu-bar smoothness against cost.
    private let interval: TimeInterval = 0.2

    init() {
        let dir = Self.supportDirectory()
        liveA = dir.appendingPathComponent("menubar-0.jpg")
        liveB = dir.appendingPathComponent("menubar-1.jpg")
        still = dir.appendingPathComponent("wallpaper-still.jpg")
    }

    private static func supportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("LiveWall", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Configuration

    /// Point the driver at the currently-loaded video (or `nil` to clear it).
    func setVideo(asset: AVAsset?, player: AVPlayer?) {
        self.player = player
        self.asset = asset
        guard let asset else { generator = nil; return }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        // The desktop image is scaled to fill the screen and, while live, only its
        // top strip is ever seen (through the menu bar), so a screen-ish width is
        // ample. The exit still is regenerated at full resolution separately.
        gen.maximumSize = CGSize(width: 1920, height: 1920)
        let tolerance = CMTime(seconds: 0.3, preferredTimescale: 600)
        gen.requestedTimeToleranceBefore = tolerance
        gen.requestedTimeToleranceAfter = tolerance
        generator = gen
    }

    // MARK: - State

    /// Turn the effect on/off. On drives the desktop picture with live frames; off
    /// settles it on a static still of the video. No-op (leaves the desktop alone)
    /// with no video, or when the bar is opaque because Reduce Transparency is on.
    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        if on {
            guard generator != nil,
                  !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency else { return }
            enabled = true
            tick()              // show the current frame immediately
            updatePump()
        } else {
            enabled = false
            stopPump()
            settleToStill()     // leave a static frame of the video behind
        }
    }

    /// Whether the video is actually moving — gates the per-frame pump. When the
    /// video is paused we leave the last frame in place, so the menu bar keeps
    /// matching the (frozen) wallpaper.
    func setPlaying(_ on: Bool) {
        guard on != playing else { return }
        playing = on
        updatePump()
    }

    /// Synchronously settle the desktop on a still frame — call before the app
    /// terminates, while the player is still alive.
    func settleNow() {
        stopPump()
        enabled = false
        settleToStill()
    }

    // MARK: - Frame pump

    private func updatePump() { (enabled && playing) ? startPump() : stopPump() }

    private func startPump() {
        guard timer == nil, generator != nil else { return }
        let t = Timer(timeInterval: interval, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopPump() { timer?.invalidate(); timer = nil }

    @objc private func tick() {
        guard enabled, !inFlight, let generator, let player else { return }
        let time = player.currentTime()
        guard time.isValid, time.seconds.isFinite else { return }

        inFlight = true
        let dest = fileToggle ? liveA : liveB
        fileToggle.toggle()

        frameQueue.async { [weak self] in
            guard let self else { return }
            var wrote = false
            if let cg = try? generator.copyCGImage(at: time, actualTime: nil) {
                wrote = self.writeJPEG(cg, to: dest, quality: 0.85)
            }
            DispatchQueue.main.async {
                if wrote, self.enabled { self.installDesktop(dest) }
                self.inFlight = false
            }
        }
    }

    /// Render the current frame at full resolution and make it the desktop picture,
    /// so the wallpaper stays a crisp still of the video after the effect stops.
    private func settleToStill() {
        guard let asset, let player else { return }
        let time = player.currentTime()
        guard time.isValid, time.seconds.isFinite else { return }

        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = stillSize()
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.3, preferredTimescale: 600)
        guard let cg = try? gen.copyCGImage(at: time, actualTime: nil),
              writeJPEG(cg, to: still, quality: 0.9) else { return }
        installDesktop(still)
    }

    /// Pixel size for the exit still — the active display's resolution, bounded.
    private func stillSize() -> CGSize {
        let screen = NSScreen.main
        let points = screen?.frame.size ?? CGSize(width: 1920, height: 1080)
        let scale = screen?.backingScaleFactor ?? 2
        let cap: CGFloat = 3840
        return CGSize(width: min(points.width * scale, cap), height: min(points.height * scale, cap))
    }

    private func writeJPEG(_ cg: CGImage, to url: URL, quality: CGFloat) -> Bool {
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]) else { return false }
        return (try? data.write(to: url)) != nil
    }

    private func installDesktop(_ url: URL) {
        // Match the wallpaper window's gravity so the bar (and the exit still) line
        // up with the video edge-for-edge instead of being scaled differently.
        let (scaling, clip): (NSImageScaling, Bool)
        switch Settings.shared.gravity {
        case .resize:       (scaling, clip) = (.scaleAxesIndependently, true)        // Stretch
        case .resizeAspect: (scaling, clip) = (.scaleProportionallyUpOrDown, false)  // Fit (letterbox)
        default:            (scaling, clip) = (.scaleProportionallyUpOrDown, true)   // Fill (crop)
        }
        let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: scaling.rawValue,
            .allowClipping: clip,
            .fillColor: NSColor.black,
        ]
        for screen in NSScreen.screens {
            try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options)
        }
    }
}
