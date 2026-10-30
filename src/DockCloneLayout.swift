import Cocoa

/// Geometry of one Dock clone on one screen, in Cocoa (bottom-left origin)
/// global coordinates. Proportions follow the system Dock: a bar `tile + 2·pad`
/// thick, flush with the screen edge, centered along it unless the display's
/// placement puts it at one end.
struct DockCloneLayout {
  let edge: DockEdge
  let tile: CGFloat
  /// Panel frame while shown.
  let frame: CGRect
  /// Item rects in the panel's own coordinates (index-aligned with items).
  let itemRects: [CGRect]
  /// The band windows should keep clear of: the full screen length along
  /// the Dock's edge, as deep as the Dock, like `visibleFrame` does.
  let reserved: CGRect

  // Ratios measured on the macOS 26 Dock (36 pt icons: 56 pt thick bar,
  // 38 pt slots, 17 pt separator, ~3.5 pt at each end).
  /// Between icon and bar edge, across the bar.
  static func padding(tile: CGFloat) -> CGFloat { (tile * 0.28).rounded() }
  /// At each end of the bar, along it.
  static func endPadding(tile: CGFloat) -> CGFloat { tile * 0.096 }
  static func slot(tile: CGFloat) -> CGFloat { tile * 19 / 18 }
  static func separatorSlot(tile: CGFloat) -> CGFloat { tile * 0.475 }

  /// `edge` defaults to the real Dock's. `top` is where a side clone at the
  /// `.start` end stops, below the menu bar (defaults to the screen top).
  init(items: [DockItem], prefs: DockPrefs, screen: CGRect, edge: DockEdge? = nil, align: CloneAlign = .center, top: CGFloat? = nil) {
    let edge = edge ?? prefs.edge
    self.edge = edge
    tile = prefs.tileSize
    let pad = Self.padding(tile: tile)
    let thick = tile + 2 * pad
    let horizontal = edge == .bottom

    var rects: [CGRect] = []
    let endPad = Self.endPadding(tile: tile)
    var along = endPad
    for item in items {
      let len = item.kind == .separator ? Self.separatorSlot(tile: tile) : Self.slot(tile: tile)
      rects.append(horizontal
        ? CGRect(x: along, y: 0, width: len, height: thick)
        : CGRect(x: 0, y: along, width: thick, height: len))
      along += len
    }
    let top = min(top ?? screen.maxY, screen.maxY)
    let room = horizontal ? screen.width : align == .start ? top - screen.minY : screen.height
    let length = min((along + endPad).rounded(), room)
    if !horizontal {
      // Cocoa y grows upward but Dock items run top to bottom.
      rects = rects.map { CGRect(x: $0.minX, y: length - $0.maxY, width: $0.width, height: $0.height) }
    }
    itemRects = rects

    // Where the bar starts along its edge (left end, or bottom end in Cocoa y).
    let x = switch align {
    case .start: screen.minX
    case .center: screen.midX - length / 2
    case .end: screen.maxX - length
    }
    let y = switch align {
    case .start: top - length
    case .center: screen.midY - length / 2
    case .end: screen.minY
    }
    switch edge {
    case .bottom:
      frame = CGRect(x: x, y: screen.minY, width: length, height: thick)
      reserved = CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: thick)
    case .left:
      frame = CGRect(x: screen.minX, y: y, width: thick, height: length)
      reserved = CGRect(x: screen.minX, y: screen.minY, width: thick, height: screen.height)
    case .right:
      frame = CGRect(x: screen.maxX - thick, y: y, width: thick, height: length)
      reserved = CGRect(x: screen.maxX - thick, y: screen.minY, width: thick, height: screen.height)
    }
  }

  /// The panel frame while auto-hidden: slid past the screen edge, with a
  /// 1 pt sliver left on screen so it stays on the right display.
  var hiddenFrame: CGRect {
    switch edge {
    case .bottom: return frame.offsetBy(dx: 0, dy: -(frame.height - 1))
    case .left: return frame.offsetBy(dx: -(frame.width - 1), dy: 0)
    case .right: return frame.offsetBy(dx: frame.width - 1, dy: 0)
    }
  }
}

/// AX and CoreGraphics use a top-left origin at the primary screen's top-left
/// corner; Cocoa uses bottom-left. Same flip both ways.
enum Coords {
  static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

  static func flip(_ r: CGRect) -> CGRect {
    CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
  }
}
