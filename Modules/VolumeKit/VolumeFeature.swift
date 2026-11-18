import AppKit
import KitziCore
import SwiftUI

/// Public entry point of the volume mixer: per-app volume and mute from the menu bar.
public final class VolumeFeature: KitziFeature {
  static let pageID = "volume.general"
  static let enabledKey = "volume.enabled"

  private let mixer = VolumeMixer()
  private var statusItem: NSStatusItem?
  private let popover = NSPopover()
  private var defaultsObserver: NSObjectProtocol?
  private var refreshTimer: Task<Void, Never>?

  public init() {
    UserDefaults.standard.register(defaults: [Self.enabledKey: true])
  }

  public func applicationDidFinishLaunching() {
    defaultsObserver = NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.applyPreferences() }
    }
    applyPreferences()
  }

  public func applicationWillTerminate() {
    mixer.stop()
  }

  public var settingsGroups: [SettingsGroup] {
    [
      SettingsGroup(
        id: "volume",
        title: String(localized: "Volume"),
        pages: [
          SettingsPage(
            id: Self.pageID,
            title: String(localized: "Volume Mixer"),
            subtitle: String(localized: "Set the volume of each app separately"),
            systemImage: "slider.horizontal.3"
          ) { [mixer] in
            VolumeSettingsView(reset: { mixer.resetAll() })
          }
        ]
      )
    ]
  }

  private func applyPreferences() {
    let enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
    if enabled {
      if !mixer.isRunning { mixer.start() }
      if statusItem == nil { statusItem = makeStatusItem() }
    } else {
      if mixer.isRunning { mixer.stop() }
      if let statusItem {
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
      }
      popover.performClose(nil)
    }
  }

  private func makeStatusItem() -> NSStatusItem {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.autosaveName = "KitziVolume"
    let icon = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: String(localized: "Volume Mixer"))?
      .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
    icon?.isTemplate = true
    item.button?.image = icon
    item.button?.target = self
    item.button?.action = #selector(togglePopover(_:))
    popover.behavior = .transient
    return item
  }

  @objc private func togglePopover(_ sender: NSStatusBarButton) {
    if popover.isShown {
      popover.performClose(sender)
      return
    }
    mixer.refresh()
    let controller = NSHostingController(rootView: MixerView(mixer: mixer) { [weak self] in
      self?.popover.performClose(nil)
      KitziHost.openSettings(Self.pageID)
    })
    // Size before showing so the popover opens right under the menu bar.
    controller.sizingOptions = .preferredContentSize
    popover.contentViewController = controller
    popover.contentSize = controller.view.fittingSize
    popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    // Keep "playing" indicators current while the mixer is open.
    refreshTimer?.cancel()
    refreshTimer = Task { [weak self] in
      while !Task.isCancelled, self?.popover.isShown == true {
        try? await Task.sleep(for: .seconds(1.5))
        self?.mixer.refresh()
      }
    }
  }
}

// MARK: - Views

struct MixerView: View {
  let mixer: VolumeMixer
  let openSettings: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Volume Mixer")
        .font(.headline)

      HStack(spacing: 10) {
        Button(action: mixer.toggleOutputMute) {
          Image(systemName: mixer.outputMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            .frame(width: 26)
        }
        .buttonStyle(.plain)
        .help(String(localized: "Mute"))
        VStack(alignment: .leading, spacing: 2) {
          Text(mixer.outputName.isEmpty ? String(localized: "Output") : mixer.outputName)
            .font(.caption)
            .foregroundStyle(.secondary)
          Slider(value: Binding(get: { Double(mixer.outputVolume) },
                                set: { mixer.setOutputVolume(Float($0)) }))
            .disabled(!mixer.outputHasVolume)
        }
        percent(mixer.outputVolume)
      }

      Divider()

      if mixer.apps.isEmpty {
        Text("No apps are using audio right now.")
          .foregroundStyle(.secondary)
          .padding(.vertical, 6)
      }
      ForEach(mixer.apps) { app in
        AppVolumeRow(app: app, mixer: mixer)
      }

      if let problem = mixer.problem {
        VStack(alignment: .leading, spacing: 6) {
          Text(problem)
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
          Button("Open Privacy Settings") {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
          }
          .buttonStyle(.link)
        }
      }

      Divider()
      Button("Volume Settings…", action: openSettings)
        .buttonStyle(.link)
    }
    .padding(14)
    .frame(width: 360)
  }
}

private struct AppVolumeRow: View {
  let app: MixerApp
  let mixer: VolumeMixer

  var body: some View {
    HStack(spacing: 10) {
      Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
        .resizable()
        .frame(width: 26, height: 26)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 4) {
          Text(app.name)
            .lineLimit(1)
          if app.isPlaying {
            Image(systemName: "waveform")
              .font(.caption2)
              .foregroundStyle(.secondary)
              .accessibilityLabel(String(localized: "Playing"))
          }
        }
        .font(.callout)
        Slider(value: Binding(get: { Double(app.volume) },
                              set: { mixer.setVolume(Float($0), for: app.id) }))
          .disabled(app.isMuted)
      }
      Button {
        mixer.toggleMute(for: app.id)
      } label: {
        Image(systemName: app.isMuted ? "speaker.slash.fill" : "speaker.wave.2")
          .foregroundStyle(app.isMuted ? Color.red : Color.secondary)
          .frame(width: 22)
      }
      .buttonStyle(.plain)
      .help(app.isMuted ? String(localized: "Unmute") : String(localized: "Mute"))
      percent(app.isMuted ? 0 : app.volume)
    }
  }
}

private func percent(_ value: Float) -> some View {
  Text((Double(value)).formatted(.percent.precision(.fractionLength(0))))
    .font(.caption.monospacedDigit())
    .foregroundStyle(.secondary)
    .frame(width: 40, alignment: .trailing)
}

struct VolumeSettingsView: View {
  let reset: () -> Void
  @AppStorage(VolumeFeature.enabledKey) private var enabled = true

  var body: some View {
    Form {
      Section {
        Toggle("Show the volume mixer in the menu bar", isOn: $enabled)
      } footer: {
        Text("Lower or mute apps like Teams or Chrome on their own. Kitzi takes the app's sound and plays it back at the level you set, so macOS asks once for permission to record audio. Apps at 100% play untouched.")
          .foregroundStyle(.secondary)
      }
      Section {
        LabeledContent("App volumes") {
          Button("Reset All to 100%", action: reset)
        }
      }
      .disabled(!enabled)
    }
    .formStyle(.grouped)
  }
}
