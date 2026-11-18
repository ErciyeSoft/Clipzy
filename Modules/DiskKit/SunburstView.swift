import AppKit
import SwiftUI

/// The ring chart of the current folder. Hover shows a piece's name and size in the center,
/// a click on a folder opens it, a click on the center goes up. Pieces can be dragged to
/// the collector.
struct SunburstView: View {
  let model: DiskAnalyzerModel
  @State private var hover = Hover.none

  enum Hover: Equatable {
    case none
    case center
    case segment(Int)
  }

  var body: some View {
    GeometryReader { proxy in
      let geometry = SunburstGeometry(size: proxy.size)
      let layout = model.layout
      let hovered = hoveredSegment(in: layout)
      let selection = model.selection
      ZStack {
        Canvas { context, _ in
          draw(in: &context, layout: layout, geometry: geometry, hovered: hovered, selection: selection)
        }
        centerLabel(hovered: hovered.map { layout.segments[$0] }, total: layout.total)
          .frame(width: geometry.hole * 1.6, height: geometry.hole * 1.6)
          .position(geometry.center)
          .allowsHitTesting(false)
      }
      .contentShape(Rectangle())
      .onContinuousHover { phase in
        let next: Hover
        switch phase {
        case .active(let point): next = spot(at: point, geometry: geometry, layout: layout)
        case .ended: next = .none
        }
        if next != hover { hover = next }
      }
      .gesture(SpatialTapGesture().onEnded { value in
        tap(spot(at: value.location, geometry: geometry, layout: layout), layout: layout)
      })
      .onDrag { model.dragProvider(for: hovered.map { layout.segments[$0].item }) }
    }
    .overlay(alignment: .bottom) {
      caption
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 420)
        .allowsHitTesting(false)
    }
    .onChange(of: model.layout.revision) { hover = .none }
  }

  /// What the hovered gray piece means, or how to use the chart.
  @ViewBuilder
  private var caption: some View {
    if let index = hoveredSegment(in: model.layout),
       let note = Self.explanation(for: model.layout.segments[index].item) {
      Text(note)
    } else if hover == .none {
      Text("Click a folder to open it, the center to go up. Drag pieces to the collector.")
        .opacity(0.7)
    }
  }

  private func hoveredSegment(in layout: SunburstLayout) -> Int? {
    if case .segment(let index) = hover, index < layout.segments.count { return index }
    return nil
  }

  private func spot(at point: CGPoint, geometry: SunburstGeometry, layout: SunburstLayout) -> Hover {
    switch geometry.locate(point) {
    case .center: .center
    case .ring(let ring, let angle): layout.segmentIndex(ring: ring, angle: angle).map(Hover.segment) ?? .none
    case .outside: .none
    }
  }

  private func tap(_ spot: Hover, layout: SunburstLayout) {
    switch spot {
    case .center:
      model.goUp()
    case .segment(let index):
      let item = layout.segments[index].item
      switch item {
      case .folder(let node):
        model.open(node)
      case .file(_, let parent), .smallerFiles(let parent):
        model.open(parent)
        model.selection = [item.id]
      case .smallObjects(_, _, let parent):
        model.open(parent)
      case .freeSpace, .hiddenSpace:
        break
      }
    case .none:
      break
    }
  }

  // MARK: Drawing

  private func draw(
    in context: inout GraphicsContext, layout: SunburstLayout, geometry: SunburstGeometry,
    hovered: Int?, selection: Set<DiskItem.ID>
  ) {
    let separator = Color(nsColor: .windowBackgroundColor)
    context.fill(geometry.holePath, with: .color(Color.secondary.opacity(hover == .center ? 0.18 : 0.08)))
    for (index, segment) in layout.segments.enumerated() {
      let path = geometry.path(for: segment)
      context.fill(path, with: .color(segment.color))
      if index == hovered {
        context.fill(path, with: .color(.white.opacity(0.3)))
      }
      context.stroke(path, with: .color(separator), lineWidth: 0.75)
    }
    if !selection.isEmpty {
      for segment in layout.segments where selection.contains(segment.item.id) {
        context.stroke(geometry.path(for: segment), with: .color(.primary), lineWidth: 2)
      }
    }
  }

  @ViewBuilder
  private func centerLabel(hovered: SunSegment?, total: Int64) -> some View {
    VStack(spacing: 3) {
      if let item = hovered?.item {
        Text(item.name)
          .font(.headline)
          .lineLimit(2)
          .truncationMode(.middle)
        Text(DiskFormat.bytes(item.size))
          .font(.title3)
          .monospacedDigit()
        if total > 0 {
          Text(DiskFormat.percent(Double(item.size) / Double(total)))
            .foregroundStyle(.secondary)
        }
      } else if let current = model.current {
        Text(current.name)
          .font(.headline)
          .lineLimit(2)
          .truncationMode(.middle)
        Text(DiskFormat.bytes(current.size))
          .font(.title3)
          .monospacedDigit()
        if hover == .center, current.parent != nil {
          Label("Up", systemImage: "arrow.up")
            .foregroundStyle(.secondary)
        } else {
          Text("\(current.fileCount.formatted()) files")
            .foregroundStyle(.secondary)
        }
      }
    }
    .multilineTextAlignment(.center)
    .minimumScaleFactor(0.7)
  }

  static func explanation(for item: DiskItem) -> String? {
    switch item {
    case .hiddenSpace:
      String(localized: "Used space the scan couldn't see: system files, snapshots, other volumes and folders without access.")
    case .freeSpace:
      String(localized: "Free space on this disk.")
    case .smallObjects:
      String(localized: "Too small to draw one by one. Click to open the folder they're in.")
    case .smallerFiles:
      String(localized: "This folder's smaller files, counted together to save memory.")
    default:
      nil
    }
  }
}
