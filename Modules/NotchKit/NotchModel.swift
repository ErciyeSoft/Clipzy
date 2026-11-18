import AppKit
import Observation
import UniformTypeIdentifiers

/// A short message shown beside the closed notch when the power source changes.
struct BatteryNotice: Equatable {
  enum Kind {
    case charging
    case onBattery
    case low
  }

  var kind: Kind
  var level: Int
}

/// The models every panel shares.
@MainActor
struct NotchServices {
  let media: NowPlayingModel
  let shelf: NotchShelfModel
  let calendar: NotchCalendarModel
  let battery: NotchBatteryModel
}

/// State of the panel on one screen.
@Observable
final class NotchViewModel {
  enum State {
    case closed
    case open
  }

  enum Tab: Hashable {
    case home
    case shelf
  }

  /// What the closed panel shows beside the camera housing.
  enum ClosedContent: Equatable {
    case plain
    case media
    case hud(NotchHUDEvent)
    case battery(BatteryNotice)
  }

  let screen: NotchScreen
  let services: NotchServices
  var settings: NotchSettings

  private(set) var state = State.closed
  var tab = Tab.home
  /// A drag with files is over the panel.
  var isDropTargeted = false {
    didSet {
      guard isDropTargeted, !oldValue, settings.shelf else { return }
      requestOpen(tab: .shelf)
    }
  }

  private(set) var hud: NotchHUDEvent?
  private(set) var batteryNotice: BatteryNotice?
  /// Closed-view media stays up a few seconds after a pause so a quick pause doesn't flicker.
  private(set) var showsPausedMedia = false

  /// Set by the screen controller, which also starts watching the pointer.
  @ObservationIgnored var openHandler: ((Tab?) -> Void)?
  @ObservationIgnored private var hudWork: DispatchWorkItem?
  @ObservationIgnored private var batteryWork: DispatchWorkItem?
  @ObservationIgnored private var pausedWork: DispatchWorkItem?

  init(screen: NotchScreen, services: NotchServices, settings: NotchSettings) {
    self.screen = screen
    self.services = services
    self.settings = settings
  }

  var isOpen: Bool { state == .open }

  var closedContent: ClosedContent {
    if let hud { return .hud(hud) }
    if let batteryNotice { return .battery(batteryNotice) }
    if settings.nowPlaying, settings.nowPlayingClosed, services.media.hasMedia,
       services.media.isPlaying || showsPausedMedia {
      return .media
    }
    return .plain
  }

  /// Width of one side wing of the closed panel.
  var closedWing: CGFloat {
    switch closedContent {
    case .plain: 0
    case .media: NotchMetrics.mediaWing
    case .hud: NotchMetrics.hudWing
    case .battery: NotchMetrics.batteryWing
    }
  }

  /// Size of the black shape when closed: covers the housing, plus the wings.
  var closedSize: CGSize {
    CGSize(width: screen.closedSize.width + 2 * NotchMetrics.closedTopRadius + 2 * closedWing,
           height: screen.closedSize.height)
  }

  var currentSize: CGSize { isOpen ? NotchMetrics.openSize : closedSize }

  // MARK: Open and close

  /// Opens the panel for a click or a drag.
  func requestOpen(tab: Tab? = nil) {
    if let openHandler { openHandler(tab) } else { open(tab: tab) }
  }

  func open(tab: Tab? = nil) {
    if let tab { self.tab = tab }
    if !settings.shelf, self.tab == .shelf { self.tab = .home }
    guard state != .open else { return }
    state = .open
  }

  func close() {
    guard state != .closed else { return }
    state = .closed
    isDropTargeted = false
  }

  // MARK: Transient content

  func show(_ event: NotchHUDEvent) {
    hud = event
    hudWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated { self?.hud = nil }
    }
    hudWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
  }

  func show(_ notice: BatteryNotice) {
    batteryNotice = notice
    batteryWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated { self?.batteryNotice = nil }
    }
    batteryWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
  }

  /// Called when playback starts or stops.
  func playbackChanged(isPlaying: Bool) {
    pausedWork?.cancel()
    guard !isPlaying else {
      showsPausedMedia = false
      return
    }
    showsPausedMedia = true
    let work = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated { self?.showsPausedMedia = false }
    }
    pausedWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
  }

  // MARK: Drops

  /// Adds dropped files (and text, saved as a file) to the shelf.
  func drop(_ providers: [NSItemProvider]) -> Bool {
    guard settings.shelf else { return false }
    let shelf = services.shelf
    var accepted = false
    for provider in providers {
      if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        accepted = true
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
          guard let url else { return }
          DispatchQueue.main.async {
            MainActor.assumeIsolated { shelf.add([url]) }
          }
        }
      } else if provider.canLoadObject(ofClass: String.self) {
        accepted = true
        _ = provider.loadObject(ofClass: String.self) { text, _ in
          guard let text, !text.isEmpty else { return }
          DispatchQueue.main.async {
            MainActor.assumeIsolated { shelf.addText(text) }
          }
        }
      }
    }
    if accepted { tab = .shelf }
    return accepted
  }
}
