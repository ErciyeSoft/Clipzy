import AppKit
import SwiftUI

/// The menu bar popover: every connected display with its brightness, resolution and
/// arrangement controls.
struct DisplayMenuView: View {
  let manager: DisplayManager
  let openSettings: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Displays")
        .font(.headline)

      if manager.confirmer.isPending {
        Label("Keep or revert the last change first.", systemImage: "clock.arrow.circlepath")
          .font(.callout)
          .foregroundStyle(.orange)
      }

      ForEach(manager.displays) { display in
        DisplayCard(display: display, manager: manager)
        if display.id != manager.displays.last?.id {
          Divider()
        }
      }

      Divider()
      HStack {
        Button("Virtual Displays…") { openSettings(DisplayFeature.virtualPageID) }
        Spacer()
        Button("Display Settings…") { openSettings(DisplayFeature.pageID) }
      }
      .buttonStyle(.link)
    }
    .padding(14)
    .frame(width: 380)
  }
}

private struct DisplayCard: View {
  let display: DisplayInfo
  let manager: DisplayManager

  private var state: DisplayControlState? { manager.controls[display.id] }
  private var mirrorName: String? { display.mirrorOf.flatMap { manager.info($0)?.name } }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      header
      if let state, state.control != .unavailable {
        BrightnessRow(state: state) { manager.setBrightness($0, for: display.id) }
        if let contrast = state.contrast {
          LevelRow(symbol: "circle.lefthalf.filled", label: String(localized: "Contrast"), value: contrast) {
            manager.setContrast($0, for: display.id)
          }
        }
        if let volume = state.volume {
          VolumeRow(volume: volume, isMuted: state.isMuted ?? false,
                    setVolume: { manager.setVolume($0, for: display.id) },
                    toggleMute: { manager.toggleMute(for: display.id) })
        }
      }
      if display.mirrorOf == nil {
        modeMenus
      }
    }
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: display.symbolName)
        .foregroundStyle(.secondary)
        .frame(width: 20)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(display.name)
            .fontWeight(.semibold)
            .lineLimit(1)
          if display.isMain {
            Badge(text: String(localized: "Main"))
          }
          if display.isVirtual {
            Badge(text: String(localized: "Virtual"))
          }
        }
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      arrangementMenu
    }
  }

  private var subtitle: String {
    if let mirrorName { return String(localized: "Mirroring \(mirrorName)") }
    guard let current = display.current else { return "" }
    return "\(current.size.title) · \(formattedRefreshRate(current.refreshRate))"
  }

  private var modeMenus: some View {
    let current = display.current
    let visible = display.resolutions.filter { !$0.isHidden }
    let hidden = display.resolutions.filter(\.isHidden)
    let rates = display.resolutions.first { $0.key == current?.size }?.modes ?? []
    return HStack(spacing: 8) {
      Menu {
        ForEach(visible) { choice in resolutionItem(choice, current: current) }
        if !hidden.isEmpty {
          Divider()
          Menu("More Resolutions") {
            ForEach(hidden) { choice in resolutionItem(choice, current: current) }
          }
        }
      } label: {
        Label(current?.size.title ?? String(localized: "Resolution"), systemImage: "rectangle.expand.vertical")
      }
      .help(String(localized: "Resolution"))
      Menu {
        ForEach(rates) { mode in
          Toggle(isOn: Binding(get: { mode.id == current?.id }, set: { _ in manager.apply(mode, to: display.id) })) {
            Text(mode.isHidden ? String(localized: "\(formattedRefreshRate(mode.refreshRate)) (hidden)") : formattedRefreshRate(mode.refreshRate))
          }
        }
      } label: {
        Text(current.map { formattedRefreshRate($0.refreshRate) } ?? String(localized: "Refresh Rate"))
      }
      .help(String(localized: "Refresh Rate"))
      .frame(maxWidth: 120)
      .disabled(rates.count < 2)
    }
    .disabled(!manager.canChangeArrangement)
  }

  private func resolutionItem(_ choice: ResolutionChoice, current: DisplayModeOption?) -> some View {
    Toggle(isOn: Binding(get: { choice.key == current?.size }, set: { _ in manager.apply(choice, to: display.id) })) {
      Text(choice.isNative ? String(localized: "\(choice.key.title) — Default") : choice.key.title)
    }
  }

  private var arrangementMenu: some View {
    let others = manager.displays.filter { $0.id != display.id && $0.mirrorOf == nil }
    return Menu {
      Button("Make Main Display") { manager.makeMain(display.id) }
        .disabled(display.isMain || display.mirrorOf != nil)
      Menu("Mirror") {
        ForEach(others) { other in
          Toggle(other.name, isOn: Binding(get: { display.mirrorOf == other.id },
                                           set: { _ in manager.setMirroring(display.id, of: other.id) }))
        }
        Divider()
        Button("Stop Mirroring") { manager.setMirroring(display.id, of: nil) }
          .disabled(display.mirrorOf == nil)
      }
      .disabled(others.isEmpty)
    } label: {
      Image(systemName: "ellipsis.circle")
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .disabled(!manager.canChangeArrangement)
    .help(String(localized: "Arrangement"))
  }
}

private struct BrightnessRow: View {
  let state: DisplayControlState
  let set: @MainActor (Double) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 8) {
        Image(systemName: "sun.min")
          .foregroundStyle(.secondary)
          .frame(width: 20)
        Slider(value: Binding(get: { state.brightness }, set: { set($0) }))
          .disabled(state.control == .checking)
        Text(state.brightness.formatted(.percent.precision(.fractionLength(0))))
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
          .frame(width: 40, alignment: .trailing)
      }
      .help(String(localized: "Brightness"))
      if let note {
        Text(note)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .padding(.leading, 28)
      }
    }
  }

  private var note: String? {
    switch state.control {
    case .ddc: String(localized: "DDC/CI")
    case .ddcWriteOnly: String(localized: "DDC/CI (the monitor doesn't report its level)")
    case .software: String(localized: "Software dimming")
    case .checking: String(localized: "Checking DDC/CI…")
    case .native, .unavailable: nil
    }
  }
}

private struct LevelRow: View {
  let symbol: String
  let label: String
  let value: Double
  let set: @MainActor (Double) -> Void

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: symbol)
        .foregroundStyle(.secondary)
        .frame(width: 20)
      Slider(value: Binding(get: { value }, set: { set($0) }))
      Text(value.formatted(.percent.precision(.fractionLength(0))))
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(width: 40, alignment: .trailing)
    }
    .help(label)
  }
}

private struct VolumeRow: View {
  let volume: Double
  let isMuted: Bool
  let setVolume: @MainActor (Double) -> Void
  let toggleMute: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Button(action: toggleMute) {
        Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2")
          .foregroundStyle(isMuted ? Color.red : Color.secondary)
          .frame(width: 20)
      }
      .buttonStyle(.plain)
      .help(isMuted ? String(localized: "Unmute") : String(localized: "Mute"))
      Slider(value: Binding(get: { volume }, set: { setVolume($0) }))
        .disabled(isMuted)
      Text(volume.formatted(.percent.precision(.fractionLength(0))))
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(width: 40, alignment: .trailing)
    }
    .help(String(localized: "Monitor volume"))
  }
}

private struct Badge: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.caption2.weight(.medium))
      .padding(.horizontal, 5)
      .padding(.vertical, 1)
      .background(.quaternary, in: Capsule())
  }
}
