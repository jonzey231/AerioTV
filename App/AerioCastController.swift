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
//  HLS proxy's DEMUXED master playlist (http://<phone-lan-ip>:<port>/demuxed.m3u8,
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
import AVFoundation
import Foundation
import GoogleCast
import Network
import SwiftUI
import UIKit
import UserNotifications

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
    /// Set by stopCasting() so a deliberate teardown is never reported as a
    /// drop, even if the SDK attaches an error to it (Android parity, dce3074).
    private var userRequestedStop = false
    /// Captured at connect: by didEnd the session no longer exposes its
    /// device, so reading it there yields nothing to name in the alert
    /// (same lesson as Android's lastDeviceName, 2026-08-19).
    private var lastDeviceName: String?
    /// Mirrors the remote player's play/pause for the cover's transport button.
    @Published private(set) var remoteIsPlaying = true

    /// Channel name of an in-flight WEB RECEIVER channel flip: set the moment
    /// the flip is requested and cleared when the receiver reports PLAYING
    /// (or the flip fails / is superseded / the session ends). A web-receiver
    /// flip is a full unload + fresh load, so the old channel disappears from
    /// the screen while the new one warms up; the card and the controls sheet
    /// say "Switching to <channel>" for exactly that window.
    @Published private(set) var switchingToTitle: String?
    /// Supersede token: every flip bumps it, and a load task whose token is
    /// stale drops its result instead of racing the newer flip.
    private var flipToken = 0
    /// True once a web receiver has media loaded, so the NEXT load on this
    /// session is a flip (tear the proxy down and load afresh) rather than the
    /// session's first load.
    private var webReceiverHasLoadedMedia = false

    /// Accent status line for the cast card and the controls sheet: the flip
    /// in progress wins over the steady "Casting to <device>".
    func castStatusLine(deviceName: String) -> String {
        if let switchingToTitle { return "Switching to \(switchingToTitle)" }
        return "Casting to \(deviceName)"
    }

    /// A session connected with nothing to play: the receiver is up but the
    /// user started the cast from the guide pill, where no channel is
    /// playing. The cover renders a channel list instead of stranding the
    /// receiver on its idle screen until the web receiver times out (Logan,
    /// 2026-09-11: "launched then died instantly").
    @Published private(set) var awaitingChannelPick = false
    /// Last connect failure, surfaced inline on the picker row that was
    /// tapped (no alert: the sheet is still on screen).
    @Published var connectError: String?
    /// Device id the picker is currently connecting to, so its row can show
    /// a spinner and the other rows can dim.
    @Published private(set) var connectingDeviceID: String?

    private var started = false
    private var pending: Content?
    private var castStateObserver: NSObjectProtocol?

    /// One-way diagnostic namespace: the receiver web app broadcasts a
    /// JSON player-state snapshot on it, the sender only listens. Exists
    /// because the receiver page's own console prints NOTHING that reaches
    /// logcat on a Google TV Streamer, so on the 15:10:03 2026-09-12
    /// session we could not see the buffered ranges or the seek range that
    /// decide whether Shaka's chosen playhead is reachable. Logan's order:
    /// "I need you to not guess. Add something in logging so you can see
    /// it." Same namespace string on Android (core/cast/).
    private static let receiverDebugNamespace = "urn:x-cast:com.aeriotv.receiver.debug"
    /// MEASURED receiver MSE codec support for this session, reported by the
    /// receiver web app on `receiverDebugNamespace` (see receiver.html):
    /// keys "ac-3", "ec-3", "mp4a.40.2", "avc1.64002A". nil until the first
    /// caps message arrives; cleared when the session ends.
    ///
    /// This replaced a model allow-list that called a Google TV Streamer
    /// AC-3 capable. The allow-list was right about the platform players and
    /// wrong about the web receiver's MSE in the MUXED shape: the receiver's
    /// own Chromium answered isTypeSupported("video/mp4;
    /// codecs=\"avc1.64002A,ac-3\"") false (2026-09-12 15:52:40) and that
    /// load died with Shaka 3015.
    ///
    /// As of 2026-09-13 the receiver probes the DEMUXED shape instead, which
    /// is what this sender now loads: isTypeSupported("audio/mp4;
    /// codecs=\"ac-3\"") is TRUE on that same Streamer, so AC-3 / E-AC-3
    /// passes through in its own audio/mp4 SourceBuffer. The keys are
    /// unchanged; only the MIME the receiver measures them with changed.
    private var receiverCaps: [String: Bool]?
    /// Last measurement logged, so the copy that rides every telemetry
    /// snapshot does not repeat the line.
    private var loggedCaps: [String: Bool]?

    /// True only when the receiver MEASURED AC-3 or E-AC-3 support, which it
    /// now probes as `audio/mp4; codecs="ac-3"` (the DEMUXED shape the sender
    /// loads) rather than the muxed `video/mp4` form that understated it. No
    /// caps yet (a first load can race READY) reads as false, which refuses an
    /// AC-3 channel by name rather than sending audio the receiver cannot
    /// decode: the phone never transcodes cast audio.
    private var receiverDecodesAC3: Bool {
        guard let caps = receiverCaps else { return false }
        return caps["ac-3"] == true || caps["ec-3"] == true
    }

    /// How long the audio plan waits for caps a web receiver has not
    /// volunteered yet (an explicit request is sent first). Short: this runs in
    /// front of the load, and the fallback is only a refusal of AC-3.
    private static let capsRequestWaitSeconds: Double = 3
    /// Poll interval while waiting for that answer.
    private static let capsPollSeconds: Double = 0.1

    /// Ask the receiver for a FRESH capability measurement. Sent on both
    /// namespaces because a page old enough to answer hello without `mse` may
    /// only listen for this on the debug channel.
    private func requestReceiverCaps() {
        sendControl(["cmd": "caps"])
        guard let channel = receiverDebugChannel,
              let data = try? JSONSerialization.data(withJSONObject: ["cmd": "caps"]),
              let text = String(data: data, encoding: .utf8) else { return }
        channel.sendTextMessage(text, error: nil)
    }

    /// Caps for the audio plan: what the receiver already told us, and
    /// otherwise ASK and wait up to `capsRequestWaitSeconds` before giving up.
    /// On a Chromecast Ultra the only caps message was the one at READY, which
    /// this sender's channel was attached too late to see.
    private func awaitReceiverCaps() async -> [String: Bool]? {
        if let caps = receiverCaps { return caps }
        requestReceiverCaps()
        var waited: Double = 0
        while waited < Self.capsRequestWaitSeconds {
            try? await Task.sleep(nanoseconds: UInt64(Self.capsPollSeconds * 1_000_000_000))
            if Task.isCancelled { return receiverCaps }
            waited += Self.capsPollSeconds
            if let caps = receiverCaps { return caps }
        }
        return nil
    }

    /// Stores the `mse` object from a receiver debug message (the dedicated
    /// `type: "caps"` message sent on READY, and the copy that rides every
    /// telemetry snapshot).
    fileprivate func noteReceiverCaps(_ json: [String: Any]) {
        guard let mse = json["mse"] as? [String: Any], !mse.isEmpty else { return }
        var parsed: [String: Bool] = [:]
        for (key, value) in mse {
            if let b = value as? Bool { parsed[key] = b } else if let n = value as? NSNumber { parsed[key] = n.boolValue }
        }
        guard !parsed.isEmpty else { return }
        receiverCaps = parsed
        guard loggedCaps != parsed else { return }
        loggedCaps = parsed
        func cap(_ key: String) -> String { parsed[key] == true ? "yes" : "no" }
        debugLog("[Cast] receiver caps: ac-3=\(cap("ac-3")) ec-3=\(cap("ec-3")) "
            + "aac=\(cap("mp4a.40.2")) h264=\(cap("avc1.64002A"))")
    }

    /// Attached on session start, dropped on session end.
    private var receiverDebugChannel: GCKGenericChannel?

    // MARK: - Receiver type (native Android TV app vs web receiver)

    /// Custom control namespace shared with the Android app (core/cast/CastControl).
    /// Used here for two things only: the receiver-type handshake and the
    /// in-place channel flip a running Cast Connect receiver needs.
    private static let controlNamespace = "urn:x-cast:com.aeriotv.control"

    /// Which receiver this session is talking to.
    ///
    /// The Cast SDK decides whether Cast Connect launched the native Android TV
    /// app or the web receiver, but it exposes that decision nowhere public
    /// (neither GCKCastSession nor its application metadata carries it). So the
    /// sender asks the RECEIVER: it sends `hello` on connect and only the AerioTV
    /// Android TV receiver answers `receiverInfo` / platform=android-tv-app. No
    /// answer inside `targetProbeSeconds` means the web receiver, which needs the
    /// phone-local HLS proxy and a directly playable contentURL.
    enum ReceiverTarget { case unknown, androidTVApp, webReceiver }

    private(set) var receiverTarget: ReceiverTarget = .unknown
    private var controlChannel: GCKGenericChannel?
    private var targetProbeTask: Task<Void, Never>?
    /// A live load held until the receiver type is known. Guessing is not an
    /// option in either direction: guessing web starts a proxy plus a server
    /// transcode for a TV that can play the raw TS natively, and guessing native
    /// black-screens a dongle.
    private var deferredLoad: Content?
    /// Last resort only: BOTH receivers answer the probe now (the web
    /// receiver.html answers platform=web-receiver as of 2026-09-13), so the
    /// timeout exists for a receiver too old to answer at all. It is long because
    /// the only thing it has to outlast is a Cast Connect cold start of the
    /// Android TV app on a slow device, and while it runs the UI stays in the
    /// state a load-in-flight already shows rather than guessing a path.
    private static let targetProbeSeconds: Double = 12
    /// Re-send interval for the probe inside that window: the Cast Connect
    /// receiver's message listener does not exist until its process has started,
    /// so a single probe sent at connect can simply be dropped.
    private static let probeRetrySeconds: Double = 1

    /// Send `hello` (repeatedly) until a receiver names itself, or the window ends.
    private func probeReceiverTarget() {
        receiverTarget = .unknown
        targetProbeTask?.cancel()
        targetProbeTask = Task { @MainActor [weak self] in
            var waited: Double = 0
            while let self, self.receiverTarget == .unknown, waited < Self.targetProbeSeconds {
                self.sendControl(["cmd": "hello"])
                try? await Task.sleep(nanoseconds: UInt64(Self.probeRetrySeconds * 1_000_000_000))
                if Task.isCancelled { return }
                waited += Self.probeRetrySeconds
            }
            guard let self, !Task.isCancelled, self.receiverTarget == .unknown else { return }
            debugLog("[Cast] receiver type handshake timed out after "
                + "\(Int(Self.targetProbeSeconds))s with no answer")
            self.resolveReceiverTarget(.webReceiver, answered: false)
        }
    }

    /// Apply a receiver's own answer. An unrecognised platform is left unknown so
    /// the timeout decides rather than a bad guess.
    private func noteReceiverInfo(_ json: [String: Any]) {
        // 2026-09-13 (Chromecast Ultra, log 02:38:56-02:39:02): the web receiver
        // sent its caps ONCE at READY on the debug namespace, and this sender
        // attached that channel after READY, so the audio plan ran with "caps
        // not received, assuming no AC-3" and refused the stream. The hello
        // reply is the one message always read before the plan, so the
        // measurement now rides along with it.
        noteReceiverCaps(json)
        switch json["platform"] as? String {
        case "android-tv-app": resolveReceiverTarget(.androidTVApp)
        case "web-receiver": resolveReceiverTarget(.webReceiver)
        default: break
        }
    }

    /// Latch the receiver type, log WHICH of the three outcomes happened, and
    /// release any held load.
    private func resolveReceiverTarget(_ target: ReceiverTarget, answered: Bool = true) {
        guard receiverTarget != target else { return }
        receiverTarget = target
        if target == .androidTVApp {
            // Remember this device as one that runs the AerioTV Android TV app,
            // so the picker can list it under "AerioTV on TV" next time.
            if let id = GCKCastContext.sharedInstance()
                .sessionManager.currentCastSession?.device.deviceID {
                CastNativeDeviceRegistry.shared.markNative(id)
            }
            debugLog("[Cast] target=android-tv-app, native playback (receiver answered)")
        } else if answered {
            debugLog("[Cast] target=web-receiver (receiver answered)")
        } else {
            debugLog("[Cast] target=web-receiver (no answer, handshake timed out)")
        }
        if let held = deferredLoad {
            deferredLoad = nil
            if let session = GCKCastContext.sharedInstance().sessionManager.currentCastSession {
                load(held, on: session)
            }
        }
    }

    /// Fire-and-forget JSON on the control namespace. No-op with no channel.
    private func sendControl(_ dict: [String: Any]) {
        guard let channel = controlChannel,
              let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else { return }
        channel.sendTextMessage(text, error: nil)
    }

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
        // Cast Connect ON (Logan 2026-09-13), measured basis: the Cast web
        // receiver's Chromium renderer presents only about 46 fps with
        // double-vsync intervals on a Google TV Streamer at 720p60 and 1080p60,
        // a ceiling every web-receiver app shares, while the native AerioTV
        // Android TV app renders a full 60 fps. With this flag the framework
        // launches that native app on any Android TV target that has AerioTV
        // installed, and the TV tunes the channel ITSELF (no phone proxy,
        // AC-3 passthrough as in normal playback).
        // Targets without the app (legacy dongles, Nest displays) fall back to
        // the web receiver on their own and keep the local HLS proxy path.
        // No credentials: the Android TV receiver authenticates nothing; it
        // validates the load against its own playlist and effective base.
        let launchOptions = GCKLaunchOptions()
        launchOptions.androidReceiverCompatible = true
        options.launchOptions = launchOptions
        GCKCastContext.setSharedInstanceWith(options)
        GCKCastContext.sharedInstance().sessionManager.add(self)
        // The flag above only makes discovery ELIGIBLE to run without a
        // GCKUICastButton; it does not by itself put a scanner on the wire.
        // Nothing else asked for discovery at launch (the only startDiscovery()
        // call lived in the in-player picker's CastDeviceList), so start it here
        // for app lifetime, exactly like the companion mDNS browser. This is
        // also what triggers the SDK's local-network permission use.
        let discovery = GCKCastContext.sharedInstance().discoveryManager
        discovery.add(self)
        discovery.startDiscovery()
        debugLog("[Cast] context configured appId=\(AerioCast.receiverAppID), discovery state=\(discovery.discoveryState.rawValue), devices=\(discovery.deviceCount)")
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
        syncNowPlayingCard()
    }

    /// Lock-screen / Control Center card while casting. The local player is
    /// torn down during a cast, so NowPlayingBridge is free; publishing here
    /// gives the backgrounded phone honest visible UI for why it is awake
    /// (the silent-render keepalive) plus play/pause without unlocking.
    /// Channel up/down stay on the in-app cover: the bridge's transport is
    /// play/pause/seek only, matching the web receiver's control surface.
    private func syncNowPlayingCard() {
        guard case .connected = state, let content = castingContent,
              let item = ChannelStore.shared.channels.first(where: { $0.id == content.mediaID })
        else {
            if isCasting == false { NowPlayingBridge.shared.teardown() }
            return
        }
        NowPlayingBridge.shared.configure(
            for: item,
            isLive: true,
            onPlay: {
                GCKCastContext.sharedInstance().sessionManager
                    .currentCastSession?.remoteMediaClient?.play()
            },
            onPause: {
                GCKCastContext.sharedInstance().sessionManager
                    .currentCastSession?.remoteMediaClient?.pause()
            },
            onSeek: nil
        )
    }

    /// End the current cast session (returns playback to the phone).
    ///
    /// The media session is stopped FIRST, and only then is the Cast session
    /// ended. Ending the session alone tears the receiver app down out from
    /// under a playing HTMLMediaElement: the Google TV Streamer log for the
    /// card's X (2026-09-12 02:29:26) shows CastV2.Receiver.Stop.In and
    /// "Stopping app" with no media request of type STOP anywhere in the
    /// session, and the audio outlived the video surface long enough for
    /// Logan to hear it ("audio kept playing in the background"). A MEDIA
    /// STOP makes the receiver unload the element and release its decoders
    /// in the normal order before the app goes away.
    func stopCasting() {
        // Parity with Android's graceful latch (commit dce3074): GCK documents
        // a nil error for intentional ends, but our own stops are latched too
        // so a deliberate teardown can never masquerade as a drop.
        userRequestedStop = true
        // Best effort and deliberately not awaited: the session teardown below
        // must happen even if the receiver never answers, and a wedged
        // receiver is exactly when the user reaches for the X.
        GCKCastContext.sharedInstance().sessionManager
            .currentCastSession?.remoteMediaClient?.stop()
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

    /// Back / Forward from the remote session sheet: a RELATIVE seek on the
    /// receiver's media session (GCKMediaSeekOptions.relative). The web
    /// receiver's player clamps it to its live seek range; with no seekable
    /// window the receiver ignores it.
    func remoteSeek(by seconds: Double) {
        guard let client = GCKCastContext.sharedInstance()
            .sessionManager.currentCastSession?.remoteMediaClient else { return }
        let options = GCKMediaSeekOptions()
        options.interval = seconds
        options.relative = true
        debugLog("[Cast] remote seek \(seconds)s")
        client.seek(with: options)
    }

    /// Friendly name of the connected cast device, for the cover header.
    var connectedDeviceName: String? {
        if case .connected(let name) = state { return name }
        return nil
    }

    /// Channel up/down from the cast cover. On the web receiver every flip
    /// is a FULL restart: the proxy session is stopped and a new one starts
    /// on the new channel, and the receiver gets a brand new load. Walks
    /// ChannelStore's full list,
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

    /// Picker entry point (guide pill AND in-player chrome): start a session
    /// on `device` and decide up front WHAT it will play, so the receiver is
    /// never left idle with nothing loaded. Priority: the channel playing
    /// locally (full or mini player), else the multiview audio tile, else
    /// nothing -- and "nothing" means the cover shows a channel list once the
    /// session connects, never a bare receiver.
    func beginSession(with device: GCKDevice) {
        let name = device.friendlyName ?? device.deviceID
        connectError = nil
        connectingDeviceID = device.deviceID
        awaitingChannelPick = false
        // One remote target at a time (Android parity): a companion session
        // would otherwise leave two remote covers live.
        if CompanionClient.shared.isControlling { CompanionClient.shared.disconnect() }
        let seed = Self.currentCastableItem()
        pending = seed.flatMap { Self.castContent(for: $0) }
        castingContent = pending
        debugLog("[Cast] picker selected \(name) -> startSession seed=\(seed?.name ?? "none")")
        let started = GCKCastContext.sharedInstance().sessionManager.startSession(with: device)
        if !started {
            pending = nil
            castingContent = nil
            connectingDeviceID = nil
            connectError = "Could not connect to \(name)"
            debugLog("[Cast] startSession refused by the SDK for \(name)")
        }
    }

    /// What a fresh session should open with, if anything is playing on the
    /// phone right now. Mirrors the in-player chrome's notion of "the current
    /// channel" (NowPlayingManager for single streams, the audio tile for
    /// multiview).
    static func currentCastableItem() -> ChannelDisplayItem? {
        if let item = NowPlayingManager.shared.playingItem { return item }
        if let id = MultiviewStore.shared.audioTileID,
           let tile = MultiviewStore.shared.tiles.first(where: { $0.id == id }) {
            return tile.item
        }
        return MultiviewStore.shared.tiles.first?.item
    }

    /// A channel tap while a session is already connected (guide row, VOD
    /// play, or the awaiting-pick state): load it on the receiver. No local
    /// playback starts (rule 5, Logan 2026-09-12).
    func castPickedChannel(_ item: ChannelDisplayItem) {
        guard let content = Self.castContent(for: item) else {
            surfaceCastFailure("This channel has no castable stream")
            return
        }
        awaitingChannelPick = false
        debugLog("[Cast] cover picked channel=\(item.name)")
        setContent(content)
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
        // Route by receiver type (2026-09-13). The native Android TV app gets the
        // channel IDENTITY and tunes itself; a web receiver gets the phone-local
        // proxy playlist. While the handshake is still in flight the load is HELD.
        switch receiverTarget {
        case .unknown:
            deferredLoad = content
            debugLog("[Cast] load held: receiver type not yet known")
            return
        case .androidTVApp:
            loadNative(content, on: session)
            return
        case .webReceiver:
            break
        }
        guard content.kind == .live, let rawTS = content.streamURL else {
            // No proxyable stream: nothing the web receiver could play.
            surfaceCastFailure("This channel has no castable stream")
            return
        }
        // Channel flip on the web receiver (Logan 2026-09-13): a flip is a
        // FRESH LOAD, never a splice into the running HLS stream. A Chromecast
        // Ultra chokes on the splice for about 5 s (BUFFERING/PLAYING
        // toggling, the playhead creeping in 0.1 s stall-skip steps, then a
        // gap jump) while the old channel is still on screen. So the old proxy
        // session is torn down first (ports freed, ingest cancelled), a new
        // one starts on the new channel, and the receiver is handed a brand
        // new load request: it unloads the old media and shows its own loading
        // state for the new channel. Cast Connect (the native Android TV app)
        // keeps its in-place setChannel tune; only this path changed.
        let isFlip = webReceiverHasLoadedMedia
        flipToken &+= 1
        let token = flipToken
        if isFlip {
            switchingToTitle = content.title
            webReceiverHasLoadedMedia = false
            debugLog("[Cast] channel flip: fresh load for \(content.title) (proxy restart)")
        }
        let headers = content.streamHeaders
        // Cast audio (Logan 2026-09-13): AC-3 / E-AC-3 PASSES THROUGH to the
        // web receiver and the Dispatcharr output-profile path is gone.
        // Nothing server-side is asked for and local playback was never
        // involved. The one on-phone transcode left is MPEG audio (TS
        // stream_type 0x03 / 0x04) to AAC, restored 2026-09-13 for the
        // European and OTA channels that carry MP2; the AC-3 family is
        // never re-encoded.
        //
        // What changed: the proxy now serves a DEMUXED master (separate video
        // and audio renditions, one SourceBuffer each), and a Google TV
        // Streamer answers isTypeSupported('audio/mp4; codecs="ac-3"') true
        // for exactly that shape while the old muxed video/mp4 form answered
        // false (the measurement that used to force the AAC profile). Emby
        // plays AC-3 through the same audio/mp4 path.
        //
        // So the ingest is ALWAYS the plain stream URL, and the only decision
        // left is whether this receiver may have the AC-3 bitstream:
        // `receiverCaps` ac-3 / ec-3, measured by the receiver itself. False
        // plus an AC-3 source is transcoded on the phone to AAC-LC stereo
        // (2026-09-21, `audio=transcode-aac`), and refused by name only when
        // this device has no AC-3 decoder (`audio=aac-only`). AAC
        // sources pass through as before (a channel_configuration 0 layout is
        // still refused), and MPEG audio transcodes instead of refusing.
        let receiverName = session.device.friendlyName ?? lastDeviceName
        let receiverModel = session.device.modelName ?? receiverName ?? "unknown"
        proxyLoadTask = Task { [weak self] in
            // The plan now WAITS for the measurement (asking for it if needed)
            // instead of reading a nil that only meant "the message has not
            // arrived on this channel yet".
            let caps = await self?.awaitReceiverCaps()
            if Task.isCancelled { return }
            if isFlip {
                // Tear the old session down BEFORE the new ingest: this frees
                // the port and cancels the old ingest, so the new session gets
                // its own server, ring and playlist URL rather than splicing a
                // new generation behind the old channel's segments.
                await Task.detached { CastHLSProxySession.shared.stop() }.value
                if Task.isCancelled { return }
            }
            if caps == nil { debugLog("[Cast] caps not received, assuming no AC-3") }
            let allowAC3 = caps?["ac-3"] == true || caps?["ec-3"] == true
            // No AC-3 on the receiver: decode it here instead of refusing the
            // channel, as long as this device can build the decoder.
            let transcodeAC3 = !allowAC3 && CastAudioTranscoder.canDecode(.ac3)
            let audioMode = allowAC3 ? "passthrough" : (transcodeAC3 ? "transcode-aac" : "aac-only")
            func cap(_ key: String) -> String { caps?[key] == true ? "yes" : "no" }
            debugLog("[Cast] audio plan: receiver=\(receiverModel) "
                + "caps=\(caps == nil ? "none" : "measured") "
                + "ac-3=\(cap("ac-3")) ec-3=\(cap("ec-3")) aac=\(cap("mp4a.40.2")) "
                + "-> ingest=plain audio=\(audioMode)")
            let playlistURL: URL
            // A connection-limit refusal or reconnect bounce after the
            // receiver loaded ends the cast with the notice text.
            CastHLSProxySession.shared.onTerminalAfterReady = { text in
                Task { @MainActor in
                    let controller = AerioCastController.shared
                    guard controller.isCasting else { return }
                    debugLog("[LIMIT] cast ingest stopped after load; ending cast")
                    controller.surfaceCastFailure(text)
                    controller.stopCasting()
                }
            }
            do {
                // The DEMUXED master is what the receiver loads: the audio
                // rendition declares ac-3 / ec-3 honestly in its own
                // audio/mp4 SourceBuffer. It is the only shape the proxy
                // serves (the muxed endpoints were removed 2026-09-13).
                playlistURL = try await CastHLSProxySession.shared.startChannel(
                    rawTSURL: rawTS, headers: headers, allowAC3Passthrough: allowAC3,
                    transcodeAC3: transcodeAC3)
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.flipToken == token else { return }
                    self.switchingToTitle = nil
                }
                self?.surfaceCastFailure(Self.castFailureMessage(
                    error, receiverName: receiverName, isDispatcharr: rawTS.path.contains("/proxy/ts/")))
                debugLog("[Cast] load channel=\(content.title) audio=unknown mode=refused")
                // The proxy is already torn down; a session left up would
                // show a live cast cover over a dead playlist (zombie
                // "Casting" UI, seen live 2026-08-14). End it; the session
                // teardown path resumes local playback.
                self?.stopCasting()
                return
            }
            let summary = CastHLSProxySession.shared.audioSummary()
            debugLog("[Cast] load channel=\(content.title) "
                + "audio=\(summary?.codec ?? "none") mode=\(summary?.mode ?? "unknown")")
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                // Re-fetch the session: the connect may have churned while
                // the proxy warmed up.
                guard let self,
                      let live = GCKCastContext.sharedInstance().sessionManager.currentCastSession,
                      self.flipToken == token,
                      self.castingContent?.mediaID == content.mediaID else { return }
                self.loadProxyPlaylist(playlistURL, content: content, on: live)
            }
        }
    }

    // Cast audio, 2026-09-13: the "retry once without the output_profile
    // parameter" wrapper that used to sit between `load` and
    // `CastHLSProxySession.startChannel` is GONE with the profile itself.
    // There is one ingest URL now, the plain one, so a failure is a real
    // failure and is surfaced as such.

    /// Specific refusal wording for every way a cast start can fail
    /// (Logan 2026-09-12: "cannot cast this channel" is not detailed
    /// enough). Shown in the cast alert and logged.
    private static func castFailureMessage(_ error: Error, receiverName: String?,
                                           isDispatcharr: Bool) -> String {
        if let codec = error as? CastUnsupportedCodecError {
            let name = codec.codecName
                .replacingOccurrences(of: " video", with: "")
                .replacingOccurrences(of: " audio", with: "")
            switch codec.stream {
            case .video:
                return "This channel's video is \(name), which Google Cast receivers cannot play."
            case .audio:
                if name.hasPrefix("AC-3") || name.hasPrefix("E-AC-3") {
                    return "This receiver cannot decode this channel's surround audio (AC-3)."
                }
                return "This channel's audio is \(name), which the receiver cannot decode."
            }
        }
        let seconds = CastHLSProxySession.readyTimeoutSeconds
        switch error {
        case CastHLSProxyError.timedOut:
            return isDispatcharr
                ? "Dispatcharr did not send any data for this channel within \(seconds) seconds."
                : "The server did not send any data for this channel within \(seconds) seconds."
        case CastHLSProxyError.upstreamUnavailable(let code):
            return isDispatcharr
                ? "Dispatcharr could not start this channel (HTTP \(code))."
                : "The server could not start this channel (HTTP \(code))."
        case CastHLSProxyError.stopped(let notice):
            return "\(notice.title). \(notice.message)"
        case CastHLSProxyError.ingestUnreachable:
            return "This channel's stream could not be reached from this iPhone."
        case CastHLSProxyError.noLANAddress:
            return "Casting needs Wi-Fi: a Google Cast device cannot reach this iPhone over cellular."
        case CastHLSProxyError.serverFailed:
            return "AerioTV could not start the local cast server on this iPhone."
        default:
            return "This channel could not be cast: \(error)"
        }
    }

    /// Cast Connect path: hand the native AerioTV Android TV receiver the channel
    /// identity only and let it tune like a local tap (its own ExoPlayer, its own
    /// effective base, AC-3 passthrough). Nothing on the phone touches the stream:
    /// no HLS proxy, no contentURL.
    ///
    /// The identity MUST be the Android app's own channel id, because the receiver
    /// resolves the load against ITS playlist: Dispatcharr channels share the
    /// server uuid, which is "disp:<uuid>" on Android (the same translation the LAN
    /// companion remote uses). A channel with no Dispatcharr uuid (XC / M3U) has no
    /// id the TV could resolve, so it is refused by name instead of black-screening.
    private func loadNative(_ content: Content, on session: GCKCastSession) {
        guard let client = session.remoteMediaClient else { return }
        let item = ChannelStore.shared.channels.first { $0.id == content.mediaID }
        guard let item, let androidID = CompanionClient.androidChannelID(for: item) else {
            surfaceCastFailure("The AerioTV app on this TV cannot look up this channel. "
                + "Only Dispatcharr channels can be cast to it.")
            debugLog("[Cast] native load refused: no Dispatcharr id for \(content.title)")
            return
        }
        // Any proxy left over from an earlier web-receiver session has no client.
        Task.detached { CastHLSProxySession.shared.stop() }

        let metadata = GCKMediaMetadata(metadataType: .generic)
        metadata.setString(content.title, forKey: kGCKMetadataKeyTitle)
        if let sub = content.subtitle, !sub.isEmpty {
            metadata.setString(sub, forKey: kGCKMetadataKeySubtitle)
        }
        if let art = content.artURL, let url = URL(string: art) {
            metadata.addImage(GCKImage(url: url, width: 480, height: 270))
        }
        // entity is what the receiver's Cast Connect load handler deep-links on,
        // and it must match the scheme MainActivity parses; customData carries the
        // identity, contentID repeats it as the fallback the receiver reads when
        // customData is stripped. No contentURL: the receiver builds its own.
        let builder = GCKMediaInformationBuilder(entity: "aeriotv://channel/\(androidID)")
        builder.contentID = androidID
        builder.streamType = .live
        builder.contentType = "video/mp2t"
        builder.metadata = metadata
        builder.customData = [
            AerioCast.keyMediaID: androidID,
            AerioCast.keyKind: AerioCast.kindLive,
        ]
        let requestBuilder = GCKMediaLoadRequestDataBuilder()
        requestBuilder.mediaInformation = builder.build()
        requestBuilder.autoplay = true
        let request = client.loadMedia(with: requestBuilder.build())
        request.delegate = self
        loadRequest = request
        // Cast Connect does not re-deliver a second load() to an already-running
        // receiver, so every tune also rides the reliable control channel, which
        // re-tunes the TV in place with no relaunch (Android parity).
        sendControl(["cmd": "setChannel", "channelId": androidID])
        debugLog("[Cast] target=android-tv-app, native playback: channel=\(content.title) "
            + "id=\(androidID) proxy=none profile=none")
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
        // The next load on this session is a flip: tear down and load afresh.
        webReceiverHasLoadedMedia = true
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
        // Same audio plan as the initial load: the plain stream URL, with
        // AC-3 / E-AC-3 passthrough gated on the receiver's own measurement,
        // otherwise the on-phone AAC transcode when a decoder exists.
        let allowAC3 = receiverDecodesAC3
        let transcodeAC3 = !allowAC3 && CastAudioTranscoder.canDecode(.ac3)
        proxyLoadTask = Task { [weak self] in
            do {
                _ = try await CastHLSProxySession.shared.startChannel(
                    rawTSURL: rawTS, headers: headers, allowAC3Passthrough: allowAC3,
                    transcodeAC3: transcodeAC3)
            } catch is CancellationError {
            } catch {
                self?.surfaceCastFailure("The stream switch interrupted casting: \(error)")
                self?.stopCasting()
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

// MARK: - GCKDiscoveryManagerListener (app-lifetime discovery + logging)

extension AerioCastController: GCKDiscoveryManagerListener {
    // GCK delivers discovery callbacks on the main thread (SDK contract).
    nonisolated func didStartDiscovery(forDeviceCategory deviceCategory: String) {
        MainActor.assumeIsolated { logDiscovery("didStartDiscovery category=\(deviceCategory)") }
    }

    nonisolated func didUpdateDeviceList() {
        MainActor.assumeIsolated { logDiscovery("didUpdateDeviceList") }
    }

    nonisolated func didInsert(_ device: GCKDevice, at index: UInt) {
        let name = device.friendlyName ?? device.deviceID
        MainActor.assumeIsolated { logDiscovery("didInsert \(name)") }
    }

    nonisolated func didRemove(_ device: GCKDevice, at index: UInt) {
        let name = device.friendlyName ?? device.deviceID
        MainActor.assumeIsolated { logDiscovery("didRemove \(name)") }
    }

    fileprivate func logDiscovery(_ what: String) {
        let discovery = GCKCastContext.sharedInstance().discoveryManager
        let names = (0..<discovery.deviceCount)
            .map { discovery.device(at: $0).friendlyName ?? discovery.device(at: $0).deviceID }
        debugLog("[Cast] \(what): discovery state=\(discovery.discoveryState.rawValue), devices=\(discovery.deviceCount) \(names)")
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
    nonisolated func sessionManager(_ sessionManager: GCKSessionManager,
                                    didFailToStart session: GCKSession,
                                    withError error: Error) {
        let name = session.device.friendlyName ?? session.device.deviceID
        let text = error.localizedDescription
        MainActor.assumeIsolated { self.onSessionFailedToStart(device: name, message: text) }
    }
    nonisolated func sessionManager(_ sessionManager: GCKSessionManager, didEnd session: GCKSession, withError error: Error?) {
        MainActor.assumeIsolated { self.onSessionEnded(error: error) }
    }

    /// Connect attempt refused by the device: clear the captured intent and
    /// leave the message on the picker row the user tapped.
    private func onSessionFailedToStart(device: String, message: String) {
        debugLog("[Cast] session failed to start \(device): \(message)")
        pending = nil
        castingContent = nil
        awaitingChannelPick = false
        connectingDeviceID = nil
        connectError = "Could not connect to \(device): \(message)"
        syncCastState(GCKCastContext.sharedInstance().castState)
    }

    /// Re-fetches the current session on the MainActor (rather than receiving the
    /// non-Sendable GCKCastSession across isolation), then loads pending content.
    private func onConnected() {
        guard let session = GCKCastContext.sharedInstance().sessionManager.currentCastSession else { return }
        state = .connected(session.device.friendlyName)
        session.device.friendlyName.map { lastDeviceName = $0 }
        connectingDeviceID = nil
        connectError = nil
        debugLog("[Cast] session started \(session.device.friendlyName ?? session.device.deviceID) state=\(GCKCastContext.sharedInstance().castState.rawValue) pending=\(pending?.title ?? "none")")
        // Ask for notification permission the first time a cast connects (a
        // moment when the user just acted, so the system dialog has obvious
        // context). Without this the app never appears in Settings >
        // Notifications unless the user happens to set a reminder first, and
        // the involuntary-drop alert below has nowhere to land - found on
        // Logan's iPhone during the drop test 2026-08-19. No-op once the
        // user has answered either way.
        Task {
            let center = UNUserNotificationCenter.current()
            guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        session.remoteMediaClient?.add(self)
        // Listen for the receiver's diagnostic snapshots (see
        // `receiverDebugNamespace`). Purely read-only; nothing is ever
        // sent on this channel.
        let debugChannel = GCKGenericChannel(namespace: Self.receiverDebugNamespace)
        debugChannel.delegate = self
        session.add(debugChannel)
        receiverDebugChannel = debugChannel
        // Custom control channel: the receiver-type handshake and the in-place
        // channel flip a running Cast Connect receiver needs. Attached BEFORE any
        // load decision below, because that decision waits on the handshake.
        let control = GCKGenericChannel(namespace: Self.controlNamespace)
        control.delegate = self
        session.add(control)
        controlChannel = control
        probeReceiverTarget()
        // Cast takes precedence over an active companion session: tear that
        // down first so the two remote covers can never both be live (review
        // 2026-07-16). Companion Disconnect leaves the Android TV playing.
        if CompanionClient.shared.isControlling { CompanionClient.shared.disconnect() }
        // What this session plays: the intent captured at picker tap
        // (beginSession), else whatever is playing now (a session started by
        // any other path, e.g. a resumed session).
        let content = pending
            ?? Self.currentCastableItem().flatMap { Self.castContent(for: $0) }
        if let content {
            // Hand the channel to the TV, then tear the local player down
            // (frees the decoder AND the Dispatcharr connection slot -- the
            // receiver is about to open its own; on max-connections=1
            // channels the local stream would starve the TV's, Android
            // review 2026-07-15). The cast-remote cover (HomeView renders it
            // off isCasting) takes over.
            setContent(content)
            AppOrientationLock.release()
            if PlayerSession.shared.mode != .idle || NowPlayingManager.shared.playingItem != nil {
                // PlayerSession.stop() tears down the local player's Now
                // Playing card; republish the cast card after it.
                PlayerSession.shared.stop()
            }
            syncNowPlayingCard()
        } else {
            // Started from the guide pill with nothing playing: the receiver
            // is up but has no media, and an unloaded web receiver dies on
            // its idle timeout (Logan 2026-09-11). Keep the session and let
            // the cover ask which channel to cast.
            awaitingChannelPick = true
            debugLog("[Cast] session started with no channel to load; awaiting channel pick")
        }
    }

    /// Session ended (user tapped Stop on the cover, or the TV went away):
    /// resume the last cast channel locally -- "stop casting" means "bring
    /// playback back to my phone" (Android parity).
    private func onSessionEnded(error: Error? = nil) {
        // Involuntary drop = the SDK reports an error AND we did not ask to
        // stop. GCK passes nil for intentional ends (unlike the Android SDK,
        // whose end codes are non-zero for every path - measured 2026-08-19:
        // deliberate stop 2161 vs receiver death 2155/2055).
        let wasUserStop = userRequestedStop
        userRequestedStop = false
        let involuntary = (error != nil) && !wasUserStop
        awaitingChannelPick = false
        connectingDeviceID = nil
        debugLog("[Cast] session ended reason=\(wasUserStop ? "user stop" : (error != nil ? "error: \(error!.localizedDescription)" : "remote end"))")
        if involuntary {
            debugLog("[CAST] session ended involuntarily: \(error.map(String.init(describing:)) ?? "?")")
        }
        pending = nil
        // The receiver is gone, so its debug channel goes with it; remove
        // it from the session while one is still reachable, then drop the
        // reference either way.
        if let debugChannel = receiverDebugChannel {
            GCKCastContext.sharedInstance().sessionManager.currentCastSession?.remove(debugChannel)
            debugChannel.delegate = nil
            receiverDebugChannel = nil
        }
        if let control = controlChannel {
            GCKCastContext.sharedInstance().sessionManager.currentCastSession?.remove(control)
            control.delegate = nil
            controlChannel = nil
        }
        targetProbeTask?.cancel()
        targetProbeTask = nil
        receiverTarget = .unknown
        deferredLoad = nil
        receiverCaps = nil
        loggedCaps = nil
        // The cast card must not outlive the session; a local resume below
        // publishes its own via PlayerSession.
        NowPlayingBridge.shared.teardown()
        // The receiver is gone; the proxy has no client left to serve.
        proxyLoadTask?.cancel()
        proxyLoadTask = nil
        loadRequest = nil
        switchingToTitle = nil
        webReceiverHasLoadedMedia = false
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepEndsAt = nil
        Task.detached { CastHLSProxySession.shared.stop() }
        syncCastState(GCKCastContext.sharedInstance().castState)
        let skipResume = suppressLocalResume
        suppressLocalResume = false
        defer { castingContent = nil }
        // Kenton-class drop (Android a5e2b73/dce3074 parity): the cast dying
        // while the app is BACKGROUNDED used to be completely silent here -
        // the TV falls to the idle splash and the phone says nothing. Post a
        // notification naming what stopped, and skip the local auto-resume
        // for that case only (audio starting in a pocket is a worse signal
        // than a notification). Foreground drops keep the existing behavior:
        // playback returns to the phone, which announces itself. If
        // notifications are not authorized, behavior is unchanged - the
        // resume below stays as the fallback signal.
        if involuntary, UIApplication.shared.applicationState != .active {
            let deviceName = lastDeviceName
            let contentTitle = castingContent?.title
            Task {
                let center = UNUserNotificationCenter.current()
                let settings = await center.notificationSettings()
                guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else { return }
                let content = UNMutableNotificationContent()
                content.title = deviceName.map { "Casting to \($0) interrupted" }
                    ?? "Casting interrupted"
                var body = ""
                if let contentTitle, !contentTitle.isEmpty { body += "\(contentTitle) stopped. " }
                body += "The connection to the TV was lost. Open AerioTV to cast again."
                content.body = body
                content.sound = .default
                try? await center.add(UNNotificationRequest(
                    identifier: "aerio-cast-drop", content: content, trigger: nil))
            }
            return
        }
        // Rule 4 (Logan 2026-09-12): "when I cancel casting, do not
        // automatically start playing it on the phone. If I close it, it
        // should just close." The old behavior resumed the cast channel
        // locally here (Android-parity "bring it back to my phone"); that is
        // deliberately gone, for EVERY end reason. `skipResume` (the sleep
        // timer's one-shot) is now redundant but stays read so the timer's
        // intent is still expressed.
        _ = skipResume
        debugLog("[Cast] stop: session ended, no local resume")
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
        // A flip's "Switching to <channel>" ends when the receiver actually
        // reports PLAYING, not when the load request returns: the receiver
        // still has to fetch the playlist and fill its buffer.
        let nowPlaying = mediaStatus?.playerState == .playing
        MainActor.assumeIsolated {
            self.remoteIsPlaying = playing
            if nowPlaying { self.switchingToTitle = nil }
        }
    }
}

// MARK: - GCKGenericChannelDelegate (receiver debug telemetry)
//
// The receiver web app broadcasts one JSON snapshot of its player state
// per event on `receiverDebugNamespace`; this logs it as ONE line so the
// sender log alone shows what Shaka believed about its own buffer. Added
// 2026-09-12 after the Google TV Streamer session where the receiver sat
// at position -58 ms in BUFFERING for 45 s and nothing on the device
// could tell us where the buffered range or the seek range actually was.
// Keys the receiver sends: ev, t, buffered (array of [start, end]
// pairs), ready, state, rate, seek ([start, end] or null), bufTime, bw,
// hist, err. Any field the receiver omits logs as `?`.

extension AerioCastController: GCKGenericChannelDelegate {

    nonisolated func cast(_ channel: GCKGenericChannel,
                          didReceiveTextMessage message: String,
                          withNamespace protocolNamespace: String) {
        // GCK delivers channel callbacks on the main thread, but this is a
        // diagnostic path and `MainActor.assumeIsolated` would TRAP if that
        // ever stopped being true. Hopping costs a log line's latency and
        // cannot take the app down.
        let ns = protocolNamespace
        Task { @MainActor [message] in
            if ns == Self.controlNamespace {
                handleControlMessage(message)
            } else {
                logReceiverDebug(message)
            }
        }
    }

    /// Receiver -> sender on the control namespace. Only the handshake answer is
    /// read here: transport and now-playing ride the Cast media status, and the
    /// receiver's own track/speed pickers are the Android remote's surface.
    private func handleControlMessage(_ message: String) {
        guard let data = message.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return
        }
        // The web receiver page spells the discriminator "type", the Android TV
        // receiver spells it "cmd" like every other frame on this namespace.
        let kind = (json["cmd"] as? String) ?? (json["type"] as? String)
        // The receiver answers an explicit caps request on whichever namespace
        // it was asked on, so the control channel can carry one too.
        if kind == "caps" { noteReceiverCaps(json); return }
        guard kind == "receiverInfo" else { return }
        noteReceiverInfo(json)
    }

    /// Never throws and never logs anything but the single line: a
    /// malformed snapshot must not cost us the rest of the session.
    private func logReceiverDebug(_ message: String) {
        guard let data = message.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return
        }
        noteReceiverCaps(json)
        // The dedicated caps message carries no player state; it is fully
        // handled above and must not print a row of "?" fields.
        if json["type"] as? String == "caps" { return }
        func string(_ key: String) -> String {
            if let s = json[key] as? String { return s }
            if let n = json[key] as? NSNumber { return n.stringValue }
            return "?"
        }
        func decimals(_ key: String, _ places: Int) -> String {
            guard let n = json[key] as? NSNumber else { return "?" }
            return String(format: "%.\(places)f", n.doubleValue)
        }
        // Chromium reports a two-track SourceBuffer's buffered ranges as
        // the INTERSECTION of the tracks, so these pairs are what the
        // proxy log's buffStart must fall inside.
        var buffered = "?"
        if let ranges = json["buffered"] as? [[Any]] {
            let pairs = ranges.compactMap { pair -> String? in
                guard pair.count >= 2,
                      let a = pair[0] as? NSNumber, let b = pair[1] as? NSNumber else { return nil }
                return String(format: "[%.3f-%.3f]", a.doubleValue, b.doubleValue)
            }
            buffered = pairs.isEmpty ? "none" : pairs.joined()
        }
        var seek = "?"
        if json["seek"] is NSNull {
            seek = "none"
        } else if let pair = json["seek"] as? [Any], pair.count >= 2,
                  let a = pair[0] as? NSNumber, let b = pair[1] as? NSNumber {
            seek = String(format: "[%.3f-%.3f]", a.doubleValue, b.doubleValue)
        } else if json["seek"] == nil {
            seek = "?"
        }
        var bandwidth = "?"
        if let bw = json["bw"] as? NSNumber { bandwidth = String(Int(bw.doubleValue)) }
        var error = "?"
        if json["err"] is NSNull { error = "none" } else if json["err"] != nil { error = string("err") }
        var history = "?"
        if let entries = json["hist"] as? [Any], let last = entries.last {
            history = String(describing: last)
        } else if json["hist"] != nil {
            history = string("hist")
        }
        // Anything the receiver adds later still reaches the log: the known
        // keys keep their order and formatting, then every remaining top-level
        // key prints generically. "type"/"mse" belong to the caps path above
        // and would only repeat it here.
        let known: Set<String> = [
            "ev", "t", "buffered", "ready", "state", "rate",
            "seek", "bufTime", "bw", "hist", "err", "type", "mse",
        ]
        var extras = ""
        for key in json.keys.sorted() where !known.contains(key) {
            let value = json[key]
            let text: String
            switch value {
            case is NSNull, nil:
                text = "null"
            case let s as String:
                text = s
            case let n as NSNumber:
                text = n.stringValue
            default:
                if let data = try? JSONSerialization.data(withJSONObject: value as Any),
                   let compact = String(data: data, encoding: .utf8) {
                    text = compact
                } else {
                    text = String(describing: value as Any)
                }
            }
            extras += " \(key)=\(text)"
        }
        var line = "[Cast] receiver: ev=\(string("ev")) t=\(decimals("t", 3)) "
            + "buffered=\(buffered) ready=\(string("ready")) state=\(string("state")) "
            + "rate=\(string("rate")) seek=\(seek) bufTime=\(decimals("bufTime", 2)) "
            + "bw=\(bandwidth) hist=\(history) err=\(error)" + extras
        if line.count > 1000 { line = String(line.prefix(997)) + "..." }
        debugLog(line)
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
            let adverts: [Advert] = results.compactMap { result in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                var txtID: String?
                if case .bonjour(let txt) = result.metadata,
                   let id = txt.dictionary["id"], !id.isEmpty {
                    txtID = id
                }
                return Advert(txtID: txtID, name: name, endpoint: result.endpoint)
            }.sorted { $0.name.lowercased() < $1.name.lowercased() }
            Task { @MainActor [weak self] in self?.publishDevices(adverts) }
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

    /// One raw Bonjour advertisement, before duplicates are collapsed. Kept
    /// separate from `TV` so the dedupe can see the TXT id and the endpoint
    /// that the picker row itself never shows.
    private struct Advert {
        let txtID: String?
        let name: String
        let endpoint: NWEndpoint
    }

    /// Per-advertisement identity (NOT the device identity): two adverts for
    /// the same device differ here, which is what lets the dedupe keep the one
    /// that resolved most recently.
    private static func advertKey(_ a: Advert) -> String {
        "\(a.txtID ?? "-")|\(a.name)|\(a.endpoint)"
    }

    /// First time each advertisement was seen, so a group of duplicates can
    /// keep the newest registration. Pruned to what the browse still reports.
    private var advertSeen: [String: Date] = [:]

    /// Collapse duplicate rows and hide quarantined ghosts.
    ///
    /// 2026-09-13: the "AerioTV Remote" section listed "Living Room Apple TV"
    /// twice for one device. The old key was id + display name, and the id
    /// falls back to the display name when an advert carries no TXT "id", so
    /// a stale advert (no TXT id) and the fresh one (with TXT id) produced two
    /// keys and two identical-looking rows. Identity is now the STABLE
    /// identifier only: the TXT "id" record, which survives a rename, plus the
    /// Bonjour instance name (the host name, which mDNS keeps unique per
    /// network) so a TXT-less advert still lands in the same group. Several
    /// interfaces for one device collapse the same way. The surviving row is
    /// the advertisement that resolved most recently.
    private func publishDevices(_ adverts: [Advert]) {
        let now = Date()
        var liveKeys = Set<String>()
        for a in adverts {
            let key = Self.advertKey(a)
            liveKeys.insert(key)
            if advertSeen[key] == nil { advertSeen[key] = now }
        }
        advertSeen = advertSeen.filter { liveKeys.contains($0.key) }

        var groupForTXTID: [String: Int] = [:]
        var groupForHost: [String: Int] = [:]
        var groups: [[Advert]] = []
        for a in adverts {
            var group: Int?
            if let id = a.txtID { group = groupForTXTID[id] }
            if group == nil { group = groupForHost[a.name] }
            let index: Int
            if let group {
                index = group
            } else {
                groups.append([])
                index = groups.count - 1
            }
            groups[index].append(a)
            if let id = a.txtID { groupForTXTID[id] = index }
            groupForHost[a.name] = index
        }

        var kept: [Advert] = []
        for group in groups {
            guard var winner = group.first else { continue }
            for a in group.dropFirst() {
                let aSeen = advertSeen[Self.advertKey(a)] ?? now
                let wSeen = advertSeen[Self.advertKey(winner)] ?? now
                // Most recently resolved wins; on a tie the advert carrying a
                // TXT id is the better-identified one.
                if aSeen > wSeen || (aSeen == wSeen && winner.txtID == nil && a.txtID != nil) {
                    winner = a
                }
            }
            for a in group where Self.advertKey(a) != Self.advertKey(winner) {
                DebugLogger.shared.log(
                    "[Remote] dropped duplicate advertisement \(a.name) \(a.endpoint)")
            }
            kept.append(winner)
        }

        devices = kept.map { TV(id: $0.txtID ?? $0.name, name: $0.name, endpoint: $0.endpoint) }
            .filter { tv in
                let key = Self.tvKey(tv)
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
            Self.clog("sleep timer fired -> pausing TV")
            self.pause()
            self.sleepEndsAt = nil
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
    func play() { sendJSON(["cmd": "play"]); Self.clog("-> TV play") }
    func setAudioOnly(_ on: Bool) { sendJSON(["cmd": "setAudioOnly", "audioOnly": on]); Self.clog("-> TV setAudioOnly \(on)") }
    func seekBy(_ deltaMs: Int64) { sendJSON(["cmd": "seekBy", "deltaMs": deltaMs]) }
    func seekToWall(_ ms: Int64) { sendJSON(["cmd": "seekWall", "targetWallMs": ms]) }
    func goLive() { sendJSON(["cmd": "goLive"]) }

    /// The card's X for the companion transport (Logan 2026-09-12): stop what
    /// the TV is playing AND close the card, the same as Cast and AirPlay. The
    /// stop frame has to reach the TV before the socket goes away, so the
    /// disconnect rides the send completion (with a short fallback in case the
    /// completion never fires on a half-dead socket).
    func stopPlaybackAndDisconnect() {
        debugLog("[Remote] X: stop + close")
        guard let socket,
              let data = try? JSONSerialization.data(withJSONObject: ["cmd": "stop"]),
              let text = String(data: data, encoding: .utf8) else {
            disconnect()
            return
        }
        var closed = false
        let close: @MainActor () -> Void = { [weak self] in
            guard !closed else { return }
            closed = true
            self?.disconnect()
        }
        socket.send(.string(text)) { _ in
            Task { @MainActor in close() }
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            close()
        }
    }

    /// Companion-only "Disconnect" (controls sheet): drop the link and hide the
    /// card, but leave the TV playing what it is playing.
    func disconnectLeavingTVPlaying() {
        debugLog("[Remote] disconnect, TV keeps playing")
        disconnect()
    }

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

// MARK: - Native (AerioTV on TV) Cast device registry

/// Cast devices that answered the `hello` handshake with
/// platform=android-tv-app at least once, i.e. Cast Connect launched the
/// AerioTV Android TV app there. The Cast SDK cannot tell us this before a
/// session exists, so the picker remembers the answer and groups those
/// devices separately from here on. Persisted in UserDefaults: it is a hint
/// for sectioning, never a gate on playback.
@MainActor
final class CastNativeDeviceRegistry: ObservableObject {

    static let shared = CastNativeDeviceRegistry()

    private static let key = "cast.nativeDeviceIDs"

    @Published private(set) var ids: Set<String>

    private init() {
        ids = Set(UserDefaults.standard.stringArray(forKey: Self.key) ?? [])
    }

    func isNative(_ deviceID: String) -> Bool { ids.contains(deviceID) }

    func markNative(_ deviceID: String) {
        guard !deviceID.isEmpty, !ids.contains(deviceID) else { return }
        ids.insert(deviceID)
        UserDefaults.standard.set(Array(ids), forKey: Self.key)
        debugLog("[Cast] device \(deviceID) recorded as AerioTV on TV")
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

/// Remote sheet for the companion transport (AerioTV on TV). Google Cast and
/// AirPlay moved to RemoteSessionSheet (2026-09-21 production layout). Local playback is torn down underneath;
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
    /// Companion transport only (Logan 2026-09-12): drop the connection and
    /// hide the card while the TV KEEPS PLAYING. The X above is the other
    /// semantic (stop the TV as well), so both need to exist here.
    var onDisconnect: (() -> Void)? = nil
    /// Non-nil for the companion transport (full options: scrubber + Options
    /// sheet). nil for basic cast (web receiver has no control namespace).
    var companion: CompanionClient? = nil

    @State private var showOptions = false
    // Skip Intervals (Settings > App Behaviors) for the skip row.
    @AppStorage(SkipIntervals.backKey) private var skipBackSeconds = SkipIntervals.defaultBack
    @AppStorage(SkipIntervals.forwardKey) private var skipForwardSeconds = SkipIntervals.defaultForward
    @Environment(\.dismiss) private var dismiss

    /// Compact bottom-sheet layout (Logan 2026-09-13): Android's cast sheet,
    /// not a full-screen page. Grabber, centered transport glyph, channel /
    /// program / accent status, the live bar, a skip row, then the bottom
    /// row (collapse, big play/pause, channel list, X). Every action the old
    /// full-screen remote had is still wired.
    /// Measured height of the compact content, so the small detent ends just
    /// below the bottom row instead of leaving the blank band a fixed
    /// fraction left behind (Logan's screenshot 2026-09-13).
    @State private var contentHeight: CGFloat = 320

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 10) {
                header
                if let companion, companion.remoteState.canSeek {
                    rewindBar(companion)
                } else {
                    liveLabel
                }
                skipRow
                bottomRow
                if let onDisconnect {
                    Button("Disconnect (leave TV playing)", action: onDisconnect)
                        .scaledFont(.footnote.weight(.semibold))
                        .foregroundStyle(ThemeManager.shared.accent)
                }
            }
            .padding(.horizontal, 24)
            // Top padding clears the drag indicator.
            .padding(.top, 18)
            .padding(.bottom, 8)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                let rounded = (height * 2).rounded() / 2
                if abs(contentHeight - rounded) > 0.5 { contentHeight = rounded }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        // Small sheet over the page the user was on (the channel list stays
        // visible above it), draggable up to full height for the options.
        .presentationDetents([.height(contentHeight + Self.bottomInset), .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.black)
        .sheet(isPresented: $showOptions) {
            if let companion {
                RemoteOptionsSheet(companion: companion)
            }
        }
    }

    /// Centered glyph (or the channel art when we have it), channel name in
    /// bold, the program, then the accent "Casting to <device>" line.
    @ViewBuilder
    private var header: some View {
        VStack(spacing: 2) {
            if let art = artURL, let url = URL(string: art) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    glyphIcon
                }
                .frame(maxWidth: 96, maxHeight: 44)
            } else {
                glyphIcon
            }
            Text(title)
                .scaledFont(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .scaledFont(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
            Text(statusText)
                .scaledFont(.caption)
                .foregroundStyle(Color.contrastText(ThemeManager.shared.accent))
                .lineLimit(1)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    private var glyphIcon: some View {
        Image(systemName: "sparkles.tv")
            .font(.system(size: 30))  // glyph in a fixed box: not text, stays fixed
            .foregroundStyle(ThemeManager.shared.accent)
            .frame(height: 40)
    }

    /// Stand-in for the rewind bar when the transport cannot seek: a full
    /// accent bar with the LIVE label, same slot as Android's.
    private var liveLabel: some View {
        VStack(spacing: 6) {
            Capsule()
                .fill(ThemeManager.shared.accent)
                .frame(height: 4)
            Text("LIVE")
                .scaledFont(.caption2.weight(.semibold))
                .foregroundStyle(Color.contrastText(ThemeManager.shared.accent))
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    /// Skip back / forward (Settings > Skip Intervals) with the channel flip
    /// on either side, so the channel-switch actions survive the condensed
    /// layout.
    private var skipRow: some View {
        HStack(spacing: 18) {
            transportButton("chevron.down", label: "Channel down",
                            size: 44, action: onChannelDown)
            transportButton(SkipIntervals.backSymbol(skipBackSeconds),
                            label: "Skip back \(skipBackSeconds) seconds",
                            size: 44) { seek(-Int64(skipBackSeconds) * 1000) }
            transportButton(SkipIntervals.forwardSymbol(skipForwardSeconds),
                            label: "Skip forward \(skipForwardSeconds) seconds",
                            size: 44) { seek(Int64(skipForwardSeconds) * 1000) }
            transportButton("chevron.up", label: "Channel up",
                            size: 44, action: onChannelUp)
        }
    }

    private var bottomRow: some View {
        HStack(spacing: 22) {
            transportButton("chevron.down", label: "Collapse", size: 50) { dismiss() }
            Button(action: onTogglePlayPause) {
                ZStack {
                    Circle().fill(ThemeManager.shared.accent).frame(width: 64, height: 64)
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 26, weight: .bold))  // glyph in a fixed box: not text, stays fixed
                        .foregroundStyle(.black)
                }
            }
            .accessibilityLabel(isPlaying ? "Pause" : "Play")
            if companion != nil {
                transportButton("list.bullet", label: "Channel list and options",
                                size: 50) { showOptions = true }
            }
            transportButton("xmark", label: stopLabel, size: 50, action: onStop)
        }
    }

    /// Skip Intervals skip: the companion transport seeks its live-rewind buffer; the other
    /// transports flip nothing, so the buttons stay out of the way there.
    /// Home-indicator inset: the detent height is the sheet's own height, so
    /// the content must clear the safe area at the bottom.
    private static var bottomInset: CGFloat {
        let inset = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets.bottom }
            .first ?? 0
        return max(12, inset)
    }

    private func seek(_ deltaMs: Int64) {
        guard let companion, companion.remoteState.canSeek else { return }
        companion.seekBy(deltaMs)
    }

    /// Live-rewind scrubber + Go Live (companion only, when a rewind
    /// buffer is rolling on the TV).
    @ViewBuilder
    private func rewindBar(_ companion: CompanionClient) -> some View {
        let s = companion.remoteState
        let span = max(1, Double(s.windowEndMs - s.windowStartMs))
        let frac = min(1, max(0, Double(s.positionWallMs - s.windowStartMs) / span))
        VStack(spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.2)).frame(height: 4)
                    Capsule().fill(ThemeManager.shared.accent)
                        .frame(width: geo.size.width * frac, height: 4)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onEnded { g in
                    let f = min(1, max(0, g.location.x / geo.size.width))
                    let target = s.windowStartMs + Int64(f * span)
                    companion.seekToWall(target)
                })
            }
            .frame(height: 16)
            // The skip buttons live in the sheet's own skip row now, so
            // this line keeps just the LIVE state and Go Live.
            HStack {
                Text(s.isLive ? "LIVE" : "REWOUND")
                    .scaledFont(.caption.weight(.semibold))
                    .foregroundStyle(s.isLive ? Color.contrastText(ThemeManager.shared.accent) : .white.opacity(0.6))
                Spacer()
                if !s.isLive {
                    Button("Go Live") { companion.goLive() }
                        .foregroundStyle(ThemeManager.shared.accent)
                }
            }
            .scaledFont(.caption)
        }
    }

    private func transportButton(_ symbol: String, label: String,
                                 size: CGFloat = 58,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Color.white.opacity(0.12)).frame(width: size, height: size)
                Image(systemName: symbol)
                    .font(.system(size: size * 0.38, weight: .semibold))  // glyph in a fixed box: not text, stays fixed
                    .foregroundStyle(.white)
            }
        }
        .accessibilityLabel(label)
    }
}

// MARK: - Remote session sheet (Cast + AirPlay, 2026-09-21 production recording)

/// The ONE expanded sheet for Google Cast and AirPlay (Apple TV and Roku),
/// laid out exactly like the production Google Cast session sheet in the
/// 2026-09-21 screen recording; only the transport wording differs
/// ("Casting to" / "Stop Casting" vs "AirPlay to" / "Stop AirPlay").
/// The companion remote keeps RemoteControlScreen (scrubber, Disconnect).
///  - idle route: "Close" on the left, "Connected" centered, nothing else.
///  - playing (and connecting, controls disabled): logo, channel, accent
///    "AirPlay to <receiver>", program + LIVE badge, time range + progress,
///    Channel Down / Up, Back / Pause / Forward, Options, Stop AirPlay.
struct RemoteSessionSheet: View {
    enum Mode { case connecting, playing }
    enum Transport { case cast, airPlay }

    var transport: Transport
    var mode: Mode
    var channelName: String
    var statusText: String
    var artURL: String?
    /// Channel whose now-airing programme the sheet shows. Resolved live
    /// against the same sources as the Live TV list row (item fields when
    /// they cover now, else GuideStore's bulk EPG), so it never drifts from
    /// the list and rolls over on its own when the programme changes.
    var channelID: String?
    /// Shown as the title when no programme is known (e.g. the cast
    /// payload's EPG subtitle).
    var fallbackSubtitle: String?
    var isPlaying: Bool
    /// The locally resolved channel, for the AirPlay Options sheet (Cast
    /// anchors its options on the controller's own castingContent).
    var item: ChannelDisplayItem?
    var onTogglePlayPause: () -> Void
    var onChannelUp: () -> Void
    var onChannelDown: () -> Void
    var onSeek: (Double) -> Void
    var onStop: () -> Void

    @State private var contentHeight: CGFloat = 320
    @State private var showOptions = false
    @ObservedObject private var guideStore = GuideStore.shared
    @ObservedObject private var channelStore = ChannelStore.shared
    @AppStorage(SkipIntervals.backKey) private var skipBackSeconds = SkipIntervals.defaultBack
    @AppStorage(SkipIntervals.forwardKey) private var skipForwardSeconds = SkipIntervals.defaultForward
    @Environment(\.dismiss) private var dismiss

    private var accent: Color { ThemeManager.shared.accent }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            playingContent
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 8)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                let rounded = (height * 2).rounded() / 2
                if abs(contentHeight - rounded) > 0.5 { contentHeight = rounded }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .presentationDetents([.height(contentHeight + Self.bottomInset), .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.sheetBackground)
        .sheet(isPresented: $showOptions) {
            if transport == .cast {
                CastOptionsSheet(cast: AerioCastController.shared)
            } else {
                CastOptionsSheet(cast: AerioCastController.shared, airPlayItem: item)
            }
        }
    }

    // MARK: Playing / connecting

    private var playingContent: some View {
        let enabled = mode == .playing
        return VStack(spacing: 14) {
            header
            programBlock
            Group {
                HStack(spacing: 48) {
                    labeledButton("chevron.down", label: "Channel Down", action: onChannelDown)
                    labeledButton("chevron.up", label: "Channel Up", action: onChannelUp)
                }
                HStack(alignment: .top, spacing: 36) {
                    labeledButton(SkipIntervals.backSymbol(skipBackSeconds),
                                  label: "Back \(skipBackSeconds)s") {
                        onSeek(-Double(skipBackSeconds))
                    }
                    Button(action: onTogglePlayPause) {
                        VStack(spacing: 6) {
                            ZStack {
                                Circle().fill(accent).frame(width: 72, height: 72)
                                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 30, weight: .bold))  // glyph in a fixed box: not text, stays fixed
                                    .foregroundStyle(.black)
                            }
                            Text(isPlaying ? "Pause" : "Play")
                                .scaledFont(.caption)
                                .foregroundStyle(.white.opacity(0.8))
                        }
                    }
                    .accessibilityLabel(isPlaying ? "Pause" : "Play")
                    labeledButton(SkipIntervals.forwardSymbol(skipForwardSeconds),
                                  label: "Forward \(skipForwardSeconds)s") {
                        onSeek(Double(skipForwardSeconds))
                    }
                }
                wideButton {
                    Label("Options", systemImage: "list.bullet")
                        .foregroundStyle(.white)
                } background: { Color.white.opacity(0.12) } action: { showOptions = true }
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.4)
            wideButton {
                Label(transport == .cast ? "Stop Casting" : "Stop AirPlay",
                      systemImage: "stop.fill")
                    .foregroundStyle(.red)
            } background: { Color.red.opacity(0.15) } action: { onStop() }
        }
        .frame(maxWidth: .infinity)
    }

    private func wideButton<L: View>(@ViewBuilder _ label: () -> L,
                                     background: () -> Color,
                                              action: @escaping () -> Void) -> some View {
        let bg = background()
        return Button(action: action) {
            label()
                .scaledFont(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(bg, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var header: some View {
        VStack(spacing: 4) {
            if let art = artURL, let url = URL(string: art) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    transportGlyph
                }
                .frame(maxWidth: 140, maxHeight: 72)
            } else {
                transportGlyph
            }
            Text(channelName)
                .scaledFont(.title3.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(statusText)
                .scaledFont(.subheadline)
                .foregroundStyle(Color.contrastText(accent))
                .lineLimit(1)
        }
        .multilineTextAlignment(.center)
    }

    private var transportGlyph: some View {
        Image(systemName: transport == .cast ? RemoteSessionCard.Transport.cast.glyph
                                             : RemoteSessionCard.Transport.airPlay.glyph)
            .font(.system(size: 40))  // glyph in a fixed box: not text, stays fixed
            .foregroundStyle(accent)
            .frame(height: 56)
    }

    /// Now-airing programme for `channelID` at `now`, same precedence as
    /// ChannelRow.liveProgram: the channel item's current-program fields
    /// (only while they still cover `now`), else GuideStore's EPG.
    static func nowAiring(channelID: String?, at now: Date = Date())
        -> (title: String, start: Date, end: Date)? {
        guard let channelID else { return nil }
        if let item = ChannelStore.shared.channels.first(where: { $0.id == channelID }),
           let title = item.currentProgram, !title.isEmpty,
           let start = item.currentProgramStart, let end = item.currentProgramEnd,
           start <= now, end > now {
            return (title, start, end)
        }
        if let p = GuideStore.shared.liveProgram(for: channelID, at: now) {
            return (p.title, p.start, p.end)
        }
        return nil
    }

    private var programBlock: some View {
        // Ticks every 30 s: the bar advances and the programme rolls over.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let prog = Self.nowAiring(channelID: channelID, at: context.date)
            let title = prog?.title ?? fallbackSubtitle
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    if let title, !title.isEmpty {
                        Text(title)
                            .scaledFont(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    // Recording: red dot + red LIVE on a red-tinted capsule.
                    HStack(spacing: 4) {
                        Circle().fill(Color.red).frame(width: 5, height: 5)
                        Text("LIVE").scaledFont(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(.red)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.red.opacity(0.15), in: Capsule())
                }
                if let prog, prog.end > prog.start {
                    Text("\(prog.start.formatted(date: .omitted, time: .shortened)) - \(prog.end.formatted(date: .omitted, time: .shortened))")
                        .scaledFont(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    let total = prog.end.timeIntervalSince(prog.start)
                    let elapsed = context.date.timeIntervalSince(prog.start)
                    ProgressView(value: min(max(elapsed / total, 0), 1))
                        .tint(accent)
                } else {
                    // Unknown programme: an empty track, never a full bar.
                    ProgressView(value: 0).tint(accent)
                }
            }
        }
    }

    private func labeledButton(_ symbol: String, label: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle().fill(Color.white.opacity(0.12)).frame(width: 52, height: 52)
                    Image(systemName: symbol)
                        .font(.system(size: 20, weight: .semibold))  // glyph in a fixed box: not text, stays fixed
                        .foregroundStyle(.white)
                }
                Text(label)
                    .scaledFont(.caption)
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .accessibilityLabel(label)
    }

    private static var bottomInset: CGFloat {
        let inset = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets.bottom }
            .first ?? 0
        return max(12, inset)
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
                        Text(s.streamInfo).scaledFont(.footnote.monospaced())
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
    /// AirPlay reuses this sheet (production parity): the channel comes from
    /// the local session, and the Cast-only rows (Sleep Timer, proxy Stream
    /// Info) are hidden.
    var airPlayItem: ChannelDisplayItem? = nil
    private var isAirPlay: Bool { airPlayItem != nil }
    @Environment(\.dismiss) private var dismiss
    @State private var showSwitchStream = false
    @State private var showRecord = false
    @State private var stats: CastHLSProxySession.Stats?

    private let sleepChoices: [(minutes: Int, label: String)] =
        [(0, "Off"), (30, "30 minutes"), (60, "1 hour"), (90, "1.5 hours"), (120, "2 hours")]

    /// The channel the TV is playing, resolved locally (castingContent
    /// carries the id; ChannelStore has the Dispatcharr fields).
    private var castItem: ChannelDisplayItem? {
        if let airPlayItem { return airPlayItem }
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
                    if !isAirPlay {
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
                }
                if !isAirPlay {
                Section("Stream Info") {
                    if let stats {
                        CastStreamInfoCard(stats: stats,
                                           receiverName: cast.connectedDeviceName)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    } else {
                        Text("Waiting for the cast proxy to report.")
                            .scaledFont(.footnote)
                            .foregroundStyle(.secondary)
                    }
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
            while !Task.isCancelled && !isAirPlay {
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
    @Environment(\.aerioTextScale) private var textScale
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
                .scaledFont(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(Color.contrastText(Color.accentPrimary))
                .frame(width: TextScale.grow(46, textScale), alignment: .trailing)
            Text(value)
                .scaledFont(.system(size: 10, weight: .medium, design: .monospaced))
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
        // Same shape and material as the iOS 26 minimized tab-bar button it
        // sits opposite (measured on Logan's screenshot 2026-09-09: a 52 pt
        // plain regular-glass circle, no accent tint, no shadow). Earlier
        // systems keep the tinted glass.
        Button(action: action) {
            Image(systemName: "tv.and.mediabox")
                .font(.system(size: 19, weight: .semibold))  // glyph in a fixed box: not text, stays fixed
                .foregroundStyle(theme.accent)
                .frame(width: 48, height: 48)
        }
        .modifier(CompanionFABChrome())
        .accessibilityLabel("Control a TV")
    }
}

private struct CompanionFABChrome: ViewModifier {
    @ObservedObject private var theme: ThemeManager = .shared
    func body(content: Content) -> some View {
        // Always glass on 26+, whatever the app's Liquid Glass style: the
        // system's minimized tab button ignores that setting, and the flat
        // fallback fill read as a solid navy disc next to it (pixel check
        // 2026-09-09).
        if #available(iOS 26.0, tvOS 26.0, *) {
            // Measured from the live view hierarchy (2026-09-09, [TABBAR]
            // dump): the minimized tab button is a 48 pt _UITabBarPlatterView
            // backed by ClearGlassView, but regular glass is what matches it
            // pixel for pixel on device (sampled 2026-09-09); clear ran darker.
            content.glassEffect(.regular, in: Circle())
        } else {
            content
                .liquidGlass(cornerRadius: 26)
                .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        }
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
        debugLog("[Cast] picker start: discovery state=\(manager.discoveryState.rawValue), devices=\(manager.deviceCount)")
    }

    func stop() {
        manager.remove(self)
    }

    private func reload() {
        let m = manager
        var list: [GCKDevice] = []
        for i in 0..<m.deviceCount { list.append(m.device(at: i)) }
        devices = list
        debugLog("[Cast] picker list: discovery state=\(m.discoveryState.rawValue), devices=\(list.count) \(list.map { $0.friendlyName ?? $0.deviceID })")
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
    @ObservedObject private var airPlay = AirPlayMonitor.shared
    @StateObject private var castDevices = CastDeviceList()
    @ObservedObject private var nativeRegistry = CastNativeDeviceRegistry.shared
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""

    /// One Cast row, used by both the "AerioTV on TV" and "Google Cast"
    /// sections so their behavior stays identical.
    @ViewBuilder
    private func castDeviceRow(_ device: GCKDevice) -> some View {
        let connecting = castController.connectingDeviceID == device.deviceID
        let otherConnecting = castController.connectingDeviceID != nil && !connecting
        Button {
            if !companion.isControlling { companion.disconnect() }
            // Session start AND the channel to load live in one place now
            // (guide pill parity with the in-player chrome).
            castController.beginSession(with: device)
        } label: {
            HStack {
                Label(device.friendlyName ?? "Cast device", systemImage: "sparkles.tv")
                Spacer()
                if connecting {
                    Text("Connecting…").foregroundStyle(.secondary)
                    ProgressView()
                }
            }
        }
        // Selection feedback (Logan 2026-09-11: the sheet looked inert after
        // the tap): the tapped row spins, the rest dim until the attempt
        // settles.
        .disabled(otherConnecting)
        .opacity(otherConnecting ? 0.4 : 1)
    }

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
                            .scaledFont(.title3.monospaced())
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
                    // Devices that have run the AerioTV Android TV app via
                    // Cast Connect get their own section, so the better path
                    // is the obvious one to pick.
                    let nativeDevices = castDevices.devices.filter {
                        nativeRegistry.isNative($0.deviceID)
                    }
                    if !nativeDevices.isEmpty {
                        Section {
                            ForEach(nativeDevices, id: \.deviceID) { device in
                                castDeviceRow(device)
                            }
                        } header: {
                            Text("AerioTV on TV")
                        } footer: {
                            Text("Plays in the AerioTV app on the TV: no phone processing, full quality.")
                        }
                    }
                    Section("Google Cast") {
                        if castDevices.devices.isEmpty {
                            Text("Searching for devices…")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(castDevices.devices.filter { !nativeRegistry.isNative($0.deviceID) },
                                id: \.deviceID) { device in
                            castDeviceRow(device)
                        }
                        if let error = castController.connectError {
                            Text(error)
                                .scaledFont(.footnote)
                                .foregroundStyle(.red)
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
                            if case .probing = airPlay.phase {
                                // Cast parity: the connecting row shows the
                                // receiver with a spinner.
                                HStack {
                                    Label(airPlay.deviceName ?? "AirPlay", systemImage: "airplay.video")
                                    Spacer()
                                    Text("Connecting…").foregroundStyle(.secondary)
                                    ProgressView()
                                }
                            } else {
                            VStack(alignment: .leading, spacing: 2) {
                                Label("AirPlay", systemImage: "airplay.video")
                                Text("Choose a TV, then start a channel")
                                    .scaledFont(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            }
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
        // Freshly connected on either transport -> the picker's job is done.
        // The user stays on the page they were on; the remote-session card
        // above the tab bar takes over (rule 1, Logan 2026-09-12).
        .onChange(of: companion.isControlling) { _, controlling in
            if controlling { dismiss() }
        }
        // 2026-09-21 production recording: the title flips "Cast to" ->
        // "Connected" (navigationTitle reads isCasting), holds briefly so
        // the user sees it, then the sheet dismisses onto the idle card.
        .onChange(of: castController.state) { _, state in
            if case .connected = state {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(600))
                    if castController.isCasting { dismiss() }
                }
            }
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
                            .scaledFont(.title3.monospaced())
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

// AirPlayMonitor moved to App/AirPlayMonitor.swift (phases + receiver, 2026-09-21 rebuild).

// MARK: - Remote session card (Logan 2026-09-12)

/// The ONE card for all three transports (Google Cast, AirPlay, AerioTV
/// Remote companion). It sits above the bottom tab bar on every tab for as
/// long as a session is live, so choosing a device never moves the user off
/// the page they were on, and tapping it opens the applicable remote controls
/// in a sheet. Sized off the Android CastMiniController/CastTransportCard (dp
/// map 1:1 to points on phone) and finished like the channel list rows
/// (Logan 2026-09-12): theme card fill with the 10% accent hairline, 12 pt
/// corners, 16 pt side margins (the list's own margin), 6 pt above the tab
/// bar, 44 pt art tile, and THREE lines -- channel name, program, then the
/// accent status line -- with accent play/pause and X trailing.
struct RemoteSessionCard: View {

    enum Transport {
        case cast, airPlay, companion

        var glyph: String {
            switch self {
            case .cast: return "sparkles.tv"
            case .airPlay: return "airplay.video"
            case .companion: return "tv.and.mediabox"
            }
        }
    }

    let transport: Transport
    let title: String
    let status: String
    var artURL: String? = nil
    let isPlaying: Bool
    /// Android parity (CastMiniController.showTransport): hidden while nothing
    /// is playing on the other screen yet, since there is nothing to pause.
    var showTransport: Bool = true
    let onTap: () -> Void
    let onTogglePlayPause: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Leading tile, Android CastMiniController: the channel logo, or
            // the transport glyph when nothing is playing yet.
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black.opacity(0.25))
                if let artURL, let url = URL(string: artURL) {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        Image(systemName: transport.glyph)
                            .font(.system(size: 20))  // glyph in a fixed box: not text, stays fixed
                            .foregroundStyle(ThemeManager.shared.accent)
                    }
                    .frame(width: 38, height: 38)
                } else {
                    Image(systemName: transport.glyph)
                        .font(.system(size: 20))  // glyph in a fixed box: not text, stays fixed
                        .foregroundStyle(ThemeManager.shared.accent)
                }
            }
            .frame(width: 44, height: 44)
            // THREE lines like the Android card: channel bold, program, then
            // the accent status line ("Controlling <TV>" / "Casting to <TV>").
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .scaledFont(.subheadline.weight(.bold))
                    .lineLimit(1)
                Text(status)
                    .scaledFont(.caption)
                    .foregroundStyle(Color.contrastText(ThemeManager.shared.accent))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if showTransport {
                Button(action: onTogglePlayPause) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .semibold))  // glyph in a fixed box: not text, stays fixed
                        .foregroundStyle(ThemeManager.shared.accent)
                        .frame(width: 38, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPlaying ? "Pause" : "Play")
            }
            // X is accent-colored on Android too, and it always ends the
            // session (see HomeView: stop on the TV, then close the card).
            Button(action: onStop) {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))  // glyph in a fixed box: not text, stays fixed
                    .foregroundStyle(ThemeManager.shared.accent)
                    .frame(width: 38, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // The SAME material the tab bar below draws (Logan 2026-09-12: "the
        // coloring should match the nav bar"): system Liquid Glass tinted
        // near-black, 12 pt corners, subtle white hairline. No accent wash:
        // the accent stays on the status line and the buttons.
        .background { Self.cardSurface }
        .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        // Same horizontal margin as the list cards.
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
        .onTapGesture {
            debugLog("[Cast] card tap")
            onTap()
        }
        .onAppear { debugLog("[Cast] card show") }
        .onDisappear { debugLog("[Cast] card hide") }
        .accessibilityElement(children: .contain)
    }

    /// 12 pt: the channel list card's radius, kept here so the card still
    /// lines up with the lists it floats over.
    private static let radius: CGFloat = 12

    /// The tab bar's own tone: near-black over the glass backdrop, so the
    /// card and the bar read as one material instead of two tiles.
    private static let glassTint = Color.black.opacity(0.45)
    /// The bar's hairline is a faint white, not an accent line.
    private static let hairline = Color.white.opacity(0.10)

    @ViewBuilder
    private static var cardSurface: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Group {
            if #available(iOS 26.0, *) {
                // Same call MinimizedTabButton uses for the minimized bar
                // pill, so the card picks up the identical Liquid Glass.
                Color.clear
                    .glassEffect(.regular, in: shape)
                    .overlay { shape.fill(glassTint) }
            } else {
                shape
                    .fill(.regularMaterial)
                    .overlay { shape.fill(glassTint) }
            }
        }
        .overlay { shape.strokeBorder(hairline, lineWidth: 1) }
        .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
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
        case "stop":
            // The phone's card X (Logan 2026-09-12): stop playback on THIS TV.
            // The phone drops the link right after, so nothing needs a reply.
            DebugLogger.shared.log("[Companion] host stop: ending playback", category: "Companion")
            PlayerSession.shared.exit()
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
                        .scaledFont(.callout.weight(.semibold))
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
                        .scaledFont(.system(size: 64))
                        .foregroundStyle(Color.accentColor)
                    Text("Pair your phone")
                        .scaledFont(.title.weight(.semibold))
                        .foregroundStyle(.white)
                    Text("Enter this code in AerioTV on your phone")
                        .scaledFont(.title3)
                        .foregroundStyle(.white.opacity(0.7))
                    Text(code)
                        .scaledFont(.system(size: 88, weight: .bold, design: .rounded).monospacedDigit())
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
