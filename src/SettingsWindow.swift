import Cocoa
import ApplicationServices
import ServiceManagement

/// Settings window, macOS System Settings style: toolbar tabs (General,
/// Dock Shortcuts, Dock Clones, About) with grouped boxes. The window
/// resizes to each tab's content. Always used from the main thread.
final class SettingsWindowController: NSWindowController {
  private var loginSwitch: NSSwitch!
  private var loginErrorLabel: NSTextField!
  /// One per tab, shown while Accessibility is missing.
  private var permissionBanners: [NSView] = []
  private var menubarSwitch: NSSwitch!
  private var alwaysSwitch: NSSwitch!
  private var clonesSwitch: NSSwitch!
  private var keepClearSwitch: NSSwitch!
  private let arrangement = DisplayArrangementView()
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
    tabs.addTabViewItem(tab("General", symbol: "gearshape", page: [permissionBanner()] + generalPage()))
    tabs.addTabViewItem(tab("Dock Shortcuts", symbol: "keyboard", page: [permissionBanner()] + shortcutsPage()))
    tabs.addTabViewItem(tab("Dock Clones", symbol: "rectangle.on.rectangle", page: [permissionBanner()] + clonesPage()))
    tabs.addTabViewItem(tab("About", symbol: "info.circle", page: [permissionBanner()] + aboutPage()))

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
    // The display map follows displays coming and going, the Dock moving
    // and hand edits of config.yml while the window is open.
    for name in [NSApplication.didChangeScreenParametersNotification, .dockSnapshotUpdated, .appConfigChanged] {
      NotificationCenter.default.addObserver(self, selector: #selector(refreshArrangement), name: name, object: nil)
    }
    arrangement.onChange = { [weak self] uuid, name, placement in
      self?.placementChosen(uuid: uuid, name: name, placement: placement)
    }
  }

  private func generalPage() -> [NSView] {
    loginSwitch = NSSwitch()
    loginSwitch.target = self
    loginSwitch.action = #selector(loginToggled(_:))
    menubarSwitch = NSSwitch()
    menubarSwitch.target = self
    menubarSwitch.action = #selector(menubarToggled(_:))
    themePopup = NSPopUpButton()
    // Item i is AppAppearance.allCases[i].
    themePopup.addItems(withTitles: AppAppearance.allCases.map(\.label))
    themePopup.target = self
    themePopup.action = #selector(appearanceChanged(_:))
    let configButton = NSButton(title: "Open config.yml", target: self, action: #selector(openConfigFile(_:)))
    configButton.bezelStyle = .rounded
    configButton.toolTip = AppConfig.fileURL.path
    let general = section(title: "General", rows: [
      ("Start automatically when you log in", loginSwitch),
      ("Show menu bar icon", menubarSwitch),
      ("Appearance", themePopup),
      ("Settings file", configButton),
    ])

    loginErrorLabel = NSTextField(wrappingLabelWithString: "")
    loginErrorLabel.font = .systemFont(ofSize: 12)
    loginErrorLabel.textColor = .systemRed
    loginErrorLabel.preferredMaxLayoutWidth = Self.width - 40
    loginErrorLabel.isHidden = true

    // Quit: the only way out when the menu bar icon is hidden.
    let quitButton = NSButton(title: "Quit DockUtils", target: NSApp, action: #selector(NSApplication.terminate(_:)))
    quitButton.bezelStyle = .rounded
    return [general, loginErrorLabel, quitButton]
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
    // 25 ms steps; the label follows the knob while dragging.
    delaySlider.numberOfTickMarks = 21
    delaySlider.allowsTickMarkValuesOnly = true
    delaySlider.isContinuous = true
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
      section(title: "Position", rows: [
        (nil, arrangement),
        (nil, hint("Click near a display's bottom, left or right edge to put its clone there: toward either end, or centered. Click the middle of a display to make it follow the Dock or turn its clone off. Each display remembers its choice.", width: DisplayArrangementView.size.width)),
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

  /// Shown at the top of every tab while Accessibility is missing: badges
  /// and clones do nothing without it, and nothing else would say so.
  private func permissionBanner() -> NSView {
    let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning") ?? NSImage())
    icon.contentTintColor = .systemOrange
    icon.setContentHuggingPriority(.required, for: .horizontal)
    let text = NSTextField(wrappingLabelWithString: "DockUtils needs Accessibility access. Until it's allowed, badges, shortcuts and Dock clones don't work.")
    text.font = .systemFont(ofSize: 12)
    text.preferredMaxLayoutWidth = Self.width - 40 - 28 - 30
    let button = NSButton(title: "Open System Settings…", target: self, action: #selector(openAccessibilitySettings(_:)))
    button.bezelStyle = .rounded
    let column = NSStackView(views: [text, button])
    column.orientation = .vertical
    column.alignment = .leading
    column.spacing = 8
    let row = NSStackView(views: [icon, column])
    row.orientation = .horizontal
    row.alignment = .top
    row.spacing = 10
    row.translatesAutoresizingMaskIntoConstraints = false
    let box = GroupBoxView(fill: NSColor.systemOrange.withAlphaComponent(0.15))
    box.translatesAutoresizingMaskIntoConstraints = false
    box.addSubview(row)
    NSLayoutConstraint.activate([
      row.topAnchor.constraint(equalTo: box.topAnchor, constant: 12),
      row.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
      row.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -14),
      row.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -12),
    ])
    // Full width, like the sections (see tab()).
    box.identifier = Self.sectionID
    permissionBanners.append(box)
    return box
  }

  /// Secondary explanatory text at the top of a tab.
  private func hint(_ text: String, width: CGFloat = SettingsWindowController.width - 40) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: text)
    field.font = .systemFont(ofSize: 12)
    field.textColor = .secondaryLabelColor
    // Bound the unwrapped intrinsic width, otherwise the stack overflows.
    field.preferredMaxLayoutWidth = width
    return field
  }

  private static let sectionID = NSUserInterfaceItemIdentifier("section")

  /// Caption + rounded group with label/control rows (nil label = full-width row).
  private func section(title: String, rows: [(String?, NSView)]) -> NSView {
    let wrap = NSStackView()
    wrap.orientation = .vertical
    wrap.alignment = .leading
    wrap.spacing = 6
    wrap.translatesAutoresizingMaskIntoConstraints = false
    let caption = NSTextField(labelWithString: title)
    caption.font = .systemFont(ofSize: 13, weight: .semibold)
    caption.textColor = .secondaryLabelColor
    wrap.addArrangedSubview(caption)

    let boxView = GroupBoxView(fill: .controlBackgroundColor)
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
    menubarSwitch.state = AppConfig.shared.showMenuBarIcon ? .on : .off
    alwaysSwitch.state = AppConfig.shared.badgesAlwaysVisible ? .on : .off
    clonesSwitch.state = AppConfig.shared.dockClones ? .on : .off
    keepClearSwitch.state = AppConfig.shared.dockClonesKeepWindowsClear ? .on : .off
    updateClonesEnabled()
    MainActor.assumeIsolated { arrangement.reload() }
    themePopup.selectItem(at: AppAppearance.allCases.firstIndex(of: AppAppearance.current) ?? 0)
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
      NotificationCenter.default.post(name: .appConfigChanged, object: nil)
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
    AppConfig.shared.showMenuBarIcon = sender.state == .on
    AppConfig.shared.save()
    NotificationCenter.default.post(name: .appConfigChanged, object: nil)
  }

  @objc private func refreshAccessibility() {
    let granted = AXIsProcessTrusted()
    for banner in permissionBanners { banner.isHidden = granted }
    tabs.fitWindow()
  }

  @objc private func openAccessibilitySettings(_: NSButton) {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
  }

  @objc private func openConfigFile(_: NSButton) {
    let url = AppConfig.fileURL
    // A fresh Mac has no app for .yml files: fall back to TextEdit.
    if NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
      NSWorkspace.shared.open(url)
    } else if let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
      NSWorkspace.shared.open([url], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
    }
  }

  @objc private func openRepo(_: NSGestureRecognizer) {
    NSWorkspace.shared.open(URL(string: "https://github.com/kovacsgellert/dock-utils-mac")!)
  }

  @objc private func appearanceChanged(_ sender: NSPopUpButton) {
    guard AppAppearance.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
    AppAppearance.current = AppAppearance.allCases[sender.indexOfSelectedItem]
    NotificationCenter.default.post(name: .appConfigChanged, object: nil)
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
    arrangement.isEnabled = AppConfig.shared.dockClones
  }

  @objc private func refreshArrangement() {
    guard window?.isVisible == true else { return }
    // Hand edits of config.yml are already reloaded into AppConfig.shared.
    updateClonesEnabled()
    MainActor.assumeIsolated { arrangement.reload() }
  }

  /// Following the Dock is what unknown displays get, so it's stored as
  /// forgetting the display.
  private func placementChosen(uuid: String, name: String, placement: ClonePlacement) {
    if placement == .followDock {
      AppConfig.shared.cloneDisplays[uuid] = nil
    } else {
      AppConfig.shared.cloneDisplays[uuid] = CloneDisplay(placement: placement, name: name)
    }
    AppConfig.shared.save()
    NotificationCenter.default.post(name: .appConfigChanged, object: nil)
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
    let ms = Int(sender.doubleValue.rounded()).clamped(0, 500)
    delayLabel.stringValue = "\(ms) ms"
    // Save once the knob is let go, not at every step of a drag.
    guard NSApp.currentEvent?.type != .leftMouseDragged else { return }
    AppConfig.shared.badgeDelayMs = ms
    AppConfig.shared.save()
    NotificationCenter.default.post(name: .appConfigChanged, object: nil)
  }
}

/// Rounded settings group whose fill tracks light/dark appearance.
/// (Resolving a dynamic NSColor to CGColor once would freeze the
/// creation-time appearance — this re-resolves on every change.)
private final class GroupBoxView: NSView {
  private let fill: NSColor

  init(fill: NSColor) {
    self.fill = fill
    super.init(frame: .zero)
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
    // cgColor resolves against the current drawing appearance.
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor = fill.cgColor
    }
  }
}

/// Toolbar tabs in a window of constant size: tall enough for the tallest
/// tab, so switching tabs never resizes it (shorter tabs top-aligned).
final class SettingsTabViewController: NSTabViewController {
  /// Size the window for the tallest tab. Called again when a tab's content
  /// changes height (e.g. the permission banner or an error row comes or goes).
  func fitWindow() {
    guard let window = view.window else { return }
    let pages = tabViewItems.compactMap { $0.viewController?.view }
    for page in pages { page.layoutSubtreeIfNeeded() }
    let needed = CGSize(
      width: pages.map(\.fittingSize.width).max() ?? 0,
      height: pages.map(\.fittingSize.height).max() ?? 0
    )
    let current = window.contentRect(forFrameRect: window.frame).size
    guard needed != current else { return }
    for item in tabViewItems { item.viewController?.preferredContentSize = needed }
    let frame = window.frameRect(forContentRect: CGRect(origin: .zero, size: needed))
    let old = window.frame
    // Keep the top edge in place.
    window.setFrame(CGRect(x: old.minX, y: old.maxY - frame.height, width: frame.width, height: frame.height), display: true)
  }
}
