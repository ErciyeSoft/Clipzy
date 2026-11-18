import Foundation
import UniformTypeIdentifiers

/// What kind of file something is, for picking the actions that apply.
nonisolated enum FileKind: Sendable {
  case image, pdf, video, audio, document, archive, other

  init(url: URL) {
    let type = UTType(filenameExtension: url.pathExtension.lowercased())
    if url.pathExtension.lowercased() == "pdf" { self = .pdf }
    else if type?.conforms(to: .image) == true { self = .image }
    else if type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true { self = .video }
    else if type?.conforms(to: .audio) == true { self = .audio }
    else if ["zip"].contains(url.pathExtension.lowercased()) { self = .archive }
    else if ["doc", "docx", "rtf", "rtfd", "html", "htm", "txt", "text", "md", "odt", "webarchive", "wordml"]
      .contains(url.pathExtension.lowercased()) { self = .document }
    else { self = .other }
  }
}

nonisolated enum ImageFormat: String, CaseIterable, Identifiable, Sendable {
  case jpeg, png, heic, tiff, gif, bmp, pdf
  var id: String { rawValue }
  var title: String { self == .jpeg ? "JPEG" : rawValue.uppercased() }
  var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
  var utType: UTType {
    switch self {
    case .jpeg: .jpeg
    case .png: .png
    case .heic: .heic
    case .tiff: .tiff
    case .gif: .gif
    case .bmp: .bmp
    case .pdf: .pdf
    }
  }
  var isLossy: Bool { self == .jpeg || self == .heic }
}

nonisolated enum VideoFormat: String, CaseIterable, Identifiable, Sendable {
  case mp4, mov
  var id: String { rawValue }
  var title: String { self == .mp4 ? "MP4 (H.264)" : "MOV (HEVC)" }
}

nonisolated enum VideoQuality: String, CaseIterable, Identifiable, Sendable {
  case original, p1080, p720, p540
  var id: String { rawValue }
  var title: String {
    switch self {
    case .original: String(localized: "Original")
    case .p1080: "1080p"
    case .p720: "720p"
    case .p540: "540p"
    }
  }
}

nonisolated enum AudioFormat: String, CaseIterable, Identifiable, Sendable {
  case m4a, wav, aiff
  var id: String { rawValue }
  var title: String { rawValue.uppercased() }
}

nonisolated enum DocumentFormat: String, CaseIterable, Identifiable, Sendable {
  case pdf, docx, rtf, html, txt, odt
  var id: String { rawValue }
  var title: String { rawValue.uppercased() }
}

/// Settings of the chosen action.
nonisolated struct ConversionOptions: Sendable {
  var imageFormat: ImageFormat = .jpeg
  var quality: Double = 0.85
  /// Longest side in pixels; nil keeps the original size.
  var maxPixels: Int?
  var stripMetadata = false
  var videoFormat: VideoFormat = .mp4
  var videoQuality: VideoQuality = .p1080
  var audioFormat: AudioFormat = .m4a
  var documentFormat: DocumentFormat = .pdf
  var pageImageFormat: ImageFormat = .png
  var gifWidth: Int = 640
}

/// Everything the converter can do, all with macOS frameworks and built-in tools.
nonisolated enum ConversionAction: String, CaseIterable, Identifiable, Sendable {
  case convertImage, imagesToPDF, readQRCode
  case mergePDFs, splitPDF, pdfToImages
  case convertVideo, extractAudio, removeAudio, videoToGIF, videoFrames
  case convertAudio
  case convertDocument
  case createZip, extractZip

  var id: String { rawValue }

  var title: String {
    switch self {
    case .convertImage: String(localized: "Convert Images")
    case .imagesToPDF: String(localized: "Images to One PDF")
    case .readQRCode: String(localized: "Read QR Codes")
    case .mergePDFs: String(localized: "Merge PDFs")
    case .splitPDF: String(localized: "Split PDF into Pages")
    case .pdfToImages: String(localized: "PDF Pages to Images")
    case .convertVideo: String(localized: "Convert or Compress Video")
    case .extractAudio: String(localized: "Extract Audio")
    case .removeAudio: String(localized: "Remove Audio")
    case .videoToGIF: String(localized: "Video to GIF")
    case .videoFrames: String(localized: "Save Video Frames")
    case .convertAudio: String(localized: "Convert Audio")
    case .convertDocument: String(localized: "Convert Documents")
    case .createZip: String(localized: "Compress to ZIP")
    case .extractZip: String(localized: "Extract ZIP")
    }
  }

  var systemImage: String {
    switch self {
    case .convertImage: "photo.on.rectangle.angled"
    case .imagesToPDF: "doc.richtext"
    case .readQRCode: "qrcode.viewfinder"
    case .mergePDFs: "doc.on.doc"
    case .splitPDF: "scissors"
    case .pdfToImages: "photo.stack"
    case .convertVideo: "film"
    case .extractAudio: "waveform"
    case .removeAudio: "speaker.slash"
    case .videoToGIF: "photo.artframe"
    case .videoFrames: "square.grid.3x3"
    case .convertAudio: "music.note"
    case .convertDocument: "doc.text"
    case .createZip: "archivebox"
    case .extractZip: "archivebox.fill"
    }
  }

  /// Actions that work on every one of the given files.
  static func available(for files: [URL]) -> [ConversionAction] {
    guard !files.isEmpty else { return [] }
    let kinds = Set(files.map(FileKind.init))
    var actions: [ConversionAction] = []
    if kinds == [.image] { actions += [.convertImage, .imagesToPDF, .readQRCode] }
    if kinds == [.pdf] {
      if files.count > 1 { actions.append(.mergePDFs) }
      actions += [.splitPDF, .pdfToImages]
    }
    if kinds.isSubset(of: [.pdf, .image]), kinds.count == 2 { actions.append(.mergePDFs) }
    if kinds == [.video] { actions += [.convertVideo, .extractAudio, .removeAudio, .videoToGIF, .videoFrames] }
    if kinds == [.audio] { actions.append(.convertAudio) }
    if kinds == [.document] { actions.append(.convertDocument) }
    if kinds == [.archive] { actions.append(.extractZip) }
    actions.append(.createZip)
    return actions
  }
}

nonisolated enum ConversionError: LocalizedError {
  case unreadable(String)
  case failed(String)

  var errorDescription: String? {
    switch self {
    case let .unreadable(name): String(localized: "Couldn't read \(name).")
    case let .failed(message): message
    }
  }
}
