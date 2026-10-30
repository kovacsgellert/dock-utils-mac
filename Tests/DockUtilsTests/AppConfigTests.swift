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

  @Test func decodesDisplayPlacementsWithTheirNames() {
    let (config, missing) = AppConfig.decode("""
      dock_clones: true
      dock_clones_display_aaaa-1111: left-start  # LG UltraFine
      DOCK_CLONES_DISPLAY_BBBB-2222: off
      dock_clones_display_cccc-3333: sideways
      """)
    #expect(missing)
    #expect(config.cloneDisplays["aaaa-1111"] == CloneDisplay(placement: .edge(.left, .start), name: "LG UltraFine"))
    #expect(config.cloneDisplays["bbbb-2222"] == CloneDisplay(placement: .off))
    // Invalid placements are ignored (the display follows the Dock).
    #expect(config.cloneDisplays["cccc-3333"] == nil)
  }

  @Test func displayPlacementsRoundTrip() {
    var config = AppConfig()
    config.cloneDisplays = [
      "aaaa-1111": CloneDisplay(placement: .edge(.right, .end), name: "Studio Display"),
      "bbbb-2222": CloneDisplay(placement: .off),
    ]
    let text = config.encode(updating: nil)
    #expect(text.contains("\ndock_clones_display_aaaa-1111: right-end  # Studio Display\n"))
    #expect(text.contains("\ndock_clones_display_bbbb-2222: off\n"))
    #expect(AppConfig.decode(text).config == config)
  }

  @Test func updatingDisplaysKeepsCommentsAndDropsForgottenOnes() {
    let existing = """
      dock_clones: true
      dock_clones_display_aaaa-1111: bottom  # work monitor
      dock_clones_display_bbbb-2222: left
      """
    var config = AppConfig()
    config.dockClones = true
    config.cloneDisplays = [
      "aaaa-1111": CloneDisplay(placement: .edge(.bottom, .start), name: "DELL U2720Q"),
      "cccc-3333": CloneDisplay(placement: .off, name: "Sidecar"),
    ]
    let lines = config.encode(updating: existing).components(separatedBy: "\n")
    #expect(lines[1] == "dock_clones_display_aaaa-1111: bottom-start  # work monitor")
    #expect(!lines.contains { $0.hasPrefix("dock_clones_display_bbbb-2222") })
    #expect(lines.contains("dock_clones_display_cccc-3333: off  # Sidecar"))
  }
}

struct ClonePlacementTests {
  @Test func configValuesRoundTrip() {
    let all: [ClonePlacement] = [.followDock, .off] + [DockEdge.bottom, .left, .right].flatMap { edge in
      CloneAlign.allCases.map { ClonePlacement.edge(edge, $0) }
    }
    for placement in all {
      #expect(ClonePlacement(configValue: placement.configValue) == placement)
    }
    #expect(ClonePlacement.edge(.bottom, .center).configValue == "bottom")
    #expect(ClonePlacement(configValue: "Right-End") == .edge(.right, .end))
  }

  @Test func rejectsUnknownValues() {
    for raw in ["", "top", "bottom-middle", "off-start", "follow-end", "left-"] {
      #expect(ClonePlacement(configValue: raw) == nil)
    }
  }
}
