# Menu‑bar wallpaper on macOS 26 (Tahoe): investigation & findings

**Status:** Known limitation — not fixable from an app with public APIs as of macOS 26.0 (Tahoe, Darwin 25.x). Documented here so contributors don't re‑attempt the same dead ends.

This is a technical writeup of why the **"Wallpaper in Menu Bar"** feature doesn't reliably work on Tahoe, backed by direct on‑device measurements. It also covers two adjacent requests (animated lock screen, removing the menu‑bar tint) that turn out to be impossible with public APIs.

---

## TL;DR

- The translucent macOS menu bar **only samples the desktop‑picture file** for its background. It does **not** blur arbitrary windows behind it — so you cannot render a live video into the bar with a window, at any window level.
- Feeding frames to the desktop picture via `NSWorkspace.setDesktopImageURL` **can** change the bar, but the window server **re‑samples the bar lazily** (≈10 s+, or on a recomposite event such as ⌘‑Tab / Mission Control / Space switch) and **coalesces away rapid updates**. There is no app‑drivable cadence that reliably updates the bar.
- Net result: a **live/animated** menu bar is impossible, and even a **static "update the bar when the wallpaper changes"** is unreliable (the set is usually coalesced until the next system recomposite).
- The **menu‑bar tint** is the system's own material; no app can remove it (the only switch is Reduce Transparency, which makes the bar fully opaque).
- An **animated / mp4 lock screen** is impossible: third‑party code cannot run in or draw the lock screen (login window) context, and no public API sets a custom/animated lock‑screen background.

---

## How the feature is supposed to work

macOS doesn't let an app draw into the menu bar (that would cover the clock/menus). So LiveWall's approach (`MenuBarWallpaperDriver`):

1. Cover the whole desktop with a full‑screen, desktop‑level window playing the video.
2. Repeatedly grab the current video frame and install it as the **desktop picture** (`setDesktopImageURL`), alternating between two files to defeat path‑based de‑duplication.
3. The translucent menu bar samples that desktop picture, so the bar appears to be a continuation of the wallpaper.

This worked well enough on earlier macOS. On Tahoe it does not.

## Symptoms reported

1. The menu bar doesn't update when you switch wallpapers (on a normal screen, no interaction).
2. ⌘‑Tab "refreshes" the bar, and the result is a stale / wrong frame.
3. The bar carries a tint that doesn't match the wallpaper.
4. (Adjacent ask) make the lock screen an animated mp4 that changes with the wallpaper.

## Investigation — what was measured on‑device

All measurements were taken on the affected machine (macOS 26 / Darwin 25.5.0, Reduce Transparency = **off**) by capturing the menu‑bar strip with `screencapture` and comparing pixels. Method is reproducible (see "Repro harness" below).

### Experiment 1 — Can a window behind the bar feed it? **No.**

A borderless window was pinned over the menu‑bar strip at one level **below** `CGWindowLevelForKey(.mainMenuWindow)`, hosting the live `AVPlayerLayer`, so the bar's backdrop would sit directly over moving video.

- Wallpaper region just below the bar: mean abs pixel change ≈ **0.57–0.98** (video animating).
- Menu‑bar strip itself: mean abs pixel change = **0.00** (dead static).

**Conclusion:** the bar does **not** blur whatever window happens to be behind it. It samples the desktop‑picture **file** specifically. A live, window‑based menu bar is therefore impossible.

### Experiment 2 — Does `setDesktopImageURL` change the bar at all? **Yes, once, in isolation.**

With the covering window present, the desktop picture was set to a solid color **once**:

- Set red → bar average color went `(242,242,242)` → `(243,123,113)` (clearly red‑tinted).
- Later, single set blue → bar average went to `(112,172,243)` (clearly blue).

**Conclusion:** the file‑injection path is real; an isolated change *can* re‑tint the bar.

### Experiment 3 — Does rapid/continuous setting work (what the driver actually does)? **No.**

- Flooded `setDesktopImageURL` with a blue image **40× at ~60 ms intervals** (more aggressive than the driver's 0.2 s pump). The bar **stayed on the previous color** — every rapid set was ignored/coalesced.
- Spacing isolated sets **1.5–3.0 s** apart and cycling red/green/blue: the bar landed on the target in only **~1 of 5** attempts; mostly it sat frozen on a stale color regardless of timing.

**Conclusion:** the window server re‑samples the menu‑bar backdrop on **its own schedule** (empirically ≈10 s+, or when a recomposite event like ⌘‑Tab / Mission Control / Space switch forces it) and **coalesces away** app‑driven desktop‑picture churn. No cadence an app can use updates the bar promptly or reliably.

## Root cause

Every reported menu‑bar symptom follows from Experiment 3:

- **No update on wallpaper switch** — the single (or pumped) `setDesktopImageURL` is coalesced; the bar's cached blur is not invalidated.
- **⌘‑Tab shows a stale/wrong frame** — ⌘‑Tab forces a recomposite, which re‑samples whatever frame is in the desktop‑picture file at that instant (with a 5 fps pump that's an arbitrary, unrelated frame).

This is **not** a logic bug in `MenuBarWallpaperDriver`. It is an OS throttle/caching policy that an app cannot defeat with public APIs. The old (`MenuBarBlurDriver`, 3 fps) and reworked (`MenuBarWallpaperDriver`, 5 fps) implementations share this exact mechanism and limitation.

Additional Tahoe context: the wallpaper store moved to `~/Library/Application Support/com.apple.wallpaper/Store/Index.plist`, and `NSWorkspace.desktopImageURL(for:)` returns **nil for aerial/dynamic wallpapers**, so the legacy `setDesktopImageURL` path is increasingly decoupled from what actually feeds the bar.

## The menu‑bar tint (symptom 3) — separate, also unfixable

The tint is the menu bar's own translucent **material**, applied on top of whatever it samples. No public API removes it. The only system control is **System Settings ▸ Accessibility ▸ Reduce Transparency**, which makes the bar fully **opaque** (the opposite of what's wanted). So even a hypothetically perfect wallpaper bar would still carry this tint.

## Lock screen (symptom 4) — impossible with public APIs

There is no public (or app‑accessible) way to set a custom or animated lock‑screen / login‑window background. When the screen is locked the user session is secured and a third‑party app isn't running in that context, so it cannot draw or animate there. Apple's own aerials are the only animated lock‑screen option and are system‑only. This request cannot be implemented.

## Options for contributors

There is no known way to make the live/animated menu bar work reliably on Tahoe. Realistic directions, honestly weighed:

1. **Remove the menu‑bar feature (recommended).** Stop touching the desktop picture entirely. Bonus: this also fixes the separate "LiveWall leaves a static still as the desktop picture after quit" problem, because nothing modifies the desktop picture — quitting simply restores the user's real wallpaper.
2. **Best‑effort static frame on switch (degraded).** On wallpaper switch, do a single `setDesktopImageURL` with the current frame. Downsides: it often won't visibly update until the next recomposite (⌘‑Tab), *and* it reintroduces the leftover‑still‑on‑quit problem. Not recommended.
3. **Find a public trigger that forces a menu‑bar re‑sample.** None is known. ⌘‑Tab / Mission Control / Space switch work but are user gestures; no public API reproduces them invisibly. If someone finds a non‑private, non‑flickering way to force the window server to re‑sample the bar, option 2 becomes viable. Private SkyLight/WindowServer calls are out of scope (fragile, unsupportable).

## Repro harness

To re‑verify on any machine (Reduce Transparency must be **off**):

```bash
# 1. Capture the menu-bar strip
screencapture -x -R0,0,1440,24 /tmp/bar.png

# 2. Set the desktop picture (mimics MenuBarWallpaperDriver). Compile once:
cat > /tmp/setdesk.swift <<'SWIFT'
import AppKit
let url = URL(fileURLWithPath: CommandLine.arguments[1])
for s in NSScreen.screens {
    try? NSWorkspace.shared.setDesktopImageURL(url, for: s, options: [
        .imageScaling: NSImageScaling.scaleAxesIndependently.rawValue,
        .allowClipping: true])
}
SWIFT
swiftc -O /tmp/setdesk.swift -o /tmp/setdesk

# 3. Compare bar pixels before/after a single set, then after a rapid flood.
#    Single isolated set: bar changes. Rapid flood / closely-spaced sets: ignored.
```

Average the bar's open area (e.g. x≈400–1700 of a 2880‑px‑wide capture, avoiding the Apple logo and clock) before/after each set to quantify whether the bar actually re‑sampled.

---

*Environment: macOS 26.0 (Tahoe), Darwin 25.5.0, Apple Silicon, single Retina display, Reduce Transparency off. Findings expected to generalize across Tahoe; the throttle timing may vary by machine/load.*
