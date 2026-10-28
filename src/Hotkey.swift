import Cocoa
import ApplicationServices

/// Global Option-hold detection + number-key interception via CGEventTap.
/// "Held" means Option alone; adding Cmd/Ctrl/Shift counts as a release.
/// Requires Accessibility permission. The tap runs on the main run loop.
@MainActor
final class HotkeyManager {
  var onOptionDown: (() -> Void)?
  var onOptionUp: (() -> Void)?
  var onNumber: ((Int) -> Void)? // 0-9 as pressed (0 = 10th)
  /// Whether a number has an app to switch to. Others reach the frontmost
  /// app, so Option+digit still types `[`, `|`, `{` etc. on layouts that
  /// put them there. Called from the tap, on the main thread.
  var handlesNumber: ((Int) -> Bool)?

  private var tap: CFMachPort?
  private var src: CFRunLoopSource?
  private var optionHeld = false

  var isRunning: Bool { tap != nil }
  var isOptionHeld: Bool { optionHeld }

  // ANSI keycodes for 1..0
  private static let numberKeycodes: [Int64: Int] = [
    18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9, 29: 0
  ]

  /// Option with no Cmd/Ctrl/Shift, so combos like Option+Cmd+Ctrl+4 reach
  /// other apps. Fn is ignored: some keyboards set it spuriously.
  private static func isOptionOnly(_ flags: CGEventFlags) -> Bool {
    flags.contains(.maskAlternate) &&
      flags.intersection([.maskCommand, .maskControl, .maskShift]).isEmpty
  }

  func start() -> Bool {
    guard tap == nil else { return true }
    let mask: CGEventMask =
      (1 << CGEventType.keyDown.rawValue) |
      (1 << CGEventType.flagsChanged.rawValue)
    guard let t = CGEvent.tapCreate(
      tap: .cgSessionEventTap,
      place: .headInsertEventTap,
      options: .defaultTap,
      eventsOfInterest: mask,
      callback: tapCallback,
      userInfo: Unmanaged.passUnretained(self).toOpaque()
    ) else { return false }
    tap = t
    src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
    CGEvent.tapEnable(tap: t, enable: true)
    return true
  }

  fileprivate func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
    let pass = Unmanaged.passUnretained(event)
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
      if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
      return pass
    case .flagsChanged:
      let down = Self.isOptionOnly(event.flags)
      if down != optionHeld {
        optionHeld = down
        DispatchQueue.main.async { [weak self] in
          down ? self?.onOptionDown?() : self?.onOptionUp?()
        }
      }
      return pass
    case .keyDown:
      guard optionHeld, Self.isOptionOnly(event.flags) else { return pass }
      let code = event.getIntegerValueField(.keyboardEventKeycode)
      guard let number = Self.numberKeycodes[code], handlesNumber?(number) ?? true else { return pass }
      // Swallow the press so Option+2 doesn't type ™ etc.; swallow
      // auto-repeat too, without acting on it, so holding the key doesn't
      // cycle windows or flip the app between hidden and shown.
      if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
        DispatchQueue.main.async { [weak self] in self?.onNumber?(number) }
      }
      return nil
    default:
      return pass
    }
  }
}

private func tapCallback(
  proxy: CGEventTapProxy,
  type: CGEventType,
  event: CGEvent,
  refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
  guard let refcon else { return Unmanaged.passUnretained(event) }
  // The tap's run loop source is on the main run loop (see start()).
  return MainActor.assumeIsolated {
    Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
      .handle(proxy: proxy, type: type, event: event)
  }
}
