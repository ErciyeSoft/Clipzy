import SwiftUI

/// One drawn piece of the chart.
struct SunSegment {
  let item: DiskItem
  /// 1 is the ring next to the center.
  let ring: Int
  /// Radians, clockwise from 12 o'clock.
  let start: Double
  let end: Double
  let color: Color
}

/// Where the rings of the current folder go, worked out once per folder or tree change.
struct SunburstLayout {
  static let rings = 6
  /// Pieces thinner than this are merged into one gray "smaller objects" piece.
  static let minimumAngle = 0.6 * Double.pi / 180

  private static var lastRevision = 0

  private(set) var segments: [SunSegment] = []
  /// Segment indices for each ring (index 0 is ring 1), in angle order.
  private(set) var byRing: [[Int]] = Array(repeating: [], count: rings)
  /// Bytes the full circle stands for.
  private(set) var total: Int64 = 0
  /// Changes with every new layout, so views can drop state that points into the old one.
  let revision: Int

  init() {
    Self.lastRevision += 1
    revision = Self.lastRevision
  }

  /// Rings for `center`; `extras` (free and hidden space) follow its contents in the first ring.
  init(center: DiskNode, extras: [DiskItem]) {
    self.init()
    total = center.size + extras.reduce(0) { $0 + $1.size }
    guard total > 0 else { return }
    let scale = 2 * Double.pi / Double(total)
    place(center, ring: 1, start: 0, scale: scale, branch: nil)
    var angle = Double(center.size) * scale
    for extra in extras {
      let span = Double(extra.size) * scale
      append(SunSegment(item: extra, ring: 1, start: angle, end: angle + span,
                        color: SunburstPalette.color(for: extra, branch: 0, ring: 1)))
      angle += span
    }
  }

  /// The segment under `angle` in `ring`, if any.
  func segmentIndex(ring: Int, angle: Double) -> Int? {
    guard ring >= 1, ring <= Self.rings else { return nil }
    let indices = byRing[ring - 1]
    // Segments of a ring never overlap and are stored in angle order.
    var low = 0
    var high = indices.count - 1
    while low <= high {
      let middle = (low + high) / 2
      let segment = segments[indices[middle]]
      if angle < segment.start {
        high = middle - 1
      } else if angle >= segment.end {
        low = middle + 1
      } else {
        return indices[middle]
      }
    }
    return nil
  }

  private mutating func append(_ segment: SunSegment) {
    byRing[segment.ring - 1].append(segments.count)
    segments.append(segment)
  }

  /// Lays out the children of `folder` in `ring`, starting at `start`, then their children
  /// one ring further out. Everything below the minimum angle becomes one merged piece.
  private mutating func place(_ folder: DiskNode, ring: Int, start: Double, scale: Double, branch: Int?) {
    var angle = start
    var index = 0
    var placedSize: Int64 = 0
    var placedCount = 0
    folder.forEachItemBySize { item in
      let span = Double(item.size) * scale
      guard span >= Self.minimumAngle else { return false }
      let itemBranch = branch ?? index
      append(SunSegment(item: item, ring: ring, start: angle, end: angle + span,
                        color: SunburstPalette.color(for: item, branch: itemBranch, ring: ring)))
      if ring < Self.rings, let child = item.folder, !child.isPackage {
        place(child, ring: ring + 1, start: angle, scale: scale, branch: itemBranch)
      }
      angle += span
      index += 1
      placedSize += item.size
      placedCount += item.objectCount
      return true
    }
    let restSize = folder.size - placedSize
    let restSpan = Double(restSize) * scale
    guard restSize > 0, restSpan > Self.minimumAngle / 4 else { return }
    let merged = DiskItem.smallObjects(count: max(1, folder.objectCount - placedCount), size: restSize, in: folder)
    append(SunSegment(item: merged, ring: ring, start: angle, end: angle + restSpan,
                      color: SunburstPalette.color(for: merged, branch: branch ?? index, ring: ring)))
  }
}

/// Colors by top-level branch, lighter further out; files paler than folders.
enum SunburstPalette {
  private static let hues: [Double] = [0.58, 0.07, 0.36, 0.79, 0.98, 0.13, 0.48, 0.9, 0.67, 0.25]

  static func color(for item: DiskItem, branch: Int, ring: Int) -> Color {
    let hue = hues[branch % hues.count]
    let depth = Double(ring - 1)
    switch item {
    case .folder:
      return Color(hue: hue, saturation: max(0.28, 0.7 - depth * 0.08), brightness: min(0.97, 0.8 + depth * 0.035))
    case .file:
      return Color(hue: hue, saturation: 0.2, brightness: min(0.93, 0.8 + depth * 0.025))
    case .smallerFiles, .smallObjects:
      return Color.gray.opacity(0.5)
    case .hiddenSpace:
      return Color.gray.opacity(0.34)
    case .freeSpace:
      return Color.gray.opacity(0.14)
    }
  }
}

/// Converts between chart angles and view points for a given view size.
struct SunburstGeometry {
  enum Spot: Equatable {
    case center
    case ring(Int, angle: Double)
    case outside
  }

  let center: CGPoint
  /// Radius of the center disc.
  let hole: CGFloat
  let ringWidth: CGFloat

  init(size: CGSize, rings: Int = SunburstLayout.rings) {
    let radius = max(60, min(size.width, size.height) / 2 - 6)
    center = CGPoint(x: size.width / 2, y: size.height / 2)
    hole = radius * 0.28
    ringWidth = (radius - hole) / CGFloat(rings)
  }

  func path(for segment: SunSegment) -> Path {
    let inner = hole + ringWidth * CGFloat(segment.ring - 1)
    let outer = inner + ringWidth
    // Chart angles start at 12 o'clock; Path angles start at 3 o'clock and grow clockwise
    // on screen because the y axis points down.
    let from = Angle.radians(segment.start - .pi / 2)
    let to = Angle.radians(segment.end - .pi / 2)
    var path = Path()
    path.addArc(center: center, radius: outer, startAngle: from, endAngle: to, clockwise: false)
    path.addArc(center: center, radius: inner, startAngle: to, endAngle: from, clockwise: true)
    path.closeSubpath()
    return path
  }

  var holePath: Path {
    Path(ellipseIn: CGRect(x: center.x - hole, y: center.y - hole, width: hole * 2, height: hole * 2))
  }

  func locate(_ point: CGPoint) -> Spot {
    let dx = Double(point.x - center.x)
    let dy = Double(point.y - center.y)
    let distance = (dx * dx + dy * dy).squareRoot()
    if distance <= Double(hole) { return .center }
    let ring = Int((distance - Double(hole)) / Double(ringWidth)) + 1
    guard ring <= SunburstLayout.rings else { return .outside }
    var angle = atan2(dy, dx) + .pi / 2
    if angle < 0 { angle += 2 * .pi }
    return .ring(ring, angle: angle)
  }
}
