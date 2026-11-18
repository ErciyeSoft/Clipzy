import Foundation

// Placeholder for the upstream MediaRemoteAdapter controller.
// Upstream loads a separate dynamic library into /usr/bin/perl to reach the private
// MediaRemote service, which Kitzi avoids (no bundled dylibs). Until an in-house
// replacement exists, Now Playing stays empty and controls do nothing.
final class MediaController {
    var onTrackInfoReceived: ((TrackInfo?) -> Void)?

    func getTrackInfo(_ onReceive: @escaping (TrackInfo?) -> Void) {
        onReceive(nil)
    }

    func startListening() {}
    func stopListening() {}
    func play() {}
    func pause() {}
    func togglePlayPause() {}
    func nextTrack() {}
    func previousTrack() {}
    func setTime(seconds: Double) {}
}
