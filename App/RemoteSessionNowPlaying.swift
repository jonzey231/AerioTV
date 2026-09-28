#if os(iOS)
import Combine
import Foundation

// MARK: - Now Playing for remote sessions (rebuilt 2026-09-24 from the 2026-09-21 log)

/// Names the receiver on the lock screen / Control Center while an AirPlay
/// receiver or a Chromecast plays the session, and logs it:
/// `[NOWPLAYING] publish remote session kind=airplay channel=ESPN HD
/// program=NFL Live device=AirPlay · Living Room Apple TV` and
/// `[NOWPLAYING] cleared`.
@MainActor
enum RemoteSessionNowPlaying {

    enum Kind: String { case airplay, cast }

    private struct Published: Equatable {
        let kind: Kind
        let channel: String
        let program: String?
        let device: String
    }

    private static var current: Published?
    private static var subscriptions: Set<AnyCancellable> = []

    static func publish(kind: Kind, channel: String, program: String?, device: String) {
        let next = Published(kind: kind, channel: channel, program: program, device: device)
        guard next != current else { return }
        current = next
        debugLog("[NOWPLAYING] publish remote session kind=\(kind.rawValue) channel=\(channel) program=\(program ?? "-") device=\(device)")
        NowPlayingBridge.shared.setRemoteDeviceLabel(device)
    }

    static func clear() {
        guard current != nil else { return }
        current = nil
        NowPlayingBridge.shared.setRemoteDeviceLabel(nil)
        debugLog("[NOWPLAYING] cleared")
    }

    /// `AirPlay · <receiver>` once resolved, plain `AirPlay` otherwise (a
    /// generic route name never yields `AirPlay · AirPlay`).
    static func airPlayDeviceLabel() -> String {
        let monitor = AirPlayMonitor.shared
        if let name = monitor.receiver?.displayName ?? monitor.deviceName,
           !AirPlayReceiver.isGenericName(name) {
            return "AirPlay · \(name)"
        }
        return "AirPlay"
    }

    /// The tile started serving a receiver.
    static func publishAirPlay(item newItem: ChannelDisplayItem? = nil) {
        guard let item = newItem ?? NowPlayingManager.shared.playingItem else { return }
        publish(kind: .airplay, channel: item.name, program: programText(item.currentProgram),
                device: airPlayDeviceLabel())
    }

    /// The receiver resolved (or changed) while serving: refresh the label.
    static func republishAirPlayDevice() {
        guard current?.kind == .airplay || AirPlayTileDelivery.isServingReceiver else { return }
        publishAirPlay()
    }

    private static func programText(_ program: String?) -> String? {
        let t = program?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (t?.isEmpty == false) ? t : nil
    }

    /// Process-wide: EPG program changes and channel flips re-publish the
    /// AirPlay line; the Cast session publishes and clears through the
    /// same API. Idempotent; called at scene activation.
    static func startObserving() {
        guard subscriptions.isEmpty else { return }
        NowPlayingManager.shared.$playingItem
            .receive(on: DispatchQueue.main)
            .sink { item in
                MainActor.assumeIsolated {
                    if AirPlayTileDelivery.isServingReceiver, let item { publishAirPlay(item: item) }
                }
            }
            .store(in: &subscriptions)
        let cast = AerioCastController.shared
        cast.$castingContent.combineLatest(cast.$state)
            .receive(on: DispatchQueue.main)
            .sink { content, state in
                // @Published emits before the write lands, so the values
                // come from the pipeline, never from `cast`.
                var connected = false
                if case .connected = state { connected = true }
                MainActor.assumeIsolated {
                    if let content, connected {
                        publish(kind: .cast, channel: content.title, program: programText(content.subtitle),
                                device: "Casting to \(cast.connectedDeviceName ?? "TV")")
                    } else if current?.kind == .cast {
                        clear()
                    }
                }
            }
            .store(in: &subscriptions)
    }
}
#endif
