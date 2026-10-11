// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LiveWall",
    platforms: [.macOS(.v13)],
    targets: [
        // The menu-bar app (window-based video wallpaper; on macOS 26+ it can hand
        // playback to the system wallpaper extension below).
        .executableTarget(
            name: "LiveWall",
            dependencies: ["LiveWallShared"],
            path: "Sources/LiveWall"
        ),

        // The host ↔ extension contract (shared directory, state.json schema, Darwin
        // notification names). Built app-extension-safe so the appex can link it.
        .target(
            name: "LiveWallShared",
            path: "Sources/LiveWallShared",
            swiftSettings: [.unsafeFlags(["-application-extension"])]
        ),

        // Objective-C declarations of the private WallpaperExtensionKit XPC protocols,
        // exposed to Swift as the `WallpaperPrivate` module.
        .target(
            name: "WallpaperPrivate",
            path: "Sources/WallpaperPrivate",
            cSettings: [.unsafeFlags(["-fapplication-extension"])]
        ),

        // The com.apple.wallpaper ExtensionKit extension. build.sh wraps the binary in
        // LiveWall.app/Contents/Extensions/LiveWallWallpaper.appex. The process entry
        // point must be Foundation's _NSExtensionMain (as Xcode's LD_ENTRY_POINT does for
        // app extensions); it then runs the Swift @main AppExtension. Without it the
        // process exits before accept(connection:) is ever called.
        .executableTarget(
            name: "LiveWallWallpaper",
            dependencies: ["WallpaperPrivate", "LiveWallShared"],
            path: "Sources/LiveWallWallpaper",
            swiftSettings: [.unsafeFlags(["-application-extension"])],
            linkerSettings: [
                .linkedFramework("ExtensionFoundation"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("IOSurface"),
                .linkedFramework("CoreText"),
                .linkedFramework("ImageIO"),
                .linkedFramework("Security"),
                .unsafeFlags([
                    "-Xlinker", "-application_extension",
                    "-Xlinker", "-e", "-Xlinker", "_NSExtensionMain",
                ]),
            ]
        ),
    ]
)
