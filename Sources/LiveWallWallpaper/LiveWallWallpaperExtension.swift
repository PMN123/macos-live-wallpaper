// LiveWallWallpaper — ExtensionKit entry point for the com.apple.wallpaper extension point.
//
// Adapted from Phosphene (https://github.com/kageroumado/phosphene), MIT License, © 2026 kageroumado
// Source: PhospheneExtension/PhospheneExtension.swift at commit db03edf. See THIRD_PARTY_NOTICES.md.
//
// WallpaperAgent spawns this process for the LiveWall tiles in System Settings >
// Wallpaper. Each hosted surface plays the video its tile names: LiveWall's current
// video, or one of its Video Library, as LiveWall publishes them in the shared
// directory (see LiveWallShared). The extension tells LiveWall when it is the live
// desktop so the app can close its own wallpaper window, and what each desktop plays.

import ExtensionFoundation
import Foundation

@main
final class LiveWallWallpaperExtension: NSObject, AppExtension {
    override required init() {
        super.init()

        let frameworkPath = "/System/Library/PrivateFrameworks/WallpaperExtensionKit.framework/WallpaperExtensionKit"
        let pid = ProcessInfo.processInfo.processIdentifier
        if let handle = dlopen(frameworkPath, RTLD_LAZY) {
            // Keep the handle open for the life of the process: the XPC value classes
            // and their Swift metadata must stay loaded while the agent talks to us.
            _ = handle
            extensionLog("INIT (pid \(pid)) — WallpaperExtensionKit loaded")
            verifyRuntimeLayout()
            if #available(macOS 26.0, *) {
                Lifecycle.queue.async {
                    Liveness.shared.start()
                    SharedStateStore.shared.start()
                    LibraryStore.shared.start()
                }
                // The extension is only ever spawned by a host connection. Push the view
                // models shortly after launch so the agent's on-disk settings cache can't
                // keep a stale answer (such as M1's "LiveWall Test" tile); the delay lets
                // the spawning connection's accept() register its proxy first.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    SettingsPush.push()
                }
            }
        } else {
            let err = dlerror().map { String(cString: $0) } ?? "unknown error"
            extensionError("INIT (pid \(pid)) — dlopen of WallpaperExtensionKit failed: \(err)")
        }
    }

    /// Startup self-check: confirm the private classes the extension bridges to are
    /// present after dlopen. It does not fail the launch (each call site fails closed),
    /// but one clear line up front marks an unsupported OS after an update.
    private func verifyRuntimeLayout() {
        let critical = [
            "WallpaperRemoteContextXPC",
            "WallpaperSnapshotXPC",
            "WallpaperCreationRequestXPC",
            "WallpaperSettingsViewModelsXPC",
            "WallpaperIDXPC",
        ]
        let missing = critical.filter { objc_getClass($0) == nil }
        if missing.isEmpty {
            extensionLog("[SelfCheck] runtime layout OK — all \(critical.count) critical classes present")
        } else {
            extensionError("[SelfCheck] UNSUPPORTED RUNTIME — missing: \(missing.joined(separator: ", "))")
        }

        if CARemote.contextClass == nil {
            extensionError("[SelfCheck] CAContext class not found — acquire will fail")
        }

        // Layout facts the raw ivar writes depend on (see RuntimeHelpers.swift).
        if let cls = objc_getClass("WallpaperRemoteContextXPC") as? AnyClass {
            let offset = class_getInstanceVariable(cls, "box").map { ivar_getOffset($0) }
            extensionLog("[SelfCheck] WallpaperRemoteContextXPC size=\(class_getInstanceSize(cls)) box offset=\(offset.map(String.init) ?? "missing")")
        }
        if let cls = objc_getClass("WallpaperSnapshotXPC") as? AnyClass {
            let offset = class_getInstanceVariable(cls, "rawValue").map { ivar_getOffset($0) }
            extensionLog("[SelfCheck] WallpaperSnapshotXPC size=\(class_getInstanceSize(cls)) rawValue offset=\(offset.map(String.init) ?? "missing")")
        }
    }

    var configuration: some AppExtensionConfiguration {
        WallpaperExtensionConfig()
    }
}
