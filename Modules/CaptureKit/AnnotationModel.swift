import AppKit
import CoreImage
import Observation
import SwiftUI

enum AnnotationTool: String, CaseIterable, Identifiable {
  case rectangle, ellipse, line, arrow, pencil, highlighter, mosaic, step, eraser, text, crop

  var id: String { rawValue }

  /// Tools in the toolbar shown inside a fresh selection (the selection itself is the crop).
  static let inline: [AnnotationTool] = [.rectangle, .ellipse, .line, .arrow, .pencil, .highlighter, .mosaic, .step, .eraser, .text]
  /// Tools in the editor window, which can also crop.
  static let window: [AnnotationTool] = inline + [.crop]

  var systemImage: String {
    switch self {
    case .rectangle: "rectangle"
    case .ellipse: "oval"
    case .line: "line.diagonal"
    case .arrow: "arrow.up.right"
    case .pencil: "pencil"
    case .highlighter: "highlighter"
    case .mosaic: "checkerboard.rectangle"
    case .step: "1.circle"
    case .eraser: "eraser"
    case .text: "textformat"
    case .crop: "crop"
    }
  }

  var title: String {
    switch self {
    case .rectangle: String(localized: "Rectangle")
    case .ellipse: String(localized: "Ellipse")
    case .line: String(localized: "Line")
    case .arrow: String(localized: "Arrow")
    case .pencil: String(localized: "Pencil")
    case .highlighter: String(localized: "Highlighter")
    case .mosaic: String(localized: "Pixelate")
    case .step: String(localized: "Numbered step")
    case .eraser: String(localized: "Eraser")
    case .text: String(localized: "Text")
    case .crop: String(localized: "Crop")
    }
  }

  /// Whether the color and size row is shown for this tool.
  var hasOptions: Bool {
    self != .eraser && self != .mosaic && self != .crop
  }
}

/// One mark drawn on the screenshot, in image pixel coordinates.
struct Annotation: Identifiable {
  enum Shape {
    case rectangle(CGRect)
    case ellipse(CGRect)
    case line(from: CGPoint, to: CGPoint)
    case arrow(from: CGPoint, to: CGPoint)
    case pencil([CGPoint])
    case highlighter([CGPoint])
    case mosaic(CGRect)
    case text(at: CGPoint, String)
    case step(at: CGPoint, Int)
  }

  let id = UUID()
  var shape: Shape
  var color: Color
  var lineWidth: CGFloat

  /// Rough area the mark covers, used by the eraser.
  var bounds: CGRect {
    let pad = lineWidth * 2 + 6
    switch shape {
    case let .rectangle(rect), let .ellipse(rect), let .mosaic(rect):
      return rect.insetBy(dx: -pad, dy: -pad)
    case let .line(from, to), let .arrow(from, to):
      return CGRect(x: min(from.x, to.x), y: min(from.y, to.y), width: abs(to.x - from.x), height: abs(to.y - from.y))
        .insetBy(dx: -pad, dy: -pad)
    case let .pencil(points), let .highlighter(points):
      let xs = points.map(\.x)
      let ys = points.map(\.y)
      guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return .null }
      return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).insetBy(dx: -pad * 2, dy: -pad * 2)
    case let .text(point, string):
      let size = max(16, lineWidth * 6)
      return CGRect(x: point.x, y: point.y, width: CGFloat(string.count) * size * 0.6, height: size * 1.3)
    case let .step(point, _):
      let radius = max(14, lineWidth * 4)
      return CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
    }
  }

  /// Whether the eraser at `point` touches this mark.
  func isHit(by point: CGPoint, radius: CGFloat) -> Bool {
    switch shape {
    case let .line(from, to), let .arrow(from, to):
      return distance(from: point, toSegment: from, to) <= radius + lineWidth
    case let .pencil(points), let .highlighter(points):
      let width = { if case .highlighter = shape { lineWidth * 4 } else { lineWidth } }()
      return zip(points, points.dropFirst()).contains {
        distance(from: point, toSegment: $0, $1) <= radius + width
      } || (points.count == 1 && hypot(points[0].x - point.x, points[0].y - point.y) <= radius + width)
    case let .rectangle(rect), let .ellipse(rect):
      // Only the outline counts, so erasing inside a box leaves it alone.
      let outer = rect.insetBy(dx: -(radius + lineWidth), dy: -(radius + lineWidth))
      let inner = rect.insetBy(dx: radius + lineWidth, dy: radius + lineWidth)
      return outer.contains(point) && (inner.isNull || !inner.contains(point))
    default:
      return bounds.insetBy(dx: -radius, dy: -radius).contains(point)
    }
  }

  private func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = b.x - a.x
    let dy = b.y - a.y
    let lengthSquared = dx * dx + dy * dy
    guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
    let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
    return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
  }
}

enum LineWeight: String, CaseIterable, Identifiable {
  case thin, medium, thick

  var id: String { rawValue }

  var factor: CGFloat {
    switch self {
    case .thin: 1
    case .medium: 2
    case .thick: 3.5
    }
  }
}

/// Text being typed on the image before it becomes a mark.
struct TextEntry {
  var point: CGPoint
  var text: String
}

/// The screenshot being edited: image, marks, undo history and tool state.
@Observable
final class EditorDocument {
  let image: CGImage
  /// Same image, pixelated; drawn inside mosaic marks.
  let pixelated: CGImage

  private(set) var annotations: [Annotation] = []
  private var undoStack: [[Annotation]] = []
  private var redoStack: [[Annotation]] = []
  private var erasing = false

  /// nil until the user picks a tool (the inline selection can still be resized then).
  var tool: AnnotationTool?
  var color: Color = .red
  var weight: LineWeight = .medium
  /// Mark being dragged out, not yet committed.
  var draft: Annotation?
  var crop: CGRect?
  var textEntry: TextEntry?

  init(image: CGImage, tool: AnnotationTool? = nil) {
    self.image = image
    self.pixelated = Self.pixelate(image) ?? image
    self.tool = tool
  }

  var pixelSize: CGSize { CGSize(width: image.width, height: image.height) }

  /// Line width in pixels, scaled with the screenshot so marks look alike on any size.
  var lineWidth: CGFloat {
    let base = max(2, min(pixelSize.width, pixelSize.height) / 300)
    return (base * weight.factor).rounded()
  }

  var nextStepNumber: Int {
    annotations.filter { if case .step = $0.shape { true } else { false } }.count + 1
  }

  var canUndo: Bool { !undoStack.isEmpty }
  var canRedo: Bool { !redoStack.isEmpty }

  func add(_ annotation: Annotation) {
    undoStack.append(annotations)
    redoStack.removeAll()
    annotations.append(annotation)
  }

  func undo() {
    textEntry = nil
    guard let previous = undoStack.popLast() else { return }
    redoStack.append(annotations)
    annotations = previous
  }

  func redo() {
    guard let next = redoStack.popLast() else { return }
    undoStack.append(annotations)
    annotations = next
  }

  /// Removes marks under the eraser; one drag is one undo step.
  func erase(at point: CGPoint, radius: CGFloat) {
    let remaining = annotations.filter { !$0.isHit(by: point, radius: radius) }
    guard remaining.count != annotations.count else { return }
    if !erasing {
      undoStack.append(annotations)
      redoStack.removeAll()
      erasing = true
    }
    annotations = remaining
  }

  func endErase() {
    erasing = false
  }

  func commitText() {
    defer { textEntry = nil }
    guard let entry = textEntry, !entry.text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
    add(Annotation(shape: .text(at: entry.point, entry.text), color: color, lineWidth: lineWidth))
  }

  private static func pixelate(_ image: CGImage) -> CGImage? {
    let input = CIImage(cgImage: image)
    guard let filter = CIFilter(name: "CIPixellate") else { return nil }
    filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
    filter.setValue(max(10, CGFloat(image.width) / 90), forKey: kCIInputScaleKey)
    filter.setValue(CIVector(x: 0, y: 0), forKey: kCIInputCenterKey)
    guard let output = filter.outputImage?.cropped(to: input.extent) else { return nil }
    return CIContext().createCGImage(output, from: input.extent)
  }
}

/// Draws the screenshot with its marks; used on screen and when exporting.
enum AnnotationRenderer {
  static func draw(_ document: EditorDocument, extra: Annotation? = nil, in context: inout GraphicsContext) {
    let bounds = CGRect(origin: .zero, size: document.pixelSize)
    context.draw(Image(decorative: document.image, scale: 1), in: bounds)
    let pixelated = Image(decorative: document.pixelated, scale: 1)
    for annotation in document.annotations + [extra].compactMap({ $0 }) {
      draw(annotation, pixelated: pixelated, imageBounds: bounds, in: &context)
    }
  }

  static func draw(_ annotation: Annotation, pixelated: Image, imageBounds: CGRect, in context: inout GraphicsContext) {
    let width = annotation.lineWidth
    let style = StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
    let color = GraphicsContext.Shading.color(annotation.color)
    switch annotation.shape {
    case let .rectangle(rect):
      context.stroke(Path(roundedRect: rect, cornerRadius: width / 2), with: color, style: style)
    case let .ellipse(rect):
      context.stroke(Path(ellipseIn: rect), with: color, style: style)
    case let .line(from, to):
      var path = Path()
      path.move(to: from)
      path.addLine(to: to)
      context.stroke(path, with: color, style: style)
    case let .arrow(from, to):
      let angle = atan2(to.y - from.y, to.x - from.x)
      let headLength = max(width * 4, 14)
      let shaftEnd = CGPoint(x: to.x - cos(angle) * headLength * 0.8, y: to.y - sin(angle) * headLength * 0.8)
      var shaft = Path()
      shaft.move(to: from)
      shaft.addLine(to: shaftEnd)
      context.stroke(shaft, with: color, style: style)
      var head = Path()
      head.move(to: to)
      head.addLine(to: CGPoint(x: to.x - cos(angle - .pi / 7) * headLength, y: to.y - sin(angle - .pi / 7) * headLength))
      head.addLine(to: CGPoint(x: to.x - cos(angle + .pi / 7) * headLength, y: to.y - sin(angle + .pi / 7) * headLength))
      head.closeSubpath()
      context.fill(head, with: color)
    case let .pencil(points):
      context.stroke(smoothPath(points), with: color, style: style)
    case let .highlighter(points):
      context.drawLayer { layer in
        layer.blendMode = .multiply
        layer.stroke(smoothPath(points), with: .color(annotation.color.opacity(0.4)),
                     style: StrokeStyle(lineWidth: width * 4, lineCap: .round, lineJoin: .round))
      }
    case let .mosaic(rect):
      context.drawLayer { layer in
        layer.clip(to: Path(rect))
        layer.draw(pixelated, in: imageBounds)
      }
    case let .text(point, string):
      let fontSize = max(16, width * 6)
      context.drawLayer { layer in
        layer.addFilter(.shadow(color: .black.opacity(0.55), radius: max(1, width / 2)))
        layer.draw(Text(string).font(.system(size: fontSize, weight: .bold)).foregroundStyle(annotation.color),
                   at: point, anchor: .topLeading)
      }
    case let .step(point, number):
      let radius = max(14, width * 4)
      let circle = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
      context.drawLayer { layer in
        layer.addFilter(.shadow(color: .black.opacity(0.35), radius: 2))
        layer.fill(Path(ellipseIn: circle), with: color)
      }
      context.stroke(Path(ellipseIn: circle), with: .color(.white), lineWidth: max(2, radius / 8))
      context.draw(Text("\(number)").font(.system(size: radius * 1.1, weight: .heavy)).foregroundStyle(.white),
                   at: point, anchor: .center)
    }
  }

  /// A freehand stroke smoothed with quadratic curves through the midpoints.
  private static func smoothPath(_ points: [CGPoint]) -> Path {
    var path = Path()
    guard let first = points.first else { return path }
    path.move(to: first)
    if points.count < 3 {
      points.dropFirst().forEach { path.addLine(to: $0) }
      if points.count == 1 { path.addLine(to: CGPoint(x: first.x + 0.1, y: first.y)) }
      return path
    }
    for index in 1..<(points.count - 1) {
      let mid = CGPoint(x: (points[index].x + points[index + 1].x) / 2, y: (points[index].y + points[index + 1].y) / 2)
      path.addQuadCurve(to: mid, control: points[index])
    }
    path.addLine(to: points[points.count - 1])
    return path
  }

  /// Final image at full resolution, cropped if a crop is set.
  @MainActor
  static func export(_ document: EditorDocument) -> CGImage? {
    document.commitText()
    let size = document.pixelSize
    let renderer = ImageRenderer(content:
      Canvas { context, _ in
        draw(document, in: &context)
      }
      .frame(width: size.width, height: size.height)
    )
    renderer.scale = 1
    guard let full = renderer.cgImage else { return nil }
    guard let crop = document.crop?.integral, crop.width >= 2, crop.height >= 2 else { return full }
    return full.cropping(to: crop.intersection(CGRect(origin: .zero, size: size)))
  }
}
