import Cocoa
import ApplicationServices

/// Thin wrappers over the AXUIElement C API.
enum AX {
  static func value(_ el: AXUIElement, _ attr: String) -> AnyObject? {
    var v: AnyObject?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
    return v
  }

  /// Several attributes in one round trip to the app, index-aligned with
  /// `attrs`; nil where an element lacks one.
  static func values(_ el: AXUIElement, _ attrs: [String]) -> [AnyObject?]? {
    var raw: CFArray?
    guard AXUIElementCopyMultipleAttributeValues(el, attrs as CFArray, [], &raw) == .success,
          let list = raw as? [AnyObject], list.count == attrs.count
    else { return nil }
    return list.map { v in
      // A missing attribute comes back as an AXValue wrapping its error.
      if CFGetTypeID(v) == AXValueGetTypeID(), AXValueGetType(v as! AXValue) == .axError { return nil }
      return v
    }
  }

  static func bool(_ v: AnyObject?) -> Bool {
    (v as? NSNumber)?.boolValue == true
  }

  static func bool(_ el: AXUIElement, _ attr: String) -> Bool {
    bool(value(el, attr))
  }

  static func frame(_ el: AXUIElement) -> CGRect? {
    rect(position: value(el, kAXPositionAttribute), size: value(el, kAXSizeAttribute))
  }

  static func rect(position: AnyObject?, size: AnyObject?) -> CGRect? {
    guard let p = point(position), let s = self.size(size) else { return nil }
    return CGRect(origin: p, size: s)
  }

  static func point(_ v: AnyObject?) -> CGPoint? {
    guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var p = CGPoint.zero
    return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
  }

  static func size(_ v: AnyObject?) -> CGSize? {
    guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var s = CGSize.zero
    return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
  }

  @discardableResult
  static func set(_ el: AXUIElement, _ attr: String, _ value: Bool) -> Bool {
    AXUIElementSetAttributeValue(el, attr as CFString, value ? kCFBooleanTrue : kCFBooleanFalse) == .success
  }

  @discardableResult
  static func setPosition(_ el: AXUIElement, _ p: CGPoint) -> Bool {
    var p = p
    guard let v = AXValueCreate(.cgPoint, &p) else { return false }
    return AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, v) == .success
  }

  @discardableResult
  static func setSize(_ el: AXUIElement, _ s: CGSize) -> Bool {
    var s = s
    guard let v = AXValueCreate(.cgSize, &s) else { return false }
    return AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, v) == .success
  }

  /// The app's real windows (role AXWindow), front to back.
  static func windows(pid: pid_t) -> [AXUIElement] {
    let windows = value(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as? [AXUIElement] ?? []
    return windows.filter { value($0, kAXRoleAttribute) as? String == kAXWindowRole }
  }
}
