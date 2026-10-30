import Cocoa

/// The Dock clone placement editor: every connected display in its real
/// arrangement (like System Settings → Displays), each with its clone drawn
/// where it goes. Clicking near a display's bottom, left or right edge puts
/// the clone there, at the nearer end or centered; clicking the middle
/// offers Follow the Dock and Off. The real Dock's display is drawn with
/// the Dock and can't be edited.
final class DisplayArrangementView: NSView {
  struct Display: Equatable {
    let uuid: String?
    let name: String
    /// Cocoa global coordinates.
    let frame: CGRect
    /// Below the menu bar: where a side clone at the top end stops.
    let top: CGFloat
    let hasDock: Bool
    let placement: ClonePlacement
  }

  /// A spot a click would put the clone.
  private struct Target: Equatable {
    let index: Int
    let edge: DockEdge
    let align: CloneAlign
  }

  /// The user picked a placement for a display.
  var onChange: ((_ uuid: String, _ name: String, _ placement: ClonePlacement) -> Void)?
  var isEnabled = true {
    didSet { hover = nil; needsDisplay = true }
  }

  private var displays: [Display] = []
  private var dockFrame: CGRect?
  private var items: [DockItem] = []
  private var prefs = DockPrefs()
  private var hover: Target? {
    didSet { if hover != oldValue { needsDisplay = true } }
  }

  static let size = CGSize(width: 332, height: 190)

  override var intrinsicContentSize: NSSize { Self.size }

  override init(frame: NSRect) {
    super.init(frame: frame)
    addTrackingArea(NSTrackingArea(
      rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self, userInfo: nil
    ))
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) { fatalError() }

  /// Re-reads the displays, the Dock and the saved placements; redraws
  /// only if something changed.
  @MainActor
  func reload() {
    let snapshot = DockModel.shared.snapshot ?? DockReader.snapshot()
    let freshDock = snapshot.map { Coords.flip($0.frame) }
    let dockID = freshDock.flatMap { NSScreen.containing($0)?.displayID }
    let fresh = NSScreen.screens.map { screen in
      let uuid = screen.displayUUID
      return Display(
        uuid: uuid, name: screen.localizedName, frame: screen.frame, top: screen.visibleFrame.maxY,
        hasDock: dockID != nil && screen.displayID == dockID,
        placement: uuid.flatMap { AppConfig.shared.cloneDisplays[$0]?.placement } ?? .followDock
      )
    }
    show(fresh, dockFrame: freshDock, items: snapshot?.items ?? [], prefs: DockPrefs.read())
  }

  func show(_ fresh: [Display], dockFrame freshDock: CGRect?, items freshItems: [DockItem], prefs freshPrefs: DockPrefs) {
    guard fresh != displays || freshDock != dockFrame || freshItems != items || freshPrefs != prefs else { return }
    displays = fresh
    dockFrame = freshDock
    items = freshItems
    prefs = freshPrefs
    if let hover, !displays.indices.contains(hover.index) { self.hover = nil }
    needsDisplay = true
  }

  // MARK: - Geometry

  /// Global (Cocoa) coordinates to the view's, scaled to fit, centered.
  private var transform: (scale: CGFloat, map: (CGRect) -> CGRect) {
    let all = displays.map(\.frame).reduce(CGRect.null) { $0.union($1) }
    guard !all.isNull, all.width > 0, all.height > 0 else { return (1, { $0 }) }
    let margin: CGFloat = 8
    let scale = min((bounds.width - 2 * margin) / all.width, (bounds.height - 2 * margin) / all.height)
    let dx = bounds.midX - all.midX * scale
    let dy = bounds.midY - all.midY * scale
    return (scale, { r in
      CGRect(x: r.minX * scale + dx, y: r.minY * scale + dy, width: r.width * scale, height: r.height * scale)
    })
  }

  /// A display's rect in the view, inset so neighbors don't touch.
  private func rect(of display: Display) -> CGRect {
    transform.map(display.frame).insetBy(dx: 1.5, dy: 1.5)
  }

  /// Where the clone would sit on a display for a placement, in global
  /// coordinates: the real layout, so its length matches the Dock's.
  private func cloneFrame(on display: Display, edge: DockEdge, align: CloneAlign) -> CGRect {
    DockCloneLayout(items: items, prefs: prefs, screen: display.frame, edge: edge, align: align, top: display.top).frame
  }

  /// A bar in the view: at least a few points thick and long so it reads
  /// at this scale, still flush with the display's edge.
  private func bar(_ frame: CGRect, in rect: CGRect, edge: DockEdge) -> CGRect {
    var r = transform.map(frame).intersection(rect.insetBy(dx: 2, dy: 2))
    guard !r.isNull else { return .zero }
    let thick: CGFloat = 5, minLength: CGFloat = 24
    switch edge {
    case .bottom:
      r.size.height = max(r.height, thick)
      if r.width < minLength { r = r.insetBy(dx: (r.width - minLength) / 2, dy: 0) }
    case .left:
      r.size.width = max(r.width, thick)
      if r.height < minLength { r = r.insetBy(dx: 0, dy: (r.height - minLength) / 2) }
    case .right:
      r.origin.x = r.maxX - max(r.width, thick)
      r.size.width = max(r.width, thick)
      if r.height < minLength { r = r.insetBy(dx: 0, dy: (r.height - minLength) / 2) }
    }
    return r.intersection(rect.insetBy(dx: 2, dy: 2))
  }

  /// The edge spot under a point: the nearest of bottom, left and right
  /// within the outer 30% of the display, split in thirds along the edge.
  /// nil in the middle, near the top, and on the real Dock's display.
  private func target(at point: CGPoint) -> Target? {
    guard let index = displays.indices.first(where: { rect(of: displays[$0]).contains(point) }),
          !displays[index].hasDock, displays[index].uuid != nil else { return nil }
    let r = rect(of: displays[index])
    let fx = (point.x - r.minX) / r.width
    let fromTop = (r.maxY - point.y) / r.height
    let distances: [(DockEdge?, CGFloat)] = [(.bottom, 1 - fromTop), (.left, fx), (.right, 1 - fx), (nil, fromTop)]
    guard let (edge, distance) = distances.min(by: { $0.1 < $1.1 }), let edge, distance < 0.3 else { return nil }
    let along = edge == .bottom ? fx : fromTop
    let align: CloneAlign = along < 1 / 3 ? .start : along > 2 / 3 ? .end : .center
    return Target(index: index, edge: edge, align: align)
  }

  // MARK: - Drawing

  override func draw(_: NSRect) {
    let alpha: CGFloat = isEnabled ? 1 : 0.45
    for (index, display) in displays.enumerated() {
      let r = rect(of: display)
      let shape = NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5)
      (hover?.index == index ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.labelColor.withAlphaComponent(0.06 * alpha))
        .setFill()
      shape.fill()
      NSColor.separatorColor.withAlphaComponent(alpha).setStroke()
      shape.lineWidth = 1
      shape.stroke()

      NSGraphicsContext.saveGraphicsState()
      shape.addClip()
      if display.hasDock, let dockFrame {
        // The real Dock, where it is.
        let edge = prefs.edge
        NSColor.secondaryLabelColor.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: bar(dockFrame, in: r, edge: edge), xRadius: 2, yRadius: 2).fill()
      } else if let (edge, align) = Self.edgeAndAlign(display.placement, dockEdge: prefs.edge) {
        let accent = NSColor.controlAccentColor
        // Following the Dock is drawn lighter: it moves when the Dock does.
        accent.withAlphaComponent(alpha * (display.placement == .followDock ? 0.55 : 1)).setFill()
        NSBezierPath(roundedRect: bar(cloneFrame(on: display, edge: edge, align: align), in: r, edge: edge), xRadius: 2, yRadius: 2).fill()
      }
      if let hover, hover.index == index {
        NSColor.controlAccentColor.withAlphaComponent(0.35).setFill()
        let ghost = bar(cloneFrame(on: display, edge: hover.edge, align: hover.align), in: r, edge: hover.edge)
        NSBezierPath(roundedRect: ghost, xRadius: 2, yRadius: 2).fill()
      }
      NSGraphicsContext.restoreGraphicsState()

      let subtitle: String
      if let hover, hover.index == index {
        subtitle = Self.describe(.edge(hover.edge, hover.align))
      } else if display.hasDock {
        subtitle = "Dock"
      } else {
        subtitle = Self.describe(display.placement)
      }
      drawLabels(display.name, subtitle, in: r, alpha: alpha * (display.placement == .off && !display.hasDock ? 0.6 : 1))
    }
  }

  private func drawLabels(_ title: String, _ subtitle: String, in r: CGRect, alpha: CGFloat) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    paragraph.lineBreakMode = .byTruncatingTail
    let titleAttrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 10, weight: .medium),
      .foregroundColor: NSColor.labelColor.withAlphaComponent(alpha),
      .paragraphStyle: paragraph,
    ]
    let subtitleAttrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 9),
      .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(alpha),
      .paragraphStyle: paragraph,
    ]
    let width = r.width - 14
    guard width > 10 else { return }
    let lineHeight: CGFloat = 13
    let showSubtitle = r.height > 2 * lineHeight + 14
    let total = showSubtitle ? 2 * lineHeight : lineHeight
    let top = r.midY + total / 2
    (title as NSString).draw(in: CGRect(x: r.minX + 7, y: top - lineHeight, width: width, height: lineHeight), withAttributes: titleAttrs)
    if showSubtitle {
      (subtitle as NSString).draw(in: CGRect(x: r.minX + 7, y: top - 2 * lineHeight, width: width, height: lineHeight), withAttributes: subtitleAttrs)
    }
  }

  static func edgeAndAlign(_ placement: ClonePlacement, dockEdge: DockEdge) -> (DockEdge, CloneAlign)? {
    switch placement {
    case .off: return nil
    case .followDock: return (dockEdge, .center)
    case let .edge(edge, align): return (edge, align)
    }
  }

  static func describe(_ placement: ClonePlacement) -> String {
    switch placement {
    case .followDock: return "Follows the Dock"
    case .off: return "No clone"
    case let .edge(edge, align):
      let side = edge.rawValue.capitalized
      switch align {
      case .center: return side
      case .start: return side + (edge == .bottom ? ", left end" : ", top end")
      case .end: return side + (edge == .bottom ? ", right end" : ", bottom end")
      }
    }
  }

  // MARK: - Mouse

  override func mouseMoved(with event: NSEvent) {
    hover = isEnabled ? target(at: convert(event.locationInWindow, from: nil)) : nil
  }

  override func mouseExited(with _: NSEvent) {
    hover = nil
  }

  override func mouseDown(with event: NSEvent) {
    guard isEnabled else { return }
    let point = convert(event.locationInWindow, from: nil)
    if let target = target(at: point) {
      let display = displays[target.index]
      guard let uuid = display.uuid else { return }
      onChange?(uuid, display.name, .edge(target.edge, target.align))
      return
    }
    // The middle of a display: the placements that aren't an edge spot.
    guard let display = displays.first(where: { rect(of: $0).contains(point) }),
          !display.hasDock, let uuid = display.uuid else { return }
    let menu = NSMenu()
    for placement in [ClonePlacement.followDock, .off] {
      let item = ActionMenuItem(placement == .followDock ? "Follow the Dock" : "No clone on this display") { [weak self] in
        self?.onChange?(uuid, display.name, placement)
      }
      item.state = display.placement == placement ? .on : .off
      menu.addItem(item)
    }
    menu.popUp(positioning: nil, at: point, in: self)
  }
}
