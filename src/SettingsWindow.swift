import Cocoa
import ApplicationServices
import ServiceManagement

/// Settings window, macOS System Settings style: toolbar tabs (General,
/// Dock Shortcuts, Dock Clones, About) with grouped boxes. The window
/// resizes to each tab's content. Always used from the main thread.
final class SettingsWindowController: NSWindowController {
  private var loginSwitch: NSSwitch!
  private var loginErrorLabel: NSTextField!
  private var accessLabel: NSTextField!
  private var accessButton: NSButton!
  private var menubarSwitch: NSSwitch!
  private var alwaysSwitch: NSSwitch!
  private var clonesSwitch: NSSwitch!
  private var keepClearSwitch: NSSwitch!
  private var themePopup: NSPopUpButton!
  private var delaySlider: NSSlider!
  private var delayLabel: NSTextField!
  private let tabs = SettingsTabViewController()

  /// Content width of every tab.
  private static let width: CGFloat = 400

  init() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 300),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    window.toolbarStyle = .preference
    super.init(window: window)
    buildUI()
    window.contentViewController = tabs
    tabs.fitWindow()
    window.center()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) { fatalError() }

  static let shared = SettingsWindowController()

  // MARK: - Layout

  private func buildUI() {
    tabs.tabStyle = .toolbar
    tabs.addTabViewItem(tab("General", symbol: "gearshape", page: generalPage()))
    tabs.addTabViewItem(tab("Dock Shortcuts", symbol: "keyboard", page: shortcutsPage()))
    tabs.addTabViewItem(tab("Dock Clones", symbol: "rectangle.on.rectangle", page: clonesPage()))
    tabs.addTabViewItem(tab("About", symbol: "info.circle", page: aboutPage()))

    refreshAll()
    NotificationCenter.default.addObserver(
      self, selector: #selector(refreshAccessibility),
      name: NSApplication.didBecomeActiveNotification, object: nil
    )
    // Live-update the permission row: the grant happens in System Settings.
    NotificationCenter.default.addObserver(
      self, selector: #selector(refreshAccessibility),
      name: .accessibilityChanged, object: nil
    )
  }

  private func generalPage() -> [NSView] {
    loginSwitch = NSSwitch()
    loginSwitch.target = self
    loginSwitch.action = #selector(loginToggled(_:))
    menubarSwitch = NSSwitch()
    menubarSwitch.target = self
    menubarSwitch.action = #selector(menubarToggled(_:))
    themePopup = NSPopUpButton()
    themePopup.addItems(withTitles: AppAppearance.allCases.map(\.label))
    themePopup.target = self
    themePopup.action = #selector(appearanceChanged(_:))
    let general = section(title: "General", rows: [
      ("Start automatically when you log in", loginSwitch),
      ("Show menu bar icon", menubarSwitch),
      ("Appearance", themePopup),
    ])

    loginErrorLabel = NSTextField(wrappingLabelWithString: "")
    loginErrorLabel.font = .systemFont(ofSize: 12)
    loginErrorLabel.textColor = .systemRed
    loginErrorLabel.preferredMaxLayoutWidth = Self.width - 40
    loginErrorLabel.isHidden = true

    accessLabel = NSTextField(wrappingLabelWithString: "")
    accessLabel.font = .systemFont(ofSize: 13)
    accessLabel.preferredMaxLayoutWidth = Self.width - 68
    accessButton = NSButton(title: "Open System Settings…", target: self, action: #selector(openAccessibilitySettings(_:)))
    accessButton.bezelStyle = .rounded
    let access = section(title: "Accessibility", rows: [(nil, accessLabel), (nil, accessButton)])

    // Quit: the only way out when the menu bar icon is hidden.
    let quitButton = NSButton(title: "Quit DockUtils", target: NSApp, action: #selector(NSApplication.terminate(_:)))
    quitButton.bezelStyle = .rounded
    return [general, loginErrorLabel, access, quitButton]
  }

  private func shortcutsPage() -> [NSView] {
    alwaysSwitch = NSSwitch()
    alwaysSwitch.target = self
    alwaysSwitch.action = #selector(alwaysToggled(_:))

    let delayRow = NSStackView()
    delayRow.orientation = .horizontal
    delayRow.alignment = .centerY
    delayRow.spacing = 8
    // Same row height as the switch/popup rows so the rhythm stays even.
    delayRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 26).isActive = true
    delaySlider = NSSlider(value: 100, minValue: 0, maxValue: 500, target: self, action: #selector(delayChanged(_:)))
    delaySlider.translatesAutoresizingMaskIntoConstraints = false
    delaySlider.widthAnchor.constraint(equalToConstant: 130).isActive = true
    delayRow.addArrangedSubview(delaySlider)
    delayLabel = NSTextField(labelWithString: "")
    delayLabel.font = .systemFont(ofSize: 13)
    delayLabel.alignment = .right
    delayLabel.translatesAutoresizingMaskIntoConstraints = false
    delayLabel.widthAnchor.constraint(equalToConstant: 52).isActive = true
    delayRow.addArrangedSubview(delayLabel)

    return [
      hint("Hold Option for numbered badges on your Dock icons, then press 1–9 or 0 to switch apps. Press again to cycle an app's windows."),
      section(title: "Badges", rows: [
        ("Badges always visible", alwaysSwitch),
        ("Badge delay", delayRow),
      ]),
    ]
  }

  private func clonesPage() -> [NSView] {
    clonesSwitch = NSSwitch()
    clonesSwitch.target = self
    clonesSwitch.action = #selector(clonesToggled(_:))
    keepClearSwitch = NSSwitch()
    keepClearSwitch.target = self
    keepClearSwitch.action = #selector(keepClearToggled(_:))
    return [
      hint("A clone of the Dock on every display the real Dock isn't on, with the same apps, running indicators and badges. Zoomed and tiled windows stop at a clone's edge."),
      section(title: "Dock Clones", rows: [
        ("Show Dock clones on other displays", clonesSwitch),
        ("Keep windows clear of the clones", keepClearSwitch),
      ]),
    ]
  }

  private func aboutPage() -> [NSView] {
    let header = NSStackView()
    header.orientation = .horizontal
    header.alignment = .centerY
    header.spacing = 12
    let iconView = NSImageView(image: NSApp.applicationIconImage)
    iconView.imageScaling = .scaleProportionallyUpOrDown
    iconView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      iconView.widthAnchor.constraint(equalToConstant: 64),
      iconView.heightAnchor.constraint(equalToConstant: 64),
    ])
    header.addArrangedSubview(iconView)
    let titleStack = NSStackView()
    titleStack.orientation = .vertical
    titleStack.alignment = .leading
    titleStack.spacing = 4
    let nameRow = NSStackView()
    nameRow.orientation = .horizontal
    nameRow.alignment = .lastBaseline
    nameRow.spacing = 8
    let title = NSTextField(labelWithString: "DockUtils")
    title.font = .systemFont(ofSize: 16, weight: .semibold)
    nameRow.addArrangedSubview(title)
    if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
      let versionLabel = NSTextField(labelWithString: version)
      versionLabel.font = .systemFont(ofSize: 12)
      versionLabel.textColor = .secondaryLabelColor
      nameRow.addArrangedSubview(versionLabel)
    }
    titleStack.addArrangedSubview(nameRow)
    let aboutName = NSTextField(labelWithString: "Made by Gellért Kovács")
    aboutName.font = .systemFont(ofSize: 12)
    aboutName.textColor = .secondaryLabelColor
    titleStack.addArrangedSubview(aboutName)
    let repoURL = URL(string: "https://github.com/kovacsgellert/dock-utils-mac")!
    let repoLink = NSTextField(wrappingLabelWithString: "")
    repoLink.isEditable = false
    repoLink.isSelectable = true
    repoLink.attributedStringValue = NSAttributedString(
      string: "github.com/kovacsgellert/dock-utils-mac",
      attributes: [.link: repoURL, .font: NSFont.systemFont(ofSize: 12)]
    )
    // Selectable fields don't always fire links on single click — belt and braces.
    repoLink.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(openRepo(_:))))
    titleStack.addArrangedSubview(repoLink)
    header.addArrangedSubview(titleStack)
    return [header]
  }

  /// One tab: its views stacked top to bottom at the window's width.
  private func tab(_ label: String, symbol: String, page views: [NSView]) -> NSTabViewItem {
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 14
    stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
    stack.translatesAutoresizingMaskIntoConstraints = false
    let page = NSViewController()
    page.view = NSView()
    page.view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: page.view.topAnchor),
      stack.leadingAnchor.constraint(equalTo: page.view.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: page.view.trailingAnchor),
      // Pinned to the top; shorter tabs leave room below.
      stack.bottomAnchor.constraint(lessThanOrEqualTo: page.view.bottomAnchor),
      stack.widthAnchor.constraint(equalToConstant: Self.width),
    ])
    // Groups span the full width, so every box in a tab lines up.
    for view in views where view.identifier == Self.sectionID {
      view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
    }
    page.title = label
    let item = NSTabViewItem(viewController: page)
    item.label = label
    item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
    return item
  }

  /// Secondary explanatory text at the top of a tab.
  private func hint(_ text: String) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: text)
    field.font = .systemFont(ofSize: 12)
    field.textColor = .secondaryLabelColor
    // Bound the unwrapped intrinsic width, otherwise the stack overflows.
    field.preferredMaxLayoutWidth = Self.width - 40
    return field
  }

  private static let sectionID = NSUserInterfaceItemIdentifier("section")

  /// Caption + rounded group with label/control rows (nil label = full-width row).
  private func section(title: String, rows: [(String?, NSView)]) -> NSView {    let wrap = NSStackView()
    wrap.orientation = .vertical
    wrap.alignment = .leading
    wrap.spacing = 6
    wrap.translatesAutoresizingMaskIntoConstraints = false
    let caption = NSTextField(labelWithString: title)
    caption.font = .systemFont(ofSize: 13, weight: .semibold)
    caption.textColor = .secondaryLabelColor
    wrap.addArrangedSubview(caption)

    let boxView = GroupBoxView()
    boxView.translatesAutoresizingMaskIntoConstraints = false
    let inner = NSStackView()
    inner.orientation = .vertical
    inner.spacing = 12
    inner.translatesAutoresizingMaskIntoConstraints = false
    for (label, control) in rows {
      if let label {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        let l = NSTextField(labelWithString: label)
        l.font = .systemFont(ofSize: 13)
        l.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        row.addArrangedSubview(l)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(control)
        inner.addArrangedSubview(row)
      } else {
        // Leading-aligned like the labels (the stack centers by default).
        let row = NSStackView(views: [control, NSView()])
        row.orientation = .horizontal
        inner.addArrangedSubview(row)
      }
    }
    boxView.addSubview(inner)
    NSLayoutConstraint.activate([
      inner.topAnchor.constraint(equalTo: boxView.topAnchor, constant: 12),
      inner.leadingAnchor.constraint(equalTo: boxView.leadingAnchor, constant: 14),
      inner.trailingAnchor.constraint(equalTo: boxView.trailingAnchor, constant: -14),
      inner.bottomAnchor.constraint(equalTo: boxView.bottomAnchor, constant: -12),
    ])
    wrap.addArrangedSubview(boxView)
    boxView.widthAnchor.constraint(equalTo: wrap.widthAnchor).isActive = true
    wrap.identifier = Self.sectionID
    return wrap
  }

  // MARK: - Behavior

  func show() {
    refreshAll()
    window?.center()
    // The app is a menu-bar agent (LSUIElement): ordering the window front
    // while the app is inactive parks it *behind* the frontmost app's
    // windows — and with no Dock icon there is no way to click it forward
    // again, so Settings silently "does nothing" until relaunch. Activate
    // the app first (`ignoringOtherApps` reliably works for an accessory app
    // and does not give it a Dock icon), then order the window front, so it
    // lands above every other app's windows.
    NSApp.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
  }

  @objc func showFromMenu(_: Any?) {
    show()
  }

  private func refreshAll() {
    // Re-read config.yml: hand/script edits show up on next open.
    AppConfig.shared.reload()
    // Dev builds can't own the login item (see loginToggled): show the
    // switch disabled rather than a meaningless state.
    loginSwitch.isEnabled = DockUtils.isAppBundle
    loginSwitch.toolTip = DockUtils.isAppBundle ? nil : "Start-at-login is managed by the installed DockUtils.app, not dev builds."
    loginSwitch.state = LaunchAtLogin.isEnabled ? .on : .off
    menubarSwitch.state = ShowMenuBarIcon.isEnabled ? .on : .off
    alwaysSwitch.state = AppConfig.shared.badgesAlwaysVisible ? .on : .off
    clonesSwitch.state = AppConfig.shared.dockClones ? .on : .off
    keepClearSwitch.state = AppConfig.shared.dockClonesKeepWindowsClear ? .on : .off
    updateClonesEnabled()
    themePopup.selectItem(withTitle: AppAppearance.current.label)
    delaySlider.doubleValue = Double(AppConfig.shared.badgeDelayMs)
    delayLabel.stringValue = "\(AppConfig.shared.badgeDelayMs) ms"
    updateDelayEnabled()
    loginErrorLabel.isHidden = true
    if DockUtils.isAppBundle, LaunchAtLogin.needsApproval { showLoginNeedsApproval() }
    refreshAccessibility()
  }

  /// Switched off under Login Items in System Settings: only the user can
  /// allow it again there.
  private func showLoginNeedsApproval() {
    loginErrorLabel.stringValue = "DockUtils is turned off in System Settings → General → Login Items. Turn it on there to start at login."
    loginErrorLabel.isHidden = false
    tabs.fitWindow()
  }

  @objc private func loginToggled(_ sender: NSSwitch) {
    // Dev builds run as a bare binary: toggling here would register that
    // throwaway binary (or unregister the installed app) at login.
    guard DockUtils.isAppBundle else {
      sender.state = .off
      loginErrorLabel.stringValue = "Start-at-login is managed by the installed DockUtils.app, not dev builds."
      loginErrorLabel.isHidden = false
      tabs.fitWindow()
      return
    }
    loginErrorLabel.isHidden = true
    do {
      try LaunchAtLogin.setEnabled(sender.state == .on)
      AppConfig.shared.startAtLogin = sender.state == .on
      AppConfig.shared.save()
      if sender.state == .on, LaunchAtLogin.needsApproval {
        sender.state = .off
        showLoginNeedsApproval()
        SMAppService.openSystemSettingsLoginItems()
      }
    } catch {
      loginErrorLabel.stringValue = "Couldn't change login item: \(error.localizedDescription)"
      loginErrorLabel.isHidden = false
      tabs.fitWindow()
      sender.state = LaunchAtLogin.isEnabled ? .on : .off
    }
  }

  @objc private func menubarToggled(_ sender: NSSwitch) {
    ShowMenuBarIcon.setEnabled(sender.state == .on)
    DockUtils.updateStatusItem(settings: SettingsWindowController.shared)
  }

  @objc private func refreshAccessibility() {
    let granted = AXIsProcessTrusted()
    accessLabel.stringValue = granted
      ? "Accessibility access: granted ✓"
      : "Accessibility access: required for badges and Dock clones"
    // No need to offer System Settings when there's nothing to fix.
    accessButton.superview?.isHidden = granted
    tabs.fitWindow()
  }

  @objc private func openAccessibilitySettings(_: NSButton) {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
  }

  @objc private func openRepo(_: NSGestureRecognizer) {
    NSWorkspace.shared.open(URL(string: "https://github.com/kovacsgellert/dock-utils-mac")!)
  }

  @objc private func appearanceChanged(_ sender: NSPopUpButton) {
    guard let selected = AppAppearance.allCases.first(where: { $0.label == sender.titleOfSelectedItem }) else { return }
    AppAppearance.current = selected
    AppAppearance.apply()
  }

  @objc private func alwaysToggled(_ sender: NSSwitch) {
    AppConfig.shared.badgesAlwaysVisible = sender.state == .on
    AppConfig.shared.save()
    updateDelayEnabled()
    NotificationCenter.default.post(name: .appConfigChanged, object: nil)
  }

  @objc private func clonesToggled(_ sender: NSSwitch) {
    AppConfig.shared.dockClones = sender.state == .on
    AppConfig.shared.save()
    updateClonesEnabled()
    NotificationCenter.default.post(name: .appConfigChanged, object: nil)
  }

  /// Clone options only matter while clones are on.
  private func updateClonesEnabled() {
    keepClearSwitch.isEnabled = AppConfig.shared.dockClones
  }

  @objc private func keepClearToggled(_ sender: NSSwitch) {
    AppConfig.shared.dockClonesKeepWindowsClear = sender.state == .on
    AppConfig.shared.save()
    NotificationCenter.default.post(name: .appConfigChanged, object: nil)
  }

  /// The hold-to-show delay is meaningless with persistent minis on screen.
  private func updateDelayEnabled() {
    let enabled = !AppConfig.shared.badgesAlwaysVisible
    delaySlider.isEnabled = enabled
    delayLabel.textColor = enabled ? .labelColor : .disabledControlTextColor
  }

  @objc private func delayChanged(_ sender: NSSlider) {
    let ms = min(max(Int(sender.doubleValue.rounded()), 0), 500)
    AppConfig.shared.badgeDelayMs = ms
    AppConfig.shared.save()
    delayLabel.stringValue = "\(ms) ms"
  }
}

/// Rounded settings group whose fill tracks light/dark appearance.
/// (Resolving a dynamic NSColor to CGColor once would freeze the
/// creation-time appearance — this re-resolves on every change.)
private final class GroupBoxView: NSView {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.cornerRadius = 10
    refresh()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) { fatalError() }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    refresh()
  }

  private func refresh() {
    layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
  }
}

/// Toolbar tabs in a window of constant size: tall enough for the tallest
/// tab, so switching tabs never resizes it (shorter tabs top-aligned).
final class SettingsTabViewController: NSTabViewController {
  /// Size the window for the tallest tab. Called again when a tab's content
  /// changes height (e.g. a permission or error row appears); only grows.
  func fitWindow() {
    guard let window = view.window else { return }
    let pages = tabViewItems.compactMap { $0.viewController?.view }
    for page in pages { page.layoutSubtreeIfNeeded() }
    let needed = CGSize(
      width: pages.map(\.fittingSize.width).max() ?? 0,
      height: pages.map(\.fittingSize.height).max() ?? 0
    )
    let current = window.contentRect(forFrameRect: window.frame).size
    guard needed.height > current.height || needed.width != current.width else { return }
    for item in tabViewItems { item.viewController?.preferredContentSize = needed }
    let frame = window.frameRect(forContentRect: CGRect(origin: .zero, size: needed))
    let old = window.frame
    // Keep the top edge in place.
    window.setFrame(CGRect(x: old.minX, y: old.maxY - frame.height, width: frame.width, height: frame.height), display: true)
  }
}
