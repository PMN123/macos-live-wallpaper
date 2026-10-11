// LiveWallWallpaper — pushes fresh settings view models to every live host connection.
//
// Adapted from Phosphene (https://github.com/kageroumado/phosphene), MIT License, © 2026 kageroumado
// Source: PhospheneExtension/SettingsPush.swift at commit db03edf. See THIRD_PARTY_NOTICES.md.
//
// The agent caches each provider's view models on disk and (on macOS 26.6) serves that
// cache on every Settings launch, re-querying only after a reinstall or OS update.
// `updateSettingsViewModels` is the host callback that refreshes the cache and updates
// an open Settings pane in place. The extension pushes once shortly after launch (so a
// cache from an older build is replaced) and again whenever the tile thumbnail changes.

import Foundation
import WallpaperPrivate

@available(macOS 26.0, *)
enum SettingsPush {
    /// One weak entry per live XPC connection, registered in accept(connection:) and
    /// removed by the connection's invalidation handler.
    private struct WeakHandler {
        weak var handler: WallpaperXPCHandler?
    }

    private static let lock = NSLock()
    private static var handlers: [WeakHandler] = []

    /// Debounce state and the tile last pushed to every live connection. A single
    /// connection's provideSettingsViewModels reply does not count. Lifecycle queue only.
    private static var pending: DispatchWorkItem?
    private static var lastPushedThumbnail: String?

    static func register(_ handler: WallpaperXPCHandler) {
        lock.lock()
        defer { lock.unlock() }
        handlers.removeAll { $0.handler == nil }
        handlers.append(WeakHandler(handler: handler))
    }

    static func unregister(_ handler: WallpaperXPCHandler) {
        lock.lock()
        defer { lock.unlock() }
        handlers.removeAll { $0.handler == nil || $0.handler === handler }
    }

    private static func liveProxies() -> [WallpaperExtensionProxyXPCProtocol] {
        lock.lock()
        defer { lock.unlock() }
        return handlers.compactMap { $0.handler?.agentProxy }
    }

    /// Build the current view models once and send them over every live connection.
    static func push() {
        Lifecycle.queue.async { pushNow(force: true) }
    }

    /// Push after a short quiet period, and only if the tile thumbnail changed (a new
    /// video, or its still arriving). Lifecycle queue.
    static func scheduleRefresh() {
        dispatchPrecondition(condition: .onQueue(Lifecycle.queue))
        pending?.cancel()
        let work = DispatchWorkItem {
            pending = nil
            pushNow(force: false)
        }
        pending = work
        Lifecycle.queue.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    /// Ask every connected host to drop cached snapshots (the video changed).
    static func invalidateSnapshots() {
        for proxy in liveProxies() {
            proxy.invalidateSnapshots { error in
                if let error {
                    extensionError("[SettingsPush] invalidateSnapshots error: \(error)")
                }
            }
        }
    }

    private static func pushNow(force: Bool) {
        dispatchPrecondition(condition: .onQueue(Lifecycle.queue))
        // Checked first: without a connection nothing is written or deleted, so the
        // agent's cached tile stays valid until the next query.
        let proxies = liveProxies()
        guard !proxies.isEmpty else {
            extensionLog("[SettingsPush] no live host connection — the cache refreshes on the next query")
            return
        }
        guard let tile = TileThumbnail.currentURL() else {
            extensionError("[SettingsPush] could not produce the tile thumbnail — nothing pushed")
            return
        }
        let thumbnail = tile.lastPathComponent
        if !force, thumbnail == lastPushedThumbnail {
            return
        }
        guard let models = buildSettingsViewModelsXPC(thumbnailURL: tile) else {
            extensionError("[SettingsPush] build failed — nothing pushed")
            return
        }
        extensionLog("[SettingsPush] pushing view models (tile \(thumbnail)) to \(proxies.count) connection(s)")
        for proxy in proxies {
            proxy.updateSettingsViewModels(models) { error in
                if let error {
                    extensionError("[SettingsPush] updateSettingsViewModels error: \(error)")
                }
            }
        }
        lastPushedThumbnail = thumbnail
        // Every live connection now has this tile; older ones can go.
        TileThumbnail.removeStale(keeping: thumbnail)
    }
}
