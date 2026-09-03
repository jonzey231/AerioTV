import Foundation
#if os(iOS)
import AVFoundation
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
    /// iOS lists an app in Control Center / the lock screen only once its
    /// audio session has actually rendered audio; metadata plus playbackState
    /// alone never surface (device log 2026-09-02: configure published, no
    /// widget). A looping silent clip keeps the session live for the length
    /// of the companion session, the same trick remote-speaker apps use.
    private var silence: AVAudioPlayer?

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
                stopSilence()
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
        startSilence()
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

    private func startSilence() {
        if silence?.isPlaying == true { return }
        if silence == nil {
            silence = try? AVAudioPlayer(data: Self.silentWav(seconds: 2), fileTypeHint: AVFileType.wav.rawValue)
            silence?.numberOfLoops = -1
            silence?.volume = 0
        }
        silence?.prepareToPlay()
        silence?.play()
    }

    private func stopSilence() {
        silence?.stop()
    }

    /// 8 kHz mono 16-bit PCM WAV of digital silence, built in memory so no
    /// asset ships with the app.
    private static func silentWav(seconds: Int) -> Data {
        let sampleRate: UInt32 = 8000
        let frames = UInt32(seconds) * sampleRate
        let dataSize = frames * 2
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!); u32(36 + dataSize); d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1); u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(dataSize)
        d.append(Data(count: Int(dataSize)))
        return d
    }

    private func publishRate(_ playing: Bool) {
        guard configuredKey != nil else { return }
        NowPlayingBridge.shared.updateElapsed(0, rate: playing ? 1 : 0)
    }
}
#endif
