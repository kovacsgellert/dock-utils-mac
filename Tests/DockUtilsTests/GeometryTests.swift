import Cocoa
import Testing
@testable import dock_utils

private func item(_ kind: DockItemKind, running: Bool = false, title: String = "") -> DockItem {
  DockItem(kind: kind, title: title, url: nil, isRunning: running, badge: nil, frame: .zero, element: nil)
}

struct DockCloneLayoutTests {
  let screen = CGRect(x: 1000, y: 0, width: 1600, height: 900)
  let items = [item(.app), item(.app), item(.separator), item(.folder), item(.trash)]

  @Test func bottomCloneIsCenteredFlushWithTheEdge() {
    let layout = DockCloneLayout(items: items, prefs: DockPrefs(edge: .bottom, tileSize: 48), screen: screen)
    #expect(abs(layout.frame.midX - screen.midX) <= 0.5)
    #expect(layout.frame.minY == screen.minY)
    #expect(layout.reserved == CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: layout.frame.height))
    #expect(layout.itemRects.count == items.count)
    // Left to right, the separator narrower than an icon slot.
    #expect(zip(layout.itemRects, layout.itemRects.dropFirst()).allSatisfy { $0.maxX <= $1.minX + 0.001 })
    #expect(layout.itemRects[2].width < layout.itemRects[0].width)
  }

  @Test func sideCloneRunsTopToBottom() {
    let layout = DockCloneLayout(items: items, prefs: DockPrefs(edge: .right, tileSize: 48), screen: screen)
    #expect(layout.frame.maxX == screen.maxX)
    #expect(layout.itemRects[0].minY > layout.itemRects[1].minY)
    #expect(layout.reserved.height == screen.height)
  }

  @Test func hiddenCloneLeavesOnePointOnScreen() {
    for edge in [DockEdge.bottom, .left, .right] {
      let layout = DockCloneLayout(items: items, prefs: DockPrefs(edge: edge, tileSize: 48, autohide: true), screen: screen)
      let visible = layout.hiddenFrame.intersection(screen)
      #expect(min(visible.width, visible.height) == 1)
    }
  }

  @Test func placementOverridesTheDocksEdge() {
    let layout = DockCloneLayout(items: items, prefs: DockPrefs(edge: .bottom, tileSize: 48), screen: screen, edge: .left)
    #expect(layout.edge == .left)
    #expect(layout.frame.minX == screen.minX)
  }

  @Test func alignedClonesSitAtTheirEnd() {
    let prefs = DockPrefs(edge: .bottom, tileSize: 48)
    let top = screen.maxY - 25  // below the menu bar
    let bottomStart = DockCloneLayout(items: items, prefs: prefs, screen: screen, align: .start, top: top)
    #expect(bottomStart.frame.minX == screen.minX)
    let bottomEnd = DockCloneLayout(items: items, prefs: prefs, screen: screen, align: .end, top: top)
    #expect(bottomEnd.frame.maxX == screen.maxX)
    let rightStart = DockCloneLayout(items: items, prefs: prefs, screen: screen, edge: .right, align: .start, top: top)
    #expect(rightStart.frame.maxY == top)
    #expect(rightStart.frame.maxX == screen.maxX)
    let leftEnd = DockCloneLayout(items: items, prefs: prefs, screen: screen, edge: .left, align: .end, top: top)
    #expect(leftEnd.frame.minY == screen.minY)
  }

  @Test func topAlignedSideCloneStaysBelowTheMenuBar() {
    let many = Array(repeating: item(.app), count: 100)
    let top = screen.maxY - 25
    let layout = DockCloneLayout(items: many, prefs: DockPrefs(edge: .left, tileSize: 64), screen: screen, align: .start, top: top)
    #expect(layout.frame.maxY == top)
    #expect(layout.frame.minY == screen.minY)
  }

  @Test func longDockIsClampedToTheScreen() {
    let many = Array(repeating: item(.app), count: 100)
    let layout = DockCloneLayout(items: many, prefs: DockPrefs(edge: .bottom, tileSize: 64), screen: screen)
    #expect(layout.frame.width == screen.width)
  }
}

struct DockSnapshotTests {
  @Test func numbersRunningAppsOnlyInDockOrder() {
    let snapshot = DockSnapshot(items: [
      item(.app, running: true, title: "A"),
      item(.app, title: "not running"),
      item(.folder, running: true),
      item(.app, running: true, title: "B"),
    ])
    #expect(snapshot.runningApps.map(\.title) == ["A", "B"])
    #expect(snapshot.runningApps.map(\.index) == [1, 2])
  }
}

@MainActor
struct BadgeOriginTests {
  let icon = CGRect(x: 100, y: 0, width: 48, height: 48)

  @Test func holdBadgesSitTowardTheScreenCenter() {
    let bottom = OverlayManager.badgeOrigin(for: icon, edge: .bottom, dockInnerX: nil, diameter: 28, style: .hold)
    #expect(bottom.y >= icon.maxY)
    let left = OverlayManager.badgeOrigin(for: icon, edge: .left, dockInnerX: nil, diameter: 28, style: .hold)
    #expect(left.x >= icon.maxX)
    let right = OverlayManager.badgeOrigin(for: icon, edge: .right, dockInnerX: nil, diameter: 28, style: .hold)
    #expect(right.x + 28 <= icon.minX)
  }

  @Test func persistentBadgesStayInsideTheDock() {
    let bottom = OverlayManager.badgeOrigin(for: icon, edge: .bottom, dockInnerX: nil, diameter: 20, style: .persistent)
    #expect(icon.contains(CGRect(origin: bottom, size: CGSize(width: 20, height: 20))))
    // On a left Dock: flush against (1 pt inside) the Dock's inner edge.
    let left = OverlayManager.badgeOrigin(for: icon, edge: .left, dockInnerX: 160, diameter: 20, style: .persistent)
    #expect(left.x + 20 == 159)
  }
}

@MainActor
struct WindowClampTests {
  // AX coordinates: top-left origin, y grows downward.
  let screen = CGRect(x: 0, y: 0, width: 1600, height: 900)
  let bottomStrip = CGRect(x: 0, y: 830, width: 1600, height: 70)
  let leftStrip = CGRect(x: 0, y: 0, width: 70, height: 900)

  @Test func zoomedWindowStopsAtTheClone() {
    let zoomed = CGRect(x: 0, y: 25, width: 1600, height: 875)
    let target = WindowGuard.clamped(zoomed, screen: screen, edge: .bottom, strip: bottomStrip)
    #expect(target?.maxY == bottomStrip.minY)
    #expect(target?.minY == zoomed.minY)
  }

  @Test func tilingMarginIsKept() {
    // Sequoia's "tiled windows have margins": 8 pt short of the edge.
    let tiled = CGRect(x: 8, y: 33, width: 784, height: 859)
    let target = WindowGuard.clamped(tiled, screen: screen, edge: .left, strip: leftStrip)
    #expect(target?.minX == leftStrip.maxX + 8)
    #expect(target?.maxX == tiled.maxX)
  }

  @Test func windowsAwayFromTheEdgeAreLeftAlone() {
    let floating = CGRect(x: 200, y: 100, width: 800, height: 760)
    #expect(WindowGuard.clamped(floating, screen: screen, edge: .bottom, strip: bottomStrip) == nil)
  }

  @Test func windowsParkedUnderTheCloneAreLeftAlone() {
    let parked = CGRect(x: 200, y: 840, width: 800, height: 60)
    #expect(WindowGuard.clamped(parked, screen: screen, edge: .bottom, strip: bottomStrip) == nil)
  }
}
