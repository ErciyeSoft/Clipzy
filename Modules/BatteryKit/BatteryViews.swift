import SwiftUI

/// Small battery shape, filled to the level (red when low).
struct BatteryGlyph: View {
  let percent: Int
  let isCharging: Bool
  let isLow: Bool

  var body: some View {
    HStack(spacing: 1) {
      ZStack(alignment: .leading) {
        RoundedRectangle(cornerRadius: 3.5)
          .strokeBorder(.secondary, lineWidth: 1)
          .frame(width: 26, height: 13)
        RoundedRectangle(cornerRadius: 2)
          .fill(isLow ? Color.red : Color.green)
          .frame(width: max(2, 22 * CGFloat(percent) / 100), height: 9)
          .padding(.leading, 2)
        if isCharging {
          Image(systemName: "bolt.fill")
            .font(.system(size: 8, weight: .bold))
            .frame(width: 26)
        }
      }
      RoundedRectangle(cornerRadius: 1)
        .fill(.secondary)
        .frame(width: 2, height: 5)
    }
    .accessibilityHidden(true)
  }
}

/// What sits in the menu bar: device icons with their levels.
struct BatteryMenuBarLabel: View {
  let devices: [BatteryDevice]
  let showPercent: Bool
  let threshold: Int

  var body: some View {
    HStack(spacing: 8) {
      if devices.isEmpty {
        Image(systemName: "battery.75percent")
      }
      ForEach(devices) { device in
        HStack(spacing: 3) {
          Image(systemName: device.kind.systemImage)
          if showPercent {
            Text(device.formattedPercent)
              .monospacedDigit()
          }
        }
        .foregroundStyle(device.percent <= threshold && !device.isCharging ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
      }
    }
    .font(.system(size: 12, weight: .medium))
    .padding(.horizontal, 4)
    .fixedSize()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// The popover list shown when the menu bar item is clicked.
struct BatteryListView: View {
  let monitor: BatteryMonitor
  let threshold: Int
  let openSettings: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if monitor.devices.isEmpty {
        Text("No battery-powered devices found yet.")
          .foregroundStyle(.secondary)
          .padding(.vertical, 12)
      }
      ForEach(Array(monitor.devices.enumerated()), id: \.element.id) { index, device in
        if index > 0 {
          Divider()
        }
        HStack(spacing: 12) {
          Image(systemName: device.kind.systemImage)
            .font(.system(size: 15))
            .foregroundStyle(.secondary)
            .frame(width: 26)
          Text(device.name)
            .lineLimit(1)
            .truncationMode(.middle)
          Spacer(minLength: 12)
          Text(device.formattedPercent)
            .monospacedDigit()
            .foregroundStyle(.secondary)
          BatteryGlyph(
            percent: device.percent,
            isCharging: device.isCharging,
            isLow: device.percent <= threshold && !device.isCharging
          )
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
      }
      Divider()
        .padding(.top, 2)
      Button(action: openSettings) {
        Text("Battery Settings…")
      }
      .buttonStyle(.link)
      .padding(.top, 8)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .frame(width: 320)
  }
}

struct BatterySettingsView: View {
  let monitor: BatteryMonitor

  @AppStorage(BatteryPrefs.enabledKey) private var enabled = true
  @AppStorage(BatteryPrefs.showPercentKey) private var showPercent = true
  @AppStorage(BatteryPrefs.includeMacKey) private var includeMac = false
  @AppStorage(BatteryPrefs.lowAlertKey) private var lowAlert = true
  @AppStorage(BatteryPrefs.thresholdKey) private var threshold = 20
  @AppStorage(BatteryPrefs.hiddenDevicesKey) private var hiddenDevices = ""

  var body: some View {
    Form {
      Section {
        Toggle("Show battery levels in the menu bar", isOn: $enabled)
        Toggle("Show percentages", isOn: $showPercent)
          .disabled(!enabled)
        Toggle("Also show this Mac in the menu bar", isOn: $includeMac)
          .disabled(!enabled)
      }

      Section {
        if monitor.devices.isEmpty {
          Text("No battery-powered devices found yet.")
            .foregroundStyle(.secondary)
        }
        ForEach(monitor.devices.filter { $0.kind != .mac }) { device in
          Toggle(isOn: shownBinding(for: device)) {
            HStack {
              Label(device.name, systemImage: device.kind.systemImage)
              Spacer()
              Text(device.formattedPercent)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
          }
        }
      } header: {
        Text("Devices in the menu bar")
      } footer: {
        Text("Bluetooth keyboards, mice and headphones appear here once Kitzi can read their battery level.")
          .foregroundStyle(.secondary)
      }
      .disabled(!enabled)

      Section {
        Toggle("Notify me when a device is low", isOn: $lowAlert)
        Stepper(value: $threshold, in: 5...50, step: 5) {
          HStack {
            Text("Low battery level")
            Spacer()
            Text((Double(threshold) / 100).formatted(.percent.precision(.fractionLength(0))))
              .monospacedDigit()
              .foregroundStyle(.secondary)
          }
        }
      } header: {
        Text("Low battery")
      }
    }
    .formStyle(.grouped)
  }

  private func shownBinding(for device: BatteryDevice) -> Binding<Bool> {
    Binding(
      get: { !hiddenDevices.split(separator: "\n").contains(Substring(device.id)) },
      set: { shown in
        var ids = Set(hiddenDevices.split(separator: "\n").map(String.init))
        if shown { ids.remove(device.id) } else { ids.insert(device.id) }
        hiddenDevices = ids.sorted().joined(separator: "\n")
      }
    )
  }
}
