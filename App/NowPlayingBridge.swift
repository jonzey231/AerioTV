import Foundation
import MediaPlayer
#if canImport(UIKit)
import UIKit
#endif

/// Manages MPNowPlayingInfoCenter and MPRemoteCommandCenter for lock screen /
/// Control Center / Apple TV Remote widget now-playing controls.
///
/// IMPORTANT – tvOS MPNowPlayingInfoCenter has a framework bug where reading
/// back `nowPlayingInfo` and writing it again (read-modify-write) triggers an
/// internal `_dispatch_assert_queue_fail` crash.  To avoid this we keep our own
/// shadow copy (`infoDict`) and **always write the full dict** — never read from
/// the center.
@MainActor
final class NowPlayingBridge {
    static let shared = NowPlayingBridge()
    private init() {}

    private var onPlay: (() -> Void)?
    private var onPause: (() -> Void)?
    private var onSeek: ((TimeInterval) -> Void)?
    private var artworkTask: Task<Void, Never>?

    /// Our shadow copy of nowPlayingInfo — always written in full, never read
    /// back from MPNowPlayingInfoCenter.
    private var infoDict: [String: Any] = [:]

    /// Call when playback begins or content changes.
    func configure(
        title: String,
        subtitle: String?,
        artworkURL: URL?,
        duration: Double?,
        isLive: Bool,
        onPlay: @escaping () -> Void,
        onPause: @escaping () -> Void,
        onSeek: ((TimeInterval) -> Void)?
    ) {
        self.onPlay = onPlay
        self.onPause = onPause
        self.onSeek = onSeek

        registerCommands(isLive: isLive)

        #if canImport(UIKit)
        DispatchQueue.main.async {
            UIApplication.shared.beginReceivingRemoteControlEvents()
        }
        #endif

        // Build the info dict.
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyIsLiveStream: isLive,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0
        ]
        if let subtitle { info[MPMediaItemPropertyArtist] = subtitle }
        if let duration, !isLive {
            info[MPMediaItemPropertyPlaybackDuration] = duration
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = 0.0
        }

        infoDict = info
        publishInfo()

        // Load artwork asynchronously and update.
        loadArtwork(from: artworkURL)
    }

    /// Update elapsed time and playback rate.
    func updateElapsed(_ time: Double, rate: Float) {
        infoDict[MPNowPlayingInfoPropertyElapsedPlaybackTime] = time
        infoDict[MPNowPlayingInfoPropertyPlaybackRate] = Double(rate)
        publishInfo()
    }


    /// Clear now-playing info and remove command handlers.
    func teardown() {
        artworkTask?.cancel()
        artworkTask = nil
        infoDict = [:]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.removeTarget(nil)
        cc.pauseCommand.removeTarget(nil)
        cc.togglePlayPauseCommand.removeTarget(nil)
        cc.changePlaybackPositionCommand.removeTarget(nil)
        cc.changePlaybackPositionCommand.isEnabled = false
        onPlay = nil
        onPause = nil
        onSeek = nil
    }

    // MARK: - Private

    /// Write our shadow dict to the system center — always a full write,
    /// never a read-modify-write.
    /// Called on @MainActor (guaranteed by class isolation).
    /// MPNowPlayingInfoCenter has internal queue assertions that crash when called
    /// from arbitrary dispatch queues (iOS _dispatch_assert_queue_fail).
    private func publishInfo() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = infoDict
    }

    private func registerCommands(isLive: Bool) {
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.removeTarget(nil)
        cc.pauseCommand.removeTarget(nil)
        cc.togglePlayPauseCommand.removeTarget(nil)
        cc.changePlaybackPositionCommand.removeTarget(nil)

        cc.playCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.onPlay?() }
            return .success
        }
        cc.pauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.onPause?() }
            return .success
        }
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let rate = self.infoDict[MPNowPlayingInfoPropertyPlaybackRate] as? Double ?? 1.0
                if rate == 0 { self.onPlay?() } else { self.onPause?() }
            }
            return .success
        }

        if !isLive {
            cc.changePlaybackPositionCommand.isEnabled = true
            cc.changePlaybackPositionCommand.addTarget { [weak self] event in
                guard let posEvent = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
                DispatchQueue.main.async { self?.onSeek?(posEvent.positionTime) }
                return .success
            }
        } else {
            cc.changePlaybackPositionCommand.isEnabled = false
        }

        cc.skipForwardCommand.isEnabled = false
        cc.skipBackwardCommand.isEnabled = false
        cc.nextTrackCommand.isEnabled = false
        cc.previousTrackCommand.isEnabled = false
    }

    private func loadArtwork(from url: URL?) {
        // tvOS: MPNowPlayingInfoCenter crashes with _dispatch_assert_queue_fail
        // whenever setNowPlayingInfo: is called with a dict containing
        // MPMediaItemPropertyArtwork. This is a confirmed Apple framework bug —
        // every approach (single write, shadow dict, delayed, pre-decoded
        // CGImage, MPNowPlayingSession) crashes identically. Skip on tvOS & iOS.
        #if os(tvOS) || os(iOS)
        return
        #else
        artworkTask?.cancel()
        guard let url else { return }
        artworkTask = Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard !Task.isCancelled else { return }
                #if canImport(UIKit)
                guard let image = UIImage(data: data) else { return }
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                guard !Task.isCancelled else { return }
                infoDict[MPMediaItemPropertyArtwork] = artwork
                publishInfo()
                #endif
            } catch {
                // Artwork load failed — non-critical.
            }
        }
        #endif
    }
}
