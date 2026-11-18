import AppKit
import SwiftUI

// MARK: - Now playing

struct ArtworkView: View {
  let media: NowPlayingModel
  var cornerRadius: CGFloat = 13

  var body: some View {
    ZStack {
      if let artwork = media.artwork {
        Image(nsImage: artwork)
          .resizable()
          .aspectRatio(contentMode: .fill)
      } else if let icon = media.appIcon {
        Image(nsImage: icon)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .padding(cornerRadius > 6 ? 14 : 0)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(Color.white.opacity(cornerRadius > 6 ? 0.08 : 0))
      } else {
        Image(systemName: "music.note")
          .font(.system(size: cornerRadius > 6 ? 30 : 10))
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(Color.white.opacity(0.1))
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
  }
}

struct MediaPlayerView: View {
  let media: NowPlayingModel

  var body: some View {
    if !media.isAvailable {
      placeholder(symbol: "exclamationmark.triangle",
                  title: "Now playing isn't available",
                  detail: "This version of macOS doesn't let Kitzi read what is playing.")
    } else if !media.hasMedia {
      placeholder(symbol: "music.note",
                  title: "Nothing playing",
                  detail: "Play something in Music, Spotify, a browser or any other player.")
    } else {
      HStack(spacing: 14) {
        Button {
          media.openSourceApp()
        } label: {
          ArtworkView(media: media)
            .frame(width: 90, height: 90)
            .overlay(alignment: .bottomTrailing) {
              if media.artwork != nil, let icon = media.appIcon {
                Image(nsImage: icon)
                  .resizable()
                  .frame(width: 24, height: 24)
                  .shadow(radius: 2)
                  .offset(x: 6, y: 6)
              }
            }
        }
        .buttonStyle(.plain)
        .help(Text(verbatim: media.appName))

        VStack(alignment: .leading, spacing: 4) {
          Text(verbatim: media.title)
            .font(.system(size: 14, weight: .semibold))
            .lineLimit(1)
          Text(verbatim: media.artist.isEmpty ? media.appName : media.artist)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(1)
          if media.duration > 0 {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
              MediaProgress(elapsed: media.elapsed(at: context.date), duration: media.duration) { seconds in
                media.seek(to: seconds)
              }
            }
            .padding(.top, 2)
          }
          HStack(spacing: 22) {
            MediaButton(symbol: "backward.fill", size: 15, label: "Previous") { media.previousTrack() }
            MediaButton(symbol: media.isPlaying ? "pause.fill" : "play.fill", size: 22,
                        label: media.isPlaying ? "Pause" : "Play") {
              media.togglePlayPause()
            }
            MediaButton(symbol: "forward.fill", size: 15, label: "Next") { media.nextTrack() }
          }
          .frame(maxWidth: .infinity)
          .padding(.top, 2)
        }
      }
    }
  }

  private func placeholder(symbol: String, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
    HStack(spacing: 14) {
      Image(systemName: symbol)
        .font(.system(size: 28))
        .foregroundStyle(.secondary)
        .frame(width: 90, height: 90)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.white.opacity(0.08)))
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.system(size: 14, weight: .semibold))
        Text(detail)
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

struct MediaButton: View {
  let symbol: String
  let size: CGFloat
  let label: LocalizedStringKey
  let action: () -> Void
  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: size))
        .contentTransition(.symbolEffect(.replace))
        .frame(width: size + 14, height: size + 10)
        .background(Circle().fill(Color.white.opacity(isHovering ? 0.12 : 0)))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .help(Text(label))
    .accessibilityLabel(Text(label))
  }
}

/// Elapsed time, a bar you can drag to seek, and the duration.
struct MediaProgress: View {
  let elapsed: TimeInterval
  let duration: TimeInterval
  let onSeek: (TimeInterval) -> Void
  @State private var dragPosition: TimeInterval?

  var body: some View {
    let shown = dragPosition ?? elapsed
    HStack(spacing: 8) {
      Text(verbatim: Self.format(shown))
        .frame(width: 38, alignment: .trailing)
      GeometryReader { geometry in
        let fraction = duration > 0 ? min(1, max(0, shown / duration)) : 0
        ZStack(alignment: .leading) {
          Capsule().fill(Color.white.opacity(0.2))
          Capsule().fill(Color.white)
            .frame(width: geometry.size.width * fraction)
        }
        .frame(height: dragPosition == nil ? 5 : 7)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(
          DragGesture(minimumDistance: 0)
            .onChanged { value in
              dragPosition = position(at: value.location.x, width: geometry.size.width)
            }
            .onEnded { value in
              onSeek(position(at: value.location.x, width: geometry.size.width))
              dragPosition = nil
            }
        )
      }
      .frame(height: 12)
      Text(verbatim: Self.format(duration))
        .frame(width: 38, alignment: .leading)
    }
    .font(.system(size: 10, weight: .medium).monospacedDigit())
    .foregroundStyle(.secondary)
    .animation(.smooth(duration: 0.12), value: dragPosition == nil)
  }

  private func position(at x: CGFloat, width: CGFloat) -> TimeInterval {
    guard width > 0 else { return 0 }
    return duration * Double(min(1, max(0, x / width)))
  }

  static func format(_ seconds: TimeInterval) -> String {
    let total = Int(max(0, seconds.isFinite ? seconds : 0))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let rest = total % 60
    return hours > 0
      ? String(format: "%d:%02d:%02d", hours, minutes, rest)
      : String(format: "%d:%02d", minutes, rest)
  }
}

// MARK: - Calendar

struct CalendarColumn: View {
  let calendar: NotchCalendarModel

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button {
        calendar.openCalendar()
      } label: {
        Text(Date.now, format: .dateTime.weekday(.wide).day().month(.wide))
          .font(.system(size: 12, weight: .semibold))
          .lineLimit(1)
      }
      .buttonStyle(.plain)
      .help(Text("Open Calendar"))

      switch calendar.access {
      case .notDetermined:
        Text("See today's events here.")
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
        Button("Show Calendar Events") { calendar.requestAccess() }
          .controlSize(.small)
      case .denied:
        Text("Kitzi can't read your calendars.")
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
        Button("Open Privacy Settings…") { calendar.openPrivacySettings() }
          .controlSize(.small)
      case .granted:
        if calendar.events.isEmpty {
          Text("No more events today")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        } else {
          ForEach(calendar.events.prefix(4)) { event in
            CalendarEventRow(event: event)
          }
          if calendar.events.count > 4 {
            Text("\(calendar.events.count - 4) more")
              .font(.system(size: 10))
              .foregroundStyle(.secondary)
          }
        }
      }
      Spacer(minLength: 0)
    }
    .frame(maxHeight: .infinity, alignment: .top)
  }
}

struct CalendarEventRow: View {
  let event: NotchEvent

  var body: some View {
    HStack(alignment: .top, spacing: 6) {
      RoundedRectangle(cornerRadius: 1.5)
        .fill(Color(nsColor: event.color))
        .frame(width: 3, height: 24)
      VStack(alignment: .leading, spacing: 1) {
        Text(verbatim: event.title)
          .font(.system(size: 11, weight: .medium))
          .lineLimit(1)
        if event.isAllDay {
          Text("All day")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        } else {
          Text(verbatim: "\(event.start.formatted(date: .omitted, time: .shortened)) – \(event.end.formatted(date: .omitted, time: .shortened))")
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(event.start <= .now ? Color.accentColor : .secondary)
        }
      }
    }
  }
}

// MARK: - Shelf

struct ShelfView: View {
  @Bindable var model: NotchViewModel

  var body: some View {
    let shelf = model.services.shelf
    ZStack {
      if shelf.items.isEmpty {
        VStack(spacing: 6) {
          Image(systemName: "tray.and.arrow.down")
            .font(.system(size: 24))
          Text("Drop files here")
            .font(.system(size: 13, weight: .semibold))
          Text("They stay on the shelf until you remove them. Drag them out into any app or folder.")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 8) {
            ForEach(shelf.items) { item in
              ShelfItemView(item: item, shelf: shelf)
            }
          }
          .padding(.horizontal, 6)
          .frame(maxHeight: .infinity)
        }
      }
    }
    .background {
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        .foregroundStyle(Color.white.opacity(model.isDropTargeted ? 0.7 : (shelf.items.isEmpty ? 0.25 : 0)))
        .background(
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.white.opacity(model.isDropTargeted ? 0.08 : 0))
        )
    }
    .animation(.smooth(duration: 0.15), value: model.isDropTargeted)
    .onAppear { shelf.revalidate() }
  }
}

struct ShelfItemView: View {
  let item: ShelfItem
  let shelf: NotchShelfModel
  @State private var thumbnail: NSImage?
  @State private var isHovering = false

  var body: some View {
    VStack(spacing: 4) {
      Image(nsImage: thumbnail ?? NSWorkspace.shared.icon(forFile: item.path))
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: 52, height: 52)
      Text(verbatim: item.name)
        .font(.system(size: 10))
        .lineLimit(2)
        .multilineTextAlignment(.center)
        .frame(width: 74, height: 26, alignment: .top)
    }
    .padding(.horizontal, 4)
    .padding(.vertical, 6)
    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(isHovering ? 0.12 : 0)))
    .overlay(alignment: .topTrailing) {
      if isHovering {
        Button {
          shelf.remove(item)
        } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 13))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, Color(white: 0.3))
        }
        .buttonStyle(.plain)
        .help(Text("Remove from Shelf"))
        .offset(x: 2, y: -2)
      }
    }
    .contentShape(Rectangle())
    .onHover { isHovering = $0 }
    .onTapGesture(count: 2) { shelf.open(item) }
    .onDrag {
      NSItemProvider(contentsOf: item.url) ?? NSItemProvider()
    }
    .contextMenu {
      Button("Open") { shelf.open(item) }
      Button("Show in Finder") { shelf.reveal(item) }
      Button("Copy") { shelf.copy(item) }
      Divider()
      Button("Remove from Shelf") { shelf.remove(item) }
    }
    .help(Text(verbatim: item.path))
    .task(id: item.path) {
      thumbnail = await ShelfThumbnails.thumbnail(for: item.url, size: 104)
    }
  }
}
