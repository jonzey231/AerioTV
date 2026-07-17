//
//  AerioCastController.swift
//  Aerio
//
//  Google Cast iOS SENDER (GH #33). iPhone/iPad only (the Cast SDK has no tvOS
//  sender), so the whole file is #if os(iOS). Casts to the SAME receiver app id
//  (76DC0564) the Android sender uses. That id is a CUSTOM WEB RECEIVER
//  (receiver.html on the repo's gh-pages; bare castMediaElement video, AerioTV
//  idle screen + fading channel banner), so the load carries a directly
//  playable contentURL: the Dispatcharr fMP4+AAC URL
//  ({proxy}?output_format=fmp4&output_profile=2). customData still carries the
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
    // 76DC0564 = the CURRENT console app (custom web receiver). The original
    // CFFD302F app was DELETED 2026-07-15 (console can't change receiver type).
    static let receiverAppID = "76DC0564"

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
        /// Directly playable URL for the CUSTOM WEB receiver (Dispatcharr
        /// fMP4+AAC rewrite, see webCastStreamURL). nil = not basic-castable
        /// (XC/M3U direct source); callers hide the cast affordance then.
        var webCastURL: URL?
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
        // Keep the framework from popping its own "connect" / expanded-controls UI
        // over our player; we drive the session from the chrome.
        options.suspendSessionsWhenBackgrounded = true
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

    /// Channel up/down from the cast cover: each flip is a fresh load on the
    /// web receiver (no custom channel; same as the Android basic-cast tier).
    /// Walks ChannelStore's full list, skipping channels that aren't
    /// basic-castable (no Dispatcharr fMP4 rewrite) so the TV never gets an
    /// unplayable load.
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
    /// channel has no Dispatcharr fMP4 rewrite (not basic-castable).
    static func castContent(for item: ChannelDisplayItem) -> Content? {
        guard let web = webCastStreamURL(item.streamURL ?? item.streamURLs.first) else { return nil }
        return Content(
            mediaID: item.id,
            kind: .live,
            title: item.name,
            subtitle: item.currentProgram,
            artURL: item.logoURL?.absoluteString,
            webCastURL: web
        )
    }

    // MARK: - Loading

    private func load(_ content: Content, on session: GCKCastSession) {
        guard let client = session.remoteMediaClient else { return }
        let isVOD = content.kind == .vod

        let metadata = GCKMediaMetadata(metadataType: isVOD ? .movie : .generic)
        metadata.setString(content.title, forKey: kGCKMetadataKeyTitle)
        if let sub = content.subtitle, !sub.isEmpty {
            metadata.setString(sub, forKey: kGCKMetadataKeySubtitle)
        }
        if let art = content.artURL, let url = URL(string: art) {
            metadata.addImage(GCKImage(url: url, width: 480, height: 270))
        }

        // Use the non-deprecated entity initializer. The channel/movie identity
        // rides in customData; entity is an opaque app-specific identifier.
        let builder = GCKMediaInformationBuilder(entity: content.mediaID)
        builder.streamType = isVOD ? .buffered : .live
        // The custom WEB receiver (76DC0564) plays contentURL directly: the
        // Dispatcharr fMP4+AAC rewrite. Its LOAD interceptor normalizes LIVE
        // duration to -1, so no duration is set here.
        builder.contentURL = content.webCastURL
        builder.contentType = "video/mp4"
        builder.metadata = metadata
        builder.customData = [
            AerioCast.keyMediaID: content.mediaID,
            AerioCast.keyKind: isVOD ? AerioCast.kindVOD : AerioCast.kindLive,
        ]
        let mediaInfo = builder.build()

        let requestBuilder = GCKMediaLoadRequestDataBuilder()
        requestBuilder.mediaInformation = mediaInfo
        requestBuilder.autoplay = true
        client.loadMedia(with: requestBuilder.build())
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
        syncCastState(GCKCastContext.sharedInstance().castState)
        defer { castingContent = nil }
        guard let content = castingContent,
              let item = ChannelStore.shared.channels.first(where: { $0.id == content.mediaID })
        else { return }
        _ = PlayerSession.shared.begin(item: item, server: ChannelStore.shared.activeServer)
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

    func startDiscovery() {
        guard browser == nil else { return }
        let b = NWBrowser(
            for: .bonjourWithTXTRecord(type: "_aeriotv._tcp", domain: nil),
            using: NWParameters()
        )
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let tvs: [TV] = results.compactMap { result in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                var stableID = name
                if case .bonjour(let txt) = result.metadata,
                   let id = txt.dictionary["id"], !id.isEmpty {
                    stableID = id
                }
                return TV(id: stableID, name: name, endpoint: result.endpoint)
            }.sorted { $0.name.lowercased() < $1.name.lowercased() }
            Task { @MainActor [weak self] in self?.devices = tvs }
        }
        b.start(queue: .main)
        browser = b
    }

    func stopDiscovery() {
        browser?.cancel()
        browser = nil
        devices = []
    }

    // MARK: Connection

    func connect(to tv: TV) {
        // Mutual exclusion with casting: cast is the heavier transport and
        // wins (review 2026-07-16). The companion picker button is already
        // hidden while casting; this guards the programmatic path too.
        guard !AerioCastController.shared.isCasting else { return }
        disconnect(userInitiated: false)
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

    private func handle(_ json: [String: Any]) {
        if let t = json["t"] as? String, !t.isEmpty {
            switch t {
            case "hello":
                if let np = json["nowPlaying"] as? String, !np.isEmpty { nowPlaying = np }
            case "authOk":
                if let token = json["token"] as? String, !token.isEmpty { storeToken(token) }
                conn = .connected(currentTV?.name)
                onControllingStarted()
                requestState()
            case "authFail":
                conn = .needsPairing(currentTV?.name)
            default:
                break
            }
            return
        }
        switch json["cmd"] as? String {
        case "state":
            remoteState = Self.decodeState(json)
            if let playing = json["isPlaying"] as? Bool { remoteIsPlaying = playing }
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
        generation += 1
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        resolver?.cancel()
        resolver = nil
        if userInitiated || conn != .idle {
            conn = .idle
            controllingChannelID = nil
            nowPlaying = ""
            remoteState = RemoteState()
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

    func setChannel(_ androidChannelID: String, title: String?) {
        controllingChannelID = androidChannelID
        if let title, !title.isEmpty { nowPlaying = title }
        sendJSON(["cmd": "setChannel", "channelId": androidChannelID])
    }

    func togglePlayPause() { sendJSON(["cmd": "toggle"]) }

    // Full options surface (parity with the Android companion overlay).
    func requestState() { sendJSON(["cmd": "getState"]) }
    func setAudioTrack(_ id: String) { sendJSON(["cmd": "setAudio", "id": id]) }
    func setTextTrack(_ id: String?) { sendJSON(["cmd": "setText", "id": id ?? ""]) }
    func setSpeed(_ speed: Double) { sendJSON(["cmd": "setSpeed", "speed": speed]) }
    func setAspect(_ key: String) { sendJSON(["cmd": "setAspect", "aspect": key]) }
    func seekBy(_ deltaMs: Int64) { sendJSON(["cmd": "seekBy", "deltaMs": deltaMs]) }
    func seekToWall(_ ms: Int64) { sendJSON(["cmd": "seekWall", "targetWallMs": ms]) }
    func goLive() { sendJSON(["cmd": "goLive"]) }

    /// Channel up/down: walk ChannelStore for the next Dispatcharr channel
    /// (companion ids only translate for Dispatcharr sources).
    func flipChannel(_ delta: Int) {
        let channels = ChannelStore.shared.channels
        guard let currentID = controllingChannelID,
              var idx = channels.firstIndex(where: { Self.androidChannelID(for: $0) == currentID })
        else { return }
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

    @State private var showOptions = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
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
                    if companion != nil {
                        transportButton("slider.horizontal.3", label: "Options") { showOptions = true }
                    }
                    transportButton("xmark", label: stopLabel, action: onStop)
                }
                .padding(.bottom, 48)
            }
            .padding(.horizontal, 24)
        }
        .sheet(isPresented: $showOptions) {
            if let companion { RemoteOptionsSheet(companion: companion) }
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

    private let speeds: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
    private let aspects: [(key: String, label: String)] =
        [("fit", "Fit"), ("fill", "Fill"), ("zoom", "Zoom")]

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
        }
        .presentationDetents([.medium, .large])
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

    private final class Session {
        let conn: NWConnection
        var authed = false
        var wasPairing = false
        var codeAttempts = 0
        init(_ conn: NWConnection) { self.conn = conn }
    }

    private var listener: NWListener?
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
            listener.service = NWListener.Service(
                name: Self.deviceName(), type: "_aeriotv._tcp", domain: nil, txtRecord: txt
            )
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
        switch json["cmd"] as? String {
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
        else { return }
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
            "audioOnly": false,
            "streamInfo": Self.streamInfoLine(ps),
            "canSeek": rewind.buffering,
            "isLive": !rewind.timeshifting,
            "positionWallMs": rewind.tailWallMs + Int64(ps?.currentMs ?? 0),
            "windowStartMs": rewind.tailWallMs,
            "windowEndMs": rewind.headWallMs,
        ]
        // Ensure isPlaying rides the state too (some clients read it off state).
        state["isPlaying"] = ps.map { !$0.isPaused } ?? true
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
        let pos: [String: Any] = [
            "cmd": "position",
            "isPlaying": playing,
            "isLive": !rewind.timeshifting,
            "canSeek": rewind.buffering,
            "positionWallMs": rewind.tailWallMs + Int64(ps?.currentMs ?? 0),
            "windowStartMs": rewind.tailWallMs,
            "windowEndMs": rewind.headWallMs,
        ]
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
        let name = Self.jsonEscape(Self.deviceName())
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
