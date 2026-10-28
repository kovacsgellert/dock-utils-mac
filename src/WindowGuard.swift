import Cocoa
import ApplicationServices

/// Keeps windows out of the Dock clones' area, the way `visibleFrame`
/// keeps them out of the real Dock's.
///
/// macOS has no API for a second reserved area (see README), so this
/// watches every app's windows through Accessibility and, after a window is
/// resized or moved, shrinks it if its Dock-side edge ends up at (or within a
/// tiling margin of) the screen edge while overlapping a clone. That covers the
/// green-button zoom, double-click-title Fill, Sequoia tiling and window
/// managers, which all size windows to `visibleFrame` (= the whole screen on
/// displays without the real Dock). Window managers often only move a window
/// (to a same-sized tile, or to another display), so moves count too, except
/// mouse drags: windows can still be dragged over a clone, just as over the
/// real Dock.
@MainActor
final class WindowGuard {
  /// Reserved bands in Cocoa coordinates.
  private var reserved: [(edge: DockEdge, rect: CGRect)] = []
  private var observers: [pid_t: AXObserver] = [:]
  private var pending: [pid_t: DispatchWorkItem] = [:]
  /// Windows changed since the last settle, and whether any of their changes
  /// should be clamped (anything but a mouse drag).
  private var pendingWindows: [pid_t: [(window: AXUIElement, clamp: Bool)]] = [:]
  /// How far from the screen edge a window edge still counts as "at the edge":
  /// Sequoia's "Tiled windows have margins" leaves a gap of about 8 pt.
  static let edgeTolerance: CGFloat = 16

  init() {
    let ws = NSWorkspace.shared.notificationCenter
    ws.observeOnMain(NSWorkspace.didLaunchApplicationNotification) { [weak self] note in
      guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
      // Fresh processes reject AX observers until they finish launching.
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.watch(app) }
    }
    ws.observeOnMain(NSWorkspace.didTerminateApplicationNotification) { [weak self] note in
      guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
      self?.unwatch(app.processIdentifier)
    }
  }

  func setReserved(_ bands: [(edge: DockEdge, rect: CGRect)]) {
    let changed = bands.map(\.rect) != reserved.map(\.rect)
    reserved = bands
    if bands.isEmpty {
      for pid in Array(observers.keys) { unwatch(pid) }
      return
    }
    for app in NSWorkspace.shared.runningApplications { watch(app) }
    // A new or moved clone: fix windows already maximized underneath it.
    if changed {
      for pid in observers.keys { clampAllWindows(pid: pid) }
    }
  }

  private func watch(_ app: NSRunningApplication) {
    let pid = app.processIdentifier
    guard !reserved.isEmpty, observers[pid] == nil, app.activationPolicy == .regular,
          pid != ProcessInfo.processInfo.processIdentifier else { return }
    var observer: AXObserver?
    let callback: AXObserverCallback = { _, element, notification, refcon in
      guard let refcon else { return }
      // Delivered on the main run loop (see below).
      MainActor.assumeIsolated {
        Unmanaged<WindowGuard>.fromOpaque(refcon).takeUnretainedValue()
          .windowChanged(element, moved: notification as String == kAXWindowMovedNotification)
      }
    }
    guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
    let appEl = AXUIElementCreateApplication(pid)
    let refcon = Unmanaged.passUnretained(self).toOpaque()
    var ok = false
    // Registered on the app element, these fire for all of its windows.
    for name in [kAXWindowResizedNotification, kAXWindowMovedNotification, kAXWindowCreatedNotification] {
      ok = AXObserverAddNotification(observer, appEl, name as CFString, refcon) == .success || ok
    }
    guard ok else { return }
    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    observers[pid] = observer
  }

  private func unwatch(_ pid: pid_t) {
    guard let observer = observers.removeValue(forKey: pid) else { return }
    CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    pending.removeValue(forKey: pid)?.cancel()
    pendingWindows[pid] = nil
  }

  /// Resizes arrive in bursts while zoom/tiling animate; act once it settles.
  private func windowChanged(_ window: AXUIElement, moved: Bool) {
    var pid: pid_t = 0
    guard AXUIElementGetPid(window, &pid) == .success else { return }
    let clamp = !(moved && isMouseDragging())
    if let i = pendingWindows[pid]?.firstIndex(where: { CFEqual($0.window, window) }) {
      pendingWindows[pid]![i].clamp = pendingWindows[pid]![i].clamp || clamp
    } else {
      pendingWindows[pid, default: []].append((window, clamp))
    }
    pending[pid]?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      let windows = self.pendingWindows.removeValue(forKey: pid) ?? []
      self.pending[pid] = nil
      for w in windows where w.clamp { self.clamp(w.window) }
    }
    pending[pid] = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
  }

  private func clampAllWindows(pid: pid_t) {
    for w in AX.windows(pid: pid) { clamp(w) }
  }

  private func clamp(_ window: AXUIElement) {
    guard AX.value(window, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
          !AX.bool(window, "AXFullScreen"),
          !AX.bool(window, kAXMinimizedAttribute),
          let frame = AX.frame(window) else { return }
    // Work in AX coordinates (top-left origin), like the window frame.
    let screens = NSScreen.screens.map { Coords.flip($0.frame) }
    guard let screen = screens.max(by: { area($0.intersection(frame)) < area($1.intersection(frame)) }),
          area(screen.intersection(frame)) > 0 else { return }

    for band in reserved {
      let strip = Coords.flip(band.rect)
      guard screen.contains(CGPoint(x: strip.midX, y: strip.midY)),
            let target = Self.clamped(frame, screen: screen, edge: band.edge, strip: strip)
      else { continue }
      if target.origin != frame.origin { AX.setPosition(window, target.origin) }
      AX.setSize(window, target.size)
      return
    }
  }

  /// Where a window goes to clear a clone's band on its screen, or nil to
  /// leave it be. All in AX coordinates (top-left origin).
  static func clamped(_ frame: CGRect, screen: CGRect, edge: DockEdge, strip: CGRect) -> CGRect? {
    guard frame.intersects(strip) else { return nil }
    var target = frame
    switch edge {
    case .bottom:
      let gap = screen.maxY - frame.maxY
      guard gap > -2, gap <= edgeTolerance else { return nil }
      target.size.height = strip.minY - max(gap, 0) - frame.minY
    case .left:
      let gap = frame.minX - screen.minX
      guard gap > -2, gap <= edgeTolerance else { return nil }
      target.origin.x = strip.maxX + max(gap, 0)
      target.size.width = frame.maxX - target.minX
    case .right:
      let gap = screen.maxX - frame.maxX
      guard gap > -2, gap <= edgeTolerance else { return nil }
      target.size.width = strip.minX - max(gap, 0) - frame.minX
    }
    // A window mostly under the clone is being parked there on purpose.
    guard target.width >= 120, target.height >= 80, target != frame else { return nil }
    return target
  }

  /// The last move notifications of a drag can arrive just after the button
  /// goes up, so a very recent drag event counts too.
  private func isMouseDragging() -> Bool {
    NSEvent.pressedMouseButtons & 1 != 0
      || CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDragged) < 0.3
  }

  private func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }
}
