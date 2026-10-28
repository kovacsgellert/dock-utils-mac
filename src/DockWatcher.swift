import Cocoa
import ApplicationServices

extension Notification.Name {
  /// Something the Dock shows may have changed: items, order, running
  /// state, its settings or the display arrangement.
  static let dockChanged = Notification.Name("dock-utils.dockChanged")
}

/// Turns system events into `.dockChanged`, so Dock-mirroring features
/// react at once instead of polling:
/// - items added/removed: Accessibility notifications from the Dock process
///   (it only supports AXCreated/AXUIElementDestroyed; badge changes send
///   nothing, so those still need a poll);
/// - running state: app launch/quit;
/// - order, pinning, position, size, auto-hide: writes to the Dock's
///   preferences file;
/// - display changes.
/// Bursts are coalesced (see post()).
@MainActor
final class DockWatcher {
  static let shared = DockWatcher()

  private var observer: AXObserver?
  private var observedPid: pid_t = 0
  private var prefsWatcher: FileWatcher?
  private var pending: [DispatchWorkItem] = []

  func start() {
    let ws = NSWorkspace.shared.notificationCenter
    for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
      ws.observeOnMain(name) { [weak self] note in
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        // A restarted Dock is a new process to observe.
        if app?.bundleIdentifier == "com.apple.dock" { self?.observeDock() }
        self?.post()
      }
    }
    NotificationCenter.default.observeOnMain(NSApplication.didChangeScreenParametersNotification) { [weak self] _ in
      self?.post()
    }
    let prefs = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Preferences/com.apple.dock.plist")
    prefsWatcher = FileWatcher(prefs) { [weak self] in self?.post() }
    observeDock()
  }

  /// (Re)attach to the Dock process. Needs Accessibility, so it's called
  /// again once that's granted.
  func observeDock() {
    guard AXIsProcessTrusted(),
          let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first,
          dock.processIdentifier != observedPid || observer == nil
    else { return }
    if let old = observer {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(old), .defaultMode)
      observer = nil
    }
    let pid = dock.processIdentifier
    var created: AXObserver?
    let callback: AXObserverCallback = { _, _, _, refcon in
      guard let refcon else { return }
      // Delivered on the main run loop (see below).
      MainActor.assumeIsolated {
        Unmanaged<DockWatcher>.fromOpaque(refcon).takeUnretainedValue().post()
      }
    }
    guard AXObserverCreate(pid, callback, &created) == .success, let created else { return }
    let refcon = Unmanaged.passUnretained(self).toOpaque()
    let app = AXUIElementCreateApplication(pid)
    for name in [kAXCreatedNotification, kAXUIElementDestroyedNotification] {
      AXObserverAddNotification(created, app, name as CFString, refcon)
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
    observer = created
    observedPid = pid
  }

  /// Coalesce a burst into one post right away, plus one more once the
  /// Dock has settled: it animates icons into place and flips running
  /// indicators a moment after an app launches or quits.
  func post() {
    for work in pending { work.cancel() }
    pending = [0.05, 0.4].map { delay in
      let work = DispatchWorkItem { NotificationCenter.default.post(name: .dockChanged, object: nil) }
      DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
      return work
    }
  }
}
