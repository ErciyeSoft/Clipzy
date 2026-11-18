import AppKit
@preconcurrency import AVFoundation
import CoreImage
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Runs an action over files and returns what it produced. Everything here uses macOS
/// frameworks or tools that ship with macOS; nothing is downloaded.
nonisolated enum ConversionRunner {
  struct Result: Sendable {
    var outputs: [URL] = []
    /// Text found by "Read QR Codes".
    var text: String?
  }

  static func run(_ action: ConversionAction, files: [URL], options: ConversionOptions, outputFolder: URL?,
                  progress: @escaping @Sendable (Double) -> Void) async throws -> Result {
    var result = Result()
    func destination(for file: URL, extension ext: String, suffix: String = "") -> URL {
      Output.uniqueURL(in: outputFolder ?? file.deletingLastPathComponent(),
                       name: file.deletingPathExtension().lastPathComponent + suffix, extension: ext)
    }

    switch action {
    case .convertImage:
      for (index, file) in files.enumerated() {
        let out = destination(for: file, extension: options.imageFormat.fileExtension)
        try ImageEngine.convert(file, to: out, options: options)
        result.outputs.append(out)
        progress(Double(index + 1) / Double(files.count))
      }
    case .imagesToPDF, .mergePDFs:
      let out = destination(for: files[0], extension: "pdf", suffix: files.count > 1 ? " (\(String(localized: "merged")))" : "")
      try PDFEngine.combine(files, into: out)
      result.outputs.append(out)
    case .readQRCode:
      result.text = try files.flatMap { try ImageEngine.qrCodes(in: $0) }.joined(separator: "\n")
    case .splitPDF:
      for file in files {
        result.outputs += try PDFEngine.split(file, folder: Output.folder(next: file, outputFolder: outputFolder,
                                                                          suffix: String(localized: "Pages")))
      }
    case .pdfToImages:
      for file in files {
        result.outputs += try PDFEngine.images(of: file, format: options.pageImageFormat,
                                               folder: Output.folder(next: file, outputFolder: outputFolder,
                                                                     suffix: String(localized: "Images")))
      }
    case .convertVideo:
      for (index, file) in files.enumerated() {
        let out = destination(for: file, extension: options.videoFormat.rawValue,
                              suffix: file.pathExtension.lowercased() == options.videoFormat.rawValue ? " (\(options.videoQuality.title))" : "")
        try await MediaEngine.convertVideo(file, to: out, format: options.videoFormat, quality: options.videoQuality)
        result.outputs.append(out)
        progress(Double(index + 1) / Double(files.count))
      }
    case .extractAudio:
      for file in files {
        let out = destination(for: file, extension: "m4a")
        try await MediaEngine.extractAudio(file, to: out)
        result.outputs.append(out)
      }
    case .removeAudio:
      for file in files {
        let out = destination(for: file, extension: file.pathExtension.lowercased() == "mp4" ? "mp4" : "mov",
                              suffix: " (\(String(localized: "no audio")))")
        try await MediaEngine.removeAudio(file, to: out)
        result.outputs.append(out)
      }
    case .videoToGIF:
      for file in files {
        let out = destination(for: file, extension: "gif")
        try await MediaEngine.gif(from: file, to: out, width: options.gifWidth)
        result.outputs.append(out)
      }
    case .videoFrames:
      for file in files {
        result.outputs += try await MediaEngine.frames(of: file, count: 12,
                                                       folder: Output.folder(next: file, outputFolder: outputFolder,
                                                                             suffix: String(localized: "Frames")))
      }
    case .convertAudio:
      for (index, file) in files.enumerated() {
        let out = destination(for: file, extension: options.audioFormat.rawValue)
        try MediaEngine.convertAudio(file, to: out, format: options.audioFormat)
        result.outputs.append(out)
        progress(Double(index + 1) / Double(files.count))
      }
    case .convertDocument:
      for file in files {
        let out = destination(for: file, extension: options.documentFormat.rawValue)
        if options.documentFormat == .pdf {
          try await MainActor.run { try DocumentEngine.pdf(from: file, to: out) }
        } else {
          try DocumentEngine.convert(file, to: out, format: options.documentFormat)
        }
        result.outputs.append(out)
      }
    case .createZip:
      let name = files.count == 1 ? files[0].deletingPathExtension().lastPathComponent : String(localized: "Archive")
      let out = Output.uniqueURL(in: outputFolder ?? files[0].deletingLastPathComponent(), name: name, extension: "zip")
      try ArchiveEngine.zip(files, to: out)
      result.outputs.append(out)
    case .extractZip:
      for file in files {
        let folder = Output.folder(next: file, outputFolder: outputFolder, suffix: "")
        try ArchiveEngine.unzip(file, to: folder)
        result.outputs.append(folder)
      }
    }
    progress(1)
    return result
  }
}

// MARK: - Output naming

nonisolated enum Output {
  /// `name.ext`, or `name 2.ext`, `name 3.ext`… if taken.
  static func uniqueURL(in folder: URL, name: String, extension ext: String) -> URL {
    var url = folder.appendingPathComponent(name).appendingPathExtension(ext)
    var counter = 2
    while FileManager.default.fileExists(atPath: url.path) {
      url = folder.appendingPathComponent("\(name) \(counter)").appendingPathExtension(ext)
      counter += 1
    }
    return url
  }

  /// A new folder next to the file (or in the chosen folder) named after it.
  static func folder(next file: URL, outputFolder: URL?, suffix: String) -> URL {
    let base = file.deletingPathExtension().lastPathComponent + (suffix.isEmpty ? "" : " \(suffix)")
    var url = (outputFolder ?? file.deletingLastPathComponent()).appendingPathComponent(base, isDirectory: true)
    var counter = 2
    while FileManager.default.fileExists(atPath: url.path) {
      url = (outputFolder ?? file.deletingLastPathComponent()).appendingPathComponent("\(base) \(counter)", isDirectory: true)
      counter += 1
    }
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}

// MARK: - Images

nonisolated enum ImageEngine {
  static func convert(_ file: URL, to out: URL, options: ConversionOptions) throws {
    guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else {
      throw ConversionError.unreadable(file.lastPathComponent)
    }
    // A thumbnail at full size applies the EXIF orientation and can scale down in one go.
    var thumbnailOptions: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
    let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
    thumbnailOptions[kCGImageSourceThumbnailMaxPixelSize] = options.maxPixels.map { min($0, max(width, height)) }
      ?? max(width, height, 1)
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
      throw ConversionError.unreadable(file.lastPathComponent)
    }

    if options.imageFormat == .pdf {
      try PDFEngine.combineImages([image], into: out)
      return
    }
    guard let destination = CGImageDestinationCreateWithURL(out as CFURL, options.imageFormat.utType.identifier as CFString,
                                                            1, nil) else {
      throw ConversionError.failed(String(localized: "This Mac can't write \(options.imageFormat.title) images."))
    }
    var imageProperties: [CFString: Any] = [:]
    if !options.stripMetadata {
      for key in [kCGImagePropertyExifDictionary, kCGImagePropertyIPTCDictionary, kCGImagePropertyGPSDictionary,
                  kCGImagePropertyTIFFDictionary] {
        if let value = properties[key] { imageProperties[key] = value }
      }
    }
    imageProperties[kCGImagePropertyOrientation] = 1
    if options.imageFormat.isLossy {
      imageProperties[kCGImageDestinationLossyCompressionQuality] = options.quality
    }
    CGImageDestinationAddImage(destination, image, imageProperties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
      throw ConversionError.failed(String(localized: "Couldn't write \(out.lastPathComponent)."))
    }
  }

  static func qrCodes(in file: URL) throws -> [String] {
    guard let image = CIImage(contentsOf: file) else { throw ConversionError.unreadable(file.lastPathComponent) }
    let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                              options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
    return (detector?.features(in: image) ?? []).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
  }
}

// MARK: - PDF

nonisolated enum PDFEngine {
  /// PDFs and images, in order, into one PDF.
  static func combine(_ files: [URL], into out: URL) throws {
    let document = PDFDocument()
    for file in files {
      if file.pathExtension.lowercased() == "pdf" {
        guard let pdf = PDFDocument(url: file) else { throw ConversionError.unreadable(file.lastPathComponent) }
        for index in 0..<pdf.pageCount {
          if let page = pdf.page(at: index) { document.insert(page, at: document.pageCount) }
        }
      } else {
        guard let image = NSImage(contentsOf: file), let page = PDFPage(image: image) else {
          throw ConversionError.unreadable(file.lastPathComponent)
        }
        document.insert(page, at: document.pageCount)
      }
    }
    guard document.write(to: out) else { throw ConversionError.failed(String(localized: "Couldn't write \(out.lastPathComponent).")) }
  }

  static func combineImages(_ images: [CGImage], into out: URL) throws {
    let document = PDFDocument()
    for image in images {
      let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
      if let page = PDFPage(image: nsImage) { document.insert(page, at: document.pageCount) }
    }
    guard document.write(to: out) else { throw ConversionError.failed(String(localized: "Couldn't write \(out.lastPathComponent).")) }
  }

  static func split(_ file: URL, folder: URL) throws -> [URL] {
    guard let pdf = PDFDocument(url: file) else { throw ConversionError.unreadable(file.lastPathComponent) }
    let base = file.deletingPathExtension().lastPathComponent
    return try (0..<pdf.pageCount).compactMap { index in
      guard let page = pdf.page(at: index) else { return nil }
      let single = PDFDocument()
      single.insert(page, at: 0)
      let out = folder.appendingPathComponent(String(format: "%@ %03d.pdf", base, index + 1))
      guard single.write(to: out) else { throw ConversionError.failed(String(localized: "Couldn't write \(out.lastPathComponent).")) }
      return out
    }
  }

  /// Each page at 2× (144 dpi).
  static func images(of file: URL, format: ImageFormat, folder: URL) throws -> [URL] {
    guard let pdf = PDFDocument(url: file) else { throw ConversionError.unreadable(file.lastPathComponent) }
    let base = file.deletingPathExtension().lastPathComponent
    var outputs: [URL] = []
    for index in 0..<pdf.pageCount {
      guard let page = pdf.page(at: index) else { continue }
      let bounds = page.bounds(for: .mediaBox)
      let scale: CGFloat = 2
      let width = Int(bounds.width * scale)
      let height = Int(bounds.height * scale)
      guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
      context.setFillColor(CGColor(gray: 1, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))
      context.scaleBy(x: scale, y: scale)
      page.draw(with: .mediaBox, to: context)
      guard let image = context.makeImage() else { continue }
      let out = folder.appendingPathComponent(String(format: "%@ %03d.%@", base, index + 1, format.fileExtension))
      guard let destination = CGImageDestinationCreateWithURL(out as CFURL, format.utType.identifier as CFString, 1, nil) else { continue }
      CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
      if CGImageDestinationFinalize(destination) { outputs.append(out) }
    }
    return outputs
  }
}

// MARK: - Video and audio

nonisolated enum MediaEngine {
  static func convertVideo(_ file: URL, to out: URL, format: VideoFormat, quality: VideoQuality) async throws {
    let asset = AVURLAsset(url: file)
    let preset: String = switch (format, quality) {
    case (.mp4, .original): AVAssetExportPresetHighestQuality
    case (.mp4, .p1080): AVAssetExportPreset1920x1080
    case (.mp4, .p720): AVAssetExportPreset1280x720
    case (.mp4, .p540): AVAssetExportPreset960x540
    case (.mov, .original): AVAssetExportPresetHEVCHighestQuality
    case (.mov, .p1080): AVAssetExportPresetHEVC1920x1080
    case (.mov, .p720), (.mov, .p540): AVAssetExportPresetHEVC1920x1080
    }
    try await export(asset, preset: preset, to: out, type: format == .mp4 ? .mp4 : .mov)
  }

  static func extractAudio(_ file: URL, to out: URL) async throws {
    let asset = AVURLAsset(url: file)
    guard !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else {
      throw ConversionError.failed(String(localized: "\(file.lastPathComponent) has no sound."))
    }
    try await export(asset, preset: AVAssetExportPresetAppleM4A, to: out, type: .m4a)
  }

  static func removeAudio(_ file: URL, to out: URL) async throws {
    let asset = AVURLAsset(url: file)
    let composition = AVMutableComposition()
    let duration = try await asset.load(.duration)
    for track in try await asset.loadTracks(withMediaType: .video) {
      guard let target = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
      try target.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
      target.preferredTransform = try await track.load(.preferredTransform)
    }
    try await export(composition, preset: AVAssetExportPresetPassthrough, to: out, type: out.pathExtension == "mp4" ? .mp4 : .mov)
  }

  static func gif(from file: URL, to out: URL, width: Int) async throws {
    let asset = AVURLAsset(url: file)
    let duration = try await asset.load(.duration).seconds
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: width, height: width * 4)
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    let fps = 12.0
    let times = stride(from: 0.0, to: max(duration, 0.1), by: 1 / fps).map { CMTime(seconds: $0, preferredTimescale: 600) }
    guard let destination = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, times.count, nil) else {
      throw ConversionError.failed(String(localized: "Couldn't write \(out.lastPathComponent)."))
    }
    CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    let frame = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
    for await result in generator.images(for: times) {
      if let image = try? result.image { CGImageDestinationAddImage(destination, image, frame) }
    }
    guard CGImageDestinationFinalize(destination) else {
      throw ConversionError.failed(String(localized: "Couldn't write \(out.lastPathComponent)."))
    }
  }

  static func frames(of file: URL, count: Int, folder: URL) async throws -> [URL] {
    let asset = AVURLAsset(url: file)
    let duration = try await asset.load(.duration).seconds
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    let times = (0..<count).map { CMTime(seconds: duration * (Double($0) + 0.5) / Double(count), preferredTimescale: 600) }
    var outputs: [URL] = []
    let base = file.deletingPathExtension().lastPathComponent
    var index = 0
    for await result in generator.images(for: times) {
      index += 1
      guard let image = try? result.image else { continue }
      let out = folder.appendingPathComponent(String(format: "%@ %02d.png", base, index))
      if let destination = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil) {
        CGImageDestinationAddImage(destination, image, nil)
        if CGImageDestinationFinalize(destination) { outputs.append(out) }
      }
    }
    return outputs
  }

  /// Audio with the built-in `afconvert` tool.
  static func convertAudio(_ file: URL, to out: URL, format: AudioFormat) throws {
    let arguments: [String] = switch format {
    // Variable bit rate at high quality works for any sample rate and channel count.
    case .m4a: ["-f", "m4af", "-d", "aac", "-s", "3", "-u", "vbrq", "100"]
    case .wav: ["-f", "WAVE", "-d", "LEI16"]
    case .aiff: ["-f", "AIFF", "-d", "BEI16"]
    }
    try Tool.run("/usr/bin/afconvert", arguments + [file.path, out.path])
  }

  private static func export(_ asset: AVAsset, preset: String, to out: URL, type: AVFileType) async throws {
    guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
      throw ConversionError.failed(String(localized: "This video can't be converted with that setting."))
    }
    session.shouldOptimizeForNetworkUse = true
    if #available(macOS 15, *) {
      try await session.export(to: out, as: type)
    } else {
      session.outputURL = out
      session.outputFileType = type
      await session.export()
      if let error = session.error { throw error }
    }
  }
}

// MARK: - Documents

nonisolated enum DocumentEngine {
  /// Between Word, RTF, HTML, text and OpenDocument with the built-in `textutil`.
  static func convert(_ file: URL, to out: URL, format: DocumentFormat) throws {
    try Tool.run("/usr/bin/textutil", ["-convert", format.rawValue, "-output", out.path, file.path])
  }

  /// Lays the document out on A4 pages and prints it to PDF.
  @MainActor
  static func pdf(from file: URL, to out: URL) throws {
    let text: NSAttributedString
    do {
      text = try NSAttributedString(url: file, options: [:], documentAttributes: nil)
    } catch {
      throw ConversionError.unreadable(file.lastPathComponent)
    }
    let printInfo = NSPrintInfo()
    printInfo.paperSize = NSSize(width: 595, height: 842)
    printInfo.topMargin = 56
    printInfo.bottomMargin = 56
    printInfo.leftMargin = 56
    printInfo.rightMargin = 56
    printInfo.horizontalPagination = .fit
    printInfo.verticalPagination = .automatic
    printInfo.jobDisposition = .save
    printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = out
    let width = printInfo.paperSize.width - printInfo.leftMargin - printInfo.rightMargin
    let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 1))
    view.textStorage?.setAttributedString(text)
    view.isVerticallyResizable = true
    view.sizeToFit()
    let operation = NSPrintOperation(view: view, printInfo: printInfo)
    operation.showsPrintPanel = false
    operation.showsProgressPanel = false
    guard operation.run() else { throw ConversionError.failed(String(localized: "Couldn't write \(out.lastPathComponent).")) }
  }
}

// MARK: - Archives

nonisolated enum ArchiveEngine {
  static func zip(_ files: [URL], to out: URL) throws {
    if files.count == 1 {
      // --keepParent keeps a folder's own name in the archive; for a single file it would
      // also put the file's parent folder in it.
      let isFolder = (try? files[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
      let keepParent = isFolder ? ["--keepParent"] : []
      try Tool.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc"] + keepParent + [files[0].path, out.path])
    } else {
      // zip needs paths relative to a shared folder to keep a flat, tidy archive.
      let parent = files[0].deletingLastPathComponent()
      try Tool.run("/usr/bin/zip", ["-r", "-q", "-X", out.path] + files.map(\.lastPathComponent), in: parent)
    }
  }

  static func unzip(_ file: URL, to folder: URL) throws {
    try Tool.run("/usr/bin/ditto", ["-x", "-k", file.path, folder.path])
  }
}

nonisolated enum Tool {
  static func run(_ path: String, _ arguments: [String], in directory: URL? = nil) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    if let directory { process.currentDirectoryURL = directory }
    let errors = Pipe()
    process.standardError = errors
    process.standardOutput = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
      throw ConversionError.failed(message.isEmpty ? String(localized: "The conversion failed.") : message)
    }
  }
}
