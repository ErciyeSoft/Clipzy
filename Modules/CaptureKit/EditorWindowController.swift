import AppKit
import KitziCore
import SwiftUI

@Observable
final class ToastState {
  var message: String?
}

/// A window with the annotation editor for one screenshot (window and screen captures,
/// or "Edit" from a pin or the history).
final class EditorWindowController: NSObject, NSWindowDelegate {
  /// Open editors keep themselves alive until their window closes.
  private static var open: Set<EditorWindowController> = []

  private let document: EditorDocument
  private let toast = ToastState()
  private var window: NSWindow?

  static func present(_ image: CGImage) {
    let controller = EditorWindowController(image: image)
    open.insert(controller)
    controller.show()
  }

  private init(image: CGImage) {
    document = EditorDocument(image: image, tool: .arrow)
    super.init()
  }

  private func show() {
    let actions = EditorActions(
      cancel: { [weak self] in self?.window?.close() },
      share: { [weak self] view in self?.export().map { CaptureActions.share($0, from: view) } },
      recognizeText: { [weak self] in self?.export().map(CaptureActions.recognizeText) },
      pin: { [weak self] in
        guard let self, let image = export() else { return }
        CaptureActions.pin(image)
        self.window?.close()
      },
      save: { [weak self] in
        guard let self, let image = export() else { return }
        CaptureActions.save(image)
        showToast(String(localized: "Saved."))
      },
      done: { [weak self] in
        guard let self, let image = export() else { return }
        CaptureActions.copy(image)
        self.window?.close()
      }
    )
    let root = EditorRoot(document: document, actions: actions, toast: toast)
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: initialSize()),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.title = String(localized: "Screenshot")
    window.titlebarAppearsTransparent = true
    window.appearance = NSAppearance(named: .darkAqua)
    window.minSize = NSSize(width: 820, height: 420)
    window.isReleasedWhenClosed = false
    window.contentViewController = NSHostingController(rootView: root)
    window.setContentSize(initialSize())
    window.delegate = self
    window.center()
    self.window = window
    KitziWindows.didOpen()
    window.makeKeyAndOrderFront(nil)
  }

  private func export() -> CGImage? {
    AnnotationRenderer.export(document)
  }

  /// Fits the screenshot at its natural point size, within most of the screen.
  private func initialSize() -> NSSize {
    let scale = NSScreen.main?.backingScaleFactor ?? 2
    let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
    let image = NSSize(width: document.pixelSize.width / scale + 32,
                       height: document.pixelSize.height / scale + 32 + 70)
    return NSSize(width: min(max(image.width, 860), visible.width * 0.85),
                  height: min(max(image.height, 460), visible.height * 0.85))
  }

  func windowWillClose(_ notification: Notification) {
    window?.contentViewController = nil
    window = nil
    KitziWindows.didClose()
    Self.open.remove(self)
  }

  private func showToast(_ message: String) {
    toast.message = message
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(1.6))
      if self?.toast.message == message { self?.toast.message = nil }
    }
  }
}

private struct EditorRoot: View {
  let document: EditorDocument
  let actions: EditorActions
  let toast: ToastState

  var body: some View {
    EditorView(document: document, actions: actions, toast: toast.message)
      .background {
        // Window shortcuts: ⌘C copies and closes, ⌘S saves, ⌘Z / ⇧⌘Z undo and redo.
        Group {
          Button("") { actions.done() }.keyboardShortcut("c", modifiers: .command)
          Button("") { actions.save() }.keyboardShortcut("s", modifiers: .command)
          Button("") { document.undo() }.keyboardShortcut("z", modifiers: .command)
          Button("") { document.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
        }
        .opacity(0)
      }
  }
}
