import Foundation

/// Portable settings in ~/.config/dock-utils/config.yml (XDG-style).
/// Hand- and script-editable; the app applies them at launch and whenever
/// the file changes. No third-party YAML dependency: the format is flat
/// `key: value` pairs, parsed below.
struct AppConfig: Equatable {
  var startAtLogin = false
  var showMenuBarIcon = true
  var appearance = AppAppearance.system
  /// Badge show delay in milliseconds, clamped to 0...500.
  var badgeDelayMs = 100
  /// Persistent mini-badges on Dock icons (no Option hold needed).
  var badgesAlwaysVisible = false
  /// Show a clone of the Dock on every display the real Dock isn't on.
  var dockClones = false
  /// Shrink zoomed/tiled windows out of the clones' area.
  var dockClonesKeepWindowsClear = true

  /// Every setting as it appears in the file, in file order. Adding a
  /// setting means adding a property above and a line here.
  static let keys: [Key] = [
    .bool("start_at_login", \.startAtLogin),
    .bool("show_menu_bar_icon", \.showMenuBarIcon),
    Key("appearance", comment: "system | light | dark",
        read: { c, raw in AppAppearance(rawValue: raw.lowercased()).map { c.appearance = $0 } != nil },
        write: { $0.appearance.rawValue }),
    Key("badge_delay_ms", comment: "0...500",
        read: { c, raw in Int(raw).map { c.badgeDelayMs = $0.clamped(0, 500) } != nil },
        write: { "\($0.badgeDelayMs)" }),
    .bool("badges_always_visible", \.badgesAlwaysVisible, comment: "persistent mini-badges on Dock icons"),
    .bool("dock_clones", \.dockClones, comment: "clone the Dock onto your other displays"),
    .bool("dock_clones_keep_windows_clear", \.dockClonesKeepWindowsClear, comment: "shrink zoomed/tiled windows out of the clones"),
  ]

  struct Key {
    let name: String
    let comment: String?
    /// Applies a raw value; false when it isn't a valid one.
    let read: (inout AppConfig, String) -> Bool
    let write: (AppConfig) -> String

    init(_ name: String, comment: String? = nil, read: @escaping (inout AppConfig, String) -> Bool, write: @escaping (AppConfig) -> String) {
      self.name = name
      self.comment = comment
      self.read = read
      self.write = write
    }

    static func bool(_ name: String, _ path: WritableKeyPath<AppConfig, Bool>, comment: String? = nil) -> Key {
      Key(name, comment: comment,
          read: { c, raw in parseBool(raw).map { c[keyPath: path] = $0 } != nil },
          write: { "\($0[keyPath: path])" })
    }
  }

  /// $XDG_CONFIG_HOME when set (absolute, ~ expanded), else ~/.config.
  /// macOS has no XDG convention natively, but this keeps dotfile-managed
  /// setups and scripts portable across machines.
  private static let configHome: URL = {
    if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"],
       !xdg.trimmingCharacters(in: .whitespaces).isEmpty {
      return URL(fileURLWithPath: (xdg as NSString).expandingTildeInPath, isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config", isDirectory: true)
  }()

  static let fileURL: URL = configHome.appendingPathComponent("dock-utils/config.yml")

  /// Previous location (before the rename from DockShortcuts). Migrated once if the new file is missing.
  private static let legacyFileURL: URL = configHome.appendingPathComponent("dock-shortcuts/config.yml")

  /// Live copy used across the app. Mutate then save(), or reload() from disk.
  @MainActor static var shared = load()

  mutating func reload() {
    self = Self.load()
  }

  // MARK: - Load / save

  static func load() -> AppConfig {
    // One-time rename migration.
    if !FileManager.default.fileExists(atPath: fileURL.path),
       FileManager.default.fileExists(atPath: legacyFileURL.path) {
      try? FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
      )
      try? FileManager.default.copyItem(at: legacyFileURL, to: fileURL)
    }
    guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
      // First run (or deleted file): migrate legacy UserDefaults, then persist.
      var fresh = AppConfig()
      fresh.startAtLogin = LaunchAtLogin.isEnabled
      if let v = UserDefaults.standard.object(forKey: "showMenuBarIcon") as? Bool {
        fresh.showMenuBarIcon = v
      }
      if let raw = UserDefaults.standard.string(forKey: "appearance"),
         let a = AppAppearance(rawValue: raw) {
        fresh.appearance = a
      }
      fresh.save()
      return fresh
    }
    let (config, missingKeys) = decode(text)
    // Older files predate newer keys: backfill once so the file always
    // documents every setting (and hand-editing discovery works).
    if missingKeys {
      config.save()
    }
    return config
  }

  /// Settings from a file's text; `missingKeys` when some aren't in it.
  /// Invalid values keep their defaults (and are logged).
  static func decode(_ text: String) -> (config: AppConfig, missingKeys: Bool) {
    var config = AppConfig()
    var missingKeys = false
    let dict = Dictionary(lines(text).compactMap(\.entry).map { ($0.key, $0.value) }) { first, _ in first }
    for key in keys {
      guard let raw = dict[key.name] else { missingKeys = true; continue }
      if !key.read(&config, raw) {
        NSLog("DockUtils: ignoring invalid \(key.name) in \(fileURL.path): \(raw)")
      }
    }
    return (config, missingKeys)
  }

  func save() {
    let existing = try? String(contentsOf: Self.fileURL, encoding: .utf8)
    do {
      try FileManager.default.createDirectory(
        at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
      )
      try encode(updating: existing).write(to: Self.fileURL, atomically: true, encoding: .utf8)
    } catch {
      NSLog("DockUtils: couldn't save config: \(error)")
    }
  }

  /// The file's text with these settings. An existing file keeps its
  /// comments, blank lines and order: only values change, and missing
  /// settings are added at the end.
  func encode(updating existing: String?) -> String {
    let header = """
      # dock-utils settings — portable, safe to edit by hand or scripts.
      # Changes from the settings window update values in place; comments are kept.

      """
    var out: [String] = []
    var written: Set<String> = []
    for line in Self.lines(existing ?? header) {
      guard let entry = line.entry, !written.contains(entry.key),
            let key = Self.keys.first(where: { $0.name == entry.key })
      else { out.append(line.text); continue }
      written.insert(key.name)
      out.append(String(line.text[..<entry.valueStart]) + key.write(self) + String(line.text[entry.valueEnd...]))
    }
    while out.last?.isEmpty == true { out.removeLast() }
    for key in Self.keys where !written.contains(key.name) {
      out.append("\(key.name): \(key.write(self))" + (key.comment.map { "  # \($0)" } ?? ""))
    }
    return out.joined(separator: "\n") + "\n"
  }

  // MARK: - Minimal flat-YAML parsing

  /// One line of the file and, for a `key: value` line, where its value is.
  private struct Line {
    let text: String
    let entry: (key: String, value: String, valueStart: String.Index, valueEnd: String.Index)?
  }

  private static func lines(_ text: String) -> [Line] {
    text.components(separatedBy: .newlines).map { text in
      let t = text.trimmingCharacters(in: .whitespaces)
      guard !t.isEmpty, !t.hasPrefix("#"), let colon = text.firstIndex(of: ":") else {
        return Line(text: text, entry: nil)
      }
      let key = text[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
      // The value runs from after the colon's spaces to a " #" comment
      // (and the spaces before it) or the end of the line.
      let afterColon = text[text.index(after: colon)...]
      let start = afterColon.firstIndex { $0 != " " && $0 != "\t" } ?? afterColon.endIndex
      var end = afterColon[start...].range(of: " #")?.lowerBound ?? afterColon.endIndex
      while end > start, text[text.index(before: end)] == " " || text[text.index(before: end)] == "\t" {
        end = text.index(before: end)
      }
      return Line(text: text, entry: (key, String(text[start..<end]), start, end))
    }
  }

  private static func parseBool(_ raw: String) -> Bool? {
    switch raw.lowercased() {
    case "true", "yes", "on", "1": return true
    case "false", "no", "off", "0": return false
    default: return nil
    }
  }
}

extension Notification.Name {
  /// Posted when settings change, from the window or by editing config.yml.
  static let appConfigChanged = Notification.Name("dock-utils.configChanged")
  /// Accessibility permission may have been granted or revoked.
  static let accessibilityChanged = Notification.Name("dock-utils.accessibilityChanged")
}
