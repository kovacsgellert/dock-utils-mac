import Cocoa

/// Dock clones: one clone of the system Dock per other display, kept in sync
/// with the Dock, its settings and the display arrangement. Off unless
/// `dock_clones` is set; idle (no AX reads, no window watching) while off.
extension Notification.Name {
  /// The clones' icons moved, appeared or disappeared (rebuild, auto-hide).
  static let dockClonesChanged = Notification.Name("dock-utils.dockClonesChanged")
}

final class DockClones {
  static let shared = DockClones()

  private var panels: [CGDirectDisplayID: DockClonePanel] = [:]
  private var snapshot = DockSnapshot()
  private var prefs = DockPrefs()
  private var config = AppConfig.shared
  private var screensKey: [CGRect] = []
  private var dockScreenID: CGDirectDisplayID?
  /// Displays showing a full-screen app, as of the last rebuild.
  private var fullscreenKey: Set<CGDirectDisplayID> = []
  private let guardian = WindowGuard()
  private var pendingHide: [CGDirectDisplayID: DispatchWorkItem] = [:]
  private var lastIconsKey: [String] = []

  func start() {
    refresh(force: true)
    NotificationCenter.default.addObserver(forName: .dockChanged, object: nil, queue: .main) { [weak self] _ in
      self?.refresh()
    }
    NotificationCenter.default.addObserver(forName: .appConfigChanged, object: nil, queue: .main) { [weak self] _ in
      self?.refresh(force: true)
    }
    NotificationCenter.default.addObserver(forName: .fullscreenDisplaysChanged, object: nil, queue: .main) { [weak self] _ in
      self?.refresh()
    }
    // Everything else arrives as .dockChanged (see DockWatcher), but badge
    // changes and the real Dock hopping displays send no event at all.
    Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.refresh() }
  }

  func refresh(force: Bool = false) {
    let freshConfig = AppConfig.shared
    guard freshConfig.dockClones else {
      if config.dockClones || force { config = freshConfig; removeAll() }
      return
    }
    guard let fresh = DockReader.snapshot() else { return }
    let freshPrefs = DockPrefs.read()
    let freshScreens = NSScreen.screens.map(\.frame)
    let freshDockScreen = Self.screenID(containing: Coords.flip(fresh.frame))
    let freshFullscreen = FullscreenSpaces.shared.displays
    let changed = force || fresh != snapshot || freshPrefs != prefs || freshConfig != config
      || freshScreens != screensKey || freshDockScreen != dockScreenID || freshFullscreen != fullscreenKey
    snapshot = fresh
    guard changed else { return }
    prefs = freshPrefs
    config = freshConfig
    screensKey = freshScreens
    dockScreenID = freshDockScreen
    fullscreenKey = freshFullscreen
    rebuild()
  }

  private func rebuild() {
    var keep: Set<CGDirectDisplayID> = []
    for screen in NSScreen.screens {
      // The real Dock hides under a full-screen app; so does the clone, and
      // it comes back once its display no longer shows a full-screen app.
      guard let id = screen.displayID, id != dockScreenID, !fullscreenKey.contains(id) else { continue }
      keep.insert(id)
      let layout = DockCloneLayout(items: snapshot.items, prefs: prefs, screen: screen.frame)
      if let panel = panels[id] {
        panel.update(layout: layout, items: snapshot.items)
      } else {
        let panel = DockClonePanel(screenID: id, layout: layout, items: snapshot.items) { [weak self] item in
          self?.click(item)
        }
        panel.onPointer = { [weak self] inside in self?.pointer(inside: inside, id: id) }
        panels[id] = panel
      }
      panels[id]?.setRevealed(!prefs.autohide, animated: false)
    }
    for (id, panel) in panels where !keep.contains(id) {
      panel.close()
      panels[id] = nil
    }
    // Auto-hidden Docks don't reserve space, same as the real one.
    let reserved = prefs.autohide ? [] : panels.values.map { (edge: $0.layout.edge, rect: $0.layout.reserved) }
    guardian.setReserved(config.dockClonesKeepWindowsClear ? reserved : [])
    iconsMayHaveMoved()
  }

  /// Where an app's icon sits on each visible clone (Cocoa coordinates),
  /// so shortcut badges can be drawn there too. Matched by bundle path,
  /// like the real Dock's own badges.
  func icons(of url: URL?, title: String) -> [(frame: CGRect, edge: DockEdge, dock: CGRect)] {
    var out: [(frame: CGRect, edge: DockEdge, dock: CGRect)] = []
    for panel in panels.values where panel.isRevealed {
      let layout = panel.layout
      for (item, slot) in zip(snapshot.items, layout.itemRects) where item.kind == .app {
        guard url.map({ $0.path == item.url?.path }) ?? (item.title == title) else { continue }
        let slot = slot.offsetBy(dx: layout.frame.minX, dy: layout.frame.minY)
        let icon = CGRect(x: slot.midX - layout.tile / 2, y: slot.midY - layout.tile / 2, width: layout.tile, height: layout.tile)
        out.append((icon, layout.edge, layout.frame))
      }
    }
    return out
  }

  /// Tell badge overlays to redraw, but only when icon positions changed
  /// (not for every badge count or running-state flip).
  private func iconsMayHaveMoved() {
    let key = panels.values.filter(\.isRevealed).map { panel in
      "\(panel.layout.frame)|" + snapshot.items.map { $0.url?.path ?? $0.title }.joined(separator: ",")
    }.sorted()
    guard key != lastIconsKey else { return }
    lastIconsKey = key
    NotificationCenter.default.post(name: .dockClonesChanged, object: nil)
  }

  private func removeAll() {
    for panel in panels.values { panel.close() }
    panels.removeAll()
    guardian.setReserved([])
    // Rebuild from scratch when switched back on.
    snapshot = DockSnapshot()
    iconsMayHaveMoved()
  }

  private func click(_ item: DockItem) {
    switch item.kind {
    case .app:
      // Pressing the real Dock item behaves exactly like a Dock click
      // (launch, activate, un-minimize, bounce).
      if let el = item.element, AXUIElementPerformAction(el, kAXPressAction as CFString) == .success { break }
      if let url = item.url {
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
      }
    case .folder:
      // Pressing would pop the stack open on the real Dock's display.
      if let url = item.url { NSWorkspace.shared.open(url) }
    case .trash:
      NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.Trash"))
    case .separator:
      break
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.refresh() }
  }

  /// Auto-hide: reveal when the pointer reaches the clone (only its 1 pt
  /// sliver at the screen edge is on screen while hidden), hide shortly
  /// after it leaves.
  private func pointer(inside: Bool, id: CGDirectDisplayID) {
    guard prefs.autohide, let panel = panels[id] else { return }
    pendingHide.removeValue(forKey: id)?.cancel()
    if inside {
      panel.setRevealed(true)
      iconsMayHaveMoved()
    } else {
      let work = DispatchWorkItem { [weak self, weak panel] in
        panel?.setRevealed(false)
        self?.iconsMayHaveMoved()
      }
      pendingHide[id] = work
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
  }

  /// The display the real Dock is on: most overlap, else the nearest
  /// (an auto-hidden Dock sits just past the edge), else the main display.
  private static func screenID(containing dock: CGRect) -> CGDirectDisplayID? {
    let screens = NSScreen.screens
    guard !dock.isEmpty else { return screens.first?.displayID }
    func overlap(_ s: NSScreen) -> CGFloat {
      let r = s.frame.intersection(dock)
      return r.isNull ? 0 : r.width * r.height
    }
    func distance(_ s: NSScreen) -> CGFloat {
      hypot(s.frame.midX - dock.midX, s.frame.midY - dock.midY)
    }
    if let best = screens.max(by: { overlap($0) < overlap($1) }), overlap(best) > 0 {
      return best.displayID
    }
    return screens.min(by: { distance($0) < distance($1) })?.displayID
  }
}

extension NSScreen {
  var displayID: CGDirectDisplayID? {
    (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
  }
}
