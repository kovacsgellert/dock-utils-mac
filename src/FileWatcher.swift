import Foundation

/// Calls `onChange` (on the main queue) whenever a file's modification date
/// changes. Watches the containing folder, since editors and cfprefsd
/// replace files rather than writing them in place.
final class FileWatcher {
  private let url: URL
  private let onChange: @MainActor () -> Void
  private var source: DispatchSourceFileSystemObject?
  private var modified: Date?

  init(_ url: URL, onChange: @escaping @MainActor () -> Void) {
    self.url = url
    self.onChange = onChange
    let dir = open(url.deletingLastPathComponent().path, O_EVTONLY)
    guard dir >= 0 else { return }
    modified = modificationDate()
    let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: dir, eventMask: .write, queue: .main)
    source.setEventHandler { [weak self] in
      guard let self else { return }
      let date = self.modificationDate()
      guard date != self.modified else { return }
      self.modified = date
      MainActor.assumeIsolated { self.onChange() }
    }
    source.setCancelHandler { close(dir) }
    source.resume()
    self.source = source
  }

  deinit { source?.cancel() }

  private func modificationDate() -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
  }
}
