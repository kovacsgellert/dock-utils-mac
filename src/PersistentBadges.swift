import Cocoa

/// Persistent mini-badges: keeps an always-on overlay in sync with the Dock
/// while `badgesAlwaysVisible` is set — apps opening/closing renumber live.
/// Hold-to-show takes over while Option is held; this stands down meanwhile.
@MainActor
final class PersistentBadges {
  private let overlay: OverlayManager
  private weak var hotkey: HotkeyManager?
  private var lastKey: [String] = []
  private var appearanceObservation: NSKeyValueObservation?

  init(overlay: OverlayManager, hotkey: HotkeyManager) {
    self.overlay = overlay
    self.hotkey = hotkey
    let center = NotificationCenter.default
    // Dock and settings changes arrive through DockModel, which also polls
    // for the changes that send no event (e.g. the Dock moving displays).
    center.observeOnMain(.dockSnapshotUpdated) { [weak self] _ in self?.sync() }
    // Dock clones moved or appeared: their badges need redrawing even
    // though the real Dock didn't change. A display entering or leaving a
    // full-screen Space: badges hide there.
    for name in [Notification.Name.dockClonesChanged, .fullscreenDisplaysChanged] {
      center.observeOnMain(name) { [weak self] _ in self?.redraw() }
    }
    // Light/dark switches (by the system, or in Settings): the glass is
    // drawn for one appearance.
    appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
      DispatchQueue.main.async { self?.sync() }
    }
  }

  /// Identity + coarse position + appearance: renumbers on open/close/
  /// reorder and redraws on a light/dark switch, but ignores sub-pixel
  /// jitter (e.g. Dock magnification hover) to avoid flicker.
  private static func key(_ apps: [DockApp]) -> [String] {
    ["dark:\(AppAppearance.isDark)"] + apps.map {
      "\($0.index)|\($0.title)|\($0.bundleURL?.path ?? "")|\(Int($0.frame.minX / 4))|\(Int($0.frame.minY / 4))"
    }
  }

  private func redraw() {
    lastKey = []
    sync()
  }

  func sync() {
    guard AppConfig.shared.badgesAlwaysVisible, hotkey?.isOptionHeld == false else {
      // Hide minis only when the feature is off. While held with the feature
      // on they stay put: no hold overlay replaces them, so hiding would
      // flash the Dock bare until release.
      if !AppConfig.shared.badgesAlwaysVisible, overlay.styleShown == .persistent {
        overlay.hide()
      }
      return
    }
    let apps = DockModel.shared.snapshot?.runningApps ?? []
    let k = Self.key(apps)
    // Re-show when the overlay isn't showing persistent minis (e.g. a hold
    // overlay took over, or they were hidden) or the Dock changed.
    guard overlay.styleShown != .persistent || k != lastKey else { return }
    lastKey = k
    overlay.show(apps: apps, style: .persistent)
  }
}
