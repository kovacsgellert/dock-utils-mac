import Cocoa
import ApplicationServices

/// A running app on the Dock, numbered for the shortcuts.
struct DockApp: Equatable {
  let index: Int // 1-based number shown to user
  let title: String
  let bundleURL: URL?
  /// AX (global, top-left origin) coordinates.
  let frame: CGRect
  var bundleIdentifier: String? {
    guard let url = bundleURL else { return nil }
    return Bundle(url: url)?.bundleIdentifier
  }
}

enum DockItemKind: Equatable {
  case app, folder, trash, separator
}

struct DockItem: Equatable {
  let kind: DockItemKind
  let title: String
  let url: URL?
  let isRunning: Bool
  /// The app's badge ("3", "!"), as the Dock shows it; nil when none.
  let badge: String?
  /// AX (global, top-left origin) coordinates.
  let frame: CGRect
  /// The real Dock's element, pressed to mirror a click exactly.
  let element: AXUIElement?

  /// Frame and element are left out: the frame jitters while the Dock
  /// magnifies, and elements are recreated as the Dock changes.
  static func == (a: DockItem, b: DockItem) -> Bool {
    a.kind == b.kind && a.title == b.title && a.url == b.url && a.isRunning == b.isRunning && a.badge == b.badge
  }
}

/// What the system Dock shows right now, plus where it sits.
struct DockSnapshot: Equatable {
  var items: [DockItem] = []
  /// The Dock's item list in AX (global, top-left origin) coordinates.
  var frame: CGRect = .zero

  /// Running apps in Dock order, numbered from 1 for the shortcuts.
  var runningApps: [DockApp] {
    items.filter { $0.kind == .app && $0.isRunning }.enumerated().map { i, item in
      DockApp(index: i + 1, title: item.title, bundleURL: item.url, frame: item.frame)
    }
  }
}

enum DockReader {
  static func runningAppItems() -> [DockApp] {
    snapshot()?.runningApps ?? []
  }

  /// Read per item in one round trip each (see `item(_:)` for the order).
  private static let attributes = [
    kAXSubroleAttribute, kAXTitleAttribute, kAXURLAttribute, "AXIsApplicationRunning",
    "AXStatusLabel", kAXPositionAttribute, kAXSizeAttribute,
  ]

  /// Every Dock item: apps (running or not), folders, Trash, separators.
  static func snapshot() -> DockSnapshot? {
    guard AXIsProcessTrusted(),
          let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
    else { return nil }
    let dockEl = AXUIElementCreateApplication(dock.processIdentifier)
    guard let lists = AX.value(dockEl, kAXChildrenAttribute) as? [AXUIElement],
          let list = lists.first,
          let elements = AX.value(list, kAXChildrenAttribute) as? [AXUIElement]
    else { return nil }

    let mirror = MirrorFix()
    var snapshot = DockSnapshot(frame: AX.frame(list).map(mirror.apply) ?? .zero)
    for el in elements {
      guard let v = AX.values(el, attributes) else { continue }
      let kind: DockItemKind
      switch v[0] as? String ?? "" {
      // Persistent and running apps; "recent" apps are the Dock's
      // suggested-apps section and behave the same when clicked.
      case "AXApplicationDockItem", "AXRecentApplicationDockItem": kind = .app
      case "AXFolderDockItem", "AXFileDockItem", "AXURLDockItem": kind = .folder
      case "AXTrashDockItem": kind = .trash
      case "AXSeparatorDockItem": kind = .separator
      // Minimized windows (AXMinimizedWindowDockItem) are not mirrored:
      // their live thumbnails are not available through AX.
      default: continue
      }
      // Skip a leading/doubled separator left over from skipped items.
      if kind == .separator, snapshot.items.last.map({ $0.kind == .separator }) ?? true { continue }
      snapshot.items.append(DockItem(
        kind: kind,
        title: v[1] as? String ?? "",
        url: v[2] as? URL,
        isRunning: AX.bool(v[3]),
        badge: (v[4] as? String).flatMap { $0.isEmpty ? nil : $0 },
        frame: AX.rect(position: v[5], size: v[6]).map(mirror.apply) ?? .zero,
        element: el
      ))
    }
    if snapshot.items.last?.kind == .separator { snapshot.items.removeLast() }
    return snapshot
  }
}

/// macOS 27 reports the items of a left-side Dock mirrored around x = 0
/// (x = -(real maxX)), i.e. off every screen. Flips such frames back when
/// the mirror lands on a screen. Not for an auto-hidden Dock, whose items
/// really are off screen while hidden. One per read: the screens and the
/// Dock's auto-hide setting are looked up once.
private final class MirrorFix {
  private let screens = NSScreen.screens.map { Coords.flip($0.frame) }
  private lazy var autohide = DockPrefs.read().autohide

  func apply(_ frame: CGRect) -> CGRect {
    guard !screens.contains(where: { $0.intersects(frame) }), !autohide else { return frame }
    let mirror = CGRect(x: -frame.maxX, y: frame.minY, width: frame.width, height: frame.height)
    return screens.contains(where: { $0.intersects(mirror) }) ? mirror : frame
  }
}
