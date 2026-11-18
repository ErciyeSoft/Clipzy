import AppKit
@preconcurrency import ScreenCaptureKit

/// A display frozen at one moment, used by the selection overlay.
struct FrozenScreen {
  let screen: NSScreen
  let image: CGImage

  /// Pixels per point of the frozen image (2 on Retina).
  var scale: CGFloat { CGFloat(image.width) / screen.frame.width }

  /// Converts a rect in global Cocoa points into this image's pixel space (top-left origin).
  func pixelRect(for rect: CGRect) -> CGRect {
    CGRect(
      x: (rect.minX - screen.frame.minX) * scale,
      y: (screen.frame.maxY - rect.maxY) * scale,
      width: rect.width * scale,
      height: rect.height * scale
    ).integral
  }

  func crop(_ rect: CGRect) -> CGImage? {
    image.cropping(to: pixelRect(for: rect).intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)))
  }
}

extension NSScreen {
  var displayID: CGDirectDisplayID? {
    (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
  }

  /// Converts a global Cocoa rect into this display's local points with a top-left origin,
  /// the space ScreenCaptureKit's `sourceRect` uses.
  func displayLocalRect(for rect: CGRect) -> CGRect {
    CGRect(x: rect.minX - frame.minX, y: frame.maxY - rect.maxY, width: rect.width, height: rect.height)
  }
}

enum GrabError: Error {
  case noDisplay
}

/// Screen capture through ScreenCaptureKit, leaving Kitzi's own windows out.
enum ScreenGrabber {
  static func freezeAllScreens() async throws -> [FrozenScreen] {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    var frozen: [FrozenScreen] = []
    for screen in NSScreen.screens {
      guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { continue }
      let image = try await capture(display: display, content: content, screen: screen, sourceRect: nil)
      frozen.append(FrozenScreen(screen: screen, image: image))
    }
    return frozen
  }

  /// Captures part of one screen (global Cocoa points) at full pixel resolution.
  static func capture(rect: CGRect, on screen: NSScreen) async throws -> CGImage {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else {
      throw GrabError.noDisplay
    }
    return try await capture(display: display, content: content, screen: screen,
                             sourceRect: screen.displayLocalRect(for: rect))
  }

  nonisolated static func filterExcludingKitzi(display: SCDisplay, content: SCShareableContent) -> SCContentFilter {
    let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
    return SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
  }

  private static func capture(display: SCDisplay, content: SCShareableContent, screen: NSScreen,
                              sourceRect: CGRect?) async throws -> CGImage {
    let configuration = SCStreamConfiguration()
    let scale = screen.backingScaleFactor
    let size = sourceRect?.size ?? CGSize(width: display.width, height: display.height)
    if let sourceRect {
      configuration.sourceRect = sourceRect
    }
    configuration.width = Int((size.width * scale).rounded())
    configuration.height = Int((size.height * scale).rounded())
    configuration.showsCursor = false
    configuration.captureResolution = .best
    return try await SCScreenshotManager.captureImage(
      contentFilter: filterExcludingKitzi(display: display, content: content),
      configuration: configuration
    )
  }

  /// On-screen windows of other apps, front to back, in global Cocoa coordinates.
  static func visibleWindowFrames() -> [CGRect] {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
      as? [[String: Any]] ?? []
    let ownPID = ProcessInfo.processInfo.processIdentifier
    let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
    return list.compactMap { info in
      guard (info[kCGWindowLayer as String] as? Int) == 0,
            (info[kCGWindowOwnerPID as String] as? pid_t) != ownPID,
            (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
            let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
            let width = bounds["Width"], let height = bounds["Height"], width > 40, height > 40 else {
        return nil
      }
      let x = bounds["X"] ?? 0
      let y = bounds["Y"] ?? 0
      return CGRect(x: x, y: primaryHeight - y - height, width: width, height: height)
    }
  }
}
