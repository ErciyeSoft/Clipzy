import AppKit
import KitziCore
import Defaults

/// Lets other modules (e.g. the Kitzi Dock) show DockDoor window previews anchored to their own icons.
final class DockPreviewService: WindowPreviewProviding {
    private var requestID = UUID()

    func showPreviews(for app: NSRunningApplication, iconFrame: CGRect, edge: ScreenEdge) {
        guard Defaults[.enableDockPreviews], !WindowUtil.isAppFiltered(app) else { return }
        let request = UUID()
        requestID = request

        Task { @MainActor [weak self] in
            guard let coordinator = SharedPreviewWindowCoordinator.activeInstance else { return }
            var windows = (try? await WindowUtil.getActiveWindows(of: app, context: .dockPreview)) ?? []
            guard let self, self.requestID == request else { return }

            if Defaults[.showWindowsFromCurrentSpaceOnly] {
                windows = WindowUtil.filterWindowsByCurrentSpace(windows)
            }
            if !Defaults[.includeHiddenWindowsInDockPreview] {
                windows = windows.filter { !$0.isHidden && !$0.isMinimized }
            }
            if windows.isEmpty, Defaults[.showWindowlessAppsInDockPreview] {
                windows = [WindowInfo.windowlessEntry(for: app)]
            }
            guard !windows.isEmpty else {
                coordinator.hideWindow()
                return
            }

            let anchor = CGPoint(x: iconFrame.midX, y: iconFrame.midY)
            let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main ?? NSScreen.screens[0]
            let position: DockPosition = switch edge {
            case .bottom: .bottom
            case .left: .left
            case .right: .right
            }
            coordinator.showWindow(
                appName: app.localizedName ?? "Unknown",
                windows: windows,
                mouseLocation: NSEvent.mouseLocation,
                mouseScreen: screen,
                dockItemElement: nil,
                overrideDelay: false,
                onWindowTap: nil,
                bundleIdentifier: app.bundleIdentifier,
                bypassDockMouseValidation: true,
                dockPositionOverride: position,
                dockItemFrameOverride: iconFrame
            )
        }
    }

    func hidePreviews() {
        requestID = UUID()
        guard let coordinator = SharedPreviewWindowCoordinator.activeInstance,
              !coordinator.mouseIsWithinPreviewWindow else { return }
        coordinator.hideWindow()
    }

    var isPointerInPreviews: Bool {
        SharedPreviewWindowCoordinator.activeInstance?.mouseIsWithinPreviewWindow ?? false
    }
}
