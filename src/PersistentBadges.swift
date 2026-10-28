import Cocoa

/// Persistent mini-badges: keeps an always-on overlay in sync with the Dock
/// while `badgesAlwaysVisible` is set — apps opening/closing renumber live.
/// Hold-to-show takes over while Option is held; this stands down meanwhile.
final class PersistentBadges: NSObject {
  private let overlay: OverlayManager
  private weak var hotkey: HotkeyManager?
  private var active = false
  private var lastKey: [String] = []

  init(overlay: OverlayManager, hotkey: HotkeyManager) {
    self.overlay = overlay
    self.hotkey = hotkey
    super.init()
    // Dock items, running state, order and settings arrive as .dockChanged
    // (see DockWatcher); config edits as .appConfigChanged.
    for name in [Notification.Name.dockChanged, .appConfigChanged] {
      NotificationCenter.default.addObserver(self, selector: #selector(sync), name: name, object: nil)
    }
    // Dock clones moved or appeared: their badges need redrawing even
    // though the real Dock didn't change.
    NotificationCenter.default.addObserver(self, selector: #selector(clonesChanged), name: .dockClonesChanged, object: nil)
    // A display entered or left a full-screen Space: badges hide there.
    NotificationCenter.default.addObserver(self, selector: #selector(clonesChanged), name: .fullscreenDisplaysChanged, object: nil)
    // The real Dock hopping to another display sends no event: slow poll.
    Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
      self?.sync()
    }
  }

  var isActive: Bool { active }

  /// Identity + coarse position: renumbers on open/close/reorder, ignores
   /// sub-pixel jitter (e.g. Dock magnification hover) to avoid flicker.
  private static func key(_ apps: [DockApp]) -> [String] {
    apps.map {
      "\($0.index)|\($0.title)|\($0.bundleURL?.path ?? "")|\(Int($0.frame.minX / 4))|\(Int($0.frame.minY / 4))"
    }
  }

  @objc private func clonesChanged() {
    lastKey = []
    sync()
  }

  @objc func sync() {
    guard AppConfig.shared.badgesAlwaysVisible, hotkey?.isOptionHeld == false else {
      // Hide minis only when the feature is off. While held with the feature
      // on they stay put: no hold overlay replaces them, so hiding would
      // flash the Dock bare until release.
      if !AppConfig.shared.badgesAlwaysVisible, overlay.styleShown == .persistent {
        Task { await overlay.hide() }
        active = false
      }
      return
    }
    let apps = DockReader.runningAppItems()
    let k = Self.key(apps)
    // Re-show when the overlay isn't showing persistent minis (e.g. a hold
    // overlay took over, or they were hidden) or the Dock changed.
    guard overlay.styleShown != .persistent || k != lastKey else { return }
    active = true
    lastKey = k
    Task { await overlay.show(apps: apps, style: .persistent) }
  }
}
