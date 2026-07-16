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

    @Published private(set) var devices: [TV] = []
    @Published private(set) var conn: Conn = .idle
    @Published private(set) var remoteIsPlaying = true
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
            case "authFail":
                conn = .needsPairing(currentTV?.name)
            default:
                break
            }
            return
        }
        switch json["cmd"] as? String {
        case "position", "state":
            if let playing = json["isPlaying"] as? Bool { remoteIsPlaying = playing }
        default:
            break
        }
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
                HStack(spacing: 28) {
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
                    transportButton("xmark", label: stopLabel, action: onStop)
                }
                .padding(.bottom, 48)
            }
            .padding(.horizontal, 24)
        }
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
