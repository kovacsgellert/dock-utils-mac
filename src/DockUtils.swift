import Cocoa
import ApplicationServices

@main
@MainActor
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
    if args.contains("--list") || args.contains("--activate") {
      guard AXIsProcessTrusted() else {
        fputs("ERROR: no Accessibility permission. Enable in System Settings > Privacy & Security > Accessibility.\n", stderr)
        exit(1)
      }
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
    // NSApplication holds its delegate weakly: this local keeps the
    // controller alive for as long as app.run() runs.
    let controller = AppController()
    app.delegate = controller
    // TEMPORARY dev/testing hook: run the full UI without Accessibility
    // (no event tap, no system prompt). Badges are inert in this mode.
    controller.start(noAccessibility: CommandLine.arguments.contains("--no-accessibility"))
    app.run()
  }
}
