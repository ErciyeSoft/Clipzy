import AppKit
import KitziCore
import SwiftUI

/// Fills the panel window; the notch hangs from its top edge.
struct NotchRootView: View {
  let model: NotchViewModel

  var body: some View {
    NotchBody(model: model)
      .frame(width: NotchMetrics.windowSize.width, height: NotchMetrics.windowSize.height, alignment: .top)
      .environment(\.colorScheme, .dark)
  }
}

/// The black shape: closed it covers the camera housing, open it grows into the panel.
struct NotchBody: View {
  @Bindable var model: NotchViewModel

  var body: some View {
    let isOpen = model.isOpen
    let size = model.currentSize
    let shape = NotchShape(
      topRadius: isOpen ? NotchMetrics.openTopRadius : NotchMetrics.closedTopRadius,
      bottomRadius: isOpen ? NotchMetrics.openBottomRadius : NotchMetrics.closedBottomRadius
    )
    ZStack(alignment: .top) {
      // Always in the hierarchy and only faded: removing it with a transition left it blank
      // after the panel had been opened once.
      NotchClosedView(model: model)
        .opacity(isOpen ? 0 : 1)
        .allowsHitTesting(!isOpen)
      if isOpen {
        NotchOpenView(model: model)
          .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
      }
    }
    .frame(width: size.width, height: size.height, alignment: .top)
    .background(Color.black)
    .clipShape(shape)
    .contentShape(shape)
    .shadow(color: .black.opacity(isOpen ? 0.55 : 0), radius: 10, y: 3)
    .onTapGesture {
      if !model.isOpen { model.requestOpen() }
    }
    .onDrop(of: [.fileURL, .plainText], isTargeted: $model.isDropTargeted) { providers in
      model.drop(providers)
    }
    .contextMenu {
      Button("Notch Settings…") { KitziHost.openSettings(NotchFeature.pageID) }
    }
    .animation(
      isOpen ? .spring(response: 0.42, dampingFraction: 0.8) : .spring(response: 0.45, dampingFraction: 1),
      value: isOpen
    )
    .animation(.spring(response: 0.38, dampingFraction: 0.85), value: model.closedWing)
  }
}

// MARK: - Closed

/// Beside the housing: artwork and a level meter while playing, a HUD, or a battery notice.
struct NotchClosedView: View {
  let model: NotchViewModel

  var body: some View {
    let wing = model.closedWing
    HStack(spacing: 0) {
      leading
        .frame(width: wing, alignment: .leading)
      Color.clear
        .frame(width: model.screen.closedSize.width)
      trailing
        .frame(width: wing, alignment: .trailing)
    }
    .padding(.horizontal, NotchMetrics.closedTopRadius)
    .frame(height: model.screen.closedSize.height)
    .clipped()
  }

  @ViewBuilder private var leading: some View {
    switch model.closedContent {
    case .plain:
      EmptyView()
    case .media:
      ArtworkView(media: model.services.media, cornerRadius: 5)
        .frame(width: 20, height: 20)
        .padding(.leading, 6)
    case .hud(let event):
      Image(systemName: HUDSymbols.symbol(for: event))
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.white)
        .contentTransition(.symbolEffect(.replace))
        .frame(width: 22)
        .padding(.leading, 8)
    case .battery(let notice):
      Text(BatteryText.title(for: notice))
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(BatteryText.color(for: notice))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .padding(.leading, 8)
    }
  }

  @ViewBuilder private var trailing: some View {
    switch model.closedContent {
    case .plain:
      EmptyView()
    case .media:
      EqualizerBars(isPlaying: model.services.media.isPlaying)
        .padding(.trailing, 7)
    case .hud(let event):
      LevelBar(value: event.muted ? 0 : event.value)
        .frame(width: NotchMetrics.hudWing - 22, height: 5)
        .padding(.trailing, 8)
    case .battery(let notice):
      HStack(spacing: 4) {
        Text(verbatim: "\(notice.level)%")
          .font(.system(size: 12, weight: .semibold).monospacedDigit())
        Image(systemName: BatteryText.symbol(level: notice.level, charging: notice.kind == .charging))
          .font(.system(size: 13))
      }
      .foregroundStyle(BatteryText.color(for: notice))
      .padding(.trailing, 8)
    }
  }
}

/// A small animated level meter, still while paused.
struct EqualizerBars: View {
  let isPlaying: Bool

  var body: some View {
    TimelineView(.animation(minimumInterval: 0.18, paused: !isPlaying)) { context in
      let time = context.date.timeIntervalSinceReferenceDate
      HStack(spacing: 2) {
        ForEach(0..<4, id: \.self) { index in
          let speed = 2.3 + Double(index) * 0.7
          let height = isPlaying ? 0.3 + 0.7 * abs(sin(time * speed + Double(index) * 1.9)) : 0.25
          Capsule()
            .fill(Color.white.opacity(0.85))
            .frame(width: 2.5, height: 14 * height)
        }
      }
      .animation(.easeInOut(duration: 0.18), value: time)
    }
    .frame(width: 18, height: 14)
  }
}

struct LevelBar: View {
  let value: Float

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Capsule().fill(Color.white.opacity(0.22))
        Capsule().fill(Color.white)
          .frame(width: geometry.size.width * CGFloat(min(1, max(0, value))))
      }
    }
    .animation(.smooth(duration: 0.15), value: value)
  }
}

enum HUDSymbols {
  static func symbol(for event: NotchHUDEvent) -> String {
    switch event.kind {
    case .brightness:
      return event.value < 0.5 ? "sun.min.fill" : "sun.max.fill"
    case .volume:
      if event.muted || event.value <= 0.001 { return "speaker.slash.fill" }
      if event.value < 0.34 { return "speaker.wave.1.fill" }
      if event.value < 0.67 { return "speaker.wave.2.fill" }
      return "speaker.wave.3.fill"
    }
  }
}

enum BatteryText {
  static func title(for notice: BatteryNotice) -> String {
    switch notice.kind {
    case .charging: String(localized: "Charging")
    case .onBattery: String(localized: "On Battery")
    case .low: String(localized: "Low Battery")
    }
  }

  static func color(for notice: BatteryNotice) -> Color {
    switch notice.kind {
    case .charging: .green
    case .onBattery: .white
    case .low: .red
    }
  }

  static func symbol(level: Int, charging: Bool) -> String {
    if charging { return "battery.100percent.bolt" }
    switch level {
    case ..<13: return "battery.0percent"
    case ..<38: return "battery.25percent"
    case ..<63: return "battery.50percent"
    case ..<88: return "battery.75percent"
    default: return "battery.100percent"
    }
  }
}

// MARK: - Open

struct NotchOpenView: View {
  @Bindable var model: NotchViewModel

  var body: some View {
    VStack(spacing: 6) {
      NotchHeader(model: model)
        .frame(height: max(28, model.screen.closedSize.height))
      Group {
        switch model.tab {
        case .home: NotchHomeView(model: model)
        case .shelf: ShelfView(model: model)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .padding(.horizontal, NotchMetrics.openTopRadius + 10)
    .padding(.bottom, 14)
    .frame(width: NotchMetrics.openSize.width, height: NotchMetrics.openSize.height, alignment: .top)
    .foregroundStyle(.white)
  }
}

/// Tabs on the left, status on the right, and nothing under the camera housing.
struct NotchHeader: View {
  @Bindable var model: NotchViewModel

  var body: some View {
    HStack(spacing: 0) {
      HStack(spacing: 6) {
        NotchTabButton(symbol: "house.fill", label: "Home", isSelected: model.tab == .home) {
          model.tab = .home
        }
        if model.settings.shelf {
          NotchTabButton(symbol: "tray.fill", label: "Shelf", isSelected: model.tab == .shelf,
                         badge: model.services.shelf.items.count) {
            model.tab = .shelf
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Color.clear.frame(width: model.screen.closedSize.width + 12)

      HStack(spacing: 10) {
        if let hud = model.hud {
          HStack(spacing: 6) {
            Image(systemName: HUDSymbols.symbol(for: hud))
              .font(.system(size: 11, weight: .semibold))
              .frame(width: 16)
            LevelBar(value: hud.muted ? 0 : hud.value)
              .frame(width: 60, height: 4)
          }
          .transition(.opacity)
        }
        if model.tab == .shelf, !model.services.shelf.items.isEmpty {
          Button {
            model.services.shelf.clear()
          } label: {
            Image(systemName: "trash")
              .font(.system(size: 12))
          }
          .buttonStyle(NotchIconButtonStyle())
          .help(Text("Clear Shelf"))
        }
        if model.settings.battery, model.services.battery.hasBattery {
          let battery = model.services.battery
          HStack(spacing: 3) {
            Text(verbatim: "\(battery.level)%")
              .font(.system(size: 11, weight: .medium).monospacedDigit())
              .foregroundStyle(.secondary)
            Image(systemName: BatteryText.symbol(level: battery.level, charging: battery.isCharging))
              .font(.system(size: 13))
              .foregroundStyle(battery.isCharging ? .green : (battery.level <= 20 ? .red : .white))
          }
        }
        Button {
          KitziHost.openSettings(NotchFeature.pageID)
        } label: {
          Image(systemName: "gearshape.fill")
            .font(.system(size: 12))
        }
        .buttonStyle(NotchIconButtonStyle())
        .help(Text("Notch Settings…"))
      }
      .frame(maxWidth: .infinity, alignment: .trailing)
    }
    .animation(.smooth(duration: 0.2), value: model.hud)
  }
}

struct NotchTabButton: View {
  let symbol: String
  let label: LocalizedStringKey
  let isSelected: Bool
  var badge = 0
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 4) {
        Image(systemName: symbol)
          .font(.system(size: 11))
        if badge > 0 {
          Text(verbatim: "\(badge)")
            .font(.system(size: 10, weight: .semibold).monospacedDigit())
        }
      }
      .padding(.horizontal, 10)
      .frame(height: 22)
      .background(Capsule().fill(Color.white.opacity(isSelected ? 0.18 : 0.0001)))
      .foregroundStyle(isSelected ? .white : .secondary)
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .help(Text(label))
    .accessibilityLabel(Text(label))
  }
}

struct NotchIconButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(.white.opacity(configuration.isPressed ? 0.5 : 0.85))
      .frame(width: 24, height: 22)
      .contentShape(Rectangle())
  }
}

// MARK: - Home

struct NotchHomeView: View {
  let model: NotchViewModel

  var body: some View {
    HStack(spacing: 16) {
      if model.settings.nowPlaying {
        MediaPlayerView(media: model.services.media)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      if model.settings.nowPlaying, model.settings.calendar {
        Rectangle()
          .fill(Color.white.opacity(0.12))
          .frame(width: 1)
          .padding(.vertical, 8)
      }
      if model.settings.calendar {
        CalendarColumn(calendar: model.services.calendar)
          .frame(width: model.settings.nowPlaying ? 190 : nil)
          .frame(maxWidth: model.settings.nowPlaying ? nil : .infinity, alignment: .leading)
      }
      if !model.settings.nowPlaying, !model.settings.calendar {
        VStack(spacing: 6) {
          Image(systemName: "rectangle.topthird.inset.filled")
            .font(.system(size: 22))
            .foregroundStyle(.secondary)
          Text("Turn on Now playing or Today's events in the notch settings.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }
}
