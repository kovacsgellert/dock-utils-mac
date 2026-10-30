# Changelog

## 2.2.0

### New

- Dock clones: choose where the clone goes on each display, from a map
  of your displays in Settings → Dock Clones: the bottom, left or right
  edge, centered or at either end, or no clone at all. Each display
  remembers its choice and gets it back when it's connected again;
  displays you haven't set follow the Dock, as before. Stored in
  config.yml as one `dock_clones_display_<uuid>` line per display

### Fixed

- Dock clones update when a different display is connected in the place
  of one with the same size

## 2.1.0

### New

- Runs on Intel Macs too: releases are a universal app. The downloads
  are now named `dock-utils-<version>-macos-universal.dmg` / `.pkg`
- Dock clones: right-click (or Control-click) an item for Hide/Show,
  Show in Finder and Quit; drop files on an app to open them with it, or
  on the Trash to move them there
- Settings shows an Accessibility warning on every tab while the
  permission is missing, with a button to System Settings
- Settings → General → Open config.yml

### Changed

- No badges while a mouse button is down, so Option-click and
  Option-drag (copying in Finder, duplicating in design apps) don't
  flash them over the Dock
- Dock clones follow the system's light/dark setting, like the real
  Dock, rather than DockUtils' own Appearance setting
- Changing a setting in the settings window keeps your comments and
  layout in config.yml
- Badge delay moves in 25 ms steps
- Running apps in the Dock's recent-apps section get numbers too
- The Dock is read once for the clones and always-visible badges
  together, not once per feature

### Fixed

- Apps past the 10th no longer get badges: the 11th showed "1", but
  Option+1 switched to the first app
- Holding Option+number no longer keeps cycling windows or flipping the
  app between hidden and shown
- The Option-hold badges could stay on screen after Option was released
- Badges land on the right side of the icons when the Dock is on a
  display other than the main one
- Always-visible badges redraw when the appearance switches between
  light and dark
- Option+digit is only taken when an app has that number, so keyboard
  layouts that type `[ ] | { }` with Option+digit keep working
- An unresponsive app can no longer stall badges and Dock clones for
  seconds at a time
- Start at login no longer turns itself back on at launch after being
  switched off in System Settings → General → Login Items; Settings
  explains how to allow it there instead

## 2.0.3

### Fixed

- Shortcut badges and Dock clones no longer show over a full-screen app
  (e.g. a full-screen video). They join every Space, so they stayed on top
  of full-screen Spaces too, where the real Dock hides. Now each display
  showing a full-screen app gets neither badges nor a clone, and both come
  back when it leaves full screen

## 2.0.2

### Fixed

- Settings opens in front of other windows when opened from the menu-bar
  icon (or after clicking the running app): the app is a menu-bar agent
  (`LSUIElement`), so ordering the window front while the app was inactive
  parked it behind the frontmost app's windows, with no Dock icon to bring
  it forward again. Opening Settings now activates the app first (which
  keeps it out of the Dock) and then raises the window above every other
  app

## 2.0.1

### Fixed

- Keep windows clear of the clones also works for window managers that
  only move a window (to a same-sized tile, or to another display), such as
  Vorssaint's quarter shortcuts. Dragging a window with the mouse still
  leaves it over a clone

## 2.0.0

DockShortcuts is now **DockUtils**: the number shortcuts plus a new,
optional Dock clone on every other display.

### New

- Dock clones (Settings → Dock Clones, off by default): a clone of the
  Dock on every display the real Dock isn't on, with the same items in
  the same order, running indicators, app badges (unread counts) and
  hover labels. Follows the Dock's position (bottom, left, right), icon
  size and auto-hide, and keeps up with apps launching, quitting, being
  pinned or reordered, and with displays being connected or rearranged.
  Clicking an icon behaves exactly like clicking it in the Dock
- Keep windows clear of the clones (on by default): zoomed, filled and
  tiled windows stop at a clone's edge, as they do at the real Dock
- Number badges also show on the Dock clones, so Option+number works
  from whichever display you're looking at

### Changed

- Renamed to DockUtils (`dock-utils-mac`, bundle id
  `com.kovacsgellert.dock-utils`, Homebrew cask `dock-utils`)
- Settings window has tabs: General, Dock Shortcuts, Dock Clones and
  About
- Always-visible badges on a side Dock sit at the icon's bottom corner
  facing the screen center, as close to the Dock's edge as fits (top-left
  for a bottom Dock, as before)
- Reacts to changes as they happen instead of polling: config.yml edits,
  Dock changes and the Accessibility permission being granted
- App icon: white dots and bar for more contrast

### Fixed

- Option+number restores an app's minimized window instead of hiding the
  app
- Always-visible badges stay on screen with the Dock on the left (macOS
  reports a left Dock's icon positions mirrored)

### Upgrading from DockShortcuts

macOS treats DockUtils as a new app. `brew upgrade` moves the
`dock-shortcuts` cask to `dock-utils`; for manual installs, delete
`DockShortcuts.app`. Then grant Accessibility to **DockUtils** and remove
the old **DockShortcuts** entry there. Settings, including start at
login, are copied from `~/.config/dock-shortcuts/` on first launch.

## 1.3.0

- No changes since 1.3.0-beta1

## 1.3.0-beta1

- Settings: Quit DockShortcuts button, so the app can be closed even with
  the menu bar icon hidden
- Releases are signed with a stable self-signed certificate, so macOS keeps
  the Accessibility permission across updates. Updating to this release from
  1.2.0 or older still needs one re-grant (see README → Updating)
- README: first-launch steps for macOS 15+ (Open Anyway)

## 1.2.0

- No changes since 1.2.0-beta1

## 1.2.0-beta1

- Option+number only triggers with Option alone: combos that add Cmd, Ctrl
  or Shift (e.g. Option+Cmd+Ctrl+4) pass through to other apps, and badges
  hide while those modifiers are held

## 1.1.0

- Repeat-pressing an app's number cycles through its windows when it has
  several open (instead of hiding it)
- Dev builds no longer touch the start-at-login item; the toggle is
  disabled there

## 1.0.0

- Rename to DockShortcuts (`dock-shortcuts-mac`): new bundle id
  `com.kovacsgellert.dock-shortcuts`, settings migrate automatically
  from the old config location

## 0.2.0

- Always-visible: holding Option no longer pops badges out (no visible change)
- Disable badge-delay slider when always-visible is on

## 0.2.0-beta1

- Always-visible Dock badges with live Dock tracking
- Settings: always-visible toggle, Appearance moved last

## 0.1.4

- Restore minimized Finder windows on switch

## 0.1.3

- Show app icon at top of README
- Versioned installer filenames

## 0.1.2

- Fix settings group boxes staying dark in light mode

## 0.1.1

- Fix `.pkg` to always install into `/Applications`

## 0.1.0

- Add app icon + menu-bar template (code-rendered)
- Wire custom icon into the `.app` bundle and menu bar
- Show settings window on reopen (Spotlight/click while running)
- Add show/hide menu-bar icon setting
- Retain status item, apply menu-bar visibility live
- Lay settings out as a grid: labels left, controls right
- Add About section in settings: author + repo link
- Restyle settings macOS-style: icon header, grouped sections
- Portable `~/.config` YAML settings store + configurable badge delay
- Settings: delay slider, disk-backed refresh, layout overflow fixes
- Add `--no-accessibility` flag for headless UI testing
- Group name + repo link under an About section
- Fix settings launch crash, footer centering, row rhythm
- Unify settings alignment: About leading, even row heights
- Show app name (+ version) as menu-bar menu header
- Menu-bar icon: mini dock with badge dots instead of 1-disc
- Match app icon to menu-bar motif; show version in settings
- Honor `XDG_CONFIG_HOME` for the config file location
- Add dock overlay screenshot to README
- Ship the app: `.app` bundle, DMG installer, settings, themes
- Open a new Finder window when switching to Finder with none open
- Add `.pkg` installer that puts the app into `/Applications`
- Hold Option to badge Dock icons, press number to switch apps
- Move sources to `src/`, add README, MIT license, AI disclosure
- Tag-triggered release workflow with install docs
