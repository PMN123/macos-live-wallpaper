// LiveWallWallpaper — still images: the display-layer seed frame, the no-video
// fallback art, PNG I/O for the Settings tile, and IOSurface snapshots.
//
// Adapted from Phosphene (https://github.com/kageroumado/phosphene), MIT License, © 2026 kageroumado
// Sources: PhospheneExtension/StillFrame.swift (makeStillSampleBuffer) and
// PhospheneExtension/SnapshotCreation.swift (renderSnapshotToIOSurface) at commit db03edf.
// See THIRD_PARTY_NOTICES.md.
//
// Plain `CALayer.contents` composites as black when the layer tree is hosted in another
// process, so every still the wallpaper shows goes through the
// AVSampleBufferDisplayLayer as an IOSurface-backed sample buffer.

import CoreGraphics
import CoreMedia
import CoreText
import CoreVideo
import Foundation
import ImageIO
import IOSurface
import LiveWallShared

/// Wrap `image` in an IOSurface-backed `CMSampleBuffer` at PTS zero, sized to the image.
func makeStillSampleBuffer(from image: CGImage) -> CMSampleBuffer? {
    let width = image.width
    let height = image.height
    guard width > 0, height > 0 else { return nil }

    let attributes: [CFString: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true,
    ]
    var pixelBufferOut: CVPixelBuffer?
    guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                              attributes as CFDictionary, &pixelBufferOut) == kCVReturnSuccess,
          let pixelBuffer = pixelBufferOut else { return nil }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    let drawn: Bool = {
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }()
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    guard drawn else { return nil }

    var formatDescription: CMVideoFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                       formatDescriptionOut: &formatDescription) == noErr,
          let format = formatDescription else { return nil }

    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    var sampleBuffer: CMSampleBuffer?
    guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                   formatDescription: format, sampleTiming: &timing,
                                                   sampleBufferOut: &sampleBuffer) == noErr else { return nil }
    return sampleBuffer
}

/// Tag a sample buffer so the renderer shows it at once, replacing whatever is on
/// screen regardless of timestamps and of the (possibly stopped) control timebase.
func setDisplayImmediately(_ sample: CMSampleBuffer) {
    guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) else { return }
    for i in 0 ..< CFArrayGetCount(attachments) {
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, i), to: CFMutableDictionary.self)
        CFDictionarySetValue(dict,
                             Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                             Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
}

/// Art shown when there is no video (LiveWall's wallpaper was removed, or the shared
/// directory is unreadable) and used as the tile thumbnail fallback: a dark gradient
/// with the LiveWall name.
enum FallbackArt {
    private static let lock = NSLock()
    private static var cache: [String: CGImage] = [:]

    static func image(width: Int, height: Int, label: Bool = true) -> CGImage? {
        let key = "\(width)x\(height)-\(label)"
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        let colors = [
            CGColor(red: 0.07, green: 0.08, blue: 0.16, alpha: 1),
            CGColor(red: 0.16, green: 0.10, blue: 0.30, alpha: 1),
            CGColor(red: 0.05, green: 0.22, blue: 0.30, alpha: 1),
        ]
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 0.55, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.maxY),
                                   end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
        }
        if label {
            let fontSize = max(CGFloat(height) * 0.12, 12)
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 1, green: 1, blue: 1, alpha: 0.85),
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "LiveWall", attributes: attributes))
            let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
            ctx.textPosition = CGPoint(x: rect.midX - bounds.width / 2 - bounds.minX,
                                       y: rect.midY - bounds.height / 2 - bounds.minY)
            CTLineDraw(line, ctx)
        }
        guard let image = ctx.makeImage() else { return nil }
        cache[key] = image
        return image
    }
}

/// Decode an image file (the host's thumbnail.png). Nil if it is missing or not an image.
func loadImage(at url: URL, maxPixelSize: Int? = nil) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
          CGImageSourceGetCount(source) > 0 else { return nil }
    if let maxPixelSize {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

/// Write `image` as a PNG beside `url`, then rename it into place, so a reader never
/// sees a partial file.
@discardableResult
func writePNGAtomically(_ image: CGImage, to url: URL) -> Bool {
    let partial = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).partial")
    guard let dest = CGImageDestinationCreateWithURL(partial as CFURL, "public.png" as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        try? FileManager.default.removeItem(at: partial)
        return false
    }
    guard rename(partial.path, url.path) == 0 else {
        try? FileManager.default.removeItem(at: partial)
        return false
    }
    return true
}

/// Draw `image` into a new BGRA IOSurface of the given pixel size, scaled the way the
/// wallpaper shows it, and wrap it in a WallpaperSnapshotXPC. Nil on any failure.
func makeSnapshotXPC(image: CGImage, pixelWidth: Int, pixelHeight: Int, gravity: SharedGravity) -> AnyObject? {
    let width = max(pixelWidth, 16)
    let height = max(pixelHeight, 16)
    let properties: [IOSurfacePropertyKey: Any] = [
        .width: width,
        .height: height,
        .bytesPerElement: 4,
        .pixelFormat: 0x4247_5241, // 'BGRA'
    ]
    guard let surface = IOSurface(properties: properties) else {
        extensionError("  [Snapshot] IOSurface creation failed (\(width)x\(height))")
        return nil
    }
    surface.lock(options: [], seed: nil)
    let drawn: Bool = {
        guard let ctx = CGContext(data: surface.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: surface.bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return false }
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: placementRect(imageWidth: image.width, imageHeight: image.height,
                                          width: width, height: height, gravity: gravity))
        ctx.flush()
        return true
    }()
    surface.unlock(options: [], seed: nil)
    guard drawn else {
        extensionError("  [Snapshot] CGContext over IOSurface failed")
        return nil
    }
    return createSnapshotXPC(surface: surface)
}

private func placementRect(imageWidth: Int, imageHeight: Int, width: Int, height: Int, gravity: SharedGravity) -> CGRect {
    let full = CGRect(x: 0, y: 0, width: width, height: height)
    guard imageWidth > 0, imageHeight > 0, gravity != .stretch else { return full }
    let sx = CGFloat(width) / CGFloat(imageWidth)
    let sy = CGFloat(height) / CGFloat(imageHeight)
    let scale = gravity == .fill ? max(sx, sy) : min(sx, sy)
    let w = CGFloat(imageWidth) * scale
    let h = CGFloat(imageHeight) * scale
    return CGRect(x: (CGFloat(width) - w) / 2, y: (CGFloat(height) - h) / 2, width: w, height: h)
}
