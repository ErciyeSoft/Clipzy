import AppKit
import SwiftUI

/// What the toolbar asks its owner (inline selection or editor window) to do.
@MainActor
struct EditorActions {
  var cancel: () -> Void
  var share: (NSView) -> Void
  var recognizeText: () -> Void
  var pin: () -> Void
  var save: () -> Void
  /// "OK": copy to the clipboard and close.
  var done: () -> Void
}

// MARK: - Toolbar

/// Dark toolbar in the style of capture tools like iScreen Shooter: cancel, drawing tools,
/// undo, then share / text / pin / save, and OK. A second row holds colors and sizes.
struct AnnotationToolbar: View {
  @Bindable var document: EditorDocument
  let tools: [AnnotationTool]
  let actions: EditorActions

  @State private var shareAnchor: NSView?

  static let accent = Color(red: 0.89, green: 1.0, blue: 0.42)
  private static let background = Color(white: 0.16).opacity(0.97)
  private static let palette: [Color] = [.red, .orange, .yellow, .green, .blue, .purple, .black, .white]

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 0) {
        iconButton("xmark.circle.fill", String(localized: "Cancel"), tint: Color(white: 0.6), action: actions.cancel)
        separator
        ForEach(tools) { tool in
          toolButton(tool)
        }
        separator
        iconButton("arrow.uturn.backward", String(localized: "Undo"), action: document.undo)
          .disabled(!document.canUndo)
          .opacity(document.canUndo ? 1 : 0.35)
        separator
        iconButton("square.and.arrow.up", String(localized: "Share")) {
          if let shareAnchor { actions.share(shareAnchor) }
        }
        .background(ViewAnchor { shareAnchor = $0 })
        iconButton("text.viewfinder", String(localized: "Recognize Text"), action: actions.recognizeText)
        iconButton("pin", String(localized: "Pin to Screen"), action: actions.pin)
        iconButton("square.and.arrow.down", String(localized: "Save"), tint: Self.accent, action: actions.save)
        separator
        Button(action: actions.done) {
          Text(verbatim: "OK")
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(Self.accent)
            .frame(width: 56, height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(String(localized: "Copy to the clipboard and close"))
      }
      .padding(.horizontal, 4)
      .background(Self.background, in: RoundedRectangle(cornerRadius: 9))

      if let tool = document.tool, tool.hasOptions {
        optionsRow
      }
    }
    .fixedSize()
    .environment(\.colorScheme, .dark)
  }

  private var separator: some View {
    Rectangle().fill(.white.opacity(0.15)).frame(width: 1, height: 24).padding(.horizontal, 3)
  }

  private func toolButton(_ tool: AnnotationTool) -> some View {
    let selected = document.tool == tool
    return Button {
      document.commitText()
      document.tool = tool
    } label: {
      Image(systemName: tool.systemImage)
        .font(.system(size: 16, weight: .regular))
        .foregroundStyle(selected ? Color.black : Color(white: 0.92))
        .frame(width: 40, height: 40)
        .background(selected ? Self.accent : .clear)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(tool.title)
    .accessibilityLabel(tool.title)
  }

  private func iconButton(_ symbol: String, _ label: String, tint: Color = Color(white: 0.92),
                          action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 16))
        .foregroundStyle(tint)
        .frame(width: 40, height: 40)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(label)
    .accessibilityLabel(label)
  }

  private var optionsRow: some View {
    HStack(spacing: 10) {
      ForEach(LineWeight.allCases) { weight in
        Button {
          document.weight = weight
        } label: {
          Circle()
            .fill(document.weight == weight ? Self.accent : Color(white: 0.85))
            .frame(width: 4 + weight.factor * 3, height: 4 + weight.factor * 3)
            .frame(width: 22, height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
      Rectangle().fill(.white.opacity(0.15)).frame(width: 1, height: 18)
      ForEach(Self.palette, id: \.self) { color in
        Button {
          document.color = color
        } label: {
          RoundedRectangle(cornerRadius: 3)
            .fill(color)
            .frame(width: 18, height: 18)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.white.opacity(0.35), lineWidth: 1))
            .padding(2)
            .overlay(RoundedRectangle(cornerRadius: 4)
              .strokeBorder(document.color == color ? Self.accent : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 4)
    .background(Self.background, in: RoundedRectangle(cornerRadius: 9))
  }
}

/// Hands out the AppKit view behind a SwiftUI view, e.g. to anchor the share picker.
struct ViewAnchor: NSViewRepresentable {
  let onCreate: (NSView) -> Void

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    DispatchQueue.main.async { onCreate(view) }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Canvas

/// The image with its marks, taking drawing gestures for the current tool.
/// `scale` is points per image pixel.
struct AnnotationCanvasView: View {
  @Bindable var document: EditorDocument
  let scale: CGFloat

  @FocusState private var textFocused: Bool

  var body: some View {
    let size = CGSize(width: document.pixelSize.width * scale, height: document.pixelSize.height * scale)
    ZStack(alignment: .topLeading) {
      Canvas { context, _ in
        context.scaleBy(x: scale, y: scale)
        AnnotationRenderer.draw(document, extra: document.draft, in: &context)
        if let crop = document.crop {
          var outside = Path(CGRect(origin: .zero, size: document.pixelSize))
          outside.addPath(Path(crop))
          context.fill(outside, with: .color(.black.opacity(0.5)), style: FillStyle(eoFill: true))
          context.stroke(Path(crop), with: .color(.white), style: StrokeStyle(lineWidth: 2 / scale, dash: [6 / scale]))
        }
      }
      .frame(width: size.width, height: size.height)
      .contentShape(Rectangle())
      .gesture(drawingGesture)

      if let entry = document.textEntry {
        TextField("Text", text: Binding(
          get: { document.textEntry?.text ?? "" },
          set: { document.textEntry?.text = $0 }
        ))
        .textFieldStyle(.plain)
        .font(.system(size: max(16, document.lineWidth * 6) * scale, weight: .bold))
        .foregroundStyle(document.color)
        .frame(minWidth: 120)
        .fixedSize()
        .padding(2)
        .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.white.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [3])))
        .offset(x: entry.point.x * scale, y: entry.point.y * scale)
        .focused($textFocused)
        .onAppear { textFocused = true }
        .onSubmit { document.commitText() }
        .onExitCommand { document.textEntry = nil }
      }
    }
    .frame(width: size.width, height: size.height)
  }

  private var drawingGesture: some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { value in
        guard let tool = document.tool else { return }
        let start = pixel(value.startLocation)
        let current = pixel(value.location)
        let rect = CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                          width: abs(current.x - start.x), height: abs(current.y - start.y))
        switch tool {
        case .rectangle: document.draft = mark(.rectangle(rect))
        case .ellipse: document.draft = mark(.ellipse(rect))
        case .line: document.draft = mark(.line(from: start, to: current))
        case .arrow: document.draft = mark(.arrow(from: start, to: current))
        case .mosaic: document.draft = mark(.mosaic(rect))
        case .pencil, .highlighter:
          var points: [CGPoint] = []
          if case let .pencil(existing)? = document.draft?.shape { points = existing }
          if case let .highlighter(existing)? = document.draft?.shape { points = existing }
          if points.isEmpty { points = [start] }
          if let last = points.last, hypot(current.x - last.x, current.y - last.y) >= 1.5 { points.append(current) }
          document.draft = mark(tool == .pencil ? .pencil(points) : .highlighter(points))
        case .eraser:
          document.erase(at: current, radius: max(6, document.lineWidth * 2))
        case .crop:
          document.crop = rect
        case .text, .step:
          break
        }
      }
      .onEnded { value in
        guard let tool = document.tool else { return }
        let point = pixel(value.location)
        switch tool {
        case .text:
          document.commitText()
          document.textEntry = TextEntry(point: point, text: "")
        case .step:
          document.add(mark(.step(at: point, document.nextStepNumber)))
        case .eraser:
          document.endErase()
        case .crop:
          if let crop = document.crop, crop.width < 4 || crop.height < 4 { document.crop = nil }
        default:
          if let draft = document.draft, isMeaningful(draft) { document.add(draft) }
          document.draft = nil
        }
      }
  }

  private func pixel(_ point: CGPoint) -> CGPoint {
    CGPoint(x: point.x / scale, y: point.y / scale)
  }

  private func mark(_ shape: Annotation.Shape) -> Annotation {
    Annotation(shape: shape, color: document.color, lineWidth: document.lineWidth)
  }

  private func isMeaningful(_ annotation: Annotation) -> Bool {
    switch annotation.shape {
    case let .line(from, to), let .arrow(from, to): hypot(to.x - from.x, to.y - from.y) > 4
    case let .rectangle(rect), let .ellipse(rect), let .mosaic(rect): rect.width > 3 && rect.height > 3
    default: true
    }
  }
}

// MARK: - Editor window content

/// Editor window: the toolbar on top, the screenshot fitted below.
struct EditorView: View {
  let document: EditorDocument
  let actions: EditorActions
  let toast: String?

  var body: some View {
    VStack(spacing: 10) {
      AnnotationToolbar(document: document, tools: AnnotationTool.window, actions: actions)
        .padding(.top, 10)
      GeometryReader { proxy in
        let fit = min(proxy.size.width / document.pixelSize.width, proxy.size.height / document.pixelSize.height)
        let scale = min(fit, 1 / (NSScreen.main?.backingScaleFactor ?? 2))
        AnnotationCanvasView(document: document, scale: scale)
          .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .padding([.horizontal, .bottom], 16)
    }
    .background(Color(white: 0.11))
    .overlay(alignment: .bottom) { ToastView(message: toast) }
  }
}

struct ToastView: View {
  let message: String?

  var body: some View {
    Group {
      if let message {
        Text(message)
          .font(.callout.weight(.medium))
          .foregroundStyle(.white)
          .padding(.horizontal, 14)
          .padding(.vertical, 8)
          .background(.black.opacity(0.8), in: Capsule())
          .padding(.bottom, 18)
          .transition(.opacity)
      }
    }
    .animation(.easeInOut(duration: 0.2), value: message)
  }
}
