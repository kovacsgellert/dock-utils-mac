import Cocoa

/// One Dock clone: a borderless panel at the Dock's window level on one screen.
@MainActor
final class DockClonePanel {
  private(set) var layout: DockCloneLayout
  private(set) var isRevealed = true
  private let panel: NSPanel
  private let bubble = TitleBubble()
  private let onClick: (DockItem) -> Void
  /// Pointer entered (true) or left (false) the clone.
  var onPointer: ((Bool) -> Void)?
  /// The right-click menu for an item.
  var menuFor: ((DockItem) -> NSMenu?)?
  /// Files dropped on an app or the Trash.
  var onDrop: (([URL], DockItem) -> Void)?

  init(layout: DockCloneLayout, items: [DockItem], onClick: @escaping (DockItem) -> Void) {
    self.layout = layout
    self.onClick = onClick
    panel = NSPanel(
      contentRect: layout.frame,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    // Same level as the real Dock: above normal and floating windows,
    // below menus and the menu bar.
    panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.becomesKeyOnlyIfNeeded = true
    // Every Space, but not full-screen Spaces (the real Dock hides there too).
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    updateAppearance()
    update(layout: layout, items: items)
    panel.orderFrontRegardless()
  }

  func update(layout: DockCloneLayout, items: [DockItem]) {
    self.layout = layout
    let root = PointerView(frame: CGRect(origin: .zero, size: layout.frame.size))
    root.onPointer = { [weak self] inside in self?.onPointer?(inside) }
    root.addSubview(Self.background(size: layout.frame.size, tile: layout.tile))
    for (item, rect) in zip(items, layout.itemRects) where item.kind != .separator {
      let view = DockItemView(frame: rect, item: item, layout: layout)
      view.onClick = { [weak self] in self?.bubble.hide(); self?.onClick(item) }
      view.onHover = { [weak self, weak view] inside in
        guard let self, let view else { return }
        inside ? self.bubble.show(item.title, over: self.screenRect(of: view), edge: layout.edge) : self.bubble.hide()
      }
      view.menuProvider = { [weak self] in
        self?.bubble.hide()
        return self?.menuFor?(item)
      }
      if item.kind == .app || item.kind == .trash {
        view.onDrop = { [weak self] urls in self?.onDrop?(urls, item) }
      }
      root.addSubview(view)
    }
    for (item, rect) in zip(items, layout.itemRects) where item.kind == .separator {
      root.addSubview(SeparatorView(frame: rect, edge: layout.edge, tile: layout.tile))
    }
    panel.contentView = root
    panel.setFrame(isRevealed ? layout.frame : layout.hiddenFrame, display: true)
  }

  func setRevealed(_ revealed: Bool, animated: Bool = true) {
    guard revealed != isRevealed else { return }
    isRevealed = revealed
    if !revealed { bubble.hide() }
    let target = revealed ? layout.frame : layout.hiddenFrame
    guard animated else { panel.setFrame(target, display: true); return }
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = 0.18
      panel.animator().setFrame(target, display: true)
    }
  }

  /// Match the system's light/dark setting, like the real Dock.
  func updateAppearance() {
    panel.appearance = AppAppearance.systemAppearance
  }

  func close() {
    bubble.hide()
    panel.orderOut(nil)
  }

  private func screenRect(of view: NSView) -> CGRect {
    panel.convertToScreen(view.convert(view.bounds, to: nil))
  }

  private static func background(size: CGSize, tile: CGFloat) -> NSView {
    let radius = (tile * 0.45).rounded()
    let view: NSView
    if #available(macOS 26, *) {
      let glass = NSGlassEffectView(frame: CGRect(origin: .zero, size: size))
      glass.cornerRadius = radius
      view = glass
    } else {
      let blur = NSVisualEffectView(frame: CGRect(origin: .zero, size: size))
      blur.material = .hudWindow
      blur.blendingMode = .behindWindow
      blur.state = .active
      blur.wantsLayer = true
      blur.layer?.cornerRadius = radius
      blur.layer?.masksToBounds = true
      blur.layer?.borderWidth = 0.5
      blur.layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
      view = blur
    }
    view.autoresizingMask = [.width, .height]
    return view
  }
}

/// Reports the pointer entering and leaving the whole clone.
private final class PointerView: NSView {
  var onPointer: ((Bool) -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    addTrackingArea(NSTrackingArea(
      rect: .zero,
      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
      owner: self
    ))
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) { fatalError() }

  override func mouseEntered(with _: NSEvent) { onPointer?(true) }
  override func mouseExited(with _: NSEvent) { onPointer?(false) }
}

private final class DockItemView: NSView {
  var onClick: (() -> Void)?
  var onHover: ((Bool) -> Void)?
  var menuProvider: (() -> NSMenu?)?
  /// Accepts dropped files when set.
  var onDrop: (([URL]) -> Void)? {
    didSet { onDrop == nil ? unregisterDraggedTypes() : registerForDraggedTypes([.fileURL]) }
  }
  private let item: DockItem
  private let edge: DockEdge
  private let tile: CGFloat
  private var pressed = false { didSet { needsDisplay = true } }

  init(frame: CGRect, item: DockItem, layout: DockCloneLayout) {
    self.item = item
    edge = layout.edge
    tile = layout.tile
    super.init(frame: frame)
    addTrackingArea(NSTrackingArea(
      rect: .zero,
      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
      owner: self
    ))
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) { fatalError() }

  override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

  override func draw(_: NSRect) {
    let icon = CGRect(x: bounds.midX - tile / 2, y: bounds.midY - tile / 2, width: tile, height: tile)
    IconCache.icon(for: item).draw(in: icon, from: .zero, operation: .sourceOver, fraction: pressed ? 0.6 : 1)
    if let badge = item.badge { drawBadge(badge, icon: icon) }
    guard item.isRunning else { return }
    // Running indicator: a small dot between the icon and the screen edge.
    let d: CGFloat = max(3, (tile * 0.1).rounded())
    let gap = (DockCloneLayout.padding(tile: tile) - d) / 2
    let center: CGPoint
    switch edge {
    case .bottom: center = CGPoint(x: bounds.midX, y: gap + d / 2)
    case .left: center = CGPoint(x: gap + d / 2, y: bounds.midY)
    case .right: center = CGPoint(x: bounds.maxX - gap - d / 2, y: bounds.midY)
    }
    NSColor.labelColor.withAlphaComponent(0.8).setFill()
    NSBezierPath(ovalIn: CGRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d)).fill()
  }

  /// Red count pill on the icon's top-right corner, like the Dock's.
  private func drawBadge(_ text: String, icon: CGRect) {
    let height = (tile * 0.42).rounded()
    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: height * 0.68, weight: .medium),
      .foregroundColor: NSColor.white,
    ]
    let label = NSAttributedString(string: text, attributes: attrs)
    let size = label.size()
    let width = max(height, size.width + height * 0.5)
    let pill = CGRect(x: min(icon.maxX - width * 0.8, bounds.maxX - width), y: icon.maxY - height * 0.8, width: width, height: height)
    NSColor.systemRed.setFill()
    NSBezierPath(roundedRect: pill, xRadius: height / 2, yRadius: height / 2).fill()
    label.draw(at: CGPoint(x: pill.midX - size.width / 2, y: pill.midY - size.height / 2))
  }

  override func mouseDown(with _: NSEvent) { pressed = true }

  override func mouseUp(with event: NSEvent) {
    pressed = false
    if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
  }

  override func mouseEntered(with _: NSEvent) { onHover?(true) }
  override func mouseExited(with _: NSEvent) { onHover?(false) }

  override func menu(for _: NSEvent) -> NSMenu? { menuProvider?() }

  // MARK: Dropping files

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    guard onDrop != nil, !Self.fileURLs(sender).isEmpty else { return [] }
    pressed = true
    return item.kind == .trash ? .move : .copy
  }

  override func draggingExited(_: NSDraggingInfo?) { pressed = false }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    pressed = false
    let urls = Self.fileURLs(sender)
    guard let onDrop, !urls.isEmpty else { return false }
    onDrop(urls)
    return true
  }

  private static func fileURLs(_ info: NSDraggingInfo) -> [URL] {
    info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
  }
}

/// A menu item that runs a closure.
final class ActionMenuItem: NSMenuItem {
  private let handler: () -> Void

  init(_ title: String, _ handler: @escaping () -> Void) {
    self.handler = handler
    super.init(title: title, action: #selector(run), keyEquivalent: "")
    target = self
  }

  @available(*, unavailable)
  required init(coder _: NSCoder) { fatalError() }

  @objc private func run() { handler() }
}

private final class SeparatorView: NSView {
  private let edge: DockEdge
  private let tile: CGFloat

  init(frame: CGRect, edge: DockEdge, tile: CGFloat) {
    self.edge = edge
    self.tile = tile
    super.init(frame: frame)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) { fatalError() }

  override func draw(_: NSRect) {
    NSColor.labelColor.withAlphaComponent(0.25).setFill()
    let len = tile * 0.85
    let line = edge == .bottom
      ? CGRect(x: bounds.midX - 0.5, y: bounds.midY - len / 2, width: 1, height: len)
      : CGRect(x: bounds.midX - len / 2, y: bounds.midY - 0.5, width: len, height: 1)
    line.fill()
  }
}

/// The app-name label the Dock shows while hovering an icon.
@MainActor
private final class TitleBubble {
  private var panel: NSPanel?

  func show(_ text: String, over item: CGRect, edge: DockEdge) {
    hide()
    guard !text.isEmpty else { return }
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: 13)
    label.textColor = .labelColor
    let size = label.fittingSize
    let box = CGSize(width: size.width + 20, height: size.height + 8)
    let gap: CGFloat = 8
    let origin: CGPoint
    switch edge {
    case .bottom: origin = CGPoint(x: item.midX - box.width / 2, y: item.maxY + gap)
    case .left: origin = CGPoint(x: item.maxX + gap, y: item.midY - box.height / 2)
    case .right: origin = CGPoint(x: item.minX - gap - box.width, y: item.midY - box.height / 2)
    }
    let p = NSPanel(contentRect: CGRect(origin: origin, size: box), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
    p.isOpaque = false
    p.backgroundColor = .clear
    p.ignoresMouseEvents = true
    p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    p.appearance = AppAppearance.systemAppearance
    let bg = NSVisualEffectView(frame: CGRect(origin: .zero, size: box))
    bg.material = .toolTip
    bg.state = .active
    bg.wantsLayer = true
    bg.layer?.cornerRadius = box.height / 2
    bg.layer?.masksToBounds = true
    label.frame = CGRect(x: 10, y: 4, width: size.width, height: size.height)
    bg.addSubview(label)
    p.contentView = bg
    p.orderFrontRegardless()
    panel = p
  }

  func hide() {
    panel?.orderOut(nil)
    panel = nil
  }
}

@MainActor
enum IconCache {
  private static var cache: [String: NSImage] = [:]

  static func icon(for item: DockItem) -> NSImage {
    if item.kind == .trash {
      // The Trash item's URL doesn't distinguish empty from full.
      let full = (try? FileManager.default.contentsOfDirectory(atPath: NSHomeDirectory() + "/.Trash"))?.contains { $0 != ".DS_Store" } ?? false
      return NSImage(named: full ? NSImage.trashFullName : NSImage.trashEmptyName) ?? NSImage()
    }
    let key = item.url?.path ?? item.title
    if let hit = cache[key] { return hit }
    let image = item.url.map { NSWorkspace.shared.icon(forFile: $0.path) }
      ?? NSImage(systemSymbolName: "questionmark.app", accessibilityDescription: nil) ?? NSImage()
    cache[key] = image
    return image
  }
}
