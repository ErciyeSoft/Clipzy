import AppKit
import SwiftUI

struct DisplaySettingsView: View {
  let manager: DisplayManager
  @AppStorage(DisplayPrefs.menuBarKey) private var showInMenuBar = true
  @AppStorage(DisplayPrefs.brightnessKeysKey) private var brightnessKeys = true
  @State private var isTrusted = AXIsProcessTrusted()

  private var externalDisplays: [DisplayInfo] {
    manager.displays.filter {
      !$0.isVirtual && manager.controls[$0.id]?.control != .native
    }
  }

  var body: some View {
    Form {
      Section {
        Toggle("Show displays in the menu bar", isOn: $showInMenuBar)
      } footer: {
        Text("Switch resolution and refresh rate, including HiDPI sizes and modes macOS hides, change brightness, contrast and volume of external monitors, mirror displays and pick the main display. Each resolution or arrangement change asks you to keep it and goes back by itself after 15 seconds.")
          .foregroundStyle(.secondary)
      }

      Section {
        Toggle("Brightness keys change the display under the pointer", isOn: $brightnessKeys)
        if brightnessKeys, !isTrusted {
          LabeledContent("Accessibility") {
            Button("Open Privacy Settings…") {
              if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
              }
            }
          }
        }
      } header: {
        Text("Brightness Keys")
      } footer: {
        Text("With the pointer on an external monitor, the brightness keys change that monitor over DDC/CI or with software dimming; hold ⌥⇧ for smaller steps. Displays macOS controls itself, like the built-in display, work as usual. Kitzi needs Accessibility access for this.")
          .foregroundStyle(.secondary)
      }

      Section {
        if externalDisplays.isEmpty {
          Text("No external monitors are connected.")
            .foregroundStyle(.secondary)
        }
        ForEach(externalDisplays) { display in
          VStack(alignment: .leading, spacing: 4) {
            Picker(selection: Binding(get: { manager.preference(for: display) },
                                      set: { manager.setPreference($0, for: display) })) {
              ForEach(BrightnessPreference.allCases) { preference in
                Text(preference.title).tag(preference)
              }
            } label: {
              Text(display.name)
            }
            HStack(spacing: 6) {
              Text(statusText(for: display))
                .font(.caption)
                .foregroundStyle(.secondary)
              if manager.ddcStatus[display.key] != .noChannel {
                Button("Check Again") { manager.recheckDDC(for: display) }
                  .buttonStyle(.link)
                  .font(.caption)
              }
            }
          }
        }
      } header: {
        Text("Brightness Control")
      } footer: {
        Text("DDC/CI sets the monitor's own backlight; some monitors need DDC/CI turned on in their own menu. Software dimming darkens the picture instead and works on any display. If a monitor doesn't answer DDC/CI, choosing DDC/CI still sends brightness to it without reading it back.")
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .task {
      while !Task.isCancelled {
        isTrusted = AXIsProcessTrusted()
        try? await Task.sleep(for: .seconds(2))
      }
    }
  }

  private func statusText(for display: DisplayInfo) -> String {
    let status = switch manager.ddcStatus[display.key] {
    case .answers: String(localized: "Answers DDC/CI.")
    case .noAnswer: String(localized: "Doesn't answer DDC/CI.")
    case .checking: String(localized: "Checking DDC/CI…")
    case .noChannel, nil: String(localized: "No DDC/CI connection.")
    }
    let now = switch manager.controls[display.id]?.control {
    case .ddc, .ddcWriteOnly: String(localized: "Using DDC/CI.")
    case .software: String(localized: "Using software dimming.")
    default: ""
    }
    return [status, now].filter { !$0.isEmpty }.joined(separator: " ")
  }
}

struct VirtualDisplaysSettingsView: View {
  let store: VirtualDisplayStore

  @State private var name = ""
  @State private var aspect = VirtualAspect.wide16x9
  @State private var largest = VirtualSize(width: 2560, height: 1440)
  @State private var hiDPI = true
  @State private var refreshRate = 60.0

  private var allowedSizes: [VirtualSize] {
    VirtualDisplayConfig.allowedSizes(for: aspect, hiDPI: hiDPI)
  }

  var body: some View {
    Form {
      if !store.isSupported {
        Section {
          Text("This version of macOS doesn't offer virtual displays.")
            .foregroundStyle(.secondary)
        }
      }

      Section {
        if store.configs.isEmpty {
          Text("No virtual displays yet.")
            .foregroundStyle(.secondary)
        }
        ForEach(store.configs) { config in
          HStack(spacing: 10) {
            Image(systemName: "rectangle.dashed")
              .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
              Text(config.name)
              Text(config.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
              if store.failures.contains(config.id) {
                Text("macOS didn't create this display.")
                  .font(.caption)
                  .foregroundStyle(.red)
              }
            }
            Spacer()
            Toggle("Connected", isOn: Binding(get: { config.isConnected },
                                             set: { store.setConnected($0, for: config) }))
              .toggleStyle(.switch)
              .labelsHidden()
              .help(String(localized: "Connected"))
            Button {
              store.remove(config)
            } label: {
              Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Remove"))
          }
        }
      } header: {
        Text("Virtual Displays")
      } footer: {
        Text("A virtual display works like a monitor that isn't there: use it for HiDPI sizes your monitor doesn't offer, screen sharing or testing. For a sharp HiDPI picture on a monitor, make one with the monitor's aspect ratio, then choose ⋯ › Mirror › (the virtual display) for the monitor in the Displays menu. Virtual displays go away when Kitzi quits and come back when it starts.")
          .foregroundStyle(.secondary)
      }

      Section {
        TextField("Name", text: $name, prompt: Text(defaultName))
        Picker("Aspect ratio", selection: $aspect) {
          ForEach(VirtualAspect.allCases) { aspect in
            Text(verbatim: aspect.title).tag(aspect)
          }
        }
        Toggle("HiDPI (Retina) sizes", isOn: $hiDPI)
        Picker("Largest resolution", selection: $largest) {
          ForEach(allowedSizes) { size in
            Text(verbatim: size.title).tag(size)
          }
        }
        Picker("Refresh rate", selection: $refreshRate) {
          ForEach([60.0, 120.0], id: \.self) { rate in
            Text(formattedRefreshRate(rate)).tag(rate)
          }
        }
        LabeledContent {
          Button("Create Virtual Display", action: create)
            .disabled(!store.isSupported)
        } label: {
          EmptyView()
        }
      } header: {
        Text("New Virtual Display")
      } footer: {
        Text("Every smaller size with the same aspect ratio is offered too. HiDPI sizes need twice the pixels, so the largest HiDPI resolution is 3840 points wide.")
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .onChange(of: aspect) { fixLargest() }
    .onChange(of: hiDPI) { fixLargest() }
  }

  private var defaultName: String {
    String(localized: "Virtual Display \(store.configs.count + 1)")
  }

  private func fixLargest() {
    guard !allowedSizes.contains(largest) else { return }
    // Closest width that is allowed for the new aspect ratio.
    largest = allowedSizes.min { abs($0.width - largest.width) < abs($1.width - largest.width) } ?? aspect.sizes[0]
  }

  private func create() {
    fixLargest()
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    store.add(VirtualDisplayConfig(
      name: trimmed.isEmpty ? defaultName : trimmed,
      aspect: aspect,
      largest: largest,
      hiDPI: hiDPI,
      refreshRate: refreshRate
    ))
    name = ""
  }
}
