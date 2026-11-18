import AppKit
import Foundation

// Everything that touches the private MediaRemote framework lives in this file.
//
// Since macOS 15.4 mediaremoted only tells Apple-signed processes what is playing, so the
// now playing info is read by a small JavaScript for Automation script that runs in
// /usr/bin/osascript (an Apple binary) and prints one JSON line whenever something changes.
// boring.notch solves the same problem by loading its own framework into /usr/bin/perl;
// Kitzi ships no prebuilt dylibs, and the script needs none. Commands (play, pause, next,
// seek) still work from inside the app, so they are sent directly.

/// What the reader script prints: one object per line.
nonisolated struct NowPlayingSnapshot: Decodable, Sendable, Equatable {
  enum Kind: String, Decodable, Sendable {
    /// Something has now playing info (it may be paused).
    case playing
    /// Nothing has now playing info.
    case none
    /// Nothing changed; sent every few seconds so the script exits when Kitzi is gone.
    case beat
    /// MediaRemote can't be loaded on this system.
    case unavailable
  }

  var kind: Kind
  var title: String?
  var artist: String?
  var album: String?
  var duration: Double?
  /// Position in seconds at `timestamp`.
  var elapsed: Double?
  var rate: Double?
  /// When `elapsed` was measured, in seconds since 1970.
  var timestamp: Double?
  var playing: Bool?
  var bundleID: String?
  var parentBundleID: String?
  var appName: String?
  var artworkSize: Int?
  /// Base64 artwork, present only when it changed (`artworkChanged`).
  var artwork: String?
  var artworkChanged: Bool?
}

/// Reads now playing info through osascript and sends media commands.
final class MediaRemoteBridge {
  enum Command: UInt32 {
    case play = 0
    case pause = 1
    case togglePlayPause = 2
    case nextTrack = 4
    case previousTrack = 5
  }

  /// Called on the main thread for every snapshot except heartbeats.
  var onSnapshot: ((NowPlayingSnapshot) -> Void)?

  private var process: Process?
  private var stopping = false
  private var failures = 0
  private var restartWork: DispatchWorkItem?

  var isRunning: Bool { process != nil }

  func start() {
    guard process == nil else { return }
    stopping = false
    launch()
  }

  func stop() {
    stopping = true
    restartWork?.cancel()
    restartWork = nil
    if let process, process.isRunning {
      process.terminate()
    }
    process = nil
  }

  // MARK: Commands

  func send(_ command: Command) {
    _ = MediaRemoteFunctions.sendCommand?(command.rawValue, nil)
  }

  func seek(to seconds: Double) {
    MediaRemoteFunctions.setElapsedTime?(max(0, seconds))
  }

  // MARK: Reader process

  private func launch() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-l", "JavaScript", "-e", Self.readerScript, "0.5"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice

    let lines = LineBuffer()
    output.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      if data.isEmpty {
        handle.readabilityHandler = nil
        return
      }
      let complete = lines.append(data)
      guard !complete.isEmpty else { return }
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.handle(lines: complete) }
      }
    }
    process.terminationHandler = { [weak self] finished in
      let status = finished.terminationStatus
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.processDidExit(finished, status: status) }
      }
    }

    do {
      try process.run()
      self.process = process
    } catch {
      self.process = nil
      scheduleRestart()
    }
  }

  private func handle(lines: [Data]) {
    let decoder = JSONDecoder()
    for line in lines {
      guard let snapshot = try? decoder.decode(NowPlayingSnapshot.self, from: line) else { continue }
      switch snapshot.kind {
      case .beat:
        failures = 0
      case .unavailable:
        stopping = true
        onSnapshot?(snapshot)
      case .playing, .none:
        failures = 0
        onSnapshot?(snapshot)
      }
    }
  }

  private func processDidExit(_ finished: Process, status: Int32) {
    guard finished === process else { return }
    process = nil
    guard !stopping else { return }
    scheduleRestart()
  }

  /// Restarts the reader after a crash, waiting longer after each failure in a row.
  private func scheduleRestart() {
    failures += 1
    guard failures <= 8 else { return }
    let delay = min(60, pow(2, Double(failures)))
    let work = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated {
        guard let self, !self.stopping, self.process == nil else { return }
        self.launch()
      }
    }
    restartWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
  }

  /// Polls `MRNowPlayingRequest` (it answers Apple processes such as osascript) and prints a
  /// line when the info changes, plus a heartbeat every 5 seconds. Writing to a closed pipe
  /// ends the script, so it never outlives Kitzi.
  static let readerScript = #"""
  ObjC.import('Foundation');
  function run(argv) {
    var interval = parseFloat(argv[0]) || 0.5;
    var out = $.NSFileHandle.fileHandleWithStandardOutput;
    function emit(obj) {
      var line = $.NSString.alloc.initWithUTF8String(JSON.stringify(obj) + '\n');
      out.writeData(line.dataUsingEncoding($.NSUTF8StringEncoding));
    }
    var bundle = $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/');
    if (bundle.isNil() || !bundle.load) { emit({ kind: 'unavailable' }); return; }
    var R = $.NSClassFromString('MRNowPlayingRequest');
    if (R.isNil()) { emit({ kind: 'unavailable' }); return; }
    function value(v) {
      if (v === undefined || v === null) return null;
      if (typeof v.isNil === 'function' && v.isNil()) return null;
      return ObjC.unwrap(v);
    }
    var last = null, lastArtKey = null, quiet = 0;
    while (true) {
      var snap = { kind: 'none' };
      var art = null;
      try {
        var item = R.localNowPlayingItem;
        var info = (item && !item.isNil()) ? item.nowPlayingInfo : null;
        if (info && !info.isNil() && info.count > 0) {
          var get = function (key) { return info.objectForKey('kMRMediaRemoteNowPlayingInfo' + key); };
          snap = {
            kind: 'playing',
            title: value(get('Title')),
            artist: value(get('Artist')),
            album: value(get('Album')),
            duration: value(get('Duration')),
            elapsed: value(get('ElapsedTime')),
            rate: value(get('PlaybackRate')),
            timestamp: null,
            playing: !!R.localIsPlaying,
            bundleID: null, parentBundleID: null, appName: null,
            artworkSize: 0
          };
          var stamp = get('Timestamp');
          if (stamp && !stamp.isNil()) snap.timestamp = stamp.timeIntervalSince1970;
          var data = get('ArtworkData');
          if (data && !data.isNil()) { art = data; snap.artworkSize = data.length; }
          try {
            var client = R.localNowPlayingPlayerPath.client;
            if (client && !client.isNil()) {
              snap.bundleID = value(client.bundleIdentifier);
              snap.appName = value(client.displayName);
              try { snap.parentBundleID = value(client.parentApplicationBundleIdentifier); } catch (e) {}
            }
          } catch (e) {}
        }
      } catch (e) {
        snap = { kind: 'none' };
      }
      var key = JSON.stringify(snap);
      if (key !== last) {
        var artKey = [snap.title, snap.artist, snap.album, snap.artworkSize].join('\u0001');
        if (artKey !== lastArtKey) {
          snap.artworkChanged = true;
          snap.artwork = art ? ObjC.unwrap(art.base64EncodedStringWithOptions(0)) : null;
          lastArtKey = artKey;
        }
        emit(snap);
        last = key;
        quiet = 0;
      } else {
        quiet += interval;
        if (quiet >= 5) { emit({ kind: 'beat' }); quiet = 0; }
      }
      delay(interval);
    }
  }
  """#
}

/// Collects pipe output and splits it into lines; used from the pipe's reading thread.
nonisolated private final class LineBuffer: @unchecked Sendable {
  private let lock = NSLock()
  private var pending = Data()

  /// Appends `data` and returns the lines it completed.
  func append(_ data: Data) -> [Data] {
    lock.withLock {
      pending.append(data)
      var lines: [Data] = []
      while let newline = pending.firstIndex(of: 0x0A) {
        let line = pending[pending.startIndex..<newline]
        if !line.isEmpty { lines.append(Data(line)) }
        pending.removeSubrange(pending.startIndex...newline)
      }
      return lines
    }
  }
}

/// The few MediaRemote functions that still work from inside the app.
private enum MediaRemoteFunctions {
  typealias SendCommand = @convention(c) (UInt32, CFDictionary?) -> Bool
  typealias SetElapsedTime = @convention(c) (Double) -> Void

  static let bundle = CFBundleCreate(
    kCFAllocatorDefault,
    URL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework") as CFURL
  )

  static let sendCommand: SendCommand? = function("MRMediaRemoteSendCommand", as: SendCommand.self)
  static let setElapsedTime: SetElapsedTime? = function("MRMediaRemoteSetElapsedTime", as: SetElapsedTime.self)

  private static func function<T>(_ name: String, as type: T.Type) -> T? {
    guard let bundle, let pointer = CFBundleGetFunctionPointerForName(bundle, name as CFString) else { return nil }
    return unsafeBitCast(pointer, to: type)
  }
}
