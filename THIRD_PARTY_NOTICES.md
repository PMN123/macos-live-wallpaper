# Third-party notices

LiveWall is licensed under the Apache License 2.0 (see `LICENSE`). It includes code
adapted from the project below, which is used under its own license.

## Phosphene

- Project: https://github.com/kageroumado/phosphene
- Version used: commit `db03edf` (v1.9.0)
- License: MIT

The following LiveWall files are adapted from Phosphene's `PhospheneExtension/`
sources. Each file says so in its header comment.

| LiveWall file | Adapted from |
|---|---|
| `Sources/WallpaperPrivate/include/WallpaperPrivate.h` | `PhospheneExtension/WallpaperExtension-Bridging-Header.h` |
| `Sources/LiveWallWallpaper/LiveWallWallpaperExtension.swift` | `PhospheneExtension/PhospheneExtension.swift` |
| `Sources/LiveWallWallpaper/WallpaperExtensionConfig.swift` | `PhospheneExtension/WallpaperExtensionConfig.swift` |
| `Sources/LiveWallWallpaper/CallerValidation.swift` | `PhospheneExtension/CallerValidation.swift` |
| `Sources/LiveWallWallpaper/WallpaperXPCHandler.swift` | `PhospheneExtension/WallpaperXPCHandler.swift`, `PhospheneExtension/SnapshotCreation.swift` |
| `Sources/LiveWallWallpaper/RuntimeHelpers.swift` | `PhospheneExtension/RuntimeHelpers.swift`, `PhospheneExtension/WallpaperIDProbe.swift`, `PhospheneExtension/SurfaceRegistry.swift` |
| `Sources/LiveWallWallpaper/SurfaceRegistry.swift` | `PhospheneExtension/SurfaceRegistry.swift`, `PhospheneExtension/WallpaperXPCHandler.swift` |
| `Sources/LiveWallWallpaper/VideoRenderer.swift` | `PhospheneExtension/VideoRenderer.swift` |
| `Sources/LiveWallWallpaper/LoopRetimer.swift` | `PhospheneExtension/VideoRenderer.swift` |
| `Sources/LiveWallWallpaper/StillImages.swift` | `PhospheneExtension/StillFrame.swift`, `PhospheneExtension/SnapshotCreation.swift` |
| `Sources/LiveWallWallpaper/SettingsProvider.swift` | `PhospheneExtension/SettingsProvider.swift` |
| `Sources/LiveWallWallpaper/CodableShims.swift` | `PhospheneExtension/CodableShims.swift` |
| `Sources/LiveWallWallpaper/SettingsPush.swift` | `PhospheneExtension/SettingsPush.swift` |

```
MIT License

Copyright (c) 2026 kageroumado

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
