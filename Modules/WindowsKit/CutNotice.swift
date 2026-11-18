import AppKit
import SwiftUI

/// A short notice near the bottom of the screen after ⌘X, since Finder shows nothing for a cut.
final class CutNotice {
  private var panel: NSPanel?
  private var hosting: NSHostingView<CutNoticeView>?
  private var hideTask: Task<Void, Never>?

  func show(count: Int) {
    let panel = panel ?? makePanel()
    hosting?.rootView = CutNoticeView(count: count)
    let size = hosting?.fittingSize ?? NSSize(width: 300, height: 56)
    let mouse = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    if let frame = screen?.visibleFrame {
      panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.minY + 140, width: size.width, height: size.height), display: true)
    }
    panel.alphaValue = 0
    panel.orderFrontRegardless()
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.15
      panel.animator().alphaValue = 1
    }
    hideTask?.cancel()
    hideTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(2.2))
      guard !Task.isCancelled else { return }
      self?.hide()
    }
  }

  func hide() {
    hideTask?.cancel()
    hideTask = nil
    guard let panel, panel.isVisible else { return }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.25
      panel.animator().alphaValue = 0
    } completionHandler: {
      MainActor.assumeIsolated {
        if panel.alphaValue == 0 { panel.orderOut(nil) }
      }
    }
  }

  private func makePanel() -> NSPanel {
    let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    panel.level = .statusBar
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.ignoresMouseEvents = true
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]

    let background = NSVisualEffectView()
    background.material = .hudWindow
    background.blendingMode = .behindWindow
    background.state = .active
    background.maskImage = Self.roundedMask(radius: 14)

    let hosting = NSHostingView(rootView: CutNoticeView(count: 1))
    hosting.translatesAutoresizingMaskIntoConstraints = false
    background.addSubview(hosting)
    NSLayoutConstraint.activate([
      hosting.leadingAnchor.constraint(equalTo: background.leadingAnchor),
      hosting.trailingAnchor.constraint(equalTo: background.trailingAnchor),
      hosting.topAnchor.constraint(equalTo: background.topAnchor),
      hosting.bottomAnchor.constraint(equalTo: background.bottomAnchor),
    ])
    panel.contentView = background
    self.panel = panel
    self.hosting = hosting
    return panel
  }

  private static func roundedMask(radius: CGFloat) -> NSImage {
    let edge = radius * 2 + 1
    let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
      NSColor.black.setFill()
      NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
      return true
    }
    image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    image.resizingMode = .stretch
    return image
  }
}

struct CutNoticeView: View {
  let count: Int

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "scissors")
        .font(.title2)
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 2) {
        Text(count == 1 ? String(localized: "1 item cut") : String(localized: "\(count) items cut"))
          .font(.headline)
        Text("Press ⌘V in the destination folder to move.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 12)
    .fixedSize()
  }
}
