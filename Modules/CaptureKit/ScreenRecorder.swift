import AVFoundation
import ImageIO
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers

enum RecordingError: Error {
  case cannotStart
  case noFrames
}

/// Records part of a screen into an H.264 MP4. Frames arrive on a private queue;
/// the writer is only touched there after `start` returns.
nonisolated final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
  let outputURL: URL
  private let queue = DispatchQueue(label: "com.erciyesoft.Kitzi.recorder")
  private var stream: SCStream?
  private var writer: AVAssetWriter?
  private var input: AVAssetWriterInput?
  private var sessionStarted = false

  init(outputURL: URL) {
    self.outputURL = outputURL
  }

  /// `sourceRect` is in the display's local points (top-left origin); `scale` is its pixels per point.
  func start(displayID: CGDirectDisplayID, sourceRect local: CGRect, scale: CGFloat, showsCursor: Bool) async throws {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
      throw GrabError.noDisplay
    }
    // H.264 wants even dimensions.
    let width = max(2, Int((local.width * scale).rounded()) & ~1)
    let height = max(2, Int((local.height * scale).rounded()) & ~1)

    let configuration = SCStreamConfiguration()
    configuration.sourceRect = local
    configuration.width = width
    configuration.height = height
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
    configuration.showsCursor = showsCursor
    configuration.pixelFormat = kCVPixelFormatType_32BGRA
    configuration.queueDepth = 6

    try? FileManager.default.removeItem(at: outputURL)
    let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: width,
      AVVideoHeightKey: height,
      AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: width * height * 6,
        AVVideoMaxKeyFrameIntervalKey: 60,
      ],
    ])
    input.expectsMediaDataInRealTime = true
    guard writer.canAdd(input) else { throw RecordingError.cannotStart }
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? RecordingError.cannotStart }
    self.writer = writer
    self.input = input

    let stream = SCStream(
      filter: ScreenGrabber.filterExcludingKitzi(display: display, content: content),
      configuration: configuration,
      delegate: self
    )
    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
    try await stream.startCapture()
    self.stream = stream
  }

  func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
    guard type == .screen, sampleBuffer.isValid, let writer, let input,
          let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
          let rawStatus = attachments.first?[.status] as? Int,
          SCFrameStatus(rawValue: rawStatus) == .complete else {
      return
    }
    if !sessionStarted {
      writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
      sessionStarted = true
    }
    if input.isReadyForMoreMediaData {
      input.append(sampleBuffer)
    }
  }

  /// Stops capturing and finishes the file.
  func stop() async throws -> URL {
    // Frames only arrive when the screen changes; end the video at the moment of stopping
    // so a still screen at the end isn't cut off. Stream timestamps use the host clock.
    let stopTime = CMClockGetTime(CMClockGetHostTimeClock())
    try? await stream?.stopCapture()
    stream = nil
    // Let any frame already queued finish appending first.
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      queue.async { continuation.resume() }
    }
    guard let writer, let input, sessionStarted else {
      self.writer?.cancelWriting()
      throw RecordingError.noFrames
    }
    input.markAsFinished()
    writer.endSession(atSourceTime: stopTime)
    await writer.finishWriting()
    if writer.status == .failed {
      throw writer.error ?? RecordingError.noFrames
    }
    return outputURL
  }
}

/// Turns a recording into a looping GIF.
enum GIFMaker {
  static func convert(_ video: URL, to gif: URL, framesPerSecond: Double = 12, maxWidth: CGFloat = 960) async throws {
    let asset = AVURLAsset(url: video)
    let duration = try await asset.load(.duration).seconds
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: maxWidth, height: maxWidth * 4)
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero

    let times = stride(from: 0.0, to: max(duration, 0.1), by: 1 / framesPerSecond)
      .map { CMTime(seconds: $0, preferredTimescale: 600) }
    guard let destination = CGImageDestinationCreateWithURL(gif as CFURL, UTType.gif.identifier as CFString,
                                                            times.count, nil) else {
      throw RecordingError.cannotStart
    }
    CGImageDestinationSetProperties(destination, [
      kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
    ] as CFDictionary)
    let frameProperties = [
      kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / framesPerSecond],
    ] as CFDictionary
    for await result in generator.images(for: times) {
      if let image = try? result.image {
        CGImageDestinationAddImage(destination, image, frameProperties)
      }
    }
    guard CGImageDestinationFinalize(destination) else { throw RecordingError.noFrames }
  }
}
