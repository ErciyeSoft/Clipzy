import Combine
import SwiftUI

// Kitzi is a personal hard fork: Sparkle and the upstream appcast are removed.
// This keeps the original API so existing views compile, but never reports updates.

enum UpdateChannel: String, CaseIterable {
    case stable
    case beta

    var displayName: String {
        switch self {
        case .stable:
            String(localized: "Stable")
        case .beta:
            String(localized: "Beta")
        }
    }
}

final class UpdaterState: NSObject, ObservableObject {
    @Published var canCheckForUpdates: Bool = false
    @Published var lastUpdateCheckDate: Date?
    @Published var currentVersion: String
    @Published var isAutomaticChecksEnabled: Bool = false
    @Published var updateChannel: UpdateChannel = .stable
    @Published var updateStatus: UpdateStatus = .noUpdates

    enum UpdateStatus {
        case noUpdates
        case checking
        case available(version: String, publishedDate: Date?, releaseNotes: String?)
        case error(String)

        static func == (lhs: UpdateStatus, rhs: UpdateStatus) -> Bool {
            switch (lhs, rhs) {
            case (.noUpdates, .noUpdates): true
            case (.checking, .checking): true
            case let (.available(lVersion, _, _), .available(rVersion, _, _)): lVersion == rVersion
            case let (.error(lMsg), .error(rMsg)): lMsg == rMsg
            default: false
            }
        }
    }

    var anUpdateIsAvailable: Bool {
        false
    }

    override init() {
        currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        super.init()
    }

    func checkForUpdates() {}

    func toggleAutomaticChecks() {}
}
