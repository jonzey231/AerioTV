import Foundation
import Network
import UniformTypeIdentifiers
import SwiftData
import SwiftUI
import AVFoundation
import AVKit
import CoreMedia
import Combine

// MARK: - TS-to-HLS remuxer (TEST, branch test/avplayer-hls-engine)

/// On-device MPEG-TS to HLS remuxer: ingests a continuous raw MPEG-TS HTTP
/// stream (Dispatcharr /proxy/ts/), cuts it into HLS segments on keyframe
/// boundaries WITHOUT transcoding (pure 188-byte packet copy), and serves a
/// rolling live playlist from 127.0.0.1 so AVPlayer can play it natively.
///
/// Why this exists: AVPlayer cannot play raw MPEG-TS over HTTP at all
/// (CoreMedia -12939); TS is only legal inside an HLS playlist. H.264 +
/// AC-3/AAC in TS segments is fully HLS-legal (RFC 8216 sec 3.2; Apple
/// authoring rules 1.2/2.5), so for those streams segmentation alone makes
/// them AVPlayer-playable, which buys the native HDR pipeline, Atmos
/// passthrough, and AirPlay.
///
/// Codec gate (checked from the PMT before anything is served):
/// - video MUST be H.264 (stream_type 0x1B). HEVC (0x24) needs fMP4
///   segments per Apple authoring rule 1.5 (a real repackager, out of
///   scope here); MPEG-2 (0x01/0x02) is not decodable by AVPlayer at all.
/// - audio entries must be AC-3 (0x81), E-AC-3 (0x87), or ADTS AAC (0x0F).
///   MP2 (0x03/0x04) is not in Apple's HLS codec list.
/// On a gate failure `onError` fires with the codec name and the caller
/// falls back to the mpv pipeline.
///
/// Latency expectation: AVPlayer joins a live playlist about three target
/// durations behind the newest segment, so with ~2s segments expect roughly
/// 4-8s tap-to-video and 6-10s behind the live edge (vs ~3.5s on mpv).
/// Segment length is ultimately dictated by the provider's GOP cadence
/// because segments must start on keyframes.
/// How the remuxed HLS reaches AVPlayer. Loopback HTTP (127.0.0.1) is the
/// proven path. iOS and iPadOS route EVERY URL request, loopback included,
/// through a configured Wi-Fi proxy or PAC, so on such a network the
/// player's playlist and segment fetches never come back and the item sits
/// at .unknown until the watchdog gives up, while mpv (its own networking)
/// plays the same channel (Freyguy1975, iPad at work, 2026-09-09: nine
/// straight 12 s timeouts on one afternoon, sub-second starts at home).
/// In-process delivery hands the same bytes to AVFoundation through an
/// AVAssetResourceLoader on a custom scheme: no socket, no proxy.
enum HLSDelivery {
    static let scheme = "aeriohls"

    /// A one-line description of the system proxy configuration, nil when
    /// there is none.
    static func systemProxyDescription() -> String? {
        guard let dict = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else { return nil }
        var parts: [String] = []
        if (dict["HTTPEnable"] as? Int) == 1 {
            parts.append("HTTP=\(dict["HTTPProxy"] as? String ?? "?"):\(dict["HTTPPort"] as? Int ?? 0)")
        }
        if (dict["HTTPSEnable"] as? Int) == 1 {
            parts.append("HTTPS=\(dict["HTTPSProxy"] as? String ?? "?"):\(dict["HTTPSPort"] as? Int ?? 0)")
        }
        if (dict["ProxyAutoConfigEnable"] as? Int) == 1 {
            parts.append("PAC=\(dict["ProxyAutoConfigURLString"] as? String ?? "?")")
        }
        if (dict["ProxyAutoDiscoveryEnable"] as? Int) == 1 {
            parts.append("WPAD")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Set when a loopback start died at .unknown (a proxy or VPN that
    /// captures loopback without showing up in the system settings); the
    /// next remuxer in this process delivers in-process instead.
    nonisolated(unsafe) static var forceInProcessNextStart = false

    /// An AirPlay output is on the audio route. In-process delivery
    /// (custom-scheme URLs) cannot be handed to a receiver, so a tune with
    /// the route up always takes loopback + LAN (device log 2026-09-25
    /// 16:22:50: an in-process start left the TV with nothing to play).
    static var airPlayRouteActive: Bool {
        #if os(iOS)
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .airPlay }
        #else
        return false
        #endif
    }

    /// Developer override: UserDefaults "hlsInProcessDelivery" = true.
    static var developerForced: Bool { UserDefaults.standard.bool(forKey: "hlsInProcessDelivery") }
}

/// Serves the remuxers' playlists and segments to AVFoundation on the
/// custom scheme. One delegate for every session; the URL host is the
/// session id.
final class HLSResourceLoaderRegistry: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let shared = HLSResourceLoaderRegistry()
    let queue = DispatchQueue(label: "com.aerio.hls-loader")
    private let lock = NSLock()
    private var sessions: [String: () -> TSHLSRemuxer?] = [:]

    func register(_ remuxer: TSHLSRemuxer, id: String) {
        lock.lock(); sessions[id] = { [weak remuxer] in remuxer }; lock.unlock()
    }

    func unregister(id: String) {
        lock.lock(); sessions[id] = nil; lock.unlock()
    }

    private func remuxer(for id: String) -> TSHLSRemuxer? {
        lock.lock(); defer { lock.unlock() }
        return sessions[id]?()
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = loadingRequest.request.url, url.scheme == HLSDelivery.scheme,
              let id = url.host, let remuxer = remuxer(for: id) else { return false }
        // AVFoundation only takes PLAYLISTS (and keys) from a resource
        // loader: a media segment answered with bytes, or redirected to a
        // file, fails with CoreMedia -12881 "custom url not redirect", and a
        // file-scheme playlist never opens (Mac harness 2026-09-10). What it
        // DOES accept is a segment given as a data: URI inside the playlist,
        // so in-process delivery inlines the segments (see playlistText).
        guard url.path.hasSuffix(".m3u8") else {
            loadingRequest.finishLoading(with: NSError(domain: NSURLErrorDomain, code: NSURLErrorUnsupportedURL))
            return true
        }
        remuxer.serve(path: url.path) { response in
            if response.status != 200 {
                loadingRequest.finishLoading(with: NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist))
                return
            }
            if let info = loadingRequest.contentInformationRequest {
                info.contentType = response.uti
                info.contentLength = Int64(response.body.count)
                info.isByteRangeAccessSupported = true
            }
            if let data = loadingRequest.dataRequest {
                let start = Int(data.requestedOffset)
                let end = data.requestsAllDataToEndOfResource
                    ? response.body.count
                    : min(response.body.count, start + data.requestedLength)
                if start < end { data.respond(with: response.body.subdata(in: start..<end)) }
            }
            loadingRequest.finishLoading()
        }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        didCancel loadingRequest: AVAssetResourceLoadingRequest) {}
}

/// Thread-safe scalar slot.
final class DoubleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double
    init(_ initial: Double) { value = initial }
    func set(_ v: Double) { lock.lock(); value = v; lock.unlock() }
    func get() -> Double { lock.lock(); defer { lock.unlock() }; return value }
}

/// Rolling 30 s wall window of segment closures, shared by every live
/// remuxer and read from the main thread by the playback driver.
///
/// Separates the two shapes of a bad feed, which the starvation
/// timestamp alone cannot tell apart (2026-09-11, atvlogs/s6_85.txt):
/// a BURSTY feed delivers nothing for 5 to 8 s and then hands over two
/// or three segments at once while its AVERAGE rate stays at real time
/// (a bigger hold-back absorbs that), and a SLOW feed delivers below
/// real time (no hold-back can fill a buffer the feed is not filling).
final class FeedRateWindow: @unchecked Sendable {
    private let lock = NSLock()
    private let windowSeconds: TimeInterval = 30
    /// (wall clock of the closure, media seconds it carried, extra wall
    /// time beyond that media length since the previous closure).
    private var samples: [(wall: Date, media: Double, excess: Double)] = []
    private var lastWall: Date?
    private var published = 0

    func record(closeWall: Date, mediaDuration: Double) {
        lock.lock(); defer { lock.unlock() }
        let excess: Double
        if let lastWall { excess = max(0, closeWall.timeIntervalSince(lastWall) - mediaDuration) }
        else { excess = 0 }
        lastWall = closeWall
        samples.append((wall: closeWall, media: mediaDuration, excess: excess))
        published &+= 1
        let cutoff = closeWall.addingTimeInterval(-windowSeconds)
        while let first = samples.first, first.wall < cutoff { samples.removeFirst() }
    }

    /// Media seconds closed in the window / wall seconds it spans.
    /// Nil until the window covers at least 15 s, so a fresh tune never
    /// looks like a slow feed.
    func rateRatio(_ now: Date = Date()) -> Double? {
        lock.lock(); defer { lock.unlock() }
        guard let first = samples.first, let last = samples.last else { return nil }
        let span = last.wall.timeIntervalSince(first.wall)
        guard span >= 15, span > 0 else { return nil }
        // The first sample bounds the window; its media landed before it.
        let media = samples.dropFirst().reduce(0.0) { $0 + $1.media }
        return media / span
    }

    /// Worst "extra" wall time beyond the media length in the window.
    func worstGap() -> Double {
        lock.lock(); defer { lock.unlock() }
        return samples.reduce(0.0) { max($0, $1.excess) }
    }

    /// Monotonic count of segments closed since launch. Never resets, so
    /// a captured value can be compared later for "did anything arrive".
    func publishedCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return published
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        samples.removeAll()
        lastWall = nil
    }
}

/// Thread-safe "when did this last happen" slot.
final class TimestampBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date?
    func set(_ date: Date) { lock.lock(); value = date; lock.unlock() }
    func secondsSince(_ now: Date = Date()) -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        guard let value else { return nil }
        return now.timeIntervalSince(value)
    }
}

final class TSHLSRemuxer: NSObject, @unchecked Sendable {

    enum RemuxError: Error, CustomStringConvertible {
        case unsupportedCodec(String)
        case ingestFailed(String)
        case serverFailed

        var description: String {
            switch self {
            case .unsupportedCodec(let codec): return "unsupported codec: \(codec)"
            case .ingestFailed(let reason):    return "ingest failed: \(reason)"
            case .serverFailed:                return "local HLS server failed"
            }
        }
    }

    // MARK: Tunables

    /// Minimum seconds between segment cuts; the actual cut lands on the
    /// FIRST keyframe at or after this much elapsed PTS.
    private let targetSegmentSeconds = 2.0
    /// Startup ramp (2026-08-25 ESPN capture): the 6.15s tune-in was
    /// 1.9s connect + 4s of accumulating readyThreshold 2.0s segments.
    /// The first few segments therefore cut at the first keyframe after
    /// 1.0s instead, halving the accumulation phase wherever the feed's
    /// keyframe cadence is denser than 2s. On a 2s-GOP feed the cuts
    /// still land at 2s and this is a no-op, never a regression.
    private let startupRampSegments = 3
    /// REVERTED to 1.0 on 2026-09-11 after the 17:15 device session.
    /// The 0.0 "cut at the first keyframe after any media" ramp produced
    /// a 1.05 s segment 0 on ESPN2 (session2.txt:381) and CoreMedia
    /// answered -16832 "restarting 1.051000s from end of live playlist;
    /// target duration 2s - stall danger" twice on that item
    /// (session2.txt:398, 400). A segment shorter than the advertised
    /// target duration is its own hazard, so the ramp stays at 1.0: on a
    /// feed with a denser-than-2 s GOP it still halves the accumulation
    /// phase, and on a 2.5 s-GOP feed it is a no-op rather than a risk.
    private let startupSegmentSeconds = 1.0
    /// Segments advertised in the live playlist window. 8 (not 6): the
    /// same capture showed AVPlayer recovers from an upstream delivery
    /// gap by re-buffering deeper behind the edge; a 16s window gives
    /// that recovery room where 12s ran out during a 9.2s feed gap.
    private let liveWindowSegments = 8
    /// Segments retained in memory; old ones beyond this are dropped even
    /// if a slow client might still want them (live TV: it should not).
    private let maxBufferedSegments = 12
    /// A BYTE ceiling (40 MB) was added to this ring on 2026-09-11 and
    /// REVERTED the same day. On Sky Sports Main Event UHD it held the
    /// ring at SEVEN segments instead of twelve ("buffered 7" with 5 to
    /// 7 MB segments, session4.txt 17:48:24-17:48:46), so every segment
    /// the player fetched more than ~25 s behind the edge came off DISK
    /// instead of RAM on a 4K path that was already running 8 to 11 s
    /// behind the live edge and stalling. The memory it saved was never
    /// the thing that killed the app; a count-only ring is what the
    /// delivery path was tuned against.
    /// Channel retention: while this remuxer ingests DETACHED (no tile
    /// playing it), keep only a couple of segments in RAM - the disk
    /// spill holds the window, and a retained UHD channel at 12 in-RAM
    /// segments would be ~350MB of dead weight (jetsam bait on tvOS).
    /// Restored to the full buffer on adoption.
    private var retainedRAMCap: Int?
    /// Catch-up: the upstream killed (or finished) the ingest but the
    /// downloaded window is intact on disk. Marking complete finalizes
    /// the playlist with EXT-X-ENDLIST so AVPlayer treats the window as
    /// a finished VOD - smooth playback to the end, no stale-playlist
    /// escalation - and the tile re-tunes only when the playhead gets
    /// there.
    private var playlistComplete = false
    /// Catch-up: declare the playlist EXT-X-PLAYLIST-TYPE:EVENT
    /// (append-only, nothing ever removed - true under full spill).
    /// Players START event playlists at the BEGINNING, which kills the
    /// join-at-edge -> seek-back-to-zero dance outright (play() was
    /// committing to the edge before the queued zero-seek applied:
    /// double buffering, a frozen edge frame, audio-before-video).
    /// NEVER set for Live Rewind - live joins want the edge.
    var eventPlaylist = false

    func markComplete() {
        queue.async {
            // Close any partial segment so its media is in the window.
            if !self.currentSegment.isEmpty, let start = self.currentStartPTS {
                self.closeSegment(endPTS: start + self.targetSegmentSeconds)
            }
            self.playlistComplete = true
        }
    }

    /// Called by the tile when Dispatcharr confirmed change_stream on this
    /// ingest's channel. The connection is kept as is; this only arms the
    /// demux to expect a new source (an SPS change alone then counts),
    /// keeps the switch gap out of the starvation telemetry, and marks the
    /// switch for the playback driver's hold-back learner.
    /// The URL this ingest is actually reading. Switch Stream observers
    /// match on this, not on a view's item/override URL, which can lag an
    /// in-place tile swap.
    var ingestURL: URL { sourceURL }

    func noteSourceSwitch() {
        let now = Date()
        Self.lastSourceSwitch.set(now)
        switchLock.lock()
        switchNotedAtShared = now
        switchSegmentAtShared = nil
        switchLock.unlock()
        queue.async {
            self.switchExpectedUntil = now.addingTimeInterval(30)
            self.switchAccountingSuppressed = true
            self.switchQuietClosures = 0
            debugLog("[TS-REMUX] switch: change_stream noted; expecting a new source on the same connection")
        }
    }

    /// Switch Stream watch readout, safe from any thread: whether the
    /// demux is still re-acquiring the new source (PSI re-gate or waiting
    /// for its first IDR), and when the last segment after the most recent
    /// noted switch was stored (nil until one lands).
    var sourceSwitchProgress: (regating: Bool, lastSegmentAt: Date?) {
        switchLock.lock(); defer { switchLock.unlock() }
        return (switchRegatingShared, switchSegmentAtShared)
    }

    private func setRegatingShared(_ on: Bool) {
        switchLock.lock(); switchRegatingShared = on; switchLock.unlock()
    }

    func setRetained(_ on: Bool) {
        queue.async {
            self.retainedRAMCap = on ? 2 : nil
            if on, self.segments.count > 2 {
                self.segments.removeFirst(self.segments.count - 2)
            }
        }
    }
    /// Segments that must exist before `onReady` fires with the playlist
    /// URL. Two keeps startup low; AVPlayer refreshes the playlist as more
    /// land.
    ///
    /// Tried at ONE on 2026-09-11 (review section 1 proposal 3) and
    /// REVERTED the same day: a one-segment live playlist puts AVPlayer at
    /// the end of the playlist with nothing ahead of it, and every tune of
    /// the 17:15 session then froze at pos 0.0 with status playing
    /// (session2.txt:302-347, with CoreMedia -16832 "stall danger" at
    /// :398). The 487 to 1885 ms this was meant to save is not worth a
    /// stream that never starts.
    private let readyThreshold = 2

    // MARK: Callbacks (delivered on the main queue, each at most once)

    var onReady: ((URL) -> Void)?
    var onError: ((RemuxError) -> Void)?
    /// Fires once with the stream's measured geometry / frame rate /
    /// 10-bit flag, from whichever arm is producing. The tile uses it to
    /// set AVDisplayManager.preferredDisplayCriteria: a bare
    /// AVPlayerLayer never triggers a display-mode match on its own
    /// (that is an AVPlayerViewController perk), so without this the
    /// panel stays at the home-screen 4K SDR 60 regardless of content.
    /// Width/height are 0 from the TS arm (it never parses the SPS);
    /// the tile falls back to a nominal geometry there.
    var onVideoParameters: ((_ width: Int, _ height: Int, _ fps: Double, _ is10Bit: Bool) -> Void)?
    /// Fires once, on the main queue, the moment the upstream delivers
    /// its FIRST byte. The live tile arms a first-byte deadline against
    /// it: a Dispatcharr connection can open and then stay silent for
    /// the whole 30 s URLSession timeout while the server's own health
    /// checks sit behind a 60 s init grace period (s7_86.txt:353-395,
    /// ESPN2 HD at 18:37:12 - zero bytes for 30 s, then a fresh pipeline
    /// silent for another 12 s until the user flipped away).
    var onFirstByte: (() -> Void)?
    /// Live stall signal (Android parity, 2026-09-14). Fires on the main
    /// queue with `true` the moment the ingest has gone
    /// `ingestSilenceThreshold` with no bytes on the wire, and again with
    /// `false` the moment bytes resume. Armed only when
    /// `reportsIngestStall` is set (live tunes); VOD/catch-up/DVR
    /// downloads legitimately go quiet and must never flash a status.
    /// The first-byte window is NOT covered here: an ingest that has
    /// never delivered a byte belongs to the tile's first-byte deadline
    /// and its stream-failover walk.
    var onIngestSilence: ((Bool) -> Void)?
    /// Fires once on the main queue when the upstream CLOSES a live
    /// ingest cleanly (EOF with no error, e.g. the stream was stopped in
    /// Dispatcharr). Before this the live branch of didCompleteWithError
    /// did nothing at all, so a server-side stop was only ever noticed
    /// later by the silence/stale-frame ladder; a closed connection is
    /// proof the upstream is gone, so the consumer re-tunes at once.
    var onIngestClosed: (() -> Void)?
    /// Set by live consumers before start(); see onIngestSilence.
    var reportsIngestStall = false
    /// Seconds of dead air that count as a stall (Android parity: the
    /// Android player shows its "Reconnecting" line at 2 s).
    static let ingestSilenceThreshold: Double = 2
    /// True once the upstream has delivered any byte. Readable from any
    /// thread (set on the URLSession delegate queue, read on the main
    /// queue by a tile adopting a WARM ingest, whose first byte can
    /// easily land before the tile mounts and its callback exists).
    var hasReceivedFirstByte: Bool {
        firstByteLock.lock(); defer { firstByteLock.unlock() }
        return firstByteArrived
    }
    private let firstByteLock = NSLock()
    private var firstByteArrived = false
    /// When the upstream's HTTP response landed (nil until it does), and
    /// the running total of ingested bytes, both readable from any
    /// thread. The tile's loading detail line polls these to tell
    /// "still connecting" from "connected but silent" from "receiving"
    /// while the spinner is up. Kept separate from totalBytesIngested,
    /// which is touched only on the remuxer's own queue.
    var ingestConnectedAt: Date? {
        firstByteLock.lock(); defer { firstByteLock.unlock() }
        return connectedAt
    }
    var bytesIngested: Int64 {
        firstByteLock.lock(); defer { firstByteLock.unlock() }
        return ingestedBytes
    }
    /// When the last ingest byte landed, readable from any thread (nil
    /// until the first one does). The tile's silent-start deadline polls
    /// this so it can measure SILENCE rather than elapsed time: a feed
    /// that is crawling in below real time is still alive and must never
    /// be walked away from (Glitzbr 2026-09-15, an over-the-air
    /// HDHomeRun feed that degraded to 0.68 of real time was abandoned
    /// for much worse backups).
    var lastIngestByteAt: Date? {
        firstByteLock.lock(); defer { firstByteLock.unlock() }
        return lastByteAt
    }
    private var connectedAt: Date?
    private var ingestedBytes: Int64 = 0
    /// When the last ingest byte landed (nil until the first one does).
    /// Written on the URLSession delegate queue under firstByteLock, read
    /// by the silence poll on the remuxer's own queue.
    private var lastByteAt: Date?
    /// Latched state of the silence signal, touched only on `queue`.
    private var silenceReported = false
    /// One clean-close report per ingest, touched only on the delegate queue.
    private var closeReported = false
    /// A non-200 ingest response whose (small) JSON body we are buffering
    /// before failing, plus its Retry-After. Dispatcharr answers every
    /// live-proxy 503 with {"error": "<reason>"}, and that reason is the
    /// difference between "the proxy is still tearing down the previous
    /// session for this channel, the same URL works in a second" and
    /// "the server already tried this channel's streams and has none",
    /// which need opposite recoveries. Only 503 is buffered; every other
    /// status still fails the moment the response head lands. Touched
    /// only on the URLSession delegate queue.
    private var errorStatusCode: Int?
    private var errorRetryAfter: Double?
    private var errorBody = Data()

    // MARK: State

    private let sourceURL: URL
    private let headers: [String: String]
    private let queue = DispatchQueue(label: "com.aerio.tsremux")
    private var urlSession: URLSession?
    private var ingestTask: URLSessionDataTask?
    /// LiveConnectionRegistry id of the open ingest (single-connection
    /// invariant). Lock-free reads are fine: written on `queue` in
    /// startIngest, read by stop() on main only to mark it closing.
    private let connLock = NSLock()
    private var connID: UUID?
    /// Set synchronously by stop() (under connLock) so a start() still
    /// queued behind it never opens a connection nobody will use.
    private var stopRequested = false
    /// First-byte marker state (see the didReceive hook). Touched only
    /// from the URLSession delegate queue and startIngest.
    private var ingestStartedAt = Date()
    private var firstByteLogged = false
    private var listener: NWListener?
    private var localPort: UInt16 = 0
    /// In-process delivery: base64 of each RAM-window segment (and the fMP4
    /// init), computed once per segment for the inlined playlist.
    private var deliveryBase64: [Int: String] = [:]
    /// Segments advertised by the inlined playlist. Smaller than the
    /// loopback window: every reload carries the segments themselves
    /// (~1.3 MB per 2 s segment as base64).
    private let inlineWindowSegments = 4
    /// In-process delivery (see HLSDelivery): decided once at init.
    let inProcessDelivery: Bool
    let deliveryID = UUID().uuidString.lowercased()
    private let deliveryNote: String
    private var stopped = false

    // TS demux state
    private var pending = Data()
    private var pmtPID = -1
    private var videoPID = -1
    private var patPacket: Data?
    private var pmtPacket: Data?
    private var codecGatePassed = false
    /// Elementary PIDs the PMT declared as audio, and the first audio
    /// stream type it declared. The TS arm never touches the audio
    /// bytes, but it has to know which PID they ride so a segment cut
    /// never lands INSIDE an audio PES (see heldAudio).
    private var audioPIDs = Set<Int>()
    private var audioStreamType: UInt8 = 0
    /// Packets of the audio PES currently in flight, withheld from the
    /// open segment until the PES is complete.
    ///
    /// Why (Logan 2026-09-12, ESPN HD): Dispatcharr's "Web Player (AAC
    /// Audio)" output profile re-muxes with ffmpeg, whose mpegts muxer
    /// accumulates audio up to pes_payload_size (2930 B) before it
    /// writes a PES. Measured on a matching local encode: AAC = one PES
    /// every ~170 ms carrying ~8 ADTS frames across 16 TS packets, with
    /// a NON-ZERO PES_packet_length (~2800); AC-3 off the provider's own
    /// mux = one 32 ms syncframe per PES in 9 packets. Cutting a segment
    /// at a video keyframe used to slice whichever audio PES was in
    /// flight, so every 2.5 s segment ended with a PES whose declared
    /// length never arrives and the next began with an orphan
    /// continuation carrying no PUSI. CoreMedia discards both, which is
    /// ~85-170 ms of AAC missing per segment (audible as audio
    /// "constantly cutting in and out") against <=32 ms of AC-3, and the
    /// resulting stalls are what trained this channel's learned live-edge
    /// hold-back up to 12 s and pushed tune-to-first-frame to 16.7 s.
    /// Holding the PES and carrying it whole into the next segment loses
    /// nothing: TS PIDs are independent streams and the PES keeps its own
    /// PTS.
    private var heldAudio: [Data] = []
    /// Corruption guard: a PES this long is not a PES. ~24 kB of payload,
    /// an order of magnitude past ffmpeg's 2930 B cap.
    private let heldAudioPacketCap = 140
    private var adtsLogged = false
    private var adtsSampleRate = 0
    private var lastAudioPESPTS = -1.0
    private var lastAudioPESFrames = 0
    private var audioGapWarnings = 0
    private var lastAudioGapLogAt = Date.distantPast
    /// Non-nil after the PMT declared HEVC: the fMP4 arm (Apple HLS rule
    /// 1.5 - HEVC only rides fMP4 segments; the TS passthrough below is
    /// the H.264 arm). Bytes route to it INSTEAD of the TS segmenter, the
    /// playlist grows EXT-X-MAP/VERSION 7, and the loopback serves
    /// init.mp4 + .m4s. Audio passes through (AC-3/E-AC-3/AAC), which is
    /// what hands the system pipeline its 5.1/Atmos bitstream.
    private var fmp4: LiveFMP4Remuxer?
    private var fmp4InitSegment: Data?
    /// TS-arm frame-rate measurement: successive video PES PTS deltas.
    /// The median of ~60 access units nails 25/30/50/59.94 without
    /// parsing the SPS.
    private var videoPTSDeltas: [Double] = []
    private var lastVideoAUPTS: Double = -1
    private var videoParamsSent = false

    // MARK: Source switch state (Dispatcharr Switch Stream, 2026-09-15)
    //
    // POST /proxy/ts/change_stream swaps the upstream behind the SAME HTTP
    // TS connection. The new source typically arrives with its own PAT/PMT
    // (different PMT, video and audio PIDs), a new SPS (FHD -> SD), and a
    // PTS / continuity jump. The PSI parsers used to latch the first
    // program forever, so every packet of the new source was dropped while
    // bytes kept flowing (device 16:08:48: 27.8 s with no segment, then
    // -12888). Everything below lets the demux re-acquire the program in
    // place, cut at the new source's first IDR, and tag the playlist with
    // EXT-X-DISCONTINUITY. The connection itself is never touched.
    /// Last PMT content the gate accepted: video PID/type plus the sorted
    /// audio PID/type pairs. A change means a new program.
    private var pmtSignature = ""
    /// Last video PES PTS seen on the TS arm (-1 = none yet).
    private var lastSeenVideoPTS: Double = -1
    /// Last continuity counter seen on the video PID (-1 = none yet).
    private var lastVideoCC = -1
    /// Wall time of the last continuity break or discontinuity_indicator
    /// on the video PID.
    private var lastVideoCCBreakAt = Date.distantPast
    /// Raw bytes of the last SPS seen on the video PID.
    private var lastSPS: [UInt8]?
    /// True from a detected source change until the new source's first
    /// IDR carrying an SPS opens a segment. That segment gets the tag.
    private var awaitingSwitchKeyframe = false
    /// The next stored segment starts a new source: EXT-X-DISCONTINUITY.
    private var nextSegmentDiscontinuity = false
    /// Sequence numbers of every segment that carries the tag. Tiny (one
    /// entry per switch) and never pruned, so the DISCONTINUITY-SEQUENCE
    /// of any window (live RAM, spill, inlined, event) is simply the count
    /// of tagged segments that slid out ahead of that window's first seq.
    private var discontinuitySeqs = Set<Int>()
    /// Set by noteSourceSwitch(): a change_stream was confirmed and the
    /// next source change is expected, so an SPS change alone is enough.
    private var switchExpectedUntil = Date.distantPast
    /// While set, segment closures do not feed the starvation telemetry
    /// (the switch gap is not upstream jitter). Cleared on the first
    /// closure after the discontinuity segment, or after a quiet window.
    private var switchAccountingSuppressed = false
    private var switchQuietClosures = 0
    /// Post-switch reservoir drain deadline (see advancePacedEdge).
    private var pacedDrainUntil: Date?
    /// Normal reservoir the drain pulls back to: two 2 s segments.
    private let pacedDrainReservoirSeconds = 4.0
    /// PTS jumps beyond these are a new source, not B-frame reordering
    /// (reorder is a few frames) or ordinary jitter.
    private let switchPTSJumpForward = 5.0
    private let switchPTSJumpBackward = 2.0
    /// Thread-safe switch progress for the tile's Switch Stream watch:
    /// when the last switch was noted, and when the last segment was
    /// stored after it (nil until one lands).
    private let switchLock = NSLock()
    private var switchNotedAtShared: Date?
    private var switchSegmentAtShared: Date?
    private var switchRegatingShared = false
    /// When ANY live remuxer last saw (or was told about) a source switch.
    /// Read on main by the playback driver so a switch gap never trains
    /// the live-edge hold-back or arms a backward rejoin.
    static let lastSourceSwitch = TimestampBox()

    // Segmenter state
    private var currentSegment = Data()
    private var currentStartPTS: Double?
    private var awaitingFirstKeyframe = true
    private var segments: [(seq: Int, data: Data, duration: Double)] = []
    private var nextSeq = 0
    private var readySignaled = false
    private var errorSignaled = false
    /// Loopback requests logged so far (the first 24 per session).
    private var loggedRequests = 0
    private var lastPollLogAt = Date.distantPast
    private var totalBytesIngested = 0

    // Live Rewind window (task #145): when > 0, every closed segment is
    // also spilled to disk and the playlist advertises the WHOLE spilled
    // window instead of the last `liveWindowSegments`. AVPlayer's own
    // seekableTimeRanges then spans the rewind depth, so native
    // pause/scrub IS the rewind UI. Memory stays bounded by
    // `maxBufferedSegments`; scrubbed-back requests read from disk.
    // Fullscreen single-stream only; multiview tiles pass 0.
    private let rewindWindowSeconds: Double
    private var spillDir: URL?
    private var spilled: [(seq: Int, url: URL, duration: Double)] = []

    init(sourceURL: URL, headers: [String: String], rewindWindowSeconds: Double = 0) {
        self.sourceURL = sourceURL
        self.headers = headers
        self.rewindWindowSeconds = rewindWindowSeconds
        let proxy = HLSDelivery.systemProxyDescription()
        let forced = HLSDelivery.forceInProcessNextStart
        HLSDelivery.forceInProcessNextStart = false
        if HLSDelivery.airPlayRouteActive,
           HLSDelivery.developerForced || proxy != nil || forced {
            // Device log 2026-09-25 16:22:50 / 16:25:12 / 16:26:01: the
            // in-process fallback on an AirPlay route made the tune
            // un-AirPlayable ("LAN delivery unavailable").
            let why = HLSDelivery.developerForced ? "developer override"
                : proxy != nil ? "system proxy" : "previous loopback start never became ready"
            inProcessDelivery = false
            deliveryNote = "loopback (AirPlay route active: in-process fallback for \(why) skipped, the receiver needs the LAN URL)"
        } else if HLSDelivery.developerForced {
            inProcessDelivery = true; deliveryNote = "in-process (developer override)"
        } else if let proxy {
            inProcessDelivery = true; deliveryNote = "in-process (system proxy: \(proxy))"
        } else if forced {
            inProcessDelivery = true; deliveryNote = "in-process (previous loopback start never became ready)"
        } else {
            inProcessDelivery = false; deliveryNote = "loopback (no system proxy)"
        }
        super.init()
    }

    // MARK: Lifecycle

    func start() {
        // New remux session = new source: drop the previous stream's
        // cadence so a channel change cannot leave it on the readouts.
        // Done HERE and not on the player-item swap, because the SPS is
        // parsed before the item exists on this path.
        DispatchQueue.main.async { RemuxMeasuredVideo.shared.reset() }
        queue.async { [weak self] in
            guard let self else { return }
            if self.rewindWindowSeconds > 0 {
                self.setupSpillDir()
            }
            debugLog("[TS-REMUX] delivery: \(self.deliveryNote)")
            if self.inProcessDelivery {
                HLSResourceLoaderRegistry.shared.register(self, id: self.deliveryID)
                self.localPort = 1   // READY gate: "server ready" marker
            } else {
                self.startServer()
            }
            self.startIngest()
        }
    }

    /// Spill lives under the same LiveRewind root the mpv-path engine
    /// uses, so the retention reaper's stale-directory sweep collects
    /// abandoned sessions (e.g. after a crash) on the next launch.
    private func setupSpillDir() {
        // Same platform split as LiveRewindEngine.rootDir: tvOS denies
        // Application Support writes on device; Caches is the only option.
        #if os(tvOS)
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        #else
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        #endif
        let dir = base
            .appendingPathComponent("LiveRewind", isDirectory: true)
            .appendingPathComponent("avp_sess_\(Int64(Date().timeIntervalSince1970 * 1000))", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableDir = dir
            try? mutableDir.setResourceValues(values)
            spillDir = dir
            debugLog("[TS-REMUX] rewind spill dir ready (window \(Int(rewindWindowSeconds))s): \(dir.lastPathComponent)")
        } catch {
            // No disk window: degrade to the classic 6-segment live edge.
            spillDir = nil
            debugLog("[TS-REMUX] rewind spill dir FAILED (\(error)); classic live window only")
        }
    }

    /// `completion` runs on the main queue AFTER every teardown step has
    /// executed on the serial queue. The channel-flip path waits on it so
    /// the outgoing upstream is genuinely released before the incoming one
    /// is opened (review 2026-09-11 section 2 proposal 2: session.txt:3497
    /// shows the new ingest starting BEFORE `stopped (ingested 205 MB)`).
    func stop(completion: (@Sendable () -> Void)? = nil) {
        // Synchronous: a new ingest to this channel started right after
        // this call waits for our cancel instead of overlapping it.
        connLock.lock(); stopRequested = true; let closingID = connID; connLock.unlock()
        LiveConnectionRegistry.shared.markClosing(closingID)
        queue.async { [weak self] in
            guard let self else {
                if let completion { DispatchQueue.main.async(execute: completion) }
                return
            }
            defer { if let completion { DispatchQueue.main.async(execute: completion) } }
            self.stopped = true
            NetworkPathLog.shared.removeObserver(self.pathObserver)
            self.pathObserver = nil
            self.ingestTask?.cancel()
            self.urlSession?.invalidateAndCancel()
            self.releaseConnection()
            self.listener?.cancel()
            self.stopLANDeliveryLocked()
            self.stopAACVariantLocked()
            HLSResourceLoaderRegistry.shared.unregister(id: self.deliveryID)
            self.deliveryBase64.removeAll()
            self.segments.removeAll()
            self.currentSegment.removeAll()
            self.lanWindowSeconds.set(0)
            self.lanWindowSegments.set(0)
            // Assign a fresh Data rather than removeAll(): the latter keeps
            // the backing allocation, so a stopped-but-still-retained remuxer
            // would hold its whole dead buffer (Apple #74).
            self.pending = Data()
            self.spilled.removeAll()
            if let dir = self.spillDir {
                try? FileManager.default.removeItem(at: dir)
                self.spillDir = nil
            }
            debugLog("[TS-REMUX] stopped (ingested \(self.totalBytesIngested / 1_048_576) MB)")
        }
    }

    private func fail(_ error: RemuxError) {
        guard !errorSignaled else { return }
        errorSignaled = true
        debugLog("[TS-REMUX] ERROR: \(error)")
        DispatchQueue.main.async { [weak self] in self?.onError?(error) }
    }

    // MARK: Ingest

    private func releaseConnection() {
        connLock.lock(); let id = connID; connID = nil; connLock.unlock()
        LiveConnectionRegistry.shared.close(id)
    }

    private func startIngest() {
        // Single-connection invariant: a previous ingest to this channel
        // that is being cancelled (warm prewarm dropped, re-tune after an
        // upstream close) must be gone before this one opens.
        LiveConnectionRegistry.shared.waitForClosing(sourceURL, timeout: 3)
        connLock.lock(); let abandoned = stopRequested; connLock.unlock()
        guard !stopped, !abandoned else { return }
        let config = URLSessionConfiguration.default
        // First-bytes patience (Freyguy, 2026-09-03): a Dispatcharr behind a
        // slow provider can take 20-30 s to deliver the first TS bytes; at
        // 15 s the ingest timed out three times in a row and the user saw
        // "Preparing" then an error while Dispatcharr Stats showed the
        // stream. Honour the Network Timeout setting with a 30 s floor.
        let userTimeout = UserDefaults.standard.double(forKey: "networkTimeout")
        config.timeoutIntervalForRequest = max(30, userTimeout > 0 ? userTimeout : 15)
        // A live stream never "completes"; rely on data flow.
        config.timeoutIntervalForResource = .infinity
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        urlSession = session
        var request = URLRequest(url: sourceURL)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let task = session.dataTask(with: request)
        ingestTask = task
        releaseConnection()
        let newConnID = LiveConnectionRegistry.shared.open(sourceURL, owner: "ts-remux#\(deliveryID.prefix(6))")
        connLock.lock(); connID = newConnID; connLock.unlock()
        ingestStartedAt = Date()
        firstByteLogged = false
        firstByteLock.lock(); lastByteAt = nil; firstByteLock.unlock()
        closeReported = false
        queue.async { [weak self] in
            self?.silenceReported = false
            self?.scheduleSilenceCheck()
        }
        task.resume()
        TuneTimeline.shared.mark("ingest")
        // New ingest, new window: without this the first closure of a flip
        // measures its gap against the PREVIOUS channel's last segment and
        // poisons worstGap for the next 30 s.
        Self.feedRateWindow.reset()
        debugLog("[TS-REMUX] ingest started (headers: \(headers.keys.sorted().joined(separator: ",")))")
        logIngestNetworkPolicy(config)
    }

    // MARK: Ingest network policy (device log 2026-09-25 17:04)

    private var pathObserver: UUID?

    /// The ingest URLSession is `.default`: cellular, expensive and
    /// constrained access allowed, no waitsForConnectivity, no multipath.
    /// Behavior unchanged; the policy and the current path are logged at
    /// ingest start, and every path change while this ingest runs is
    /// logged, loudly when it leaves Wi-Fi / wired while an AirPlay
    /// receiver is on the route (Wi-Fi Assist moving the ingest to
    /// cellular while the TV stays on Wi-Fi).
    private func logIngestNetworkPolicy(_ config: URLSessionConfiguration) {
        let airPlay = HLSDelivery.airPlayRouteActive
        #if os(iOS)
        let multipath = "\(config.multipathServiceType.rawValue)"
        #else
        let multipath = "n/a"
        #endif
        debugLog("[TS-REMUX] ingest network policy: allowsCellular=\(config.allowsCellularAccess) "
            + "allowsExpensive=\(config.allowsExpensiveNetworkAccess) "
            + "allowsConstrained=\(config.allowsConstrainedNetworkAccess) "
            + "waitsForConnectivity=\(config.waitsForConnectivity) "
            + "multipath=\(multipath) airPlayRoute=\(airPlay); "
            + NetworkPathLog.shared.currentWithPower)
        NetworkPathLog.shared.removeObserver(pathObserver)
        pathObserver = NetworkPathLog.shared.addObserver { [weak self] text in
            guard let self else { return }
            self.queue.async {
                guard !self.stopped else { return }
                let receiver = self.lanListener != nil || HLSDelivery.airPlayRouteActive
                let offLAN = !text.contains("via wifi") && !text.contains("via wired")
                if receiver, offLAN {
                    debugLog("[TS-REMUX] ingest path changed while an AirPlay receiver is served: \(text); "
                        + "the ingest may now ride cellular (Wi-Fi Assist) while the receiver stays on Wi-Fi")
                } else {
                    debugLog("[TS-REMUX] ingest path changed: \(text)")
                }
            }
        }
    }

    // MARK: Ingest silence poll (live "Reconnecting" signal)

    /// Self-rescheduling 0.5 s poll on the remuxer's own queue. Cheap
    /// (one Date compare) and it dies with the remuxer, so no timer
    /// outlives a teardown.
    private func scheduleSilenceCheck() {
        guard reportsIngestStall, !stopped, !errorSignaled else { return }
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !self.stopped, !self.errorSignaled else { return }
            self.checkIngestSilence()
            self.scheduleSilenceCheck()
        }
    }

    private func checkIngestSilence() {
        firstByteLock.lock()
        let last = lastByteAt
        firstByteLock.unlock()
        // Nothing has arrived yet: the first-byte deadline owns that window.
        guard let last else { return }
        let gap = Date().timeIntervalSince(last)
        let silent = gap >= Self.ingestSilenceThreshold
        guard silent != silenceReported else { return }
        silenceReported = silent
        if silent {
            debugLog("[TS-REMUX] ingest silent for \(String(format: "%.1f", gap))s (>= \(Int(Self.ingestSilenceThreshold))s); reporting stall")
        } else {
            debugLog("[TS-REMUX] ingest bytes resumed; clearing stall")
        }
        DispatchQueue.main.async { [weak self] in self?.onIngestSilence?(silent) }
    }

    // MARK: TS packet walk

    private func consume(_ data: Data) {
        guard !stopped, !errorSignaled else { return }
        totalBytesIngested += data.count
        if let fmp4 {
            // HEVC arm: the sub-remuxer does its own sync/PSI/PES walk.
            // It re-acquires PAT/PMT from their in-stream repetition, so
            // the partial chunk consumed before the switch costs nothing.
            fmp4.feed(data)
            return
        }
        // AirPlay airplay-aac variant: the same bytes, in ingest order, on
        // the variant's own queue. No second upstream connection.
        airPlayVariant?.feed(data)
        pending.append(data)

        // Resync to 0x47 if alignment was lost (provider hiccup).
        while pending.count >= 188 {
            if pending[pending.startIndex] != 0x47 {
                if let sync = pending.firstIndex(of: 0x47) {
                    pending.removeSubrange(pending.startIndex..<sync)
                    continue
                } else {
                    pending.removeAll()
                    break
                }
            }
            // Require the NEXT packet to also start with 0x47 (or be the
            // tail) so a stray 0x47 inside payload does not fake a sync.
            if pending.count >= 189, pending[pending.index(pending.startIndex, offsetBy: 188)] != 0x47 {
                pending.removeFirst(1)
                continue
            }
            let packet = pending.prefix(188)
            pending.removeFirst(188)
            handlePacket(Data(packet))
        }

        // Apple #74. Foundation's Data is a __DataStorage reference plus a
        // Range, and removeFirst/removeSubrange at the FRONT only advance the
        // range's lower bound: the tail is never memmoved down and the
        // allocation is never compacted, while append keeps extending the far
        // end. So this buffer retains EVERY byte ever ingested and stays
        // dirty-resident until the remuxer deallocates, even though
        // `pending.count` reads back under 188 on every pass and the
        // "buffered N" segment counter stays honestly pinned at 10. Nothing
        // the app logs could see it.
        //
        // Measured against this exact loop: 218 MB ingested cost +220.1 MB of
        // phys_footprint (1.0096 bytes resident per byte in) with startIndex
        // equal to the total consumed; re-seating holds it at +0.1 MB for the
        // same input and the same packet count. That 1:1 slope is what walked
        // ochaos's Apple TV from ~450 MB to the ~2 GB jetsam ceiling in under
        // an hour on a single channel, and why time-to-crash tracked the
        // channel's bitrate rather than anything the user did.
        //
        // The surviving tail is at most one TS packet, so the copy is free.
        // Placed after the loop so it also covers the `break` out of the
        // resync path above.
        pending = pending.isEmpty ? Data() : Data(pending)
    }

    private func handlePacket(_ p: Data) {
        guard p.count == 188 else { return }
        var p = p
        let pid = (Int(p[1] & 0x1F) << 8) | Int(p[2])
        let pusi = (p[1] & 0x40) != 0

        // Catch-up (event) streams from the archive carry MALFORMED
        // IDR access units: the mux orders them SPS,PPS,AUD,SEI,slice -
        // the AUD sits mid-AU instead of leading it. ffmpeg/mpv shrug;
        // VideoToolbox's AU assembler REFUSES the track (AVFoundation
        // 'Cannot Open' -12430; on HLS the symptom was ~10s of audio
        // before any video). Non-IDR AUs are already conformant
        // (AUD,SEI,slice). Fix = length-preserving byte ROTATION inside
        // the packet: move the AUD block in front of the SPS. Bench-
        // verified: first video frame went from pos 10.3s to 0.00s.
        // Gated to eventPlaylist so the proven live path is untouched,
        // and to PES-start packets: the malformed pattern only occurs at
        // IDR AU starts, which begin a PES - scanning EVERY video packet
        // (~86k/s at line rate) fell behind ingest and ballooned the
        // pending buffer past 1GB (field 2026-08-28: stall at 5s,
        // fp=1061MB, playlist stopped growing).
        if eventPlaylist, pid == videoPID, pusi {
            fixAUDOrder(&p)
        }

        // PSI is watched for the whole session, not just until the first
        // program is found: Switch Stream swaps the source on this same
        // connection and the new mux can carry a different program.
        if pid == 0 {
            parsePAT(p, pusi: pusi)
        } else if pid == pmtPID {
            parsePMT(p, pusi: pusi)
        }

        guard codecGatePassed else { return }

        if pid == videoPID { noteVideoContinuity(p) }

        // Keyframe-aligned cuts: only video PES starts can open segments.
        if pid == videoPID, pusi {
            if let pts = extractPTS(p) {
                if !videoParamsSent {
                    // FIRST choice: the stream's OWN declared cadence from
                    // the SPS VUI timing info. A measured rate is perturbed
                    // by genpts / nobuffer / discontinuity handling and read
                    // 32fps on a 59.94 feed (Logan 2026-09-11), so the
                    // declaration wins whenever the SPS carries one.
                    if let sps = firstSPSNAL(p), let info = H264SPSTiming.parse(sps) {
                        videoParamsSent = true
                        debugLog("[TS-REMUX] video: declared \(String(format: "%.2f", info.fps))fps \(info.isInterlaced ? "interlaced" : "progressive") (H.264 SPS VUI)")
                        let cb = onVideoParameters
                        let declaredFPS = info.fps
                        let interlaced = info.isInterlaced
                        DispatchQueue.main.async {
                            RemuxMeasuredVideo.shared.note(fps: declaredFPS, declared: true,
                                                           interlaced: interlaced)
                            cb?(0, 0, declaredFPS, false)
                        }
                    }
                }
                if !videoParamsSent {
                    if lastVideoAUPTS >= 0 {
                        let d = pts - lastVideoAUPTS
                        if d > 0.005, d < 0.1 { videoPTSDeltas.append(d) }
                    }
                    lastVideoAUPTS = pts
                    // 240 access units (4-10s of video), not 60: a short
                    // window over a feed that is still settling is exactly
                    // what produced the bogus 32fps. Deltas further than 3x
                    // from the median are discontinuities and are dropped
                    // before the median is taken again.
                    if videoPTSDeltas.count >= 240 {
                        videoParamsSent = true
                        let sorted = videoPTSDeltas.sorted()
                        let rough = sorted[sorted.count / 2]
                        let kept = sorted.filter { $0 <= rough * 3 && $0 >= rough / 3 }
                        let median = kept.isEmpty ? rough : kept[kept.count / 2]
                        var fps = median > 0 ? 1.0 / median : 0
                        // Snap to the nearest broadcast rate within 1%.
                        fps = VideoRateStandards.snap(fps)
                        if fps >= 23, fps <= 61 {
                            debugLog("[TS-REMUX] video: measured \(String(format: "%.2f", fps))fps over \(videoPTSDeltas.count) AUs (H.264 arm, no SPS timing)")
                            let cb = onVideoParameters
                            DispatchQueue.main.async { cb?(0, 0, fps, false) }
                        } else {
                            debugLog("[TS-REMUX] video: measured \(String(format: "%.2f", fps))fps implausible; NOT driving display criteria")
                        }
                    }
                }
                let isKeyframe = packetStartsKeyframeAccessUnit(p)
                let sps = isKeyframe ? firstSPSNAL(p) : nil
                if !awaitingFirstKeyframe,
                   let reason = sourceChangeReason(pts: pts, sps: sps) {
                    beginSourceSwitch(reason: reason)
                }
                if let sps { lastSPS = sps }
                lastSeenVideoPTS = pts
                if awaitingSwitchKeyframe {
                    // Only an IDR access unit that carries its own SPS (and
                    // so its PPS) may open the first segment of the new
                    // source: anything earlier references parameter sets
                    // the decoder has not seen and renders as garbage.
                    let nals = leadingNALTypes(p, limit: 16)
                    if isKeyframe, nals.contains(7) {
                        awaitingSwitchKeyframe = false
                        awaitingFirstKeyframe = false
                        setRegatingShared(false)
                        // Segment 0 has nothing before it to be discontinuous with.
                        nextSegmentDiscontinuity = nextSeq > 0
                        beginSegment(at: pts)
                        currentSegmentLeadNALs = nals
                        var spsDesc = ""
                        if let sps, let info = H264SPSTiming.parse(sps) {
                            spsDesc = String(format: ", SPS %.2ffps %@", info.fps,
                                             info.isInterlaced ? "interlaced" : "progressive")
                        }
                        debugLog("[TS-REMUX] switch: new source IDR+SPS at pts \(String(format: "%.3f", pts)) lead=\(nals)\(spsDesc); segment \(nextSeq) tagged EXT-X-DISCONTINUITY")
                    }
                } else if awaitingFirstKeyframe {
                    if isKeyframe {
                        awaitingFirstKeyframe = false
                        beginSegment(at: pts)
                        if nextSeq < 12 { currentSegmentLeadNALs = leadingNALTypes(p) }
                    }
                } else if isKeyframe,
                          let start = currentStartPTS {
                    var elapsed = pts - start
                    let cutAt = nextSeq < startupRampSegments
                        ? startupSegmentSeconds : targetSegmentSeconds
                    // 33-bit PTS wrap (~26.5h) or discontinuity: cut here.
                    if elapsed < 0 { elapsed = cutAt }
                    if elapsed >= cutAt {
                        closeSegment(endPTS: pts)
                        beginSegment(at: pts)
                        if nextSeq < 12 { currentSegmentLeadNALs = leadingNALTypes(p) }
                    }
                }
            }
        }

        guard !awaitingFirstKeyframe else { return }

        // Audio rides a hold buffer so a whole PES always lands in one
        // segment (rationale at the heldAudio declaration).
        if audioPIDs.contains(pid) {
            if pusi {
                flushHeldAudio()
                heldAudio = [p]
            } else if !heldAudio.isEmpty {
                heldAudio.append(p)
                // Never withhold unboundedly: a PES start we missed or a
                // corrupt length would otherwise park audio forever.
                if heldAudio.count >= heldAudioPacketCap { flushHeldAudio() }
            } else {
                // Continuation of a PES that started before this segment
                // opened (or before the PMT was read): pass it through.
                currentSegment.append(p)
            }
            return
        }

        currentSegment.append(p)
    }

    // MARK: Source switch detection

    /// Continuity bookkeeping on the video PID. A counter that skips, or
    /// an adaptation-field discontinuity_indicator, is recorded with its
    /// wall time; on its own it is ordinary packet loss, but together
    /// with a changed SPS it marks a new source.
    private func noteVideoContinuity(_ p: Data) {
        let afc = (p[3] >> 4) & 0x03
        if (afc & 0x02) != 0, p[4] > 0, (p[5] & 0x80) != 0 {
            lastVideoCCBreakAt = Date()
        }
        guard (afc & 0x01) != 0 else { return }
        let cc = Int(p[3] & 0x0F)
        if lastVideoCC >= 0, cc != lastVideoCC, cc != (lastVideoCC + 1) & 0x0F {
            lastVideoCCBreakAt = Date()
        }
        lastVideoCC = cc
    }

    /// Why this video PES start begins a new source, or nil. Two shapes:
    /// a PTS jump far beyond reordering or jitter (never the 33-bit wrap),
    /// or a changed SPS together with a recent continuity break (or with
    /// a change_stream the tile has just confirmed).
    private func sourceChangeReason(pts: Double, sps: [UInt8]?) -> String? {
        if lastSeenVideoPTS >= 0 {
            let delta = pts - lastSeenVideoPTS
            let wrap = 8_589_934_592.0 / 90_000.0
            let wrapped = lastSeenVideoPTS > wrap - 60 && pts < 60
            if !wrapped, delta > switchPTSJumpForward || delta < -switchPTSJumpBackward {
                return String(format: "PTS jump %+.3fs (%.3f -> %.3f)", delta, lastSeenVideoPTS, pts)
            }
        }
        if let sps, let previous = lastSPS, spsDiffers(previous, sps) {
            let now = Date()
            let ccBreak = now.timeIntervalSince(lastVideoCCBreakAt) < 3
            let expected = now < switchExpectedUntil
            if ccBreak || expected {
                return "SPS changed (\(ccBreak ? "continuity break" : "change_stream noted"))"
            }
        }
        return nil
    }

    /// Compare the leading bytes of two SPS NALs. The extracted slices can
    /// be cut short by the TS packet end, so only the common prefix counts
    /// (profile, level, ids and the picture size live in it).
    private func spsDiffers(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        let n = min(16, min(a.count, b.count) - 1)
        guard n >= 4 else { return false }
        return a[0..<n] != b[0..<n]
    }

    /// Close whatever the old source left open and wait for the new
    /// source's first IDR with an SPS. The connection is never touched.
    private func beginSourceSwitch(reason: String) {
        debugLog("[TS-REMUX] switch: source change detected (\(reason)); closing seg \(nextSeq) and waiting for the new source's IDR+SPS")
        Self.lastSourceSwitch.set(Date())
        setRegatingShared(true)
        switchAccountingSuppressed = true
        switchQuietClosures = 0
        if !currentSegment.isEmpty, let start = currentStartPTS {
            flushHeldAudio()
            // End on the old source's own clock: one frame past its last
            // video PES (the new source's PTS says nothing about it).
            let frame = videoPTSDeltas.isEmpty ? 1.0 / 30.0
                : videoPTSDeltas.sorted()[videoPTSDeltas.count / 2]
            let end = lastSeenVideoPTS >= start ? lastSeenVideoPTS + frame : start + targetSegmentSeconds
            closeSegment(endPTS: end)
        }
        heldAudio.removeAll(keepingCapacity: true)
        currentSegment = Data()
        currentStartPTS = nil
        awaitingFirstKeyframe = true
        awaitingSwitchKeyframe = true
        lastSeenVideoPTS = -1
        lastVideoAUPTS = -1
        lastAudioPESPTS = -1
        lastAudioPESFrames = 0
    }

    /// Append the completed audio PES to the open segment and read its
    /// ADTS telemetry on the way past.
    private func flushHeldAudio() {
        guard !heldAudio.isEmpty else { return }
        inspectAudioPES(heldAudio)
        for packet in heldAudio { currentSegment.append(packet) }
        heldAudio.removeAll(keepingCapacity: true)
    }

    /// One-time AAC shape line plus a continuity check on audio PES
    /// timestamps. Reads only; the bytes go out untouched.
    private func inspectAudioPES(_ packets: [Data]) {
        guard audioStreamType == 0x0F, let first = packets.first else { return }
        var es = [UInt8]()
        es.reserveCapacity(packets.count * 184)
        for (index, packet) in packets.enumerated() {
            guard var off = payloadStart(packet) else { continue }
            if index == 0 {
                guard off + 8 < 188,
                      packet[off] == 0x00, packet[off + 1] == 0x00, packet[off + 2] == 0x01
                else { return }
                off += 9 + Int(packet[off + 8])
                guard off < 188 else { return }
            }
            es.append(contentsOf: packet[off..<188])
        }

        var frames = 0
        var profile = 0
        var rate = 0
        var channels = 0
        var i = 0
        while i + 7 <= es.count {
            guard es[i] == 0xFF, (es[i + 1] & 0xF0) == 0xF0 else { i += 1; continue }
            let frameLen = (Int(es[i + 3] & 0x03) << 11)
                | (Int(es[i + 4]) << 3)
                | (Int(es[i + 5]) >> 5)
            guard frameLen > 7, es.count - i >= frameLen else { break }
            if frames == 0 {
                profile = (Int(es[i + 2]) >> 6) + 1
                let freqIndex = (Int(es[i + 2]) >> 2) & 0x0F
                let rates = [96000, 88200, 64000, 48000, 44100, 32000,
                             24000, 22050, 16000, 12000, 11025, 8000, 7350]
                rate = freqIndex < rates.count ? rates[freqIndex] : 0
                channels = ((Int(es[i + 2]) & 0x01) << 2) | (Int(es[i + 3]) >> 6)
            }
            frames += 1
            i += frameLen
        }
        guard frames > 0, rate > 0 else { return }

        if !adtsLogged {
            adtsLogged = true
            adtsSampleRate = rate
            debugLog("[TS-REMUX] AAC: profile=\(profile) sr=\(rate) ch=\(channels) frames/PES=\(frames)")
        }

        // Consecutive PES timestamps must advance by exactly the frames
        // the previous PES carried. A bigger step is missing audio (the
        // symptom that sent us here); a smaller one is an overlap.
        if let pts = extractPTS(first) {
            let frameSeconds = 1024.0 / Double(rate)
            if lastAudioPESPTS >= 0, lastAudioPESFrames > 0 {
                let expected = Double(lastAudioPESFrames) * frameSeconds
                let drift = pts - lastAudioPESPTS - expected
                if abs(drift) > frameSeconds, abs(drift) < 10 {
                    audioGapWarnings += 1
                    let now = Date()
                    if now.timeIntervalSince(lastAudioGapLogAt) > 10 {
                        lastAudioGapLogAt = now
                        debugLog(String(format:
                            "[TS-REMUX] WARNING audio PTS gap %+.0f ms (%.1f frames) at pts %.3f, %d so far",
                            drift * 1000, drift / frameSeconds, pts, audioGapWarnings))
                    }
                }
            }
            lastAudioPESPTS = pts
            lastAudioPESFrames = frames
        }
    }

    /// Rotate a malformed IDR AU's AUD in front of its SPS/PPS, in
    /// place (details at the call site). Both NALs must sit in the same
    /// TS packet - true in practice: the mux emits SPS,PPS,AUD
    /// adjacently at each PES start. A straddling case is skipped
    /// (that one AU stays malformed; VT tolerates isolated ones once
    /// the stream has opened).
    private func fixAUDOrder(_ p: inout Data) {
        guard let off = payloadStart(p), off < p.count else { return }
        var bytes = [UInt8](p)
        func find(_ pattern: [UInt8], from: Int) -> Int? {
            guard bytes.count >= pattern.count, from >= 0 else { return nil }
            var i = from
            while i <= bytes.count - pattern.count {
                if bytes[i] == pattern[0], bytes[i+1] == pattern[1],
                   bytes[i+2] == pattern[2], bytes[i+3] == pattern[3] { return i }
                i += 1
            }
            return nil
        }
        guard let sps = find([0, 0, 1, 0x67], from: off),
              let aud = find([0, 0, 1, 0x09], from: sps + 4) else { return }
        let aStart = (aud > off && bytes[aud - 1] == 0) ? aud - 1 : aud
        let aLen = (aud - aStart) + 5   // startcode(3|4) + type + payload byte
        guard aStart + aLen <= bytes.count else { return }
        let sStart = (sps > off && bytes[sps - 1] == 0) ? sps - 1 : sps
        let audBlock = Array(bytes[aStart..<(aStart + aLen)])
        let midBlock = Array(bytes[sStart..<aStart])
        bytes.replaceSubrange(sStart..<(aStart + aLen), with: audBlock + midBlock)
        p = Data(bytes)
    }

    // MARK: PSI parsing

    private func payloadStart(_ p: Data) -> Int? {
        let afc = (p[3] >> 4) & 0x03
        switch afc {
        case 0x01: return 4                              // payload only
        case 0x03:
            let afLen = Int(p[4])
            let start = 5 + afLen
            return start < 188 ? start : nil             // adaptation + payload
        default: return nil                              // no payload
        }
    }

    private func parsePAT(_ p: Data, pusi: Bool) {
        guard pusi, let base = payloadStart(p), base + 1 < 188 else { return }
        let pointer = Int(p[base])
        let section = base + 1 + pointer
        // table_id 0x00 only: anything else on PID 0 is not a PAT.
        guard section + 8 < 188, p[section] == 0x00 else { return }
        // table_id(1) section_length(2) tsid(2) ver(1) sec(1) last(1) = 8,
        // then program entries of 4 bytes each.
        var offset = section + 8
        while offset + 3 < 188 {
            let programNumber = (Int(p[offset]) << 8) | Int(p[offset + 1])
            let pidValue = (Int(p[offset + 2] & 0x1F) << 8) | Int(p[offset + 3])
            if programNumber != 0 {
                if pmtPID < 0 {
                    pmtPID = pidValue
                    patPacket = p
                    TuneTimeline.shared.mark("PAT")
                    debugLog("[TS-REMUX] PAT: program \(programNumber) -> PMT PID \(pmtPID)")
                } else if pidValue != pmtPID {
                    // Switch Stream: a new mux on the same connection.
                    debugLog("[TS-REMUX] switch: PAT changed, program \(programNumber) -> PMT PID \(pmtPID) -> \(pidValue); re-running the codec gate")
                    if codecGatePassed, fmp4 == nil { beginSourceSwitch(reason: "PAT PMT PID \(pmtPID) -> \(pidValue)") }
                    resetProgramState()
                    pmtPID = pidValue
                    patPacket = p
                } else {
                    patPacket = p
                }
                return
            }
            offset += 4
        }
    }

    /// Forget the program so the next PMT runs the codec gate afresh.
    /// Segments already stored, the playlist, pacing and the connection
    /// all stay; only the demux's view of the program is dropped.
    private func resetProgramState() {
        videoPID = -1
        pmtPacket = nil
        pmtSignature = ""
        codecGatePassed = false
        audioPIDs.removeAll()
        audioStreamType = 0
        setSourceAudioStreamType(0)
        lastVideoCC = -1
        lastSPS = nil
        adtsLogged = false
        setRegatingShared(true)
    }

    private func parsePMT(_ p: Data, pusi: Bool) {
        guard pusi, let base = payloadStart(p), base + 1 < 188 else { return }
        let pointer = Int(p[base])
        let section = base + 1 + pointer
        guard section + 12 < 188, p[section] == 0x02 else { return }
        let sectionLength = (Int(p[section + 1] & 0x0F) << 8) | Int(p[section + 2])
        let programInfoLength = (Int(p[section + 10] & 0x0F) << 8) | Int(p[section + 11])
        var offset = section + 12 + programInfoLength
        let sectionEnd = min(section + 3 + sectionLength - 4, 187) // minus CRC32

        var foundVideo: (pid: Int, type: UInt8)?
        var audioTypes: [UInt8] = []
        var foundAudioPIDs = Set<Int>()
        var audioPairs: [String] = []

        while offset + 4 < sectionEnd {
            let streamType = p[offset]
            let esPID = (Int(p[offset + 1] & 0x1F) << 8) | Int(p[offset + 2])
            let esInfoLength = (Int(p[offset + 3] & 0x0F) << 8) | Int(p[offset + 4])
            switch streamType {
            case 0x1B, 0x24, 0x01, 0x02:           // H.264 / HEVC / MPEG-1/2 video
                if foundVideo == nil { foundVideo = (esPID, streamType) }
            case 0x81, 0x87, 0x0F, 0x03, 0x04, 0x11: // AC-3 / E-AC-3 / AAC / MP2 / LATM
                audioTypes.append(streamType)
                foundAudioPIDs.insert(esPID)
                audioPairs.append("\(esPID):\(streamType)")
            default:
                break
            }
            offset += 5 + esInfoLength
        }

        guard let video = foundVideo else { return }
        let signature = "v\(video.pid):\(video.type) a" + audioPairs.sorted().joined(separator: ",")

        if videoPID >= 0 {
            // Program already gated. Same content: just refresh the cached
            // PMT the segments lead with. Different content: a new source.
            if signature == pmtSignature {
                pmtPacket = p
                return
            }
            // The HEVC arm owns its own demux; a mid-stream change there is
            // its sub-remuxer's to handle.
            guard fmp4 == nil else { return }
            debugLog("[TS-REMUX] switch: PMT changed [\(pmtSignature)] -> [\(signature)]; re-running the codec gate")
            if codecGatePassed { beginSourceSwitch(reason: "PMT content changed") }
            resetProgramState()
        }
        videoPID = video.pid
        pmtPacket = p
        pmtSignature = signature

        // The codec gate, per Apple's HLS authoring rules. H.264 stays on
        // the TS passthrough below; HEVC switches to the fMP4 arm (rule
        // 1.5); MPEG-2 has no decoder on this platform at all.
        if video.type == 0x24 {
            if nextSeq > 0 {
                // A TS playlist cannot turn into an fMP4 one mid-stream.
                // Report it and let the tile's failure handling decide.
                debugLog("[TS-REMUX] switch: new source is HEVC after \(nextSeq) H.264 segments -> codec gate FAILED")
                fail(.unsupportedCodec("HEVC after Switch Stream"))
                return
            }
            startFMP4Pipeline()
            return
        }
        if video.type != 0x1B {
            fail(.unsupportedCodec("MPEG-2 video"))
            return
        }
        if audioTypes.contains(where: { $0 == 0x03 || $0 == 0x04 }) {
            fail(.unsupportedCodec("MP2 audio"))
            return
        }
        codecGatePassed = true
        audioPIDs = foundAudioPIDs
        audioStreamType = audioTypes.first ?? 0
        setSourceAudioStreamType(audioStreamType)
        let audioDesc = audioTypes.map { String(format: "0x%02X", $0) }.joined(separator: ",")
        debugLog("[TS-REMUX] PMT: H.264 video PID \(videoPID), audio types [\(audioDesc)] -> codec gate PASSED")
    }

    // MARK: PES / NAL inspection

    /// PTS (seconds) from a PES header at the start of this packet's
    /// payload, when present.
    private func extractPTS(_ p: Data) -> Double? {
        guard let base = payloadStart(p), base + 13 < 188 else { return nil }
        // PES start code 00 00 01
        guard p[base] == 0x00, p[base + 1] == 0x00, p[base + 2] == 0x01 else { return nil }
        let flags = p[base + 7]
        guard (flags & 0x80) != 0 else { return nil }    // PTS present
        let b0 = UInt64(p[base + 9]), b1 = UInt64(p[base + 10]), b2 = UInt64(p[base + 11])
        let b3 = UInt64(p[base + 12]), b4 = UInt64(p[base + 13])
        let pts: UInt64 = ((b0 >> 1) & 0x07) << 30
            | b1 << 22
            | ((b2 >> 1) & 0x7F) << 15
            | b3 << 7
            | (b4 >> 1)
        return Double(pts) / 90_000.0
    }

    /// Does this PUSI packet's payload open a keyframe access unit? Scans
    /// the visible NAL start codes for SPS (7) or IDR (5); encoders emit
    /// SPS/PPS immediately before each IDR, so SPS in the first packet is
    /// a reliable keyframe marker even when the IDR NAL itself starts in
    /// a later packet of the same PES.
    private func packetStartsKeyframeAccessUnit(_ p: Data) -> Bool {
        guard let base = payloadStart(p), base + 9 < 188 else { return false }
        let headerLen = Int(p[base + 8])
        var i = base + 9 + headerLen
        let end = 188 - 4
        while i < end {
            if p[i] == 0x00, p[i + 1] == 0x00 {
                var nalStart = -1
                if p[i + 2] == 0x01 { nalStart = i + 3 }
                else if p[i + 2] == 0x00, i + 3 < end, p[i + 3] == 0x01 { nalStart = i + 4 }
                if nalStart > 0, nalStart < 188 {
                    let nalType = p[nalStart] & 0x1F
                    if nalType == 5 || nalType == 7 { return true }
                    i = nalStart
                    continue
                }
            }
            i += 1
        }
        return false
    }

    // MARK: Segmenter

    private func beginSegment(at pts: Double) {
        currentSegment = Data()
        // Every segment must lead with PAT + PMT so a client can join at
        // any segment. The cached packets carry stale continuity counters;
        // AVPlayer tolerates that on PSI PIDs.
        if let pat = patPacket { currentSegment.append(pat) }
        if let pmt = pmtPacket { currentSegment.append(pmt) }
        // heldAudio is deliberately NOT flushed here: an audio PES still
        // in flight when the cut landed belongs whole to THIS segment,
        // and flushes into it as soon as its last packet arrives.
        currentStartPTS = pts
    }

    /// Switch this remuxer into fMP4 mode for an HEVC mux. Storage,
    /// playlist window, READY gating, ramp, spill and jitter telemetry
    /// are all shared with the TS arm; only production differs.
    private func startFMP4Pipeline() {
        guard fmp4 == nil else { return }
        let mux = LiveFMP4Remuxer(
            targetSegmentSeconds: targetSegmentSeconds,
            rampSegmentSeconds: startupSegmentSeconds,
            rampSegments: startupRampSegments,
            log: { debugLog("[TS-REMUX] \($0)") })
        mux.onPMT = { desc in
            debugLog("[TS-REMUX] PMT: \(desc) -> fMP4 arm ENGAGED")
        }
        mux.onInitSegment = { [weak self] data in
            self?.fmp4InitSegment = data
        }
        mux.onMediaSegment = { [weak self] data, duration in
            self?.storeSegment(data: data, duration: duration)
        }
        mux.onError = { [weak self] error in
            self?.fail(.unsupportedCodec(error.codecName))
        }
        mux.onVideoParameters = { [weak self] w, h, fps, tenBit in
            let cb = self?.onVideoParameters
            DispatchQueue.main.async {
                // The remuxer MEASURES the cadence off frame timestamps.
                // fMP4 built here carries no nominal frame rate, so the
                // AVPlayer driver has nothing else to report until frames
                // render; park it where the driver can pick it up
                // (Logan 2026-09-11: badge showed a resolution and no fps).
                RemuxMeasuredVideo.shared.note(fps: VideoRateStandards.snap(fps))
                cb?(w, h, fps, tenBit)
            }
        }
        fmp4 = mux
        codecGatePassed = true
        // Bytes already sitting in the TS arm's buffer belong to the new
        // arm; hand them over before the next network chunk arrives.
        if !pending.isEmpty {
            mux.feed(Data(pending))
            pending.removeAll()
        }
    }

    private func closeSegment(endPTS: Double) {
        guard let start = currentStartPTS, !currentSegment.isEmpty else { return }
        var duration = endPTS - start
        if duration <= 0 || duration > 10 { duration = targetSegmentSeconds }
        if nextSeq < 12 {
            // Startup detail for the next unexplained "never became ready"
            // (2026-09-09): where each early segment starts, how long it
            // really is, and what its first video access unit opens with.
            debugLog("[TS-REMUX] seg \(nextSeq) start=\(String(format: "%.3f", start)) end=\(String(format: "%.3f", endPTS)) dur=\(String(format: "%.3f", duration)) bytes=\(currentSegment.count) lead=\(currentSegmentLeadNALs)")
        }
        storeSegment(data: currentSegment, duration: duration)
    }

    /// NAL types (in order) of the first video PES in the open segment,
    /// captured when the segment begins. Logging only.
    private var currentSegmentLeadNALs: [Int] = []

    /// The first SPS (NAL type 7) inside this 188-byte packet's PES
    /// payload, start code stripped. Nil when the packet carries none, or
    /// when the SPS continues into the next packet - the caller simply
    /// tries again on the next PES start rather than reassembling.
    private func firstSPSNAL(_ p: Data) -> [UInt8]? {
        guard let base = payloadStart(p), base + 9 < 188 else { return nil }
        var i = base + 9 + Int(p[base + 8])
        let end = 188 - 4
        while i < end {
            if p[i] == 0x00, p[i + 1] == 0x00 {
                var nalStart = -1
                if p[i + 2] == 0x01 { nalStart = i + 3 }
                else if p[i + 2] == 0x00, i + 3 < end, p[i + 3] == 0x01 { nalStart = i + 4 }
                if nalStart > 0, nalStart < 188 {
                    if (p[nalStart] & 0x1F) == 7 {
                        // Run to the next start code, or the packet end.
                        var j = nalStart + 1
                        while j < 188 - 3 {
                            if p[j] == 0x00, p[j + 1] == 0x00,
                               (p[j + 2] == 0x01 || (p[j + 2] == 0x00 && p[j + 3] == 0x01)) {
                                break
                            }
                            j += 1
                        }
                        let slice = Array(p[nalStart..<min(j + 1, 188)])
                        return slice.count > 8 ? slice : nil
                    }
                    i = nalStart
                    continue
                }
            }
            i += 1
        }
        return nil
    }

    private func leadingNALTypes(_ p: Data, limit: Int = 6) -> [Int] {
        guard let base = payloadStart(p), base + 9 < 188 else { return [] }
        var i = base + 9 + Int(p[base + 8])
        var out: [Int] = []
        let end = 188 - 4
        while i < end, out.count < limit {
            if p[i] == 0x00, p[i + 1] == 0x00 {
                var nalStart = -1
                if p[i + 2] == 0x01 { nalStart = i + 3 }
                else if p[i + 2] == 0x00, i + 3 < end, p[i + 3] == 0x01 { nalStart = i + 4 }
                if nalStart > 0, nalStart < 188 {
                    out.append(Int(p[nalStart] & 0x1F))
                    i = nalStart
                    continue
                }
            }
            i += 1
        }
        return out
    }

    /// Shared segment store for BOTH arms (TS passthrough and fMP4):
    /// window buffering, rewind spill, READY gating, and the feed-jitter
    /// telemetry all behave identically regardless of who produced the
    /// bytes.
    private func storeSegment(data: Data, duration: Double) {
        // Upstream delivery jitter telemetry (2026-08-25 capture: 174 of
        // 940 closures arrived >2.6s apart, worst 9.2s, and the two
        // AVPlayer stalls line up with the worst gaps). Wall-clock gap
        // between closures minus the media duration ~= feed starvation.
        let nowWall = Date()
        let isDiscontinuity = nextSegmentDiscontinuity
        nextSegmentDiscontinuity = false
        if isDiscontinuity {
            discontinuitySeqs.insert(nextSeq)
            // The first segment of the new source is live media again:
            // drain whatever the switch left in the paced reservoir back
            // to the normal target for the next 20 s (see advancePacedEdge).
            pacedDrainUntil = nowWall.addingTimeInterval(20)
            Self.lastSourceSwitch.set(nowWall)
        }
        if switchAccountingSuppressed {
            // The switch gap is not upstream jitter: keep it out of the
            // rate window, the worst-gap figure and lastFeedStarvation, or
            // the hold-back learner and the resume gate train on it. The
            // window restarts at the first closure after the new source's
            // first segment, or after three closures when a noted
            // change_stream never showed a detectable change.
            switchQuietClosures = isDiscontinuity ? 0 : switchQuietClosures + 1
            let afterNewSource = !isDiscontinuity && discontinuitySeqs.contains(nextSeq - 1)
            if afterNewSource || (!awaitingSwitchKeyframe && !isDiscontinuity && switchQuietClosures >= 3) {
                switchAccountingSuppressed = false
                Self.feedRateWindow.reset()
                debugLog("[TS-REMUX] switch: feed telemetry restarted after the source change")
            }
            lastSegmentCloseWall = nil
        }
        switchLock.lock()
        if switchNotedAtShared != nil || isDiscontinuity { switchSegmentAtShared = nowWall }
        switchLock.unlock()
        // Rate window first: the driver reads it in the same tick it reads
        // lastFeedStarvation, and needs THIS closure counted.
        if !switchAccountingSuppressed {
            Self.feedRateWindow.record(closeWall: nowWall, mediaDuration: duration)
        }
        if !switchAccountingSuppressed, let lastWall = lastSegmentCloseWall {
            let gap = nowWall.timeIntervalSince(lastWall)
            if gap > duration + 0.6 {
                starvedClosures += 1
                worstClosureGap = max(worstClosureGap, gap)
                recentStarvations.append((wall: nowWall, gap: gap))
                linkLock.lock(); linkStats.starvedClosures += 1; linkLock.unlock()
                // Publish the moment of starvation, not just the 150-segment
                // summary: an AVPlayer stall that lands within a few seconds
                // of an upstream gap must NOT be answered by holding further
                // back from the live edge (2026-09-11, see the holdback note
                // in AVPlayerProgressDriver).
                Self.lastFeedStarvation.set(nowWall)
                if nowWall.timeIntervalSince(lastStarvationLogAt) > 10 {
                    lastStarvationLogAt = nowWall
                    debugLog("[TS-REMUX] feed starved: \(String(format: "%.1f", gap))s wall for a \(String(format: "%.1f", duration))s segment (\(starvedClosures) so far)")
                }
            }
        }
        lastSegmentCloseWall = nowWall
        if nextSeq > 0, nextSeq % 150 == 0 {
            debugLog("[TS-REMUX] feed-jitter: \(starvedClosures) starved closures so far, worst gap \(String(format: "%.1f", worstClosureGap))s")
        }
        segments.append((seq: nextSeq, data: data, duration: duration))
        if lanListener != nil {
            refreshLANHoldBack(now: nowWall)
            updateLANReservoir()
        }
        spillSegment(seq: nextSeq, data: data, duration: duration)
        if inProcessDelivery { deliveryBase64[nextSeq] = data.base64EncodedString() }
        nextSeq += 1
        let ramCap = retainedRAMCap ?? (lanListener != nil ? lanRingSegments : maxBufferedSegments)
        if segments.count > ramCap {
            let evicted = segments.prefix(segments.count - ramCap)
            // Rule 4: the reservoir can hold at most the ring itself. If the
            // ring is about to evict a segment the playlist never showed,
            // advertise it first; the player must never lose a segment it
            // has not seen.
            if let advertised = pacedAdvertisedSeq, let lastEvicted = evicted.last?.seq,
               lastEvicted > advertised {
                pacedAdvertisedSeq = lastEvicted
                pacedNextReleaseAt = Date() + (evicted.last?.duration ?? targetSegmentSeconds)
            }
            segments.removeFirst(segments.count - ramCap)
        }
        if inProcessDelivery, let first = segments.first?.seq {
            for k in deliveryBase64.keys where k >= 0 && k < first { deliveryBase64[k] = nil }
        }
        let lanTail = segments.suffix(lanRingSegments)
        lanWindowSeconds.set(lanTail.reduce(0.0) { $0 + $1.duration })
        lanWindowSegments.set(Double(lanTail.count))
        // nextSeq, not segments.count: the count pins at maxBufferedSegments
        // once the window fills, and 12 % 5 != 0 silenced every close after
        // the first ten seconds of the 2026-08-25 UHD soak.
        if nextSeq == 1 { TuneTimeline.shared.mark("seg0") }
        if isDiscontinuity {
            debugLog("[TS-REMUX] switch: segment \(nextSeq - 1) closed (\(String(format: "%.2f", duration))s, \(data.count / 1024) KB) opens the new source, discontinuity sequence now \(discontinuitySeqs.count)")
        }
        if nextSeq == 1 || nextSeq % 5 == 0 {
            debugLog("[TS-REMUX] segment \(nextSeq - 1) closed (\(String(format: "%.2f", duration))s, \(data.count / 1024) KB), buffered \(segments.count)")
        }
        // READY gate: TWO segments, always. Publishing on a full-length
        // segment 0 alone was tried on 2026-09-11 (78a7fd0) and looped the
        // very first tune: the player started with 2.5 s buffered, the
        // feed delivered segment 1 three seconds later (below realtime at
        // start), the buffer ran empty for 7 s, AVPlayer raised its
        // holdback and answered -12640 "Cannot get that close to live",
        // then jumped back 9 s (session5.txt:489-519). One GOP of start
        // time is not worth that; the gain has to come from upstream.
        if !readySignaled, segments.count >= readyThreshold,
           localPort != 0,
           fmp4 == nil || fmp4InitSegment != nil {
            readySignaled = true
            let url = inProcessDelivery
                ? URL(string: "\(HLSDelivery.scheme)://\(deliveryID)/live.m3u8")!
                : URL(string: "http://127.0.0.1:\(localPort)/live.m3u8")!
            TuneTimeline.shared.mark("remuxReady")
            debugLog("[TS-REMUX] READY on seg\(readyThreshold - 1) -> \(url.absoluteString)")
            debugLog("[TS-REMUX] \(pacingStateDescription)")
            DispatchQueue.main.async { [weak self] in self?.onReady?(url) }
        }
        // Start (or advance) the paced live edge. The first call, in the
        // same closure that declared READY, makes the two READY segments
        // visible at once; every later call releases only what the 1.0x
        // clock allows.
        advancePacedEdge()
    }

    /// Write the closed segment into the rewind spill window, then ring
    /// it by total duration so the playlist never exceeds the depth.
    private func spillSegment(seq: Int, data: Data, duration: Double) {
        guard rewindWindowSeconds > 0, let dir = spillDir else { return }
        let url = dir.appendingPathComponent("seg\(seq).\(segmentFileExtension)")
        do {
            try data.write(to: url)
        } catch {
            debugLog("[TS-REMUX] spill write failed (\(error)); dropping disk window")
            spillDir = nil
            spilled.removeAll()
            return
        }
        spilled.append((seq: seq, url: url, duration: duration))
        var total = spilled.reduce(0) { $0 + $1.duration }
        while total > rewindWindowSeconds, spilled.count > liveWindowSegments {
            let oldest = spilled.removeFirst()
            total -= oldest.duration
            try? FileManager.default.removeItem(at: oldest.url)
        }
    }

    // MARK: Feed-jitter telemetry (read the [TS-REMUX] feed-jitter lines)
    private var lastSegmentCloseWall: Date?
    private var lastStarvationLogAt = Date.distantPast
    /// When ANY live remuxer last cut a segment short because bytes
    /// stopped arriving. Read from the main thread by the playback
    /// driver; written from the ingest queue, hence the box.
    static let lastFeedStarvation = TimestampBox()
    /// Rolling 30 s delivery window behind `lastFeedStarvation`: it says
    /// whether the feed is bursty (average at real time) or genuinely
    /// slow, and carries the monotonic published-segment counter the
    /// post-stall nudge uses.
    static let feedRateWindow = FeedRateWindow()
    private var starvedClosures = 0
    private var worstClosureGap = 0.0

    /// See playlistText: monotonic, never shrinks, seeded at the target.
    private var pinnedTargetDuration = 2.0 {
        didSet { advertisedTargetDuration.set(pinnedTargetDuration) }
    }
    /// The TARGETDURATION this remuxer is currently advertising, readable
    /// from the main thread. AVPlayer polls a live playlist once per
    /// TARGETDURATION and parks roughly 3 x TARGETDURATION behind the
    /// edge, so the tile sizes its join offset from this (session7,
    /// 18:07: the value grew from 3 to 4 when a 3.92 s segment closed and
    /// the poll cadence went with it).
    let advertisedTargetDuration = DoubleBox(2.0)
    /// Media seconds (and segment count) the LAN playlist's RAM window
    /// holds right now: the last `lanRingSegments` cut segments. The
    /// AirPlay start gate reads it (device log 2026-09-25: a 4 s window
    /// under an 8 s hold-back never started on the Apple TV).
    let lanWindowSeconds = DoubleBox(0)
    let lanWindowSegments = DoubleBox(0)

    // MARK: Live-edge pacing (proxy burst join, 2026-09-13)
    //
    // Dispatcharr's "proxy" stream profile dumps ~30 s of backlog in the
    // first second of a tune: ten to twelve segments close inside 1 s, the
    // advertised live edge jumps 30 s under AVPlayer's feet right after it
    // joined, and it chases with -12640 "Cannot get that close to live",
    // a frozen first frame and a 17 s time-to-video. Join-side fixes were
    // tried and all failed on device (see the memory note). This paces the
    // PLAYLIST instead: after READY the advertised edge advances at 1.0x
    // wall time, and segments that close faster than that wait in a
    // reservoir. They are already stored; only their visibility is delayed,
    // never their order, and nothing is ever dropped.
    /// Highest sequence number the live playlist is allowed to advertise.
    /// nil until READY, which means "no pacing yet": before READY the
    /// playlist is rendered exactly as it always was.
    private var pacedAdvertisedSeq: Int?
    /// Wall time at which the next held segment may become visible:
    /// the previous advertised segment's visibility time plus its duration.
    private var pacedNextReleaseAt = Date.distantPast
    /// Highest /segN.ts (or .m4s) the player has fetched; the starvation
    /// guard reads it as the player's position. -1 = nothing fetched yet.
    private var pacedHighestRequestedSeq = -1
    private var pacedLastLogAt = Date.distantPast
    /// Ordinary upstream jitter (a 2.0 s segment closing 2.0 s minus a few
    /// tens of ms after the last one) must not start holding segments on a
    /// real-time feed, so a closure this close to its deadline counts as on
    /// time. Bursts miss the deadline by whole seconds, not by 0.25 s.
    private let pacedGrace = 0.25

    /// Pacing applies to the LIVE playlist, which on this app is normally
    /// the SPILL rendering: every live tune arms a 1800 s Live Rewind
    /// window, so `spilled` is non-empty from the first segment and the
    /// live playlist is the spilled list (2026-09-13 device log: the live
    /// playlist grew from 280 B to 2 KB across one tune). An earlier gate
    /// excluded the spill branch and so disabled pacing on every tune.
    /// What is genuinely excluded is the rewind / timeshift playlist
    /// ITSELF: catch-up and DVR render EXT-X-PLAYLIST-TYPE:EVENT
    /// (`eventPlaylist`) or an ENDLIST (`playlistComplete`), and those are
    /// never a live join. In-process delivery is excluded too: its
    /// segments are inlined as data URIs, so there are no segment GETs to
    /// read the player's position from and the starvation guard (rule 3)
    /// could not be honored there.
    private var pacingApplies: Bool {
        readySignaled && !eventPlaylist && !playlistComplete && !inProcessDelivery
    }

    /// Reason string for the one-shot READY log line.
    private var pacingStateDescription: String {
        if eventPlaylist { return "pacing off: event playlist (catch-up/DVR)" }
        if playlistComplete { return "pacing off: completed playlist" }
        if inProcessDelivery { return "pacing off: in-process delivery (inlined segments)" }
        return "pacing active"
    }

    /// Advance the paced live edge for `now`. Called on `queue` from
    /// playlistText (every playlist poll) and from storeSegment.
    private func advancePacedEdge(now: Date = Date()) {
        guard pacingApplies, let lastStored = segments.last?.seq else { return }
        guard var advertised = pacedAdvertisedSeq else {
            // READY just fired: the two segments READY was declared on are
            // visible immediately (rule 1), and the clock starts from the
            // edge segment's duration.
            pacedAdvertisedSeq = lastStored
            pacedNextReleaseAt = now + (segments.last?.duration ?? targetSegmentSeconds)
            return
        }
        while advertised < lastStored {
            let next = advertised + 1
            guard let segment = segments.first(where: { $0.seq == next }) else {
                // Ringed out before it could be advertised (rule 4 keeps
                // this from happening, but never stall the edge on a hole).
                advertised = next
                continue
            }
            guard now >= pacedNextReleaseAt - pacedGrace else { break }
            advertised = next
            // Anchor the next deadline on the later of now and this one, so
            // a late feed never banks credit and an on-time feed never
            // accumulates debt: one 2 s segment every 2 s releases on
            // arrival, forever, exactly as before this change.
            pacedNextReleaseAt = max(now, pacedNextReleaseAt) + segment.duration
        }
        // Post-switch drain: the switch starved the player, and the new
        // source then arrives as a burst that pacing would bank as a
        // reservoir, walking the advertised edge ever further behind real
        // time (device 16:09:15: 45 s behind live). For 20 s after the new
        // source's first segment, release held segments until the
        // reservoir is back at the normal two-segment target.
        if let drainUntil = pacedDrainUntil {
            if now >= drainUntil {
                pacedDrainUntil = nil
            } else {
                let before = advertised
                var held = segments.filter { $0.seq > advertised }.reduce(0.0) { $0 + $1.duration }
                while held > pacedDrainReservoirSeconds, advertised < lastStored {
                    advertised += 1
                    held -= segments.first(where: { $0.seq == advertised })?.duration ?? 0
                }
                if advertised > before {
                    pacedNextReleaseAt = now + (segments.first(where: { $0.seq == advertised })?.duration
                                                ?? targetSegmentSeconds)
                    debugLog("[TS-REMUX] paced: switch drain released segs \(before + 1)-\(advertised) (reservoir now \(String(format: "%.1f", max(0, held))) s)")
                }
            }
        }
        pacedAdvertisedSeq = advertised
        pacedStarvationRelease(now: now)
        pacedLog(now: now, lastStored: lastStored)
    }

    /// Rule 3: pacing must never cause a stall the reservoir could have
    /// prevented. If the player is within one target duration of the
    /// advertised edge and segments are held, release one at once.
    private func pacedStarvationRelease(now: Date) {
        guard let advertised = pacedAdvertisedSeq,
              let lastStored = segments.last?.seq,
              advertised < lastStored,
              pacedHighestRequestedSeq >= 0 else { return }
        let ahead = segments
            .filter { $0.seq > pacedHighestRequestedSeq && $0.seq <= advertised }
            .reduce(0.0) { $0 + $1.duration }
        guard ahead <= pinnedTargetDuration else { return }
        let next = advertised + 1
        pacedAdvertisedSeq = next
        pacedNextReleaseAt = now + (segments.first(where: { $0.seq == next })?.duration
                                    ?? targetSegmentSeconds)
        debugLog("[TS-REMUX] paced: starvation release seg \(next)")
    }

    /// Rule 6: at most one held-segment line per second.
    private func pacedLog(now: Date, lastStored: Int) {
        guard let advertised = pacedAdvertisedSeq, advertised < lastStored,
              now.timeIntervalSince(pacedLastLogAt) >= 1 else { return }
        pacedLastLogAt = now
        let held = segments.filter { $0.seq > advertised }
        let heldSeconds = held.reduce(0.0) { $0 + $1.duration }
        let heldMS = Int(max(0, pacedNextReleaseAt.timeIntervalSince(now)) * 1000)
        debugLog("[TS-REMUX] paced: seg \(advertised + 1) held \(heldMS) ms "
                 + "(reservoir \(held.count) segs, \(String(format: "%.1f", heldSeconds)) s)")
    }

    /// `lan`: the AirPlay LAN listener's copy (see `refreshLANHoldBack`):
    /// never paced, a deeper RAM window, and an explicit hold-back.
    private func playlistText(lan: Bool = false) -> String {
        advancePacedEdge()
        // Rewind mode: advertise the whole disk window; AVPlayer's
        // seekable range then IS the rewind window. Every spilled entry
        // also existed in memory when written, so seq numbering is one
        // continuous run either way.
        // In-process delivery inlines the segments, so the window is the
        // last few RAM segments only; the rewind disk window is not
        // advertised there (a 30-minute window would be a 1 GB playlist).
        // Live-edge pacing clamps the LIVE window to the paced edge; the
        // spill (Live Rewind) window is rendered whole, as always.
        // Live-edge pacing clamps the HEAD of whichever live window is
        // rendered (RAM window or Live Rewind spill window) to the paced
        // edge. Clamping the head only: the rewind depth behind the player
        // is untouched, so the seekable range keeps its full 1800 s.
        // LAN (AirPlay receiver): no pacing, every cut segment is served
        // at once (device log 2026-09-25 17:04: the paced one-segment
        // reservoir left the receiver no runway through a feed gap).
        let edgeCap: Int? = (pacingApplies && !lan) ? pacedAdvertisedSeq : nil
        func capped<T>(_ items: [T], _ seq: (T) -> Int) -> [T] {
            guard let cap = edgeCap else { return items }
            return items.filter { seq($0) <= cap }
        }
        let window: [(seq: Int, duration: Double)] = inProcessDelivery
            ? segments.suffix(inlineWindowSegments).map { (seq: $0.seq, duration: $0.duration) }
            : (spillDir != nil && !spilled.isEmpty)
                ? capped(spilled, { $0.seq }).map { (seq: $0.seq, duration: $0.duration) }
                : capped(segments, { $0.seq }).suffix(lan ? lanRingSegments : liveWindowSegments)
                    .map { (seq: $0.seq, duration: $0.duration) }
        guard let first = window.first else {
            return "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:\(Int(pinnedTargetDuration.rounded(.up)))\n#EXT-X-MEDIA-SEQUENCE:0\n"
        }
        // RFC 8216 4.3.3.1: TARGETDURATION MUST NOT change between playlist
        // reloads. The old `window.max()` recomputation could report 1 during
        // the startup ramp and grow to 2 (or beyond, after a long-GOP cut)
        // later, which is exactly the heuristic CoreMedia's -12888 staleness
        // check keys off. Pin it monotonically, seeded at the steady-state
        // target.
        pinnedTargetDuration = max(pinnedTargetDuration,
                                   window.map(\.duration).max() ?? targetSegmentSeconds)
        // fMP4 arm: EXT-X-MAP requires protocol version 6+; 7 matches
        // Apple's own fMP4 playlists. The TS arm stays at 3.
        let version = fmp4 != nil ? 7 : 3
        var text = """
        #EXTM3U
        #EXT-X-VERSION:\(version)
        #EXT-X-TARGETDURATION:\(Int(pinnedTargetDuration.rounded(.up)))
        #EXT-X-MEDIA-SEQUENCE:\(first.seq)

        """
        // Switch Stream: every window variant (live RAM, Live Rewind spill,
        // inlined, event) derives its tags from the same seq set, so the
        // count of tagged segments that slid out ahead of this window is
        // its DISCONTINUITY-SEQUENCE and the tags stay consistent across
        // reloads and across variants.
        if !discontinuitySeqs.isEmpty {
            let slid = discontinuitySeqs.filter { $0 < first.seq }.count
            text += "#EXT-X-DISCONTINUITY-SEQUENCE:\(slid)\n"
        }
        if eventPlaylist {
            text += "#EXT-X-PLAYLIST-TYPE:EVENT\n"
        }
        if lan, !eventPlaylist, !playlistComplete, lanHoldBackSeconds > 0 {
            // Never deeper than the window minus one target, so the join
            // point stays inside what is advertised.
            // HOLD-BACK must be at least 3x target per spec, and TIME-OFFSET
            // must never exceed the playlist duration: when the window is
            // too shallow for either, omit both tags for this reload.
            let room = window.reduce(0.0) { $0 + $1.duration } - pinnedTargetDuration
            if room >= 3 * pinnedTargetDuration.rounded(.up) {
                let hb = min(lanHoldBackSeconds, room)
                text += "#EXT-X-SERVER-CONTROL:HOLD-BACK=\(String(format: "%.3f", hb))\n"
                text += "#EXT-X-START:TIME-OFFSET=-\(String(format: "%.3f", hb)),PRECISE=NO\n"
            }
        }
        if fmp4 != nil {
            if inProcessDelivery, let initSeg = fmp4InitSegment {
                text += "#EXT-X-MAP:URI=\"data:video/mp4;base64,\(initSeg.base64EncodedString())\"\n"
            } else {
                text += "#EXT-X-MAP:URI=\"init.mp4\"\n"
            }
        }
        for segment in window {
            if discontinuitySeqs.contains(segment.seq) {
                text += "#EXT-X-DISCONTINUITY\n"
            }
            text += "#EXTINF:\(String(format: "%.3f", segment.duration)),\n"
            if inProcessDelivery, let b64 = deliveryBase64[segment.seq] {
                let mime = fmp4 != nil ? "video/iso.segment" : "video/mp2t"
                text += "data:\(mime);base64,\(b64)\n"
            } else {
                text += "seg\(segment.seq).\(segmentFileExtension)\n"
            }
        }
        if playlistComplete {
            text += "#EXT-X-ENDLIST\n"
        }
        return text
    }

    /// Media-segment URI extension per arm. Cosmetic to AVPlayer (the
    /// playlist context decides), load-bearing for a human reading a
    /// packet capture.
    private var segmentFileExtension: String { fmp4 != nil ? "m4s" : "ts" }

    /// Memory-first (live edge), disk-fallback (scrubbed back into the
    /// rewind window). Called on `queue`.
    private func segmentData(seq: Int) -> Data? {
        if let segment = segments.first(where: { $0.seq == seq }) {
            return segment.data
        }
        if let entry = spilled.first(where: { $0.seq == seq }) {
            return try? Data(contentsOf: entry.url)
        }
        return nil
    }

    // MARK: Loopback HTTP server

    private func startServer() {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            // Loopback only; never expose the stream on the LAN.
            params.requiredInterfaceType = .loopback
            let listener = try NWListener(using: params, on: .any)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.queue.async {
                        self.localPort = listener.port?.rawValue ?? 0
                        debugLog("[TS-REMUX] loopback server ready on port \(self.localPort)")
                    }
                case .failed:
                    self.queue.async { self.fail(.serverFailed) }
                default:
                    break
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
        } catch {
            fail(.serverFailed)
        }
    }

    // MARK: AirPlay LAN delivery (2026-09-21 rebuild)

    /// Result of `startLANDelivery`.
    enum LANDeliveryResult: Sendable {
        case ready(ip: String, port: UInt16)
        /// No Wi-Fi / Ethernet IPv4 address to serve on.
        case noAddress
        /// In-process delivery, or the listener would not come up.
        case unavailable
    }

    /// Second listener, bound to Wi-Fi (Ethernet as fallback), up ONLY while
    /// an AirPlay receiver is being served: in AirPlay video mode AVPlayer
    /// hands the item URL to the receiver, which cannot reach 127.0.0.1.
    /// Touched only on `queue`.
    private var lanListener: NWListener?
    private var lanPort: UInt16 = 0
    private var lanPeersLogged = Set<String>()

    // MARK: AirPlay LAN runway (device log 2026-09-25 17:04)
    //
    // The receiver played a bursty feed (11-13 stalls a minute, 4.5-6 s
    // wall for a 2.5 s segment) from a paced playlist whose reservoir was
    // one segment, and rebuffered until AVPlayer dropped external
    // playback. The LAN copy of the playlist is never paced, the RAM ring
    // is deeper while a receiver is served, and the playlist states a
    // hold-back that keeps the receiver ~3 segments (>= 8 s) behind the
    // live edge, grown for a bursty ingest and for high bitrates, up to
    // `lanHoldBackCeiling`. Loopback playback is untouched.

    /// RAM ring (and LAN RAM window) while a receiver is served: 16
    /// segments of ~2.5 s = 40 s, >= the 20 s hold-back ceiling plus
    /// room to re-fetch through a stall. Live tunes also have the disk
    /// spill behind it.
    private let lanRingSegments = 16
    private let lanHoldBackFloor = 8.0
    private let lanHoldBackCeiling = 20.0
    /// Touched only on `queue`. Monotonic per LAN session (only grows), so
    /// a receiver that re-joins after a stall joins at least as deep.
    private var lanHoldBackSeconds = 0.0
    private var lanHoldBackReason = ""
    /// Starved closures (wall, gap) for the last 60 s, touched on `queue`.
    private var recentStarvations: [(wall: Date, gap: Double)] = []
    /// Highest segment the receiver fetched on the LAN (-1 = none).
    private var lanHighestRequestedSeq = -1 {
        didSet { updateLANReservoir() }
    }

    // MARK: AirPlay link counters (read by the tile's 10 s link line)

    struct LANLinkStats: Sendable {
        /// Monotonic ingest bytes (same counter as `bytesIngested`).
        var ingestBytes: Int64 = 0
        /// Monotonic starved closures.
        var starvedClosures = 0
        /// Monotonic bytes sent on the LAN listener.
        var servedBytes: Int64 = 0
        var peer: String?
        /// Cut segments the receiver has not fetched yet.
        var reservoirSegments = 0
        var reservoirSeconds = 0.0
        var holdBack = 0.0
    }
    private let linkLock = NSLock()
    private var linkStats = LANLinkStats()

    var lanLinkStats: LANLinkStats {
        var st: LANLinkStats
        linkLock.lock(); st = linkStats; linkLock.unlock()
        st.ingestBytes = bytesIngested
        st.holdBack = lanHoldBack.get()
        return st
    }

    /// Runs on `queue`.
    private func updateLANReservoir() {
        let ahead = segments.filter { $0.seq > lanHighestRequestedSeq }
        let secs = ahead.reduce(0.0) { $0 + $1.duration }
        linkLock.lock()
        linkStats.reservoirSegments = ahead.count
        linkStats.reservoirSeconds = secs
        linkLock.unlock()
    }

    private func noteLANServed(bytes: Int, peer: String?) {
        linkLock.lock()
        linkStats.servedBytes += Int64(bytes)
        if let peer { linkStats.peer = peer }
        linkLock.unlock()
    }
    /// The stated LAN hold-back, readable from any thread (0 = no LAN).
    let lanHoldBack = DoubleBox(0)

    /// Starved closures in the last 60 s and the worst gap among them.
    private func recentStarvationStats(now: Date) -> (count: Int, worst: Double) {
        recentStarvations.removeAll { now.timeIntervalSince($0.wall) > 60 }
        return (recentStarvations.count, recentStarvations.reduce(0.0) { max($0, $1.gap) })
    }

    /// Bitrate of the RAM ring, kbps.
    private func ringKbps() -> Int {
        let bytes = segments.reduce(0) { $0 + $1.data.count }
        let secs = segments.reduce(0.0) { $0 + $1.duration }
        return secs > 0 ? Int(Double(bytes) * 8 / secs / 1000) : 0
    }

    /// Runs on `queue`. Chooses the LAN hold-back and logs when it grows.
    private func refreshLANHoldBack(now: Date) {
        let target = max(targetSegmentSeconds, pinnedTargetDuration.rounded(.up))
        let stats = recentStarvationStats(now: now)
        let kbps = ringKbps()
        var hb = max(3 * target, lanHoldBackFloor)
        var why = String(format: "3 x target %.0f s = %.0f s, floor %.0f s", target, 3 * target, lanHoldBackFloor)
        if stats.count > 6 {
            let add = stats.count > 12 ? 8.0 : 4.0
            hb += add
            why += String(format: "; bursty ingest %d stalls in 60 s +%.0f s", stats.count, add)
        }
        if stats.worst > 0, stats.worst + target > hb {
            hb = stats.worst + target
            why += String(format: "; worst gap %.1f s + target", stats.worst)
        }
        if kbps > 10_000 {
            hb += 4
            why += "; \(kbps) kbps > 10 Mbps +4 s"
        }
        hb = min(lanHoldBackCeiling, hb)
        guard hb > lanHoldBackSeconds + 0.4 else { return }
        lanHoldBackSeconds = hb
        lanHoldBackReason = why
        lanHoldBack.set(hb)
        airPlayVariant?.setHoldBackFloor(hb)
        debugLog(String(format: "[TS-REMUX] LAN hold-back %.1f s (%@; ceiling %.0f s); LAN playlist unpaced, RAM ring %d segs",
                        hb, why, lanHoldBackCeiling, lanRingSegments))
    }
    /// Touched only on `queue`; readable elsewhere through
    /// `currentAirPlayVariant`.
    private var airPlayVariant: AirPlayAACVariant? {
        didSet { airPlayLock.lock(); airPlayVariantShared = airPlayVariant; airPlayLock.unlock() }
    }
    private let airPlayLock = NSLock()
    private var airPlayVariantShared: AirPlayAACVariant?
    private var sourceAudioStreamTypeShared: UInt8 = 0

    var currentAirPlayVariant: AirPlayAACVariant? {
        airPlayLock.lock(); defer { airPlayLock.unlock() }
        return airPlayVariantShared
    }

    private func setSourceAudioStreamType(_ type: UInt8) {
        airPlayLock.lock(); sourceAudioStreamTypeShared = type; airPlayLock.unlock()
    }

    /// The PMT's first audio stream as the AirPlay log names it:
    /// AC-3 / E-AC-3 / AAC, "unknown" before the PMT (or on the HEVC arm).
    var sourceAudioCodec: String {
        airPlayLock.lock(); let t = sourceAudioStreamTypeShared; airPlayLock.unlock()
        switch t {
        case 0x81: return "AC-3"
        case 0x87: return "E-AC-3"
        case 0x0F: return "AAC"
        default: return "unknown"
        }
    }

    /// Start (or reuse) the LAN listener. `completion` runs on the main
    /// queue exactly once.
    func startLANDelivery(completion: @escaping @MainActor (LANDeliveryResult) -> Void) {
        let once = LANStartOnce()
        queue.async { [weak self] in
            @Sendable func finish(_ r: LANDeliveryResult) {
                guard once.claim() else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { completion(r) } }
            }
            guard let self, !self.stopped, !self.inProcessDelivery else { finish(.unavailable); return }
            guard let ip = CastHLSProxySession.wifiLANAddress() else { finish(.noAddress); return }
            if self.lanListener != nil, self.lanPort != 0 {
                finish(.ready(ip: ip, port: self.lanPort))
                return
            }
            self.openLANListener(interfaces: [.wifi, .wiredEthernet]) { port in
                // Runs on `queue`.
                if port != nil { self.refreshLANHoldBack(now: Date()) }
                if let port { finish(.ready(ip: ip, port: port)) } else { finish(.unavailable) }
            }
            self.queue.asyncAfter(deadline: .now() + 3) { finish(.unavailable) }
        }
    }

    /// Runs on `queue`. Tries each interface type in order.
    private func openLANListener(interfaces: [NWInterface.InterfaceType],
                                 ready: @escaping @Sendable (UInt16?) -> Void) {
        guard let type = interfaces.first else { ready(nil); return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.requiredInterfaceType = type
            let listener = try NWListener(using: params, on: .any)
            lanListener = listener
            listener.newConnectionHandler = { [weak self] connection in
                self?.handleLANConnection(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.queue.async {
                        guard self.lanListener === listener else { return }
                        self.lanPort = listener.port?.rawValue ?? 0
                        ready(self.lanPort == 0 ? nil : self.lanPort)
                    }
                case .failed, .cancelled:
                    self.queue.async {
                        guard self.lanListener === listener else { return }
                        listener.cancel()
                        self.lanListener = nil
                        self.lanPort = 0
                        self.openLANListener(interfaces: Array(interfaces.dropFirst()), ready: ready)
                    }
                default:
                    break
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
        } catch {
            openLANListener(interfaces: Array(interfaces.dropFirst()), ready: ready)
        }
    }

    /// One-shot latch for `startLANDelivery`'s completion (ready, failure
    /// and the 3 s timeout race each other).
    private final class LANStartOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }

    func stopLANDelivery() {
        queue.async { [weak self] in self?.stopLANDeliveryLocked() }
    }

    private func stopLANDeliveryLocked() {
        guard let listener = lanListener else { return }
        lanListener = nil
        lanPort = 0
        lanPeersLogged.removeAll()
        lanHoldBackSeconds = 0
        lanHoldBack.set(0)
        lanHoldBackReason = ""
        lanHighestRequestedSeq = -1
        linkLock.lock(); linkStats.peer = nil; linkLock.unlock()
        listener.cancel()
        debugLog("[TS-REMUX] LAN delivery stopped (loopback only)")
    }

    /// Peer filter: the stream leaves the device on this listener, so only
    /// private (RFC 1918), link-local and unique-local peers are served;
    /// anything else gets 403.
    private func handleLANConnection(_ connection: NWConnection) {
        let peer = Self.peerHost(connection.endpoint)
        guard Self.isPrivatePeer(connection.endpoint) else {
            debugLog("[TS-REMUX] LAN delivery refused \(peer ?? "?") (not a private address): 403")
            connection.start(queue: .global(qos: .userInitiated))
            let body = Data("forbidden".utf8)
            var response = Data(("HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\n"
                + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n").utf8)
            response.append(body)
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        if let peer {
            queue.async { [weak self] in
                guard let self, self.lanPeersLogged.insert(peer).inserted else { return }
                debugLog("[TS-REMUX] LAN delivery: first request from \(peer)")
            }
        }
        handleConnection(connection, lan: true, peer: peer)
    }

    static func peerHost(_ endpoint: NWEndpoint) -> String? {
        guard case let .hostPort(host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let a): return "\(a)"
        case .ipv6(let a): return "\(a)"
        case .name(let n, _): return n
        @unknown default: return nil
        }
    }

    static func isPrivatePeer(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let a):
            return isPrivateIPv4([UInt8](a.rawValue))
        case .ipv6(let a):
            let b = [UInt8](a.rawValue)
            guard b.count == 16 else { return false }
            // IPv4-mapped ::ffff:a.b.c.d
            if b[0..<10].allSatisfy({ $0 == 0 }), b[10] == 0xFF, b[11] == 0xFF {
                return isPrivateIPv4(Array(b[12..<16]))
            }
            if b[0] == 0xFE, b[1] & 0xC0 == 0x80 { return true }   // fe80::/10 link-local
            if b[0] & 0xFE == 0xFC { return true }                 // fc00::/7 unique-local
            return b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 // ::1
        default:
            return false
        }
    }

    static func isPrivateIPv4(_ b: [UInt8]) -> Bool {
        guard b.count == 4 else { return false }
        switch (b[0], b[1]) {
        case (10, _), (127, _): return true
        case (172, 16...31): return true
        case (192, 168): return true
        case (169, 254): return true
        default: return false
        }
    }

    /// Start the airplay-aac variant, primed from the buffered TS window.
    /// nil (on main) when this session cannot feed one: the HEVC fMP4 arm,
    /// a source that is not AC-3 / E-AC-3, or no platform decoder.
    func startAACVariant(completion: @escaping @MainActor (AirPlayAACVariant?) -> Void) {
        queue.async { [weak self] in
            func finish(_ v: AirPlayAACVariant?) {
                DispatchQueue.main.async { MainActor.assumeIsolated { completion(v) } }
            }
            guard let self, !self.stopped else { finish(nil); return }
            if let existing = self.airPlayVariant { finish(existing); return }
            let source: CastAudioSourceCodec
            switch self.audioStreamType {
            case 0x81: source = .ac3
            case 0x87: source = .eac3
            default: finish(nil); return
            }
            guard self.fmp4 == nil, self.codecGatePassed, CastAudioTranscoder.canDecode(source) else {
                finish(nil); return
            }
            let variant = AirPlayAACVariant(sourceCodecName: source.displayName,
                                            log: { debugLog("[TS-REMUX] airplay-aac \($0)") })
            let window = self.segments.suffix(self.liveWindowSegments).map { (seq: $0.seq, data: $0.data) }
            var tail = self.currentSegment
            for packet in self.heldAudio { tail.append(packet) }
            tail.append(self.pending)
            self.airPlayVariant = variant
            variant.setHoldBackFloor(self.lanHoldBackSeconds)
            variant.start(primeSegments: Array(window), tail: tail)
            finish(variant)
        }
    }

    func stopAACVariant() {
        queue.async { [weak self] in self?.stopAACVariantLocked() }
    }

    private func stopAACVariantLocked() {
        guard let variant = airPlayVariant else { return }
        airPlayVariant = nil
        variant.stop()
    }

    private func handleConnection(_ connection: NWConnection, lan: Bool = false, peer: String? = nil) {
        connection.start(queue: .global(qos: .userInitiated))
        receiveRequest(connection, buffer: Data(), lan: lan, peer: peer)
    }

    private func receiveRequest(_ connection: NWConnection, buffer: Data, lan: Bool, peer: String?) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self, error == nil else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                // Parse BEFORE honouring isComplete: a legal request whose
                // last bytes arrive with FIN piggybacked must still be served.
                let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
                let path = head.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                self.respond(connection, path: path, lan: lan, peer: peer)
            } else if isComplete || buffer.count >= 16_384 {
                // EOF before a complete request, or an oversized head. Without
                // the isComplete arm a cleanly half-closed peer returns
                // (nil, true, nil) forever and this re-armed on every one.
                connection.cancel()
            } else {
                self.receiveRequest(connection, buffer: buffer, lan: lan, peer: peer)
            }
        }
    }

    struct ServedResource {
        let status: Int
        let body: Data
        let contentType: String
        let uti: String
    }

    /// Resolves one playlist / init / segment request on the remux queue.
    /// Shared by the loopback HTTP server and the in-process loader.
    func serve(path: String, lan: Bool = false, completion: @escaping (ServedResource) -> Void) {
        // AirPlay airplay-aac variant (plan section 4). Resolved OFF the
        // remux queue: a live-edge segment GET is held up to the store's
        // wait, and the ingest must never stall behind it.
        if path.hasPrefix("/aac/") {
            let variant = currentAirPlayVariant
            DispatchQueue.global(qos: .userInitiated).async {
                let r: ServedResource
                if let variant {
                    let v = variant.serve(path: path)
                    debugLog("[AVP-AIRPLAY] GET \(path) -> \(v.status) \(v.kind) seq \(v.seq) \(v.body.count) B")
                    r = ServedResource(status: v.status, body: v.body, contentType: v.contentType,
                                       uti: v.contentType.hasSuffix("mpegurl") ? "public.m3u-playlist" : "public.mpeg-4")
                } else {
                    debugLog("[AVP-AIRPLAY] GET \(path) -> 404 (no airplay-aac variant)")
                    r = ServedResource(status: 404, body: Data("not found".utf8), contentType: "text/plain", uti: "public.plain-text")
                }
                completion(r)
            }
            return
        }
        queue.async { [weak self] in
            guard let self else {
                completion(ServedResource(status: 410, body: Data(), contentType: "text/plain", uti: "public.plain-text"))
                return
            }
            let r: ServedResource
            if path.hasSuffix("live.m3u8") {
                r = ServedResource(status: 200, body: Data(self.playlistText(lan: lan).utf8),
                                   contentType: "application/vnd.apple.mpegurl", uti: "public.m3u-playlist")
            } else if path.hasSuffix("init.mp4"), let initSeg = self.fmp4InitSegment {
                r = ServedResource(status: 200, body: initSeg, contentType: "video/mp4", uti: "public.mpeg-4")
            } else if path.hasPrefix("/seg"), path.hasSuffix(".ts"),
                      let seq = Int(path.dropFirst(4).dropLast(3)),
                      let data = self.segmentData(seq: seq) {
                // The player's position, for the pacing starvation guard
                // (loopback only: the LAN copy is unpaced).
                if lan { self.lanHighestRequestedSeq = max(self.lanHighestRequestedSeq, seq) }
                else { self.pacedHighestRequestedSeq = max(self.pacedHighestRequestedSeq, seq) }
                r = ServedResource(status: 200, body: data, contentType: "video/mp2t", uti: "public.mpeg-2-transport-stream")
            } else if path.hasPrefix("/seg"), path.hasSuffix(".m4s"),
                      let seq = Int(path.dropFirst(4).dropLast(4)),
                      let data = self.segmentData(seq: seq) {
                if lan { self.lanHighestRequestedSeq = max(self.lanHighestRequestedSeq, seq) }
                else { self.pacedHighestRequestedSeq = max(self.pacedHighestRequestedSeq, seq) }
                r = ServedResource(status: 200, body: data, contentType: "video/iso.segment", uti: "public.mpeg-4")
            } else {
                r = ServedResource(status: 404, body: Data("not found".utf8), contentType: "text/plain", uti: "public.plain-text")
            }
            // First 24 requests verbose, then playlist polls only, at most
            // one every 10 s. The flat 24-line cap is why the 17:58:55
            // buffer-empty could not be diagnosed: every GET line had been
            // spent 15 s earlier, so "AVPlayer stopped fetching" and
            // "AVPlayer kept fetching" looked identical in the log
            // (session6.txt, exactly 24 GET lines, last at 17:58:40).
            let isPlaylistPoll = path.hasSuffix("live.m3u8")
            let throttledPoll = isPlaylistPoll
                && Date().timeIntervalSince(self.lastPollLogAt) > 10
            if self.loggedRequests < 24 || throttledPoll || r.status != 200 {
                if throttledPoll { self.lastPollLogAt = Date() }
                self.loggedRequests += 1
                debugLog("[TS-REMUX] GET \(path) -> \(r.status) \(r.body.count) B (segments \(self.segments.first?.seq ?? -1)...\(self.segments.last?.seq ?? -1))")
            }
            completion(r)
        }
    }

    private func respond(_ connection: NWConnection, path: String, lan: Bool = false, peer: String? = nil) {
        serve(path: path, lan: lan) { [weak self] r in
            if lan { self?.noteLANServed(bytes: r.body.count, peer: peer) }
            let status: String
            switch r.status {
            case 200: status = "200 OK"
            case 403: status = "403 Forbidden"
            case 404: status = "404 Not Found"
            default: status = "410 Gone"
            }
            let header = "HTTP/1.1 \(status)\r\n"
                + "Content-Type: \(r.contentType)\r\n"
                + "Content-Length: \(r.body.count)\r\n"
                + "Cache-Control: no-cache\r\n"
                + "Connection: close\r\n\r\n"
            var response = Data(header.utf8)
            response.append(r.body)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}

// MARK: - URLSessionDataDelegate (ingest)

extension TSHLSRemuxer: URLSessionDataDelegate {
    /// The interface the ingest actually rode (a live ingest reports this
    /// only when the task ends: reconnect, stop, failure). Device log
    /// 2026-09-25 17:04.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let t = metrics.transactionMetrics.last else { return }
        debugLog("[TS-REMUX] ingest transport: cellular=\(t.isCellular) expensive=\(t.isExpensive) "
            + "constrained=\(t.isConstrained) multipath=\(t.isMultipath) "
            + "local=\(t.localAddress ?? "?") reused=\(t.isReusedConnection)")
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            // 503 carries the server's own explanation in its body, and the
            // tile's recovery depends on WHICH 503 this is (Logan
            // 2026-09-12: never assume the cause, and fail over when the
            // server says it has no stream). Allow the tiny body through so
            // the failure reason can quote Dispatcharr verbatim.
            // 429 too: Dispatcharr's "Stream limit exceeded" body is the
            // only proof of a session-limit refusal (DispatcharrConnectionLimit).
            if http.statusCode == 503 || http.statusCode == 429 {
                errorStatusCode = http.statusCode
                errorBody.removeAll()
                if let header = http.value(forHTTPHeaderField: "Retry-After"),
                   let secs = Double(header.trimmingCharacters(in: .whitespaces)) {
                    errorRetryAfter = secs
                }
                completionHandler(.allow)
                return
            }
            queue.async { [weak self] in self?.fail(.ingestFailed("HTTP \(http.statusCode)")) }
            completionHandler(.cancel)
            return
        }
        firstByteLock.lock()
        if connectedAt == nil { connectedAt = Date() }
        firstByteLock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // Error body, not media: buffer it and fail as soon as the JSON
        // parses (or the body grows past anything Dispatcharr would send).
        if errorStatusCode != nil {
            errorBody.append(data)
            if ingestErrorReason() != nil || errorBody.count > 8192 {
                failWithIngestError()
            }
            return
        }
        // "First byte" marker (review 2026-09-11, marker inventory): the
        // log had NOTHING between `ingest started` and the PAT parse, so
        // connect + TLS + the upstream open (220 to 2532 ms) could not be
        // separated from the PSI walk.
        firstByteLock.lock()
        ingestedBytes += Int64(data.count)
        lastByteAt = Date()
        // A response we never saw (a 200 with no delegate callback is not
        // possible, but an adopted/warm ingest can hand us data first)
        // still counts as connected for the loading detail line.
        if connectedAt == nil { connectedAt = Date() }
        firstByteLock.unlock()
        if !firstByteLogged {
            firstByteLogged = true
            let ms = Int(Date().timeIntervalSince(ingestStartedAt) * 1000)
            TuneTimeline.shared.mark("firstByte")
            firstByteLock.lock(); firstByteArrived = true; firstByteLock.unlock()
            debugLog("[TS-REMUX] first byte after \(ms)ms (\(data.count) B)")
            // Cancels the tile's first-byte deadline / failover walk
            // (s7_86.txt:353-395).
            DispatchQueue.main.async { [weak self] in self?.onFirstByte?() }
        }
        queue.async { [weak self] in self?.consume(data) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // The socket is closed whatever the outcome; release the slot so
        // a re-tune does not see a phantom overlap.
        if task === ingestTask { releaseConnection() }
        // The buffered error response ended (a body too short to trip the
        // parse above, or no body at all): report it now, never as a
        // clean EOF.
        if errorStatusCode != nil {
            failWithIngestError()
            return
        }
        guard let error, (error as NSError).code != NSURLErrorCancelled else {
            // Clean EOF. For event (catch-up / local-file) playlists this
            // IS the happy ending: finalize with ENDLIST so AVPlayer gets
            // a finite VOD instead of a forever-stale live playlist (the
            // old behavior wedged the end of a fully-downloaded catch-up
            // programme into the stale-escalation path).
            if eventPlaylist {
                debugLog("[TS-REMUX] ingest complete (clean EOF); finalizing event playlist")
                markComplete()
                return
            }
            // Our own stop() cancels the task; that is a teardown, not the
            // upstream going away.
            let cancelled = (error as NSError?)?.code == NSURLErrorCancelled
            guard !cancelled, !closeReported else { return }
            closeReported = true
            debugLog("[TS-REMUX] upstream CLOSED the live ingest (clean EOF) after "
                + "\(bytesIngested / 1_048_576) MB; the stream is gone, so this re-tunes "
                + "now instead of waiting out the \(Int(Self.ingestSilenceThreshold))s silence timer")
            DispatchQueue.main.async { [weak self] in self?.onIngestClosed?() }
            return
        }
        queue.async { [weak self] in self?.fail(.ingestFailed(error.localizedDescription)) }
    }

    /// Dispatcharr's reason string out of the buffered body
    /// ({"error": "<reason>"}), nil while the body is still partial or
    /// is not the JSON shape we expect.
    private func ingestErrorReason() -> String? {
        guard !errorBody.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: errorBody),
              let dict = object as? [String: Any],
              let reason = dict["error"] as? String else { return nil }
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Fails the buffered error response with the server's own words
    /// attached, in the " | " field form the tile parses (see
    /// AVPlayerMultiviewTile.parse503). "waited" rides along for the log
    /// only: it is the server telling us how long it spent trying this
    /// channel's streams itself.
    private func failWithIngestError() {
        guard let code = errorStatusCode else { return }
        errorStatusCode = nil
        var text = "HTTP \(code)"
        if let reason = ingestErrorReason() { text += " | reason=\(reason)" }
        if let retryAfter = errorRetryAfter { text += " | retryAfter=\(retryAfter)" }
        if let object = try? JSONSerialization.jsonObject(with: errorBody),
           let dict = object as? [String: Any], let waited = dict["waited"] as? String {
            text += " | waited=\(waited)"
        }
        errorBody.removeAll()
        errorRetryAfter = nil
        // No cancel here: the tile's error path tears the pipeline down
        // (stop() cancels the task), and ingestTask is not ours to touch
        // from the delegate queue.
        queue.async { [weak self] in self?.fail(.ingestFailed(text)) }
    }
}

// MARK: - AVPlayer multiview tile (TEST, branch test/avplayer-hls-engine)

/// AVPlayer-backed video surface for ONE multiview tile, the per-tile
/// engine-swap counterpart of `MPVPlayerViewRepresentable`. Multiview's
/// features (layouts, spotlight, relocate, audio routing, staging,
/// chrome, focus) all live in the container and store and are
/// tile-agnostic, so swapping the video view per tile is all that
/// AVPlayer multiview requires; nothing else is duplicated.
///
/// Direct HLS URLs play as-is; raw TS rides a per-tile TSHLSRemuxer
/// instance (each binds its own loopback port, so N concurrent tiles
/// remux independently). On any remux/codec-gate/playback failure the
/// tile reports back and the parent swaps it to an mpv tile, so
/// mixed-engine grids (e.g. an HEVC UHD channel on mpv next to H.264
/// channels on AVPlayer) are the normal failure mode, not an error.
///
/// Self-rescheduling stall/freeze watchdog for a live AVPlayer item. Polls
/// every `interval` while `player.currentItem === item`; calls `onDead(reason)`
/// exactly once and stops when the item fails, never becomes ready, renders no
/// video, or freezes (clock not advancing while the player is trying to play).
/// The one-shot +Ns "no renderable video" check it replaces could be
/// permanently disarmed by a single rendered frame; this keeps watching, so a
/// mid-stream server wedge (a rejected reload, a stuck live edge) self-heals to
/// the mpv engine instead of stranding the viewer on a frozen frame. Store the
/// instance and `cancel()` it on teardown / channel swap.
///
/// Uses DispatchQueue.main.asyncAfter (not Timer, whose @Sendable block rejects
/// the non-Sendable AVPlayer/closure captures) and MainActor.assumeIsolated on
/// each fire, matching the codebase's main-queue-callback idiom.
@MainActor
final class AVPStallWatchdog {
    private weak var player: AVPlayer?
    private weak var item: AVPlayerItem?
    private let label: String
    private let interval: TimeInterval
    private let onDead: (String) -> Void
    private var lastTime = -1.0
    private var stuckPolls = 0     // consecutive polls with a frozen clock
    private var unknownPolls = 0   // consecutive polls stuck at .unknown
    private var cancelled = false
    private var fired = false      // onDead is strictly one-shot

    /// Media-byte progress probe (MKV VOD tiles): the engine's total
    /// received bytes. A stream that is still ADVANCING is a slow link,
    /// not a wedge - a resumed 4K title's first segment build is ~190MB,
    /// nearly a minute at 30Mbps Wi-Fi, and the fixed 12s no-ready kill
    /// was exactly why iPhone UHD VOD "would not play at all"
    /// (2026-08-26; the watchdog's own retry cancelled every healthy
    /// build mid-flight). nil = no probe (live/direct), old behavior.
    private let mediaBytes: (() -> Int64)?
    private var lastMediaBytes: Int64 = -1

    init(player: AVPlayer, item: AVPlayerItem, label: String,
         interval: TimeInterval = 4.0,
         mediaBytes: (() -> Int64)? = nil,
         onDead: @escaping (String) -> Void) {
        self.player = player
        self.item = item
        self.label = label
        self.interval = interval
        self.mediaBytes = mediaBytes
        self.onDead = onDead
    }

    /// True when the media stream received bytes since the last poll.
    /// Call at most once per poll (it advances the baseline).
    private func pollStreamingProgress() -> Bool {
        guard let mediaBytes else { return false }
        let now = mediaBytes()
        defer { lastMediaBytes = now }
        return now > lastMediaBytes
    }

    func start() { schedule() }
    func cancel() { cancelled = true }

    /// AirPlay (2026-09-21 rebuild): while an external receiver plays, the
    /// local clock and presentation size are not a render this phone can
    /// judge, so polls pass without verdicts. Re-arming resets every
    /// baseline and, after the tile swapped items, binds to `item`.
    private(set) var suspended = false

    func setSuspended(_ on: Bool, item newItem: AVPlayerItem?) {
        if let newItem { item = newItem }
        guard suspended != on else { return }
        suspended = on
        if !on {
            lastTime = -1
            stuckPolls = 0
            unknownPolls = 0
            lastMediaBytes = -1
        }
    }

    private func schedule() {
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func poll() {
        guard !cancelled, !fired else { return }
        if suspended { schedule(); return }
        guard let player, let item, player.currentItem === item else { return }
        func die(_ reason: String) {
            fired = true
            debugLog("[AVP-WATCHDOG] \(label): \(reason); falling back to mpv")
            // What AVFoundation itself thinks went wrong (Freyguy1975
            // 2026-09-09: one channel sat at .unknown for 12 s with no
            // app-side clue; the item's own logs name playlist parse
            // errors, segment fetch failures and format rejections).
            if let events = item.errorLog()?.events, !events.isEmpty {
                for e in events.suffix(6) {
                    debugLog("[AVP-WATCHDOG] errorLog: code=\(e.errorStatusCode) domain=\(e.errorDomain) uri=\(e.uri ?? "-") comment=\(e.errorComment ?? "-")")
                }
            } else {
                debugLog("[AVP-WATCHDOG] errorLog: none")
            }
            if let a = item.accessLog()?.events.last {
                debugLog("[AVP-WATCHDOG] accessLog: segments=\(a.numberOfMediaRequests) bytes=\(a.numberOfBytesTransferred) stalls=\(a.numberOfStalls) startup=\(String(format: "%.2f", a.startupTime)) indicated=\(Int(a.indicatedBitrate)) observed=\(Int(a.observedBitrate)) uri=\(a.uri ?? "-")")
            } else {
                debugLog("[AVP-WATCHDOG] accessLog: none")
            }
            onDead(reason)
        }
        let progressing = pollStreamingProgress()
        switch item.status {
        case .failed:
            die("item failed (\(item.error.map { "\($0)" } ?? "unknown error"))")
            return
        case .unknown:
            unknownPolls += 1
            if unknownPolls >= 15 {
                die("never became ready (~\(Int(interval * 15))s, stream \(progressing ? "still advancing" : "stalled"))")
                return
            }
            if unknownPolls >= 3 {
                if progressing {
                    debugLog("[AVP-WATCHDOG] \(label): .unknown ~\(Int(interval) * unknownPolls)s but media stream advancing (slow link); waiting")
                } else {
                    die("never became ready (~\(Int(interval * 3))s at .unknown)")
                    return
                }
            }
        case .readyToPlay:
            unknownPolls = 0
            let size = item.presentationSize
            if size.width == 0 && size.height == 0 {
                die("ready but no renderable video (audio-only / undecodable video)")
                return
            }
            // Frozen clock: only count when the player claims to be
            // PLAYING with a stuck playhead (a true wedge), or when it is
            // waiting AND the media stream has stopped advancing. A
            // waiting player whose stream is still receiving bytes is a
            // slow-link rebuffer (UHD seek at 30Mbps takes ~a minute) and
            // must be left alone.
            let status = player.timeControlStatus
            if status == .playing
                || (status == .waitingToPlayAtSpecifiedRate && !progressing) {
                let t = CMTimeGetSeconds(item.currentTime())
                // abs(): a SEEK moves the clock in either direction and is
                // never a wedge. The signed test read every backward jump
                // (rewind-30 spam) as "stuck" - two rewinds inside ~8s
                // killed a perfectly healthy VOD session (field find
                // 2026-08-26, #7 Seventhdary while rewinding).
                if t.isFinite, lastTime >= 0, abs(t - lastTime) < 0.25 {
                    stuckPolls += 1
                    // A PLAYING player with a stuck clock is a wedge in
                    // ~2 polls. A WAITING one gets a longer fuse (4): a
                    // flow-control-suspended stream can look idle for a
                    // poll while the pipeline is healthy.
                    if stuckPolls >= (status == .playing ? 2 : 4) {
                        die(String(format: "playback frozen (clock stuck at %.2fs while not paused)", t))
                        return
                    }
                } else {
                    stuckPolls = 0
                }
                if t.isFinite { lastTime = t }
            } else {
                stuckPolls = 0   // user paused: never accumulate
            }
        @unknown default:
            break
        }
        schedule()
    }
}

#if os(tvOS)
/// Debounces display-criteria teardown across tile generations. A tile
/// stop used to clear the criteria immediately, and a session that
/// started 160ms later set new ones (2026-08-25 log, 72 HOURS): the
/// panel gets told "revert to SDR 60" and "switch to HDR 24" back to
/// back, risking two HDMI re-handshakes where one (or zero, when the
/// formats match) would do. The clear now waits 3s and a new apply
/// cancels it, so movie-to-movie and channel-zap transitions hand the
/// panel one coherent instruction.
@MainActor
enum DisplayCriteriaCoordinator {
    private static var pendingClear: DispatchWorkItem?
    /// What the panel was last ASKED for ("1920x1080|SDR|59.94"), so a
    /// repeat request can be recognised as a no-op and skipped rather
    /// than stalling the tune across an HDMI mode change that changes
    /// nothing (review 2026-09-11 section 1 proposal 6).
    private(set) static var lastAppliedSignature: String?

    static func apply(_ criteria: AVDisplayCriteria, to dm: AVDisplayManager,
                      signature: String? = nil) {
        pendingClear?.cancel()
        pendingClear = nil
        dm.preferredDisplayCriteria = criteria
        lastAppliedSignature = signature
    }

    static func scheduleClear(_ dm: AVDisplayManager) {
        pendingClear?.cancel()
        let work = DispatchWorkItem {
            dm.preferredDisplayCriteria = nil
            lastAppliedSignature = nil
            debugLog("[AVP-DISPLAY] display criteria cleared (debounced; panel returns to default mode)")
        }
        pendingClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }
}
#endif

/// Known evaluation limitations: the chrome scrubber and track pickers
/// bind to the mpv progress store, so they are inert while the audio
/// tile is AVPlayer-backed; play/pause via `shouldPause` works.
/// Accumulates subtitle cues harvested by the MKV engine's A/V builds
/// and answers "what text is on screen at time T". Rendering is our own
/// overlay (mpv also drew its own subs): native VTT renditions were
/// measured unusable - AVPlayer prefetches subtitle segments ~2 minutes
/// ahead, each costing a 3-span media fetch on a UHD remux. Harvested
/// cues instead ride the spans the A/V build already parsed, so
/// coverage always leads the playhead by the forward buffer for free.
@MainActor final class AVPSubtitleCueStore: ObservableObject {
    struct Cue { let startMs: Int64; let endMs: Int64; let text: String }
    private(set) var tracks: [(number: Int, name: String, language: String)] = []
    private var cuesByTrack: [Int: [Cue]] = [:]
    /// MKV track number of the enabled subtitle track; nil = off.
    @Published var activeTrack: Int?

    func setTracks(_ t: [(number: Int, name: String, language: String)]) { tracks = t }

    func add(track: Int, newCues: [MKVFMP4Remuxer.SubtitleCue]) {
        cuesByTrack[track, default: []].append(contentsOf: newCues.map {
            Cue(startMs: $0.ptsTicks / 90,
                endMs: ($0.ptsTicks + $0.durTicks) / 90,
                text: Self.displayText($0.text))
        })
    }

    /// Linear scan is fine: a feature film carries ~1-2k cues per track
    /// and this runs 4x/second.
    func text(atMs ms: Int64) -> String? {
        guard let t = activeTrack, let list = cuesByTrack[t] else { return nil }
        var lines: [String] = []
        for cue in list where ms >= cue.startMs && ms < cue.endMs {
            lines.append(cue.text)
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    func reset() {
        tracks = []
        cuesByTrack = [:]
        activeTrack = nil
    }

    /// SRT markup (<i>, <font ...>) means nothing to a Text view; strip
    /// every angle-bracket tag for display.
    private static func displayText(_ raw: String) -> String {
        guard raw.contains("<") else { return raw }
        var out = ""
        var depth = 0
        for c in raw {
            if c == "<" { depth += 1 }
            else if c == ">" { if depth > 0 { depth -= 1 } }
            else if depth == 0 { out.append(c) }
        }
        return out
    }
}

/// Bottom-center subtitle text over an AVPlayer tile, driven by a 4Hz
/// clock against the harvested-cue store. Hidden entirely while no
/// track is enabled.
struct AVPSubtitleOverlay: View {
    @ObservedObject var store: AVPSubtitleCueStore
    let timeMs: () -> Int64
    /// The playing video's aspect ratio (width/height) when known, so
    /// the cue text anchors to the VIDEO's bottom edge, not the tile's.
    /// iPhone portrait letterboxes a 16:9 movie mid-screen, and a
    /// tile-anchored cue sat way below the picture (field find
    /// 2026-08-26). nil = assume 16:9.
    var videoAspect: () -> CGFloat? = { nil }
    @State private var text: String?
    private let tick = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    #if os(tvOS)
    private var fontSize: CGFloat { 38 }
    private var baseInset: CGFloat { 90 }
    #else
    private var fontSize: CGFloat { 18 }
    private var baseInset: CGFloat { 24 }
    #endif

    private func bottomInset(_ geo: GeometryProxy) -> CGFloat {
        let aspect = max(0.2, videoAspect() ?? (16.0 / 9.0))
        let videoHeight = min(geo.size.height, geo.size.width / aspect)
        return (geo.size.height - videoHeight) / 2 + baseInset
    }

    var body: some View {
        GeometryReader { geo in
            VStack {
                Spacer()
                if let text, store.activeTrack != nil {
                    Text(text)
                        .scaledFont(.system(size: fontSize, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.9), radius: 2, x: 0, y: 1)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                        .padding(.bottom, bottomInset(geo))
                        .padding(.horizontal, 40)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .allowsHitTesting(false)
        .onReceive(tick) { _ in
            let now = store.activeTrack == nil ? nil : store.text(atMs: timeMs())
            if now != text { text = now }
        }
    }
}

// MARK: - Live channel retention (Logan 2026-08-27, Option B)
//
// With "Keep Recent Channels Live" on, flipping away from a live channel
// hands its still-ingesting remuxer (and its rewind spill window) to this
// manager instead of stopping it. Tuning the channel again ADOPTS the
// running remuxer, so the rewind timeline is complete - including the
// minutes spent away. Costs one concurrent upstream connection per
// retained channel, which is why it is opt-in and capped at 5.
@MainActor
final class LiveChannelRetention: ObservableObject {
    static let shared = LiveChannelRetention()

    struct Entry {
        let key: String            // resolved stream URL - the channel identity
        let channelID: String      // guide channel id (solo tile id) - the Jump target
        let channelName: String
        let remuxer: TSHLSRemuxer
        let localURL: URL          // loopback playlist URL (already READY)
        var lastActiveAt: Date
        var videoParams: (width: Int, height: Int, fps: Double, tenBit: Bool)?
    }
    @Published private(set) var entries: [Entry] = []

    private init() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main) { _ in
            Task { @MainActor in
                LiveChannelRetention.shared.stopAll(reason: "memory warning")
            }
        }
    }

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "liveRewindEnabled")
            && UserDefaults.standard.bool(forKey: "liveRewindRetainChannels")
    }
    /// User-facing "channels to keep going" INCLUDING the one playing.
    static var maxChannels: Int {
        let v = UserDefaults.standard.integer(forKey: "liveRewindRetainCount")
        return min(5, max(1, v == 0 ? 2 : v))
    }

    /// Take over a still-running remuxer from a tile that is going away.
    func retain(key: String, channelID: String, channelName: String, remuxer: TSHLSRemuxer, localURL: URL) {
        guard Self.isEnabled else { remuxer.stop(); return }
        // Replace a stale entry for the same channel outright.
        if let idx = entries.firstIndex(where: { $0.key == key || $0.channelID == channelID }) {
            entries[idx].remuxer.stop()
            entries.remove(at: idx)
        }
        remuxer.setRetained(true)
        remuxer.onReady = nil
        // The previous tile's handlers must not act for a retained channel:
        // its clean-close re-tune would restart whatever that tile shows
        // now. A retained connection never reconnects; a clean end (a
        // server-side terminate) releases it.
        remuxer.onFirstByte = nil
        remuxer.onIngestSilence = nil
        remuxer.reportsIngestStall = false
        remuxer.onIngestClosed = { [weak self] in
            Task { @MainActor in
                DebugLogger.shared.log(
                    "[AVP-RETAIN] retained '\(channelName)' ended by the server; released, no reconnect",
                    category: "Playback", level: .info)
                self?.drop(key: key)
            }
        }
        remuxer.onError = { [weak self] error in
            Task { @MainActor in
                DebugLogger.shared.log(
                    "[AVP-RETAIN] retained '\(channelName)' died (\(error)); dropping",
                    category: "Playback", level: .warning)
                self?.drop(key: key)
            }
        }
        let entry = Entry(key: key, channelID: channelID, channelName: channelName, remuxer: remuxer,
                          localURL: localURL, lastActiveAt: Date(), videoParams: nil)
        remuxer.onVideoParameters = { [weak self] w, h, fps, tenBit in
            Task { @MainActor in
                guard let self, let idx = self.entries.firstIndex(where: { $0.key == key }) else { return }
                self.entries[idx].videoParams = (w, h, fps, tenBit)
            }
        }
        entries.append(entry)
        DebugLogger.shared.log(
            "[AVP-RETAIN] keeping '\(channelName)' live in background (\(entries.count) retained, cap \(Self.maxChannels - 1))",
            category: "Playback", level: .info)
    }

    /// A tile tuning this channel takes the running remuxer back, if
    /// kept. Channel id is the PRIMARY match: the URL key can drift
    /// between the flip-away snapshot and a fresh tune's resolution,
    /// and a missed adopt leaves a stale duplicate ingesting upstream
    /// (field find 2026-08-27: ESPNU playing AND listed as retained).
    func adopt(key: String, channelID: String) -> Entry? {
        guard let idx = entries.firstIndex(where: { $0.channelID == channelID || $0.key == key }) else { return nil }
        var e = entries.remove(at: idx)
        e.lastActiveAt = Date()
        e.remuxer.setRetained(false)
        DebugLogger.shared.log(
            "[AVP-RETAIN] adopting '\(e.channelName)' (window intact; \(entries.count) still retained)",
            category: "Playback", level: .info)
        return e
    }

    /// A NEW channel is starting fresh: the active session takes one of
    /// the user's N slots, so retained entries shrink to N-1, oldest out
    /// ("open a 6th, the first drops off").
    func evictForNewActive(activeChannelID: String? = nil) {
        guard Self.isEnabled else { stopAll(reason: "retention disabled"); return }
        // Any entry for the channel being tuned is stale by definition
        // (the tile adopts BEFORE this runs; reaching here means adopt
        // missed or a duplicate survived) - kill it before it double-
        // ingests alongside the fresh session.
        if let id = activeChannelID, let idx = entries.firstIndex(where: { $0.channelID == id }) {
            let e = entries.remove(at: idx)
            e.remuxer.stop()
            LiveUpstreamReleases.note(e.key)
            DebugLogger.shared.log(
                "[AVP-RETAIN] dropped stale entry for now-active '\(e.channelName)'",
                category: "Playback", level: .warning)
        }
        let keep = Self.maxChannels - 1
        while entries.count > keep {
            if let idx = entries.indices.min(by: { entries[$0].lastActiveAt < entries[$1].lastActiveAt }) {
                let e = entries.remove(at: idx)
                e.remuxer.stop()
                LiveUpstreamReleases.note(e.key)
                DebugLogger.shared.log(
                    "[AVP-RETAIN] evicted oldest '\(e.channelName)' (over cap)",
                    category: "Playback", level: .info)
            } else { break }
        }
    }

    func drop(key: String) {
        guard let idx = entries.firstIndex(where: { $0.key == key }) else { return }
        entries[idx].remuxer.stop()
        LiveUpstreamReleases.note(key)
        entries.remove(at: idx)
    }

    func stopAll(reason: String) {
        guard !entries.isEmpty else { return }
        DebugLogger.shared.log(
            "[AVP-RETAIN] stopping all \(entries.count) retained channels (\(reason))",
            category: "Playback", level: .info)
        entries.forEach {
            $0.remuxer.stop()
            LiveUpstreamReleases.note($0.key)
        }
        entries.removeAll()
    }
}

/// Upstreams released in the last few seconds, by ANY tile or by channel
/// retention. Dispatcharr drops a provider connection asynchronously, so
/// re-opening a channel the app JUST let go of is what draws the 503
/// "max connections" (session.txt:3546-3550, 2026-09-11). Re-opening a
/// channel nobody was holding needs no such wait, which is why the flip
/// path settles only on a hit here (session3: every flip was paying a
/// blanket 1.16 s for a case that almost never applies).
@MainActor
enum LiveUpstreamReleases {
    private static var released: [(key: String, at: Date)] = []

    static func note(_ key: String) {
        prune()
        released.append((key: key, at: Date()))
    }

    static func releasedRecently(_ key: String, within: TimeInterval = 5) -> Bool {
        prune()
        return released.contains { $0.key == key && Date().timeIntervalSince($0.at) < within }
    }

    private static func prune() {
        released.removeAll { Date().timeIntervalSince($0.at) > 10 }
    }
}

/// Process-lifetime cache of a Dispatcharr channel's member-stream ids
/// (highest priority first), keyed by the channel's INTEGER pk. The
/// no-first-byte failover walk (s7_86.txt:353-395) must not spend a
/// round trip on the list every time it steps, and the list changes only
/// when the server's M3U sources are re-scanned.
@MainActor
enum LiveFailoverStreamCache {
    private static var byChannel: [Int: [Int]] = [:]

    static func cached(_ channelPK: Int) -> [Int]? {
        guard let ids = byChannel[channelPK], !ids.isEmpty else { return nil }
        return ids
    }

    static func store(_ ids: [Int], for channelPK: Int) {
        // Never cache an empty answer: the brief's refetch-if-empty rule.
        guard !ids.isEmpty else { return }
        byChannel[channelPK] = ids
    }
}

/// One 250 ms poll of whichever byte source a loading tile is using.
/// `connectedAt` is nil until the source's HTTP response has landed
/// (the AVPlayer access-log source has no such timestamp: it reports
/// connected with a nil date and the line times from its own clock).
struct LoadingDetailSample {
    var connected: Bool
    var bytes: Int64
    var connectedAt: Date?
}

/// The small line under a loading spinner that says what the network is
/// actually doing (Logan 2026-09-11: a slow server must LOOK like a slow
/// server instead of a broken player). Mounted only while the status
/// text is non-nil, so its own lifetime IS the "statusText went nil ->
/// non-nil" clock the 3 s delay is keyed to; a change between two
/// non-nil status texts leaves it mounted and the clock running.
struct LoadingDetailLine: View {
    /// Current status text, watched only for the failover step ("Trying
    /// another stream..."), which restarts the waiting counter.
    let statusText: String
    /// Polled on every tick; never captured, because the tile's byte
    /// source can be swapped out under it (failover, MKV -> direct).
    let sample: () -> LoadingDetailSample

    @State private var detail: String?
    @State private var appearedAt = Date()
    /// Fallback connection clock for sources with no response timestamp,
    /// and the failover step's restart point.
    @State private var stepStartedAt: Date?
    @State private var connectedFallbackAt: Date?
    private let tick = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(detail ?? " ")
            .scaledFont(.caption2)
            .foregroundColor(.white.opacity(0.55))
            .monospacedDigit()
            .lineLimit(1)
            .opacity(detail == nil ? 0 : 1)
            .onAppear { appearedAt = Date(); refresh() }
            .onReceive(tick) { _ in refresh() }
            .onChange(of: statusText) { _, new in
                if new.contains("Trying another stream") {
                    stepStartedAt = Date()
                    connectedFallbackAt = nil
                }
            }
    }

    private func refresh() {
        // Held back 3 s: a tune that completes promptly never shows a
        // line at all, so the detail only appears when there is genuinely
        // something to explain.
        guard Date().timeIntervalSince(appearedAt) >= 3.0 else {
            if detail != nil { detail = nil }
            return
        }
        let s = sample()
        var next: String
        if !s.connected {
            next = "Connecting to server"
        } else if s.bytes <= 0 {
            if connectedFallbackAt == nil { connectedFallbackAt = Date() }
            let base = [s.connectedAt, stepStartedAt, connectedFallbackAt]
                .compactMap { $0 }.max() ?? Date()
            let secs = max(0, Int(Date().timeIntervalSince(base)))
            next = "Waiting for stream data  \(secs) s"
        } else {
            next = Self.received(s.bytes)
        }
        if next != detail { detail = next }
    }

    /// KB below 1 MB, one decimal MB below 1024 MB, one decimal GB above.
    static func received(_ bytes: Int64) -> String {
        if bytes < 1_048_576 { return "Received \(bytes / 1024) KB" }
        let mb = Double(bytes) / 1_048_576
        if mb < 1024 { return String(format: "Received %.1f MB", mb) }
        return String(format: "Received %.1f GB", mb / 1024)
    }
}

/// Per-channel learned time-to-first-byte for the live silent-start
/// deadline (see `AVPlayerMultiviewTile.armFirstByteDeadline`).
///
/// Glitzbr 2026-09-15: over-the-air HDHomeRun channels through
/// Dispatcharr have to LOCK A TUNER before a single byte exists, and a
/// 12 s client deadline walked away from a working-but-slow source onto
/// much worse backups. A channel that has historically taken a long time
/// to produce its first byte earns a proportionally longer budget on
/// later tunes, with a ceiling so one pathological sample cannot stretch
/// the wait forever and a TTL so a one-off slow start is forgotten.
///
/// Storage is deliberately the SAME shape as `LiveEdgeHoldback`: a
/// UserDefaults dictionary of values plus a SEPARATE dictionary of learn
/// stamps, bounded entry count, expiry read by the reader. Device-local,
/// never synced: like the learned hold-back this is a property of THIS
/// device's network and provider path.
enum LiveFirstByteLearner {
    private static let defaultsKey = "playback.liveFirstByte"
    private static let learnedAtKey = "playback.liveFirstByteAt"

    /// Ceiling on a single learned sample (seconds).
    static let maxLearned: Double = 45
    /// Past this a learned value is ignored and relearned: a tuner's lock
    /// time is a property of the channel, not of one session.
    static let ttl: TimeInterval = 24 * 60 * 60
    /// A faster start pulls the learned value down by half the difference.
    private static let decayShare: Double = 0.5
    private static let maxEntries = 400

    /// This channel's learned time-to-first-byte in seconds, or nil when
    /// nothing is known or the value has expired.
    static func learned(for key: String) -> Double? {
        let map = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Double]
        guard let value = map?[key], value > 0 else { return nil }
        let stamps = UserDefaults.standard.dictionary(forKey: learnedAtKey) as? [String: Double]
        guard let stamp = stamps?[key] else { forget(key); return nil }
        let age = Date().timeIntervalSince1970 - stamp
        guard age >= 0, age < ttl else { forget(key); return nil }
        return value
    }

    /// Record a SUCCESSFUL time-to-first-byte. The stored value is a
    /// decayed maximum: a slower start raises it at once (that is the
    /// case we must not walk away from), a faster start pulls it down
    /// gradually, so one bad tune does not pin the channel and one good
    /// tune does not erase a genuinely slow tuner.
    static func record(_ seconds: Double, for key: String) {
        guard seconds > 0, !key.isEmpty else { return }
        var map = (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Double]) ?? [:]
        var stamps = (UserDefaults.standard.dictionary(forKey: learnedAtKey) as? [String: Double]) ?? [:]
        let now = Date().timeIntervalSince1970
        let previous = map[key]
        let expired = (now - (stamps[key] ?? 0)) > ttl
        let next: Double
        if let previous, !expired, seconds < previous {
            next = previous - (previous - seconds) * decayShare
        } else {
            next = seconds
        }
        let value = min(max(next, 0.001), maxLearned)
        map[key] = value
        stamps[key] = now
        if map.count > maxEntries { map = [key: value]; stamps = [key: now] }
        stamps = stamps.filter { map[$0.key] != nil }
        UserDefaults.standard.set(map, forKey: defaultsKey)
        UserDefaults.standard.set(stamps, forKey: learnedAtKey)
        debugLog(String(format: "[FAILOVER] learned first byte %.1fs (observed %.1fs, TTL %.0fh)",
                        value, seconds, ttl / 3600))
    }

    /// Drop one stale learned value with its stamp, so an expired entry
    /// is not re-read on every tune of that channel.
    private static func forget(_ key: String) {
        var map = (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Double]) ?? [:]
        var stamps = (UserDefaults.standard.dictionary(forKey: learnedAtKey) as? [String: Double]) ?? [:]
        guard map.removeValue(forKey: key) != nil || stamps.removeValue(forKey: key) != nil else { return }
        UserDefaults.standard.set(map, forKey: defaultsKey)
        UserDefaults.standard.set(stamps, forKey: learnedAtKey)
    }
}

struct AVPlayerMultiviewTile: View {
    /// The owning tile's id; mute state derives from comparing this to
    /// the store's audioTileID LIVE (never from a captured snapshot,
    /// see the audio note below).
    let tileID: String
    let streamURL: URL
    let headers: [String: String]
    let shouldPause: Bool
    let channelName: String
    /// The GUIDE channel id (tile.item.id). NOT tileID: a tile's id is
    /// pinned at seed and survives in-place channel flips, so it names
    /// the ORIGINAL channel forever - keying retention on it made the
    /// first flip adopt the just-retained old channel back (black
    /// screen, 2026-08-27). This is the retention identity and the
    /// Jump-to-Channel deep-link target.
    var channelID: String = ""
    /// Dispatcharr channel identity for the no-first-byte failover walk
    /// (s7_86.txt:353-395): the INTEGER pk keys the member-streams list,
    /// the uuid keys change_stream. Both nil off Dispatcharr Direct
    /// Connect, which leaves the tile on its existing retry path.
    var dispatcharrChannelPK: Int? = nil
    var dispatcharrChannelUUID: String? = nil

    /// VOD tile: route MP4 direct / MKV through MKVVODServer, apply the
    /// resume offset, and never treat the URL as a live TS stream.
    var isVOD: Bool = false
    /// In-progress server recording over its live-style HLS playlist.
    /// Plays direct (AVPlayer speaks HLS natively - no remuxer, no MKV
    /// server) with the driver in DVR-window mode: growing scrubber,
    /// live-edge default, exact seeks anywhere in the recorded window.
    var isDVR: Bool = false
    /// Resume offset handed straight from tile.resumePositionMs. The
    /// progress-store copy (explicitResumeMs) is applied by the PARENT
    /// view's onAppear, which fires AFTER this child's - so a player
    /// started synchronously in start() (direct HLS/MP4) read nil and
    /// never seeked (field find 2026-08-27: DVR resume landed at the
    /// live edge). The store copy still wins when present (version
    /// switches update it mid-session); this is the launch fallback.
    var resumePositionMs: Int32? = nil
    /// Catch-up replay payload (.catchup tiles): archive TS window with
    /// the mpv-parity re-tune seek model. The remuxer's single plain GET
    /// is exactly the transport contract the archive needs (one session,
    /// no range probes, no duration probe).
    var catchup: CatchupPlayback? = nil
    /// The per-tile store the container chrome binds to (scrubber,
    /// play-pause, track pickers, stream info). AVPlayerProgressDriver
    /// feeds it from this tile's AVPlayer, so the unified chrome works
    /// identically over an AVPlayer tile as over an mpv tile.
    let progressStore: PlayerProgressStore
    /// Solo/fullscreen tile: arm Picture in Picture on the video layer
    /// (grid tiles never PiP, mpv-path parity). Passed by the parent as
    /// isSoleTile so the flag tracks tile-count changes.
    var pipEnabled: Bool = false
    /// Parent flips this tile back to the mpv engine.
    let onEngineFallback: (String) -> Void

    @State private var player: AVPlayer?
    @State private var driver: AVPlayerProgressDriver?
    @State private var remuxer: TSHLSRemuxer?
    /// Live direct-HLS tile that failed on the server's redirect target
    /// (field 2026-09-03: a Redirect stream profile 302s to raw upstream
    /// TS, AVPlayer -11850): the same channel re-tuned once through the
    /// on-device TS remux, on the URL without the HLS upgrade.
    @State private var directHLSFallbackURL: URL?
    private var liveSourceURL: URL { directHLSFallbackURL ?? streamURL }
    @State private var mkvServer: MKVVODServer?
    @State private var statusText: String?
    /// Terminal playback failure shown when mpv is disabled: a plain
    /// English explanation plus the raw internal reason in small print
    /// (users report bugs with screenshots - the diagnostic line is the
    /// iteration hook). Distinct from statusText, which means loading.
    struct TileError {
        let title: String
        let message: String
        /// Which provider copy was playing ("#1 Primary · 8.0 Mbps"),
        /// nil outside a version-switching session. Field ask
        /// 2026-08-26: the card must say WHICH version failed.
        let version: String?
        let diagnostic: String
    }
    @State private var tileError: TileError?
    /// One silent re-index retry per stream URL for index/media
    /// mismatches (provider rotating the file behind the URL). Reset on
    /// URL change so every copy gets its own retry.
    /// Budget 2 (was a one-shot): Dispatcharr's per-connection VOD
    /// failover can serve a DIFFERENT provider copy under the same URL
    /// mid-session, so a fresh re-index can land on a copy whose cues
    /// disagree with the next connection's media again (field
    /// 2026-08-29, Thor #6: first mismatch retried at 1min, second at
    /// 3.6min went straight to the card). Two fresh pipelines before
    /// giving up absorbs a one-time flip AND a flip-back.
    @State private var mismatchAutoRetries = 0
    /// Server-busy (HTTP 502/503) retries at tile start, with backoff:
    /// Dispatcharr answers 503 while it is still tearing down the previous
    /// connection for the same channel (fullscreen -> multiview tile, fast
    /// swap-back), which takes a few seconds; three 1s retries all landed
    /// inside that window (FS1, Logan 2026-09-02).
    @State private var serverBusyRetries = 0
    /// Same-URL retries spent on Dispatcharr's "Channel is stopping,
    /// retry shortly" 503 (Logan 2026-09-12). That 503 is the proxy
    /// tearing down the PREVIOUS session for this channel - a cast that
    /// just ended, a fast flip back - so the same URL is the right URL;
    /// it only needs the teardown to drain. Reset on a user tune.
    @State private var channelStoppingRetries = 0
    /// Live Rewind armed for this tile: the remuxer was created with a
    /// spill window (solo live + setting on), so the driver runs in
    /// rewind-window mode and LiveRewindEngine mirrors the window for
    /// the chrome. Dropped when a second tile joins (grid chrome has no
    /// scrubber; the spill ring keeps running, disk-bounded).
    @State private var liveRewindArmed = false
    /// Identity of the session THIS tile is actually running, snapshotted
    /// at start(). stop() retains under these - NEVER under the struct's
    /// current streamURL/channelID, which a channel-flip onChange has
    /// already advanced to the INCOMING channel (two field black-screens
    /// from exactly that trap, 2026-08-27).
    @State private var sessionRetainKey: String?
    @State private var sessionRetainChannelID: String?
    @State private var sessionRetainName: String?
    /// Catch-up: programme-relative ms offset of the CURRENT window and
    /// the (re-minted/rebuilt) URL serving it. streamURL stays the
    /// original programme-start URL.
    @State private var catchupBaseMs: Int32 = 0
    @State private var catchupURL: URL?
    @State private var catchupMintInFlight = false
    @State private var lastCatchupReportAt = Date.distantPast
    /// Position of the last dead-pipeline reconnect; a fresh reconnect
    /// is allowed only after 15s of real progress past it.
    @State private var lastCatchupReconnectMs: Int32 = -1
    /// The pipeline was quiesced by didEnterBackground (PiP inactive):
    /// ingest + loopback sockets die under app suspension anyway, so the
    /// tile tears down CLEANLY on the way out (freeing the provider
    /// slot) instead of waking up to "ingest failed: The request timed
    /// out." + a -12888 stale playlist and the error card (field
    /// 2026-08-29). willEnterForeground rebuilds the pipeline.
    @State private var backgroundSuspended = false
    /// Position saved at quiesce for kinds that can resume in place.
    @State private var backgroundResumeMs: Int32 = 0
    /// Previous isPiPActive, to catch "PiP closed while the app is
    /// still backgrounded" - the ONE path where suspension arrives with
    /// no didEnterBackground left to quiesce for it.
    @State private var pipWasActive = false
    /// Harvested-cue subtitle state for MKV VOD playback (see
    /// AVPSubtitleCueStore). A class ref, so the server callbacks can
    /// capture it directly without the stale-struct hazard below.
    @StateObject private var subtitleStore = AVPSubtitleCueStore()
    /// AUDIO CORRECTNESS: the remuxer's onReady closure captures this
    /// view struct BY VALUE at start() time. Adding tiles moves
    /// audioTileID to the newest tile while older tiles' remuxers are
    /// still spinning up, so a closure that calls startPlayer directly
    /// would create the player from a STALE "I own audio" snapshot,
    /// unmuted. Multiple unmuted tiles was the audible result on
    /// device. Routing READY through @State (shared storage across
    /// struct copies) makes startPlayer run from onChange on the FRESH
    /// struct, and the mute decision reads the store at that moment.
    @State private var readyLocalURL: URL?
    /// KVO on the item's presentationSize; registers the tile's real
    /// video aspect with the store so the focus border hugs the video.
    @State private var sizeObservation: AnyCancellable?
    /// Fires a few seconds after start: if the item became ready but never
    /// reported a video size, the stream is audio-only to AVFoundation
    /// (e.g. HEVC carried in MPEG-TS HLS) and we fall the tile back to mpv.
    @State private var stallWatchdog: AVPStallWatchdog?
    #if os(iOS)
    /// AirPlay LAN handoff for this tile (2026-09-21 rebuild).
    @State private var airPlayDelivery = AirPlayTileDelivery()
    #endif
    #if os(tvOS)
    /// The display manager our criteria landed on, for teardown. Mirrors
    /// the mpv path's clearDisplayCriteria bookkeeping.
    @State private var appliedDisplayManager: AVDisplayManager?
    #endif
    /// Set by stop(). Device log 2026-09-03 18:33: Menu two seconds into
    /// an MKV movie tore the tile down, then the still-running prepare
    /// finished and applied HDR display criteria with no tile left to
    /// clear them (the panel stayed in HDR). Late applies are dropped.
    /// Declared on every platform (start/stop touch it unconditionally).
    @State private var tileStopped = false
    /// Clean-close reconnect ladder (immediate, 5 s, 15 s, 30 s, then 60 s)
    /// with "Reconnecting" showing. A live stream is never abandoned on a
    /// guess: only a VERIFIED session-limit reading stops it (see
    /// DispatcharrSessionLimitVerifier). Cleared with the failover walk
    /// (teardown / user tune) and by Retry.
    @State private var cleanEndPolicy = LiveCleanEndPolicy()
    /// When the session that is playing now was opened, for the verifier's
    /// "a newer session took our slot" test.
    @State private var liveSessionStartedAt = Date()
    /// Live stall state: the remuxer's latched silence signal, and the
    /// token that keeps exactly one buffer-evaluation loop running.
    @State private var ingestSilent = false
    @State private var stallEvalToken = UUID()
    /// Standing slow retry for a live tile whose fast retries ran out
    /// (review 2026-09-11 section 2 proposal 3): ESPNews HD died at
    /// 15:05:36 and the tile stayed dead for 5 minutes 6 seconds
    /// (session.txt:3610-3619) because nothing tried again. Cancelled by
    /// bumping `teardownToken` on teardown or a channel change.
    @State private var standingRetries = 0
    @State private var teardownToken = UUID()
    /// First-byte deadline / stream-failover walk (s7_86.txt:353-395).
    /// ESPN2 HD opened its ingest at 18:37:12 and delivered ZERO bytes:
    /// URLSession sat on its 30 s timeout, the auto-retry's fresh
    /// pipeline was silent for another 12 s, and Dispatcharr's own
    /// health checks cannot fail a connected-but-silent stream over for
    /// about 75 s (60 s channel_init_grace_period + 3 checks at 5 s).
    /// So the CLIENT walks the channel's member streams instead.
    @State private var firstByteSeen = false
    /// Re-rolled every time the deadline is armed; a fired timer whose
    /// token moved on is a stale one and does nothing.
    @State private var firstByteDeadlineToken = UUID()
    /// When the CURRENT silent-start deadline was armed, and the budget
    /// it is running with (seconds of SILENCE, see armFirstByteDeadline).
    @State private var firstByteArmedAt: Date?
    @State private var firstByteBudget: Double = 28
    /// When THIS tune first armed a deadline, so a learned
    /// time-to-first-byte measures the whole tap-to-first-byte rather
    /// than just the last walk step.
    @State private var tuneStartedAt: Date?
    /// Streams already walked this tune, so the walk never revisits one.
    @State private var failoverTriedStreamIDs: Set<Int> = []
    /// The stream the walk believes is live right now (seeded from
    /// /status.url on the first step, then from our own change_stream).
    @State private var failoverCurrentStreamID: Int?
    /// Steps taken this tune, for the recovery log line.
    @State private var failoverSteps = 0
    @State private var failoverInFlight = false
    @State private var failoverStartedAt: Date?
    /// Display-mode switch deferred until the first frame is on screen
    /// (review section 1 proposal 6): the HDMI mode change used to land
    /// mid-tune and stalled the remuxer for 3.99 s on the session's worst
    /// tune (session.txt:3375-3380).
    @State private var pendingDisplayCriteria: (width: Int, height: Int, fps: Double, tenBit: Bool)?
    @State private var firstFrameSeen = false
    /// Video Scale: gravity for this tile's layer, kept in step with the
    /// shared store (Fill only when this tile owns the whole screen and
    /// PiP is not driving it).
    @State private var tileGravity: AVLayerVideoGravity = .resizeAspect

    /// Single place the tile's video gravity is decided, so a device log
    /// proves a Video Scale pill actually reached the layer.
    private func applyTileGravity(mode: VideoAspectMode,
                                  allowsFill: Bool,
                                  pipActive: Bool) {
        let gravity: AVLayerVideoGravity =
            (allowsFill && !pipActive) ? mode.videoGravity : .resizeAspect
        tileGravity = gravity
        debugLog("[VIDEO-SCALE] applied \(mode.rawValue) gravity=\(gravity.rawValue) tile=\(tileID) allowsFill=\(allowsFill) pip=\(pipActive)")
    }

    var body: some View {
        ZStack {
            Color.black
            if let player {
                AVPlayerLayerView(player: player,
                                  videoGravity: tileGravity,
                                  pipStore: pipEnabled ? progressStore : nil)
                AVPSubtitleOverlay(store: subtitleStore, timeMs: {
                    let s = player.currentTime().seconds
                    return s.isFinite ? Int64(s * 1000) : 0
                }, videoAspect: { [tileID] in
                    MultiviewStore.shared.tileVideoAspects[tileID]
                })
            }
            if let statusText, tileError == nil {
                VStack(spacing: 8) {
                    ProgressView()
                    Text(statusText)
                        .scaledFont(.caption)
                        .foregroundColor(.white.opacity(0.8))
                    LoadingDetailLine(statusText: statusText) { loadingDetailSample() }
                }
            }
            if let tileError {
                VStack(spacing: 10) {
                    Image(systemName: "play.slash.fill")
                        .scaledFont(.system(size: 34, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                    Text(tileError.title)
                        .scaledFont(.headline)
                        .foregroundColor(.white)
                    Text(tileError.message)
                        .scaledFont(.subheadline)
                        .foregroundColor(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                    if let version = tileError.version {
                        Text("Version: \(version)")
                            .scaledFont(.caption)
                            .foregroundColor(.white.opacity(0.7))
                    }
                    Text(tileError.diagnostic)
                        .scaledFont(.caption2)
                        .foregroundColor(.white.opacity(0.45))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                }
                .padding(36)
            }
        }
        .onAppear {
            AudioSessionRefCount.increment(caller: "avp-tile")
            progressStore.liveStopRetryAction = { retryLiveStopNotice() }
            start()
        }
        .onDisappear {
            // Cancels any standing slow retry in flight.
            teardownToken = UUID()
            stop()
            progressStore.liveStopNotice = nil
            progressStore.liveStopRetryAction = nil
            // Tile teardown clears the stream-failover walk
            // (s7_86.txt:353-395).
            resetFailoverWalk()
            // Final teardown of a native catch-up session frees its
            // provider slot server-side (seek re-tunes revoke their own
            // predecessors; this covers the last window).
            if let cu = catchup, cu.nativeChannelUUID != nil {
                CatchupSupport.revokeNative(playback: cu, currentURL: catchupURL ?? streamURL)
            }
            AudioSessionRefCount.decrement(caller: "avp-tile")
        }
        #if os(iOS)
        // Background lifecycle (field 2026-08-29): quiesce cleanly on the
        // way out, rebuild on the way back. PiP-active sessions skip both
        // (iOS keeps the process running and the pipeline healthy).
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didEnterBackgroundNotification)) { _ in
            quiesceForBackground()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.willEnterForegroundNotification)) { _ in
            resumeFromBackground()
        }
        // PiP closed while still backgrounded: suspension follows with no
        // further lifecycle callback, so quiesce right here.
        .onReceive(progressStore.$isPiPActive) { active in
            applyTileGravity(mode: progressStore.aspectMode,
                             allowsFill: progressStore.allowsVideoFill,
                             pipActive: active)
            if pipWasActive, !active,
               UIApplication.shared.applicationState == .background {
                debugLog("[AVP-PIP] closed while backgrounded; quiescing pipeline")
                quiesceForBackground()
            }
            pipWasActive = active
        }
        #endif
        // Remux READY lands here with fresh property values.
        .onChange(of: readyLocalURL) { _, url in
            guard let url else { return }
            statusText = nil
            #if os(iOS)
            // AirPlay route already selected: resolve the receiver, plan
            // the audio and start on the LAN URL instead (plan 4c).
            if MultiviewStore.shared.audioTileID == tileID, let mux = remuxer,
               airPlayDelivery.prepareStart(remuxer: mux, loopbackURL: url, channelName: channelName,
                                            start: { startURL, lanAAC in
                                                // The tile moved on while the receiver resolved.
                                                guard readyLocalURL == url, player == nil else { return }
                                                startPlayer(url: startURL, requestHeaders: [:], lanAAC: lanAAC)
                                            }) {
                debugLog("[AVP-MV] tile playing REMUXED channel=\(channelName) muted=false")
                return
            }
            #endif
            startPlayer(url: url, requestHeaders: [:])
            debugLog("[AVP-MV] tile playing REMUXED channel=\(channelName) muted=\(player?.isMuted == true)")
        }
        // Clear the VOD "Buffering..." spinner the moment the playhead
        // actually advances (the driver's periodic observer writes
        // currentMs for VOD only, so live is untouched).
        // Video Scale: follow the shared aspect + solo-tile eligibility.
        .onReceive(progressStore.$aspectMode) { mode in
            applyTileGravity(mode: mode,
                             allowsFill: progressStore.allowsVideoFill,
                             pipActive: progressStore.isPiPActive)
        }
        .onReceive(progressStore.$allowsVideoFill) { allowsFill in
            applyTileGravity(mode: progressStore.aspectMode,
                             allowsFill: allowsFill,
                             pipActive: progressStore.isPiPActive)
        }
        .onReceive(progressStore.$currentMs) { ms in
            if ms > 0, statusText == "Buffering..." { statusText = nil }
            // Native catch-up sessions want periodic position reports
            // (server-side resume + session keepalive), mpv parity 20s.
            if let cu = catchup, cu.nativeChannelUUID != nil, ms > 0,
               Date().timeIntervalSince(lastCatchupReportAt) >= 20 {
                lastCatchupReportAt = Date()
                let url = catchupURL ?? streamURL
                let paused = progressStore.isPaused
                Task {
                    _ = await CatchupSupport.reportNativePosition(
                        playback: cu, currentURL: url,
                        positionSecs: Double(ms) / 1000.0, paused: paused)
                }
            }
        }
        // Mute follows the store's published audio owner directly:
        // independent of SwiftUI prop diffing, fires for every change,
        // and uses the EMITTED value (the store property itself is
        // willSet-old inside this handler).
        .onReceive(MultiviewStore.shared.$audioTileID) { newAudioID in
            player?.isMuted = (newAudioID != tileID)
        }
        .onChange(of: shouldPause) { _, paused in
            if paused { player?.pause() } else { player?.play() }
        }
        // In-place channel swap on the same tile id (the container
        // swaps `tile.streamURL` without changing tile identity).
        .onChange(of: streamURL) { oldURL, newURL in
            mismatchAutoRetries = 0
            serverBusyRetries = 0
            channelStoppingRetries = 0
            standingRetries = 0
            teardownToken = UUID()
            // User-initiated tune: the incoming channel starts its own
            // stream-failover walk (s7_86.txt:353-395).
            resetFailoverWalk()
            // Channel-flip ordering (review 2026-09-11 section 2 proposals
            // 1 and 2). session.txt:3546-3547: the flip STOPPED the
            // ESPNews upstream and re-opened the SAME channel in the
            // identical millisecond; Dispatcharr still held the old
            // connection, answered 503 six times, and the tile died for
            // five minutes. The fix that matters is ORDER - release, wait
            // for the confirmed teardown, then acquire.
            //
            // Narrowed 2026-09-11 (session3): the blanket 1 s settle on
            // top of that cost every flip 1.16 s before the ingest even
            // started, for a hazard that only exists when the app itself
            // was holding the TARGET channel moments ago. So: no wait at
            // all in the normal case, and 2 s only when this tile or
            // channel retention released that same upstream inside the
            // last 5 s.
            let justReleased = LiveUpstreamReleases.releasedRecently(newURL.absoluteString)
            LiveUpstreamReleases.note(oldURL.absoluteString)
            let settle = justReleased ? 2.0 : 0.0
            let outgoing = remuxer
            let token = teardownToken
            stop()
            statusText = "Tuning..."
            let resume = {
                let go = {
                    guard token == teardownToken else { return }
                    debugLog("[AVP-MV] flip start after confirmed teardown "
                        + "(\(justReleased ? "2.0s settle: target released <5s ago" : "no settle: target was not ours")) "
                        + "channel=\(channelName)")
                    start()
                }
                if settle > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + settle, execute: go)
                } else {
                    go()
                }
            }
            // stop() hands a healthy rewind session to channel retention
            // (Keep Recent Channels Live) instead of stopping it; stopping
            // `outgoing` here would kill the channel just retained.
            if let outgoing,
               !LiveChannelRetention.shared.entries.contains(where: { $0.remuxer === outgoing }) {
                outgoing.stop { resume() }
            } else {
                resume()
            }
        }
        // A second tile joining drops the rewind UI (grid chrome has no
        // scrubber; mpv parity - its relay falls back to direct too).
        // Switch Stream (live remux tile). The unified single-tile player
        // is this tile, not NativeHLSPlayerScreen, so the reprime must be
        // observed here too. Dispatcharr keeps the socket; arm the
        // remuxer's re-gate on the ingest actually reading that channel.
        .onReceive(NotificationCenter.default.publisher(for: .switchStreamReprime)) { note in
            guard let uuid = note.userInfo?["uuid"] as? String else {
                debugLog("[SWITCH] AVP tile ignored reprime: no uuid"); return
            }
            guard let mux = remuxer else {
                debugLog("[SWITCH] AVP tile ignored reprime: no remuxer (channel=\(channelName))"); return
            }
            guard mux.ingestURL.absoluteString.contains("/proxy/ts/stream/\(uuid)") else {
                debugLog("[SWITCH] AVP tile ignored reprime: ingest url is not /proxy/ts/stream/\(uuid) (channel=\(channelName))"); return
            }
            debugLog("[SWITCH] kept connection (AVPlayer remux tile) channel=\(channelName)")
            mux.noteSourceSwitch()
        }
        .onReceive(NotificationCenter.default.publisher(for: .aerioLiveRewindDropRelay)) { _ in
            guard liveRewindArmed else { return }
            liveRewindArmed = false
            driver?.liveRewindWindowActive = false
            LiveRewindEngine.shared.endExternalWindow(owner: tileID)
            debugLog("[AVP-REWIND] window dropped (second tile)")
        }
        // Catch-up: EOF of the finalized downloaded window with programme
        // left = re-tune a fresh session at the playhead. A real
        // programme end (within 30s of the pinned duration) just stops.
        .onReceive(NotificationCenter.default.publisher(
            for: .AVPlayerItemDidPlayToEndTime)) { note in
            guard let cu = catchup,
                  let ended = note.object as? AVPlayerItem,
                  ended === player?.currentItem else { return }
            let pos = progressStore.currentMs
            if pos < cu.programDurationMs - 30_000 {
                debugLog("[AVP-CU] downloaded window exhausted at \(pos / 1000)s; re-tuning for the next window")
                statusText = "Loading..."
                retuneCatchupWindow(pos, cu)
            } else {
                debugLog("[AVP-CU] programme complete at \(pos / 1000)s")
            }
        }
        // Direct-HLS playback failures have no remuxer to report them;
        // catch the item-level failure and fall back to mpv.
        .onReceive(NotificationCenter.default.publisher(
            for: .AVPlayerItemFailedToPlayToEndTime)) { note in
            guard let failed = note.object as? AVPlayerItem,
                  failed === player?.currentItem else { return }
            debugLog("[AVP-MV] tile playback failed channel=\(channelName); falling back to mpv tile")
            failOrFallback("playback failed")
        }
    }

    /// 503/502 backoff ladder. See the call site in failOrFallback.
    private static let serverBusyDelays: [Double] = [2, 5, 10, 20, 40]
    /// Slow standing retry cadence after the fast ladder is spent: 15 s,
    /// 30 s, then every 60 s, for as long as the tile is mounted and
    /// still showing the user's channel.
    private static let standingRetryDelays: [Double] = [15, 30]

    /// A live tile is never permanently abandoned (review 2026-09-11
    /// section 2 proposal 3). Cancelled by `teardownToken` on teardown
    /// or a channel change, so nothing survives the tile.
    private func scheduleStandingRetry(_ reason: String, serverReason: String? = nil) {
        let delay = standingRetries < Self.standingRetryDelays.count
            ? Self.standingRetryDelays[standingRetries] : 60
        standingRetries += 1
        stop()
        // Copy rule (Logan 2026-09-12): quote the server when it said
        // something, and say nothing about a cause when it did not. The
        // old line claimed "Too many connections" for every 503, which
        // Dispatcharr never states.
        statusText = serverReason.map { Self.serverStatus($0, "Reconnecting...") } ?? "Reconnecting..."
        let token = teardownToken
        debugLog("[AVP-MV] standing retry #\(standingRetries) in \(delay)s (\(reason)) channel=\(channelName)")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard token == teardownToken,
                  MultiviewStore.shared.tiles.contains(where: {
                      $0.id == tileID && $0.streamURL == streamURL
                  }) else {
                debugLog("[AVP-MV] standing retry dropped (tile gone or channel changed)")
                return
            }
            start()
        }
    }

    // MARK: - Live ingest stall ("Reconnecting", Android parity 2026-09-14)

    /// Status copy this tile owns for a mid-stream stall. Compared by
    /// value so the clear never wipes a status some other path put up.
    private static let reconnectingStatus = "Reconnecting..."

    /// Live tunes only: arm the remuxer's 2 s silence signal and its
    /// clean-close signal.
    private func attachLiveStallHandlers(_ mux: TSHLSRemuxer) {
        guard !isVOD, !isDVR, catchup == nil else { return }
        mux.reportsIngestStall = true
        mux.onIngestSilence = { silent in handleIngestSilence(silent) }
        mux.onIngestClosed = { handleUpstreamClosed() }
    }

    /// Bytes stopped (or resumed) on a channel that is already playing.
    ///
    /// Silence ALONE is not a stall: Dispatcharr's proxy delivers this
    /// stream in 8 to 9.5 s bursts while playback is perfect with ~10 s
    /// buffered (Android log analysis 2026-09-14), so a bare 2 s gap
    /// would flash "Reconnecting" during healthy playback. Even a low
    /// buffer is only "starving": the overlay waits for playback itself to
    /// stop (a rebuffer, the playhead frozen >= 1 s, or an empty buffer)
    /// and clears as soon as the playhead advances again.
    private func handleIngestSilence(_ silent: Bool) {
        guard tileError == nil, !tileStopped else { return }
        ingestSilent = silent
        if silent {
            guard firstFrameSeen else { return }
            stallEvalToken = UUID()
            evaluateStallOverlay(token: stallEvalToken)
        }
        // Bytes resuming does not clear the overlay by itself: a running
        // evaluator hides it once the playhead actually advances again.
    }

    /// Seconds of media loaded ahead of the playhead, or nil when the
    /// item cannot answer yet.
    private func loadedAheadSeconds() -> Double? {
        guard let item = player?.currentItem,
              let range = item.loadedTimeRanges.last?.timeRangeValue else { return nil }
        let end = CMTimeGetSeconds(CMTimeAdd(range.start, range.duration))
        let now = CMTimeGetSeconds(item.currentTime())
        guard end.isFinite, now.isFinite else { return nil }
        return max(0, end - now)
    }

    /// Re-evaluates the overlay every 0.5 s for as long as the ingest is
    /// silent; the silence signal itself only latches at its edges.
    private func evaluateStallOverlay(token: UUID, lastPosition: Double? = nil,
                                      lastAdvance: Date = Date(), sawAdvance: Bool = false) {
        guard token == stallEvalToken, tileError == nil, !tileStopped else { return }
        guard ingestSilent || statusText == Self.reconnectingStatus else { return }
        guard let player else { return }
        let ahead = loadedAheadSeconds() ?? 0
        let position = player.currentItem.map { CMTimeGetSeconds($0.currentTime()) } ?? .nan
        let advanced = position.isFinite && lastPosition != nil && position != lastPosition
        let now = Date()
        let advanceAt = (advanced || lastPosition == nil) ? now : lastAdvance
        let wantsToPlay = player.timeControlStatus != .paused
        let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        let frozen = wantsToPlay && !advanced && now.timeIntervalSince(advanceAt) >= Self.stallFrozenSeconds
        let empty = wantsToPlay && ingestSilent && ahead < Self.stallEmptyBuffer
        let stalled = (waiting && (sawAdvance || advanced)) || frozen || empty
        if statusText == nil, stalled {
            statusText = Self.reconnectingStatus
            debugLog("[AVP-STREAM] STALL: playback stalled (status=\(player.timeControlStatus.rawValue), frozen=\(frozen)) with "
                + "\(String(format: "%.1f", ahead))s loaded ahead; showing Reconnecting channel=\(channelName)")
        } else if statusText == Self.reconnectingStatus, advanced, !waiting {
            statusText = nil
            debugLog("[AVP-STREAM] playback advancing with \(String(format: "%.1f", ahead))s ahead; "
                + "cleared Reconnecting channel=\(channelName)")
        }
        let next = stallEvalToken
        let pos: Double? = position.isFinite ? position : lastPosition
        let saw = sawAdvance || advanced
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            evaluateStallOverlay(token: next, lastPosition: pos, lastAdvance: advanceAt, sawAdvance: saw)
        }
    }

    /// Overlay thresholds. Silence plus a low buffer (under 1.5 s) is only
    /// "starving" and routinely happens between Dispatcharr bursts while the
    /// picture plays perfectly (Streamer 2026-09-14), so the overlay needs a
    /// REAL stall: a rebuffer after playing, the playhead frozen this long
    /// while playback is requested, or the buffer effectively empty.
    private static let stallFrozenSeconds: Double = 1
    private static let stallEmptyBuffer: Double = 0.25

    /// The upstream closed cleanly (server-side stop). A closed socket is
    /// proof, not a guess, so this re-tunes at once rather than letting
    /// the silence/stale-frame ladder run its course.
    private func handleUpstreamClosed() {
        guard tileError == nil, !tileStopped, progressStore.liveStopNotice == nil else { return }
        let firstEnd = cleanEndPolicy.isFirstEnd
        let sessionStartedAt = liveSessionStartedAt
        let delay = cleanEndPolicy.nextDelay()
        debugLog("[RECONNECT] upstream closed the live stream; attempt \(cleanEndPolicy.attempts) "
            + "in \(Int(delay))s channel=\(channelName)")
        // Never hand the dead remuxer to channel retention: start() would
        // adopt it back and sit on a closed ingest. stop() cancels it; the
        // fresh ingest's startIngest waits for that cancel to land
        // (LiveConnectionRegistry), so the re-tune cannot overlap it.
        stop(allowRetain: false)
        statusText = Self.reconnectingStatus
        let token = teardownToken
        // From the SECOND clean end on, ask Dispatcharr whether this
        // account is actually at its session limit with a newer session
        // elsewhere. Only that verified answer stops the reconnects.
        if !firstEnd {
            Task { @MainActor in
                let verdict = await DispatcharrSessionLimitVerifier.verify(sessionStartedAt: sessionStartedAt)
                debugLog("[VERIFY] clean end check: \(verdict.logText) channel=\(channelName)")
                guard token == teardownToken, case .atLimit = verdict else { return }
                showLiveStopNotice(.streamEnded, reason: "verified session limit reached elsewhere")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(delay, 0.5)) {
            guard token == teardownToken, progressStore.liveStopNotice == nil else {
                debugLog("[RECONNECT] upstream-close re-tune dropped (channel changed, tile gone or stopped)")
                return
            }
            start()
        }
    }

    // MARK: - Live stop notice (connection limit / reconnect bounce)

    /// Stops the pipeline for good and shows the notice. No retry, no
    /// failover walk, no Reconnecting status: the connection is released
    /// and the tile waits for Retry.
    private func showLiveStopNotice(_ notice: LiveStopNotice, reason: String) {
        guard progressStore.liveStopNotice == nil else { return }
        debugLog("[LIMIT] \(notice.kind.rawValue) (\(reason)); connection released, waiting for Retry channel=\(channelName)")
        // Cancels every scheduled retry (standing, 503 ladders, deadlines).
        teardownToken = UUID()
        failoverInFlight = false
        firstByteDeadlineToken = UUID()
        stop(allowRetain: false)
        statusText = nil
        progressStore.liveStopNotice = notice
    }

    /// Retry button of the notice: one fresh tune of the same channel.
    private func retryLiveStopNotice() {
        guard progressStore.liveStopNotice != nil else { return }
        debugLog("[LIMIT] Retry pressed channel=\(channelName)")
        progressStore.liveStopNotice = nil
        teardownToken = UUID()
        resetFailoverWalk()
        cleanEndPolicy.reset()
        mismatchAutoRetries = 0
        serverBusyRetries = 0
        channelStoppingRetries = 0
        standingRetries = 0
        start()
    }

    // MARK: - No-first-byte stream failover (s7_86.txt:353-395)

    /// Seconds a live ingest may stay connected-but-SILENT on the FIRST
    /// attempt of a tune before the client starts walking the channel's
    /// other streams. Deliberately SEPARATE from the ingest's 30 s
    /// URLSession request timeout, which stays where the Freyguy
    /// first-bytes-patience comment put it.
    ///
    /// Was 12 s. Raised 2026-09-15 (Glitzbr, over-the-air HDHomeRun
    /// tuners through Dispatcharr): a tuner has to LOCK before a single
    /// byte exists, and 12 s walked a working channel onto much worse
    /// backups.
    private static let firstTuneFirstByteDeadline: Double = 28

    /// Budget for every ingest AFTER the first of a tune. The server has
    /// already swapped a stream in behind the same connection, so there
    /// is no tuner lock left to wait for and failover stays responsive.
    private static let stepFirstByteDeadline: Double = 12

    /// Hard ceiling on a learned-stretched budget.
    private static let firstByteBudgetMax: Double = 45

    /// A channel learned to start slowly gets 1.5x its learned
    /// time-to-first-byte (never less than the base budget).
    private static let learnedFirstByteHeadroom: Double = 1.5

    /// How often the deadline re-checks silence.
    private static let silencePollInterval: Double = 0.5

    /// Live tune only. Arms (or re-arms, after a failover step) the
    /// deadline; the remuxer's onFirstByte disarms it.
    ///
    /// The wait measures SILENCE, not wall clock: each poll restarts the
    /// budget from the last ingest byte, so a slow but live feed is
    /// never abandoned.
    private func armFirstByteDeadline(firstAttempt: Bool = true) {
        guard !isVOD, !isDVR, catchup == nil else { return }
        firstByteSeen = false
        firstByteDeadlineToken = UUID()
        let armedAt = Date()
        firstByteArmedAt = armedAt
        if firstAttempt { tuneStartedAt = armedAt }
        let key = liveSourceURL.absoluteString
        let learned = LiveFirstByteLearner.learned(for: key)
        let budget: Double
        if firstAttempt {
            let stretched = (learned ?? 0) * Self.learnedFirstByteHeadroom
            budget = min(max(Self.firstTuneFirstByteDeadline, stretched), Self.firstByteBudgetMax)
        } else {
            budget = Self.stepFirstByteDeadline
        }
        firstByteBudget = budget
        debugLog(String(format: "[FAILOVER] channel=%@ silent-start budget %.0fs (learned %@, %@)",
                        channelName, budget,
                        learned.map { String(format: "%.1fs", $0) } ?? "none",
                        firstAttempt ? "first attempt" : "walk step"))
        pollFirstByteSilence(deadlineToken: firstByteDeadlineToken,
                             token: teardownToken, armedAt: armedAt, budget: budget)
    }

    /// One tick of the silent-start poll. Re-schedules itself until a
    /// byte lands (any byte, not just the first) or the ingest has been
    /// quiet for the whole budget.
    private func pollFirstByteSilence(deadlineToken: UUID, token: UUID,
                                      armedAt: Date, budget: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.silencePollInterval) {
            guard token == teardownToken, deadlineToken == firstByteDeadlineToken,
                  !firstByteSeen, !tileStopped, tileError == nil else { return }
            // Bytes from BEFORE this arm (a re-armed deadline on the same
            // open ingest) must not count as activity for this attempt.
            let lastByte = remuxer?.lastIngestByteAt
            let since = Date().timeIntervalSince(max(armedAt, lastByte ?? armedAt))
            guard since >= budget else {
                pollFirstByteSilence(deadlineToken: deadlineToken, token: token,
                                     armedAt: armedAt, budget: budget)
                return
            }
            handleNoFirstByte(silentFor: since)
        }
    }

    /// The budget the current deadline is running with, for the logs and
    /// the walk's reason text.
    private var firstByteDeadlineText: String {
        String(format: "no bytes for %.0fs", firstByteBudget)
    }

    /// Wipes the walk. Called on teardown and on every user-initiated
    /// tune, so a new channel never inherits the old channel's tried set.
    private func resetFailoverWalk() {
        cleanEndPolicy.reset()
        ingestSilent = false
        stallEvalToken = UUID()
        firstByteDeadlineToken = UUID()
        firstByteSeen = false
        failoverTriedStreamIDs.removeAll()
        failoverCurrentStreamID = nil
        failoverSteps = 0
        failoverInFlight = false
        failoverStartedAt = nil
        firstByteArmedAt = nil
        tuneStartedAt = nil
    }

    /// The remuxer delivered its first byte: disarm, and if we had
    /// already stepped the walk, say what recovered us.
    private func noteFirstByte() {
        guard !firstByteSeen else { return }
        firstByteSeen = true
        firstByteDeadlineToken = UUID()
        // Learn only clean successes on this channel's own stream: a time
        // measured after a change_stream walk is the backup's, not this
        // channel's normal tuner-lock time.
        if failoverSteps == 0, let started = tuneStartedAt {
            let ttfb = Date().timeIntervalSince(started)
            if ttfb > 0 {
                debugLog(String(format: "[FAILOVER] channel=%@ firstByte in %.1fs; learning",
                                channelName, ttfb))
                LiveFirstByteLearner.record(ttfb, for: liveSourceURL.absoluteString)
            }
        }
        if failoverSteps > 0 {
            let ms = failoverStartedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0
            let id = failoverCurrentStreamID.map(String.init) ?? "unknown"
            debugLog("[FAILOVER] channel=\(channelName) recovered on stream id=\(id) after \(ms)ms")
        }
        // statusText is cleared by the normal ready/first-frame path.
    }

    /// Can this tile drive Dispatcharr's change_stream? Direct Connect,
    /// admin account, and a channel identity to key both endpoints.
    private func failoverServer() -> ServerConnection? {
        guard dispatcharrChannelPK != nil,
              let uuid = dispatcharrChannelUUID, !uuid.isEmpty,
              let server = ChannelStore.shared.activeServer,
              server.type == .dispatcharrAPI,
              server.dispatcharrCanSwitchStream else { return nil }
        return server
    }

    /// Deadline fired: the ingest has been silent for the whole budget.
    private func handleNoFirstByte(silentFor silentSeconds: Double) {
        guard !failoverInFlight else { return }
        guard let server = failoverServer(),
              let pk = dispatcharrChannelPK,
              let uuid = dispatcharrChannelUUID else {
            // Non-admin, Xtream/M3U, or a single-stream channel: nothing
            // to fail over TO. Say the tile is working on it and leave
            // the 30 s URLSession timeout plus the existing retry ladder
            // exactly as they are.
            statusText = "Reconnecting..."
            debugLog(String(format: "[FAILOVER] channel=%@ no bytes for %.0fs (budget %.0fs); "
                + "no switchable streams, staying on the retry path",
                            channelName, silentSeconds, firstByteBudget))
            return
        }
        failoverInFlight = true
        if failoverStartedAt == nil { failoverStartedAt = Date() }
        debugLog(String(format: "[FAILOVER] channel=%@ no bytes for %.0fs (budget %.0fs); "
            + "walking to the next stream", channelName, silentSeconds, firstByteBudget))
        Task { @MainActor in
            defer { failoverInFlight = false }
            await stepFailover(server: server, channelPK: pk, channelUUID: uuid)
        }
    }

    /// One step of the walk: resolve the list, mark where we are, POST
    /// change_stream for the next untried entry, re-arm the deadline.
    /// The ingest connection is deliberately LEFT OPEN - Dispatcharr
    /// swaps the upstream in place behind the proxy connection (see
    /// DispatcharrAPI.changeStream), so tearing it down here would only
    /// cost us the connection and revert the channel to its default.
    @MainActor
    private func stepFailover(server: ServerConnection, channelPK: Int, channelUUID: String,
                              serverReason: String? = nil,
                              restartPipeline: Bool = false) async {
        guard let api = SwitchStreamFlow.makeAPI(server: server) else { return }
        // Every status line in the walk quotes the server's reason when we
        // have one (the 503 entry point) and says nothing about a cause
        // when we do not (the silent-stream entry point).
        let say: (String) -> Void = { tail in
            statusText = serverReason.map { Self.serverStatus($0, tail) } ?? tail
        }
        var ids: [Int]
        if let cached = LiveFailoverStreamCache.cached(channelPK) {
            ids = cached
        } else {
            guard let fetched = try? await api.getChannelStreams(channelID: channelPK) else {
                debugLog("[FAILOVER] channel=\(channelName) stream list unavailable; staying on the retry path")
                say("Reconnecting...")
                return
            }
            ids = fetched.map(\.id)
            LiveFailoverStreamCache.store(ids, for: channelPK)
        }
        guard tileError == nil, !tileStopped, !firstByteSeen else { return }
        guard ids.count >= 2 else {
            say("Reconnecting...")
            debugLog("[FAILOVER] channel=\(channelName) single stream; staying on the retry path")
            return
        }
        // Seed "where are we" once. /status.url is the trustworthy field
        // (stream_id goes stale on the event path), but the streams list
        // is keyed by id, so we resolve the id by status and fall back to
        // the highest-priority entry when the read does not land in 3 s.
        if failoverCurrentStreamID == nil {
            failoverCurrentStreamID = await currentStreamID(api: api, channelUUID: channelUUID) ?? ids[0]
        }
        if let current = failoverCurrentStreamID { failoverTriedStreamIDs.insert(current) }
        let startIndex = failoverCurrentStreamID.flatMap { ids.firstIndex(of: $0) } ?? 0
        // Walk forward from the current entry, wrapping once; the tried
        // set is what guarantees we never revisit a stream.
        var next: Int?
        for offset in 1...ids.count {
            let candidate = ids[(startIndex + offset) % ids.count]
            if !failoverTriedStreamIDs.contains(candidate) { next = candidate; break }
        }
        guard let target = next else {
            debugLog("[FAILOVER] channel=\(channelName) exhausted \(ids.count) streams")
            scheduleStandingRetry(firstByteDeadlineText, serverReason: serverReason)
            // scheduleStandingRetry's generic copy is wrong here: the
            // streams all answered, none of them delivered. With a server
            // reason in hand, its own words stay in front of the user.
            if serverReason == nil { statusText = "Channel unavailable. Retrying..." }
            return
        }
        failoverSteps += 1
        failoverTriedStreamIDs.insert(target)
        let step = failoverSteps
        do {
            _ = try await api.changeStream(channelUUID: channelUUID, streamID: target)
        } catch {
            debugLog("[FAILOVER] channel=\(channelName) change_stream to id=\(target) failed: "
                + error.localizedDescription)
            say("Reconnecting...")
            return
        }
        guard tileError == nil, !tileStopped, !firstByteSeen else { return }
        failoverCurrentStreamID = target
        say("Trying another stream...")
        // No owner= field here: change_stream already logs the server's
        // own owner flag ([SwitchStream] change_stream ... owner=).
        debugLog("[FAILOVER] channel=\(channelName) stream \(step)/\(ids.count) id=\(target) "
            + "reason=\(serverReason ?? "\(firstByteDeadlineText) within the silent-start budget")")
        // The silent-stream entry point deliberately LEAVES the ingest
        // open (Dispatcharr swaps the upstream in place behind it). The
        // 503 entry point has no connection at all - the response WAS the
        // failure - so that one needs a fresh pipeline, which arms its own
        // first-byte deadline inside start().
        if restartPipeline {
            stop()
            let token = teardownToken
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard token == teardownToken else {
                    debugLog("[FAILOVER] post-switch start dropped (channel changed or tile gone)")
                    return
                }
                start()
            }
            return
        }
        armFirstByteDeadline(firstAttempt: false)
    }

    // MARK: - Dispatcharr 503 reasons (Logan 2026-09-12)

    /// Same-URL waits allowed on "Channel is stopping, retry shortly".
    private static let channelStoppingMaxRetries = 5
    /// Cap on the server's Retry-After, so a generous header cannot park
    /// a live tile on a spinner.
    private static let channelStoppingMaxDelay: Double = 3

    /// Pulls Dispatcharr's own explanation out of an ingest-failure
    /// reason built by TSHLSRemuxer.failWithIngestError. nil for anything
    /// that is not a live ingest 503 - notably the VOD "range fetch HTTP
    /// 503" text, whose terminal card is unrelated.
    private static func parse503(_ reason: String) -> (serverReason: String?, retryAfter: Double?)? {
        guard reason.contains("ingest failed: HTTP 503") else { return nil }
        var serverReason: String?
        var retryAfter: Double?
        for field in reason.components(separatedBy: " | ") {
            if field.hasPrefix("reason=") {
                let text = String(field.dropFirst("reason=".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { serverReason = text }
            } else if field.hasPrefix("retryAfter=") {
                retryAfter = Double(field.dropFirst("retryAfter=".count))
            }
        }
        return (serverReason, retryAfter)
    }

    /// The server's sentence, quoted verbatim apart from its first letter
    /// and a trailing period, then what the tile is doing about it.
    private static func serverStatus(_ serverReason: String, _ tail: String) -> String {
        var text = serverReason.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(".") { text = String(text.dropLast()) }
        guard let first = text.first else { return tail }
        return "Server: \(first.uppercased())\(text.dropFirst()). \(tail)"
    }

    /// A 503 the server explained as "nothing available here" (no
    /// available streams, a specific upstream error_reason it already
    /// waited on, or resources unavailable). A backoff ladder cannot
    /// help: Dispatcharr has already walked this channel's streams
    /// itself. So run the existing failover walk right now where we are
    /// allowed to drive change_stream, and the standing slow retry where
    /// we are not.
    private func handle503Unavailable(reason: String, serverReason: String) {
        guard let server = failoverServer(),
              let pk = dispatcharrChannelPK,
              let uuid = dispatcharrChannelUUID else {
            debugLog("[FAILOVER] 503 reason=\"\(serverReason)\" -> standing retry channel=\(channelName)")
            scheduleStandingRetry(reason, serverReason: serverReason)
            return
        }
        guard !failoverInFlight else { return }
        debugLog("[FAILOVER] 503 reason=\"\(serverReason)\" -> next stream channel=\(channelName)")
        failoverInFlight = true
        if failoverStartedAt == nil { failoverStartedAt = Date() }
        stop()
        statusText = Self.serverStatus(serverReason, "Trying another stream...")
        Task { @MainActor in
            defer { failoverInFlight = false }
            await stepFailover(server: server, channelPK: pk, channelUUID: uuid,
                               serverReason: serverReason, restartPipeline: true)
        }
    }

    /// `/status.streamID` with a 3 s cap. The change_stream flow only
    /// trusts this field BEFORE any in-session switch (see
    /// DispatcharrAPI.getChannelStatus), which is exactly where the walk
    /// reads it: once, to seed its starting point.
    @MainActor
    private func currentStreamID(api: DispatcharrAPI, channelUUID: String) async -> Int? {
        let read = Task { @MainActor in
            try? await api.getChannelStatus(channelUUID: channelUUID).streamID
        }
        let cap = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            read.cancel()
        }
        let value = await read.value
        cap.cancel()
        return value
    }

    /// Every mpv-fallback trigger routes through here. With the mpv
    /// engine disabled (test flag, see PlaybackFeatureFlags), the
    /// failure stays ON SCREEN instead of being silently rescued - the
    /// whole point of the no-mpv field test is to see what breaks.
    private func failOrFallback(_ reason: String) {
        #if os(iOS)
        // Quiesced (or mid-quiesce) for background: any error racing the
        // teardown is noise from the pipeline we are already stopping;
        // foreground rebuilds fresh. Same for an error arriving while
        // suspended-adjacent (state .background with PiP inactive) - the
        // resume handler owns recovery, not the card.
        if backgroundSuspended { return }
        if UIApplication.shared.applicationState == .background,
           !progressStore.isPiPActive {
            debugLog("[AVP-MV] failure while backgrounded (\(reason)); deferring to foreground rebuild channel=\(channelName)")
            quiesceForBackground()
            return
        }
        #endif
        // A stopped notice owns the tile until Retry; late errors from the
        // torn-down pipeline are noise.
        if progressStore.liveStopNotice != nil { return }
        // Dispatcharr connection-limit refusal (exact server signal, Direct
        // Connect only): show the notice and stop. No retry ladder, no
        // failover walk, no change_stream.
        if !isVOD, !isDVR, let notice = DispatcharrConnectionLimit.fromIngestFailure(reason) {
            showLiveStopNotice(notice, reason: reason)
            return
        }
        // MKV master-playlist rejection (field 2026-08-29, -12927 on a
        // UHD remux whose SPS carries custom scaling lists): CoreMedia's
        // MULTIVARIANT loader parses the init's parameter sets with a
        // stricter reader than the plain media-playlist path, and fails
        // the item before the first segment. The server is healthy -
        // re-point the SAME session at its bare vod.m3u8 (alternate
        // audio renditions are lost, playback is not). One-shot by
        // construction: the retry flips readyLocalURL off master.m3u8.
        if reason.contains("-12927"), mkvServer != nil,
           let ready = readyLocalURL, ready.lastPathComponent == "master.m3u8" {
            let media = ready.deletingLastPathComponent().appendingPathComponent("vod.m3u8")
            debugLog("[AVP-MV] master playlist rejected (-12927); retrying on plain media playlist (alternate audio dropped) title=\(channelName)")
            readyLocalURL = media
            statusText = "Buffering..."
            startPlayer(url: media, requestHeaders: [:])
            return
        }
        // In-progress DVR: ANY terminal error most likely means the
        // recording just finished (Dispatcharr finalizes and the /hls/
        // playlist route starts serving the SPA's HTML -> -12646
        // "Playlist parse error"; a stop without finalize just starves
        // the edge into the stale-playlist escalation). Runs BEFORE the
        // generic auto-retry: re-tuning a finalized playlist just flashes
        // "Retrying..." and fails again (field find 2026-08-27). One shot:
        // migrate the tile onto the completed /file/ endpoint at the
        // current position. The store swap changes streamURL, which the
        // onChange restart picks up; a false return (unexpected URL
        // shape) falls through to the normal card.
        if isDVR, tileError == nil {
            let pos = progressStore.currentMs
            debugLog("[AVP-MV] DVR terminal (\(reason)); attempting completed-file migration at \(pos)ms title=\(channelName)")
            if MultiviewStore.shared.migrateDVRTileToCompletedFile(tileID: tileID, positionMs: pos) {
                statusText = "Recording finished. Reloading..."
                stop()
                return
            }
        }

        // One silent full-chain retry per stream URL for the transient
        // classes, BEFORE any mpv fallback or error card: provider
        // mid-rotation mismatches and the wedges they cause downstream
        // (the 13:33 field freeze was a dead upstream connection
        // starving the buffer - the watchdog's 'playback frozen'
        // never passed the old server.onError retry). A fresh start
        // re-indexes and reconnects; a second failure proceeds below.
        let retryable = reason.contains("file changed upstream")
            || reason.contains("no video samples")
            || reason.contains("segment build failures")
            || reason.contains("playback frozen")
            || reason.contains("playback failed")
            || reason.contains("never became ready")
            || reason.contains("range fetch HTTP 5")
            // A fresh live ingest can 500 while the proxy is still
            // tearing down the previous connection for the same channel
            // (fast swap-back; field 2026-08-28 ESPN at pos=0). Same
            // transient class as the version-switch 503 - the 1s-delayed
            // one-shot retry lets the teardown drain.
            || reason.contains("ingest failed: HTTP 5")
            // Suspension-adjacent socket death that slipped past the
            // background quiesce (notification shade dwell, brief app
            // switch): the connection is simply gone, and a fresh
            // pipeline is what any viewer would try (field 2026-08-29).
            // NOT for catch-up tiles: their session-bound URL must go
            // through the position-preserving re-mint branch below, not
            // a generic programme-start restart.
            || (catchup == nil && (reason.contains("timed out")
                    || reason.contains("network connection was lost")))
            || reason.contains("persistent fetch error")
            || (reason.contains("span") && reason.contains("unreadable"))
        // LIVE included (2026-08-26 field: Sky Sports UHD died with
        // 'persistent fetch error -12888 x3' after 8 healthy minutes -
        // a one-shot re-tune is what any viewer would do before giving
        // up; the old mpv downgrade used to absorb exactly this class).
        // Deterministic mid-file CoreMedia decode failure on the MKV remux
        // path (tester 2026-08-31: Code=-4 at exactly 63813ms on two
        // separate attempts of the same 20Mbps title): one cluster in this
        // copy remuxes into something CoreMedia refuses. A plain retry at
        // the same position dies identically, so retry once skipping 3s
        // past the poisonous sample -- and log the segment/byte range so
        // the copy can be fetched and benched offline. Bounded by the same
        // retry budget as the generic path.
        if reason.contains("Code=-4"), isVOD, let srv = mkvServer,
           mismatchAutoRetries < 2, tileError == nil {
            let pos = max(progressStore.currentMs, 0)
            mismatchAutoRetries += 1
            debugLog("[AVP-MV] CoreMedia -4 at \(pos)ms (\(srv.diagnostics(forMs: pos))); "
                + "retrying 3s past the failing sample title=\(channelName)")
            progressStore.explicitResumeMs = pos + 3_000
            stop()
            statusText = "Retrying..."
            let token = teardownToken
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                guard token == teardownToken else { return }
                start()
            }
            return
        }
        // A live 503 that Dispatcharr EXPLAINED (Logan 2026-09-12: never
        // assume the cause in the copy, and fail over when the server says
        // it has no stream). Two different servers hide behind one status
        // code, and they need opposite recoveries:
        //   "Channel is stopping, retry shortly" (Retry-After: 1) is the
        //   proxy tearing down the previous session for THIS channel - a
        //   cast that just ended, a fast channel flip - and the same URL
        //   works as soon as that drains.
        //   "No available streams for this channel", a specific upstream
        //   error_reason with the server's own "waited", or "Channel
        //   resources unavailable" means the server already tried this
        //   channel's streams, so waiting buys nothing and the client
        //   walks to another stream instead.
        // The 502/503 ladder below stays for a bare, unexplained 503.
        if !isVOD, !isDVR, catchup == nil, tileError == nil,
           let info = Self.parse503(reason) {
            if let serverReason = info.serverReason {
                if serverReason.lowercased().contains("is stopping") {
                    if channelStoppingRetries < Self.channelStoppingMaxRetries {
                        let delay = min(max(info.retryAfter ?? 1, 1), Self.channelStoppingMaxDelay)
                        channelStoppingRetries += 1
                        debugLog("[AVP-MV] 503 reason=\"\(serverReason)\"; same-URL retry "
                            + "\(channelStoppingRetries)/\(Self.channelStoppingMaxRetries) in \(delay)s "
                            + "channel=\(channelName)")
                        stop()
                        statusText = "Reconnecting..."
                        let token = teardownToken
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            guard token == teardownToken else {
                                debugLog("[AVP-MV] stale channel-stopping retry dropped")
                                return
                            }
                            start()
                        }
                        return
                    }
                    // Waited out the whole budget and the previous session
                    // is still there: treat it as an unavailable channel
                    // and go looking for another stream.
                }
                handle503Unavailable(reason: reason, serverReason: serverReason)
                return
            }
        }
        let serverBusy = reason.contains("HTTP 503") || reason.contains("HTTP 502")
        if serverBusy, serverBusyRetries < Self.serverBusyDelays.count, tileError == nil {
            // Widened from [1.5, 3, 5, 8] (review 2026-09-11 section 2
            // proposal 4): a provider connection cap is a TIME problem,
            // and the old ladder plus the generic retries all fired
            // inside 21 s of the first 503 (session.txt:3550-3600), just
            // before the cap would have cleared.
            let delay = Self.serverBusyDelays[serverBusyRetries]
            serverBusyRetries += 1
            debugLog("[AVP-MV] server busy (\(reason)); retry \(serverBusyRetries)/\(Self.serverBusyDelays.count) in \(delay)s title=\(channelName)")
            stop()
            // No cause in the copy (Logan 2026-09-12). This ladder is now
            // only reached by a 502, or by a 503 that carried no reason at
            // all; an explained 503 is handled above and never guesses.
            statusText = "Reconnecting..."
            let token = teardownToken
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard token == teardownToken else { return }
                start()
            }
            return
        }
        if retryable, mismatchAutoRetries < 2, tileError == nil {
            mismatchAutoRetries += 1
            // Device log 2026-09-25 16:22:49 / 16:25:10: the loopback item
            // "never became ready" because the RECEIVER held it (external
            // playback after a failed LAN item; 127.0.0.1 is unreachable
            // from the TV), not because a proxy captured loopback. A
            // session served to AirPlay is not a failed loopback start.
            #if os(iOS)
            let airPlayServed = HLSDelivery.airPlayRouteActive
                || player?.isExternalPlaybackActive == true
                || airPlayDelivery.isServing
            #else
            let airPlayServed = false
            #endif
            if reason.contains("never became ready"), reason.contains(".unknown"), airPlayServed {
                debugLog("[AVP-MV] loopback start not counted as failed (AirPlay route / external playback active); retry stays on loopback title=\(channelName)")
            } else if reason.contains("never became ready"), reason.contains(".unknown"),
               let mux = remuxer, !mux.inProcessDelivery {
                // Loopback fetches never answered: a proxy or VPN is
                // capturing 127.0.0.1 (see HLSDelivery). The retry hands
                // the bytes to AVFoundation in-process instead.
                HLSDelivery.forceInProcessNextStart = true
                debugLog("[AVP-MV] loopback delivery never became ready; retrying with in-process delivery title=\(channelName)")
            }
            debugLog("[AVP-MV] recoverable failure (\(reason)); auto-retrying with a fresh pipeline title=\(channelName)")
            if isVOD, progressStore.currentMs > 2_000 {
                progressStore.explicitResumeMs = progressStore.currentMs
            }
            stop()
            // A beat before the fresh start: a version switch's outgoing
            // AVPlayer drops its provider connections ASYNCHRONOUSLY, and
            // the incoming prepare landing ~250ms later can hit the
            // provider's connection cap (field find 2026-08-26, Her
            // Private Hell #7: 'range fetch HTTP 503' on every switch to
            // it). One second lets the old connections die first.
            statusText = "Retrying..."
            // Cancellable like every other deferred start (device session
            // 2026-09-11 17:15): this retry was armed at 17:15:32.863, the
            // user flipped to ESPN2 at 17:15:33.597, and BOTH the retry
            // (port 64097, session2.txt:369) and the flip settle (port
            // 64098, :375) opened an ingest - two upstream connections and
            // two players for one tile. The token is re-rolled by
            // onChange(streamURL) and onDisappear, so a stale retry is
            // dropped instead of racing the new channel.
            let token = teardownToken
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                guard token == teardownToken else {
                    debugLog("[AVP-MV] stale auto-retry dropped (channel changed or tile gone)")
                    return
                }
                start()
            }
            return
        }
        // Catch-up: the archive session is single-use and the upstream
        // KILLS greedy connections (field 2026-08-28: 2GB in ~2min,
        // then 'network connection was lost'). A generic retry would
        // replay the dead session URL; re-mint/rebuild at the current
        // position instead. Allowed again each time playback has
        // advanced 15s+ since the last reconnect - repeated failures
        // at the same spot fall through to the card.
        // Catch-up 404 before anything played: the archive has no
        // recording for this time (a provider that advertises more days
        // than it keeps; Logan 2026-09-05, ESPN 7d flag, 3d archive).
        // Re-minting the session only asks the same question again, so
        // this is terminal, with a card that says what happened.
        if catchup != nil, tileError == nil,
           reason.contains("ingest failed: HTTP 404"),
           progressStore.currentMs <= catchupBaseMs, readyLocalURL == nil {
            debugLog("[AVP-CU] archive 404 at \(catchupBaseMs / 1000)s; not retrying title=\(channelName)")
            failOrFallbackTerminal("archive unavailable (HTTP 404)")
            return
        }
        if let cu = catchup, tileError == nil {
            let pos = progressStore.currentMs
            if pos > lastCatchupReconnectMs + 15_000 || lastCatchupReconnectMs < 0 {
                lastCatchupReconnectMs = max(pos, 0)
                debugLog("[AVP-CU] pipeline died (\(reason)); reconnecting at \(pos / 1000)s title=\(channelName)")
                statusText = "Reconnecting..."
                retuneCatchupWindow(max(pos, 0), cu)
                return
            }
        }
        // Direct-HLS live tile whose upgrade URL did not play: the host's
        // 302 went somewhere that is not HLS (Redirect stream profile ->
        // raw upstream TS; field 2026-09-03, iPhone on a LAN Dispatcharr:
        // -11850 "server is not correctly configured"). Drop the host's
        // capability and re-tune ONCE through the TS remux arm on the
        // plain URL. Ahead of the mpv fallback: the remux is the engine
        // every other Dispatcharr channel already plays through.
        if !isVOD, !isDVR, catchup == nil, directHLSFallbackURL == nil,
           tileError == nil,
           classifyStreamURL(streamURL) == .hls,
           (streamURL.query ?? "").contains("output_format=hls") {
            HLSCapabilityStore.shared.markNotCapable(streamURL)
            let plain = removingHLSOutputFormat(streamURL)
            debugLog("[AVP-MV] direct HLS failed (\(reason)); re-tuning via TS remux channel=\(channelName)")
            directHLSFallbackURL = plain
            stop()
            statusText = "Retrying..."
            let token = teardownToken
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard token == teardownToken else { return }
                start()
            }
            return
        }
        if PlaybackFeatureFlags.mpvEngineEnabled {
            onEngineFallback(reason)
            return
        }
        // Live ingest 404: the channel's stream UUID is GONE server-side
        // (Dispatcharr removed or rotated the channel - PGA/event
        // streams are torn down when coverage ends, and the app's
        // channel row keeps the stale UUID until the next playlist
        // sync). Playback cannot be saved, but kick a channel refresh
        // so the guide corrects itself while the user reads the card
        // (field 2026-08-30: three PGA event channels 404'd in a row).
        if !isVOD, !isDVR, catchup == nil, reason.contains("ingest failed: HTTP 404") {
            Task { @MainActor in
                guard let container = AerioApp.sharedContainer else { return }
                let servers = (try? ModelContext(container).fetch(FetchDescriptor<ServerConnection>())) ?? []
                guard !servers.isEmpty else { return }
                debugLog("[AVP-MV] live ingest 404; kicking channel refresh to re-resolve the stale channel list")
                ChannelStore.shared.refresh(servers: servers)
            }
        }
        // Which provider copy was playing, for the card and the log
        // (field ask: "Stream Mismatch on WHICH version?"). Nil when
        // this session has no version context (single-copy titles,
        // live).
        let store = MultiviewStore.shared
        let versionLabel: String? = {
            guard isVOD, !store.vodVersionOptions.isEmpty else { return nil }
            guard let id = store.vodCurrentVersionID else { return "Auto" }
            return store.vodVersionOptions.first(where: { $0.id == id })?.label
        }()
        // A LIVE tile that is still mounted and still the user's channel
        // falls into the slow standing retry instead of the terminal card
        // (review 2026-09-11 section 2 proposal 3). A 404 means the
        // channel is gone server-side, which no amount of retrying fixes,
        // so that one keeps its card.
        if !isVOD, !isDVR, catchup == nil, tileError == nil, !tileStopped,
           !reason.contains("HTTP 404") {
            debugLog("[AVP-NO-MPV] live '\(channelName)' exhausted fast retries (\(reason)); "
                + "entering standing retry rather than abandoning the tile")
            scheduleStandingRetry(reason)
            return
        }
        // One line with everything an iteration needs: what, where,
        // which copy, which file (sanitized), how far in, which chain.
        debugLog("[AVP-NO-MPV] FAILED \(isVOD ? "VOD" : "live") '\(channelName)' "
            + "version=\(versionLabel ?? "-") reason=\(reason) pos=\(progressStore.currentMs)ms "
            + "engine=\(mkvServer != nil ? "mkv-remux" : (remuxer != nil ? "ts-remux" : "direct")) "
            + "url=\(DebugLogger.sanitize(streamURL.absoluteString))")
        // FIRST error wins the card: the root failure (e.g. Stream
        // Mismatch with its census) must not be papered over by the
        // startup watchdog firing a generic "never became ready" a few
        // seconds later (field find, 2026-08-26: two cards back to
        // back, the informative one lost).
        failOrFallbackTerminal(reason, version: versionLabel)
    }

    /// The error card, with playback torn down. Shared by the generic
    /// failure tail and the catch-up archive 404.
    private func failOrFallbackTerminal(_ reason: String, version: String? = nil) {
        guard tileError == nil else { return }
        player?.pause()
        // A paused AVPlayer still reloads a live playlist (field log
        // 2026-08-27: ~10s of -12646 spam AFTER the card went up).
        // Dropping the item ends the loading session outright; Retry
        // rebuilds a fresh player from streamURL anyway.
        player?.replaceCurrentItem(with: nil)
        statusText = nil
        // Terminal for this tile: stop the engines so AVPlayer's retry
        // loop can't keep hammering dead segment builds every 5s.
        mkvServer?.stop()
        remuxer?.stop()
        let friendly = Self.userFacingError(reason)
        tileError = TileError(title: friendly.title,
                              message: friendly.message,
                              version: version,
                              diagnostic: reason)
    }

    /// Map internal failure reasons to something a viewer can act on.
    /// The raw reason still shows in the small diagnostic line.
    private static func userFacingError(_ reason: String) -> (title: String, message: String) {
        let r = reason.lowercased()
        if r.contains("archive unavailable") {
            return ("Not Available in the Archive",
                    "The provider has no recording for this time. The channel advertises "
                    + "more catch-up days than its archive actually holds; try a more recent program.")
        }
        func codecName(_ marker: String) -> String {
            // "audio codec A_DTS" / "video codec V_MS/VFW/FOURCC"
            guard let range = reason.range(of: marker, options: .caseInsensitive) else { return "" }
            let raw = reason[range.upperBound...].trimmingCharacters(in: .whitespaces)
            return raw.replacingOccurrences(of: "A_", with: "")
                .replacingOccurrences(of: "V_", with: "")
                .replacingOccurrences(of: "MPEGH/ISO/", with: "")
                .replacingOccurrences(of: "MPEG4/ISO/", with: "")
        }
        if r.contains("unsupported codec: mpeg-2") {
            // OTA/ATSC broadcast channels (field 2026-08-31, second tester:
            // every OTA channel failed with a generic card). Apple silicon
            // has no MPEG-2 decoder; name the real constraint instead of
            // implying the channel is broken.
            return ("Channel Not Supported",
                    "This channel broadcasts MPEG-2 video (over-the-air TV), "
                    + "which this device can't decode natively. See the "
                    + "OTA / HDHomeRun section of the AerioTV GitHub README "
                    + "for a Dispatcharr Stream Profile that fixes this.")
        }
        if r.contains("range fetch http 503") || r.contains("range fetch http 502") {
            // Tester 2026-09-01 (iPad over VPN, 1.8.23): every VOD copy on
            // every provider failed at prepare with HTTP 503 from the
            // Dispatcharr VOD proxy, and the card said "the connection to
            // the provider stalled", which implies a link problem the user
            // cannot act on. A 503 at prepare means the SERVER refused to
            // open the file (provider connection limit reached, or the
            // proxy busy); name that so the user checks the right thing.
            return ("Server Busy",
                    "The server could not open this video (HTTP 503). This usually means the provider's connection limit is reached or the server is busy. Wait a moment and try again, or check the provider's active connections.")
        }
        if r.contains("audio codec") {
            let codec = codecName("audio codec ")
            return ("Audio Not Supported",
                    "This copy's audio format (\(codec)) can't be decoded by this device's native player. Try another version if one is available.")
        }
        if r.contains("video codec") {
            let codec = codecName("video codec ")
            return ("Video Not Supported",
                    "This copy's video format (\(codec)) can't be decoded by this device's native player. Try another version if one is available.")
        }
        if r.contains("no cues") || r.contains("empty cues") {
            return ("File Can't Be Streamed",
                    "This copy is missing its seek index, so it can't be streamed. Try another version if one is available.")
        }
        if r.contains("contentencodings") {
            return ("File Can't Be Streamed",
                    "This copy uses compressed or encrypted tracks that can't be streamed. Try another version if one is available.")
        }
        if r.contains("file changed upstream") {
            return ("Stream Changed",
                    "The provider replaced this file while it was playing. Play again to pick up the new copy, or try another version.")
        }
        if r.contains("no video samples") || r.contains("segment build failures") {
            return ("Stream Mismatch",
                    "The provider is sending media that doesn't match this copy's index (it may be failing over between sources). Try another version or play again.")
        }
        if r.contains("playback frozen") {
            return ("Playback Stalled",
                    "Playback stopped advancing and couldn't recover. Play again, or try another version if one is available.")
        }
        if r.contains("ingest failed: http 404") {
            return ("Channel Unavailable",
                    "The server no longer offers this stream. Event channels disappear when their coverage ends; the channel list is refreshing now, so check the guide again in a moment.")
        }
        if r.contains("timed out") || r.contains("stream failed")
            || r.contains("stream cancelled") || r.contains("range fetch http")
            || r.contains("persistent fetch error") {
            return ("Connection Problem",
                    "The connection to the provider stalled. Check the source and try again.")
        }
        if r.contains("never became ready") || r.contains("no video size") {
            return ("Playback Didn't Start",
                    "The stream loaded but never produced playable video. Try again, or try another version if one is available.")
        }
        return ("Unable to Play",
                "This stream couldn't be played by the native engine.")
    }

    #if os(iOS)
    /// didEnterBackground with PiP inactive: the process is about to be
    /// suspended, which kills the ingest connection and the loopback
    /// server's sockets no matter what we do - so tear the pipeline down
    /// CLEANLY now (freeing the provider slot for the whole background
    /// stay) and remember to rebuild on foreground. Without this, the
    /// wake-up delivered "ingest failed: The request timed out." plus a
    /// -12888 stale-playlist error and the terminal card (field log
    /// 2026-08-29, Clippers game).
    private func quiesceForBackground() {
        // A receiver is being served from this phone (plan section 6):
        // the keepalive holds the process, and quiescing would starve it.
        if airPlayDelivery.handleBackgroundEntry() { return }
        guard !progressStore.isPiPActive else { return }
        guard tileError == nil, player != nil || statusText != nil else { return }
        backgroundResumeMs = progressStore.currentMs
        if isVOD, progressStore.currentMs > 2_000 {
            progressStore.explicitResumeMs = progressStore.currentMs
        }
        // Never hand the remuxer to LiveChannelRetention from here: the
        // app is leaving the screen and retention's own app-background
        // policy stops every kept session anyway. Clearing the retain
        // snapshot makes stop() release instead of retain.
        sessionRetainKey = nil
        sessionRetainChannelID = nil
        stop()
        backgroundSuspended = true
        debugLog("[AVP-MV] pipeline quiesced for background channel=\(channelName) pos=\(backgroundResumeMs)ms")
    }

    /// willEnterForeground after a quiesce: rebuild the pipeline. Live
    /// returns at the live edge, VOD resumes via explicitResumeMs, DVR
    /// returns at its live edge, catch-up re-tunes its window at the
    /// saved position (the dead-pipeline reconnect path).
    private func resumeFromBackground() {
        guard backgroundSuspended else { return }
        backgroundSuspended = false
        // Each background cycle earns fresh silent retries; without the
        // reset the second background trip went straight to the card.
        mismatchAutoRetries = 0
        statusText = "Reconnecting..."
        debugLog("[AVP-MV] rebuilding pipeline after background channel=\(channelName)")
        if let cu = catchup, backgroundResumeMs > 0 {
            lastCatchupReconnectMs = backgroundResumeMs
            retuneCatchupWindow(backgroundResumeMs, cu)
        } else {
            start()
        }
    }
    #endif

    private func start() {
        // Exactly ONE pipeline per tile. A deferred start that raced a
        // fresh one left two remuxers ingesting the same tile on
        // 2026-09-11 (session2.txt:369 port 64097 and :375 port 64098,
        // two READY URLs and two players for one channel). The deferred
        // starts are token-guarded now; this is the backstop for any path
        // that reaches start() with a pipeline still up.
        if remuxer != nil || player != nil || mkvServer != nil {
            debugLog("[AVP-MV] start() with a live pipeline present; tearing it down first channel=\(channelName)")
            stop()
        }
        tileStopped = false
        tileError = nil
        progressStore.liveStopNotice = nil
        liveSessionStartedAt = Date()
        if let cu = catchup {
            startCatchup(cu)
            return
        }
        if isDVR {
            // Growing HLS window from the server's DVR pipeline: direct
            // play, no remux chain. The driver (DVR-window mode via
            // progressStore.isDVRWindow) owns the timeline.
            startPlayer(url: streamURL, requestHeaders: headers)
            MultiviewStore.shared.registerEngine("AVPlayer · DVR HLS", for: tileID)
            debugLog("[AVP-MV] DVR tile playing direct HLS title=\(channelName)")
            return
        }
        if isVOD {
            startVOD()
            return
        }
        let sourceURL = liveSourceURL
        switch classifyStreamURL(sourceURL) {
        case .hls:
            // Full headers, not just UA: server-side HLS upgrades hit the
            // same Dispatcharr endpoints as the TS path and expect the
            // same auth.
            startPlayer(url: sourceURL, requestHeaders: headers)
            // No remux ingest here to adopt a warm one; release it now.
            LivePrewarm.shared.cancel(reason: "tile playing direct HLS")
            debugLog("[AVP-MV] tile playing direct HLS channel=\(channelName)")
        default:
            statusText = "Preparing..."
            // Live Rewind (task #145, AVPlayer port 2026-08-27): solo
            // live sessions spill every closed segment to disk and the
            // playlist advertises the whole window - AVPlayer native
            // seek IS the rewind. Both arms spill (TS .ts / fMP4 .m4s).
            let rewindSeconds: Double = {
                guard MultiviewStore.shared.tiles.count == 1,
                      UserDefaults.standard.bool(forKey: "liveRewindEnabled") else { return 0 }
                let mins = UserDefaults.standard.integer(forKey: "liveRewindDepthMinutes")
                return Double(mins > 0 ? mins : 30) * 60
            }()
            liveRewindArmed = rewindSeconds > 0
            sessionRetainKey = sourceURL.absoluteString
            sessionRetainChannelID = channelID
            sessionRetainName = channelName
            if liveRewindArmed {
                debugLog("[AVP-REWIND] armed: \(Int(rewindSeconds))s spill window channel=\(channelName)")
                // Channel retention: if this channel's remuxer is still
                // ingesting from a recent flip, adopt it - the rewind
                // window (including the time away) comes back intact.
                if let entry = LiveChannelRetention.shared.adopt(key: sourceURL.absoluteString,
                                                                 channelID: channelID) {
                    let mux = entry.remuxer
                    mux.onError = { error in
                        debugLog("[AVP-MV] tile remux failed (\(error)) channel=\(channelName)")
                        failOrFallback("\(error)")
                    }
                    mux.onVideoParameters = { w, h, fps, tenBit in
                        applyDisplayCriteria(width: w, height: h, fps: fps, is10Bit: tenBit)
                    }
                    if let vp = entry.videoParams {
                        applyDisplayCriteria(width: vp.width, height: vp.height,
                                             fps: vp.fps, is10Bit: vp.tenBit)
                    }
                    // The retained entry pointed these at retention; the
                    // clean-close / silence signals belong to this tile again.
                    mux.onFirstByte = nil
                    attachLiveStallHandlers(mux)
                    remuxer = mux
                    statusText = nil
                    // The onChange(readyLocalURL) handler starts the player.
                    // With retain keys correct this always sees a real value
                    // change (fresh tile: nil -> URL; flip-back: other
                    // channel's port -> this one's), so no direct start here
                    // - that would double-start the player.
                    readyLocalURL = entry.localURL
                    // A warm ingest for this channel would now be a
                    // duplicate upstream connection; release it.
                    LivePrewarm.shared.cancel(reason: "retained window adopted instead")
                    debugLog("[AVP-RETAIN] tile resuming adopted window channel=\(channelName)")
                    return
                }
                // Fresh live session takes one of the N retention slots.
                LiveChannelRetention.shared.evictForNewActive(activeChannelID: channelID)
            }
            // Warm start (review 2026-09-11 section 1 proposal 8): the
            // ingest may already be open, started at press time in
            // parallel with the multiview transition. Adopting it skips
            // the 125 to 183 ms lock->ingest gap AND overlaps the 220 to
            // 2532 ms upstream open with the SwiftUI transition.
            if let warm = LivePrewarm.shared.adopt(key: sourceURL.absoluteString,
                                                   channelID: channelID,
                                                   rewindSeconds: rewindSeconds) {
                let mux = warm.remuxer
                mux.onReady = { url in readyLocalURL = url }
                mux.onError = { error in
                    debugLog("[AVP-MV] tile remux failed (\(error)) channel=\(channelName)")
                    failOrFallback("\(error)")
                }
                mux.onVideoParameters = { w, h, fps, tenBit in
                    applyDisplayCriteria(width: w, height: h, fps: fps, is10Bit: tenBit)
                }
                remuxer = mux
                if let vp = warm.videoParams {
                    applyDisplayCriteria(width: vp.width, height: vp.height,
                                         fps: vp.fps, is10Bit: vp.tenBit)
                }
                // A warm ingest can be silent too (s7_86.txt:353-395):
                // it is the same upstream open, just started earlier.
                mux.onFirstByte = { noteFirstByte() }
                attachLiveStallHandlers(mux)
                if mux.hasReceivedFirstByte {
                    // Bytes arrived before this tile existed, so the
                    // callback will never fire for it; nothing to guard.
                    noteFirstByte()
                } else if warm.failure == nil, warm.readyURL == nil {
                    armFirstByteDeadline()
                }
                if let failure = warm.failure {
                    failOrFallback(failure)
                } else if let url = warm.readyURL {
                    // The onChange(readyLocalURL) handler starts the player.
                    readyLocalURL = url
                }
                debugLog("[AVP-MV] tile adopted warm ingest channel=\(channelName)")
                return
            }
            // This tile is opening its own ingest, so any warm one left
            // over (different channel, or a rewind-window mismatch) is
            // dead weight holding a provider slot.
            LivePrewarm.shared.cancel(reason: "tile started its own ingest")
            let mux = TSHLSRemuxer(sourceURL: sourceURL, headers: headers,
                                   rewindWindowSeconds: rewindSeconds)
            mux.onReady = { url in
                // @State write only; the fresh-struct onChange handler
                // does the actual player start (see readyLocalURL doc).
                readyLocalURL = url
            }
            mux.onError = { error in
                debugLog("[AVP-MV] tile remux failed (\(error)) channel=\(channelName)")
                failOrFallback("\(error)")
            }
            mux.onVideoParameters = { w, h, fps, tenBit in
                applyDisplayCriteria(width: w, height: h, fps: fps, is10Bit: tenBit)
            }
            // Connected-but-silent ingest guard (s7_86.txt:353-395).
            mux.onFirstByte = { noteFirstByte() }
            attachLiveStallHandlers(mux)
            remuxer = mux
            mux.start()
            armFirstByteDeadline()
        }
    }

    /// Catch-up: ingest the archive TS window through the live remux arm
    /// (ONE plain GET - the exact transport contract the single-use
    /// session needs) and pin the chrome timeline to the EPG duration.
    /// Seeks are window re-tunes (mpv parity): rebuild/re-mint the URL
    /// at the target offset and restart the pipeline.
    private func startCatchup(_ cu: CatchupPlayback) {
        statusText = "Loading..."
        progressStore.durationMs = cu.programDurationMs
        progressStore.currentMs = catchupBaseMs
        let source = catchupURL ?? streamURL
        // Spill the WHOLE window to disk: archive servers deliver at
        // line rate, not realtime (the reason mpv's relay spooled to
        // disk and tailed at playback speed). Without spill the live
        // arm's 12-segment RAM ring rolls segments off faster than the
        // player consumes them - stutter, then a dead pipeline (field,
        // 2026-08-28 First Take). With it, nothing rolls off and
        // in-window seeks are native.
        let windowSecs = Double(max(60_000, cu.programDurationMs)) / 1000.0 + 300
        let mux = TSHLSRemuxer(sourceURL: source, headers: headers,
                               rewindWindowSeconds: windowSecs)
        mux.eventPlaylist = true
        mux.onReady = { url in
            readyLocalURL = url
            MultiviewStore.shared.registerEngine("AVPlayer · Catch-up", for: tileID)
        }
        mux.onError = { [weak mux] error in
            let reason = "\(error)"
            // The upstream kills greedy line-rate connections every ~2min
            // with 20+ min of content already spilled. Ingest death is
            // NOT playback death: finalize the playlist (ENDLIST) and
            // keep playing the downloaded window; the EOF handler
            // re-tunes when the playhead reaches its end. Only a death
            // BEFORE anything played falls through to the error path.
            if reason.contains("ingest failed"), progressStore.currentMs > 0 || readyLocalURL != nil {
                debugLog("[AVP-CU] ingest died (\(reason)); window finalized, playback continues title=\(channelName)")
                mux?.markComplete()
                return
            }
            debugLog("[AVP-CU] remux failed (\(reason)) title=\(channelName)")
            failOrFallback(reason)
        }
        mux.onVideoParameters = { w, h, fps, tenBit in
            applyDisplayCriteria(width: w, height: h, fps: fps, is10Bit: tenBit)
        }
        remuxer = mux
        mux.start()
        debugLog("[AVP-CU] ingest start base=\(catchupBaseMs / 1000)s title=\(channelName)")
    }

    /// Chrome seekAction in catch-up mode: target is programme-relative
    /// ms. Native Dispatcharr sessions re-mint (full-second precision,
    /// old session revoked); XC-shaped rebuilds the timeshift URL floored
    /// to the minute. Both restart the remux pipeline at the new window.
    private func performCatchupSeek(_ targetMs: Int32, _ cu: CatchupPlayback) {
        let dur = max(0, cu.programDurationMs)
        let clamped = min(max(targetMs, 0), max(0, dur - 5_000))
        // In-window fast path: the whole window spills to disk and the
        // ingest runs at line rate, so most targets are ALREADY local -
        // seek the player natively instead of burning a server re-tune
        // (and, on native sessions, a mint/revoke round trip).
        if let item = player?.currentItem,
           let range = item.seekableTimeRanges.last?.timeRangeValue {
            let start = CMTimeGetSeconds(range.start)
            let end = CMTimeGetSeconds(CMTimeRangeGetEnd(range))
            let rel = Double(clamped - catchupBaseMs) / 1000.0
            if start.isFinite, end.isFinite, rel >= start, rel <= end - 2 {
                debugLog("[AVP-CU] in-window seek -> \(clamped / 1000)s (local)")
                player?.seek(to: CMTime(seconds: rel, preferredTimescale: 600),
                             toleranceBefore: .zero, toleranceAfter: .zero)
                progressStore.currentMs = clamped
                if player?.timeControlStatus == .paused { player?.play() }
                return
            }
        }
        retuneCatchupWindow(clamped, cu)
    }

    /// The actual window re-tune (server round trip + pipeline restart),
    /// shared by out-of-window seeks and dead-pipeline reconnects (which
    /// must NOT take the in-window fast path - the loopback is dead).
    private func retuneCatchupWindow(_ clamped: Int32, _ cu: CatchupPlayback) {
        if cu.nativeChannelUUID != nil {
            guard !catchupMintInFlight else {
                debugLog("[AVP-CU] seek dropped (mint in flight)")
                return
            }
            catchupMintInFlight = true
            statusText = "Loading..."
            progressStore.currentMs = clamped   // optimistic, mpv parity
            let previous = catchupURL ?? streamURL
            debugLog("[AVP-CU] native re-tune -> \(clamped / 1000)s title=\(channelName)")
            Task { @MainActor in
                defer { catchupMintInFlight = false }
                guard let newURL = await CatchupSupport.remintNative(
                    playback: cu, currentURL: previous,
                    offsetSeconds: Double(clamped) / 1000.0) else {
                    debugLog("[AVP-CU] native re-mint failed; keeping current window")
                    statusText = nil
                    return
                }
                CatchupSupport.revokeNative(playback: cu, currentURL: previous)
                catchupURL = newURL
                catchupBaseMs = clamped
                stop()
                start()
            }
        } else {
            let flooredSecs = Double((Int(clamped) / 60_000) * 60)
            guard let newURL = CatchupSupport.rebuildForOffset(
                url: catchupURL ?? streamURL,
                panelTimeZoneID: cu.panelTimeZoneID,
                programStart: cu.programStart, programEnd: cu.programEnd,
                offsetSeconds: flooredSecs) else {
                debugLog("[AVP-CU] XC rebuild failed; keeping current window")
                return
            }
            catchupURL = newURL
            catchupBaseMs = Int32(flooredSecs * 1000)
            progressStore.currentMs = catchupBaseMs
            statusText = "Loading..."
            debugLog("[AVP-CU] XC re-tune -> \(Int(flooredSecs))s (minute-floored) title=\(channelName)")
            stop()
            start()
        }
    }

    /// VOD chain: MP4-family plays direct; everything else attempts the
    /// MKV cue-indexed remux, and a non-Matroska file gets one direct
    /// try (Dispatcharr's extensionless proxy URL can front an MP4)
    /// before the tile falls back to mpv.
    /// Byte source for the loading detail line, chosen by which pipeline
    /// this tile is actually running: the TS/fMP4 ingest (live, catch-up,
    /// local-file and raw-TS VOD), the MKV VOD server, or, for direct
    /// AVPlayer sources (MP4/MOV VOD, server-side DVR, direct HLS), the
    /// player item's own access log. Exactly one of them, never a mix.
    private func loadingDetailSample() -> LoadingDetailSample {
        if let mux = remuxer {
            let at = mux.ingestConnectedAt
            return LoadingDetailSample(connected: at != nil,
                                       bytes: mux.bytesIngested,
                                       connectedAt: at)
        }
        if let srv = mkvServer {
            let at = srv.mediaConnectedAt
            return LoadingDetailSample(connected: at != nil,
                                       bytes: srv.mediaBytesStreamed,
                                       connectedAt: at)
        }
        if let events = player?.currentItem?.accessLog()?.events, !events.isEmpty {
            // An access-log event exists only once AVFoundation has a
            // response for the item, so its presence IS "connected";
            // numberOfBytesTransferred is -1 when unknown.
            let bytes = events.reduce(Int64(0)) { $0 + max(0, $1.numberOfBytesTransferred) }
            return LoadingDetailSample(connected: true, bytes: bytes, connectedAt: nil)
        }
        return LoadingDetailSample(connected: false, bytes: 0, connectedAt: nil)
    }

    private func startVOD() {
        let ext = streamURL.pathExtension.lowercased()
        if streamURL.isFileURL || ext == "ts" {
            // Local-file recordings (and any raw .ts VOD): AVPlayer can't
            // open bare TS, so ingest through the live remux arm as an
            // event playlist - disk-speed ingest finalizes with ENDLIST
            // within seconds and the file plays as normal seekable VOD.
            // The spill window temporarily duplicates the file next to
            // the LiveRewind spill (same budget sweeper bounds it).
            statusText = "Preparing..."
            let mux = TSHLSRemuxer(sourceURL: streamURL, headers: headers,
                                   rewindWindowSeconds: 21_600)
            mux.eventPlaylist = true
            mux.onReady = { url in
                readyLocalURL = url
                MultiviewStore.shared.registerEngine("AVPlayer · TS Remux", for: tileID)
            }
            mux.onError = { error in
                debugLog("[AVP-MV] TS-file remux failed (\(error)) title=\(channelName)")
                failOrFallback("\(error)")
            }
            mux.onVideoParameters = { w, h, fps, tenBit in
                applyDisplayCriteria(width: w, height: h, fps: fps, is10Bit: tenBit)
            }
            remuxer = mux
            mux.start()
            debugLog("[AVP-MV] VOD via TS ingest (\(streamURL.isFileURL ? "local file" : "raw ts")) title=\(channelName)")
            return
        }
        if ext == "m3u8" {
            // HLS-fronted VOD (e.g. a finished server recording exposed
            // as a playlist): native AVPlayer territory, never the MKV
            // chain (the magic-bytes probe would just bounce it anyway).
            startPlayer(url: streamURL, requestHeaders: headers)
            MultiviewStore.shared.registerEngine("AVPlayer · Direct HLS", for: tileID)
            debugLog("[AVP-MV] VOD playing direct HLS title=\(channelName)")
            return
        }
        if ["mp4", "m4v", "mov"].contains(ext) {
            startPlayer(url: streamURL, requestHeaders: headers)
            // Truthful badge: the generic session label says "Remux TS",
            // which is a live-arm name; VOD is direct-play or MKV remux
            // and the dev badge should say which (field ask, 2026-08-25).
            MultiviewStore.shared.registerEngine("AVPlayer · Direct", for: tileID)
            debugLog("[AVP-MV] VOD playing direct \(ext.uppercased()) title=\(channelName)")
            return
        }
        statusText = "Preparing..."
        let server = MKVVODServer(url: streamURL, headers: headers)
        server.onReady = { url in
            readyLocalURL = url
            MultiviewStore.shared.registerEngine("AVPlayer · MKV Remux", for: tileID)
        }
        server.onVideoParameters = { w, h, fps, tenBit in
            applyDisplayCriteria(width: w, height: h, fps: fps, is10Bit: tenBit)
        }
        // Class ref captured directly - safe across view-struct copies
        // (unlike @State value snapshots, see AUDIO CORRECTNESS above).
        let subStore = subtitleStore
        server.onSubtitleTracks = { tracks in
            subStore.setTracks(tracks)
            debugLog("[AVP-MV] subtitle tracks: \(tracks.map(\.name).joined(separator: ", "))")
        }
        server.onSubtitleCues = { track, cues in
            subStore.add(track: track, newCues: cues)
        }
        server.onError = { reason in
            if reason.contains("not an EBML") {
                debugLog("[AVP-MV] VOD not Matroska; trying direct AVPlayer title=\(channelName)")
                // Clear the loading text: only the remux-READY path did,
                // so the direct fallback played underneath a permanent
                // "Preparing..." (field find 2026-08-26, Her Private
                // Hell - the provider had rotated the 'MKV' copies to
                // MP4s, making direct the common path for that title).
                statusText = nil
                startPlayer(url: streamURL, requestHeaders: headers)
            } else {
                // failOrFallback owns the one-shot auto-retry for the
                // transient mismatch/wedge classes.
                debugLog("[AVP-MV] VOD remux failed (\(reason)) title=\(channelName)")
                failOrFallback(reason)
            }
        }
        mkvServer = server
        server.start()
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main) { [weak server] _ in
            server?.purgeOnMemoryWarning()
        }
    }

    /// `lanAAC`: the item is the AirPlay airplay-aac variant on the LAN,
    /// whose playlists state their own HOLD-BACK (plan section 5).
    private func startPlayer(url: URL, requestHeaders: [String: String], lanAAC: Bool = false) {
        var options: [String: Any] = [:]
        if !requestHeaders.isEmpty {
            options["AVURLAssetHTTPHeaderFieldsKey"] = requestHeaders
        }
        var driverJoinOffset = 0.0
        var driverOffsetFloor = 0.0
        let asset = AVURLAsset(url: url, options: options)
        if url.scheme == HLSDelivery.scheme {
            asset.resourceLoader.setDelegate(HLSResourceLoaderRegistry.shared,
                                             queue: HLSResourceLoaderRegistry.shared.queue)
        }
        let playerItem = AVPlayerItem(asset: asset)
        // Live-edge point: trust the server, do not force an offset. The
        // Dispatcharr HLS output now pins the join point itself, correctly for
        // each mode: #EXT-X-START ~3 target durations back on the standard
        // output (safe, no CoreMedia -16832 stall-danger), and PART-HOLD-BACK
        // ~1.5s on the Low-Latency output. A hard-coded configuredTimeOffsetFromLive
        // would override both and, on the LL path, pin latency at our guess
        // instead of riding the live edge. Preserve whatever start point the
        // server hands us across stalls. (mpv never needs this: it reads a
        // continuous MPEG-TS stream with no live edge to ride.) Deliberately no
        // fallback configuredTimeOffsetFromLive when EXT-X-START is absent:
        // AVPlayer's own PART-HOLD-BACK / 3x-TARGETDURATION default is safe, an
        // override would pin LL latency, and a server that joins us into an
        // unservable edge is recovered by the stall watchdog below.
        playerItem.automaticallyPreservesTimeOffsetFromLive = true
        // Stream Buffer (Settings > App Behaviors), AVPlayer-live parity
        // with mpv's cache-secs: a bursty upstream (field 2026-08-30, MLS
        // event feed arriving at 0.8x realtime for ~25s stretches, then
        // catching up in bursts) starves a player holding only the
        // default ~3-target-duration edge distance - one ~2s stall per
        // window. The user's chosen seconds ride ON TOP of that default
        // so 0 stays byte-identical to today's low-latency join, and a
        // 3-5s setting absorbs the deficit at the cost of that much
        // added latency. Live tiles only: VOD/DVR/catch-up have no edge.
        let streamBufferSeconds = UserDefaults.standard.double(forKey: "appBehaviorsStreamBufferSeconds")
        let isLiveTune = !isVOD && !isDVR && catchup == nil
        // Hold-back learned from this channel's PREVIOUS stalls, applied
        // here at join time. Raising it mid-playback is what replayed
        // content on the user (see the holdback note in
        // AVPlayerProgressDriver.logPerfSummary); at join there is no
        // playhead to move, so it is free.
        let holdbackKey = isLiveTune ? liveSourceURL.absoluteString : nil
        let learned = holdbackKey.map { LiveEdgeHoldback.offset(for: $0) } ?? LiveEdgeHoldback.base
        // Join offset geometry (session7, ESPN 18:06:52-18:07:18). The
        // playlist's TARGETDURATION sets AVPlayer's poll cadence, so a
        // player parked only 6 s back has barely one poll of slack: the
        // remuxer pinned TARGETDURATION at 4 after a 3.92 s segment,
        // AVPlayer then polled every 4 s (:15.36, :19.37, :23.37),
        // segments 10 and 11 closed after its last fetch, the feed also
        // ran 3.1 s late once, and the buffer ran empty. Three target
        // durations is AVPlayer's own default hold-back for a reason;
        // take the largest of that, what this channel's stalls have
        // taught us, and the 6 s floor, then add the user's Stream
        // Buffer. Same 18 s ceiling as before.
        let joinTargetDuration = isLiveTune ? (remuxer?.advertisedTargetDuration.get() ?? 0) : 0
        if isLiveTune, lanAAC {
            debugLog("[AVP-AIRPLAY] join offset left to the variant playlist's HOLD-BACK (primary offset not applied) channel=\(channelName)")
        } else if isLiveTune {
            let floor = max(3 * joinTargetDuration, learned, LiveEdgeHoldback.base)
            var offset = min(18.0, floor + streamBufferSeconds)
            // AirPlay passthrough on the LAN URL: at least the remuxer's LAN
            // hold-back (device log 2026-09-25 17:04), which the LAN
            // playlist also states.
            let lanHoldBack = (url.host != "127.0.0.1" && url.scheme == "http")
                ? (remuxer?.lanHoldBack.get() ?? 0) : 0
            if lanHoldBack > offset {
                debugLog(String(format: "[AVP-AIRPLAY] join offset %.1fs -> LAN hold-back %.1fs channel=%@",
                                offset, lanHoldBack, channelName))
                offset = lanHoldBack
            }
            // Never join deeper than the LAN window actually holds (window
            // minus one target): an offset past the playlist start leaves
            // the receiver parked on the first fetch (device log
            // 2026-09-25, 8 s offset into a 4 s window).
            if lanHoldBack > 0 {
                let available = (remuxer?.lanWindowSeconds.get() ?? 0) - joinTargetDuration
                if available > 0, offset > available {
                    debugLog(String(format: "[AVP-AIRPLAY] join offset %.1fs clamped to %.1fs (LAN window minus one target) channel=%@",
                                    offset, available, channelName))
                    offset = available
                }
            }
            playerItem.configuredTimeOffsetFromLive =
                CMTime(seconds: offset, preferredTimescale: 600)
            debugLog(String(format:
                "[AVP-MV] live edge offset %.1fs at join (3x targetDuration %.1f = %.1f, learned %.1f, floor %.1f, stream buffer %.1f) channel=%@",
                offset, joinTargetDuration, 3 * joinTargetDuration, learned,
                LiveEdgeHoldback.base, streamBufferSeconds, channelName))
            driverJoinOffset = offset
            driverOffsetFloor = max(learned, LiveEdgeHoldback.base) + streamBufferSeconds
        }
        // Forward buffer: left at AVPlayer's automatic default (0). A device
        // capture DISPROVED the idea that a forced preferredForwardBufferDuration
        // does not gate first frame: forcing 12s gated tune-in to ~11.8s on a
        // bandwidth-limited (WAN/cellular) path, because
        // automaticallyWaitsToMinimizeStalling (default true) waits to fill that
        // buffer and a ~1x-realtime link needs ~12s to do so (Apple's own caveat
        // that a large value delays start). On LAN the same 12s filled instantly
        // (343ms first frame, zero stalls over a long run), so the cushion was
        // invisible there but pure downside off-LAN, and it did NOT prevent the
        // one WAN stall anyway. Automatic adapts per link: near-instant on LAN
        // (huge headroom keeps it stall-free), fastest-safe off-LAN. The 9s
        // offset above stays as the only explicit live-edge lever; the real
        // low-latency-AND-no-stall fix off-LAN is server-side LL-HLS.
        // EXCEPTION (2026-08-26 jetsam, second event): the MKV-remux VOD
        // path serves from loopback, where AVPlayer observes ~1.9 Gbps
        // and its automatic forward buffer balloons - on a ~65 Mbps UHD
        // remux that alone is hundreds of MB, and the app died at 1.19GB
        // footprint DURING SMOOTH PLAYBACK (rss hit 808MB within 90s of
        // start). Localhost refills 15s in ~1s, so a bounded buffer
        // costs nothing there; the WAN caveat above does not apply
        // because the slow hop (provider -> engine) has its own
        // flow-controlled buffer ahead of the loopback server.
        let isLoopback = (url.host == "127.0.0.1" || url.host == "localhost")
        let isLoopbackVOD = isVOD && isLoopback
        // Catch-up loopback too: line-rate ingest leaves an hours-deep
        // "live" window that automatic buffering gorges on at ~3Gbps
        // during startup - churn that lets audio start while video
        // decode lags seconds behind (field 2026-08-28). 15s bounds it;
        // the disk window makes deeper buffering pointless anyway.
        if isLoopbackVOD || (catchup != nil && isLoopback) {
            playerItem.preferredForwardBufferDuration = 15
        }
        // NO first-play buffering override. The 2026-09-11 17:15 device
        // session (session2.txt) is the counter-experiment: with
        // `automaticallyWaitsToMinimizeStalling = false` and a 2 s
        // forward buffer, AVPlayer reported timeControlStatus .playing
        // IMMEDIATELY and then never advanced the clock - eleven
        // consecutive "[AVP-FREEZE] clock advanced 0.000s ... pos 0.0s,
        // status playing" ticks per tune (session2.txt:302-347), and
        // CoreMedia answered -16832 "restarting from end of live
        // playlist - stall danger" (session2.txt:398). The ONE channel
        // that played that session was the one whose second remuxer ran
        // under the automatic policy. Automatic waiting is what actually
        // starts a live remux stream; leave it alone.
        debugLog("[AVP-MV] live offset=server fwdBuf=\(isLoopbackVOD ? "15s (loopback VOD)" : "automatic") channel=\(channelName)")
        let avPlayer = AVPlayer(playerItem: playerItem)
        // Explicit readyToPlay marker (review 2026-09-11, marker
        // inventory): the log had no discrete line for it, only the
        // layer's isReadyForDisplay, so "how long did AVPlayer take to
        // accept the playlist" was guesswork.
        var itemReadyObs: NSKeyValueObservation?
        itemReadyObs = playerItem.observe(\.status, options: [.new]) { item, _ in
            guard item.status != .unknown else { return }
            if item.status == .readyToPlay {
                TuneTimeline.shared.mark("ready")
                debugLog("[AVP-ITEM] AVPlayerItem readyToPlay")
            } else {
                debugLog("[AVP-ITEM] AVPlayerItem status=failed (\(item.error?.localizedDescription ?? "unknown"))")
            }
            itemReadyObs?.invalidate()
            itemReadyObs = nil
        }
        #if os(iOS)
        // Remote-session card (2026-09-12): AirPlay state for the card comes
        // off whichever AVPlayer is currently feeding output. The audio tile
        // is the one that can own an external route.
        if MultiviewStore.shared.audioTileID == tileID {
            AirPlayMonitor.shared.attach(avPlayer)
            if let mux = remuxer {
                airPlayDelivery.onWatchdogs = { suspend, item in
                    stallWatchdog?.setSuspended(suspend, item: item)
                }
                airPlayDelivery.attach(player: avPlayer, remuxer: mux,
                                       loopbackURL: readyLocalURL, channelName: channelName)
                airPlayDelivery.noteStartItem(playerItem)
            }
        }
        #endif
        // Live truth at this instant, never a captured snapshot.
        avPlayer.isMuted = (MultiviewStore.shared.audioTileID != tileID)
        // VOD resume (Continue Watching): the store carries the offset
        // the container preloaded; AVPlayer queues the seek until the
        // item is ready, so firing it here is safe and race-free.
        let resumeMs = progressStore.explicitResumeMs ?? resumePositionMs
        if isDVR, resumeMs == 0 {
            // "Watch from Beginning" on an in-progress recording: without
            // a seek, a live-shaped playlist starts at the live edge.
            // The pre-ready queued seek alone is NOT enough: when the item
            // reaches readyToPlay, AVPlayer's live-edge positioning for a
            // live-shaped playlist stomps it, and playback lands at the
            // edge anyway (tester 2026-08-31: "Watch from Beginning went
            // to Live"; log showed the queued seek then edge=-7.0s). So
            // re-issue the seek at readiness, when it sticks. The DVR
            // playlist never rolls anything off, so position 0 is always
            // in the window.
            avPlayer.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            var readyObs: NSKeyValueObservation?
            readyObs = playerItem.observe(\.status, options: [.new]) { item, _ in
                guard item.status != .unknown else { return }
                if item.status == .readyToPlay {
                    avPlayer.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                    debugLog("[AVP-MV] DVR from-beginning seek re-issued at readyToPlay")
                }
                readyObs?.invalidate()
                readyObs = nil
            }
            debugLog("[AVP-MV] DVR from-beginning seek queued title=\(channelName)")
        }
        if isVOD || isDVR, let ms = resumeMs, ms > 2_000 {
            let t = CMTime(value: CMTimeValue(ms), timescale: 1_000)
            // EXACT seek: infinite tolerance snapped to the nearest
            // segment boundary - up to ~6s drift per version switch with
            // 6s cue segments, which read as "doesn't pick back up at
            // the same time" when A/B-ing copies (field find
            // 2026-08-26). Exact costs one keyframe-to-target decode.
            avPlayer.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
            debugLog("[AVP-MV] VOD resume seek to \(ms / 1000)s (exact) title=\(channelName)")
        }
        if !shouldPause { avPlayer.play() }
        // Loopback VOD: keep a spinner up until the clock actually
        // moves. The first segment build on a resumed 4K title over
        // slow Wi-Fi can take close to a minute, and the screen was
        // pure black the whole time (2026-08-26 iPhone find). Cleared
        // by the currentMs observer below the body.
        if isLoopbackVOD { statusText = "Buffering..." }
        player = avPlayer
        // Bridge this tile's AVPlayer into the chrome's store. When this
        // tile is the audio tile, the container chrome's scrubber /
        // play-pause / track pickers / stream info now drive it (they
        // were inert over an AVPlayer tile before). Tear any prior one
        // down first (channel swap reuses the tile).
        driver?.teardown()
        // isLive must be truthful: the driver's duration/position
        // observers all guard on it, so a VOD tile driven as live gets
        // durationMs 0 and the chrome renders the scrubber-less live
        // layout (field find: "can't scrub at all", Speak No Evil).
        driver = AVPlayerProgressDriver(
            player: avPlayer, store: progressStore,
            isLive: !(isVOD || isDVR || catchup != nil), applyGravity: { _ in })
        // Where a stall-learned hold-back is recorded for the NEXT tune.
        driver?.liveHoldbackKey = holdbackKey
        // A TARGETDURATION that grows during the first 30 s (a long GOP
        // lands and the pin rises) leaves the join offset too small; the
        // driver re-applies it, but ONLY inside that window and ONLY with
        // an empty buffer, because writing this on a healthy playing item
        // is what seeks backward.
        if isLiveTune, let mux = remuxer {
            driver?.appliedLiveOffset = driverJoinOffset
            driver?.liveOffsetFloor = driverOffsetFloor
            driver?.liveTargetDuration = { mux.advertisedTargetDuration.get() }
        }
        // First frame closes the press-to-picture clock and releases any
        // display-mode switch that was deferred out of the tune.
        driver?.onFirstFrame = {
            // TuneTimeline.firstFrame() is closed by the driver itself at
            // the same moment (it owns the clock-advance detection).
            guard !firstFrameSeen else { return }
            firstFrameSeen = true
            if let pending = pendingDisplayCriteria {
                pendingDisplayCriteria = nil
                debugLog("[AVP-DISPLAY] applying deferred display criteria now that the first frame is up")
                applyDisplayCriteria(width: pending.width, height: pending.height,
                                     fps: pending.fps, is10Bit: pending.tenBit, force: true)
            }
        }
        if let cu = catchup {
            // Pinned EPG duration + base-offset position composition; the
            // chrome's seekAction becomes the window re-tune (must come
            // AFTER driver init - wireCommands just installed the plain
            // seek).
            driver?.catchupBaseMs = catchupBaseMs
            progressStore.durationMs = cu.programDurationMs
            progressStore.seekAction = { target in performCatchupSeek(target, cu) }
        }
        if liveRewindArmed, !isVOD, !isDVR {
            driver?.liveRewindWindowActive = true
            LiveRewindEngine.shared.beginExternalWindow(owner: tileID)
        }
        // MKV-remux tiles: tell the loopback server about every user seek
        // so it can drop the old neighbourhood's span/segment caches
        // (~200MB of stale Data on a high-bitrate title). Wrap must come
        // AFTER driver init (wireCommands just installed the plain seek)
        // and stays out of the catch-up branch (mutually exclusive with
        // mkvServer, but ordering here keeps that obvious).
        if isVOD, let srv = mkvServer {
            let baseSeek = progressStore.seekAction
            progressStore.seekAction = { [weak srv] target in
                srv?.noteSeek()
                baseSeek?(target)
            }
        }
        // MKV subtitle picker: the overlay store owns subtitle state, so
        // the store's subtitle fields are OURS, not the driver's (the
        // legible group is empty - subs never ride the HLS master, see
        // AVPSubtitleCueStore). Must come AFTER the driver init above:
        // wireCommands just reassigned setSubtitleTrackAction.
        if isVOD, mkvServer != nil, !subtitleStore.tracks.isEmpty {
            let subStore = subtitleStore
            let store = progressStore
            store.externalSubtitleControl = true
            store.subtitleTracks = subStore.tracks.map {
                MediaTrack(id: $0.number, type: "sub", title: $0.name,
                           lang: $0.language, codec: "", isDefault: false)
            }
            store.currentSubtitleTrackID = 0
            store.setSubtitleTrackAction = { id in
                subStore.activeTrack = id == 0 ? nil : id
                store.currentSubtitleTrackID = id
                debugLog("[AVP-MV] subtitle track -> \(id == 0 ? "off" : String(id))")
            }
        }
        // Fast path: AVFoundation's own diagnosis of a rejected playlist / failed
        // reload arrives as an errorLog entry; escalate the fatal codes straight
        // to the mpv engine instead of logging and stranding the tile.
        driver?.onUnrecoverable = { failOrFallback($0) }
        // Report the real video aspect once decode knows it, so the
        // focus border can trace the picture instead of the tile frame.
        // presentationSize fires repeatedly (often with the SAME size) as the
        // pipeline settles; each distinct value writes @Published
        // tileVideoAspects, which re-lays out the whole container. removeDuplicates()
        // collapses the redundant fires so the aspect (and its layout pass) lands
        // once instead of on every KVO tick during the first-frame window. The
        // timing log tells us, from the next device run, whether that layout pass
        // is the ~650ms first-frame hang or whether the cost is inside
        // AVFoundation's own first-frame decode (in which case it isn't ours to fix).
        sizeObservation = playerItem.publisher(for: \.presentationSize)
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { size in
                guard size.width > 0, size.height > 0 else { return }
                let t0 = Date()
                MultiviewStore.shared.registerVideoAspect(size.width / size.height, for: tileID)
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                if ms > 50 {
                    debugLog("[AVP-MV] registerVideoAspect relayout took \(ms)ms (size=\(Int(size.width))x\(Int(size.height)))")
                }
            }

        // Stall/freeze watchdog. Covers the old audio-only/no-renderable-video
        // case (HEVC-in-TS reaches readyToPlay with presentationSize 0x0) AND,
        // unlike the previous one-shot +4s check, keeps watching so a mid-stream
        // wedge (a rejected LL reload, a stuck live edge) that arrives AFTER the
        // first frame still self-heals to the mpv engine. Self-invalidates on
        // channel swap (currentItem changes); stop() invalidates it on teardown.
        stallWatchdog?.cancel()
        let progressServer = mkvServer
        let watchdog = AVPStallWatchdog(
            player: avPlayer, item: playerItem, label: "tile \(channelName)",
            mediaBytes: progressServer.map { s in { s.mediaBytesStreamed } },
            onDead: { failOrFallback($0) })
        #if os(iOS)
        // Started on the LAN for an AirPlay receiver: the local clock is
        // the receiver's, not a render the phone can judge.
        if airPlayDelivery.isServing { watchdog.setSuspended(true, item: nil) }
        #endif
        watchdog.start()
        stallWatchdog = watchdog
    }

    private func stop(allowRetain: Bool = true) {
        tileStopped = true
        // No stall overlay survives a pipeline teardown.
        ingestSilent = false
        stallEvalToken = UUID()
        // Disarm the deadline with the pipeline, but KEEP the tried set:
        // an internal retry (503 ladder, fresh pipeline) is the same tune
        // on the same channel, and re-walking streams we already proved
        // silent would loop (s7_86.txt:353-395). Only a channel flip or
        // the tile going away clears the walk.
        firstByteDeadlineToken = UUID()
        firstByteSeen = false
        // Next tune gets its own fast start and its own deferred
        // display-mode switch.
        firstFrameSeen = false
        pendingDisplayCriteria = nil
        if liveRewindArmed {
            LiveRewindEngine.shared.endExternalWindow(owner: tileID)
            // Channel retention: hand a HEALTHY rewind session to the
            // manager instead of stopping it, so flipping back resumes
            // the full window. Errored tiles stop as before.
            if allowRetain, LiveChannelRetention.isEnabled, tileError == nil,
               let mux = remuxer, let url = readyLocalURL,
               let key = sessionRetainKey, let chID = sessionRetainChannelID {
                LiveChannelRetention.shared.retain(
                    key: key, channelID: chID,
                    channelName: sessionRetainName ?? channelName,
                    remuxer: mux, localURL: url)
                remuxer = nil
            }
            sessionRetainKey = nil
            sessionRetainChannelID = nil
        }
        driver?.teardown()
        driver = nil
        player?.pause()
        player = nil
        #if os(iOS)
        airPlayDelivery.reset()
        AirPlayMonitor.shared.detach()
        #endif
        if remuxer != nil, !isVOD, !isDVR, catchup == nil, let releasedKey = sessionRetainKey {
            // This upstream is now in the provider's asynchronous
            // teardown; a re-open of it inside the next few seconds is
            // the 503 case the flip path settles for. sessionRetainKey,
            // NEVER the struct's streamURL: a channel-flip onChange has
            // already advanced streamURL to the INCOMING channel (same
            // trap the retain snapshot documents above), so using it here
            // would mark the channel we are about to open as released.
            LiveUpstreamReleases.note(releasedKey)
        }
        remuxer?.stop()
        remuxer = nil
        mkvServer?.stop()
        mkvServer = nil
        statusText = nil
        tileError = nil
        readyLocalURL = nil
        sizeObservation = nil
        stallWatchdog?.cancel()
        stallWatchdog = nil
        subtitleStore.reset()
        progressStore.externalSubtitleControl = false
        MultiviewStore.shared.unregisterVideoAspect(for: tileID)
        #if os(tvOS)
        if let dm = appliedDisplayManager {
            appliedDisplayManager = nil
            DispatchQueue.main.async { DisplayCriteriaCoordinator.scheduleClear(dm) }
        }
        #endif
    }

    /// tvOS display-mode match for the AVPlayer tile. A bare
    /// AVPlayerLayer never triggers Match Content on its own (that is an
    /// AVPlayerViewController behavior), so the panel would stay at the
    /// home-screen 4K SDR 60 no matter what plays - the 2026-08-25 field
    /// report for the fMP4 arm's first run (HDR did not engage, TV stayed
    /// at 60Hz). Mirrors MPVPlayerView.applyMetalHDRDisplayCriteria: a
    /// distinctive-shape CMVideoFormatDescription, BT.2020/PQ extensions
    /// when the mux is 10-bit, at the measured refresh rate. The system
    /// converts HLG under an HDR10 HDMI mode, same as the mpv Metal path.
    /// `force` skips the defer check: it is the deferred apply itself,
    /// running from the first-frame callback, and must not re-defer on a
    /// stale read of `firstFrameSeen`.
    private func applyDisplayCriteria(width: Int, height: Int, fps: Double,
                                      is10Bit: Bool, force: Bool = false) {
        #if os(tvOS)
        guard !tileStopped else {
            debugLog("[AVP-DISPLAY] criteria apply skipped: tile already stopped")
            return
        }
        guard fps > 10, fps < 130 else { return }
        // The HDMI mode change is SERIALIZED INTO THE TUNE (review
        // 2026-09-11 section 1 proposal 6). session.txt:3375-3380: the
        // criteria were set at 15:00:31.839, the panel answered 3 s
        // later, and the remuxer produced nothing for 3.99 s across the
        // switch - on a request for 59.94 Hz SDR while the panel was
        // ALREADY at 60. Two changes: skip a no-op switch outright, and
        // otherwise defer the real one until the first frame is playing
        // (HDR and 50 Hz still engage, just a beat later).
        let signature = String(format: "%dx%d|%@|%.2f", width, height,
                               is10Bit ? "PQ" : "SDR", fps)
        if DisplayCriteriaCoordinator.lastAppliedSignature == signature {
            debugLog("[AVP-DISPLAY] display criteria unchanged (\(signature)); no mode switch")
            return
        }
        if !force, !firstFrameSeen {
            pendingDisplayCriteria = (width, height, fps, is10Bit)
            debugLog("[AVP-DISPLAY] display criteria deferred until first frame (\(signature))")
            return
        }
        let window: UIWindow? = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?
            .keyWindow
        guard let window else {
            debugLog("[AVP-DISPLAY] display criteria skipped: no window available")
            return
        }
        // Nothing applied yet this session and the panel already runs at
        // the requested SDR rate: the switch would be a no-op that costs
        // seconds of ingest (row 8 of the review's table).
        if DisplayCriteriaCoordinator.lastAppliedSignature == nil, !is10Bit,
           Int(fps.rounded()) == window.screen.maximumFramesPerSecond {
            debugLog("[AVP-DISPLAY] panel already at \(window.screen.maximumFramesPerSecond)Hz SDR; "
                + "skipping no-op mode switch (\(signature))")
            return
        }
        var extensions: [CFString: Any]?
        if is10Bit {
            extensions = [
                kCMFormatDescriptionExtension_ColorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_2020,
                kCMFormatDescriptionExtension_TransferFunction: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ,
                kCMFormatDescriptionExtension_YCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020,
            ]
        }
        var formatDesc: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: is10Bit ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            width: width > 0 ? Int32(width) : 1920,
            height: height > 0 ? Int32(height) : 1080,
            extensions: extensions as CFDictionary?,
            formatDescriptionOut: &formatDesc)
        guard status == noErr, let formatDesc else {
            debugLog("[AVP-DISPLAY] CMVideoFormatDescriptionCreate failed: \(status)")
            return
        }
        let dm = window.avDisplayManager
        appliedDisplayManager = dm
        DisplayCriteriaCoordinator.apply(
            AVDisplayCriteria(refreshRate: Float(fps), formatDescription: formatDesc), to: dm,
            signature: signature)
        debugLog("[AVP-DISPLAY] display criteria set: \(width)x\(height) " +
                 "\(is10Bit ? "bt.2020/PQ" : "SDR") @ \(String(format: "%.2f", fps))Hz " +
                 "(matchingEnabled=\(dm.isDisplayCriteriaMatchingEnabled))")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak window] in
            guard let screen = window?.screen else { return }
            debugLog("[AVP-DISPLAY] panel reports \(screen.maximumFramesPerSecond)Hz 3s after criteria request")
        }
        #endif
    }
}

/// Bare AVPlayerLayer host: video only, no system chrome, sized by
/// SwiftUI like any other tile content.
struct AVPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    /// Sizing mode for the video inside the layer. Defaults to the
    /// previous hardcoded letterbox so existing call sites (multiview
    /// tiles) are unaffected; the unified player chrome drives it from
    /// the shared aspect setting.
    var videoGravity: AVLayerVideoGravity = .resizeAspect
    /// Non-nil arms Picture in Picture on THIS layer (solo/fullscreen
    /// hosts only; grid tiles pass nil). PiP under the AVPlayer engine
    /// is a plain AVPlayerLayer controller - the mpv path's sample-
    /// buffer PiP never applied here, which is why swipe-home produced
    /// no PiP window at all on the remux engine (field 2026-08-29).
    /// Auto-start from inline only, matching the mpv policy; the
    /// delegate mirrors active state into the store so the tile's
    /// background handler knows iOS is driving the window.
    var pipStore: PlayerProgressStore? = nil

    final class HostView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        /// Diagnostic: when the video plane ACTUALLY has a frame to
        /// show, vs the item clock/audio (audio-before-video hunts).
        var readyObservation: NSKeyValueObservation?
        var attachedAt = Date()
    }

    final class PiPCoordinator: NSObject, AVPictureInPictureControllerDelegate {
        var controller: AVPictureInPictureController?
        weak var store: PlayerProgressStore?
        /// AirPlay (plan section 7): auto-start from inline is disarmed
        /// while a receiver is served from this tile, re-armed after.
        var airPlaySubscription: AnyCancellable?

        func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
            // Synchronous, and iOS fires it BEFORE didEnterBackground -
            // the tile's background quiesce reads this flag to stand
            // down while PiP owns playback (mpv-path parity).
            store?.isPiPActive = true
            debugLog("[AVP-PIP] will start")
        }

        func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
            debugLog("[AVP-PIP] did start")
            #if os(iOS)
            let pipID = ObjectIdentifier(controller)
            MainActor.assumeIsolated { ForegroundPiPBridge.shared.handleDidStart(pipID) }
            #endif
        }

        func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
            store?.isPiPActive = false
            debugLog("[AVP-PIP] did stop")
            #if os(iOS)
            let pipID = ObjectIdentifier(controller)
            MainActor.assumeIsolated { ForegroundPiPBridge.shared.handleDidStop(pipID) }
            #endif
        }

        func pictureInPictureController(_ controller: AVPictureInPictureController,
                                        failedToStartPictureInPictureWithError error: Error) {
            store?.isPiPActive = false
            debugLog("[AVP-PIP] failed to start: \(error.localizedDescription)")
            #if os(iOS)
            let pipID = ObjectIdentifier(controller)
            MainActor.assumeIsolated { ForegroundPiPBridge.shared.handleFailedToStart(pipID) }
            #endif
        }

        func pictureInPictureController(_ controller: AVPictureInPictureController,
                                        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler
                                        completionHandler: @escaping (Bool) -> Void) {
            // The hosting SwiftUI screen stays mounted through PiP, so
            // there is nothing to rebuild - just confirm. A swipe-started
            // PiP ran with the player minimized: expand it first so the
            // window animates back into a fullscreen layer.
            #if os(iOS)
            let pipID = ObjectIdentifier(controller)
            MainActor.assumeIsolated { _ = ForegroundPiPBridge.shared.handleRestore(pipID) }
            #endif
            completionHandler(true)
        }
    }

    func makeCoordinator() -> PiPCoordinator { PiPCoordinator() }

    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = videoGravity
        view.attachedAt = Date()
        view.readyObservation = view.playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { layer, _ in
            let ms = Int(Date().timeIntervalSince(view.attachedAt) * 1000)
            debugLog("[AVP-LAYER] isReadyForDisplay=\(layer.isReadyForDisplay) at +\(ms)ms from layer attach")
        }
        syncPiP(view, context.coordinator)
        return view
    }

    func updateUIView(_ view: HostView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
        if view.playerLayer.videoGravity != videoGravity {
            view.playerLayer.videoGravity = videoGravity
            debugLog("[VIDEO-SCALE] applied layer=avplayerlayer gravity=\(videoGravity.rawValue)")
        }
        syncPiP(view, context.coordinator)
    }

    /// Arm or disarm the PiP controller to match [pipStore]. The
    /// controller binds to the LAYER, so player swaps on the same host
    /// view (retry, version switch) keep the same controller.
    private func syncPiP(_ view: HostView, _ coordinator: PiPCoordinator) {
        #if os(iOS)
        if let store = pipStore {
            coordinator.store = store
            if coordinator.controller == nil,
               AVPictureInPictureController.isPictureInPictureSupported() {
                if let pip = AVPictureInPictureController(playerLayer: view.playerLayer) {
                    pip.delegate = coordinator
                    let external = MainActor.assumeIsolated { AirPlayTileDelivery.isServingReceiver }
                    pip.canStartPictureInPictureAutomaticallyFromInline = !external
                    coordinator.controller = pip
                    MainActor.assumeIsolated { ForegroundPiPBridge.shared.register(pip) }
                    debugLog("[AVP-PIP] controller armed (auto-start from inline: \(external ? "disarmed, AirPlay external" : "on"))")
                    MainActor.assumeIsolated {
                        coordinator.airPlaySubscription = AirPlayTileDelivery.serving
                            .dropFirst()
                            .removeDuplicates()
                            .sink { [weak pip] serving in
                                guard let pip,
                                      pip.canStartPictureInPictureAutomaticallyFromInline == serving else { return }
                                pip.canStartPictureInPictureAutomaticallyFromInline = !serving
                                debugLog(serving ? "[AVP-PIP] auto-start from inline disarmed (AirPlay external)"
                                                 : "[AVP-PIP] auto-start from inline re-armed")
                            }
                    }
                }
            }
        } else if let existing = coordinator.controller {
            // Tile count grew past solo: PiP is a fullscreen-only
            // affordance, mirror the mpv policy and drop it.
            existing.delegate = nil
            coordinator.controller = nil
            coordinator.airPlaySubscription = nil
            coordinator.store?.isPiPActive = false
            MainActor.assumeIsolated { ForegroundPiPBridge.shared.unregister(existing) }
            debugLog("[AVP-PIP] controller disarmed (no longer solo)")
        }
        #endif
    }
}


/// Last video cadence MEASURED by the TS/fMP4 remuxer, for readouts that
/// have no other source: remuxed fMP4 declares no nominal frame rate, so
/// `AVAssetTrack.nominalFrameRate` is 0 on that path and
/// `currentVideoFrameRate` only fills in once frames render.
@MainActor
final class RemuxMeasuredVideo: ObservableObject {
    static let shared = RemuxMeasuredVideo()
    /// 0 when nothing is known for the current stream.
    @Published private(set) var fps: Double = 0
    /// True once the rate came from the stream's OWN declaration (H.264
    /// SPS VUI timing). A declared rate is never replaced by a measured
    /// one (Logan 2026-09-11).
    @Published private(set) var isDeclared = false
    /// Interlaced per the SPS (frame_mbs_only_flag == 0).
    @Published private(set) var isInterlaced = false

    private init() {}

    func note(fps: Double, declared: Bool = false, interlaced: Bool? = nil) {
        if let interlaced, interlaced != isInterlaced { isInterlaced = interlaced }
        guard fps > 0 else { return }
        if isDeclared, !declared { return }
        if declared, !isDeclared { isDeclared = true }
        if abs(fps - self.fps) > 0.001 { self.fps = fps }
    }

    /// New source: forget the previous stream's cadence.
    func reset() {
        if fps != 0 { fps = 0 }
        if isDeclared { isDeclared = false }
        if isInterlaced { isInterlaced = false }
    }
}

/// Standard broadcast frame rates every readout snaps to.
enum VideoRateStandards {
    static let all: [Double] = [23.976, 24, 25, 29.97, 30, 50, 59.94, 60]

    /// Snap to the nearest standard when within `tolerance` (default 1%),
    /// otherwise return the input untouched. Measured cadences drift; a
    /// declared one does not, but snapping a declared 29.97 that arrives
    /// as 29.969999 is harmless.
    static func snap(_ fps: Double, tolerance: Double = 0.01) -> Double {
        guard fps > 0, let nearest = all.min(by: { abs($0 - fps) < abs($1 - fps) }) else { return fps }
        return abs(nearest - fps) / nearest <= tolerance ? nearest : fps
    }
}

/// H.264 SPS reader for the bits the readouts need: the VUI timing info
/// (the stream's OWN declared cadence) and `frame_mbs_only_flag` (0 for
/// an interlaced source). Reading the declared rate is the only way to
/// be right on a feed whose PTS deltas are perturbed by genpts /
/// nobuffer / discontinuity handling (Logan 2026-09-11: a 59.94 feed
/// measured as 32).
enum H264SPSTiming {
    struct Info {
        /// FRAME rate. For H.264 the VUI clock ticks twice per frame, so
        /// this is time_scale / (2 * num_units_in_tick). A 1080i59.94
        /// ATSC feed carries time_scale 60000 / num_units_in_tick 1001,
        /// i.e. 29.97 FRAMES per second (59.94 fields), and its
        /// frame_mbs_only_flag is 0, so the readouts say 1080i 29.97.
        var fps: Double
        var isInterlaced: Bool
    }

    /// `nal` is one SPS NAL unit WITHOUT its start code, first byte the
    /// NAL header. Returns nil when the SPS carries no timing info or
    /// cannot be parsed.
    static func parse(_ nal: [UInt8]) -> Info? {
        guard nal.count > 4, (nal[0] & 0x1F) == 7 else { return nil }
        // Strip emulation prevention bytes.
        var rbsp: [UInt8] = []
        rbsp.reserveCapacity(nal.count)
        var zeros = 0
        for b in nal.dropFirst() {
            if zeros == 2, b == 0x03 { zeros = 0; continue }
            rbsp.append(b)
            zeros = b == 0 ? zeros + 1 : 0
        }
        var r = Reader(rbsp)
        do {
            let profile = try r.bits(8)
            _ = try r.bits(8)            // constraint flags + reserved
            _ = try r.bits(8)            // level_idc
            _ = try r.ue()               // seq_parameter_set_id
            if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profile) {
                let chroma = try r.ue()
                if chroma == 3 { _ = try r.bit() }  // separate_colour_plane_flag
                _ = try r.ue()           // bit_depth_luma_minus8
                _ = try r.ue()           // bit_depth_chroma_minus8
                _ = try r.bit()          // qpprime_y_zero_transform_bypass_flag
                if try r.bit() == 1 {    // seq_scaling_matrix_present_flag
                    let count = chroma != 3 ? 8 : 12
                    for i in 0..<count where try r.bit() == 1 {
                        try skipScalingList(&r, size: i < 6 ? 16 : 64)
                    }
                }
            }
            _ = try r.ue()               // log2_max_frame_num_minus4
            let pocType = try r.ue()
            if pocType == 0 {
                _ = try r.ue()           // log2_max_pic_order_cnt_lsb_minus4
            } else if pocType == 1 {
                _ = try r.bit()          // delta_pic_order_always_zero_flag
                _ = try r.se()           // offset_for_non_ref_pic
                _ = try r.se()           // offset_for_top_to_bottom_field
                let cycle = try r.ue()
                for _ in 0..<cycle { _ = try r.se() }
            }
            _ = try r.ue()               // max_num_ref_frames
            _ = try r.bit()              // gaps_in_frame_num_value_allowed_flag
            _ = try r.ue()               // pic_width_in_mbs_minus1
            _ = try r.ue()               // pic_height_in_map_units_minus1
            let frameMbsOnly = try r.bit()
            if frameMbsOnly == 0 { _ = try r.bit() }   // mb_adaptive_frame_field_flag
            _ = try r.bit()              // direct_8x8_inference_flag
            if try r.bit() == 1 {        // frame_cropping_flag
                _ = try r.ue(); _ = try r.ue(); _ = try r.ue(); _ = try r.ue()
            }
            guard try r.bit() == 1 else { return nil }  // vui_parameters_present_flag
            if try r.bit() == 1 {        // aspect_ratio_info_present_flag
                let idc = try r.bits(8)
                if idc == 255 { _ = try r.bits(16); _ = try r.bits(16) }
            }
            if try r.bit() == 1 { _ = try r.bit() }     // overscan
            if try r.bit() == 1 {        // video_signal_type_present_flag
                _ = try r.bits(3)        // video_format
                _ = try r.bit()          // video_full_range_flag
                if try r.bit() == 1 { _ = try r.bits(24) }  // colour description
            }
            if try r.bit() == 1 { _ = try r.ue(); _ = try r.ue() }  // chroma_loc
            guard try r.bit() == 1 else { return nil }  // timing_info_present_flag
            let numUnitsInTick = try r.bits(32)
            let timeScale = try r.bits(32)
            guard numUnitsInTick > 0, timeScale > 0 else { return nil }
            let fps = Double(timeScale) / (2.0 * Double(numUnitsInTick))
            guard fps >= 1, fps <= 480 else { return nil }
            return Info(fps: VideoRateStandards.snap(fps), isInterlaced: frameMbsOnly == 0)
        } catch {
            return nil
        }
    }

    private static func skipScalingList(_ r: inout Reader, size: Int) throws {
        var last = 8, next = 8
        for _ in 0..<size {
            if next != 0 {
                let delta = try r.se()
                next = (last + delta + 256) % 256
            }
            last = next == 0 ? last : next
        }
    }

    struct Reader {
        private let bytes: [UInt8]
        private var pos = 0
        enum Err: Error { case eof }
        init(_ b: [UInt8]) { bytes = b }

        mutating func bit() throws -> Int {
            let byte = pos >> 3
            guard byte < bytes.count else { throw Err.eof }
            let v = (Int(bytes[byte]) >> (7 - (pos & 7))) & 1
            pos += 1
            return v
        }
        mutating func bits(_ n: Int) throws -> UInt32 {
            var v: UInt32 = 0
            for _ in 0..<n { v = (v << 1) | UInt32(try bit()) }
            return v
        }
        mutating func ue() throws -> Int {
            var zeros = 0
            while try bit() == 0 { zeros += 1; if zeros > 31 { throw Err.eof } }
            if zeros == 0 { return 0 }
            let rest = Int(try bits(zeros))
            return (1 << zeros) - 1 + rest
        }
        mutating func se() throws -> Int {
            let k = try ue()
            return k % 2 == 0 ? -(k / 2) : (k + 1) / 2
        }
    }
}

