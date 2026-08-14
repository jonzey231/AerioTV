//
//  AerioCastController.swift
//  Aerio
//
//  Google Cast iOS SENDER (GH #33). iPhone/iPad only (the Cast SDK has no tvOS
//  sender), so the whole file is #if os(iOS). Casts to the SAME receiver app id
//  (46B79062) the Android sender uses. That id is a CUSTOM WEB RECEIVER
//  (receiver.html on the repo's gh-pages; bare castMediaElement video, AerioTV
//  idle screen + fading channel banner), so the load carries a directly
//  playable contentURL. Casting rework P2: that URL is the PHONE-LOCAL cast
//  HLS proxy's master playlist (http://<phone-lan-ip>:<port>/master.m3u8,
//  CastHLSProxySession), which ingests the channel's raw MPEG-TS and
//  re-serves it as sliding-window live HLS with fMP4/CMAF segments. The
//  previous Dispatcharr progressive-fMP4 URL stuttered every 10-15 s on the
//  web receiver because a progressive live stream has no manifest clock; the
//  proxy also works for NON-Dispatcharr sources. customData still carries the
//  channel/movie IDENTITY ("aerioMediaId"/"aerioKind", matching the Android
//  sender) for session resume + parity, but the WEB receiver plays contentURL.
//
//  Unlike Android we do NOT hand-roll discovery or a route chooser: GCKUICastButton
//  does discovery + the device picker + session UI itself. iOS only needs the
//  NSLocalNetworkUsageDescription + NSBonjourServices Info.plist keys.
//

#if os(iOS)
import Foundation
import GoogleCast
import Network
import SwiftUI

/// Receiver application id registered + published in the Google Cast SDK
/// Developer Console (same id the Android sender targets).
enum AerioCast {
    // 46B79062 = the CURRENT console app (custom web receiver), re-registered
    // 2026-08-05 after the 76DC0564 registration VANISHED from the console
    // (cause unknown; Logan did not delete it - it broke cast for every user
    // on the 1.8.4/0.4.3 builds, task #224). The original CFFD302F app was
    // DELETED 2026-07-15 (console can't change receiver type). If this id
    // ever changes again, also update Info.plist NSBonjourServices
    // (_<id>._googlecast._tcp) and Android local.properties
    // CAST_RECEIVER_APP_ID.
    static let receiverAppID = "46B79062"

    /// customData contract shared with the Android receiver.
    static let keyMediaID = "aerioMediaId"
    static let keyKind = "aerioKind"
    static let kindLive = "live"
    static let kindVOD = "vod"
}

/// Observable Cast state for the player chrome to react to.
@MainActor
final class AerioCastController: NSObject, ObservableObject {

    static let shared = AerioCastController()

    enum State: Equatable {
        case unavailable          // no cast app id / no devices
        case available            // devices found, not connected
        case connecting(String?)  // device friendly name
        case connected(String?)
    }

    enum Kind { case live, vod }

    struct Content: Equatable {
        var mediaID: String
        var kind: Kind
        var title: String
        var subtitle: String?
        var artURL: String?
        /// The channel's raw MPEG-TS stream URL (the SAME URL the local
        /// player would tune) plus its auth headers. P2: the web receiver
        /// no longer gets this URL; it gets the local proxy playlist the
        /// proxy builds FROM this ingest. nil = nothing playable (event
        /// style channel); callers hide the cast affordance then.
        var streamURL: URL?
        var streamHeaders: [String: String] = [:]
    }

    @Published private(set) var state: State = .unavailable
    /// Convenience for the player: true while a cast session is live and local
    /// playback should be suspended.
    var isCasting: Bool { if case .connected = state { return true } else { return false } }

    /// What the TV is (or is about to be) playing. Survives the local player's
    /// teardown so the cast-remote cover + channel flips have their anchor.
    @Published private(set) var castingContent: Content?
    /// Mirrors the remote player's play/pause for the cover's transport button.
    @Published private(set) var remoteIsPlaying = true

    private var started = false
    private var pending: Content?
    private var castStateObserver: NSObjectProtocol?

    /// Initialise GCKCastContext once. Call from app launch on the main thread.
    func start() {
        guard !started else { return }
        let criteria = GCKDiscoveryCriteria(applicationID: AerioCast.receiverAppID)
        let options = GCKCastOptions(discoveryCriteria: criteria)
        // P2: the phone IS the receiver's media server (local HLS proxy),
        // so the session must survive backgrounding; suspending it would
        // freeze the TV the moment the user pockets the phone. The
        // proxy's own keepalive rides the audio background mode via
        // AudioSessionRefCount (see CastHLSProxySession).
        options.suspendSessionsWhenBackgrounded = false
        // The SDK defaults to deferring ALL discovery until the user taps a
        // GCKUICastButton for the first time. Task #225 replaced that button
        // with the app's own sectioned picker, so the tap never happens,
        // discovery never starts, castState stays noDevicesAvailable, and the
        // picker's Google Cast section (gated on that state) can never appear
        // to start discovery manually. Device-verified on Logan's iPhone:
        // zero Cast devices listed even for the default media receiver ID
        // until this flag went false.
        options.startDiscoveryAfterFirstTapOnCastButton = false
        GCKCastContext.setSharedInstanceWith(options)
        GCKCastContext.sharedInstance().sessionManager.add(self)
        // SDK 4.x has no GCKCastStateListener; cast availability changes arrive
        // via kGCKCastStateDidChangeNotification. The session listener below is
        // still the authority on the connected/connecting transitions.
        castStateObserver = NotificationCenter.default.addObserver(
            forName: .gckCastStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.syncCastState(GCKCastContext.sharedInstance().castState)
            }
        }
        // Task #267: while casting, a confirmed Dispatcharr Switch Stream
        // (SwitchStreamView, opened from the cast Options sheet) posts the
        // same reprime the local player uses; here it re-tunes the proxy.
        // The local player is torn down while casting, so this observer is
        // the only live consumer.
        NotificationCenter.default.addObserver(
            forName: .switchStreamReprime,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let uuid = note.userInfo?["uuid"] as? String
            Task { @MainActor in self?.handleSwitchStreamReprime(uuid: uuid) }
        }
        started = true
        syncCastState(GCKCastContext.sharedInstance().castState)
    }

    /// Set (or clear) the content mirrored to the cast device. Loads immediately
    /// if a session is connected; otherwise held until one connects.
    func setContent(_ content: Content?) {
        pending = content
        castingContent = content
        if let content, let session = GCKCastContext.sharedInstance().sessionManager.currentCastSession {
            load(content, on: session)
        }
    }

    /// End the current cast session (returns playback to the phone).
    func stopCasting() {
        GCKCastContext.sharedInstance().sessionManager.endSessionAndStopCasting(true)
    }

    /// Remote transport for the cast-remote cover. The web receiver has no
    /// custom control channel; plain RemoteMediaClient play/pause is the whole
    /// basic-cast transport surface (device-verified on Android 2026-07-15).
    func remoteTogglePlayPause() {
        guard let client = GCKCastContext.sharedInstance()
            .sessionManager.currentCastSession?.remoteMediaClient else { return }
        if client.mediaStatus?.playerState == .paused {
            client.play()
        } else {
            client.pause()
        }
    }

    /// Friendly name of the connected cast device, for the cover header.
    var connectedDeviceName: String? {
        if case .connected(let name) = state { return name }
        return nil
    }

    /// Channel up/down from the cast cover: each flip re-points the local
    /// proxy (same server + port, new generation, gap-free splice) and is
    /// a fresh load on the web receiver. Walks ChannelStore's full list,
    /// skipping channels with no stream URL at all.
    func castChannel(_ delta: Int) {
        guard let current = castingContent else { return }
        let channels = ChannelStore.shared.channels
        guard !channels.isEmpty,
              var idx = channels.firstIndex(where: { $0.id == current.mediaID }) else { return }
        for _ in 0..<channels.count {
            idx += delta
            guard channels.indices.contains(idx) else { return } // clamp at ends
            if let content = Self.castContent(for: channels[idx]) {
                setContent(content)
                return
            }
        }
    }

    /// Build the web-receiver payload for a live channel, or nil when the
    /// channel has no stream URL at all. P2: EVERY source type is now
    /// castable in principle (Dispatcharr, XC, M3U); the proxy's codec
    /// gate is the real arbiter and refuses by name at load time.
    static func castContent(for item: ChannelDisplayItem) -> Content? {
        guard let url = item.streamURL ?? item.streamURLs.first else { return nil }
        return Content(
            mediaID: item.id,
            kind: .live,
            title: item.name,
            subtitle: item.currentProgram,
            artURL: item.logoURL?.absoluteString,
            streamURL: url,
            streamHeaders: ChannelStore.shared.activeServer?.authHeaders ?? ["Accept": "*/*"]
        )
    }

    // MARK: - Loading

    /// In-flight "warm the proxy, then load" task; superseded by every
    /// channel flip and cancelled when the session ends.
    private var proxyLoadTask: Task<Void, Never>?
    /// The in-flight load request; retained so its delegate callbacks
    /// (which report receiver-side load failure) stay alive.
    private var loadRequest: GCKRequest?

    /// Live path (casting rework P2): start (or re-point) the local cast
    /// HLS proxy at the channel's raw TS URL, wait until the playlist has
    /// two segments (25 s bound, first terminal error wins), then load
    /// the proxy's MASTER playlist. The wait matters: the receiver
    /// fetches the playlist the moment load() lands, and an empty live
    /// playlist is a hard receiver error, not a retry.
    private func load(_ content: Content, on session: GCKCastSession) {
        proxyLoadTask?.cancel()
        guard content.kind == .live, let rawTS = content.streamURL else {
            // No proxyable stream: nothing the web receiver could play.
            surfaceCastFailure("This channel has no castable stream")
            return
        }
        let headers = content.streamHeaders
        proxyLoadTask = Task { [weak self] in
            let playlistURL: URL
            do {
                playlistURL = try await CastHLSProxySession.shared.startChannel(
                    rawTSURL: rawTS, headers: headers)
            } catch let error as CastUnsupportedCodecError {
                self?.surfaceCastFailure("Can't cast this channel: \(error.codecName) needs transcoding")
                return
            } catch is CancellationError {
                return
            } catch {
                self?.surfaceCastFailure("Can't cast this channel: \(error)")
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                // Re-fetch the session: the connect may have churned while
                // the proxy warmed up.
                guard let self,
                      let live = GCKCastContext.sharedInstance().sessionManager.currentCastSession,
                      self.castingContent?.mediaID == content.mediaID else { return }
                self.loadProxyPlaylist(playlistURL, content: content, on: live)
            }
        }
    }

    private func loadProxyPlaylist(_ playlistURL: URL, content: Content, on session: GCKCastSession) {
        guard let client = session.remoteMediaClient else { return }

        let metadata = GCKMediaMetadata(metadataType: .generic)
        metadata.setString(content.title, forKey: kGCKMetadataKeyTitle)
        if let sub = content.subtitle, !sub.isEmpty {
            metadata.setString(sub, forKey: kGCKMetadataKeySubtitle)
        }
        if let art = content.artURL, let url = URL(string: art) {
            metadata.addImage(GCKImage(url: url, width: 480, height: 270))
        }

        // Use the non-deprecated entity initializer. The channel identity
        // rides in customData; entity is an opaque app-specific identifier.
        let builder = GCKMediaInformationBuilder(entity: content.mediaID)
        builder.streamType = .live
        // The custom WEB receiver (46B79062) plays contentURL directly:
        // the local proxy's MASTER playlist (the master's
        // CLOSED-CAPTIONS=NONE is load-bearing; see CastHLSSegmentStore).
        // Declaring the segment container skips the receiver's sniffing.
        builder.contentURL = playlistURL
        builder.contentType = "application/x-mpegURL"
        builder.hlsSegmentFormat = .FMP4
        builder.hlsVideoSegmentFormat = .FMP4
        builder.metadata = metadata
        builder.customData = [
            AerioCast.keyMediaID: content.mediaID,
            AerioCast.keyKind: AerioCast.kindLive,
        ]
        let mediaInfo = builder.build()

        let requestBuilder = GCKMediaLoadRequestDataBuilder()
        requestBuilder.mediaInformation = mediaInfo
        requestBuilder.autoplay = true
        let request = client.loadMedia(with: requestBuilder.build())
        request.delegate = self
        loadRequest = request
    }

    // MARK: - Switch Stream reprime (cast Options sheet, task #267)

    /// Dispatcharr Switch Stream while casting: `change_stream` swaps the
    /// upstream behind the SAME `/proxy/ts/stream/<uuid>` URL, so the
    /// ingest URL and the receiver's playlist URL never change -- but the
    /// proxy's remuxer should not be left riding the mid-stream TS splice
    /// (fresh buffer, new clock). Re-run `startChannel` with the unchanged
    /// raw TS URL: same server + port, new generation, gap-free playlist
    /// splice, and the receiver just keeps polling (the same seamless path
    /// channel flips use, device-verified). No loadMedia; the loaded media
    /// stays untouched.
    private func handleSwitchStreamReprime(uuid: String?) {
        guard isCasting, let uuid, let content = castingContent,
              let rawTS = content.streamURL,
              let item = ChannelStore.shared.channels.first(where: { $0.id == content.mediaID }),
              item.uuid == uuid else { return }
        debugLog("[CAST-HLS] switch-stream reprime for \(item.name)")
        let headers = content.streamHeaders
        proxyLoadTask?.cancel()
        proxyLoadTask = Task { [weak self] in
            do {
                _ = try await CastHLSProxySession.shared.startChannel(
                    rawTSURL: rawTS, headers: headers)
            } catch is CancellationError {
            } catch {
                self?.surfaceCastFailure("The stream switch interrupted casting: \(error)")
            }
        }
    }

    // MARK: - Sleep timer (Android cast-options parity, task #267)

    /// When the armed timer fires (nil = off). Phone-side countdown like
    /// the companion remote's; expiry STOPS the cast (frees the TV, the
    /// proxy, and the provider connection) WITHOUT the usual local resume
    /// -- a sleeping user's phone must not start playing to a dark room.
    @Published private(set) var sleepEndsAt: Date?
    private var sleepTimerTask: Task<Void, Never>?
    /// One-shot: the next onSessionEnded skips the resume-locally step.
    private var suppressLocalResume = false

    /// Arm (minutes > 0) or cancel (0) the sleep timer.
    func armSleepTimer(minutes: Int) {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        guard minutes > 0 else { sleepEndsAt = nil; return }
        sleepEndsAt = Date().addingTimeInterval(TimeInterval(minutes) * 60)
        debugLog("[CAST-HLS] sleep timer armed: \(minutes)m")
        sleepTimerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(minutes) * 60 * 1_000_000_000)
            guard !Task.isCancelled, let self, self.isCasting else { return }
            debugLog("[CAST-HLS] sleep timer fired -> stopping cast")
            self.sleepEndsAt = nil
            self.suppressLocalResume = true
            self.stopCasting()
        }
    }

    /// Same surface the cast tap paths already imply: a plain alert on
    /// the frontmost scene (mirrors the Android Toast).
    fileprivate func surfaceCastFailure(_ message: String) {
        debugLog("[CAST-HLS] cast failure surfaced: \(message)")
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard let root = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        let alert = UIAlertController(title: "Cast", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        top.present(alert, animated: true)
    }

    // MARK: - State plumbing

    fileprivate func syncCastState(_ castState: GCKCastState) {
        let session = GCKCastContext.sharedInstance().sessionManager.currentCastSession
        let device = session?.device.friendlyName
        switch castState {
        // Guard on an actual session: at teardown castState can still read
        // .connected for a runloop tick while currentCastSession is already nil,
        // which would leave a transient .connected(nil) and keep isCasting true.
        case .connected where session != nil: state = .connected(device)
        case .connected: state = .available
        case .connecting: state = .connecting(device)
        case .notConnected: state = .available
        default: state = .unavailable   // .noDevicesAvailable
        }
    }
}

// MARK: - GCKSessionManagerListener

extension AerioCastController: GCKSessionManagerListener {
    // GCK delivers session-manager callbacks on the main thread, so
    // MainActor.assumeIsolated runs synchronously in place. This (vs a
    // Task { @MainActor }) avoids "sending non-Sendable session across isolation"
    // under Swift 6 strict concurrency, since nothing is dispatched cross-domain.
    nonisolated func sessionManager(_ sessionManager: GCKSessionManager, didStart session: GCKCastSession) {
        MainActor.assumeIsolated { self.onConnected() }
    }
    nonisolated func sessionManager(_ sessionManager: GCKSessionManager, didResumeCastSession session: GCKCastSession) {
        MainActor.assumeIsolated { self.onConnected() }
    }
    nonisolated func sessionManager(_ sessionManager: GCKSessionManager, didEnd session: GCKSession, withError error: Error?) {
        MainActor.assumeIsolated { self.onSessionEnded() }
    }

    /// Re-fetches the current session on the MainActor (rather than receiving the
    /// non-Sendable GCKCastSession across isolation), then loads pending content.
    private func onConnected() {
        guard let session = GCKCastContext.sharedInstance().sessionManager.currentCastSession else { return }
        state = .connected(session.device.friendlyName)
        session.remoteMediaClient?.add(self)
        if let pending {
            load(pending, on: session)
            return
        }
        // Cast takes precedence over an active companion session: tear that
        // down first so the two remote covers can never both be live (review
        // 2026-07-16). Companion Disconnect leaves the Android TV playing.
        if CompanionClient.shared.isControlling { CompanionClient.shared.disconnect() }
        // Fresh session started from the player chrome: hand the CURRENTLY
        // playing channel to the TV, then tear the local player down (frees
        // the decoder AND the Dispatcharr connection slot -- the receiver is
        // about to open its own; on max-connections=1 channels the local
        // stream would starve the TV's, Android review 2026-07-15). The
        // cast-remote cover (HomeView renders it off isCasting) takes over.
        if let item = NowPlayingManager.shared.playingItem,
           let content = Self.castContent(for: item) {
            setContent(content)
            AppOrientationLock.release()
            PlayerSession.shared.stop()
        } else {
            // Nothing castable to hand over (the chrome gate keys on tile 0,
            // but the seed/audio item may differ in multiview): don't strand a
            // connected-but-empty session that renders no cover and can't be
            // stopped except by re-finding the icon (review 2026-07-16).
            stopCasting()
        }
    }

    /// Session ended (user tapped Stop on the cover, or the TV went away):
    /// resume the last cast channel locally -- "stop casting" means "bring
    /// playback back to my phone" (Android parity).
    private func onSessionEnded() {
        pending = nil
        // The receiver is gone; the proxy has no client left to serve.
        proxyLoadTask?.cancel()
        proxyLoadTask = nil
        loadRequest = nil
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepEndsAt = nil
        Task.detached { CastHLSProxySession.shared.stop() }
        syncCastState(GCKCastContext.sharedInstance().castState)
        let skipResume = suppressLocalResume
        suppressLocalResume = false
        defer { castingContent = nil }
        guard !skipResume,
              let content = castingContent,
              let item = ChannelStore.shared.channels.first(where: { $0.id == content.mediaID })
        else { return }
        _ = PlayerSession.shared.begin(item: item, server: ChannelStore.shared.activeServer)
    }
}

// MARK: - GCKRequestDelegate (receiver-side load failure)

extension AerioCastController: GCKRequestDelegate {
    /// A load the receiver rejected must not leave the proxy ingesting a
    /// stream nobody is watching (it pins a provider connection slot).
    nonisolated func request(_ request: GCKRequest, didFailWithError error: GCKError) {
        // Identity captured OUTSIDE the isolation hop: GCKRequest is not
        // Sendable, and the callback arrives on the main thread anyway
        // (assumeIsolated runs synchronously in place).
        let failedID = ObjectIdentifier(request)
        let errorText = String(describing: error)
        MainActor.assumeIsolated {
            guard let inFlight = self.loadRequest, ObjectIdentifier(inFlight) == failedID else { return }
            self.loadRequest = nil
            debugLog("[CAST-HLS] receiver load failed: \(errorText)")
            Task.detached { CastHLSProxySession.shared.stop() }
            self.surfaceCastFailure("The TV could not start this channel")
        }
    }
}

// MARK: - GCKRemoteMediaClientListener (play/pause mirror for the cover)

extension AerioCastController: GCKRemoteMediaClientListener {
    nonisolated func remoteMediaClient(_ client: GCKRemoteMediaClient,
                                       didUpdate mediaStatus: GCKMediaStatus?) {
        let playing: Bool
        switch mediaStatus?.playerState {
        case .paused: playing = false
        default: playing = true // playing / buffering / loading all read as "on"
        }
        MainActor.assumeIsolated { self.remoteIsPlaying = playing }
    }
}

// MARK: - Companion remote client (GH #33 second-screen)

/// LAN remote for the AerioTV ANDROID TV app: the TV advertises `_aeriotv._tcp`
/// and runs a WebSocket server; this client discovers it (NWBrowser), pairs
/// with the TV's 6-digit code (token remembered per TV afterwards), and drives
/// the TV's native player. The wire format is EXACTLY the Android
/// CompanionProtocol + CastControl JSON: session frames carry "t"
/// (hello/auth/authOk/authFail), control frames carry "cmd". Channel identity
/// is the ANDROID id format -- "disp:<uuid>" for Dispatcharr channels -- so
/// companion channel control is Dispatcharr-only (both platforms share the
/// server uuid; XC/M3U ids don't translate across apps).
///
/// Unlike casting, Disconnect leaves the TV playing (it's the user's own
/// device; Android device-verified UX 2026-07-15) and the phone just returns
/// to the guide -- no local resume.
@MainActor
final class CompanionClient: NSObject, ObservableObject {

    static let shared = CompanionClient()

    struct TV: Identifiable, Equatable {
        let id: String          // TXT "id" when present, else the service name
        let name: String
        let endpoint: NWEndpoint
    }

    enum Conn: Equatable {
        case idle
        case connecting(String?)
        /// Connected but unauthenticated: the TV is showing a pairing code.
        case needsPairing(String?)
        case connected(String?)
    }

    /// One audio/subtitle track the phone's picker renders.
    struct Track: Identifiable, Equatable {
        let id: String
        let label: String
        let selected: Bool
    }

    /// Full option state pushed by the TV (CMD_STATE) -- powers the phone's
    /// audio/subtitle/speed/aspect pickers + the rewind scrubber. Same shape as
    /// the Android CastControl.RemoteState.
    struct RemoteState: Equatable {
        var audio: [Track] = []
        var text: [Track] = []
        var textOff = true
        var speed: Double = 1
        var aspect = "fit"
        var streamInfo = ""
        var canSeek = false
        var isLive = true
        var positionWallMs: Int64 = 0
        var windowStartMs: Int64 = 0
        var windowEndMs: Int64 = 0
        var audioOnly = false
    }

    @Published private(set) var devices: [TV] = []
    @Published private(set) var conn: Conn = .idle
    @Published private(set) var remoteIsPlaying = true
    /// Full options snapshot from the TV (tracks / speed / aspect / rewind).
    @Published private(set) var remoteState = RemoteState()
    /// Best-effort title of what the TV plays (hello frame / what we sent).
    @Published private(set) var nowPlaying = ""
    /// Android-format channel id ("disp:<uuid>") this phone last sent.
    @Published private(set) var controllingChannelID: String?

    var isControlling: Bool { if case .connected = conn { return true } else { return false } }
    var connectedTVName: String? { if case .connected(let n) = conn { return n } else { return nil } }

    private var browser: NWBrowser?
    private var socket: URLSessionWebSocketTask?
    private var resolver: NWConnection?
    private var currentTV: TV?
    /// Monotonic attempt counter: a cancelled attempt's async tail must never
    /// clobber its successor's state (Android adversarial-review lesson).
    private var generation = 0

    // MARK: Discovery

    /// True between startDiscovery() and stopDiscovery(): the auto-restart
    /// paths only revive a browse the app still wants.
    private var discoveryWanted = false

    func startDiscovery() {
        discoveryWanted = true
        guard browser == nil else { return }
        let b = NWBrowser(
            for: .bonjourWithTXTRecord(type: "_aeriotv._tcp", domain: nil),
            using: NWParameters()
        )
        b.browseResultsChangedHandler = { [weak self] results, _ in
            // Raw dump (GH #33 field debugging): every result with its full
            // endpoint + TXT so ghost-vs-real mysteries are diagnosable from
            // the device log.
            let dump = results.map { r -> String in
                var txt = "-"
                if case .bonjour(let t) = r.metadata { txt = t.dictionary.description }
                return "\(r.endpoint) txt=\(txt) if=\(r.interfaces.map { "\($0.type)" }.joined(separator: "+"))"
            }.joined(separator: " | ")
            DebugLogger.shared.log("companion browse results (\(results.count)): \(dump)")
            let tvs: [TV] = results.compactMap { result in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                var stableID = name
                if case .bonjour(let txt) = result.metadata,
                   let id = txt.dictionary["id"], !id.isEmpty {
                    stableID = id
                }
                return TV(id: stableID, name: name, endpoint: result.endpoint)
            }.sorted { $0.name.lowercased() < $1.name.lowercased() }
            Task { @MainActor [weak self] in self?.publishDevices(tvs) }
        }
        // An NWBrowser that dies while the app is suspended reports .failed on
        // resume; without this handler the wedged instance also blocked
        // startDiscovery()'s nil guard forever, freezing `devices` with ghost
        // entries (2026-07-16: picker kept a stale "Apple TV" and never saw
        // its "Living Room" re-registration, so connecting just timed out).
        b.stateUpdateHandler = { [weak self] state in
            DebugLogger.shared.log("companion browser state: \(state)")
            if case .failed = state {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.browser?.cancel()
                    self.browser = nil
                    if self.discoveryWanted { self.startDiscovery() }
                }
            }
        }
        b.start(queue: .main)
        browser = b
    }

    func stopDiscovery() {
        discoveryWanted = false
        browser?.cancel()
        browser = nil
        devices = []
    }

    /// Scene-foreground re-assert: restart the browse if it is missing or not
    /// healthy. `devices` is intentionally NOT cleared here -- the fresh
    /// browser's first results callback replaces the list wholesale, so ghost
    /// entries drop without the Control-TV button blinking on every foreground.
    func ensureDiscovery() {
        guard discoveryWanted else { return }
        if let b = browser, case .ready = b.state { return }
        browser?.cancel()
        browser = nil
        startDiscovery()
    }

    // MARK: Ghost filtering

    /// Connect-failed quarantine. The phone's system mDNS cache keeps a dead
    /// service's PTR record for up to 75 min when the goodbye packets were
    /// missed (phone suspended), so a fresh browse can list TVs that no longer
    /// exist (2026-07-16: two ghost "Apple TV" rows after the ATV renamed).
    /// A failed connect is the one reliable ghost detector: hide that entry
    /// for a while (a real TV that was just briefly unreachable comes back on
    /// the next results change or after the window).
    private var deadTVs: [String: Date] = [:]
    private static let deadTVWindow: TimeInterval = 60

    private static func tvKey(_ tv: TV) -> String { "\(tv.id)|\(tv.name)" }

    /// Collapse duplicate rows (one advert seen via several interfaces / a
    /// re-registration sharing TXT id + name) and hide quarantined ghosts.
    private func publishDevices(_ tvs: [TV]) {
        var seen = Set<String>()
        devices = tvs.filter { tv in
            let key = Self.tvKey(tv)
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            if let died = deadTVs[key],
               Date().timeIntervalSince(died) < Self.deadTVWindow { return false }
            return true
        }
    }

    private func quarantine(_ tv: TV) {
        let key = Self.tvKey(tv)
        deadTVs[key] = Date()
        devices.removeAll { Self.tvKey($0) == key }
    }

    // MARK: Connection

    func connect(to tv: TV) {
        // Mutual exclusion with casting: cast is the heavier transport and
        // wins (review 2026-07-16). The companion picker button is already
        // hidden while casting; this guards the programmatic path too.
        guard !AerioCastController.shared.isCasting else { return }
        disconnect(userInitiated: false)
        remoteMinimized = false
        currentTV = tv
        generation += 1
        let gen = generation
        conn = .connecting(tv.name)
        // The TV's WS server lives at ws://host:port/remote; a Bonjour endpoint
        // carries neither, so resolve first: open a throwaway TCP connection to
        // the service endpoint and read the remote host:port off its path.
        let probe = NWConnection(to: tv.endpoint, using: .tcp)
        resolver = probe
        probe.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, gen == self.generation else { return }
                switch state {
                case .ready:
                    let remote = probe.currentPath?.remoteEndpoint
                    probe.cancel()
                    self.resolver = nil
                    if case .hostPort(let host, let port)? = remote {
                        self.openSocket(host: host, port: port, gen: gen)
                    } else {
                        self.conn = .idle
                    }
                case .failed, .cancelled:
                    if case .connecting = self.conn, self.resolver != nil {
                        self.resolver = nil
                        self.conn = .idle
                        self.quarantine(tv)
                    }
                default:
                    // .waiting (unreachable host / connection refused) retries
                    // forever with default NWParameters, so never resolves on
                    // its own -- the timeout below is the only escape.
                    break
                }
            }
        }
        probe.start(queue: .main)
        // Fail an unresolvable pick (ghost mDNS record, dead WS server) instead
        // of spinning "Connecting…" forever (review 2026-07-16).
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, gen == self.generation, self.resolver != nil else { return }
            self.resolver?.cancel()
            self.resolver = nil
            if case .connecting = self.conn { self.conn = .idle }
            self.quarantine(tv)
        }
    }

    private func openSocket(host: NWEndpoint.Host, port: NWEndpoint.Port, gen: Int) {
        // Bracket IPv6, and PRESERVE the %interface zone (link-local fe80::/10
        // is common on flat home LANs and unroutable without its scope) by
        // percent-encoding it as %25<zone> per RFC 6874 -- NOT stripping it,
        // which black-holed link-local companion connections (review 2026-07-16).
        var h = "\(host)"
        if h.contains(":") {
            h = h.replacingOccurrences(of: "%", with: "%25")
            h = "[\(h)]"
        }
        guard let url = URL(string: "ws://\(h):\(port)/remote") else {
            conn = .idle
            return
        }
        let task = URLSession.shared.webSocketTask(with: url)
        socket = task
        task.resume()
        // Authenticate immediately: remembered token, or blank to make the TV
        // show a pairing code (it answers authFail + needsPairing).
        sendJSON(["t": "auth", "token": storedToken(), "code": ""])
        receiveLoop(task: task, gen: gen)
    }

    private func receiveLoop(task: URLSessionWebSocketTask, gen: Int) {
        task.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, gen == self.generation else { return }
                switch result {
                case .success(let message):
                    if case .string(let text) = message,
                       let data = text.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        self.handle(json)
                    }
                    self.receiveLoop(task: task, gen: gen)
                case .failure:
                    self.socket = nil
                    self.conn = .idle
                    self.controllingChannelID = nil
                    self.nowPlaying = ""
                }
            }
        }
    }

    /// Liveness: both hosts tick ~1Hz while a session is authed, so silence
    /// means the TV app died/restarted (2026-07-16 test: the phone sat frozen
    /// on "Controlling Living Room" after a tvOS redeploy). Tear the session
    /// down instead of leaving a dead remote on screen.
    private var lastMessageAt = Date()
    private var livenessTask: Task<Void, Never>?

    private func startLiveness(gen: Int) {
        livenessTask?.cancel()
        lastMessageAt = Date()
        livenessTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard let self, gen == self.generation, self.isControlling else { return }
                if Date().timeIntervalSince(self.lastMessageAt) > 12 {
                    debugLog("companion liveness: no traffic for 12s -> dropping session")
                    self.disconnect(userInitiated: false)
                    self.conn = .idle
                    return
                }
            }
        }
    }

    private func handle(_ json: [String: Any]) {
        lastMessageAt = Date()
        if let t = json["t"] as? String, !t.isEmpty {
            switch t {
            case "hello":
                if let np = json["nowPlaying"] as? String, !np.isEmpty { nowPlaying = np }
            case "authOk":
                let remembered = (json["token"] as? String)?.isEmpty == false
                if let token = json["token"] as? String, !token.isEmpty { storeToken(token) }
                conn = .connected(currentTV?.name)
                Self.clog("authOk -> connected to \(currentTV?.name ?? "TV") (token=\(remembered ? "issued" : "none"))")
                onControllingStarted()
                requestState()
                startLiveness(gen: generation)
            case "authFail":
                conn = .needsPairing(currentTV?.name)
                Self.clog("authFail reason=\(json["reason"] as? String ?? "?") -> needs pairing", level: .warning)
            default:
                break
            }
            return
        }
        switch json["cmd"] as? String {
        case "state":
            remoteState = Self.decodeState(json)
            if let playing = json["isPlaying"] as? Bool { remoteIsPlaying = playing }
            // Adopt the TV's reported channel as the flip anchor -- covers
            // connecting to a TV that is already playing something this phone
            // didn't start (and TVs that switch channels on their own remote).
            if let cid = json["channelId"] as? String, !cid.isEmpty {
                if cid != controllingChannelID { Self.clog("state anchor adopt \(cid) audioOnly=\(remoteState.audioOnly)") }
                controllingChannelID = cid
            }
            if let np = json["nowPlaying"] as? String, !np.isEmpty { nowPlaying = np }
        case "position":
            if let playing = json["isPlaying"] as? Bool { remoteIsPlaying = playing }
            // Live scrubber fields crawl via the ~1Hz tick.
            var s = remoteState
            if let v = json["canSeek"] as? Bool { s.canSeek = v }
            if let v = json["isLive"] as? Bool { s.isLive = v }
            if let v = Self.int64(json["positionWallMs"]) { s.positionWallMs = v }
            if let v = Self.int64(json["windowStartMs"]) { s.windowStartMs = v }
            if let v = Self.int64(json["windowEndMs"]) { s.windowEndMs = v }
            remoteState = s
            // The anchor also rides the tick: the Android host's post-setChannel
            // full-state push races its async re-prime (it still carries the OLD
            // channel), and nothing else re-sent channelId -- Switch Stream then
            // targeted the previous channel (2026-07-17 Streamer test).
            if let cid = json["channelId"] as? String, !cid.isEmpty {
                controllingChannelID = cid
            }
        default:
            break
        }
    }

    private static func decodeState(_ json: [String: Any]) -> RemoteState {
        func tracks(_ key: String) -> [Track] {
            (json[key] as? [[String: Any]] ?? []).map {
                Track(id: $0["id"] as? String ?? "",
                      label: $0["label"] as? String ?? "",
                      selected: $0["selected"] as? Bool ?? false)
            }
        }
        var s = RemoteState()
        s.audio = tracks("audio")
        s.text = tracks("text")
        s.textOff = json["textOff"] as? Bool ?? true
        s.speed = json["speed"] as? Double ?? 1
        s.aspect = json["aspect"] as? String ?? "fit"
        s.streamInfo = json["streamInfo"] as? String ?? ""
        s.canSeek = json["canSeek"] as? Bool ?? false
        s.isLive = json["isLive"] as? Bool ?? true
        s.positionWallMs = int64(json["positionWallMs"]) ?? 0
        s.windowStartMs = int64(json["windowStartMs"]) ?? 0
        s.windowEndMs = int64(json["windowEndMs"]) ?? 0
        s.audioOnly = json["audioOnly"] as? Bool ?? false
        return s
    }

    private static func int64(_ v: Any?) -> Int64? {
        if let i = v as? Int64 { return i }
        if let i = v as? Int { return Int64(i) }
        if let d = v as? Double { return Int64(d) }
        return nil
    }

    /// User typed the 6-digit code shown on the TV.
    func submitPairingCode(_ code: String) {
        conn = .connecting(currentTV?.name)
        sendJSON(["t": "auth", "token": "", "code": code.trimmingCharacters(in: .whitespaces)])
    }

    /// Stop controlling. The TV keeps playing; the phone does NOT resume local
    /// playback (companion Disconnect semantics, device-verified on Android).
    func disconnect(userInitiated: Bool = true) {
        if isControlling { Self.clog("disconnect(userInitiated=\(userInitiated)) from \(connectedTVName ?? "TV")") }
        generation += 1
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        resolver?.cancel()
        resolver = nil
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepEndsAt = nil
        if userInitiated || conn != .idle {
            conn = .idle
            controllingChannelID = nil
            nowPlaying = ""
            remoteState = RemoteState()
        }
    }

    // MARK: Sleep timer (Android companion-overlay parity)

    /// When the armed timer fires (nil = off). Phone-side countdown, like the
    /// Android overlay: the session is the user's own TV, so expiry PAUSES it
    /// (a cast would be stopped) and drops the remote cover.
    @Published private(set) var sleepEndsAt: Date?
    private var sleepTimerTask: Task<Void, Never>?

    /// Arm (minutes > 0) or cancel (0) the sleep timer.
    func armSleepTimer(minutes: Int) {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        guard minutes > 0 else { sleepEndsAt = nil; Self.clog("sleep timer cancelled"); return }
        sleepEndsAt = Date().addingTimeInterval(TimeInterval(minutes) * 60)
        Self.clog("sleep timer armed: \(minutes)m")
        sleepTimerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(minutes) * 60 * 1_000_000_000)
            guard !Task.isCancelled, let self, self.isControlling else { return }
            Self.clog("sleep timer fired -> pausing TV + minimizing remote")
            self.pause()
            self.sleepEndsAt = nil
            self.remoteMinimized = true
        }
    }

    // MARK: Control surface

    /// Fresh companion session: mirror the currently playing channel to the TV,
    /// then tear down local playback (same swap as casting).
    private func onControllingStarted() {
        guard let item = NowPlayingManager.shared.playingItem,
              let androidID = Self.androidChannelID(for: item) else { return }
        setChannel(androidID, title: item.name)
        AppOrientationLock.release()
        PlayerSession.shared.stop()
    }

    /// True while the remote cover is minimized so the user can browse the
    /// guide (Channels button); channel taps still route to the TV. Cleared
    /// on connect and whenever a channel is sent, so the remote pops back.
    @Published var remoteMinimized = false

    /// Shared diagnostic breadcrumb for the companion remote. Gated behind the
    /// user's debug-logging pref (DebugLogger); safe to leave in Release so a
    /// user hitting a bug can flip logging on, reproduce, and send the file.
    static func clog(_ message: String, level: LogLevel = .info) {
        DebugLogger.shared.log("[Companion] \(message)", category: "Companion", level: level)
    }

    func setChannel(_ androidChannelID: String, title: String?) {
        controllingChannelID = androidChannelID
        if let title, !title.isEmpty { nowPlaying = title }
        sendJSON(["cmd": "setChannel", "channelId": androidChannelID])
        remoteMinimized = false
        Self.clog("-> TV setChannel \(androidChannelID) title=\(title ?? "-")")
    }

    func togglePlayPause() { sendJSON(["cmd": "toggle"]); Self.clog("-> TV toggle") }

    // Full options surface (parity with the Android companion overlay).
    func requestState() { sendJSON(["cmd": "getState"]) }
    func setAudioTrack(_ id: String) { sendJSON(["cmd": "setAudio", "id": id]); Self.clog("-> TV setAudio \(id)") }
    func setTextTrack(_ id: String?) { sendJSON(["cmd": "setText", "id": id ?? ""]); Self.clog("-> TV setText \(id ?? "off")") }
    func setSpeed(_ speed: Double) { sendJSON(["cmd": "setSpeed", "speed": speed]); Self.clog("-> TV setSpeed \(speed)") }
    func setAspect(_ key: String) { sendJSON(["cmd": "setAspect", "aspect": key]); Self.clog("-> TV setAspect \(key)") }
    func pause() { sendJSON(["cmd": "pause"]); Self.clog("-> TV pause") }
    func setAudioOnly(_ on: Bool) { sendJSON(["cmd": "setAudioOnly", "audioOnly": on]); Self.clog("-> TV setAudioOnly \(on)") }
    func seekBy(_ deltaMs: Int64) { sendJSON(["cmd": "seekBy", "deltaMs": deltaMs]) }
    func seekToWall(_ ms: Int64) { sendJSON(["cmd": "seekWall", "targetWallMs": ms]) }
    func goLive() { sendJSON(["cmd": "goLive"]) }

    /// Channel up/down: walk ChannelStore for the next Dispatcharr channel
    /// (companion ids only translate for Dispatcharr sources).
    func flipChannel(_ delta: Int) {
        let channels = ChannelStore.shared.channels
        var idx: Int
        if let currentID = controllingChannelID,
           let cur = channels.firstIndex(where: { Self.androidChannelID(for: $0) == currentID }) {
            idx = cur
        } else {
            // No anchor (TV idle on its guide, or playing something we can't
            // map): behave like a real remote and start from the ends -- up
            // tunes the first controllable channel, down the last.
            idx = delta > 0 ? -1 : channels.count
        }
        for _ in 0..<channels.count {
            idx += delta
            guard channels.indices.contains(idx) else { return } // clamp at ends
            let item = channels[idx]
            if let androidID = Self.androidChannelID(for: item) {
                setChannel(androidID, title: item.name)
                return
            }
        }
    }

    /// The ANDROID app's channel id for a channel this iOS app knows:
    /// Dispatcharr channels share the server uuid ("disp:<uuid>" on Android).
    /// nil for XC/M3U (ids don't translate; companion control unavailable).
    static func androidChannelID(for item: ChannelDisplayItem) -> String? {
        guard let uuid = item.uuid, !uuid.isEmpty else { return nil }
        return "disp:\(uuid)"
    }

    private func sendJSON(_ dict: [String: Any]) {
        guard let socket,
              let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { _ in }
    }

    // MARK: Token store (per TV)

    private func tokenKey() -> String { "companion.token.\(currentTV?.id ?? "unknown")" }
    private func storedToken() -> String {
        UserDefaults.standard.string(forKey: tokenKey()) ?? ""
    }
    private func storeToken(_ token: String) {
        UserDefaults.standard.set(token, forKey: tokenKey())
    }
}

// MARK: - SwiftUI Cast button

/// Wraps the SDK's GCKUICastButton (which owns discovery + the device chooser).
struct CastButton: UIViewRepresentable {
    var tint: UIColor = .white

    func makeUIView(context: Context) -> GCKUICastButton {
        let button = GCKUICastButton(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
        button.tintColor = tint
        return button
    }

    func updateUIView(_ uiView: GCKUICastButton, context: Context) {
        uiView.tintColor = tint
    }
}

// MARK: - Cast remote cover (GH #33 basic cast)

/// Fullscreen remote shown while a REMOTE screen plays (cast web receiver OR
/// companion-controlled Android TV). Local playback is torn down underneath;
/// this drives the TV. One layout, two transports -- the callbacks decide.
/// Inlined here (not its own file) so no pbxproj target surgery is needed.
struct RemoteControlScreen: View {
    var title: String
    var subtitle: String?
    var artURL: String?
    var statusText: String       // "Casting to X" / "Controlling X"
    var isPlaying: Bool
    var stopLabel: String        // "Stop casting" / "Disconnect"
    var onTogglePlayPause: () -> Void
    var onChannelUp: () -> Void
    var onChannelDown: () -> Void
    var onStop: () -> Void
    /// Non-nil for the companion transport (full options: scrubber + Options
    /// sheet). nil for basic cast (web receiver has no control namespace).
    var companion: CompanionClient? = nil
    /// Non-nil shows a "Channels" button that minimizes this remote back to
    /// the guide (stay connected, browse, tap a channel to send it to the TV).
    var onBrowse: (() -> Void)? = nil
    /// Non-nil for the basic-cast transport (task #267): shows the same
    /// Options button as the companion remote, opening CastOptionsSheet
    /// (Switch Stream / Record / Sleep Timer / proxy Stream Info) -- the
    /// phone-driven subset, since the web receiver has no control channel.
    var cast: AerioCastController? = nil

    @State private var showOptions = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let onBrowse {
                VStack {
                    HStack {
                        Button(action: onBrowse) {
                            HStack(spacing: 6) {
                                Image(systemName: "square.grid.2x2")
                                Text("Channels")
                            }
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 14)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                        }
                        .accessibilityLabel("Browse channels")
                        Spacer()
                    }
                    .padding(.top, 12)
                    .padding(.horizontal, 20)
                    Spacer()
                }
            }
            VStack(spacing: 18) {
                Spacer()
                if let art = artURL, let url = URL(string: art) {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        Image(systemName: "tv").font(.system(size: 56))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: 220, maxHeight: 120)
                } else {
                    Image(systemName: "tv").font(.system(size: 56))
                        .foregroundStyle(.secondary)
                }
                Text(title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                }
                Text(statusText)
                    .font(.callout)
                    .foregroundStyle(Color.accentColor)
                Spacer()
                if let companion, companion.remoteState.canSeek {
                    rewindBar(companion)
                }
                HStack(spacing: 24) {
                    transportButton("chevron.down", label: "Channel down", action: onChannelDown)
                    Button(action: onTogglePlayPause) {
                        ZStack {
                            Circle().fill(Color.accentColor).frame(width: 74, height: 74)
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 30, weight: .bold))
                                .foregroundStyle(.black)
                        }
                    }
                    .accessibilityLabel(isPlaying ? "Pause" : "Play")
                    transportButton("chevron.up", label: "Channel up", action: onChannelUp)
                    if companion != nil || cast != nil {
                        transportButton("slider.horizontal.3", label: "Options") { showOptions = true }
                    }
                    transportButton("xmark", label: stopLabel, action: onStop)
                }
                .padding(.bottom, 48)
            }
            .padding(.horizontal, 24)
        }
        .sheet(isPresented: $showOptions) {
            if let companion {
                RemoteOptionsSheet(companion: companion)
            } else if let cast {
                CastOptionsSheet(cast: cast)
            }
        }
    }

    /// Live-rewind scrubber + ±30s + Go Live (companion only, when a rewind
    /// buffer is rolling on the TV).
    @ViewBuilder
    private func rewindBar(_ companion: CompanionClient) -> some View {
        let s = companion.remoteState
        let span = max(1, Double(s.windowEndMs - s.windowStartMs))
        let frac = min(1, max(0, Double(s.positionWallMs - s.windowStartMs) / span))
        VStack(spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.2)).frame(height: 5)
                    Capsule().fill(Color.accentColor)
                        .frame(width: geo.size.width * frac, height: 5)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onEnded { g in
                    let f = min(1, max(0, g.location.x / geo.size.width))
                    let target = s.windowStartMs + Int64(f * span)
                    companion.seekToWall(target)
                })
            }
            .frame(height: 24)
            HStack {
                Button("−30s") { companion.seekBy(-30_000) }
                Spacer()
                Text(s.isLive ? "LIVE" : "REWOUND")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(s.isLive ? Color.accentColor : .white.opacity(0.6))
                Spacer()
                Button("+30s") { companion.seekBy(30_000) }
                Button("Go Live") { companion.goLive() }
            }
            .font(.callout)
            .foregroundStyle(.white)
        }
        .padding(.bottom, 12)
    }

    private func transportButton(_ symbol: String, label: String,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Color.white.opacity(0.12)).frame(width: 58, height: 58)
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .accessibilityLabel(label)
    }
}

// MARK: - Companion options sheet (audio / subtitles / speed / aspect / info)

/// Full options picker for the companion remote -- parity with the Android
/// CastRemoteOverlay's Options menu. Drives the TV via CompanionClient.
struct RemoteOptionsSheet: View {
    @ObservedObject var companion: CompanionClient
    @Environment(\.dismiss) private var dismiss
    @State private var showSwitchStream = false
    @State private var showRecord = false

    private let speeds: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
    private let aspects: [(key: String, label: String)] =
        [("fit", "Fit"), ("fill", "Fill"), ("zoom", "Zoom")]
    private let sleepChoices: [(minutes: Int, label: String)] =
        [(0, "Off"), (30, "30 minutes"), (60, "1 hour"), (90, "1.5 hours"), (120, "2 hours")]

    /// The controlled channel resolved locally, for actions the phone drives
    /// against Dispatcharr itself (Record) -- same anchor as Switch Stream
    /// but without the admin-credentials gate.
    private var controlledItem: ChannelDisplayItem? {
        guard let cid = companion.controllingChannelID, cid.hasPrefix("disp:")
        else { return nil }
        let uuid = String(cid.dropFirst(5))
        return ChannelStore.shared.channels.first(where: { $0.uuid == uuid })
    }

    /// The controlled channel resolved on THIS phone, when Switch Stream can
    /// work: Dispatcharr swaps the source server-side while the TV keeps
    /// playing the same proxy URL, so the phone can drive the swap directly
    /// (same pk/uuid/admin gate as the native player's Switch Stream row).
    private var switchStreamTarget: (id: Int, uuid: String, name: String)? {
        guard let cid = companion.controllingChannelID,
              cid.hasPrefix("disp:"),
              ChannelStore.shared.activeServer?.dispatcharrCanSwitchStream ?? false
        else { return nil }
        let uuid = String(cid.dropFirst(5))
        guard let item = ChannelStore.shared.channels.first(where: { $0.uuid == uuid }),
              let pk = item.dispatcharrChannelID
        else { return nil }
        return (pk, uuid, item.name)
    }

    var body: some View {
        NavigationStack {
            List {
                let s = companion.remoteState
                if !s.audio.isEmpty {
                    Section("Audio") {
                        ForEach(s.audio) { t in
                            row(t.label, checked: t.selected) { companion.setAudioTrack(t.id) }
                        }
                    }
                }
                Section("Subtitles") {
                    row("Off", checked: s.textOff) { companion.setTextTrack(nil) }
                    ForEach(s.text) { t in
                        row(t.label, checked: t.selected) { companion.setTextTrack(t.id) }
                    }
                }
                Section("Speed") {
                    ForEach(speeds, id: \.self) { sp in
                        row(sp == 1 ? "Normal" : "\(speedLabel(sp))×",
                            checked: abs(s.speed - sp) < 0.01) { companion.setSpeed(sp) }
                    }
                }
                Section("Aspect Ratio") {
                    ForEach(aspects, id: \.key) { a in
                        row(a.label, checked: s.aspect == a.key) { companion.setAspect(a.key) }
                    }
                }
                if switchStreamTarget != nil {
                    Section {
                        Button {
                            showSwitchStream = true
                        } label: {
                            Label("Switch Stream", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                }
                // Android companion-overlay parity: Record / Sleep Timer /
                // Audio Only ride the same options surface.
                Section {
                    if controlledItem?.dispatcharrChannelID != nil {
                        Button {
                            CompanionClient.clog("Record Current Program opened for \(controlledItem?.name ?? "?")")
                            showRecord = true
                        } label: {
                            Label("Record Current Program", systemImage: "record.circle")
                        }
                    }
                    Menu {
                        ForEach(sleepChoices, id: \.minutes) { c in
                            Button(c.label) { companion.armSleepTimer(minutes: c.minutes) }
                        }
                    } label: {
                        HStack {
                            Label("Sleep Timer", systemImage: "timer")
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(sleepValueLabel)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button {
                        companion.setAudioOnly(!s.audioOnly)
                    } label: {
                        HStack {
                            Label("Audio Only", systemImage: "music.note")
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(s.audioOnly ? "On" : "Off")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if !s.streamInfo.isEmpty {
                    Section("Stream Info") {
                        Text(s.streamInfo).font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showSwitchStream) {
                if let t = switchStreamTarget {
                    SwitchStreamView(channelID: t.id, channelUUID: t.uuid, channelName: t.name)
                }
            }
            .sheet(isPresented: $showRecord) {
                if let item = controlledItem {
                    let now = Date()
                    RecordProgramSheet(
                        programTitle: item.currentProgram ?? "\(item.name) live recording",
                        programDescription: item.currentProgramDescription ?? "",
                        channelID: item.id,
                        channelName: item.name,
                        scheduledStart: item.currentProgramStart ?? now,
                        scheduledEnd: (item.currentProgramEnd.flatMap { $0 > now ? $0 : nil })
                            ?? now.addingTimeInterval(3600),
                        isLive: true,
                        dispatcharrChannelID: item.dispatcharrChannelID,
                        streamURL: item.streamURL
                    )
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var sleepValueLabel: String {
        guard let end = companion.sleepEndsAt else { return "Off" }
        let mins = max(1, Int(end.timeIntervalSinceNow / 60) + 1)
        return "\(mins)m left"
    }

    private func row(_ label: String, checked: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(label).foregroundStyle(.primary)
                Spacer()
                if checked { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
        }
    }

    private func speedLabel(_ s: Double) -> String {
        s == s.rounded() ? String(Int(s)) : String(format: "%g", s)
    }
}

// MARK: - Cast options sheet (task #267, Android cast-options parity)

/// Options for the BASIC cast transport (web receiver). The receiver has
/// no control channel, so unlike RemoteOptionsSheet everything here is
/// phone-driven: Switch Stream swaps the Dispatcharr upstream behind the
/// proxy's unchanged ingest URL (the reprime observer in
/// AerioCastController re-splices the proxy), Record talks to the
/// Dispatcharr DVR API directly, the sleep timer is a phone-side countdown
/// that stops the cast, and Stream Info renders the local HLS proxy's own
/// stats (there is no player on the phone to ask). The Android cast
/// overlay's receiver-state rows (audio/subtitles/speed/aspect/audio-only)
/// need a control channel the web receiver lacks, so they are omitted.
struct CastOptionsSheet: View {
    @ObservedObject var cast: AerioCastController
    @Environment(\.dismiss) private var dismiss
    @State private var showSwitchStream = false
    @State private var showRecord = false
    @State private var stats: CastHLSProxySession.Stats?

    private let sleepChoices: [(minutes: Int, label: String)] =
        [(0, "Off"), (30, "30 minutes"), (60, "1 hour"), (90, "1.5 hours"), (120, "2 hours")]

    /// The channel the TV is playing, resolved locally (castingContent
    /// carries the id; ChannelStore has the Dispatcharr fields).
    private var castItem: ChannelDisplayItem? {
        guard let id = cast.castingContent?.mediaID else { return nil }
        return ChannelStore.shared.channels.first(where: { $0.id == id })
    }

    /// Same pk/uuid/admin gate as the native player's Switch Stream row
    /// (and the companion sheet's).
    private var switchStreamTarget: (id: Int, uuid: String, name: String)? {
        guard ChannelStore.shared.activeServer?.dispatcharrCanSwitchStream ?? false,
              let item = castItem,
              let uuid = item.uuid, !uuid.isEmpty,
              let pk = item.dispatcharrChannelID
        else { return nil }
        return (pk, uuid, item.name)
    }

    var body: some View {
        NavigationStack {
            List {
                if switchStreamTarget != nil {
                    Section {
                        Button {
                            showSwitchStream = true
                        } label: {
                            Label("Switch Stream", systemImage: "arrow.triangle.2.circlepath")
                        }
                    } footer: {
                        Text("Swaps this channel's upstream. The TV keeps playing; the picture follows in a few seconds.")
                    }
                }
                Section {
                    if castItem?.dispatcharrChannelID != nil {
                        Button {
                            showRecord = true
                        } label: {
                            Label("Record Current Program", systemImage: "record.circle")
                        }
                    }
                    Menu {
                        ForEach(sleepChoices, id: \.minutes) { c in
                            Button(c.label) { cast.armSleepTimer(minutes: c.minutes) }
                        }
                    } label: {
                        HStack {
                            Label("Sleep Timer", systemImage: "timer")
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(sleepValueLabel)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Stream Info") {
                    if let stats {
                        CastStreamInfoCard(stats: stats,
                                           receiverName: cast.connectedDeviceName)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    } else {
                        Text("Waiting for the cast proxy to report.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showSwitchStream) {
                if let t = switchStreamTarget {
                    SwitchStreamView(channelID: t.id, channelUUID: t.uuid, channelName: t.name)
                }
            }
            .sheet(isPresented: $showRecord) {
                if let item = castItem {
                    let now = Date()
                    RecordProgramSheet(
                        programTitle: item.currentProgram ?? "\(item.name) live recording",
                        programDescription: item.currentProgramDescription ?? "",
                        channelID: item.id,
                        channelName: item.name,
                        scheduledStart: item.currentProgramStart ?? now,
                        scheduledEnd: (item.currentProgramEnd.flatMap { $0 > now ? $0 : nil })
                            ?? now.addingTimeInterval(3600),
                        isLive: true,
                        dispatcharrChannelID: item.dispatcharrChannelID,
                        streamURL: item.streamURL
                    )
                }
            }
        }
        .presentationDetents([.medium, .large])
        // ~1 Hz stats poll while the sheet is up; statsSnapshot is one
        // short hop onto the proxy's session queue.
        .task {
            while !Task.isCancelled {
                stats = CastHLSProxySession.shared.statsSnapshot()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private var sleepValueLabel: String {
        guard let end = cast.sleepEndsAt else { return "Off" }
        let mins = max(1, Int(end.timeIntervalSinceNow / 60) + 1)
        return "\(mins)m left"
    }
}

/// The proxy's own numbers in the app's Stream Info card treatment
/// (StreamInfoCardView's monospaced label/value rows): what the phone is
/// ingesting, what it serves, and how the pipeline is pacing.
private struct CastStreamInfoCard: View {
    let stats: CastHLSProxySession.Stats
    let receiverName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row(label: "SOURCE", value: stats.ingestHost)
            row(label: "VIDEO", value: stats.videoCodec ?? "detecting")
            row(label: "AUDIO", value: stats.audioPath ?? "detecting")
            row(label: "SEGS", value: "\(stats.segmentsProduced) produced  gen \(stats.generation)")
            row(label: "RATE", value: rateLine)
            row(label: "PROXY", value: "HLS on port \(stats.port)")
            row(label: "TV", value: receiverName ?? "-")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    /// Latest completed per-8-segment rollup (the same numbers the proxy
    /// logs); "measuring" until the first rollup lands (~24 s in).
    private var rateLine: String {
        guard let kbps = stats.lastRollupKbps else { return "measuring" }
        var line = "\(kbps) kbps"
        if let avg = stats.lastRollupAvgSegmentSeconds {
            line += String(format: "  avg seg %.2fs", avg)
        }
        return line
    }

    @ViewBuilder
    private func row(label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(Color.accentPrimary)
                .frame(width: 46, alignment: .trailing)
            Text(value)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.primary.opacity(0.9))
        }
    }
}

// MARK: - Floating "Control TV" pill

/// Shown above the tab bar whenever a controllable AerioTV TV is discovered on
/// the LAN -- so the phone can act as a remote for whatever the TV is already
/// playing WITHOUT first opening a channel here (user request 2026-07-16).
struct CompanionControlFAB: View {
    @ObservedObject private var theme: ThemeManager = .shared
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "tv.and.mediabox")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(theme.accent)
                .frame(width: 52, height: 52)
        }
        .liquidGlass(cornerRadius: 26)
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        .accessibilityLabel("Control a TV")
    }
}

// MARK: - Companion device picker sheet

/// Lists discovered AerioTV Android TVs; pick one -> connect (remembered token
/// auto-authenticates), or the TV shows a 6-digit code entered inline here.
// MARK: - Unified sectioned output picker (task #225)

/// Discovered Google Cast devices for the unified picker. The SDK's
/// GCKUICastButton owns its own modal chooser; the sectioned sheet needs the
/// raw device list, so this thin wrapper mirrors GCKDiscoveryManager into
/// SwiftUI. Listener callbacks arrive on the main thread per the Cast SDK
/// contract; the Task hop keeps that assumption out of the type system the
/// same way AerioCastController's own observers do.
final class CastDeviceList: NSObject, ObservableObject, GCKDiscoveryManagerListener {
    @Published private(set) var devices: [GCKDevice] = []

    private var manager: GCKDiscoveryManager {
        GCKCastContext.sharedInstance().discoveryManager
    }

    func start() {
        manager.add(self)
        manager.startDiscovery()
        reload()
    }

    func stop() {
        manager.remove(self)
    }

    private func reload() {
        let m = manager
        var list: [GCKDevice] = []
        for i in 0..<m.deviceCount { list.append(m.device(at: i)) }
        devices = list
    }

    func didUpdateDeviceList() {
        // Cast SDK delivers listener callbacks on the main thread (SDK
        // contract), so the @Published mutation in reload() is main-safe
        // without an executor hop.
        reload()
    }
}

/// Task #225: ONE sectioned output picker replacing the separate Cast /
/// AirPlay / Control-a-TV chrome buttons (Android CastControls.kt "Cast to"
/// dialog twin, plus the iOS-only AirPlay section). Fixed section order:
///
///   "AerioTV Remote" - companion devices (full native player on the TV,
///                      no codec limits)
///   "Google Cast"    - Cast SDK devices (web receiver, Dispatcharr-only)
///   "AirPlay"        - hands off to the system route sheet
///
/// A section renders only when its transport is currently usable for the
/// playing content -- the host passes the same gates the three buttons used.
/// Transports are mutually exclusive (Android parity): picking one tears the
/// other down first.
struct CastPickerSheet: View {
    /// Cast section gate: devices may exist AND the channel is basic-castable.
    let showGoogleCast: Bool
    /// AirPlay section gate: the session rides AVPlayer (video routes exist).
    let showAirPlay: Bool

    @ObservedObject private var companion = CompanionClient.shared
    @ObservedObject private var castController = AerioCastController.shared
    @StateObject private var castDevices = CastDeviceList()
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""

    var body: some View {
        NavigationStack {
            List {
                // Active connection first, with its teardown action (the
                // Android dialog's "Stop casting" / "Disconnect TV" buttons).
                if castController.isCasting {
                    Section {
                        Button(role: .destructive) {
                            castController.stopCasting()
                        } label: {
                            Label("Stop casting", systemImage: "stop.circle")
                        }
                    }
                }
                if companion.isControlling {
                    Section {
                        Button(role: .destructive) {
                            companion.disconnect()
                        } label: {
                            Label("Disconnect TV", systemImage: "stop.circle")
                        }
                    }
                }
                if case .needsPairing(let name) = companion.conn {
                    Section("Enter the code shown on \(name ?? "the TV")") {
                        TextField("6-digit code", text: $code)
                            .keyboardType(.numberPad)
                            .font(.title3.monospaced())
                        Button("Pair") {
                            companion.submitPairingCode(code)
                            code = ""
                        }
                        .disabled(code.trimmingCharacters(in: .whitespaces).count < 6)
                    }
                } else if case .connecting(let name) = companion.conn {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Connecting to \(name ?? "TV")…").padding(.leading, 8)
                        }
                    }
                }
                if !companion.devices.isEmpty {
                    Section("AerioTV Remote") {
                        ForEach(companion.devices) { tv in
                            Button {
                                // One remote target at a time (Android parity).
                                castController.stopCasting()
                                companion.connect(to: tv)
                            } label: {
                                Label(tv.name, systemImage: "tv")
                            }
                        }
                    }
                }
                if showGoogleCast {
                    Section("Google Cast") {
                        if castDevices.devices.isEmpty {
                            Text("Searching for devices…")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(castDevices.devices, id: \.deviceID) { device in
                            Button {
                                if !companion.isControlling { companion.disconnect() }
                                GCKCastContext.sharedInstance().sessionManager
                                    .startSession(with: device)
                            } label: {
                                Label(device.friendlyName ?? "Cast device",
                                      systemImage: "sparkles.tv")
                            }
                        }
                    }
                }
                if showAirPlay {
                    Section("AirPlay") {
                        Button {
                            dismiss()
                            // The system route sheet replaces this one; see
                            // AirPlayMenuTrigger for the hidden-picker detail.
                            AirPlayMenuTrigger.present()
                        } label: {
                            Label("Choose AirPlay output…", systemImage: "airplay.video")
                        }
                    }
                }
                if companion.devices.isEmpty && !showGoogleCast && !showAirPlay {
                    Text("No AerioTV devices found. Open AerioTV on your TV, then check again.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(
                castController.isCasting || companion.isControlling ? "Connected" : "Cast to"
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        // Cancel an in-flight / unpaired companion attempt so
                        // it doesn't stay retained + spinning after the sheet
                        // is gone; a fully connected session is left alone.
                        if !companion.isControlling { companion.disconnect() }
                        dismiss()
                    }
                }
            }
        }
        // Unconditional: the device-list mirror must run even while the gate
        // still reads unavailable, or a sheet opened before the first
        // discovery results can never grow the Google Cast section.
        .onAppear { castDevices.start() }
        .onDisappear { castDevices.stop() }
        // Freshly connected on either transport -> the picker's job is done;
        // the remote cover (HomeView) takes over.
        .onChange(of: companion.isControlling) { _, controlling in
            if controlling { dismiss() }
        }
        .onChange(of: castController.state) { _, state in
            if case .connected = state { dismiss() }
        }
        .presentationDetents([.medium])
    }
}

struct CompanionPickerSheet: View {
    @ObservedObject private var companion = CompanionClient.shared
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""

    var body: some View {
        NavigationStack {
            List {
                if case .needsPairing(let name) = companion.conn {
                    Section("Enter the code shown on \(name ?? "the TV")") {
                        TextField("6-digit code", text: $code)
                            .keyboardType(.numberPad)
                            .font(.title3.monospaced())
                        Button("Pair") {
                            companion.submitPairingCode(code)
                            code = ""
                        }
                        .disabled(code.trimmingCharacters(in: .whitespaces).count < 6)
                    }
                } else if case .connecting(let name) = companion.conn {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Connecting to \(name ?? "TV")…").padding(.leading, 8)
                        }
                    }
                }
                Section("AerioTV devices") {
                    if companion.devices.isEmpty {
                        Text("No AerioTV devices found. Open AerioTV on your TV, then check again.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(companion.devices) { tv in
                        Button {
                            companion.connect(to: tv)
                        } label: {
                            Label(tv.name, systemImage: "tv")
                        }
                    }
                }
            }
            .navigationTitle("Control a TV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        // Cancel an in-flight / unpaired attempt so it doesn't
                        // stay retained + spinning after the sheet is gone
                        // (review 2026-07-16). A fully connected session is
                        // left alone -- its cover takes over.
                        if !companion.isControlling { companion.disconnect() }
                        dismiss()
                    }
                }
            }
        }
        // Freshly connected -> the picker's job is done; the remote cover
        // (HomeView) takes over. presentationDetents keep it compact.
        .onChange(of: companion.isControlling) { _, controlling in
            if controlling { dismiss() }
        }
        .presentationDetents([.medium])
    }
}
#endif

// MARK: - Companion HOST (tvOS) -- phones control THIS Apple TV

#if os(tvOS)
import Foundation
import Network
import SwiftUI
import UIKit

/// tvOS mirror of the Android CompanionHostController: advertises `_aeriotv._tcp`
/// over mDNS and runs a native WebSocket server (NWListener + NWProtocolWebSocket,
/// no third-party dep). A paired phone (the iOS CompanionClient OR the Android
/// companion client -- same wire format) drives THIS Apple TV's player: tune a
/// channel, play/pause. Speaks the identical CompanionProtocol/CastControl JSON,
/// so no client change is needed to control an Apple TV.
///
/// Security parity with the Android host (adversarial-review-hardened): control
/// is refused until authenticated; a wrong 6-digit code both counts against a
/// per-connection budget AND rotates the displayed code (the space can't be
/// swept); the code clears when the last unpaired socket drops. (Origin-header
/// rejection isn't exposed by NWProtocolWebSocket's built-in upgrade the way
/// Ktor exposes it; the token/code gate is the real protection and a
/// browser-scripted socket still can't control without the code.)
@MainActor
final class CompanionHost: NSObject, ObservableObject {

    static let shared = CompanionHost()

    /// 6-digit code to show on the TV while a phone is pairing (nil = hidden).
    @Published private(set) var pairingCode: String?

    /// Transient on-TV confirmation ("Phone connected"); auto-clears.
    @Published private(set) var toast: String?
    private var toastClear: Task<Void, Never>?

    private func showToast(_ message: String) {
        toast = message
        toastClear?.cancel()
        toastClear = Task { @MainActor [weak self] in
            // 4.5s: TV-glanceable (the viewer looks up from the phone).
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    private final class Session {
        let conn: NWConnection
        var authed = false
        var wasPairing = false
        var codeAttempts = 0
        init(_ conn: NWConnection) { self.conn = conn }
    }

    private var listener: NWListener?
    /// The name Bonjour actually registered us under (the user's Apple TV name,
    /// e.g. "Living Room"); nil until the first registration lands.
    private var advertisedName: String?
    private var sessions: [ObjectIdentifier: Session] = [:]
    private var pairingWaiters = 0
    private var started = false
    private var ticker: Task<Void, Never>?

    private static let maxCodeAttempts = 5
    private static let tokensKey = "companion.host.tokens"
    private static let deviceIDKey = "companion.host.deviceId"

    // MARK: Advertise + serve

    func start() {
        guard !started else { return }
        do {
            let params = NWParameters.tcp
            let ws = NWProtocolWebSocket.Options()
            ws.autoReplyPing = true
            params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
            // Ephemeral port (nil) -- the advertised Bonjour service carries the
            // real port, same as the Android host's port-0 bind.
            let listener = try NWListener(using: params)
            let txt = NWTXTRecord(["v": "1", "id": Self.deviceID()])
            // name: nil -> mDNSResponder registers under the system default
            // service name, which IS the user-assigned Apple TV name ("Living
            // Room"), the same name AirPlay shows. The app can't read that name
            // directly (UIDevice.name is privacy-generic "Apple TV" on tvOS 16+
            // without a special entitlement), but Bonjour fills it in daemon-side
            // and reports the final registered name back below.
            listener.service = NWListener.Service(
                name: nil, type: "_aeriotv._tcp", domain: nil, txtRecord: txt
            )
            listener.serviceRegistrationUpdateHandler = { [weak self] change in
                if case .add(let endpoint) = change,
                   case .service(let name, _, _, _) = endpoint {
                    Task { @MainActor in self?.advertisedName = name }
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in self?.accept(conn) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                // .cancelled too: tvOS kills the listener when the app
                // suspends (Home press / TV sleep), and it does NOT come back
                // as .failed -- leaving `started` true made start() a no-op on
                // return, so the Apple TV silently stopped advertising until a
                // full app relaunch (found 2026-07-16: iPhone saw the Streamer
                // but never the ATV).
                switch state {
                case .failed, .cancelled:
                    Task { @MainActor in self?.started = false; self?.listener = nil }
                default:
                    break
                }
            }
            listener.start(queue: .main)
            self.listener = listener
            started = true
        } catch {
            started = false
        }
        // Watchdog (parity with the Android host): whatever tears the listener
        // down while the app stays frontmost, bring the advert back.
        if watchdog == nil {
            watchdog = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    await MainActor.run { self?.ensureRunning() }
                }
            }
        }
    }

    /// Restart advertising if the listener is gone or dead. Called on scene
    /// foreground and by the watchdog; cheap no-op while healthy.
    func ensureRunning() {
        guard UIApplication.shared.applicationState == .active else { return }
        if let l = listener {
            switch l.state {
            case .ready, .setup, .waiting:
                return // healthy or still coming up
            default:
                break
            }
        }
        started = false
        listener?.cancel()
        listener = nil
        start()
    }

    private var watchdog: Task<Void, Never>?

    private func accept(_ conn: NWConnection) {
        let session = Session(conn)
        sessions[ObjectIdentifier(conn)] = session
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { @MainActor in self?.drop(conn) }
            default:
                break
            }
        }
        conn.start(queue: .main)
        // Hello immediately (needsPairing=true; the phone answers with a
        // remembered token or asks the user for the code).
        send(hello(), to: conn)
        receive(conn)
    }

    private func receive(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            Task { @MainActor in
                guard let self else { return }
                if let data, let text = String(data: data, encoding: .utf8) {
                    self.handle(text, conn: conn)
                }
                if error == nil, self.sessions[ObjectIdentifier(conn)] != nil {
                    self.receive(conn)
                } else {
                    self.drop(conn)
                }
            }
        }
    }

    private func drop(_ conn: NWConnection) {
        guard let session = sessions.removeValue(forKey: ObjectIdentifier(conn)) else { return }
        conn.cancel()
        // Last unpaired pairing socket gone -> take the code overlay down.
        if session.wasPairing, !session.authed {
            pairingWaiters = max(0, pairingWaiters - 1)
            if pairingWaiters == 0 { pairingCode = nil }
        }
        if sessions.values.allSatisfy({ !$0.authed }) {
            ticker?.cancel(); ticker = nil
        }
    }

    // MARK: Handshake + control

    private func handle(_ text: String, conn: NWConnection) {
        guard let session = sessions[ObjectIdentifier(conn)],
              let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        if let type = json["t"] as? String, !type.isEmpty {
            guard type == "auth" else { return }
            let token = json["token"] as? String ?? ""
            let code = json["code"] as? String ?? ""
            if let issued = tryAuth(token: token, code: code) {
                session.authed = true
                pairingCode = nil
                send(authOk(token: issued), to: conn)
                startTickerIfNeeded()
                sendState(to: conn)   // full snapshot on connect
                pushPosition(to: conn)
                showToast("Phone connected")
                DebugLogger.shared.log("[Companion] host: phone authed (\(token.isEmpty ? "code" : "token"))",
                                       category: "Companion")
                return
            }
            // Wrong code: count it AND rotate the code (can't be brute-swept).
            if !code.isEmpty {
                session.codeAttempts += 1
                pairingCode = nil
            }
            if session.codeAttempts >= Self.maxCodeAttempts {
                send(authFail(reason: "badCode"), to: conn)
                drop(conn)
                return
            }
            if !session.wasPairing { session.wasPairing = true; pairingWaiters += 1 }
            ensurePairingCode()
            send(authFail(reason: token.isEmpty ? "badCode" : "badToken"), to: conn)
            return
        }

        guard session.authed else { return } // control refused pre-auth
        let ps = MultiviewStore.shared.audioProgressStore
        let cmd = json["cmd"] as? String
        if let cmd, cmd != "getState" {
            DebugLogger.shared.log("[Companion] host cmd: \(cmd)", category: "Companion")
        }
        switch cmd {
        case "setChannel":
            if let id = json["channelId"] as? String { openChannel(id) }
        case "toggle":
            ps?.togglePauseAction?()
        case "play":
            if ps?.isPaused == true { ps?.togglePauseAction?() }
        case "pause":
            if ps?.isPaused == false { ps?.togglePauseAction?() }
        // Full options parity with the Cast receiver / Android host: drive the
        // live coordinator's programmatic surface off the audio tile's store.
        case "setAudio":
            if let id = intArg(json["id"]) { ps?.setAudioTrackAction?(id) }
        case "setText":
            // "" / absent id = Off (track 0). mpv sid=no.
            ps?.setSubtitleTrackAction?(intArg(json["id"]) ?? 0)
        case "setSpeed":
            if let s = json["speed"] as? Double { ps?.setSpeedAction?(s) }
        case "setAspect":
            if let key = json["aspect"] as? String {
                let mode = Self.aspectMode(fromKey: key)
                ps?.aspectMode = mode
                UserDefaults.standard.set(mode.rawValue, forKey: "player.aspectMode")
            }
        case "setAudioOnly":
            // Android-host parity: drop/restore the video track (audio keeps
            // playing, screen goes dark) rather than an overlay-only flag.
            ps?.setVideoEnabledAction?(!(json["audioOnly"] as? Bool ?? false))
        case "seekBy":
            // window-relative: current playhead + signed delta (Live Rewind).
            if let store = ps, let delta = intArg64(json["deltaMs"]) {
                store.seekAction?(Int32(clamping: Int64(store.currentMs) + delta))
            }
        case "seekWall":
            // absolute wall-clock -> window-relative (target - buffer tail).
            if let target = intArg64(json["targetWallMs"]) {
                let rel = target - LiveRewindEngine.shared.tailWallMs
                ps?.seekAction?(Int32(clamping: rel))
            }
        case "goLive":
            // Seek past the head (>= window length) routes to the live edge.
            let window = LiveRewindEngine.shared.headWallMs - LiveRewindEngine.shared.tailWallMs
            ps?.seekAction?(Int32(clamping: window))
        case "getState":
            break // the state reply below answers it
        default:
            break
        }
        // Mirror the Android host: after EVERY command push the full snapshot
        // (so the phone's pickers/scrubber stay in sync) + the position tick.
        sendState(to: conn)
        // mpv applies track/speed changes asynchronously, so the immediate
        // push above can still carry the PRE-change selection (2026-07-16
        // path-1 test: TV rendered the subtitle but the phone's checkmark
        // stayed on Off). Re-push once the engine has settled.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            self?.sendState(to: conn)
        }
    }

    private func intArg(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let s = v as? String { return Int(s) }
        return nil
    }
    private func intArg64(_ v: Any?) -> Int64? {
        if let i = v as? Int64 { return i }
        if let i = v as? Int { return Int64(i) }
        if let d = v as? Double { return Int64(d) }
        if let s = v as? String { return Int64(s) }
        return nil
    }

    /// Android AspectMode keys (fit/fill/zoom) -> tvOS VideoAspectMode
    /// (fit/fill/stretch). zoom maps to the nearest crop-ish mode.
    private static func aspectMode(fromKey key: String) -> VideoAspectMode {
        switch key {
        case "fill": return .fill
        case "zoom": return .stretch
        default: return .fit
        }
    }
    private static func aspectKey(_ mode: VideoAspectMode) -> String {
        switch mode {
        case .fill: return "fill"
        case .stretch: return "zoom"
        default: return "fit"
        }
    }

    /// Tune a "disp:<uuid>" channel id (Dispatcharr; the only cross-platform
    /// identity) from ANY app state -- begin() enters the player like a fresh
    /// tap, mirroring the Android host's requestOpenChannel path.
    private func openChannel(_ channelID: String) {
        let uuid = channelID.hasPrefix("disp:") ? String(channelID.dropFirst(5)) : channelID
        guard let item = ChannelStore.shared.channels.first(where: { $0.uuid == uuid })
        else {
            DebugLogger.shared.log("[Companion] host openChannel: no channel for \(channelID)",
                                   category: "Companion", level: .warning)
            return
        }
        // A remote setChannel means TUNE, not add-a-tile: with a session
        // already up, begin() takes its multiview-add branch, so the TV
        // keeps the old channel fullscreen (2026-07-17 ATV test: ESPN
        // stayed up when the phone picked ESPN2). Tear down first so
        // begin() reseeds like a fresh tap; same-channel requests are
        // left alone.
        let store = MultiviewStore.shared
        if !store.tiles.isEmpty {
            if store.tiles.count == 1,
               NowPlayingManager.shared.playingItem?.uuid == uuid { return }
            PlayerSession.shared.exit()
        }
        _ = PlayerSession.shared.begin(item: item, server: ChannelStore.shared.activeServer)
    }

    private func tryAuth(token: String, code: String) -> String? {
        var tokens = UserDefaults.standard.stringArray(forKey: Self.tokensKey) ?? []
        if !token.isEmpty, tokens.contains(token) { return token } // remembered
        if !code.isEmpty, let pending = pairingCode, code == pending {
            let fresh = UUID().uuidString
            tokens.append(fresh)
            UserDefaults.standard.set(tokens, forKey: Self.tokensKey)
            return fresh
        }
        return nil
    }

    private func ensurePairingCode() {
        if pairingCode == nil {
            pairingCode = String(format: "%06d", Int.random(in: 0..<1_000_000))
        }
    }

    // MARK: State push

    private func startTickerIfNeeded() {
        guard ticker == nil else { return }
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                for session in self.sessions.values where session.authed {
                    self.pushPosition(to: session.conn)
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    /// Full snapshot (tracks / speed / aspect / stream-info / rewind window) the
    /// phone's option pickers + scrubber render -- the tvOS twin of the Android
    /// host's buildRemoteStateMessage. Built with JSONSerialization so arbitrary
    /// track labels are escaped safely.
    private func sendState(to conn: NWConnection) {
        let ps = MultiviewStore.shared.audioProgressStore
        let rewind = LiveRewindEngine.shared

        func tracks(_ list: [MediaTrack], selectedID: Int) -> [[String: Any]] {
            list.map { ["id": String($0.id), "label": $0.displayName, "selected": $0.id == selectedID] }
        }
        let subSelected = ps?.currentSubtitleTrackID ?? 0

        var state: [String: Any] = [
            "cmd": "state",
            "audio": tracks(ps?.audioTracks ?? [], selectedID: ps?.currentAudioTrackID ?? 0),
            // subtitleTracks are the real tracks; "Off" is the implicit id-0 row
            // the phone always adds, so exclude any 0-id entry here.
            "text": tracks((ps?.subtitleTracks ?? []).filter { $0.id != 0 }, selectedID: subSelected),
            "textOff": subSelected == 0,
            "speed": ps?.speed ?? 1.0,
            "aspect": Self.aspectKey(ps?.aspectMode ?? .fit),
            "audioOnly": ps?.isAudioOnly ?? false,
            "streamInfo": Self.streamInfoLine(ps),
            "canSeek": rewind.buffering,
            "isLive": !rewind.timeshifting,
            "positionWallMs": rewind.tailWallMs + Int64(ps?.currentMs ?? 0),
            "windowStartMs": rewind.tailWallMs,
            "windowEndMs": rewind.headWallMs,
        ]
        // Ensure isPlaying rides the state too (some clients read it off state).
        state["isPlaying"] = ps.map { !$0.isPaused } ?? true
        // Anchor for the phone's channel up/down: what THIS TV is playing, in
        // the shared Android channel-id format. Without it a phone that
        // connected to an already-playing TV had no flip anchor (2026-07-16
        // path-1 test: chevrons were silent no-ops).
        if let item = NowPlayingManager.shared.playingItem {
            if let uuid = item.uuid, !uuid.isEmpty { state["channelId"] = "disp:\(uuid)" }
            state["nowPlaying"] = item.name
        }
        if let data = try? JSONSerialization.data(withJSONObject: state),
           let text = String(data: data, encoding: .utf8) {
            send(text, to: conn)
        }
    }

    /// Lightweight ~1Hz tick: crawling playhead + window + transport state.
    private func pushPosition(to conn: NWConnection) {
        let ps = MultiviewStore.shared.audioProgressStore
        let rewind = LiveRewindEngine.shared
        let playing = ps.map { !$0.isPaused } ?? true
        var pos: [String: Any] = [
            "cmd": "position",
            "isPlaying": playing,
            "isLive": !rewind.timeshifting,
            "canSeek": rewind.buffering,
            "positionWallMs": rewind.tailWallMs + Int64(ps?.currentMs ?? 0),
            "windowStartMs": rewind.tailWallMs,
            "windowEndMs": rewind.headWallMs,
        ]
        // Anchor rides the tick (matches the Android host): a native TV-side
        // channel change would otherwise leave connected phones' flip /
        // Switch-Stream anchor stale until the next command's state push.
        if let uuid = NowPlayingManager.shared.playingItem?.uuid, !uuid.isEmpty {
            pos["channelId"] = "disp:\(uuid)"
        }
        if let data = try? JSONSerialization.data(withJSONObject: pos),
           let text = String(data: data, encoding: .utf8) {
            send(text, to: conn)
        }
    }

    /// One-line decode summary for the phone's Stream Info sheet.
    private static func streamInfoLine(_ ps: PlayerProgressStore?) -> String {
        guard let info = ps?.streamInfo else { return "" }
        var parts: [String] = []
        if info.width > 0, info.height > 0 { parts.append("\(info.width)x\(info.height)") }
        if !info.videoCodec.isEmpty { parts.append(info.videoCodec.uppercased()) }
        if !info.audioCodec.isEmpty { parts.append(info.audioCodec.uppercased()) }
        if info.channels > 0 { parts.append("\(info.channels)ch") }
        if info.bitrate > 0 { parts.append(String(format: "%.1f Mbps", Double(info.bitrate) * 8 / 1_000_000)) }
        return parts.joined(separator: "  ·  ")
    }

    // MARK: Frame builders

    private func hello() -> String {
        let name = Self.jsonEscape(advertisedName ?? Self.deviceName())
        let np = Self.jsonEscape(NowPlayingManager.shared.playingItem?.name ?? "")
        return #"{"t":"hello","v":1,"device":"\#(name)","needsPairing":true,"nowPlaying":"\#(np)"}"#
    }
    private func authOk(token: String) -> String {
        #"{"t":"authOk","token":"\#(Self.jsonEscape(token))"}"#
    }
    private func authFail(reason: String) -> String {
        #"{"t":"authFail","reason":"\#(reason)"}"#
    }

    private func send(_ text: String, to conn: NWConnection) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [meta])
        conn.send(content: text.data(using: .utf8), contentContext: context,
                  isComplete: true, completion: .contentProcessed { _ in })
    }

    private static func jsonEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func deviceName() -> String {
        let n = UIDevice.current.name
        return n.isEmpty ? "Apple TV" : n
    }
    private static func deviceID() -> String {
        if let id = UserDefaults.standard.string(forKey: deviceIDKey) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: deviceIDKey)
        return id
    }
}

/// Full-screen "enter this code on your phone" overlay shown on the Apple TV
/// while a phone is pairing. Mounted at the app root.
struct CompanionPairingOverlay: View {
    @ObservedObject private var host = CompanionHost.shared

    var body: some View {
        // Transient connect confirmation (bottom-center capsule, auto-clears).
        if host.pairingCode == nil, let toast = host.toast {
            VStack {
                Spacer()
                HStack(spacing: 12) {
                    Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                        .foregroundStyle(Color.accentColor)
                    Text(toast)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                }
                .padding(.vertical, 14)
                .padding(.horizontal, 26)
                .background(Capsule().fill(Color.black.opacity(0.78)))
                .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
                .padding(.bottom, 60)
            }
            .transition(.opacity)
            .zIndex(99)
            .animation(.easeInOut(duration: 0.25), value: host.toast)
        }
        if let code = host.pairingCode {
            ZStack {
                Color.black.opacity(0.82).ignoresSafeArea()
                VStack(spacing: 24) {
                    Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                        .font(.system(size: 64))
                        .foregroundStyle(Color.accentColor)
                    Text("Pair your phone")
                        .font(.title.weight(.semibold))
                        .foregroundStyle(.white)
                    Text("Enter this code in AerioTV on your phone")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.7))
                    Text(code)
                        .font(.system(size: 88, weight: .bold, design: .rounded).monospacedDigit())
                        .tracking(16)
                        .foregroundStyle(.white)
                }
                .padding(60)
            }
            .transition(.opacity)
            .zIndex(100)
        }
    }
}
#endif
