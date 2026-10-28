import Cocoa

private final class GlassBadgeView: NSVisualEffectView {
  init(diameter: CGFloat, text: String, dark: Bool) {
    super.init(frame: CGRect(origin: .zero, size: CGSize(width: diameter, height: diameter)))
    // Dark: translucent-dark glass; light: frosted-light glass.
    material = dark ? .hudWindow : .popover
    blendingMode = .behindWindow
    state = .active
    wantsLayer = true
    layer?.cornerRadius = diameter / 2
    layer?.masksToBounds = true
    layer?.borderColor = NSColor.white.withAlphaComponent(dark ? 0.5 : 0.7).cgColor
    layer?.borderWidth = 1

    // Top-down specular gloss: the "liquid" cue.
    let gloss = CAGradientLayer()
    gloss.colors = [
      NSColor.white.withAlphaComponent(dark ? 0.28 : 0.5).cgColor,
      NSColor.white.withAlphaComponent(0.0).cgColor,
    ]
    gloss.startPoint = CGPoint(x: 0.5, y: 0.0)
    gloss.endPoint = CGPoint(x: 0.5, y: 1.0)
    gloss.frame = bounds
    gloss.cornerRadius = diameter / 2
    layer?.addSublayer(gloss)

    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: (diameter * 0.53).rounded(), weight: .semibold)
    label.textColor = dark ? .white : .black
    label.alignment = .center
    // Vertically true-center: NSTextField doesn't center text within an
    // oversized frame, so center the field itself (intrinsic height) instead.
    label.translatesAutoresizingMaskIntoConstraints = false
    addSubview(label)
    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: centerXAnchor),
      label.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 0.5),
    ])
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) { fatalError() }
}

private extension NSShadow {
  func withConfigured(color: NSColor, blur: CGFloat, offset: CGSize) -> NSShadow {
    let s = NSShadow()
    s.shadowColor = color
    s.shadowBlurRadius = blur
    s.shadowOffset = offset
    return s
  }
}

/// Floating number badges beside Dock icons.
/// AX frames use a top-left origin; Cocoa windows use bottom-left, so we flip Y.
/// Badge presentation style.
enum BadgeStyle {
  /// Option-hold: large badges beside icons, toward the screen center.
  case hold
  /// Always-visible: small badges inset in the icon's top-left corner,
  /// fully inside the Dock perimeter.
  case persistent
}

final class OverlayManager {
  private var panels: [NSPanel] = []
  /// What the panels currently show (nil = hidden). Lets the watcher tell
  /// a hold overlay apart from persistent mini-badges.
  private(set) var styleShown: BadgeStyle?
  private let holdSize: CGFloat = 28
  private let persistentSize: CGFloat = 20
  /// Inset of persistent badges from the icon corner (keeps them on the icon).
  private let cornerInset: CGFloat = 2
  private let gap: CGFloat = 8

  func show(apps: [DockApp], style: BadgeStyle = .hold) {
    hide()
    // Only 1–9 and 0 have keys: an 11th app would repeat the 1st's number.
    let apps = apps.filter { $0.index <= 10 }
    let dark = AppAppearance.isDark
    let diameter = style == .hold ? holdSize : persistentSize
    let icons = apps.map { (app: $0, icon: Coords.flip($0.frame)) }
    // The real Dock's display, which needn't be the main one. Badges go on
    // the side of its edge facing the screen center.
    let dockRect = icons.map(\.icon).reduce(CGRect.null) { $0.union($1) }
    guard let screen = NSScreen.containing(dockRect) else { return }
    let edge = DockPrefs.read().edge
    // The real Dock's inner (screen-center-facing) edge on a side Dock:
    // where visibleFrame begins or ends (nil when auto-hidden, as it then
    // reserves nothing).
    let visible = screen.visibleFrame
    let dockInnerX: CGFloat? = switch edge {
    case .left: visible.minX > screen.frame.minX ? visible.minX : nil
    case .right: visible.maxX < screen.frame.maxX ? visible.maxX : nil
    case .bottom: nil
    }
    // Same numbers on the Dock clones on other displays.
    var targets = icons.map { (app: $0.app, icon: $0.icon, edge: edge, dockInnerX: dockInnerX) }
    for app in apps {
      for clone in DockClones.shared.icons(of: app.bundleURL, title: app.title) {
        targets.append((app, clone.frame, clone.edge, clone.edge == .right ? clone.dock.minX : clone.dock.maxX))
      }
    }
    // Not over a full-screen app: the real Dock hides there, and the clone
    // on such a display is gone.
    let fullscreen = NSScreen.screens.filter(FullscreenSpaces.shared.contains)
    targets.removeAll { target in
      fullscreen.contains { $0.frame.contains(CGPoint(x: target.icon.midX, y: target.icon.midY)) }
    }

    for (app, icon, edge, dockInnerX) in targets {
      let origin = badgeOrigin(for: icon, edge: edge, dockInnerX: dockInnerX, diameter: diameter, style: style)
      let panel = NSPanel(
        contentRect: CGRect(origin: origin, size: CGSize(width: diameter, height: diameter)),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
      )
      panel.level = .screenSaver
      panel.isOpaque = false
      panel.backgroundColor = .clear
      panel.hasShadow = style == .hold
      panel.ignoresMouseEvents = true
      panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

      panel.contentView = GlassBadgeView(diameter: diameter, text: "\(app.index % 10)", dark: dark)
      panel.alphaValue = 0
      panel.orderFrontRegardless()
      NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = 0.12
        panel.animator().alphaValue = 1
      }
      panels.append(panel)
    }
    styleShown = style
  }

  func hide() {
    for p in panels { p.orderOut(nil) }
    panels.removeAll()
    styleShown = nil
  }

  private func badgeOrigin(for icon: CGRect, edge: DockEdge, dockInnerX: CGFloat?, diameter: CGFloat, style: BadgeStyle) -> CGPoint {
    switch style {
    case .persistent:
      // A corner of the icon, inset so the badge sits on the icon, inside
      // the Dock perimeter: top-left with the Dock at the bottom; on a side
      // Dock the bottom corner facing the screen center, pushed toward the
      // Dock's inner edge as far as still fits inside the Dock.
      guard edge != .bottom else {
        return CGPoint(x: icon.minX + cornerInset, y: icon.maxY - diameter - cornerInset)
      }
      // The Dock's item frames are wider than the icon: use the square
      // in their middle so the badge lands on the icon's corner.
      let s = min(icon.width, icon.height)
      let square = CGRect(x: icon.midX - s / 2, y: icon.midY - s / 2, width: s, height: s)
      // 1 pt inside the Dock's border; without a known edge, slightly over
      // the icon's.
      if edge == .left {
        let right = dockInnerX.map { $0 - 1 } ?? square.maxX + 2
        return CGPoint(x: right - diameter, y: square.minY + cornerInset)
      }
      let left = dockInnerX.map { $0 + 1 } ?? square.minX - 2
      return CGPoint(x: left, y: square.minY + cornerInset)
    case .hold:
      switch edge {
      case .right: // Dock on right -> badges to the left, vertically centered
        return CGPoint(x: icon.minX - gap - diameter, y: icon.midY - diameter / 2)
      case .left: // Dock on left -> badges to the right
        return CGPoint(x: icon.maxX + gap, y: icon.midY - diameter / 2)
      case .bottom: // Dock on bottom -> badges above
        return CGPoint(x: icon.midX - diameter / 2, y: icon.maxY + gap)
      }
    }
  }

}
