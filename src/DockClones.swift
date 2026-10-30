import Cocoa

/// Dock clones: one clone of the system Dock per other display, kept in sync
/// with the Dock, its settings and the display arrangement. Off unless
/// `dock_clones` is set; idle (no AX reads, no window watching) while off.
extension Notification.Name {
  /// The clones' icons moved, appeared or disappeared (rebuild, auto-hide).
  static let dockClonesChanged = Notification.Name("dock-utils.dockClonesChanged")
}

@MainActor
final class DockClones {
  static let shared = DockClones()

  private var panels: [CGDirectDisplayID: DockClonePanel] = [:]
  private var snapshot = DockSnapshot()
  private var prefs = DockPrefs()
  private var config = AppConfig.shared
  /// Each display's UUID and frame: a different monitor plugged in where
  /// another was, at the same size, still counts as a change.
  private var screensKey: [String] = []
  private var dockScreenID: CGDirectDisplayID?
  /// Displays showing a full-screen app, as of the last rebuild.
  private var fullscreenKey: Set<CGDirectDisplayID> = []
  private let guardian = WindowGuard()
  private var pendingHide: [CGDirectDisplayID: DispatchWorkItem] = [:]
  private var lastIconsKey: [String] = []

  func start() {
    refresh(force: true)
    // Dock and settings changes arrive through DockModel, which also polls
    // for the changes that send no event.
    for name in [Notification.Name.dockSnapshotUpdated, .fullscreenDisplaysChanged] {
      NotificationCenter.default.observeOnMain(name) { [weak self] _ in self?.refresh() }
    }
    // The clones look like the real Dock, which follows the system's
    // light/dark setting rather than DockUtils' own Appearance setting.
    DistributedNotificationCenter.default().observeOnMain(.init("AppleInterfaceThemeChangedNotification")) { [weak self] _ in
      // The setting is written just after the announcement.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        guard let self else { return }
        for panel in self.panels.values { panel.updateAppearance() }
      }
    }
  }

  func refresh(force: Bool = false) {
    let freshConfig = AppConfig.shared
    guard freshConfig.dockClones else {
      if config.dockClones || force { config = freshConfig; removeAll() }
      return
    }
    guard let fresh = DockModel.shared.snapshot else { return }
    let freshPrefs = DockPrefs.read()
    let freshScreens = NSScreen.screens.map { "\($0.displayUUID ?? "?") \($0.frame)" }
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
      // Displays seen before get their remembered placement back.
      let placement = screen.displayUUID.flatMap { config.cloneDisplays[$0]?.placement } ?? .followDock
      let edge: DockEdge?, align: CloneAlign
      switch placement {
      case .off: continue
      case .followDock: (edge, align) = (nil, .center)
      case let .edge(e, a): (edge, align) = (e, a)
      }
      keep.insert(id)
      let layout = DockCloneLayout(
        items: snapshot.items, prefs: prefs, screen: screen.frame,
        edge: edge, align: align, top: screen.visibleFrame.maxY
      )
      if let panel = panels[id] {
        panel.update(layout: layout, items: snapshot.items)
      } else {
        let panel = DockClonePanel(layout: layout, items: snapshot.items) { [weak self] item in
          self?.click(item)
        }
        panel.onPointer = { [weak self] inside in self?.pointer(inside: inside, id: id) }
        panel.menuFor = { [weak self] item in self?.menu(for: item) }
        panel.onDrop = { [weak self] urls, item in self?.drop(urls, on: item) }
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
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { DockModel.shared.refresh() }
  }

  /// The right-click menu: a short version of the Dock's.
  private func menu(for item: DockItem) -> NSMenu? {
    let menu = NSMenu()
    func add(_ title: String, _ action: @escaping () -> Void) {
      menu.addItem(ActionMenuItem(title, action))
    }
    switch item.kind {
    case .app:
      let app = item.url.flatMap { url in
        NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == url.path }
      }
      if let app {
        add(app.isHidden ? "Show" : "Hide") { _ = app.isHidden ? app.unhide() : app.hide() }
      } else {
        add("Open") { [weak self] in self?.click(item) }
      }
      if let url = item.url {
        add("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
      }
      // Finder can't be quit from the Dock either.
      if let app, app.bundleIdentifier != "com.apple.finder" {
        menu.addItem(.separator())
        add("Quit") { app.terminate() }
      }
    case .folder:
      add("Open") { [weak self] in self?.click(item) }
      if let url = item.url {
        add("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
      }
    case .trash:
      add("Open") { [weak self] in self?.click(item) }
    case .separator:
      return nil
    }
    return menu
  }

  /// Files dropped on an app open with it; on the Trash they move there,
  /// as with the real Dock.
  private func drop(_ urls: [URL], on item: DockItem) {
    switch item.kind {
    case .app:
      guard let app = item.url else { return }
      NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    case .trash:
      NSWorkspace.shared.recycle(urls)
    case .folder, .separator:
      break
    }
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

  /// The display the real Dock is on.
  private static func screenID(containing dock: CGRect) -> CGDirectDisplayID? {
    NSScreen.containing(dock)?.displayID
  }
}

extension NSScreen {
  var displayID: CGDirectDisplayID? {
    (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
  }

  /// The screen showing most of `rect` (Cocoa coordinates), else the
  /// nearest one (an auto-hidden Dock sits just past the edge), else the
  /// main display.
  static func containing(_ rect: CGRect) -> NSScreen? {
    guard !rect.isEmpty else { return screens.first }
    func overlap(_ s: NSScreen) -> CGFloat {
      let r = s.frame.intersection(rect)
      return r.isNull ? 0 : r.width * r.height
    }
    func distance(_ s: NSScreen) -> CGFloat {
      hypot(s.frame.midX - rect.midX, s.frame.midY - rect.midY)
    }
    if let best = screens.max(by: { overlap($0) < overlap($1) }), overlap(best) > 0 {
      return best
    }
    return screens.min(by: { distance($0) < distance($1) })
  }
}
