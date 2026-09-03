import Foundation
#if os(iOS)
import Combine
import MediaPlayer

/// iPhone Now Playing controls while the phone controls an AerioTV TV
/// (companion remote, GH #33; Logan 2026-09-02, parity with the Android
/// media notification). Drives `NowPlayingBridge` from `CompanionClient`
/// state: the current programme as the title, "<channel> on <TV>" beneath,
/// the channel logo, play/pause and skip 30 forwarded over the companion
/// socket, next/previous flipping the TV's channel. Torn down on disconnect.
///
/// Local playback is stopped when a companion session starts
/// (`CompanionClient.onControllingStarted` -> `PlayerSession.stop()`), which
/// tears the bridge down; the configure here runs after a short debounce so
/// it always lands on top of that teardown.
@MainActor
final class CompanionNowPlaying {
    static let shared = CompanionNowPlaying()
    private init() {}

    private var bag = Set<AnyCancellable>()
    private var tick: Timer?
    private var configuredKey: String?

    func start() {
        guard bag.isEmpty else { return }
        let client = CompanionClient.shared
        Publishers.CombineLatest3(client.$conn, client.$controllingChannelID, client.$nowPlaying)
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in self?.refresh() }
            .store(in: &bag)
        client.$remoteIsPlaying
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] playing in self?.publishRate(playing) }
            .store(in: &bag)
    }

    private func refresh() {
        let client = CompanionClient.shared
        guard client.isControlling else {
            if configuredKey != nil {
                configuredKey = nil
                tick?.invalidate(); tick = nil
                NowPlayingBridge.shared.teardown()
            }
            return
        }
        // Never fight a local player for the lock screen.
        guard NowPlayingManager.shared.playingItem == nil else { return }
        let tvName = client.connectedTVName ?? "TV"
        let channel = client.controllingChannelID.flatMap { id in
            ChannelStore.shared.channels.first { CompanionClient.androidChannelID(for: $0) == id }
        }
        let channelName = channel?.name ?? client.nowPlaying
        let programme = channel?.currentProgram?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (programme?.isEmpty == false ? programme! : (channelName.isEmpty ? "Controlling \(tvName)" : channelName))
        let subtitle = (channelName.isEmpty || channelName == title) ? "on \(tvName)" : "\(channelName) on \(tvName)"
        let key = "\(client.controllingChannelID ?? "-")|\(title)|\(subtitle)"
        guard key != configuredKey else { return }
        configuredKey = key
        NowPlayingBridge.shared.configure(
            title: title,
            subtitle: subtitle,
            artworkURL: channel?.logoURL,
            duration: nil,
            isLive: true,
            programStart: channel?.currentProgramStart,
            programEnd: channel?.currentProgramEnd,
            onPlay: { CompanionClient.shared.play() },
            onPause: { CompanionClient.shared.pause() },
            onSeek: nil,
            onSkip: { secs in CompanionClient.shared.seekBy(Int64(secs * 1000)) },
            onFlipChannel: { delta in CompanionClient.shared.flipChannel(delta) }
        )
        publishRate(client.remoteIsPlaying)
        tick?.invalidate()
        // 30 s tick: advances the programme timeline, and picks up a
        // programme rollover or late EPG (the key includes the title).
        tick = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
                self?.publishRate(CompanionClient.shared.remoteIsPlaying)
            }
        }
    }

    private func publishRate(_ playing: Bool) {
        guard configuredKey != nil else { return }
        NowPlayingBridge.shared.updateElapsed(0, rate: playing ? 1 : 0)
    }
}
#endif
