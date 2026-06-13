import AppKit
import AVFoundation

/// Makes the wallpaper appear in the system menu bar.
///
/// The macOS menu bar is owned by the window server and only samples the
/// *desktop picture* for its translucency — it never bleeds arbitrary windows
/// through. So instead of drawing over the menu bar (which would hide the clock
/// and menus), we periodically grab a frame from the playing video and install
/// it as the desktop picture. The full-screen wallpaper window covers the real
/// desktop, so that picture is only ever visible *through* the translucent menu
/// bar — giving a soft, live, fully-readable menu bar.
///
/// Requires menu-bar translucency (System Settings ▸ Accessibility ▸ Reduce
/// Transparency = off). Original desktop pictures are saved on activation and
/// restored when the feature is turned off or the app quits.
final class MenuBarBlurDriver {
    private weak var player: AVPlayer?
    private var generator: AVAssetImageGenerator?
    private var timer: Timer?
    private var active = false
    private var inFlight = false
    private var fileToggle = false

    /// Original desktop picture per display, captured when the driver activates.
    private var savedDesktop: [CGDirectDisplayID: URL] = [:]

    /// Two alternating temp files — reusing one URL would make AppKit skip the
    /// visual refresh, so each tick writes to the *other* file.
    private let fileA: URL
    private let fileB: URL
    private let frameQueue = DispatchQueue(label: "com.praniil.livewall.menubar", qos: .utility)

    init() {
        let dir = FileManager.default.temporaryDirectory
        fileA = dir.appendingPathComponent("livewall-menubar-0.jpg")
        fileB = dir.appendingPathComponent("livewall-menubar-1.jpg")
    }

    // MARK: - Configuration

    /// Point the driver at the currently-loaded video (or `nil` to clear it).
    func setVideo(asset: AVAsset?, player: AVPlayer?) {
        self.player = player
        guard let asset else { generator = nil; return }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 480, height: 300) // the bar is blurred; tiny is plenty
        let tolerance = CMTime(seconds: 0.4, preferredTimescale: 600)
        gen.requestedTimeToleranceBefore = tolerance
        gen.requestedTimeToleranceAfter = tolerance
        generator = gen
    }

    /// Turn the menu-bar effect on/off. Safe to call repeatedly.
    func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        on ? start() : stop()
    }

    /// Synchronously restore the desktop — call before the app terminates.
    func restoreNow() {
        timer?.invalidate(); timer = nil
        active = false
        restoreDesktop()
    }

    // MARK: - Lifecycle

    private func start() {
        guard generator != nil else { active = false; return }
        saveDesktopIfNeeded()
        timer?.invalidate()
        let t = Timer(timeInterval: 0.33, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    private func stop() {
        timer?.invalidate(); timer = nil
        restoreDesktop()
    }

    // MARK: - Frame pump

    @objc private func tick() {
        guard active, !inFlight, let generator, let player else { return }
        let time = player.currentTime()
        guard time.isValid, time.seconds.isFinite else { return }

        inFlight = true
        let dest = fileToggle ? fileA : fileB
        fileToggle.toggle()

        frameQueue.async { [weak self] in
            guard let self else { return }
            var wrote = false
            if let cg = try? generator.copyCGImage(at: time, actualTime: nil) {
                wrote = self.writeJPEG(cg, to: dest)
            }
            DispatchQueue.main.async {
                if wrote, self.active { self.installDesktop(dest) }
                self.inFlight = false
            }
        }
    }

    private func writeJPEG(_ cg: CGImage, to url: URL) -> Bool {
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else { return false }
        return (try? data.write(to: url)) != nil
    }

    private func installDesktop(_ url: URL) {
        let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSImageScaling.scaleAxesIndependently.rawValue,
            .allowClipping: true,
        ]
        for screen in NSScreen.screens {
            try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options)
        }
    }

    // MARK: - Save / restore the real wallpaper

    private func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private func saveDesktopIfNeeded() {
        guard savedDesktop.isEmpty else { return }
        for screen in NSScreen.screens {
            guard let id = displayID(of: screen),
                  let url = NSWorkspace.shared.desktopImageURL(for: screen),
                  url != fileA, url != fileB // never adopt our own temp frame as the "original"
            else { continue }
            savedDesktop[id] = url
        }
    }

    private func restoreDesktop() {
        guard !savedDesktop.isEmpty else { return }
        for screen in NSScreen.screens {
            guard let id = displayID(of: screen), let url = savedDesktop[id] else { continue }
            try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
        }
        savedDesktop.removeAll()
    }
}
