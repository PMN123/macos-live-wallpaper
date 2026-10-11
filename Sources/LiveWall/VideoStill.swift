import AVFoundation
import Foundation
import ImageIO

/// Still frames for the System Settings tiles (system wallpaper mode).
enum VideoStill {
    /// Write a still of `videoURL` at about 1 s (the first frame for shorter clips), at
    /// most 640 px on its longest side, as a PNG at `destination`. The PNG is written
    /// under a hidden temporary name and renamed into place, so `destination` only ever
    /// holds a complete file. Blocks; call off the main thread.
    static func writePNG(for videoURL: URL, to destination: URL) -> Bool {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        let tolerance = CMTime(value: 1, timescale: 2)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        guard let image = generateImage(generator, at: CMTime(value: 1, timescale: 1))
            ?? generateImage(generator, at: .zero) else { return false }
        let partial = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).partial")
        guard let output = CGImageDestinationCreateWithURL(partial as CFURL, "public.png" as CFString, 1, nil) else {
            return false
        }
        CGImageDestinationAddImage(output, image, nil)
        guard CGImageDestinationFinalize(output), rename(partial.path, destination.path) == 0 else {
            try? FileManager.default.removeItem(at: partial)
            return false
        }
        return true
    }

    private final class ImageBox {
        var image: CGImage?
    }

    private static func generateImage(_ generator: AVAssetImageGenerator, at time: CMTime) -> CGImage? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ImageBox()
        generator.generateCGImageAsynchronously(for: time) { image, _, _ in
            box.image = image
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 15) == .success else { return nil }
        return box.image
    }
}
