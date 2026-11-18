import AppKit
import Observation

/// What is playing right now, fed by `MediaRemoteBridge`.
@Observable
final class NowPlayingModel {
  private(set) var hasMedia = false
  private(set) var title = ""
  private(set) var artist = ""
  private(set) var album = ""
  private(set) var artwork: NSImage?
  private(set) var isPlaying = false
  private(set) var duration: TimeInterval = 0
  private(set) var appName = ""
  private(set) var bundleID: String?
  /// False when MediaRemote can't be read on this system.
  private(set) var isAvailable = true
  /// Last time playback started or stopped; used to keep the closed view steady briefly.
  private(set) var lastPlayingChange = Date.distantPast

  /// Position at `positionDate`, advanced at `rate` while playing.
  private var position: TimeInterval = 0
  private var positionDate = Date()
  private var rate: Double = 0
  /// Ignore the feed's position for a moment after a local seek or play/pause.
  private var holdPositionUntil = Date.distantPast

  @ObservationIgnored private let bridge = MediaRemoteBridge()

  init() {
    bridge.onSnapshot = { [weak self] snapshot in self?.apply(snapshot) }
  }

  var isRunning: Bool { bridge.isRunning }

  func start() { bridge.start() }

  func stop() {
    bridge.stop()
    clear()
  }

  /// The playback position now.
  func elapsed(at date: Date = Date()) -> TimeInterval {
    let value = position + (isPlaying ? date.timeIntervalSince(positionDate) * max(rate, 0) : 0)
    return duration > 0 ? min(max(0, value), duration) : max(0, value)
  }

  // MARK: Controls

  func togglePlayPause() {
    let now = Date()
    position = elapsed(at: now)
    positionDate = now
    isPlaying.toggle()
    if isPlaying, rate == 0 { rate = 1 }
    lastPlayingChange = now
    holdPositionUntil = now.addingTimeInterval(1.5)
    bridge.send(.togglePlayPause)
  }

  func nextTrack() { bridge.send(.nextTrack) }
  func previousTrack() { bridge.send(.previousTrack) }

  func seek(to seconds: TimeInterval) {
    position = seconds
    positionDate = Date()
    holdPositionUntil = Date().addingTimeInterval(1.5)
    bridge.seek(to: seconds)
  }

  /// Brings the app that plays the media to the front.
  func openSourceApp() {
    guard let bundleID,
          let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
  }

  var appIcon: NSImage? {
    guard let bundleID,
          let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
    return NSWorkspace.shared.icon(forFile: url.path)
  }

  // MARK: Feed

  private func apply(_ snapshot: NowPlayingSnapshot) {
    switch snapshot.kind {
    case .unavailable:
      isAvailable = false
      clear()
      return
    case .none:
      clear()
      return
    case .beat:
      return
    case .playing:
      break
    }

    let newBundleID = snapshot.parentBundleID ?? snapshot.bundleID
    let newTitle = snapshot.title ?? ""
    let sourceName = snapshot.appName ?? newBundleID.flatMap(Self.appName(for:)) ?? ""
    hasMedia = true
    // Players without metadata (QuickTime with a bare file) still get a name.
    title = newTitle.isEmpty ? sourceName : newTitle
    artist = snapshot.artist ?? ""
    album = snapshot.album ?? ""
    duration = max(0, snapshot.duration ?? 0)
    appName = sourceName
    bundleID = newBundleID

    let playing = snapshot.playing ?? ((snapshot.rate ?? 0) > 0)
    if playing != isPlaying, Date() >= holdPositionUntil {
      isPlaying = playing
      lastPlayingChange = Date()
    }
    if Date() >= holdPositionUntil {
      // A player that just started may still report a rate of 0.
      let reported = snapshot.rate ?? 0
      rate = playing ? (reported > 0 ? reported : 1) : 0
      position = snapshot.elapsed ?? 0
      positionDate = snapshot.timestamp.map { Date(timeIntervalSince1970: $0) } ?? Date()
    }

    if snapshot.artworkChanged == true {
      artwork = snapshot.artwork
        .flatMap { Data(base64Encoded: $0) }
        .flatMap(NSImage.init(data:))
    }
  }

  private func clear() {
    hasMedia = false
    title = ""
    artist = ""
    album = ""
    artwork = nil
    if isPlaying { lastPlayingChange = Date() }
    isPlaying = false
    duration = 0
    position = 0
    rate = 0
    appName = ""
    bundleID = nil
  }

  private static func appName(for bundleID: String) -> String? {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
    return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
  }
}
