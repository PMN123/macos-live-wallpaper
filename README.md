# LiveWall

An extremely lightweight native live wallpaper app for macOS. Pure Swift + AppKit + AVFoundation — no Electron, no web views, no dependencies. Lives in the menu bar.

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
![Platform: macOS 13+](https://img.shields.io/badge/Platform-macOS%2013%2B-lightgrey.svg)

## Features

- Plays any video (MP4, MOV, M4V…) as your desktop wallpaper, behind desktop icons, on every Space
- **Drag-and-drop Video Library** — a window where you collect your videos and click any one to set it as the wallpaper
- **Wallpaper in the menu bar** — extends the live wallpaper into the system menu bar so there's no seam between them (on by default; see note below)
- Multi-display: one shared hardware-accelerated decode pipeline drives all screens
- Power-efficient by design:
  - Auto-pauses when the wallpaper is fully hidden (fullscreen apps), when the screen locks or sleeps, and in Low Power Mode (all toggleable)
  - Never prevents display sleep; muted by default
- Scaling modes: Fill / Fit / Stretch
- Recent videos list, Launch at Login, drop a video on the app icon to set it
- Menu bar only — no Dock icon, ~no idle CPU

## Build

Requires macOS 13+ and Xcode Command Line Tools (`xcode-select --install`).

```bash
./build.sh
cp -R build/LiveWall.app /Applications/
open /Applications/LiveWall.app
```

## Use

Click the ✦ menu bar icon, then either:

- **Video Library…** — opens a window. Drag & drop videos into it, then click any tile to set it as your wallpaper. Hover a tile and click the × to remove it from the library.
- **Choose Video…** — pick a single file directly.

Everything else (play/pause, mute, scaling, *Wallpaper in Menu Bar*, login item) is in the same menu.

### Wallpaper in the menu bar

macOS owns the menu bar and only lets it sample the *desktop picture* — no app can make a window (live video included) bleed through it directly. So when **Wallpaper in Menu Bar** is on (the default), LiveWall feeds live frames of the playing video to the system desktop picture a few times a second, scaled to match your chosen Fill/Fit/Stretch mode. Because the full-screen wallpaper window covers the real desktop, those frames are only ever visible *through* the menu bar — so the bar reads as a seamless continuation of the wallpaper. When the video is paused, the last frame stays put so the bar still matches.

- Requires menu-bar translucency: **System Settings ▸ Accessibility ▸ Reduce Transparency** must be **off** (with it on, the bar is a solid color and LiveWall leaves your desktop picture alone).
- macOS always applies its own subtle menu-bar tint; that's system-owned and can't be removed, so the bar won't be pixel-identical to the wallpaper below it.
- This sets your desktop picture. When you turn the option off or quit, LiveWall leaves a high-res **still frame of the video** as your wallpaper rather than restoring whatever was there before — on macOS 26 the previous wallpaper may be an *aerial/dynamic* one that no public API can read back, so a clean still is the most reliable result. To go back to a different wallpaper, pick one in **System Settings ▸ Wallpaper**.

## Notes

- The ad-hoc signature is fine for personal use. To distribute, sign with a Developer ID and notarize.
- Settings persist in `defaults` under `com.praniil.livewall`.
- For minimum battery impact, prefer HEVC (H.265) videos at your display's native resolution.

## License

Licensed under the [Apache License 2.0](LICENSE). © 2026 Praniil Nagaraj.
