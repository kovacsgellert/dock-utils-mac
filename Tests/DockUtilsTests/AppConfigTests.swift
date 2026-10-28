import Testing
@testable import dock_utils

struct AppConfigTests {
  @Test func decodesEveryKey() {
    let (config, missing) = AppConfig.decode("""
      start_at_login: yes
      show_menu_bar_icon: off
      appearance: Dark  # system | light | dark
      badge_delay_ms: 250
      badges_always_visible: 1
      dock_clones: true
      dock_clones_keep_windows_clear: false
      """)
    #expect(!missing)
    #expect(config.startAtLogin)
    #expect(!config.showMenuBarIcon)
    #expect(config.appearance == .dark)
    #expect(config.badgeDelayMs == 250)
    #expect(config.badgesAlwaysVisible)
    #expect(config.dockClones)
    #expect(!config.dockClonesKeepWindowsClear)
  }

  @Test func reportsMissingKeysAndKeepsDefaults() {
    let (config, missing) = AppConfig.decode("dock_clones: true\n")
    #expect(missing)
    #expect(config.dockClones)
    #expect(config.badgeDelayMs == AppConfig().badgeDelayMs)
  }

  @Test func invalidValuesKeepDefaults() {
    let (config, _) = AppConfig.decode("""
      appearance: purple
      badge_delay_ms: soon
      show_menu_bar_icon: maybe
      """)
    #expect(config == AppConfig())
  }

  @Test func clampsBadgeDelay() {
    #expect(AppConfig.decode("badge_delay_ms: 9000").config.badgeDelayMs == 500)
    #expect(AppConfig.decode("badge_delay_ms: -5").config.badgeDelayMs == 0)
  }

  @Test func newFileListsEverySettingAndRoundTrips() {
    var config = AppConfig()
    config.dockClones = true
    config.badgeDelayMs = 175
    let text = config.encode(updating: nil)
    for key in AppConfig.keys {
      #expect(text.contains("\n\(key.name): "))
    }
    let (decoded, missing) = AppConfig.decode(text)
    #expect(!missing)
    #expect(decoded == config)
  }

  @Test func updatingKeepsCommentsOrderAndUnknownLines() {
    let existing = """
      # my dotfiles: DockUtils
      dock_clones: false   # off at work

      badge_delay_ms: 100
      some_future_key: 3
      """
    var config = AppConfig()
    config.dockClones = true
    config.badgeDelayMs = 300
    let lines = config.encode(updating: existing).components(separatedBy: "\n")
    #expect(lines[0] == "# my dotfiles: DockUtils")
    #expect(lines[1] == "dock_clones: true   # off at work")
    #expect(lines[2] == "")
    #expect(lines[3] == "badge_delay_ms: 300")
    #expect(lines[4] == "some_future_key: 3")
    // Settings the file lacked are appended, once each.
    #expect(lines.filter { $0.hasPrefix("start_at_login:") }.count == 1)
    #expect(lines.filter { $0.hasPrefix("dock_clones:") }.count == 1)
  }
}
