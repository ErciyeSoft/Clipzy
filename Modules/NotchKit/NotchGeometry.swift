import AppKit
import SwiftUI

/// Sizes of the panel. The open size and corner radii follow boring.notch (GPL-3.0).
enum NotchMetrics {
  static let openSize = CGSize(width: 640, height: 190)
  /// Room around the open panel for its shadow.
  static let shadowPadding: CGFloat = 20
  static let windowSize = CGSize(width: openSize.width + 2 * shadowPadding, height: openSize.height + shadowPadding)

  static let closedTopRadius: CGFloat = 6
  static let closedBottomRadius: CGFloat = 14
  static let openTopRadius: CGFloat = 19
  static let openBottomRadius: CGFloat = 24

  /// Width the closed panel grows on each side for now playing, a HUD or the battery.
  static let mediaWing: CGFloat = 34
  static let hudWing: CGFloat = 78
  static let batteryWing: CGFloat = 92
}

/// One screen the panel can live on, with the size of its camera housing.
struct NotchScreen: Equatable {
  let screen: NSScreen
  let displayID: CGDirectDisplayID
  let hasNotch: Bool
  /// The camera housing, or the pill drawn on a screen without one.
  let closedSize: CGSize
  /// Horizontal center of the housing in Cocoa screen coordinates.
  let centerX: CGFloat

  static func == (lhs: NotchScreen, rhs: NotchScreen) -> Bool {
    lhs.displayID == rhs.displayID && lhs.hasNotch == rhs.hasNotch && lhs.closedSize == rhs.closedSize
      && lhs.centerX == rhs.centerX && lhs.screen.frame == rhs.screen.frame
  }

  init(screen: NSScreen) {
    self.screen = screen
    displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
    let left = screen.auxiliaryTopLeftArea ?? .zero
    let right = screen.auxiliaryTopRightArea ?? .zero
    if screen.safeAreaInsets.top > 0, !left.isEmpty, !right.isEmpty, right.minX > left.maxX {
      hasNotch = true
      closedSize = CGSize(width: right.minX - left.maxX, height: screen.safeAreaInsets.top)
      centerX = (left.maxX + right.minX) / 2
    } else {
      hasNotch = false
      let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
      closedSize = CGSize(width: 185, height: max(24, min(menuBar, 40)))
      centerX = screen.frame.midX
    }
  }

  /// The screens that should show a panel for this choice.
  static func screens(for choice: NotchScreenChoice) -> [NotchScreen] {
    let all = NSScreen.screens.map(NotchScreen.init)
    switch choice {
    case .notchScreens:
      return all.filter(\.hasNotch)
    case .mainScreen:
      // The main screen is the one with the menu bar in focus; the first one has the menu bar.
      guard let main = NSScreen.main ?? NSScreen.screens.first else { return [] }
      return [NotchScreen(screen: main)]
    case .allScreens:
      return all
    }
  }

  /// The window frame: the open size plus shadow room, hanging from the top edge.
  var windowFrame: CGRect {
    let size = NotchMetrics.windowSize
    return CGRect(x: centerX - size.width / 2, y: screen.frame.maxY - size.height, width: size.width, height: size.height)
  }

  /// A rect of `size` hanging from the top edge at the notch, in Cocoa screen coordinates.
  func topRect(_ size: CGSize) -> CGRect {
    CGRect(x: centerX - size.width / 2, y: screen.frame.maxY - size.height, width: size.width, height: size.height)
  }
}

/// The notch outline: the top edge runs the full width, curves in at the top corners and
/// rounds off at the bottom, so it melts into the camera housing.
nonisolated struct NotchShape: Shape {
  var topRadius: CGFloat
  var bottomRadius: CGFloat

  var animatableData: AnimatablePair<CGFloat, CGFloat> {
    get { AnimatablePair(topRadius, bottomRadius) }
    set {
      topRadius = newValue.first
      bottomRadius = newValue.second
    }
  }

  func path(in rect: CGRect) -> Path {
    let top = min(topRadius, rect.width / 4)
    let bottom = min(bottomRadius, rect.height / 2, (rect.width - 2 * top) / 2)
    var path = Path()
    path.move(to: CGPoint(x: rect.minX, y: rect.minY))
    path.addQuadCurve(to: CGPoint(x: rect.minX + top, y: rect.minY + top),
                      control: CGPoint(x: rect.minX + top, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
    path.addQuadCurve(to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY),
                      control: CGPoint(x: rect.minX + top, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
    path.addQuadCurve(to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom),
                      control: CGPoint(x: rect.maxX - top, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
    path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                      control: CGPoint(x: rect.maxX - top, y: rect.minY))
    path.closeSubpath()
    return path
  }
}
