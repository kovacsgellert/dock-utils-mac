import Cocoa
import ApplicationServices

@MainActor
enum AppActivator {
  /// Activate the running app matching a Dock item. Returns true on success.
  ///
  /// Multi-window cycling: every press advances to the next window
  /// (wrapping around), continuing from the currently focused/main window
  /// — so releasing Option and pressing Option+N again picks up where
  /// cycling left off instead of restarting at the first window.
  /// Single-window apps keep the old toggle: frontmost -> hide.
  static func activate(_ dockApp: DockApp) -> Bool {
    let running = NSWorkspace.shared.runningApplications
    // Rotations of apps that have quit hold stale windows: drop them.
    let pids = Set(running.map(\.processIdentifier))
    cycleOrder = cycleOrder.filter { pids.contains($0.key) }
    cycleIndex = cycleIndex.filter { pids.contains($0.key) }

    var target: NSRunningApplication?
    if let bid = dockApp.bundleIdentifier {
      target = running.first { $0.bundleIdentifier == bid }
    }
    if target == nil, let url = dockApp.bundleURL {
      let path = url.path
      target = running.first { $0.bundleURL?.path == path }
    }
    if target == nil {
      target = running.first { $0.localizedName == dockApp.title }
    }
    guard let app = target else { return false }
    let pid = app.processIdentifier
    let isFinder = app.bundleIdentifier == "com.apple.finder"
    let windows = AX.windows(pid: pid)
    // Multi-window apps: cycle instead of hiding. Every press advances
    // from the currently focused/main window (or, when Accessibility
    // can't see background focus, from the last cycled position), so
    // releasing Option between presses never restarts the cycle.
    if windows.count > 1 {
      let wasActive = app.isActive
      if !wasActive {
        _ = app.activate()
        if isFinder {
          unminimizeWindows(pid: pid)
        }
      }
      cycleToNextWindow(app: app, windows: windows, advance: wasActive || cycleIndex[pid] != nil)
      return true
    }
    // Single-window (or windowless) apps: toggle hide / activate.
    // If frontmost *with visible windows*, hide it (toggle). Otherwise
    // activate and restore minimized windows — minimizing the only window
    // leaves the app frontmost, so that case must not count as visible —
    // and for Finder open a new window if there are none, mirroring a
    // Dock click.
    if app.isActive, windows.contains(where: { !isMinimized($0) }) {
      app.hide()
    } else {
      _ = app.activate()
      unminimizeWindows(pid: pid)
      if isFinder, windows.isEmpty {
        NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory()))
      }
    }
    return true
  }

  private static func isMinimized(_ w: AXUIElement) -> Bool {
    AX.bool(w, kAXMinimizedAttribute)
  }

  private static func unminimizeWindows(pid: pid_t) {
    for w in AX.windows(pid: pid) where isMinimized(w) {
      AX.set(w, kAXMinimizedAttribute, false)
      AXUIElementPerformAction(w, kAXRaiseAction as CFString)
    }
  }

  // MARK: - Window cycling

  /// Stable rotation per app process. AXWindows re-sorts itself (the main
  /// window comes back at index 0), so plain index+1 cycling ping-pongs
  /// between two windows and never reaches the rest. Instead we keep our
  /// own window order and advance within it; AXUIElement identity
  /// (CFEqual) is stable across fetches, so the rotation survives
  /// re-sorting.
  private static var cycleOrder: [pid_t: [AXUIElement]] = [:]
  private static var cycleIndex: [pid_t: Int] = [:]

  /// Focus the next window in the app's stable rotation, wrapping around.
  /// - When the current focused/main window is readable: advance from its
  ///   position in the stable order, unless this is the very first touch
  ///   of an inactive app (no history), in which case keep the current
  ///   window instead of skipping past it.
  /// - When unreadable (typical for background apps): advance from the
  ///   last cycled position, else start at the frontmost window.
  /// New windows join the end of the rotation; closed ones drop out.
  private static func cycleToNextWindow(app: NSRunningApplication, windows: [AXUIElement], advance: Bool) {
    let pid = app.processIdentifier
    var order = cycleOrder[pid]?.filter { kept in windows.contains(where: { CFEqual(kept, $0) }) } ?? []
    for w in windows where !order.contains(where: { CFEqual($0, w) }) {
      order.append(w)
    }
    guard !order.isEmpty else { return }
    func position(of window: AXUIElement) -> Int? {
      order.firstIndex(where: { CFEqual($0, window) })
    }
    let next: Int
    if let current = focusedWindowIndex(windows: windows),
       let pos = position(of: windows[current]) {
      next = advance ? (pos + 1) % order.count : pos
    } else if let last = cycleIndex[pid] {
      next = (last + 1) % order.count
    } else {
      next = 0
    }
    cycleOrder[pid] = order
    cycleIndex[pid] = next
    focusWindow(app: app, window: order[next])
  }

  /// Index of the window carrying keyboard focus (focused, else main).
  private static func focusedWindowIndex(windows: [AXUIElement]) -> Int? {
    windows.firstIndex { AX.bool($0, kAXFocusedAttribute) }
      ?? windows.firstIndex { AX.bool($0, kAXMainAttribute) }
  }

  /// Bring one window of an already-resolved app to the front with focus.
  private static func focusWindow(app: NSRunningApplication, window: AXUIElement) {
    _ = app.activate()
    if isMinimized(window) {
      AX.set(window, kAXMinimizedAttribute, false)
    }
    AX.set(window, kAXMainAttribute, true)
    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    // Raise alone may leave keyboard focus behind — re-assert activation.
    _ = app.activate()
  }
}
