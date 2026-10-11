// LiveWallWallpaper — Objective-C runtime helpers for the private wallpaper XPC types.
//
// Adapted from Phosphene (https://github.com/kageroumado/phosphene), MIT License, © 2026 kageroumado
// Sources: PhospheneExtension/RuntimeHelpers.swift, WallpaperIDProbe.swift, the Mirror helpers in
// WallpaperXPCHandler.swift and invalidateRemoteContext in SurfaceRegistry.swift, at commit db03edf.
// See THIRD_PARTY_NOTICES.md.
//
// Layout facts verified read-only on macOS 26.6.2 (25G83) by an ObjC runtime probe:
//   WallpaperRemoteContextXPC  size 16, ivar `box`      at offset 8
//   WallpaperSnapshotXPC       size 16, ivar `rawValue` at offset 8
// Every raw write below looks the offset up at runtime and bounds-checks it against
// the instance size, failing closed instead of corrupting the heap on a new OS.

import Foundation
import IOSurface
import QuartzCore

// MARK: - XPC reply objects

/// Construct a WallpaperRemoteContextXPC wrapping the given CAContext id. The class
/// stores a WallpaperExtensionRemoteContext (a single UInt32 remoteContextID) in `box`.
func createRemoteContextXPC(contextId: UInt32) -> AnyObject? {
    guard let realClass = objc_getClass("WallpaperRemoteContextXPC") as? AnyClass,
          let raw = class_createInstance(realClass, 0) else {
        extensionError("  ERROR: could not create WallpaperRemoteContextXPC")
        return nil
    }

    let obj = raw as AnyObject
    let ptr = Unmanaged.passUnretained(obj).toOpaque()
    let ivarOffset: Int
    if let ivar = class_getInstanceVariable(realClass, "box") {
        ivarOffset = ivar_getOffset(ivar)
    } else {
        ivarOffset = 8
        extensionError("  WARNING: WallpaperRemoteContextXPC has no `box` ivar — assuming offset 8")
    }
    // Bounds-check before the raw write: a shrunken layout or stale offset must fail
    // closed rather than write past the instance.
    let size = class_getInstanceSize(realClass)
    guard ivarOffset >= MemoryLayout<UnsafeRawPointer>.size,
          ivarOffset + MemoryLayout<UInt32>.size <= size else {
        extensionError("  ERROR: WallpaperRemoteContextXPC layout unexpected (offset \(ivarOffset), size \(size))")
        return nil
    }
    ptr.advanced(by: ivarOffset).storeBytes(of: contextId, as: UInt32.self)
    traceLog("  created WallpaperRemoteContextXPC (contextId \(contextId), offset \(ivarOffset), size \(size))")
    return obj
}

/// Construct a WallpaperSnapshotXPC wrapping the given IOSurface. The class stores a
/// WallpaperSnapshot (one retained IOSurface pointer) in `rawValue`.
func createSnapshotXPC(surface: IOSurface) -> AnyObject? {
    guard let snapshotXPCClass = objc_getClass("WallpaperSnapshotXPC") as? AnyClass,
          let instance = class_createInstance(snapshotXPCClass, 0) else {
        extensionError("  [Snapshot] failed to create WallpaperSnapshotXPC")
        return nil
    }

    let snapshotOffset = class_getInstanceVariable(snapshotXPCClass, "rawValue").map { ivar_getOffset($0) } ?? 8
    let size = class_getInstanceSize(snapshotXPCClass)
    guard snapshotOffset >= MemoryLayout<UnsafeRawPointer>.size,
          snapshotOffset + MemoryLayout<UnsafeRawPointer>.size <= size else {
        extensionError("  [Snapshot] WallpaperSnapshotXPC layout unexpected (offset \(snapshotOffset), size \(size))")
        return nil
    }

    // +1 reference owned by the XPC object; released when it is deallocated.
    let surfaceRef = Unmanaged.passRetained(surface).toOpaque()
    let instancePtr = Unmanaged.passUnretained(instance as AnyObject).toOpaque()
    instancePtr.advanced(by: snapshotOffset).storeBytes(of: surfaceRef, as: UnsafeRawPointer.self)
    return instance as AnyObject
}

// MARK: - CAContext (private QuartzCore class, reached through the runtime)

/// Remote CAContext access without a compile-time declaration of the private class.
enum CARemote {
    static var contextClass: NSObject.Type? {
        NSClassFromString("CAContext") as? NSObject.Type
    }

    /// `+[CAContext remoteContextWithOptions:]` with `displayId` when known, else
    /// `+[CAContext remoteContext]`. Returns nil if the class or selector is missing
    /// or the context id comes back 0.
    static func makeRemoteContext(displayID: UInt32?) -> (context: NSObject, contextId: UInt32)? {
        guard let cls = contextClass else { return nil }
        let created: AnyObject? = autoreleasepool {
            if let displayID {
                let sel = NSSelectorFromString("remoteContextWithOptions:")
                guard cls.responds(to: sel) else { return nil }
                let options: NSDictionary = ["displayId": NSNumber(value: displayID)]
                return cls.perform(sel, with: options)?.takeUnretainedValue()
            }
            let sel = NSSelectorFromString("remoteContext")
            guard cls.responds(to: sel) else { return nil }
            return cls.perform(sel)?.takeUnretainedValue()
        }
        guard let context = created as? NSObject,
              let id = contextId(of: context), id != 0 else { return nil }
        return (context, id)
    }

    static func contextId(of context: NSObject) -> UInt32? {
        (context.value(forKey: "contextId") as? NSNumber)?.uint32Value
    }

    static func setLayer(_ layer: CALayer?, on context: NSObject) {
        context.setValue(layer, forKey: "layer")
    }

    /// Force the WindowServer to reclaim a remote CAContext. Dropping our reference is
    /// not enough: the host's CALayerHost keeps the tree resident until invalidated.
    static func invalidate(_ context: NSObject) {
        let sel = NSSelectorFromString("invalidate")
        guard context.responds(to: sel) else { return }
        context.perform(sel)
    }
}

// MARK: - Mirror helpers for the private Swift value types inside the XPC wrappers

/// The `WallpaperID` UUID inside a WallpaperIDXPC (`box.rawValue.id`), or nil: the
/// first UUID found in the Mirror tree.
func extractWallpaperUUID(fromID id: Any?) -> UUID? {
    guard let id else { return nil }
    return searchUUID(id, depth: 0)
}

private func searchUUID(_ value: Any, depth: Int) -> UUID? {
    guard depth < 8 else { return nil }
    if let uuid = value as? UUID { return uuid }
    for child in Mirror(reflecting: value).children {
        if let found = searchUUID(child.value, depth: depth + 1) { return found }
    }
    return nil
}

/// Recursively search a value's Mirror for a stored property with the given label, to
/// a shallow depth. Robust to the XPC wrapper nesting, unlike parsing a description.
func mirrorFindProperty(_ label: String, in value: Any, depth: Int = 0) -> Any? {
    guard depth < 6 else { return nil }
    for child in Mirror(reflecting: value).children {
        if child.label == label {
            return child.value
        }
        if let found = mirrorFindProperty(label, in: child.value, depth: depth + 1) {
            return found
        }
    }
    return nil
}

/// An enum case name: `.idle` → "idle", `.suspended(reason)` → "suspended". Falls
/// back to `String(describing:)` for payload-less cases and non-enums.
func enumCaseName(_ value: Any) -> String {
    let mirror = Mirror(reflecting: value)
    if mirror.displayStyle == .enum, let label = mirror.children.first?.label {
        return label
    }
    return String(describing: value)
}
