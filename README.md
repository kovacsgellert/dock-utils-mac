<img src="assets/icon-1024.png" width="128" alt="DockUtils icon">

# DockUtils

Small utilities for the macOS Dock:

- **Dock shortcuts:** hold **Option** to overlay numbered glass badges on your Dock icons, then press a number to switch to that app — a minimal, keyboard-first app switcher.
- **Dock clones:** optionally, a clone of the Dock on every other display, with zoomed and tiled windows kept clear of it.

Formerly DockShortcuts (`dock-shortcuts-mac`).

![Numbered glass badges above the Dock](screenshots/dock-overlay.png)

## How it works

1. Hold **Option** — frosted number badges appear beside each running app's Dock icon (100 ms delay, so quick `Option+letter` combos stay clean).
2. Press **1–9**, **0** (0 = 10th app) — the matching app activates, or hides if it's already frontmost. If the app has multiple windows open, repeat presses cycle through its windows instead of hiding.
3. Release **Option** — badges disappear.

Badge placement follows the Dock automatically (left / right / bottom) based on icon geometry.

## Dock clones on other displays

Optional, off by default: **Settings → Dock Clones → Show Dock clones on other displays** (or `dock_clones: true`) puts a clone of the Dock on every display the real Dock isn't on, like ExtraDock's Live Dock.

- Same items in the same order (apps, separator, folders, Trash), with running indicators, badges (unread counts) and hover labels. Matches the Dock's icon size and auto-hide, and by default its position (bottom/left/right).
- **Position per display:** Settings → Dock Clones shows your displays as they're arranged. Click near a display's bottom, left or right edge to put its clone there, at either end or centered; click the middle of a display to make it follow the Dock again or to turn its clone off. Each display remembers its choice (by display UUID), so it comes back when you reconnect that display. Displays you haven't set follow the Dock.
- Clicking an app presses the real Dock item, so it launches, activates or un-minimizes exactly like a Dock click. Folders and Trash open in Finder.
- Right-click (or Control-click) an item for Hide/Show, Show in Finder and Quit. Drop files on an app to open them with it, or on the Trash to move them there.
- Light or dark like the real Dock: the clones follow the system appearance, not DockUtils' own Appearance setting.
- Follows Dock changes, display connect/disconnect and rearrangement, and the real Dock moving between displays.
- The number badges (hold Option, or always visible) show on the clones too, so Option+number works from whichever display you're looking at.
- **Keep windows clear of the clones** (on by default): zoomed, filled and tiled windows stop at a clone's edge, as they do at the real Dock.

How windows are kept clear: the real Dock reserves space by shrinking `NSScreen.visibleFrame`, and there's no public API to reserve more. SkyLight's private `SLSSetDockRectWithReason` does shrink another display's `visibleFrame`, but it's a single global rect shared with the real Dock, so it can't serve more than one clone. Instead, DockUtils watches other apps' windows through Accessibility (`kAXWindowResizedNotification`, `kAXWindowMovedNotification`) and, once a resize or move settles, shrinks a window whose edge is at (or within a 16 pt tiling margin of) the screen edge under a clone. Window managers often only move a window into a same-sized tile, so moves count too, but mouse drags don't, so you can still drag windows over a clone. The catch: the window first animates under the clone, then snaps back about 0.15 s later.

Limitations: minimized windows aren't mirrored, folders don't pop up as stacks (or accept drops), and there's no magnification, bounce, progress bars or rearranging by dragging.

Under the hood: Dock icon positions come from the Accessibility API (`AXDockItem` elements of the Dock process), key interception via `CGEventTap`, badges are borderless `NSPanel`s with `NSVisualEffectView`.

## Requirements

- macOS 14+, Apple Silicon or Intel
- Swift toolchain (`xcode-select --install` is enough; full Xcode not required)
- **Accessibility permission**: the app needs it to read Dock icon positions and listen for the Option key, and for Dock clones to press Dock items and resize other apps' windows. Grant it in `System Settings → Privacy & Security → Accessibility` for your terminal (or the built binary) on first run.

## Build

```sh
swift build
./scripts/test.sh   # swift test, plus the paths Swift Testing needs without Xcode
```

## Install a released version

Via Homebrew:

```sh
brew tap kovacsgellert/tap
brew install --cask dock-utils
```

Or manually:

1. Download `dock-utils-<version>-macos-universal.dmg` from the [Releases page](https://github.com/kovacsgellert/dock-utils-mac/releases), open it, and drag **DockUtils** into **Applications**. (Prefer a guided install? Use `dock-utils-<version>-macos-universal.pkg` instead — it puts the app into `/Applications` automatically.)
2. Neither is notarized, so Gatekeeper blocks the first launch. On macOS 15 (Sequoia) and later, try to open the app once, then go to `System Settings → Privacy & Security`, scroll down and click **Open Anyway**. On macOS 14, right-click the app and choose **Open** instead.
3. Grant Accessibility permission when prompted (`System Settings → Privacy & Security → Accessibility`).
4. A settings window opens on first launch: toggle **Start automatically when you log in** if you want it always running. The window can be reopened anytime from the menu-bar icon.

### Updating

Update with `brew upgrade --cask dock-utils`, or by dragging the new version over the old one in Applications. Releases are signed with the same certificate, so the Accessibility permission carries over.

Coming from DockShortcuts: DockUtils is a new app as far as macOS is concerned (new name and bundle id `com.kovacsgellert.dock-utils`). Your `~/.config/dock-shortcuts/config.yml` is copied over on first launch. Grant Accessibility to **DockUtils**, then remove the old **DockShortcuts** entry there with **−** and delete `DockShortcuts.app` if it's still in Applications.

### Releasing

Releases are built automatically: pushing a version tag like `0.1.0` triggers the `Release` workflow, which packages the `.app`, builds the DMG, and attaches it to the GitHub Release.

Releases are signed with a self-signed certificate (no paid Apple Developer ID), stored in the `SIGNING_P12_BASE64` and `SIGNING_P12_PASSWORD` repository secrets. A stable signature is what lets macOS keep the Accessibility permission across updates; ad-hoc signatures change with every build. The workflow refuses to publish a release without it. The certificate is shared by all of the author's Mac apps (macOS keys permissions on bundle id + certificate, so apps stay separate); it was created once with `scripts/make-signing-cert.sh` into `~/.codesign/`. Keep its `.p12` and password backed up: a new certificate means every user has to grant Accessibility again. To sign a local build the same way, run `SIGNING_P12=<path> SIGNING_P12_PASSWORD=<password> ./scripts/package-app.sh`.

## Configuration file

Settings live in `~/.config/dock-utils/config.yml` — plain `key: value` pairs, safe to edit by hand or manage with scripts across machines. If `XDG_CONFIG_HOME` is set, `$XDG_CONFIG_HOME/dock-utils/config.yml` is used instead.

```yaml
start_at_login: false
show_menu_bar_icon: true
appearance: system  # system | light | dark
badge_delay_ms: 100  # 0...500
badges_always_visible: false  # persistent mini-badges on Dock icons
dock_clones: false  # clone the Dock onto your other displays
dock_clones_keep_windows_clear: true  # shrink zoomed/tiled windows out of the clones
dock_clones_display_37d8832a-2d66-02ca-b9f7-8f30a301b230: left-start  # DELL U2720Q
```

The `dock_clones_display_<uuid>` lines are the per-display clone positions, written by the settings window: `bottom`, `left` or `right`, optionally followed by `-start` or `-end` (the left or top end of the edge, or the right or bottom end), or `off`. Displays without a line follow the Dock. The comment names the display.

The file is created on first launch (existing installs migrate their current settings into it). Hand edits apply as soon as the file is saved, no relaunch needed. Everything is also editable from the settings window (**General → Open config.yml** opens the file); changes made there update values in place and keep your comments.


## Usage

List running Dock apps and their badge numbers:

```sh
swift run dock-utils --list
```

Activate an app by number (same as pressing it while holding Option):

```sh
swift run dock-utils --activate 2
```

Run the daemon (hold Option to badge, press a number to switch, `Ctrl+C` to quit):

```sh
swift run dock-utils --daemon
```

## AI usage disclosure

This app is completely vibe-coded — designed and written with an AI coding assistant, no hand-written code.

## License

MIT — see [LICENSE](LICENSE).

