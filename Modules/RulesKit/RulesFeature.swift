import AppKit
import KitziCore
import SwiftUI

enum RulesPrefs {
  static let appSweepKey = "rules.appSweep"

  static func register() {
    UserDefaults.standard.register(defaults: [appSweepKey: true])
  }

  static var appSweep: Bool { UserDefaults.standard.bool(forKey: appSweepKey) }
}

/// Public entry point of Folder Rules: watches folders the user picks and runs their rules
/// on new and changed files, Hazel-style, plus App Sweep for leftovers of deleted apps.
/// Nothing runs until the user adds a folder and a rule.
public final class RulesFeature: KitziFeature {
  static let pageID = "rules.general"
  /// Date conditions ("added more than 3 days ago") need a look now and then, not only on changes.
  private static let recheckInterval: Duration = .seconds(15 * 60)

  private let store: RulesStore
  private let sweeper: AppSweeper
  private var recheckTask: Task<Void, Never>?
  private var observers: [NSObjectProtocol] = []

  public init() {
    RulesPrefs.register()
    store = RulesStore(directory: RulesPaths.directory)
    sweeper = AppSweeper(directory: RulesPaths.directory)
  }

  public func applicationDidFinishLaunching() {
    Task { [store] in await store.load() }
    recheckTask = Task { [weak store] in
      while !Task.isCancelled {
        try? await Task.sleep(for: Self.recheckInterval)
        store?.runAutomaticCheck()
      }
    }
    observers.append(NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.didWake() }
    })
    observers.append(NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.applyPreferences() }
    })
    applyPreferences()
  }

  public func applicationWillTerminate() {
    recheckTask?.cancel()
    store.stop()
    store.flush()
    sweeper.stop()
  }

  public var settingsGroups: [SettingsGroup] {
    [
      SettingsGroup(
        id: "rules",
        title: String(localized: "Folder Rules"),
        pages: [
          SettingsPage(
            id: Self.pageID,
            title: String(localized: "Folder Rules"),
            subtitle: String(localized: "Sort, rename and tidy files in folders automatically"),
            systemImage: "folder.badge.gearshape"
          ) { [store] in
            RulesSettingsView(store: store)
          }
        ]
      )
    ]
  }

  private func applyPreferences() {
    sweeper.setEnabled(RulesPrefs.appSweep)
  }

  /// Disks and network folders can take a moment to come back after sleep.
  private func didWake() {
    Task { [weak store] in
      try? await Task.sleep(for: .seconds(10))
      store?.runAutomaticCheck()
    }
  }
}
