import Foundation

/// Notification and timer blocks scheduled on the main queue run on the
/// main actor, but their types don't say so. These say it once.
extension NotificationCenter {
  @discardableResult
  func observeOnMain(
    _ name: Notification.Name, object: Any? = nil, _ block: @escaping @MainActor (Notification) -> Void
  ) -> NSObjectProtocol {
    addObserver(forName: name, object: object, queue: .main) { note in
      MainActor.assumeIsolated { block(note) }
    }
  }
}

extension Timer {
  /// A repeating timer on the main run loop.
  @discardableResult
  static func onMain(every interval: TimeInterval, _ block: @escaping @MainActor (Timer) -> Void) -> Timer {
    scheduledTimer(withTimeInterval: interval, repeats: true) { timer in
      MainActor.assumeIsolated { block(timer) }
    }
  }
}
