# LiveWall

An extremely lightweight native live wallpaper app for macOS. Pure Swift + AppKit + AVFoundation — no Electron, no web views, no dependencies. Lives in the menu bar.

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
![Platform: macOS 13+](https://img.shields.io/badge/Platform-macOS%2013%2B-lightgrey.svg)

## Features

- Plays any video (MP4, MOV, M4V…) as your desktop wallpaper, behind desktop icons, on every Space
- **Drag-and-drop Video Library** — a window where you collect your videos and click any one to set it as the wallpaper
- Multi-display: one shared hardware-accelerated decode pipeline drives all screens
- Power-efficient by design:
  - LiveWall's own window auto-pauses when the wallpaper is fully hidden (fullscreen apps) and in Low Power Mode (both toggleable), and whenever the screen locks or sleeps or you switch to another user. In [system wallpaper mode](#system-wallpaper-mode-macos-26-experimental) macOS decides instead
  - Never prevents display sleep; muted by default
- Scaling modes: Fill / Fit / Stretch
- Recent videos list, Launch at Login, drop a video on the app icon to set it
- Never edits your wallpaper settings itself. In its normal window mode, quitting LiveWall shows whatever wallpaper you've set in System Settings. The optional [system wallpaper mode](#system-wallpaper-mode-macos-26-experimental) (macOS 26+) is something you turn on, and off, in System Settings yourself
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

Everything else (play/pause, mute, scaling, pause options, login item) is in the same menu. If LiveWall's window is holding playback automatically (Low Power Mode, a fullscreen app, a locked screen…), the menu says why.

## System wallpaper mode (macOS 26+, experimental)

Normally LiveWall plays the video in a window behind your desktop icons. On macOS 26 it can instead hand the video to macOS, which then draws it as the real wallpaper:

- on every Space, behind the menu bar, including while you click the wallpaper to reveal the desktop (where a window can't follow)
- on the lock screen, where it keeps playing

LiveWall then closes its own window, so the video is decoded only once. It follows LiveWall's menu for the video you pick, Pause/Play and scaling, but adds no pauses of its own: it behaves like one of macOS's own video wallpapers, and macOS decides when it plays. macOS stops drawing the wallpaper when it isn't visible, for example while the display is asleep or another Space is showing, and holds it while a screen saver covers it. The LiveWall tile is offered for the wallpaper only, not in the Screen Saver picker: LiveWall can't tell its own screen saver apart from another one, so as a screen saver it would show a still frame. **Pause When Hidden** and **Pause in Low Power Mode** apply only to LiveWall's own window, so the menu shows them disabled in this mode. System wallpaper mode is always silent; the Mute setting applies only to LiveWall's own window.

macOS keeps a wallpaper extension playing while app windows cover the desktop, which costs a few percent of CPU. If that matters to you, choose **Pause** in LiveWall's menu, or use LiveWall's own window mode, which pauses when the wallpaper is hidden.

> **Experimental.** This mode uses private macOS interfaces: the undocumented wallpaper-extension protocol of WallpaperAgent and a private Core Animation class. A macOS update can break it. If the system wallpaper stops responding, LiveWall notices within about half a minute and goes back to its own window.

**Set up**

1. Build and install LiveWall as above (`./build.sh`, copy to `/Applications`, open it).
2. Choose **Use as System Wallpaper…** in LiveWall's menu. LiveWall registers its bundled wallpaper extension with macOS if needed (`pluginkit`), then opens **System Settings ▸ Wallpaper**.
3. Pick the **LiveWall** tile, then turn on **Show on all Spaces**. With more than one display, pick LiveWall for every display: while the system wallpaper plays, LiveWall closes its own window on all displays, so a display left on another wallpaper shows that wallpaper. If the tile is missing, quit System Settings and open it again.

LiveWall's menu then says **Playing as system wallpaper**. To change the video, use LiveWall's menu or Video Library as usual; the wallpaper follows.

Until you use this mode, LiveWall writes nothing for it. Once it is on, LiveWall shares the current video with the extension through `~/Library/Application Support/LiveWall/Wallpaper/`. That folder holds a copy of the video, a thumbnail for the Settings tile, `state.json`, and the extension's log, `extension.log`. The copy is an APFS clone, which takes no extra disk space, when the video is on the same volume as your home folder; a video on another volume is copied in full.

**Undo**

- Pick any other wallpaper in **System Settings ▸ Wallpaper**. LiveWall never writes the system wallpaper settings; macOS records your choice. If LiveWall is still running with a video, it goes back to playing it in its own window a few seconds later and stops sharing videos with the extension; choose **Remove Wallpaper** or quit LiveWall to see the wallpaper you picked.
- Quitting LiveWall does not undo system wallpaper mode: macOS keeps playing the last video, or keeps it paused if you paused it in LiveWall.
- If you delete LiveWall while its tile is selected, macOS falls back to the default wallpaper.
- To remove every trace, first pick another wallpaper and quit LiveWall. Then:
  1. Run `pluginkit -m -v -i com.praniil.livewall.wallpaper`. It prints the path of the registered extension (it may be a build folder rather than `/Applications`). Unregister that copy with `pluginkit -r "<that path>"`.
  2. Delete `~/Library/Application Support/LiveWall/Wallpaper/` and the extension's sandbox container, `~/Library/Containers/com.praniil.livewall.wallpaper/`.

## Notes

- On macOS 26 the menu bar has no background by default, so the live wallpaper shows straight through it with no extra work. One exception: while you click the wallpaper to reveal the desktop, macOS draws the menu bar over its own wallpaper, not over LiveWall's window. Use [system wallpaper mode](#system-wallpaper-mode-macos-26-experimental) to keep the video there too. If you give the menu bar a background in **System Settings ▸ Menu Bar** or turn on **Reduce Transparency**, it covers the video. An earlier "Wallpaper in Menu Bar" mode that pushed video frames into the desktop picture was removed: macOS ignores rapid desktop-picture changes, and the mode overwrote your real wallpaper (see [issue #1](https://github.com/PMN123/macos-live-wallpaper/issues/1)).
- **Upgrading from 1.0?** Its *Wallpaper in Menu Bar* mode (on by default) replaced your desktop picture with a still frame of the video. LiveWall no longer touches it, so pick your wallpaper again once in **System Settings ▸ Wallpaper**. After that you can delete the old files in `~/Library/Application Support/LiveWall/`. Keep its `Wallpaper` folder if you use system wallpaper mode.
- The ad-hoc signature is fine for personal use. To distribute, sign with a Developer ID and notarize.
- Settings persist in `defaults` under `com.praniil.livewall`.
- For minimum battery impact, prefer HEVC (H.265) videos at your display's native resolution.

## License

Licensed under the [Apache License 2.0](LICENSE). © 2026 Praniil Nagaraj.
