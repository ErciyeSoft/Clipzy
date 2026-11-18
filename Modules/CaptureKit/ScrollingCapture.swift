import AppKit
import SwiftUI

/// Captures content taller than the screen: scrolls the selected area step by step,
/// grabs it each time and stitches the frames where they overlap.
enum ScrollingCapture {
  private static let maxFrames = 60
  private static let maxHeight = 30_000

  static func run(_ region: SelectedRegion) async -> CGImage? {
    let hud = ProgressHUD(text: String(localized: "Scrolling capture… Press Esc or click Stop to finish"))
    hud.show(on: region.screen)
    defer { hud.close() }

    // Scroll events go to the view under the pointer, so put it in the middle of the area.
    let primaryHeight = NSScreen.screens.first?.frame.maxY ?? region.screen.frame.maxY
    CGWarpMouseCursorPosition(CGPoint(x: region.rect.midX, y: primaryHeight - region.rect.midY))

    guard var previous = try? await ScreenGrabber.capture(rect: region.rect, on: region.screen) else { return nil }
    var stitched = StitchedImage(first: previous)
    let step = Int32(max(40, region.rect.height * 0.6))

    for _ in 0..<maxFrames where !hud.isStopped && stitched.height < maxHeight {
      CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -step, wheel2: 0, wheel3: 0)?
        .post(tap: .cghidEventTap)
      try? await Task.sleep(for: .milliseconds(350))
      guard !hud.isStopped,
            let next = try? await ScreenGrabber.capture(rect: region.rect, on: region.screen) else { break }
      guard let shift = FrameMatcher.shift(from: previous, to: next), shift > 2 else { break }
      stitched.append(next, newRows: shift)
      previous = next
    }
    return stitched.render()
  }
}

/// Finds how far content moved up between two frames of the same size.
enum FrameMatcher {
  private static let columns = 64

  /// Rows the content moved, or nil when the frames don't line up (or nothing moved).
  static func shift(from previous: CGImage, to next: CGImage) -> Int? {
    guard previous.width == next.width, previous.height == next.height,
          let a = signatures(previous), let b = signatures(next) else { return nil }
    let height = a.count
    let minOverlap = max(12, height / 10)
    guard height > minOverlap + 2 else { return nil }

    // Nothing moved: the end of the page.
    if difference(a, b, shift: 0, samples: 40) < 1.5 { return 0 }

    // Coarse search over every 4th shift, then refine around the best one.
    var best = (shift: 0, error: Float.greatestFiniteMagnitude)
    for shift in stride(from: 1, through: height - minOverlap, by: 4) {
      let error = difference(a, b, shift: shift, samples: 24)
      if error < best.error { best = (shift, error) }
    }
    var refined = (shift: best.shift, error: Float.greatestFiniteMagnitude)
    for shift in max(1, best.shift - 4)...min(height - minOverlap, best.shift + 4) {
      let error = difference(a, b, shift: shift, samples: 80)
      if error < refined.error { refined = (shift, error) }
    }
    return refined.error < 6 ? refined.shift : nil
  }

  /// Mean absolute difference between rows `shift...` of `a` and rows `0...` of `b`.
  private static func difference(_ a: [[UInt8]], _ b: [[UInt8]], shift: Int, samples: Int) -> Float {
    let overlap = a.count - shift
    guard overlap > 0 else { return .greatestFiniteMagnitude }
    let step = max(1, overlap / samples)
    var total = 0
    var count = 0
    var row = 0
    while row < overlap {
      let rowA = a[row + shift]
      let rowB = b[row]
      for column in 0..<columns {
        total += abs(Int(rowA[column]) - Int(rowB[column]))
      }
      count += columns
      row += step
    }
    return Float(total) / Float(max(1, count))
  }

  /// Each row squeezed to 64 grey values: cheap to compare, robust to tiny rendering noise.
  private static func signatures(_ image: CGImage) -> [[UInt8]]? {
    let height = image.height
    guard let context = CGContext(data: nil, width: columns, height: height, bitsPerComponent: 8,
                                  bytesPerRow: columns, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
    context.interpolationQuality = .medium
    context.draw(image, in: CGRect(x: 0, y: 0, width: columns, height: height))
    guard let data = context.data else { return nil }
    let bytes = data.bindMemory(to: UInt8.self, capacity: columns * height)
    // The bitmap's memory starts with the top row of the image.
    return (0..<height).map { row in
      let start = row * columns
      return Array(UnsafeBufferPointer(start: bytes + start, count: columns))
    }
  }
}

/// Frames collected so far, joined top to bottom.
struct StitchedImage {
  private var pieces: [(image: CGImage, rows: Range<Int>)] = []
  private(set) var height = 0
  private let width: Int

  init(first: CGImage) {
    width = first.width
    pieces = [(first, 0..<first.height)]
    height = first.height
  }

  /// Adds the bottom `newRows` rows of the frame.
  mutating func append(_ frame: CGImage, newRows: Int) {
    let rows = (frame.height - newRows)..<frame.height
    pieces.append((frame, rows))
    height += newRows
  }

  func render() -> CGImage? {
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    var top = 0
    for piece in pieces {
      guard let slice = piece.image.cropping(to: CGRect(x: 0, y: piece.rows.lowerBound, width: width,
                                                        height: piece.rows.count)) else { continue }
      // Core Graphics draws from the bottom-left.
      let y = height - top - piece.rows.count
      context.draw(slice, in: CGRect(x: 0, y: y, width: width, height: piece.rows.count))
      top += piece.rows.count
    }
    return context.makeImage()
  }
}

/// Small floating panel with a status line and a Stop button; Esc also stops.
final class ProgressHUD {
  private var panel: NSPanel?
  private var keyMonitor: Any?
  private(set) var isStopped = false
  private let text: String

  init(text: String) {
    self.text = text
  }

  func show(on screen: NSScreen) {
    let view = HUDView(text: text) { [weak self] in self?.isStopped = true }
    let hosting = NSHostingView(rootView: view)
    let size = hosting.fittingSize
    let panel = NSPanel(contentRect: NSRect(x: screen.frame.midX - size.width / 2,
                                            y: screen.visibleFrame.maxY - size.height - 12,
                                            width: size.width, height: size.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.level = .statusBar
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.contentView = hosting
    panel.orderFrontRegardless()
    self.panel = panel
    keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
      if event.keyCode == 53 {
        MainActor.assumeIsolated { self?.isStopped = true }
      }
    }
  }

  func close() {
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    keyMonitor = nil
    panel?.orderOut(nil)
    panel = nil
  }

  private struct HUDView: View {
    let text: String
    let stop: () -> Void

    var body: some View {
      HStack(spacing: 12) {
        ProgressView().controlSize(.small)
        Text(text).font(.callout.weight(.medium))
        Button("Stop", action: stop)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      .background(.regularMaterial, in: Capsule())
      .fixedSize()
    }
  }
}
