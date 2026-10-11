// LiveWallWallpaper — logging: unified logging plus a plain file.
//
// Unified logging:
//   log stream --level info --predicate 'subsystem == "com.praniil.livewall.wallpaper"'
// On macOS 26.6.2 nothing from the extension reached `log show`/`log stream` during
// M1, so every line also goes to a file:
//   ~/Library/Application Support/LiveWall/Wallpaper/extension.log   (shared directory)
// or, when the sandbox exception for that directory is not honoured (or the host app
// has not created it yet), the extension container:
//   ~/Library/Containers/com.praniil.livewall.wallpaper/Data/Documents/extension.log
// The file is capped at 512 KB; the previous file is kept as extension.1.log.
//
// Messages are logged `.public`: they are wallpaper lifecycle state only.

import Foundation
import LiveWallShared
import os

private let logger = Logger(subsystem: "com.praniil.livewall.wallpaper", category: "extension")

/// Lifecycle and state-change log line. Notice level, so it is persisted to the log store.
func extensionLog(_ message: String) {
    logger.notice("\(message, privacy: .public)")
    FileLog.shared.write("NOTE", message)
}

/// Problems that need attention (missing private classes, layout surprises, failed replies).
func extensionError(_ message: String) {
    logger.error("\(message, privacy: .public)")
    FileLog.shared.write("ERROR", message)
}

/// Detail lines (request payloads, renderer steps). Never per-frame.
func traceLog(_ message: @autoclosure () -> String) {
    let text = message()
    logger.info("\(text, privacy: .public)")
    FileLog.shared.write("TRACE", text)
}

/// Bounded `String(describing:)` for logging opaque private XPC values.
func describeBounded(_ value: Any?, limit: Int = 1_500) -> String {
    guard let value else { return "nil" }
    let text = String(describing: value)
    return text.count > limit ? String(text.prefix(limit)) + "…(\(text.count) chars)" : text
}

/// Append-only log file with one-step rotation. All file work happens on a private
/// utility queue; callers never block on disk.
final class FileLog {
    static let shared = FileLog()

    private static let maxBytes = 512 * 1_024
    /// While writing to the container fallback, re-try the shared directory this often
    /// (in lines), so the log moves there once the host app has created it.
    private static let retrySharedEvery = 200

    private let queue = DispatchQueue(label: "com.praniil.livewall.wallpaper.filelog", qos: .utility)
    private let pid = ProcessInfo.processInfo.processIdentifier
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // Confined to `queue`.
    private var handle: FileHandle?
    private var url: URL?
    private var size = 0
    private var usingFallback = false
    private var linesSinceRetry = 0
    private var lastOpenFailureLogged = false

    private init() {}

    /// Where lines currently go (for the startup self-check), read synchronously.
    var currentPath: String {
        queue.sync {
            if handle == nil { open() }
            return url?.path ?? "(no writable location)"
        }
    }

    func write(_ level: String, _ message: String) {
        let now = Date()
        queue.async { [self] in
            let line = "\(formatter.string(from: now)) [\(pid)] \(level) \(message)\n"
            append(line)
        }
    }

    private func append(_ line: String) {
        if usingFallback {
            linesSinceRetry += 1
            if linesSinceRetry >= Self.retrySharedEvery {
                linesSinceRetry = 0
                if FileManager.default.fileExists(atPath: SharedWallpaper.defaultDirectory().path) {
                    close()
                }
            }
        }
        if handle == nil { open() }
        guard handle != nil else { return }
        let data = Data(line.utf8)
        if size + data.count > Self.maxBytes {
            rotate()
            guard handle != nil else { return }
        }
        do {
            try handle?.write(contentsOf: data)
            size += data.count
        } catch {
            close()
        }
    }

    private func open() {
        let fm = FileManager.default
        let shared = SharedWallpaper.defaultDirectory()
        let container = fm.homeDirectoryForCurrentUser.appendingPathComponent("Documents", isDirectory: true)
        // The extension cannot create the shared directory itself (only its contents are
        // granted), so it must already exist; the container is always ours.
        for (dir, isFallback) in [(shared, false), (container, true)] {
            if isFallback {
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            } else if !fm.fileExists(atPath: dir.path) {
                continue
            }
            let fileURL = dir.appendingPathComponent(SharedWallpaper.logFileName, isDirectory: false)
            if !fm.fileExists(atPath: fileURL.path) {
                guard fm.createFile(atPath: fileURL.path, contents: nil) else { continue }
            }
            guard let h = try? FileHandle(forWritingTo: fileURL) else { continue }
            let end = (try? h.seekToEnd()) ?? 0
            handle = h
            url = fileURL
            size = Int(end)
            usingFallback = isFallback
            linesSinceRetry = 0
            return
        }
        if !lastOpenFailureLogged {
            lastOpenFailureLogged = true
            logger.error("FileLog: no writable log location")
        }
    }

    private func close() {
        try? handle?.close()
        handle = nil
        url = nil
        size = 0
    }

    /// extension.log → extension.1.log (replacing the older one), then a fresh file.
    private func rotate() {
        guard let current = url else { return }
        let rotated = current.deletingLastPathComponent()
            .appendingPathComponent(SharedWallpaper.rotatedLogFileName, isDirectory: false)
        close()
        let fm = FileManager.default
        try? fm.removeItem(at: rotated)
        try? fm.moveItem(at: current, to: rotated)
        open()
    }
}
