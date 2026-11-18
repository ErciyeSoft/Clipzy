import AppKit
import AudioToolbox
import CoreAudio
import Observation

/// One app in the mixer (all its audio processes together, e.g. Chrome and its helpers).
struct MixerApp: Identifiable, Equatable {
  /// Path of the app bundle; also the key its level is saved under.
  let id: String
  let name: String
  let url: URL
  let processes: Set<AudioObjectID>
  let isPlaying: Bool
  var volume: Float
  var isMuted: Bool
}

/// Per-app volume like the Windows volume mixer, plus the output device's own volume.
@Observable
final class VolumeMixer {
  private(set) var apps: [MixerApp] = []
  private(set) var outputName = ""
  private(set) var outputVolume: Float = 1
  private(set) var outputMuted = false
  private(set) var outputHasVolume = false
  private(set) var problem: String?

  private struct Level: Codable {
    var volume: Float
    var muted: Bool
  }

  private static let levelsKey = "volume.levels"

  @ObservationIgnored private var levels: [String: Level] = [:]
  @ObservationIgnored private var taps: [String: AppTap] = [:]
  @ObservationIgnored private var listeners: [AudioListenerToken] = []
  @ObservationIgnored private var deviceListeners: [AudioListenerToken] = []

  var isRunning: Bool { !listeners.isEmpty }

  func start() {
    guard listeners.isEmpty else { return }
    if let data = UserDefaults.standard.data(forKey: Self.levelsKey),
       let saved = try? JSONDecoder().decode([String: Level].self, from: data) {
      levels = saved
    }
    listeners = [
      AudioHAL.listen(AudioHAL.system, kAudioHardwarePropertyProcessObjectList) { [weak self] in
        MainActor.assumeIsolated { self?.refresh() }
      },
      AudioHAL.listen(AudioHAL.system, kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
        MainActor.assumeIsolated { self?.outputDeviceChanged() }
      },
    ]
    watchOutputDevice()
    refresh()
  }

  func stop() {
    listeners.removeAll()
    deviceListeners.removeAll()
    taps.removeAll()
  }

  // MARK: - Apps

  func refresh() {
    var groups: [String: (url: URL, processes: Set<AudioObjectID>, playing: Bool)] = [:]
    for process in AudioProcess.all() {
      guard let url = process.appURL else { continue }
      var group = groups[url.path] ?? (url, [], false)
      group.processes.insert(process.objectID)
      group.playing = group.playing || process.isPlaying
      groups[url.path] = group
    }
    apps = groups.map { path, group in
      let level = levels[path] ?? Level(volume: 1, muted: false)
      return MixerApp(
        id: path,
        name: FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: ""),
        url: group.url,
        processes: group.processes,
        isPlaying: group.playing,
        volume: level.volume,
        isMuted: level.muted
      )
    }
    .sorted { ($0.isPlaying ? 0 : 1, $0.name.localizedLowercase) < ($1.isPlaying ? 0 : 1, $1.name.localizedLowercase) }
    applyTaps()
    refreshOutput()
  }

  func setVolume(_ volume: Float, for id: String) {
    var level = levels[id] ?? Level(volume: 1, muted: false)
    level.volume = max(0, min(1, volume))
    update(level, for: id)
  }

  func toggleMute(for id: String) {
    var level = levels[id] ?? Level(volume: 1, muted: false)
    level.muted.toggle()
    update(level, for: id)
  }

  func resetAll() {
    levels.removeAll()
    save()
    taps.removeAll()
    refresh()
  }

  private func update(_ level: Level, for id: String) {
    levels[id] = (level.volume >= 0.999 && !level.muted) ? nil : level
    save()
    if let index = apps.firstIndex(where: { $0.id == id }) {
      apps[index].volume = level.volume
      apps[index].isMuted = level.muted
    }
    applyTaps()
  }

  private static let permissionProblem = String(localized: "Kitzi couldn't change this app's volume. Allow audio recording for Kitzi in System Settings > Privacy & Security.")

  /// A tap mutes the app; if playback through Kitzi doesn't start (for example without the
  /// audio recording permission), remove it right away so the app is never left silent.
  private func verify(_ tap: AppTap, for id: String) {
    Task { [weak self, weak tap] in
      try? await Task.sleep(for: .milliseconds(800))
      guard let self, let tap, taps[id] === tap, tap.gain.renderCount == 0 else { return }
      taps[id] = nil
      problem = Self.permissionProblem
    }
  }

  private func save() {
    UserDefaults.standard.set(try? JSONEncoder().encode(levels), forKey: Self.levelsKey)
  }

  /// Apps at full volume play untouched; the others go through a tap scaled to their level.
  private func applyTaps() {
    let present = Set(apps.map(\.id))
    for id in taps.keys where !present.contains(id) {
      taps[id] = nil
    }
    var failure: String?
    for app in apps {
      let gain: Float = app.isMuted ? 0 : app.volume
      if gain >= 0.999 {
        taps[app.id] = nil
      } else if let tap = taps[app.id], tap.processes == app.processes {
        tap.gain.value = gain
      } else {
        taps[app.id] = nil
        do {
          let tap = try AppTap(processes: app.processes, gain: gain)
          taps[app.id] = tap
          verify(tap, for: app.id)
        } catch {
          failure = Self.permissionProblem
        }
      }
    }
    problem = failure
  }

  // MARK: - Output device

  func setOutputVolume(_ volume: Float) {
    AudioHAL.setMainVolume(AudioHAL.defaultOutputDevice, volume)
    outputVolume = volume
  }

  func toggleOutputMute() {
    let device = AudioHAL.defaultOutputDevice
    AudioHAL.setMuted(device, !outputMuted)
    refreshOutput()
  }

  private func outputDeviceChanged() {
    // Taps play through the device they were built for; rebuild them for the new one.
    taps.removeAll()
    watchOutputDevice()
    refresh()
  }

  private func watchOutputDevice() {
    let device = AudioHAL.defaultOutputDevice
    deviceListeners = [
      AudioHAL.listen(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput) { [weak self] in
        MainActor.assumeIsolated { self?.refreshOutput() }
      },
      AudioHAL.listen(device, kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput) { [weak self] in
        MainActor.assumeIsolated { self?.refreshOutput() }
      },
    ]
  }

  private func refreshOutput() {
    let device = AudioHAL.defaultOutputDevice
    outputName = AudioHAL.deviceName(device) ?? ""
    let volume = AudioHAL.mainVolume(device)
    outputHasVolume = volume != nil
    outputVolume = volume ?? 1
    outputMuted = AudioHAL.isMuted(device)
  }
}
