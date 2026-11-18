import AudioToolbox
import CoreAudio
import Foundation

enum TapError: Error {
  case tapFailed(OSStatus)
  case aggregateFailed(OSStatus)
  case ioFailed(OSStatus)
  case noOutputDevice
}

/// Volume shared with the real-time audio thread. Plain Float stores and loads are
/// atomic on Apple silicon and Intel, which is all the IO block needs.
nonisolated final class GainBox: @unchecked Sendable {
  var value: Float = 1
  /// Incremented by the audio thread; used to check that playback really runs.
  var renderCount = 0
}

/// Takes an app's audio away from the output (muted when tapped), scales it by `gain`
/// and plays it back through the default output device, via a private aggregate device.
nonisolated final class AppTap: @unchecked Sendable {
  let gain = GainBox()
  let processes: Set<AudioObjectID>

  private var tapID = AudioObjectID(kAudioObjectUnknown)
  private var aggregateID = AudioObjectID(kAudioObjectUnknown)
  private var procID: AudioDeviceIOProcID?
  private let queue = DispatchQueue(label: "com.erciyesoft.Kitzi.volume", qos: .userInteractive)

  init(processes: Set<AudioObjectID>, gain: Float) throws {
    self.processes = processes
    self.gain.value = gain

    let output = AudioHAL.defaultOutputDevice
    guard output != kAudioObjectUnknown, let outputUID = AudioHAL.deviceUID(output) else {
      throw TapError.noOutputDevice
    }

    let description = CATapDescription(stereoMixdownOfProcesses: Array(processes))
    description.uuid = UUID()
    description.muteBehavior = .mutedWhenTapped
    description.isPrivate = true
    description.name = "Kitzi volume"
    var status = AudioHardwareCreateProcessTap(description, &tapID)
    guard status == noErr else { throw TapError.tapFailed(status) }

    let aggregate: [String: Any] = [
      kAudioAggregateDeviceNameKey: "Kitzi volume",
      kAudioAggregateDeviceUIDKey: "com.erciyesoft.Kitzi.volume.\(UUID().uuidString)",
      kAudioAggregateDeviceMainSubDeviceKey: outputUID,
      kAudioAggregateDeviceIsPrivateKey: true,
      kAudioAggregateDeviceIsStackedKey: false,
      kAudioAggregateDeviceTapAutoStartKey: true,
      kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
      kAudioAggregateDeviceTapListKey: [[
        kAudioSubTapDriftCompensationKey: true,
        kAudioSubTapUIDKey: description.uuid.uuidString,
      ]],
    ]
    status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
    guard status == noErr else {
      cleanUp()
      throw TapError.aggregateFailed(status)
    }

    // The aggregate's inputs start with the output device's own inputs (a headset mic),
    // then the tap; skip the former.
    let inputOffset = AudioHAL.streamCount(output, scope: kAudioDevicePropertyScopeInput)
    let gainBox = self.gain
    status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, output, _ in
      gainBox.renderCount += 1
      Self.render(input: input, output: output, inputOffset: inputOffset, gain: gainBox.value)
    }
    guard status == noErr, let procID else {
      cleanUp()
      throw TapError.ioFailed(status)
    }
    status = AudioDeviceStart(aggregateID, procID)
    guard status == noErr else {
      cleanUp()
      throw TapError.ioFailed(status)
    }
  }

  deinit {
    cleanUp()
  }

  func stop() {
    cleanUp()
  }

  private func cleanUp() {
    if let procID, aggregateID != kAudioObjectUnknown {
      AudioDeviceStop(aggregateID, procID)
      AudioDeviceDestroyIOProcID(aggregateID, procID)
    }
    procID = nil
    if aggregateID != kAudioObjectUnknown {
      AudioHardwareDestroyAggregateDevice(aggregateID)
      aggregateID = AudioObjectID(kAudioObjectUnknown)
    }
    if tapID != kAudioObjectUnknown {
      AudioHardwareDestroyProcessTap(tapID)
      tapID = AudioObjectID(kAudioObjectUnknown)
    }
  }

  /// Real-time thread: copy the tapped (input) audio to the output, scaled. No allocations.
  private static func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>,
                             inputOffset: Int, gain: Float) {
    let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
    let outputs = UnsafeMutableAudioBufferListPointer(output)
    for out in outputs {
      if let data = out.mData { memset(data, 0, Int(out.mDataByteSize)) }
    }
    guard gain > 0, inputs.count > inputOffset else { return }
    let tapStreams = inputs.count - inputOffset

    for (index, out) in outputs.enumerated() {
      let source = inputs[inputOffset + min(index, tapStreams - 1)]
      guard let src = source.mData?.assumingMemoryBound(to: Float.self),
            let dst = out.mData?.assumingMemoryBound(to: Float.self) else { continue }
      let inChannels = max(1, Int(source.mNumberChannels))
      let outChannels = max(1, Int(out.mNumberChannels))
      let frames = min(Int(source.mDataByteSize) / (4 * inChannels), Int(out.mDataByteSize) / (4 * outChannels))
      for frame in 0..<frames {
        for channel in 0..<outChannels {
          // Extra output channels repeat the last input channel (mono sources go to both sides).
          let sourceChannel = min(channel, inChannels - 1)
          dst[frame * outChannels + channel] = src[frame * inChannels + sourceChannel] * gain
        }
      }
    }
  }
}
