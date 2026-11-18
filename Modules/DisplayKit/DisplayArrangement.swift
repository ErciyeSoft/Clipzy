import AppKit
import CoreGraphics
import Observation
import SwiftUI

/// Resolution, mirroring and main-display changes through Quartz Display Services.
enum DisplayConfigurator {
  static func setMode(_ mode: CGDisplayMode, for display: CGDirectDisplayID) -> Bool {
    configure { CGConfigureDisplayWithDisplayMode($0, display, mode, nil) }
  }

  /// `master` nil stops mirroring.
  static func setMirror(_ display: CGDirectDisplayID, of master: CGDirectDisplayID?) -> Bool {
    configure { CGConfigureDisplayMirrorOfDisplay($0, display, master ?? kCGNullDirectDisplay) }
  }

  /// Top-left corners of the active displays that aren't mirroring another one.
  static func origins() -> [CGDirectDisplayID: CGPoint] {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    return Dictionary(uniqueKeysWithValues: ids.prefix(Int(count))
      .filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
      .map { ($0, CGDisplayBounds($0).origin) })
  }

  static func setOrigins(_ origins: [CGDirectDisplayID: CGPoint]) -> Bool {
    configure { config in
      for (display, origin) in origins {
        let result = CGConfigureDisplayOrigin(config, display, Int32(origin.x), Int32(origin.y))
        if result != .success { return result }
      }
      return .success
    }
  }

  /// The main display is the one at (0, 0); everything else moves with it.
  static func makeMain(_ display: CGDirectDisplayID) -> Bool {
    let all = origins()
    guard let target = all[display] else { return false }
    return setOrigins(all.mapValues { CGPoint(x: $0.x - target.x, y: $0.y - target.y) })
  }

  private static func configure(_ body: (CGDisplayConfigRef) -> CGError) -> Bool {
    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
    guard body(config) == .success else {
      CGCancelDisplayConfiguration(config)
      return false
    }
    return CGCompleteDisplayConfiguration(config, .permanently) == .success
  }
}

/// "Keep these display settings?" with a countdown, like System Settings. Shown on every
/// screen, so it can be answered even if the changed display goes dark; no answer reverts.
@Observable
final class DisplayChangeConfirmer {
  static let timeout = 15

  private(set) var isPending = false
  private(set) var summary = ""
  private(set) var secondsLeft = 0

  @ObservationIgnored private var completion: ((Bool) -> Void)?
  @ObservationIgnored private var countdown: Task<Void, Never>?
  @ObservationIgnored private var panels: [NSPanel] = []

  func ask(summary: String, completion: @escaping (Bool) -> Void) {
    finish(keep: true)
    self.summary = summary
    self.completion = completion
    secondsLeft = Self.timeout
    isPending = true
    countdown = Task { [weak self] in
      // Let the new arrangement settle so the panels land on the screens as they are now.
      try? await Task.sleep(for: .milliseconds(700))
      guard !Task.isCancelled else { return }
      self?.showPanels()
      while !Task.isCancelled, let self, self.secondsLeft > 0 {
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled else { return }
        self.secondsLeft -= 1
      }
      guard !Task.isCancelled else { return }
      self?.finish(keep: false)
    }
  }

  func finish(keep: Bool) {
    guard isPending else { return }
    isPending = false
    countdown?.cancel()
    countdown = nil
    panels.forEach { $0.orderOut(nil) }
    panels = []
    let completion = self.completion
    self.completion = nil
    completion?(keep)
  }

  private func showPanels() {
    guard isPending else { return }
    panels = NSScreen.screens.map { screen in
      let panel = ConfirmPanel(
        contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false
      )
      panel.level = .modalPanel
      panel.isOpaque = false
      panel.backgroundColor = .clear
      panel.hasShadow = true
      panel.hidesOnDeactivate = false
      panel.isReleasedWhenClosed = false
      panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

      let background = NSVisualEffectView()
      background.material = .hudWindow
      background.blendingMode = .behindWindow
      background.state = .active
      background.wantsLayer = true
      background.layer?.cornerRadius = 16
      background.layer?.masksToBounds = true
      let hosting = NSHostingView(rootView: ConfirmChangeView(confirmer: self))
      hosting.translatesAutoresizingMaskIntoConstraints = false
      background.addSubview(hosting)
      NSLayoutConstraint.activate([
        hosting.leadingAnchor.constraint(equalTo: background.leadingAnchor),
        hosting.trailingAnchor.constraint(equalTo: background.trailingAnchor),
        hosting.topAnchor.constraint(equalTo: background.topAnchor),
        hosting.bottomAnchor.constraint(equalTo: background.bottomAnchor),
      ])
      panel.contentView = background
      let size = hosting.fittingSize
      let frame = screen.visibleFrame
      panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2,
                            width: size.width, height: size.height), display: true)
      panel.orderFrontRegardless()
      return panel
    }
    NSApp.activate(ignoringOtherApps: true)
    let mouse = NSEvent.mouseLocation
    (panels.first { NSMouseInRect(mouse, $0.screen?.frame ?? .zero, false) } ?? panels.first)?.makeKey()
  }
}

/// Borderless, but still takes Return and Esc.
private final class ConfirmPanel: NSPanel {
  override var canBecomeKey: Bool { true }
}

private struct ConfirmChangeView: View {
  let confirmer: DisplayChangeConfirmer

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "display")
        .font(.system(size: 30))
        .foregroundStyle(.secondary)
      Text("Keep these display settings?")
        .font(.headline)
      Text(confirmer.summary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      Text("Reverting in \(confirmer.secondsLeft) seconds.")
        .font(.callout.monospacedDigit())
        .foregroundStyle(.secondary)
      HStack(spacing: 10) {
        Button("Revert") { confirmer.finish(keep: false) }
          .keyboardShortcut(.cancelAction)
        Button("Keep Changes") { confirmer.finish(keep: true) }
          .keyboardShortcut(.defaultAction)
      }
      .controlSize(.large)
      .padding(.top, 4)
    }
    .padding(22)
    .frame(width: 340)
  }
}
