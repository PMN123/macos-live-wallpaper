# LiveWall

An extremely lightweight native live wallpaper app for macOS. Pure Swift + AppKit + AVFoundation — no Electron, no web views, no dependencies. Lives in the menu bar.

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
![Platform: macOS 13+](https://img.shields.io/badge/Platform-macOS%2013%2B-lightgrey.svg)

## Features

- Plays any video (MP4, MOV, M4V…) as your desktop wallpaper, behind desktop icons, on every Space
- **Drag-and-drop Video Library** — a window where you collect your videos and click any one to set it as the wallpaper
- Multi-display: one shared hardware-accelerated decode pipeline drives all screens
- Power-efficient by design:
  - Auto-pauses when the wallpaper is fully hidden (fullscreen apps) and in Low Power Mode (both toggleable), and whenever the screen locks or sleeps or you switch to another user
  - Never prevents display sleep; muted by default
- Scaling modes: Fill / Fit / Stretch
- Recent videos list, Launch at Login, drop a video on the app icon to set it
- Never changes your system desktop picture, so quitting LiveWall shows whatever wallpaper you've set in System Settings
- Menu bar only — no Dock icon, ~no idle CPU

## Build

Requires macOS 13+ and Xcode Command Line Tools (`xcode-select --install`).

```bash
./build.sh
cp -R build/LiveWall.app /Applications/
open /Applications/LiveWall.app
```

## Use

Click the LiveWall icon (a TV with sparkles) in the menu bar, then either:

- **Video Library…** — opens a window. Drag & drop videos into it, then click any tile to set it as your wallpaper. Click the × on a tile to remove it from the library.
- **Choose Video…** — pick a single file directly.

Everything else (play/pause, mute, scaling, pause options, login item) is in the same menu. If playback is being held automatically (Low Power Mode, a fullscreen app, a locked screen…), the menu says why.

## Notes

- On macOS 26 the menu bar has no background by default, so the live wallpaper shows straight through it with no extra work. If you give the menu bar a background in **System Settings ▸ Menu Bar** or turn on **Reduce Transparency**, it covers the video. An earlier "Wallpaper in Menu Bar" mode that pushed video frames into the desktop picture was removed: macOS ignores rapid desktop-picture changes, and the mode overwrote your real wallpaper (see [issue #1](https://github.com/PMN123/macos-live-wallpaper/issues/1)).
- **Upgrading from 1.0?** Its *Wallpaper in Menu Bar* mode (on by default) replaced your desktop picture with a still frame of the video. LiveWall no longer touches it, so pick your wallpaper again once in **System Settings ▸ Wallpaper**; after that you can delete `~/Library/Application Support/LiveWall/`.
- The ad-hoc signature is fine for personal use. To distribute, sign with a Developer ID and notarize.
- Settings persist in `defaults` under `com.praniil.livewall`.
- For minimum battery impact, prefer HEVC (H.265) videos at your display's native resolution.

## License

Licensed under the [Apache License 2.0](LICENSE). © 2026 Praniil Nagaraj.
