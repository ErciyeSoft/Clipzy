import AppKit
import EventKit
import Observation

/// One of today's events.
struct NotchEvent: Identifiable, Equatable {
  let id: String
  let title: String
  let start: Date
  let end: Date
  let isAllDay: Bool
  let color: NSColor
}

/// Today's remaining events from Calendar. Access is only asked for when the user clicks.
@Observable
final class NotchCalendarModel {
  enum Access {
    case notDetermined
    case granted
    case denied
  }

  private(set) var access = Access.notDetermined
  private(set) var events: [NotchEvent] = []

  @ObservationIgnored private var store: EKEventStore?
  @ObservationIgnored private var observers: [NSObjectProtocol] = []
  @ObservationIgnored private var timer: Timer?

  private var isStarted: Bool { !observers.isEmpty }

  func start() {
    guard !isStarted else { return }
    updateAccess()
    let center = NotificationCenter.default
    observers.append(center.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.refresh() }
    })
    observers.append(center.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.refresh() }
    })
    // Finished events drop off the list.
    let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.refresh() }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
    refresh()
  }

  func stop() {
    observers.forEach(NotificationCenter.default.removeObserver)
    observers = []
    timer?.invalidate()
    timer = nil
    events = []
  }

  func requestAccess() {
    let store = eventStore()
    store.requestFullAccessToEvents { [weak self] _, _ in
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          self?.updateAccess()
          self?.refresh()
        }
      }
    }
  }

  func openPrivacySettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
      NSWorkspace.shared.open(url)
    }
  }

  func openCalendar() {
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
      NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
  }

  private func updateAccess() {
    switch EKEventStore.authorizationStatus(for: .event) {
    case .fullAccess: access = .granted
    case .notDetermined: access = .notDetermined
    default: access = .denied
    }
  }

  private func eventStore() -> EKEventStore {
    if let store { return store }
    let created = EKEventStore()
    store = created
    return created
  }

  private func refresh() {
    updateAccess()
    guard isStarted, access == .granted else {
      events = []
      return
    }
    let store = eventStore()
    let now = Date()
    let calendar = Calendar.current
    let startOfDay = calendar.startOfDay(for: now)
    guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else { return }
    let predicate = store.predicateForEvents(withStart: startOfDay, end: endOfDay, calendars: nil)
    let found = store.events(matching: predicate)
      .filter { $0.isAllDay || $0.endDate > now }
      .sorted { lhs, rhs in
        if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
        return lhs.startDate < rhs.startDate
      }
      .map { event in
        NotchEvent(
          id: event.calendarItemIdentifier + "\(event.startDate.timeIntervalSince1970)",
          title: event.title ?? "",
          start: event.startDate,
          end: event.endDate,
          isAllDay: event.isAllDay,
          color: event.calendar.map { NSColor(cgColor: $0.cgColor) ?? .systemBlue } ?? .systemBlue
        )
      }
    if found != events { events = found }
  }
}
