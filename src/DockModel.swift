import Cocoa

extension Notification.Name {
  /// DockModel read the Dock again, or stopped reading it. The snapshot
  /// may or may not have changed: listeners compare.
  static let dockSnapshotUpdated = Notification.Name("dock-utils.dockSnapshotUpdated")
}

/// The Dock as last read, shared by the features that mirror it (Dock
/// clones, always-visible badges), so it's read once per change or poll
/// instead of once per feature. Idle while neither is on; the Option-hold
/// badges read the Dock fresh instead.
@MainActor
final class DockModel {
  static let shared = DockModel()

  private(set) var snapshot: DockSnapshot?

  private var isNeeded: Bool {
    AppConfig.shared.dockClones || AppConfig.shared.badgesAlwaysVisible
  }

  func start() {
    // Items, running state, order and Dock settings arrive as .dockChanged
    // (see DockWatcher).
    NotificationCenter.default.observeOnMain(.dockChanged) { [weak self] _ in self?.refresh() }
    NotificationCenter.default.observeOnMain(.appConfigChanged) { [weak self] _ in self?.refresh() }
    // Badge (unread count) changes and the real Dock moving to another
    // display send no event at all: a slow poll catches those.
    Timer.onMain(every: 1.0) { [weak self] _ in self?.refresh() }
    refresh()
  }

  func refresh() {
    guard isNeeded || snapshot != nil else { return }
    snapshot = isNeeded ? DockReader.snapshot() : nil
    NotificationCenter.default.post(name: .dockSnapshotUpdated, object: nil)
  }
}
