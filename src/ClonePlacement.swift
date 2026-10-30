import Cocoa

/// Where a Dock clone goes along its edge. Start is the left end of a
/// bottom clone and the top end of a side one (where Dock items begin).
enum CloneAlign: String, CaseIterable {
  case start, center, end
}

/// Where the clone goes on one display, remembered per display in
/// config.yml (see `AppConfig.cloneDisplays`).
enum ClonePlacement: Equatable {
  /// The real Dock's edge, centered: what unknown displays get.
  case followDock
  /// No clone on this display.
  case off
  case edge(DockEdge, CloneAlign)

  /// As written in config.yml: `follow`, `off`, `bottom`, `left-start`,
  /// `right-end`… (a bare edge is centered).
  var configValue: String {
    switch self {
    case .followDock: return "follow"
    case .off: return "off"
    case let .edge(edge, align): return align == .center ? edge.rawValue : "\(edge.rawValue)-\(align.rawValue)"
    }
  }

  init?(configValue raw: String) {
    let parts = raw.lowercased().split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
    switch parts.first {
    case "follow" where parts.count == 1: self = .followDock
    case "off" where parts.count == 1: self = .off
    default:
      guard let edge = parts.first.flatMap(DockEdge.init(rawValue:)),
            let align = parts.count == 2 ? CloneAlign(rawValue: parts[1]) : .center
      else { return nil }
      self = .edge(edge, align)
    }
  }
}

/// A display's remembered placement, with its name for the comment in
/// config.yml (so the file says which display a UUID is).
struct CloneDisplay: Equatable {
  var placement: ClonePlacement
  var name = ""
}

extension NSScreen {
  /// Stable across reconnects and reboots, unlike `displayID`; lowercased,
  /// as config.yml keys are. Identical monitors that report no serial
  /// number share one.
  var displayUUID: String? {
    guard let id = displayID, let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
    return (CFUUIDCreateString(nil, uuid) as String).lowercased()
  }
}
