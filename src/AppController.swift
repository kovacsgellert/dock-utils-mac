import Cocoa
import ApplicationServices

/// The running app: wires the Option-hold shortcuts, always-visible
/// badges, Dock clones and menu-bar item together, and applies settings
/// as they change (from the settings window or by editing config.yml).
@MainActor
final class AppController: NSObject, NSApplicationDelegate {
  private let settings = SettingsWindowController.shared
  private let overlay = OverlayManager()
  private let hotkey = HotkeyManager()
  private let persistent: PersistentBadges
  /// Switch targets while Option is held; nil until resolved.
  private var current: [DockApp]?
  private var pendingShow: DispatchWorkItem?
  /// Kept to remove the item when the user hides it.
  private var statusItem: NSStatusItem?
  private var configWatcher: FileWatcher?
  /// The settings last applied, to tell what an edit changed.
  private var applied = AppConfig.shared

  override init() {
    persistent = PersistentBadges(overlay: overlay, hotkey: hotkey)
    super.init()
  }

  func start(noAccessibility: Bool) {
    // Portable config wins: enforce the desired login-item state (e.g. fresh
    // machine with a copied config.yml) and apply the saved appearance.
    // Never from a dev CLI build: SMAppService would register this
    // throwaway binary (or unregister the real installed app) at login.
    AppConfig.shared.reload()
    applied = AppConfig.shared
    if DockUtils.isAppBundle { LaunchAtLogin.apply(applied.startAtLogin) }
    AppAppearance.apply()
    wireShortcuts()

    let tapStarted = noAccessibility || hotkey.start()
    if tapStarted {
      print("DockUtils daemon running. Hold Option to show numbers, press 1-9/0 to switch. Ctrl+C to quit.")
    } else {
      // Launched on its own (e.g. via Finder) without Accessibility yet:
      // stay alive, prompt, and let the settings window guide the user.
      // The tap starts once the permission arrives (see watchAccessibility).
      AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
      print("WARNING: no Accessibility permission yet — badges disabled until granted.")
    }
    updateStatusItem()
    watchConfig()
    watchAccessibility()
    // First launch shows the settings window (login toggle lives there),
    // as does a launch that still needs Accessibility.
    let launchedKey = "hasLaunchedBefore"
    if !tapStarted || noAccessibility || !UserDefaults.standard.bool(forKey: launchedKey) {
      UserDefaults.standard.set(true, forKey: launchedKey)
      DispatchQueue.main.async { self.settings.show() }
    }
    // Without Accessibility these stay empty until it's granted.
    DockWatcher.shared.start()
    FullscreenSpaces.shared.start()
    DockModel.shared.start()
    persistent.sync()
    DockClones.shared.start()
  }

  func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
    // Launch from Spotlight / click on running app → show settings.
    settings.show()
    return true
  }

  // MARK: - Shortcuts

  private func wireShortcuts() {
    hotkey.onOptionDown = { [weak self] in self?.optionDown() }
    hotkey.onOptionUp = { [weak self] in self?.optionUp() }
    hotkey.handlesNumber = { [weak self] in self?.target($0) != nil }
    hotkey.onNumber = { [weak self] number in
      if let app = self?.target(number) {
        _ = AppActivator.activate(app)
      }
    }
    // Option-click and Option-drag (copying in Finder, duplicating in
    // design apps) aren't shortcuts: no badges over the Dock meanwhile.
    // Global monitors deliver on the main thread.
    NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
      MainActor.assumeIsolated { self?.mouseDown() }
    }
  }

  private func optionDown() {
    // Resolve targets immediately so a fast Option+number still switches.
    // With always-visible minis on screen there is nothing to pop out:
    // only the delayed hold overlay needs painting otherwise.
    let apps = DockReader.runningAppItems()
    current = apps
    guard !AppConfig.shared.badgesAlwaysVisible else { return }
    // Hold-to-show delay, configurable 0...500 ms: quick Option taps
    // (e.g. Option+letter combos) never flash badges.
    let work = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated {
        guard NSEvent.pressedMouseButtons == 0 else { return }
        self?.overlay.show(apps: apps, style: .hold)
      }
    }
    pendingShow = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Double(AppConfig.shared.badgeDelayMs) / 1000, execute: work)
  }

  private func optionUp() {
    pendingShow?.cancel()
    pendingShow = nil
    current = nil
    // Clear a hold overlay if one is up (leaves persistent minis untouched),
    // then restore minis if enabled.
    if overlay.styleShown == .hold {
      overlay.hide()
    }
    persistent.sync()
  }

  private func mouseDown() {
    pendingShow?.cancel()
    pendingShow = nil
    if overlay.styleShown == .hold {
      overlay.hide()
    }
  }

  /// The app a number switches to while Option is held.
  private func target(_ number: Int) -> DockApp? {
    // The tap can ask before optionDown has run (both are on the main
    // thread, but optionDown arrives via the main queue).
    if current == nil { current = DockReader.runningAppItems() }
    let idx = (number == 0) ? 10 : number
    return current?.first { $0.index == idx }
  }

  // MARK: - Settings

  private func watchConfig() {
    // Hand/script edits to config.yml apply the moment the file changes;
    // the settings window posts .appConfigChanged itself.
    configWatcher = FileWatcher(AppConfig.fileURL) { [weak self] in
      AppConfig.shared.reload()
      guard let self, AppConfig.shared != self.applied else { return }
      NotificationCenter.default.post(name: .appConfigChanged, object: nil)
    }
    NotificationCenter.default.observeOnMain(.appConfigChanged) { [weak self] _ in self?.applyConfig() }
  }

  private func applyConfig() {
    let config = AppConfig.shared
    // Dev CLI builds leave login items alone (see start).
    if DockUtils.isAppBundle, config.startAtLogin != applied.startAtLogin {
      LaunchAtLogin.apply(config.startAtLogin)
    }
    AppAppearance.apply()
    updateStatusItem()
    applied = config
  }

  /// Accessibility granted (or revoked): the system announces changes to
  /// the permission list; the trust check lags it slightly.
  private func watchAccessibility() {
    DistributedNotificationCenter.default().observeOnMain(.init("com.apple.accessibility.api")) { [weak self] _ in
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.accessibilityMayHaveChanged() }
    }
    NotificationCenter.default.observeOnMain(NSApplication.didBecomeActiveNotification) { [weak self] _ in
      self?.accessibilityMayHaveChanged()
    }
    // Safety net in case the announcement is missed: a slow retry, only
    // until permission arrives.
    if !AXIsProcessTrusted() {
      Timer.onMain(every: 5.0) { [weak self] timer in
        guard AXIsProcessTrusted() else { return }
        timer.invalidate()
        self?.accessibilityMayHaveChanged()
      }
    }
  }

  private func accessibilityMayHaveChanged() {
    if !hotkey.isRunning, hotkey.start() {
      print("Event tap started — badges enabled.")
    }
    DockWatcher.shared.observeDock()
    DockWatcher.shared.post()
    NotificationCenter.default.post(name: .accessibilityChanged, object: nil)
  }

  // MARK: - Menu bar

  /// Create or remove the menu-bar item to match the setting.
  private func updateStatusItem() {
    if AppConfig.shared.showMenuBarIcon {
      guard statusItem == nil else { return }
      let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
      if let button = item.button {
        button.toolTip = "DockUtils"
        if let url = Bundle.main.url(forResource: "menubar", withExtension: "png"),
           let icon = NSImage(contentsOf: url) {
          icon.isTemplate = true
          icon.size = CGSize(width: 18, height: 18)
          button.image = icon
        } else {
          button.image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: "DockUtils")
        }
      }
      let menu = NSMenu()
      let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      let header = NSMenuItem(
        title: version.map { "DockUtils \($0)" } ?? "DockUtils",
        action: nil, keyEquivalent: ""
      )
      header.isEnabled = false
      menu.addItem(header)
      menu.addItem(.separator())
      let settingsItem = NSMenuItem(title: "Settings…", action: nil, keyEquivalent: "")
      settingsItem.target = settings
      settingsItem.action = #selector(SettingsWindowController.showFromMenu(_:))
      menu.addItem(settingsItem)
      menu.addItem(.separator())
      menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
      item.menu = menu
      statusItem = item
    } else if let item = statusItem {
      NSStatusBar.system.removeStatusItem(item)
      statusItem = nil
    }
  }
}
