import Foundation
import MediaPlayer
#if canImport(UIKit)
import UIKit
#endif
#if os(iOS)
import AVFoundation
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

        #if DEBUG
        print("[NowPlaying] configure: title=\"\(title)\" subtitle=\"\(subtitle ?? "nil")\" isLive=\(isLive)")
        #endif

        // Defensive session re-activation. iOS will NOT publish now-playing info
        // to the lockscreen / Dynamic Island unless the app holds an active
        // `.playback` audio session at the moment `nowPlayingInfo` is written.
        // `AudioSessionRefCount` only applies `setCategory`+`setActive(true)` on
        // the 0→1 transition, so if that initial activation failed (we've seen
        // `SessionCore.mm Error -50` on cold app launch when the OS isn't
        // ready yet) the session is left in `.soloAmbient` / unconfigured and
        // the lockscreen stays blank forever — subsequent increments no-op and
        // never retry. Re-applying here is idempotent when it already succeeded
        // and rescues the case where it didn't.
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playback,
                mode: .moviePlayback,
                options: [.allowAirPlay, .allowBluetoothA2DP]
            )
            try session.setActive(true)
            #if DEBUG
            print("[NowPlaying] configure: session .playback active (category=\(session.category.rawValue))")
            #endif
        } catch {
            #if DEBUG
            print("[NowPlaying] configure: session activation failed: \(error)")
            #endif
        }
        #endif

        registerCommands(isLive: isLive)

        #if canImport(UIKit)
        // Synchronous on main — we're already on @MainActor — so iOS has the
        // remote-control route registered BEFORE `nowPlayingInfo` is written.
        // Previously this was `DispatchQueue.main.async`, which scheduled the
        // call AFTER `publishInfo()` had already published; iOS's lockscreen
        // pipeline can drop the info if no app has claimed remote-control events
        // at the moment of publish.
        UIApplication.shared.beginReceivingRemoteControlEvents()
        #if DEBUG
        print("[NowPlaying] configure: beginReceivingRemoteControlEvents called")
        #endif
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

        #if DEBUG
        let publishedCount = MPNowPlayingInfoCenter.default().nowPlayingInfo?.count ?? -1
        print("[NowPlaying] configure: published nowPlayingInfo (local.count=\(info.count) center.count=\(publishedCount))")
        #endif

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
        #if canImport(UIKit)
        // Balance the beginReceivingRemoteControlEvents() call in configure()
        // so backgrounded apps don't continue holding the remote-control route.
        DispatchQueue.main.async {
            UIApplication.shared.endReceivingRemoteControlEvents()
        }
        #endif
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
        // Historical note: the closure-based
        // `MPMediaItemArtwork(boundsSize:requestHandler:)` init, when passed
        // a full-size channel logo (3200x2400 observed on-device), crashes
        // with `BUG IN CLIENT OF LIBDISPATCH: Block was expected to execute
        // on queue` — a queue-specific assertion inside iOS's Media
        // framework. The crash sits on Thread 10 (MP's private serial queue)
        // after our dict write, deep inside `-[MPNowPlayingInfoCenter
        // setNowPlayingInfo:]` → `dispatch_barrier_async` → `dispatch_after`
        // → `dispatch_barrier_async` → `_dispatch_assert_queue_fail`. Apple
        // Music/Podcasts avoid this entirely by going through
        // `MPMusicPlayerController` + Asset-backed metadata, not the manual
        // dict write. We can't do that with mpv.
        //
        // Workaround path below: (1) pre-decode to a small thumbnail on
        // our controlled queue so iOS never has to pull pixels async,
        // (2) use the deprecated-but-functional `MPMediaItemArtwork(image:)`
        // init so there's no closure for iOS's Media framework to resolve
        // on its private queue — the UIImage is retained directly on the
        // artwork object, (3) assign + publish in one atomic main-thread
        // write. If this still crashes, fall back to the no-artwork path —
        // the user's channel logo isn't worth a hard crash.
        //
        // tvOS has a separate, confirmed `_dispatch_assert_queue_fail`
        // bug in MPNowPlayingInfoCenter that no workaround survives — keep
        // it skipped entirely there.
        #if os(tvOS)
        return
        #else
        artworkTask?.cancel()
        guard let url else { return }
        artworkTask = Task { [weak self] in
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard !Task.isCancelled else { return }
                #if canImport(UIKit)
                guard let original = UIImage(data: data) else { return }

                // Downscale to a lockscreen-sized thumbnail. 512pt matches
                // the largest pixel dimension MPNowPlayingInfoCenter's
                // consumers (lockscreen, Dynamic Island, Control Center)
                // actually render at on current devices — handing iOS a
                // 30MB 3200x2400 source made the Media framework try to
                // bounce pixels across its private queue and tripped the
                // queue assertion. `byPreparingThumbnail` returns nil if
                // it can't decode (corrupt data, memory pressure) — fall
                // through silently.
                let maxSide: CGFloat = 512
                let targetSize: CGSize = {
                    let w = original.size.width
                    let h = original.size.height
                    guard w > 0, h > 0 else { return CGSize(width: maxSide, height: maxSide) }
                    let scale = min(maxSide / w, maxSide / h, 1.0)
                    return CGSize(width: floor(w * scale), height: floor(h * scale))
                }()
                guard let thumbnail = await original.byPreparingThumbnail(ofSize: targetSize) else {
                    #if DEBUG
                    print("[NowPlaying] artwork: thumbnail prepare returned nil (size=\(original.size.width)x\(original.size.height))")
                    #endif
                    return
                }
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    guard let self else { return }
                    // `init(image:)` is deprecated since iOS 10 but still
                    // functional. It retains the UIImage directly — NO
                    // closure for iOS's Media framework to resolve on its
                    // internal queue. That's what avoids the
                    // `_dispatch_assert_queue_fail` path the closure-based
                    // init triggers. Worth the deprecation warning.
                    let artwork = MPMediaItemArtwork(image: thumbnail)
                    self.infoDict[MPMediaItemPropertyArtwork] = artwork
                    self.publishInfo()
                    #if DEBUG
                    print("[NowPlaying] artwork: published thumbnail=\(Int(thumbnail.size.width))x\(Int(thumbnail.size.height)) source=\(Int(original.size.width))x\(Int(original.size.height))")
                    #endif
                }
                #endif
            } catch {
                #if DEBUG
                print("[NowPlaying] artwork: load failed: \(error)")
                #endif
            }
        }
        #endif
    }
}
