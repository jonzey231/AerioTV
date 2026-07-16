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

/// Fullscreen "Casting to <device>" remote shown while a web-receiver session
/// is live. Local playback is torn down underneath (HomeView owns that swap);
/// this screen drives the TV: play/pause via RemoteMediaClient, channel
/// up/down as fresh loads, X ends the session (HomeView then resumes local
/// playback). Mirrors the Android CastRemoteOverlay's basic-cast tier.
/// Inlined here (not its own file) so no pbxproj target surgery is needed.
struct CastRemoteScreen: View {
    @ObservedObject private var cast = AerioCastController.shared
    var deviceName: String?
    var onChannelUp: () -> Void
    var onChannelDown: () -> Void
    var onStopCasting: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 18) {
                Spacer()
                if let art = cast.castingContent?.artURL, let url = URL(string: art) {
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
                Text(cast.castingContent?.title ?? "")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                if let sub = cast.castingContent?.subtitle, !sub.isEmpty {
                    Text(sub)
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                }
                Text("Casting to \(deviceName ?? "TV")")
                    .font(.callout)
                    .foregroundStyle(Color.accentColor)
                Spacer()
                HStack(spacing: 28) {
                    transportButton("chevron.down", label: "Channel down", action: onChannelDown)
                    Button(action: { cast.remoteTogglePlayPause() }) {
                        ZStack {
                            Circle().fill(Color.accentColor).frame(width: 74, height: 74)
                            Image(systemName: cast.remoteIsPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 30, weight: .bold))
                                .foregroundStyle(.black)
                        }
                    }
                    .accessibilityLabel(cast.remoteIsPlaying ? "Pause" : "Play")
                    transportButton("chevron.up", label: "Channel up", action: onChannelUp)
                    transportButton("xmark", label: "Stop casting", action: onStopCasting)
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
#endif
