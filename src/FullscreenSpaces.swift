import Cocoa
import ApplicationServices

extension Notification.Name {
  /// A display started or stopped showing a full-screen app.
  static let fullscreenDisplaysChanged = Notification.Name("dock-utils.fullscreenDisplaysChanged")
}

/// Displays showing a full-screen app. The real Dock hides in a full-screen
/// Space, so the Dock clones and shortcut badges stay off those displays too.
/// Panels that join all Spaces would otherwise show over the full-screen app.
final class FullscreenSpaces {
  static let shared = FullscreenSpaces()

  private(set) var displays: Set<CGDirectDisplayID> = []

  func start() {
    update()
    // Full-screen state arrives as Space changes (entering or leaving a
    // full-screen Space); the check reads the windows' own AXFullScreen
    // state, so fullscreen detection never polls. Display changes and a
    // permission change can alter what is visible too.
    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.mayHaveChanged() }
    NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.mayHaveChanged() }
    NotificationCenter.default.addObserver(
      forName: .accessibilityChanged, object: nil, queue: .main
    ) { [weak self] _ in self?.mayHaveChanged() }
  }

  func contains(_ screen: NSScreen) -> Bool {
    screen.displayID.map(displays.contains) ?? false
  }

  /// The Space notification can precede the window settling into its Space,
  /// so take a couple more looks shortly after; these are single follow-ups,
  /// not a poll. Listeners only hear about it when the set actually changed.
  private func mayHaveChanged() {
    update()
    for delay in [0.4, 1.0] {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.update() }
    }
  }

  private func update() {
    let fresh = Self.scan()
    guard fresh != displays else { return }
    displays = fresh
    NotificationCenter.default.post(name: .fullscreenDisplaysChanged, object: nil)
  }

  /// Displays showing a full-screen app, from each window's own
  /// `AXFullScreen` state: the system's full-screen signal for another app's
  /// window (`NSWindow.styleMask` is only available for our own windows).
  /// A window in a background Space still reports that state, so a window
  /// only counts while it is in the on-screen window list.
  private static func scan() -> Set<CGDirectDisplayID> {
    let screens = NSScreen.screens
    guard !screens.isEmpty, AXIsProcessTrusted() else { return [] }
    let visible = onScreenWindows()
    let apps = NSWorkspace.shared.runningApplications.filter { app in
      app.activationPolicy == .regular
        && app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        && visible.contains { $0.pid == app.processIdentifier }
    }
    var fullscreen: Set<CGDirectDisplayID> = []
    for app in apps {
      let appEl = AXUIElementCreateApplication(app.processIdentifier)
      let windows = AX.value(appEl, kAXWindowsAttribute) as? [AXUIElement] ?? []
      for window in windows {
        guard (AX.value(window, "AXFullScreen") as? NSNumber)?.boolValue == true,
              let frame = AX.frame(window),
              visible.contains(where: { $0.pid == app.processIdentifier && sameFrame($0.frame, frame) })
        else { continue }
        // AX and CGWindow frames share the top-left origin, unlike NSScreen.
        for screen in screens {
          guard let id = screen.displayID, !fullscreen.contains(id),
                Coords.flip(screen.frame).intersects(frame) else { continue }
          fullscreen.insert(id)
        }
      }
    }
    return fullscreen
  }

  /// Windows currently on screen, in AX (top-left origin) coordinates. Used
  /// only to tell a visible full-screen Space from a background one.
  private static func onScreenWindows() -> [(pid: pid_t, frame: CGRect)] {
    guard let windows = CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
    ) as? [[String: Any]] else { return [] }
    return windows.compactMap { window -> (pid: pid_t, frame: CGRect)? in
      guard let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
            let bounds = window[kCGWindowBounds as String] as? [String: Any],
            let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
      else { return nil }
      return (pid, frame)
    }
  }

  private static func sameFrame(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2
      && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
  }
}
