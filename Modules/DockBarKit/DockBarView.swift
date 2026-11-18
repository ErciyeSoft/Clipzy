import KitziCore
import SwiftUI
import UniformTypeIdentifiers

/// What the dock view asks its controller to do.
@MainActor
struct DockBarActions {
  var open: (DockBarItem) -> Void
  var showInFinder: (DockBarItem) -> Void
  var keepInDock: (DockBarItem) -> Void
  var removeFromDock: (DockBarItem) -> Void
  var hide: (DockBarItem) -> Void
  var quit: (DockBarItem, _ force: Bool) -> Void
  var emptyTrash: () -> Void
  var dropFiles: ([URL], DockBarItem?) -> Void
  var movePinned: (_ id: String, _ before: DockBarItem) -> Void
}

/// Fills the panel and puts the dock against the configured screen edge.
struct DockBarRootView: View {
  let model: DockBarModel
  let actions: DockBarActions
  static let edgeMargin: CGFloat = 6

  var body: some View {
    switch model.edge {
    case .bottom:
      VStack(spacing: 0) {
        Spacer(minLength: 0)
        DockBarView(model: model, actions: actions)
      }
      .padding(.bottom, Self.edgeMargin)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .left:
      HStack(spacing: 0) {
        DockBarView(model: model, actions: actions)
        Spacer(minLength: 0)
      }
      .padding(.leading, Self.edgeMargin)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .right:
      HStack(spacing: 0) {
        Spacer(minLength: 0)
        DockBarView(model: model, actions: actions)
      }
      .padding(.trailing, Self.edgeMargin)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

struct DockBarView: View {
  let model: DockBarModel
  let actions: DockBarActions

  var body: some View {
    let scales = model.scales()
    let layout = model.isHorizontal
      ? AnyLayout(HStackLayout(alignment: .bottom, spacing: model.spacing))
      : AnyLayout(VStackLayout(alignment: model.edge == .left ? .leading : .trailing, spacing: model.spacing))

    layout {
      ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
        DockBarItemView(
          item: item,
          length: model.baseLength(of: item) * scales[index],
          model: model,
          actions: actions
        )
      }
    }
    .padding(model.padding)
    .background(alignment: backgroundAlignment) {
      background
    }
    .animation(.interpolatingSpring(stiffness: 320, damping: 28), value: model.pointer)
    .animation(.easeInOut(duration: 0.2), value: model.items)
  }

  private var backgroundAlignment: Alignment {
    switch model.edge {
    case .bottom: .bottom
    case .left: .leading
    case .right: .trailing
    }
  }

  @ViewBuilder
  private var background: some View {
    let shape = RoundedRectangle(cornerRadius: min(22, model.thickness * 0.32), style: .continuous)
    Group {
      if #available(macOS 26.0, *) {
        Color.clear.glassEffect(.regular, in: shape)
      } else {
        shape.fill(.ultraThinMaterial)
          .overlay(shape.strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
      }
    }
    .frame(
      width: model.isHorizontal ? nil : model.thickness,
      height: model.isHorizontal ? model.thickness : nil
    )
  }
}

struct DockBarItemView: View {
  let item: DockBarItem
  let length: CGFloat
  let model: DockBarModel
  let actions: DockBarActions

  @State private var isDropTarget = false

  var body: some View {
    content
      .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
        model.itemFrames[item.id] = frame
      }
  }

  @ViewBuilder
  private var content: some View {
    switch item.kind {
    case .separator:
      separator
    case .spacer:
      Color.clear
        .frame(width: model.isHorizontal ? length : model.iconSize,
               height: model.isHorizontal ? model.iconSize : length)
    default:
      icon
    }
  }

  private var separator: some View {
    Capsule()
      .fill(.primary.opacity(0.25))
      .frame(width: model.isHorizontal ? 1 : model.iconSize * 0.7,
             height: model.isHorizontal ? model.iconSize * 0.7 : 1)
      .frame(width: model.isHorizontal ? length : model.iconSize,
             height: model.isHorizontal ? model.iconSize : length)
  }

  private var icon: some View {
    Image(nsImage: model.icon(for: item))
      .resizable()
      .interpolation(.high)
      .aspectRatio(contentMode: .fit)
      .frame(width: length, height: length)
      .scaleEffect(isDropTarget ? 1.08 : 1)
      .overlay(alignment: indicatorAlignment) {
        if item.isRunning {
          Circle()
            .fill(.primary.opacity(0.75))
            .frame(width: 4, height: 4)
            .offset(indicatorOffset)
        }
      }
      .overlay(alignment: labelAlignment) {
        if model.hoveredID == item.id {
          label
        }
      }
      .contentShape(Rectangle())
      .onTapGesture { actions.open(item) }
      .contextMenu { menu }
      .onDrag {
        NSItemProvider(object: "kitzi-dock-item:\(item.pinnedID?.uuidString ?? "")" as NSString)
      }
      .onDrop(of: [.fileURL, .plainText], isTargeted: $isDropTarget) { providers in
        handleDrop(providers)
      }
      .accessibilityElement()
      .accessibilityLabel(item.title)
      .accessibilityAddTraits(.isButton)
  }

  /// Name bubble next to the hovered icon, on the side away from the screen edge.
  private var label: some View {
    Text(item.title)
      .font(.system(size: 13, weight: .medium))
      .lineLimit(1)
      .padding(.horizontal, 10)
      .padding(.vertical, 4)
      .background(.regularMaterial, in: Capsule())
      .fixedSize()
      .offset(labelOffset)
      .allowsHitTesting(false)
  }

  /// The bubble is anchored to the icon's edge facing the screen edge, then pushed past the icon.
  private var labelAlignment: Alignment {
    switch model.edge {
    case .bottom: .bottom
    case .left: .leading
    case .right: .trailing
    }
  }

  private var labelOffset: CGSize {
    let distance = length + 10
    switch model.edge {
    case .bottom: return CGSize(width: 0, height: -distance)
    case .left: return CGSize(width: distance, height: 0)
    case .right: return CGSize(width: -distance, height: 0)
    }
  }

  private var indicatorAlignment: Alignment {
    switch model.edge {
    case .bottom: .bottom
    case .left: .leading
    case .right: .trailing
    }
  }

  private var indicatorOffset: CGSize {
    let gap = model.padding * 0.55 + 2
    switch model.edge {
    case .bottom: return CGSize(width: 0, height: gap)
    case .left: return CGSize(width: -gap, height: 0)
    case .right: return CGSize(width: gap, height: 0)
    }
  }

  @ViewBuilder
  private var menu: some View {
    switch item.kind {
    case .trash:
      Button("Open") { actions.open(item) }
      Divider()
      Button("Empty Trash…") { actions.emptyTrash() }
    case .folder, .file:
      Button("Open") { actions.open(item) }
      Button("Show in Finder") { actions.showInFinder(item) }
      Divider()
      Button("Remove from Dock") { actions.removeFromDock(item) }
    default:
      if !item.isRunning {
        Button("Open") { actions.open(item) }
      }
      Button("Show in Finder") { actions.showInFinder(item) }
      if item.pinnedID == nil {
        Button("Keep in Dock") { actions.keepInDock(item) }
      } else {
        Button("Remove from Dock") { actions.removeFromDock(item) }
      }
      if item.isRunning {
        Divider()
        Button("Hide") { actions.hide(item) }
        Button("Quit") { actions.quit(item, false) }
        Button("Force Quit") { actions.quit(item, true) }
      }
    }
  }

  private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
    let target = item
    if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) {
      _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
        guard let url = (object as? NSURL) as URL? else { return }
        Task { @MainActor in actions.dropFiles([url], target) }
      }
      return true
    }
    if let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) {
      _ = provider.loadObject(ofClass: NSString.self) { object, _ in
        guard let text = object as? NSString as String?, text.hasPrefix("kitzi-dock-item:") else { return }
        let id = String(text.dropFirst("kitzi-dock-item:".count))
        guard !id.isEmpty else { return }
        Task { @MainActor in actions.movePinned(id, target) }
      }
      return true
    }
    return false
  }
}
