import AppKit
import Observation
import SwiftUI

enum SelectionPurpose {
  case screenshot, scrolling, recording

  var hint: String {
    switch self {
    case .screenshot:
      String(localized: "Drag to select · Click a window · Enter: whole screen · C: copy color · Esc: cancel")
    case .scrolling:
      String(localized: "Select the part that scrolls · Click a window · Esc: cancel")
    case .recording:
      String(localized: "Select what to record · Click a window · Enter: whole screen · Esc: cancel")
    }
  }
}

/// The area the user picked, in global Cocoa points, with the frozen frame it was picked on.
struct SelectedRegion: @unchecked Sendable {
  let screen: NSScreen
  let rect: CGRect
  let frozen: FrozenScreen?

  var image: CGImage? { frozen?.crop(rect) }
}

/// Which part of the selection a drag grabs.
enum SelectionHandle {
  case move
  case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
}

@Observable
final class SelectionModel {
  enum Phase { case choosing, editing }

  var phase: Phase = .choosing
  var pointer: CGPoint = .zero
  var dragStart: CGPoint?
  var dragCurrent: CGPoint?
  var hoveredWindow: CGRect?
  /// Fixed selection while editing, global Cocoa points.
  var selection: CGRect?
  var document: EditorDocument?
  /// Toolbar frame in the SwiftUI coordinates of the screen showing it.
  var toolbarFrame: CGRect = .zero
  var toast: String?

  var liveSelection: CGRect? {
    guard let dragStart, let dragCurrent else { return nil }
    return CGRect(x: min(dragStart.x, dragCurrent.x), y: min(dragStart.y, dragCurrent.y),
                  width: abs(dragCurrent.x - dragStart.x), height: abs(dragCurrent.y - dragStart.y))
  }

  var highlight: CGRect? {
    if phase == .editing { return selection }
    if let live = liveSelection, live.width >= 2, live.height >= 2 { return live }
    return dragStart == nil ? hoveredWindow : nil
  }

  /// Once a tool is picked the selection stops moving, so marks stay where they were drawn.
  var isLocked: Bool { document?.tool != nil }
}

/// Freezes every screen and lets the user pick an area, a window or a whole screen, with a
/// size readout and a pixel magnifier. For screenshots it then stays open with a toolbar to
/// mark up, copy, save, pin, share or read the text of the selection right where it is.
final class SelectionSession {
  private let frozen: [FrozenScreen]
  private let purpose: SelectionPurpose
  private let model = SelectionModel()
  private var windows: [SelectionWindow] = []
  private var windowFrames: [CGRect] = []
  private var completion: ((SelectedRegion?) -> Void)?
  private var grab: (handle: SelectionHandle, start: CGPoint, original: CGRect)?

  static func run(_ purpose: SelectionPurpose) async -> SelectedRegion? {
    guard let frozen = try? await ScreenGrabber.freezeAllScreens(), !frozen.isEmpty else { return nil }
    let session = SelectionSession(frozen: frozen, purpose: purpose)
    return await withCheckedContinuation { continuation in
      session.start { continuation.resume(returning: $0) }
    }
  }

  private init(frozen: [FrozenScreen], purpose: SelectionPurpose) {
    self.frozen = frozen
    self.purpose = purpose
  }

  private func start(completion: @escaping (SelectedRegion?) -> Void) {
    self.completion = completion
    windowFrames = ScreenGrabber.visibleWindowFrames()
    windows = frozen.map { SelectionWindow(frozen: $0, model: model, purpose: purpose, session: self) }
    NSApp.activate(ignoringOtherApps: true)
    windows.forEach { $0.orderFrontRegardless() }
    let pointer = NSEvent.mouseLocation
    (windows.first { $0.frame.contains(pointer) } ?? windows.first)?.makeKey()
    pointerMoved()
  }

  // MARK: - Routing

  /// Whether a click at `point` (SwiftUI coordinates of `screen`) belongs to the SwiftUI
  /// toolbar or drawing canvas rather than to the selection logic.
  func routesToOverlay(_ point: CGPoint, on screen: FrozenScreen) -> Bool {
    guard model.phase == .editing, let selection = model.selection,
          screen.screen.frame.intersects(selection) else { return false }
    if model.toolbarFrame.insetBy(dx: -2, dy: -2).contains(point) { return true }
    let local = SelectionOverlayView.local(selection, in: screen)
    return model.isLocked && local.contains(point)
  }

  // MARK: - Mouse

  func pointerMoved() {
    let pointer = NSEvent.mouseLocation
    model.pointer = pointer
    if model.phase == .choosing, model.dragStart == nil {
      let hovered = windowFrames.first { $0.contains(pointer) }
      model.hoveredWindow = hovered.map { $0.intersection(screen(containing: pointer).frame) }
    }
    windows.first { $0.frame.contains(pointer) }?.makeKey()
    updateCursor()
  }

  func mouseDown(clickCount: Int) {
    let pointer = NSEvent.mouseLocation
    if model.phase == .editing, let selection = model.selection {
      if clickCount == 2, selection.contains(pointer) {
        done()
        return
      }
      if !model.isLocked, let handle = handle(at: pointer, in: selection) {
        grab = (handle, pointer, selection)
        return
      }
      guard !model.isLocked else { return }
      // A click outside starts a new selection.
      model.phase = .choosing
      model.selection = nil
      model.document = nil
    }
    model.dragStart = pointer
    model.dragCurrent = pointer
  }

  func mouseDragged() {
    let pointer = NSEvent.mouseLocation
    model.pointer = pointer
    if let grab {
      model.selection = adjusted(grab.original, handle: grab.handle, by: CGPoint(x: pointer.x - grab.start.x,
                                                                                 y: pointer.y - grab.start.y))
      return
    }
    guard let start = model.dragStart else { return }
    // A selection stays on the screen where it started.
    let bounds = screen(containing: start).frame
    model.dragCurrent = CGPoint(x: min(max(pointer.x, bounds.minX), bounds.maxX),
                                y: min(max(pointer.y, bounds.minY), bounds.maxY))
  }

  func mouseUp() {
    if grab != nil {
      grab = nil
      if let selection = model.selection { beginEditing(selection) }
      return
    }
    let picked: CGRect?
    if let live = model.liveSelection, live.width >= 4, live.height >= 4 {
      picked = live
    } else if let window = model.hoveredWindow ?? windowFrames.first(where: { $0.contains(model.pointer) }) {
      picked = window.intersection(screen(containing: model.pointer).frame)
    } else {
      picked = nil
    }
    model.dragStart = nil
    model.dragCurrent = nil
    guard let picked else { return }
    if purpose == .screenshot {
      beginEditing(picked)
    } else {
      finish(picked)
    }
  }

  // MARK: - Keys

  func keyDown(_ event: NSEvent) {
    let command = event.modifierFlags.contains(.command)
    switch (event.keyCode, command) {
    case (53, _): // Esc
      if model.document?.textEntry != nil {
        model.document?.textEntry = nil
      } else {
        finish(nil)
      }
    case (36, _), (76, _): // Return, Enter
      if model.phase == .editing {
        done()
      } else {
        let target = model.hoveredWindow ?? screen(containing: model.pointer).frame
        purpose == .screenshot ? beginEditing(target) : finish(target)
      }
    case (8, true) where model.phase == .editing: // ⌘C
      done()
    case (1, true) where model.phase == .editing: // ⌘S
      actions.save()
    case (6, true): // ⌘Z
      model.document?.undo()
    case (8, false) where model.phase == .choosing && purpose == .screenshot: // C
      copyColorUnderPointer()
      finish(nil)
    default:
      break
    }
  }

  // MARK: - Editing

  private func beginEditing(_ rect: CGRect) {
    let frozenScreen = frozenScreen(for: rect)
    let clamped = rect.intersection(frozenScreen.screen.frame)
    guard clamped.width >= 1, clamped.height >= 1, let image = frozenScreen.crop(clamped) else { return }
    let previous = model.document
    let document = EditorDocument(image: image)
    if let previous {
      document.color = previous.color
      document.weight = previous.weight
    }
    model.selection = clamped
    model.document = document
    model.phase = .editing
    updateCursor()
  }

  lazy var actions = EditorActions(
    cancel: { [weak self] in self?.finish(nil) },
    share: { [weak self] view in self?.exportImage().map { CaptureActions.share($0, from: view) } },
    recognizeText: { [weak self] in
      guard let self, let image = exportImage() else { return }
      finish(nil)
      CaptureActions.recognizeText(image)
    },
    pin: { [weak self] in
      guard let self, let image = exportImage(), let selection = model.selection else { return }
      finish(nil)
      CaptureActions.pin(image, frame: selection)
    },
    save: { [weak self] in
      guard let self, let image = exportImage() else { return }
      finish(nil)
      CaptureActions.save(image)
    },
    done: { [weak self] in self?.done() }
  )

  private func done() {
    guard let image = exportImage() else { return }
    finish(nil)
    CaptureActions.copy(image)
  }

  private func exportImage() -> CGImage? {
    model.document.flatMap { AnnotationRenderer.export($0) }
  }

  // MARK: - Geometry

  private func handle(at point: CGPoint, in rect: CGRect) -> SelectionHandle? {
    let tolerance: CGFloat = 8
    let nearLeft = abs(point.x - rect.minX) <= tolerance
    let nearRight = abs(point.x - rect.maxX) <= tolerance
    let nearBottom = abs(point.y - rect.minY) <= tolerance
    let nearTop = abs(point.y - rect.maxY) <= tolerance
    let insideX = point.x > rect.minX - tolerance && point.x < rect.maxX + tolerance
    let insideY = point.y > rect.minY - tolerance && point.y < rect.maxY + tolerance
    switch (nearLeft, nearRight, nearTop, nearBottom) {
    case (true, _, true, _): return .topLeft
    case (_, true, true, _): return .topRight
    case (true, _, _, true): return .bottomLeft
    case (_, true, _, true): return .bottomRight
    case (true, _, _, _) where insideY: return .left
    case (_, true, _, _) where insideY: return .right
    case (_, _, true, _) where insideX: return .top
    case (_, _, _, true) where insideX: return .bottom
    default: return rect.contains(point) ? .move : nil
    }
  }

  /// Applies a drag to the selection (Cocoa coordinates: y grows upwards).
  private func adjusted(_ rect: CGRect, handle: SelectionHandle, by delta: CGPoint) -> CGRect {
    var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
    switch handle {
    case .move:
      let bounds = screen(containing: CGPoint(x: rect.midX, y: rect.midY)).frame
      let dx = min(max(delta.x, bounds.minX - rect.minX), bounds.maxX - rect.maxX)
      let dy = min(max(delta.y, bounds.minY - rect.minY), bounds.maxY - rect.maxY)
      return rect.offsetBy(dx: dx, dy: dy)
    case .topLeft: minX += delta.x; maxY += delta.y
    case .top: maxY += delta.y
    case .topRight: maxX += delta.x; maxY += delta.y
    case .right: maxX += delta.x
    case .bottomRight: maxX += delta.x; minY += delta.y
    case .bottom: minY += delta.y
    case .bottomLeft: minX += delta.x; minY += delta.y
    case .left: minX += delta.x
    }
    return CGRect(x: min(minX, maxX), y: min(minY, maxY), width: max(4, abs(maxX - minX)), height: max(4, abs(maxY - minY)))
  }

  private func updateCursor() {
    let pointer = model.pointer
    guard model.phase == .editing, let selection = model.selection else {
      NSCursor.crosshair.set()
      return
    }
    if model.isLocked {
      (selection.contains(pointer) ? NSCursor.crosshair : NSCursor.arrow).set()
      return
    }
    switch handle(at: pointer, in: selection) {
    case .move: NSCursor.openHand.set()
    case .left, .right: NSCursor.resizeLeftRight.set()
    case .top, .bottom: NSCursor.resizeUpDown.set()
    case .topLeft, .bottomRight, .topRight, .bottomLeft: NSCursor.crosshair.set()
    case nil: NSCursor.crosshair.set()
    }
  }

  private func screen(containing point: CGPoint) -> NSScreen {
    frozen.first { NSMouseInRect(point, $0.screen.frame, false) }?.screen ?? frozen[0].screen
  }

  private func frozenScreen(for rect: CGRect) -> FrozenScreen {
    frozen.max { lhs, rhs in
      area(lhs.screen.frame.intersection(rect)) < area(rhs.screen.frame.intersection(rect))
    } ?? frozen[0]
  }

  private func area(_ rect: CGRect) -> CGFloat {
    rect.isNull ? 0 : rect.width * rect.height
  }

  private func copyColorUnderPointer() {
    guard let screen = frozen.first(where: { NSMouseInRect(model.pointer, $0.screen.frame, false) }),
          let hex = SelectionOverlayView.hexColor(in: screen, at: model.pointer) else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(hex, forType: .string)
  }

  private func finish(_ rect: CGRect?) {
    windows.forEach { $0.orderOut(nil) }
    windows.removeAll()
    NSCursor.arrow.set()
    let completion = self.completion
    self.completion = nil
    guard let rect, rect.width >= 1, rect.height >= 1 else {
      completion?(nil)
      return
    }
    let frozenScreen = frozenScreen(for: rect)
    completion?(SelectedRegion(screen: frozenScreen.screen, rect: rect.intersection(frozenScreen.screen.frame),
                               frozen: frozenScreen))
  }
}

// MARK: - Windows

final class SelectionWindow: NSWindow {
  init(frozen: FrozenScreen, model: SelectionModel, purpose: SelectionPurpose, session: SelectionSession) {
    super.init(contentRect: frozen.screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
    // Above the Dock and menu bar, but below menus so the share picker can open on top.
    level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
    isOpaque = true
    backgroundColor = .black
    hasShadow = false
    acceptsMouseMovedEvents = true
    isReleasedWhenClosed = false
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

    let input = SelectionInputView(frame: NSRect(origin: .zero, size: frozen.screen.frame.size))
    input.session = session
    input.frozen = frozen
    let overlay = NSHostingView(rootView: SelectionOverlayView(
      frozen: frozen, model: model, purpose: purpose, actions: session.actions
    ))
    overlay.frame = input.bounds
    overlay.autoresizingMask = [.width, .height]
    input.addSubview(overlay)
    input.overlay = overlay
    contentView = input
    setFrame(frozen.screen.frame, display: false)
  }

  override var canBecomeKey: Bool { true }
}

/// Takes mouse and key input for the selection; clicks on the toolbar and, once a tool is
/// picked, on the selection go to the SwiftUI overlay instead.
final class SelectionInputView: NSView {
  weak var session: SelectionSession?
  weak var overlay: NSView?
  var frozen: FrozenScreen?

  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func viewDidMoveToWindow() { window?.makeFirstResponder(self) }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard frame.contains(point) else { return nil }
    let local = convert(point, from: superview)
    let swiftUIPoint = CGPoint(x: local.x, y: bounds.height - local.y)
    if let frozen, let overlay, session?.routesToOverlay(swiftUIPoint, on: frozen) == true {
      return overlay.hitTest(local) ?? self
    }
    return self
  }

  override func mouseMoved(with event: NSEvent) { session?.pointerMoved() }
  override func mouseDown(with event: NSEvent) { session?.mouseDown(clickCount: event.clickCount) }
  override func mouseDragged(with event: NSEvent) { session?.mouseDragged() }
  override func mouseUp(with event: NSEvent) { session?.mouseUp() }
  override func rightMouseDown(with event: NSEvent) { session?.keyDown(Self.escape) }
  override func keyDown(with event: NSEvent) { session?.keyDown(event) }

  private static let escape = NSEvent.keyEvent(
    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
    characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
  )!
}

// MARK: - Overlay

struct SelectionOverlayView: View {
  let frozen: FrozenScreen
  let model: SelectionModel
  let purpose: SelectionPurpose
  let actions: EditorActions

  static let borderColor = Color(red: 0.18, green: 0.5, blue: 0.98)
  private static let loupePixels = 15
  private static let loupeZoom: CGFloat = 8

  var body: some View {
    let size = frozen.screen.frame.size
    let highlight = model.highlight.flatMap { rect -> CGRect? in
      frozen.screen.frame.intersects(rect) ? Self.local(rect, in: frozen) : nil
    }
    ZStack(alignment: .topLeading) {
      Image(decorative: frozen.image, scale: frozen.scale)
        .resizable()
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)

      Canvas { context, canvasSize in
        var dim = Path(CGRect(origin: .zero, size: canvasSize))
        if let highlight { dim.addPath(Path(highlight)) }
        context.fill(dim, with: .color(.black.opacity(0.4)), style: FillStyle(eoFill: true))
      }
      .frame(width: size.width, height: size.height)
      .allowsHitTesting(false)

      if model.phase == .editing, let highlight, let document = model.document {
        AnnotationCanvasView(document: document, scale: 1 / frozen.scale)
          .offset(x: highlight.minX, y: highlight.minY)
      }

      if let highlight {
        selectionFrame(highlight)
          .allowsHitTesting(false)
        sizeLabel(for: highlight)
          .allowsHitTesting(false)
      }

      if model.phase == .editing, let highlight, let document = model.document {
        toolbar(document: document, below: highlight, screenSize: size)
      }

      if model.phase == .choosing, frozen.screen.frame.contains(model.pointer) {
        hintBar
          .frame(width: size.width)
          .padding(.top, 40)
          .allowsHitTesting(false)
        loupe
          .allowsHitTesting(false)
      }
    }
    .frame(width: size.width, height: size.height, alignment: .topLeading)
  }

  /// Global Cocoa rect → a screen's SwiftUI coordinates (top-left origin).
  static func local(_ rect: CGRect, in frozen: FrozenScreen) -> CGRect {
    let frame = frozen.screen.frame
    return CGRect(x: rect.minX - frame.minX, y: frame.maxY - rect.maxY, width: rect.width, height: rect.height)
  }

  // MARK: Selection frame

  private func selectionFrame(_ rect: CGRect) -> some View {
    let showHandles = model.phase == .editing && !model.isLocked
    return ZStack(alignment: .topLeading) {
      Rectangle()
        .strokeBorder(Self.borderColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
        .frame(width: rect.width, height: rect.height)
        .offset(x: rect.minX, y: rect.minY)
      if showHandles {
        ForEach(Array(handlePoints(rect).enumerated()), id: \.offset) { _, handle in
          handleShape(horizontal: handle.horizontal, corner: handle.corner)
            .position(handle.point)
        }
      }
    }
  }

  private func handlePoints(_ r: CGRect) -> [(point: CGPoint, corner: Bool, horizontal: Bool)] {
    [
      (CGPoint(x: r.minX, y: r.minY), true, true), (CGPoint(x: r.maxX, y: r.minY), true, true),
      (CGPoint(x: r.minX, y: r.maxY), true, true), (CGPoint(x: r.maxX, y: r.maxY), true, true),
      (CGPoint(x: r.midX, y: r.minY), false, true), (CGPoint(x: r.midX, y: r.maxY), false, true),
      (CGPoint(x: r.minX, y: r.midY), false, false), (CGPoint(x: r.maxX, y: r.midY), false, false),
    ]
  }

  @ViewBuilder
  private func handleShape(horizontal: Bool, corner: Bool) -> some View {
    if corner {
      Circle().fill(.white).frame(width: 11, height: 11)
        .overlay(Circle().strokeBorder(Self.borderColor, lineWidth: 1.5))
    } else {
      Capsule().fill(.white).frame(width: horizontal ? 24 : 9, height: horizontal ? 9 : 24)
        .overlay(Capsule().strokeBorder(Self.borderColor, lineWidth: 1.5))
    }
  }

  private func sizeLabel(for rect: CGRect) -> some View {
    let text = "\(Int((rect.width * frozen.scale).rounded())) × \(Int((rect.height * frozen.scale).rounded()))"
    let above = rect.minY > 30
    return Text(text)
      .font(.system(size: 12, weight: .semibold).monospacedDigit())
      .foregroundStyle(.white)
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 5))
      .fixedSize()
      .offset(x: rect.minX, y: above ? rect.minY - 26 : rect.minY + 6)
  }

  // MARK: Toolbar

  private func toolbar(document: EditorDocument, below rect: CGRect, screenSize: CGSize) -> some View {
    let size = model.toolbarFrame.size == .zero ? CGSize(width: 620, height: 44) : model.toolbarFrame.size
    let x = min(max(8, rect.minX), screenSize.width - size.width - 8)
    var y = rect.maxY + 10
    if y + size.height > screenSize.height - 8 { y = rect.minY - size.height - 10 }
    if y < 8 { y = rect.maxY - size.height - 10 }
    return AnnotationToolbar(document: document, tools: AnnotationTool.inline, actions: actions)
      .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.toolbarFrame = $0 }
      .offset(x: x, y: y)
  }

  // MARK: Choosing

  private var hintBar: some View {
    Text(purpose.hint)
      .font(.system(size: 13, weight: .medium))
      .foregroundStyle(.white)
      .padding(.horizontal, 14)
      .padding(.vertical, 7)
      .background(.black.opacity(0.7), in: Capsule())
      .fixedSize()
  }

  /// Square magnifier with a yellow crosshair, then size, color and a copy hint.
  @ViewBuilder
  private var loupe: some View {
    let pointer = Self.local(CGRect(origin: model.pointer, size: .zero), in: frozen).origin
    let side = CGFloat(Self.loupePixels) * Self.loupeZoom
    let size = frozen.screen.frame.size
    let x = pointer.x + 22 + side > size.width ? pointer.x - 22 - side : pointer.x + 22
    let y = pointer.y + 22 + side + 56 > size.height ? pointer.y - 22 - side - 56 : pointer.y + 22
    let live = model.liveSelection
    VStack(spacing: 0) {
      ZStack {
        if let crop = loupeImage() {
          Image(decorative: crop, scale: 1)
            .interpolation(.none)
            .resizable()
            .frame(width: side, height: side)
        }
        Rectangle().fill(.yellow.opacity(0.85)).frame(width: side, height: 1)
        Rectangle().fill(.yellow.opacity(0.85)).frame(width: 1, height: side)
      }
      .frame(width: side, height: side)
      .clipped()
      VStack(spacing: 2) {
        if let live, live.width > 0 {
          Text("\(Int((live.width * frozen.scale).rounded())) * \(Int((live.height * frozen.scale).rounded()))")
        } else {
          Text("\(Int((pointer.x * frozen.scale).rounded())), \(Int((pointer.y * frozen.scale).rounded()))")
        }
        if let hex = Self.hexColor(in: frozen, at: model.pointer) {
          Text("RGB:\(hex)")
        }
        if purpose == .screenshot {
          Text("(Press “C” to copy)")
        }
      }
      .font(.system(size: 10.5, weight: .medium).monospacedDigit())
      .foregroundStyle(.white)
      .frame(width: side)
      .padding(.vertical, 5)
      .background(.black)
    }
    .overlay(Rectangle().strokeBorder(.white.opacity(0.9), lineWidth: 1))
    .shadow(radius: 6)
    .offset(x: x, y: y)
  }

  private func loupeImage() -> CGImage? {
    let center = frozen.pixelRect(for: CGRect(origin: model.pointer, size: .zero)).origin
    let half = CGFloat(Self.loupePixels / 2)
    return frozen.image.cropping(to: CGRect(x: center.x - half, y: center.y - half,
                                            width: CGFloat(Self.loupePixels), height: CGFloat(Self.loupePixels)))
  }

  static func hexColor(in frozen: FrozenScreen, at point: CGPoint) -> String? {
    let pixel = frozen.pixelRect(for: CGRect(origin: point, size: .zero)).origin
    guard let crop = frozen.image.cropping(to: CGRect(x: pixel.x, y: pixel.y, width: 1, height: 1)),
          let color = NSBitmapImageRep(cgImage: crop).colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB) else {
      return nil
    }
    return String(format: "#%02X%02X%02X",
                  Int((color.redComponent * 255).rounded()),
                  Int((color.greenComponent * 255).rounded()),
                  Int((color.blueComponent * 255).rounded()))
  }
}
