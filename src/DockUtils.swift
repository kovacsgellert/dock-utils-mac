import Cocoa
import ApplicationServices

@main
struct DockUtils {
  static func main() {
    // Accessibility calls are synchronous: without a bound, one hung app
    // stalls the main thread (badges, clones, the event tap) for the
    // system's default ~6 s. Applies to every element of this process.
    AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
    let args = CommandLine.arguments
    if args.contains("--daemon") || (args.count == 1 && isAppBundle) {
      runDaemon()
      return
    }
    if args.contains("--list") {
      let apps = DockReader.runningAppItems()
      if apps.isEmpty { print("(no dock apps found)"); return }
      for a in apps {
        let f = a.frame
        print("\(a.index <= 10 ? String(a.index % 10) : "-"): \(a.title) [\(a.bundleIdentifier ?? "-")] frame=\(Int(f.origin.x)),\(Int(f.origin.y)) \(Int(f.width))x\(Int(f.height))")
      }
      print("\nTip: swift run dock-utils --activate <number>")
      return
    }
    if let i = args.firstIndex(of: "--activate"), args.count > i + 1,
       let n = Int(args[i + 1]) {
      let apps = DockReader.runningAppItems()
      // User presses 1-9,0 where 0 = 10th
      let idx = (n == 0) ? 10 : n
      guard let app = apps.first(where: { $0.index == idx }) else {
        print("No app for number \(n)"); exit(1)
      }
      print("Activating \(app.title)...")
      exit(AppActivator.activate(app) ? 0 : 1)
    }
    print("Usage: dock-utils [--list] [--activate <1-9,0>] [--daemon] [--no-accessibility]")
  }

  /// True when running as DockUtils.app rather than a bare binary.
  static var isAppBundle: Bool {
    Bundle.main.bundleURL.pathExtension == "app"
  }

  /// Menu-bar-style daemon: hold Option to badge Dock icons, press a number to switch.
  static func runDaemon() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    // TEMPORARY dev/testing hook: run the full UI without Accessibility
    // (no event tap, no system prompt). Badges are inert in this mode.
    let noAccessibility = CommandLine.arguments.contains("--no-accessibility")
    // Portable config wins: enforce the desired login-item state (e.g. fresh
    // machine with a copied config.yml) and apply the saved appearance.
    // Never from a dev CLI build: SMAppService would register this
    // throwaway binary (or unregister the real installed app) at login.
    AppConfig.shared.reload()
    if isAppBundle { LaunchAtLogin.apply(AppConfig.shared.startAtLogin) }
    AppAppearance.apply()
    let delegate = AppDelegate()
    app.delegate = delegate
    let overlay = OverlayManager()
    let hotkey = HotkeyManager()
    let persistent = PersistentBadges(overlay: overlay, hotkey: hotkey)
    // Switch targets while Option is held; nil until resolved.
    var current: [DockApp]?
    var pendingShow: DispatchWorkItem?
    func target(_ number: Int) -> DockApp? {
      // The tap can ask before onOptionDown has run (both are on the main
      // thread, but onOptionDown arrives via the main queue).
      if current == nil { current = DockReader.runningAppItems() }
      let idx = (number == 0) ? 10 : number
      return current?.first { $0.index == idx }
    }

    hotkey.onOptionDown = {
      // Resolve targets immediately so a fast Option+number still switches.
      // With always-visible minis on screen there is nothing to pop out:
      // only the delayed hold overlay needs painting otherwise.
      let snapshot = DockReader.runningAppItems()
      current = snapshot
      guard !AppConfig.shared.badgesAlwaysVisible else { return }
      // Hold-to-show delay, configurable 0...500 ms: quick Option taps
      // (e.g. Option+letter combos) never flash badges.
      let showDelay = Double(AppConfig.shared.badgeDelayMs) / 1000.0
      let work = DispatchWorkItem { overlay.show(apps: snapshot, style: .hold) }
      pendingShow = work
      DispatchQueue.main.asyncAfter(deadline: .now() + showDelay, execute: work)
    }
    hotkey.onOptionUp = {
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
    hotkey.handlesNumber = { target($0) != nil }
    hotkey.onNumber = { number in
      if let app = target(number) {
        _ = AppActivator.activate(app)
      }
    }

    guard noAccessibility || hotkey.start() else {
      // Launched on its own (e.g. via Finder) without Accessibility yet:
      // stay alive, prompt, and let the settings window guide the user.
      // The tap is retried whenever the app activates (see runChrome).
      AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
      print("WARNING: no Accessibility permission yet — badges disabled until granted.")
      runChrome(settings: SettingsWindowController.shared, hotkey: hotkey, forceSettings: true)
      persistent.sync()
      // Clones appear once Accessibility is granted (until then reads fail).
      DockWatcher.shared.start()
      FullscreenSpaces.shared.start()
      DockClones.shared.start()
      app.run()
      return
    }

    runChrome(settings: SettingsWindowController.shared, hotkey: hotkey, forceSettings: noAccessibility)
    print("DockUtils daemon running. Hold Option to show numbers, press 1-9/0 to switch. Ctrl+C to quit.")
    persistent.sync()
    DockWatcher.shared.start()
    FullscreenSpaces.shared.start()
    DockClones.shared.start()
    app.run()
  }

  /// Retained so the item can be removed when the user hides it (status bar
  /// does not retain items in a way we can reclaim without our own reference).
  static var statusItem: NSStatusItem?
  private static var configWatcher: FileWatcher?

  /// Menu-bar presence (LSUIElement apps have no Dock icon): Settings + Quit,
  /// first-launch window, and event-tap retry once Accessibility is granted.
  static func runChrome(settings: SettingsWindowController, hotkey: HotkeyManager, forceSettings: Bool) {
    updateStatusItem(settings: settings)

    // Hand/script edits to config.yml apply the moment the file changes.
    // Note: `hotkey` is retained by the observer/timer blocks for the app's lifetime.
    var lastApplied = AppConfig.shared
    configWatcher = FileWatcher(AppConfig.fileURL) {
      AppConfig.shared.reload()
      guard AppConfig.shared != lastApplied else { return }
      // Dev CLI builds leave login items alone (see runDaemon).
      if isAppBundle, AppConfig.shared.startAtLogin != lastApplied.startAtLogin {
        LaunchAtLogin.apply(AppConfig.shared.startAtLogin)
      }
      AppAppearance.apply()
      updateStatusItem(settings: settings)
      lastApplied = AppConfig.shared
      NotificationCenter.default.post(name: .appConfigChanged, object: nil)
    }

    // Accessibility granted (or revoked): the system announces changes to
    // the permission list; the trust check lags it slightly.
    func accessibilityMayHaveChanged() {
      if !hotkey.isRunning, hotkey.start() {
        print("Event tap started — badges enabled.")
      }
      DockWatcher.shared.observeDock()
      DockWatcher.shared.post()
      NotificationCenter.default.post(name: .accessibilityChanged, object: nil)
    }
    DistributedNotificationCenter.default().addObserver(
      forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main
    ) { _ in
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { accessibilityMayHaveChanged() }
    }
    NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { _ in accessibilityMayHaveChanged() }
    // Safety net in case the announcement is missed: a slow retry, only
    // until permission arrives.
    if !AXIsProcessTrusted() {
      Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { timer in
        guard AXIsProcessTrusted() else { return }
        timer.invalidate()
        accessibilityMayHaveChanged()
      }
    }

    // First launch shows the settings window (login toggle lives there).
    let launchedKey = "hasLaunchedBefore"
    if forceSettings || !UserDefaults.standard.bool(forKey: launchedKey) {
      UserDefaults.standard.set(true, forKey: launchedKey)
      DispatchQueue.main.async { settings.show() }
    }
  }

  /// Create or remove the menu-bar item to match the user setting.
  /// Called at launch and live from the settings toggle.
  static func updateStatusItem(settings: SettingsWindowController) {
    if ShowMenuBarIcon.isEnabled {
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

private final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    // Launch from Spotlight / click on running app → show settings.
    SettingsWindowController.shared.show()
    return true
  }
}
