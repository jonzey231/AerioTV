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

    /// Live/program state captured at `configure`, used by `updateElapsed`
    /// so per-tick elapsed writes stay PROGRAM-relative on live channels
    /// (see the program-timeline note in `configure`). For VOD these stay
    /// nil and `updateElapsed` uses the raw stream clock.
    private var currentIsLive = false
    /// Explicit program bounds passed by the caller. When nil, `programBounds`
    /// resolves them LIVE from `ChannelStore` (which carries EPG-merged
    /// current-program windows) keyed by the playing channel id — so the
    /// timeline fills in as EPG loads and rolls over to the next programme
    /// without a reconfigure.
    private var overrideProgramStart: Date?
    private var overrideProgramEnd: Date?

    /// Convenience for live channels: builds title / program subtitle /
    /// channel-logo artwork / program-relative timeline straight from a
    /// `ChannelDisplayItem`, so the foreground player AND the headless
    /// CarPlay controller publish identical, complete Now Playing metadata.
    func configure(
        for item: ChannelDisplayItem,
        isLive: Bool,
        onPlay: @escaping () -> Void,
        onPause: @escaping () -> Void,
        onSeek: ((TimeInterval) -> Void)?
    ) {
        let subtitle = item.currentProgram?.trimmingCharacters(in: .whitespacesAndNewlines)
        configure(
            title: item.name,
            subtitle: (subtitle?.isEmpty == false) ? subtitle : item.group,
            artworkURL: item.logoURL,
            duration: nil,
            isLive: isLive,
            programStart: item.currentProgramStart,
            programEnd: item.currentProgramEnd,
            onPlay: onPlay,
            onPause: onPause,
            onSeek: onSeek
        )
    }

    /// Call when playback begins or content changes.
    ///
    /// For a LIVE channel with a known current-program window
    /// (`programStart`/`programEnd`), the item is presented as a BOUNDED
    /// program (duration = program length, elapsed = now − programStart)
    /// rather than `IsLiveStream = true`. The bare-live presentation is why
    /// CarPlay / the lock screen showed only the channel name with a "LIVE"
    /// chip and no progress bar, artwork, or subtitle; a bounded item makes
    /// the OS draw the full Now Playing chrome with a filling timeline.
    /// Falls back to `IsLiveStream = true` when no program bounds are known.
    func configure(
        title: String,
        subtitle: String?,
        artworkURL: URL?,
        duration: Double?,
        isLive: Bool,
        programStart: Date? = nil,
        programEnd: Date? = nil,
        onPlay: @escaping () -> Void,
        onPause: @escaping () -> Void,
        onSeek: ((TimeInterval) -> Void)?
    ) {
        self.onPlay = onPlay
        self.onPause = onPause
        self.onSeek = onSeek
        self.currentIsLive = isLive
        self.overrideProgramStart = programStart
        self.overrideProgramEnd = programEnd

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
            MPNowPlayingInfoPropertyPlaybackRate: 1.0
        ]
        if let subtitle { info[MPMediaItemPropertyArtist] = subtitle }
        if isLive {
            if let bounds = programBounds() {
                // Present the CURRENT PROGRAM as a bounded item so the OS draws
                // a filling progress bar + full chrome instead of a bare "LIVE".
                info[MPMediaItemPropertyPlaybackDuration] = bounds.duration
                info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = bounds.elapsed
                // Deliberately NOT setting IsLiveStream — that suppresses the timeline.
            } else {
                info[MPNowPlayingInfoPropertyIsLiveStream] = true
            }
        } else if let duration {
            info[MPMediaItemPropertyPlaybackDuration] = duration
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = 0.0
        }

        infoDict = info
        publishInfo()

        // #43: tvOS REQUIRES an explicit `playbackState` for the system to treat
        // this app as the active Now Playing app — which is what makes the OS
        // relay the lock-screen / Control Center widget to a paired iPhone (the
        // same way YouTube/Emby surface their Apple TV playback on your phone).
        // iOS infers "playing" from the active audio session, but tvOS does not:
        // setting only `nowPlayingInfo` without `playbackState` leaves the phone
        // with no widget at all. This is the missing piece behind "AerioTV on
        // the Apple TV shows no Now Playing widget on my iPhone."
        setPlaybackState(.playing)
        debugLog("[NowPlaying] configure: published + playbackState=.playing title=\"\(title)\" isLive=\(isLive)")

        #if DEBUG
        let publishedCount = MPNowPlayingInfoCenter.default().nowPlayingInfo?.count ?? -1
        print("[NowPlaying] configure: published nowPlayingInfo (local.count=\(info.count) center.count=\(publishedCount))")
        #endif

        // Load artwork asynchronously and update.
        loadArtwork(from: artworkURL)
    }

    /// Update elapsed time and playback rate. For a live channel presented
    /// as a bounded program, the elapsed value is PROGRAM-relative
    /// (now − programStart), not the raw stream clock `time` — otherwise the
    /// per-tick perf pump would overwrite the program timeline with the mpv
    /// playback position (which resets to ~0 on every tune).
    func updateElapsed(_ time: Double, rate: Float) {
        if currentIsLive, let bounds = programBounds() {
            // EPG is (now) available: upgrade to a bounded programme timeline,
            // dropping the "LIVE" chip. This self-heals the common case where
            // `configure` ran before EPG loaded (cold-car / resume) — the next
            // tick flips the bare "LIVE" presentation into a filling progress
            // bar with no reconfigure needed.
            infoDict[MPMediaItemPropertyPlaybackDuration] = bounds.duration
            infoDict[MPNowPlayingInfoPropertyElapsedPlaybackTime] = bounds.elapsed
            infoDict.removeValue(forKey: MPNowPlayingInfoPropertyIsLiveStream)
        } else if currentIsLive {
            // Still no programme window — keep the live chip.
            infoDict[MPNowPlayingInfoPropertyIsLiveStream] = true
            infoDict.removeValue(forKey: MPMediaItemPropertyPlaybackDuration)
            infoDict.removeValue(forKey: MPNowPlayingInfoPropertyElapsedPlaybackTime)
        } else {
            infoDict[MPNowPlayingInfoPropertyElapsedPlaybackTime] = time
        }
        infoDict[MPNowPlayingInfoPropertyPlaybackRate] = Double(rate)
        publishInfo()
        // #43: keep tvOS's active-app signal in sync with play/pause so the
        // relayed widget reflects the right state and stays alive.
        setPlaybackState(rate > 0 ? .playing : .paused)
    }

    /// Duration + clamped elapsed for the current-program window, or nil when
    /// no valid bounds are known (falls back to the live chip). Prefers the
    /// explicit override; otherwise reads the LIVE current-program window from
    /// `ChannelStore` keyed by the playing channel id — re-read on every call
    /// so the timeline appears as EPG loads and advances to the next programme
    /// on rollover without a reconfigure.
    private func programBounds() -> (duration: Double, elapsed: Double)? {
        var start = overrideProgramStart
        var end = overrideProgramEnd
        if start == nil || end == nil,
           let id = NowPlayingManager.shared.playingItem?.id,
           let channel = ChannelStore.shared.channels.first(where: { $0.id == id }) {
            start = channel.currentProgramStart
            end = channel.currentProgramEnd
        }
        guard let s = start, let e = end else { return nil }
        let duration = e.timeIntervalSince(s)
        guard duration > 0 else { return nil }
        let elapsed = min(max(Date().timeIntervalSince(s), 0), duration)
        return (duration, elapsed)
    }


    /// Clear now-playing info and remove command handlers.
    func teardown() {
        artworkTask?.cancel()
        artworkTask = nil
        infoDict = [:]
        currentIsLive = false
        overrideProgramStart = nil
        overrideProgramEnd = nil
        // #43: clear the active-app signal so the relayed widget dismisses.
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.removeTarget(nil)
        cc.pauseCommand.removeTarget(nil)
        cc.togglePlayPauseCommand.removeTarget(nil)
        cc.changePlaybackPositionCommand.removeTarget(nil)
        cc.changePlaybackPositionCommand.isEnabled = false
        cc.nextTrackCommand.removeTarget(nil)
        cc.nextTrackCommand.isEnabled = false
        cc.previousTrackCommand.removeTarget(nil)
        cc.previousTrackCommand.isEnabled = false
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

    /// #43: set the system playback state. On tvOS this is the signal that makes
    /// the app the active Now Playing app (which is what the OS relays to the
    /// Apple TV Remote / a paired iPhone's lock-screen widget); on iOS it keeps
    /// the widget in sync with play/pause. Available iOS 13+ / tvOS 13+.
    private func setPlaybackState(_ state: MPNowPlayingPlaybackState) {
        MPNowPlayingInfoCenter.default().playbackState = state
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

        // v1.7.x CarPlay: on live channels, the car's (and lock screen's)
        // next/previous buttons flip channels. `changeChannel` has its own
        // 300ms debounce against rapid hardware-press cascades. VOD keeps
        // these disabled — there is no "next channel" for on-demand.
        cc.nextTrackCommand.removeTarget(nil)
        cc.previousTrackCommand.removeTarget(nil)
        if isLive {
            cc.nextTrackCommand.isEnabled = true
            cc.previousTrackCommand.isEnabled = true
            cc.nextTrackCommand.addTarget { _ in
                DispatchQueue.main.async {
                    NowPlayingManager.shared.changeChannel(direction: 1)
                }
                return .success
            }
            cc.previousTrackCommand.addTarget { _ in
                DispatchQueue.main.async {
                    NowPlayingManager.shared.changeChannel(direction: -1)
                }
                return .success
            }
        } else {
            cc.nextTrackCommand.isEnabled = false
            cc.previousTrackCommand.isEnabled = false
        }
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
                // v1.6.23: route through LogoFetcher so the active
                // server's auth headers are applied — Dispatcharr-API
                // logos live behind /api/channels/logos/<id>/cache/
                // which 401s without X-API-Key, leaving the lockscreen
                // artwork blank for every Dispatcharr-API channel.
                let data = try await LogoFetcher.fetch(url)
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
                    // v1.6.8: routed through `AerioMakeMPMediaItemArtwork`
                    // (Shared/AerioObjC/MPMediaItemArtworkShim.{h,m}). The
                    // Objective-C shim wraps `-[MPMediaItemArtwork
                    // initWithImage:]` inside `#pragma clang diagnostic`
                    // so the deprecation warning is silenced at the source.
                    // We continue to use the deprecated init on purpose:
                    // the closure-based replacement
                    // `+initWithBoundsSize:requestHandler:` triggers
                    // `_dispatch_assert_queue_fail` on lockscreen artwork
                    // updates. The shim header documents this in detail.
                    let artwork = AerioMakeMPMediaItemArtwork(thumbnail)
                    self.infoDict[MPMediaItemPropertyArtwork] = artwork
                    self.publishInfo()
                    #if DEBUG
                    print("[NowPlaying] artwork: published thumbnail=\(Int(thumbnail.size.width))x\(Int(thumbnail.size.height)) source=\(Int(original.size.width))x\(Int(original.size.height))")
                    // Read back the live center to PROVE the artwork actually
                    // landed in MPNowPlayingInfoCenter (vs. a silent drop). If
                    // hasArtworkKey=true the data is present and any missing
                    // CarPlay/lockscreen image is a renderer/sim issue, not an
                    // app publish bug. iOS-only read (the tvOS read-back bug
                    // doesn't apply here; this whole path is #else of os(tvOS)).
                    let liveCenter = MPNowPlayingInfoCenter.default().nowPlayingInfo
                    let hasArt = liveCenter?[MPMediaItemPropertyArtwork] != nil
                    print("[NowPlaying] artwork readback: center.count=\(liveCenter?.count ?? -1) hasArtworkKey=\(hasArt) artworkBounds=\((liveCenter?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)?.bounds.size ?? .zero)")
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
