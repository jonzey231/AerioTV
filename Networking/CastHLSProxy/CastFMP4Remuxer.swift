//
//  CastFMP4Remuxer.swift
//  Aerio
//
//  MPEG-TS to fragmented-MP4 (CMAF) remuxer for the phone-local cast HLS
//  proxy (GH #33 web-receiver rework, P2). Direct port of the Android
//  implementation that survived a 4h10m hardware soak; behavior parity
//  with that build is the contract here.
//

import Foundation

/// A stream the cast HLS proxy cannot serve. The web receiver is a
/// Chromium page; MSE there decodes H.264 + AAC only, and video is never
/// re-encoded, so non-H.264 video refuses up front with the codec name
/// for the user-facing message. AC-3/E-AC-3/MP2 audio transcodes on the
/// phone instead of refusing; this still fires for audio outside that
/// family and for transcodable audio the device cannot decode.
struct CastUnsupportedCodecError: Error, CustomStringConvertible {
    /// Which elementary stream refused; the sender words a different
    /// message for each (video can never be re-encoded, audio can).
    enum Stream { case video, audio }
    let codecName: String
    var stream: Stream = .audio
    var description: String { "cast HLS proxy cannot serve \(codecName)" }
}

/// Abstraction over the AudioToolbox transcoder so the remuxer's pure
/// logic is testable off-device with a fake.
protocol CastAudioTranscoding: AnyObject {
    /// Queue one whole source frame (AC-3/E-AC-3/MP2 syncframe). Throws
    /// `CastUnsupportedCodecError` when the platform has no decoder.
    func feed(_ data: [UInt8], range: Range<Int>, ptsTicks: Int64, info: CastESFrameInfo) throws
    /// Splice/reconnect: drop in-flight state and re-anchor output PTS.
    func flush()
    /// Final teardown of the converters.
    func release()
}

/// Ingests raw TS bytes off the wire, demuxes to elementary streams, and
/// emits CMAF init + media segments:
///  - `onInitSegment` fires once, as soon as SPS/PPS (and the audio
///    config when the PMT declares audio) have been seen: ftyp + moov
///    with one video and optionally one audio track, timescale 90000 on
///    both so PES 90 kHz timestamps ride through untouched.
///  - `onMediaSegment` fires per segment: one moof (two trafs sharing
///    one mdat, video data first), cut ONLY on video keyframes,
///    targeting `targetSegmentTicks`. baseMediaDecodeTime is the
///    segment's first DTS rebased to the session start, carried through
///    the 33-bit PTS wraparound by a per-track unwrapper.
///
/// H.264 video is pure passthrough (Annex B converted to 4-byte-length
/// avc1 samples); audio is ADTS AAC passthrough or an on-phone
/// AC-3/E-AC-3/MP2 to AAC-LC stereo transcode (the field lineup is
/// mostly AC-3, which the web receiver cannot decode).
///
/// Threading: single-caller. `feed` runs on the ingest queue only; no
/// internal locking.
final class CastFMP4Remuxer {

    static let ticksPerSecond: Int64 = 90_000
    private static let tsPacket = 188
    private static let ptsWrap: Int64 = 1 << 33

    private static let videoTrackID = 1
    private static let audioTrackID = 2

    /// ISO 13818-1 stream_type values this remux understands.
    private static let streamTypeH264 = 0x1B
    private static let streamTypeAACADTS = 0x0F

    /// Names for the refusal message; anything not listed reports the
    /// raw stream_type.
    private static let streamTypeNames: [Int: String] = [
        0x01: "MPEG-1 video", 0x02: "MPEG-2 video", 0x10: "MPEG-4 Part 2 video",
        0x24: "HEVC video", 0x42: "AVS video", 0xEA: "VC-1 video",
        0x03: "MP3 audio", 0x04: "MP2 audio", 0x11: "AAC-LATM audio",
        0x81: "AC-3 audio", 0x87: "E-AC-3 audio", 0x82: "DTS audio", 0x8A: "DTS audio",
    ]
    private static let videoStreamTypes: Set<Int> = [0x01, 0x02, 0x10, 0x1B, 0x24, 0x42, 0xEA]
    private static let audioStreamTypes: Set<Int> = [0x03, 0x04, 0x0F, 0x11, 0x81, 0x87, 0x82, 0x8A]

    /// stream_types the audio transcode can take instead of a refusal.
    /// MPEG-1 audio (0x03) rides the same decoder family as MP2.
    private static let transcodeSources: [Int: CastAudioSourceCodec] = [
        0x81: .ac3, 0x87: .eac3, 0x03: .mp2, 0x04: .mp2,
    ]

    /// What to do with audio the web receiver's MSE cannot decode.
    /// `allowAC3Passthrough` flips AC-3 / E-AC-3 to a pure passthrough
    /// (no decode, no encode, original channel layout) and is set by the
    /// sender only for receivers that actually decode it; everything else
    /// keeps the AudioToolbox transcode as the fallback.
    private let allowAC3Passthrough: Bool

    /// Speaker-layout label for the Stream Info audio path. Total decoded
    /// channels (LFE included) to the familiar x.1 names.
    private static func channelLabel(_ channels: Int) -> String {
        switch channels {
        case 1: return "mono"
        case 2: return "stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(channels)ch"
        }
    }

    var onInitSegment: ((Data) -> Void)?
    /// `durationTicks` is the segment's video span in 90 kHz ticks.
    var onMediaSegment: ((Data, Int64) -> Void)?

    /// Per segment: the numbers needed to do the playhead-vs-buffer
    /// arithmetic from the sender log alone.
    ///
    /// Added 2026-09-12 on Logan's order ("I need you to not guess. Add
    /// something in logging so you can see it."): with
    /// manifest.hls.sequenceMode=false the receiver takes segment
    /// timestamps from the MEDIA (our tfdt boxes) and segment positions
    /// from the PLAYLIST (accumulated EXTINF from 0), and on the
    /// 15:10:03 Google TV Streamer session those two timelines only
    /// agreed by luck: Shaka picked a start position of 2.439 s (window
    /// end 11.311 s minus the 9 s presentation delay) BEFORE any media
    /// was appended, then relocated to 0.016 s once it saw the buffer
    /// (MediaGapJumped=1) and pinned at -58 ms in BUFFERING forever. The
    /// receiver page prints nothing that reaches logcat, so these are
    /// the only numbers we can actually read.
    ///
    /// All four Doubles are SECONDS RELATIVE TO `timelineBase`, i.e.
    /// exactly what lands in the tfdt boxes divided by the 90 kHz tick
    /// rate. `firstVideoPTSSeconds` is the video track's earliest
    /// presentation time; `max(firstVideoPTSSeconds,
    /// firstAudioPTSSeconds)` is where a two-track SourceBuffer's
    /// buffered range actually BEGINS, because Chromium reports the
    /// INTERSECTION of the tracks' ranges, not their union.
    /// `firstAudioPTSSeconds` is -1.0 when the segment has no audio.
    var onSegmentComposition: ((_ videoSamples: Int, _ audioSamples: Int,
                                _ firstVideoDTSSeconds: Double, _ firstVideoPTSSeconds: Double,
                                _ firstAudioPTSSeconds: Double,
                                _ segmentStartSeconds: Double) -> Void)?

    private let targetSegmentTicks: Int64
    private let log: (String) -> Void
    /// Injectable for the CLI tests (AudioToolbox codecs are not
    /// exercised there); production uses the real transcoder.
    private let transcoderFactory: (CastAudioSourceCodec,
                                    @escaping (_ asc: [UInt8], _ sampleRate: Int) -> Void,
                                    @escaping (_ data: [UInt8], _ ptsTicks: Int64) -> Void) -> CastAudioTranscoding

    init(targetSegmentTicks: Int64 = 3 * CastFMP4Remuxer.ticksPerSecond,
         allowAC3Passthrough: Bool = false,
         log: @escaping (String) -> Void = { _ in },
         transcoderFactory: ((CastAudioSourceCodec,
                              @escaping (_ asc: [UInt8], _ sampleRate: Int) -> Void,
                              @escaping (_ data: [UInt8], _ ptsTicks: Int64) -> Void) -> CastAudioTranscoding)? = nil) {
        self.targetSegmentTicks = targetSegmentTicks
        self.allowAC3Passthrough = allowAC3Passthrough
        self.log = log
        self.transcoderFactory = transcoderFactory ?? { source, onConfig, onFrame in
            CastAudioTranscoder(source: source, onEncoderConfig: onConfig, onAACFrame: onFrame, log: log)
        }
    }

    // MARK: TS layer state

    /// Packet-boundary carry: the ingest hands arbitrary chunk sizes and
    /// Dispatcharr joins clients mid-packet, so bytes are re-aligned on a
    /// verified triple 0x47 before anything downstream sees them.
    private var carry: [UInt8] = []
    private var needResync = true

    private var pmtPID = -1
    private var videoPID = -1
    private var audioPID = -1
    /// PMT parsed; `audioPID` < 0 after this means a video-only mux.
    private var pmtSeen = false

    private lazy var videoPES = PESAssembler { [weak self] payload, pts, dts in
        self?.onVideoAccessUnit(payload, pts33: pts, dts33: dts)
    }
    private lazy var audioPES = PESAssembler { [weak self] payload, pts, _ in
        try self?.onAudioPES(payload, pts33: pts)
    }

    // MARK: codec config

    private var sps: [UInt8]?
    private var pps: [UInt8]?
    private var aacObjectType = 0
    private var aacFreqIndex = -1
    private var aacChannelConfig = 0

    /// Latched once so the PCE strip is announced a single time instead of
    /// for every frame of the connection.
    private var aacPCELogged = false
    private var initSent = false

    // MARK: audio transcode

    /// Non-nil when the PMT's audio is AC-3/E-AC-3/MP2; nil keeps the
    /// ADTS AAC passthrough path untouched.
    private var audioSource: CastAudioSourceCodec?
    private var transcoder: CastAudioTranscoding?
    /// Encoder AudioSpecificConfig; gates the init segment the same way
    /// the ADTS header does on the passthrough path.
    private var transcodeASC: [UInt8]?
    private var transcodeSampleRate = 0
    private var transcodeLogged = false
    /// Human-readable audio path for the cast Options sheet's Stream
    /// Info card ("AAC passthrough" / "AC-3 5.1 -> AAC stereo"). Set at
    /// PMT parse, refined with the channel layout once the transcode
    /// sees its first frame header.
    private(set) var audioPathDescription: String?
    /// Non-nil when the PMT's AC-3 / E-AC-3 audio rides through
    /// untouched (receiver decodes it); mutually exclusive with
    /// `audioSource`.
    private var audioPassthrough: CastAudioSourceCodec?
    /// First passthrough syncframe's bitstream config; gates the init
    /// segment and writes the dac3 / dec3 box.
    private var passthroughConfig: CastAC3SampleEntryConfig?
    private var passthroughLogged = false

    /// RFC 6381 codec name for the audio the receiver will be handed, so
    /// the playlist's CODECS attribute names the right decoder. nil for a
    /// video-only mux.
    var audioCodecsAttribute: String? {
        if audioPID < 0 { return nil }
        if let passthroughConfig { return passthroughConfig.codecsAttribute }
        if let audioPassthrough { return audioPassthrough == .eac3 ? "ec-3" : "ac-3" }
        return "mp4a.40.2"
    }
    /// Where the source audio clock should continue; a jump past the
    /// discontinuity threshold flushes the codecs (splice/reconnect).
    private var expectedSrcAudioPTS: Int64 = -1

    // MARK: timeline

    private var videoClock = PTSUnwrapper()
    private var audioClock = PTSUnwrapper()
    /// First queued video DTS; every tfdt is relative to this so the
    /// receiver's timeline starts near zero.
    private var timelineBase: Int64 = -1

    /// First queued video PRESENTATION time (dts + composition offset).
    ///
    /// Audio is gated on this, not on `timelineBase`. The Cast receiver
    /// appends our muxed segments in MSE 'sequence' AppendMode (Shaka's
    /// HLS default; Chromium logs the multitrack warning on every one of
    /// our loads), and in that mode Chromium ignores tfdt and anchors the
    /// whole append on the PRESENTATION timestamp of the first coded
    /// frame, which is our first video sample. Any audio between
    /// `timelineBase` and that presentation time therefore lands before
    /// zero and Chromium throws it away, logging on the Google TV
    /// Streamer (2026-09-12 02:27:57, iPhone session):
    ///
    ///   Dropping audio frame (DTS -24000us PTS -24000us,-2667us) that is
    ///     outside append window [0us, ...]
    ///   Truncating audio buffer which overlaps append window start.
    ///
    /// The truncated frame is then the one that fails to decode
    /// ("Failed to send audio packet for decoding ... timestamp=0",
    /// "audio decoder fallback after initial decode error"), costing the
    /// load a decoder swap and a reseek. Measured on dumped segments:
    /// audio started 56 ms before the first video presentation time.
    private var timelineBasePTS: Int64 = -1

    // MARK: pending segment

    private struct VideoSample {
        let data: [UInt8]
        let dts: Int64
        let pts: Int64
        let keyframe: Bool
    }
    private struct AudioSample {
        let data: [UInt8]
        let pts: Int64
    }

    private var videoQueue: [VideoSample] = []
    private var audioQueue: [AudioSample] = []
    /// Output AAC frame ticks: 1024 samples at the track sample rate.
    private var audioFrameTicks: Int64 = 0
    /// Audio frames can straddle PES packet boundaries; carry the tail.
    private var audioCarry: [UInt8] = []
    private var lastVideoDuration: Int64 = 3_000 // ~30 fps fallback for the first delta
    private var sequenceNumber = 0

    /// Running total of the `durationTicks` already emitted by this
    /// remuxer, i.e. the next segment's accumulated media START within
    /// the generation. One remuxer is built per generation
    /// (`CastHLSProxySession.startIngestLocked`), so the first segment of
    /// a generation reports 0. This is the PLAYLIST timeline (accumulated
    /// EXTINF from 0); the tfdt numbers above are the MEDIA timeline, and
    /// the whole point of logging both is that nothing reconciles them.
    private var emittedMediaTicks: Int64 = 0

    /// Feed raw TS bytes off the wire. Throws `CastUnsupportedCodecError`
    /// as soon as the PMT declares a codec the remux cannot carry.
    func feed(_ data: Data) throws {
        var merged: [UInt8]
        if carry.isEmpty {
            merged = [UInt8](data)
        } else {
            merged = carry
            merged.append(contentsOf: data)
        }
        if needResync {
            guard let sync = Self.findSync(merged) else {
                carry = Array(merged.suffix(Self.tsPacket * 2 + 1))
                return
            }
            if sync > 0 { merged.removeFirst(sync) }
            needResync = false
        }
        let whole = (merged.count / Self.tsPacket) * Self.tsPacket
        carry = whole < merged.count ? Array(merged[whole...]) : []
        var p = 0
        while p < whole {
            if merged[p] != 0x47 {
                // Lost sync mid-stream (provider glitch): rescan from here.
                needResync = true
                carry = []
                guard let resync = Self.findSync(Array(merged[p..<whole])) else { return }
                p += resync
                needResync = false
                continue
            }
            try parsePacket(merged, p)
            p += Self.tsPacket
        }
    }

    /// Release the transcode codecs (no-op for passthrough muxes). The
    /// session calls this once per ingest connection.
    func release() {
        transcoder?.release()
        transcoder = nil
    }

    // MARK: TS packet / PSI parsing

    private func parsePacket(_ buf: [UInt8], _ off: Int) throws {
        if buf[off + 1] & 0x80 != 0 { return }  // transport_error_indicator
        let pusi = buf[off + 1] & 0x40 != 0
        let pid = (Int(buf[off + 1] & 0x1F) << 8) | Int(buf[off + 2])
        if buf[off + 3] & 0xC0 != 0 { return }  // scrambled
        let afc = (Int(buf[off + 3]) >> 4) & 0x03
        if afc == 0 || afc == 2 { return }      // no payload
        var payloadStart = off + 4
        if afc == 3 {
            payloadStart += 1 + Int(buf[off + 4])
            if payloadStart >= off + Self.tsPacket { return }
        }
        let payloadLen = off + Self.tsPacket - payloadStart
        switch pid {
        case 0:
            parsePAT(buf, payloadStart, payloadLen, pusi)
        case pmtPID where !pmtSeen:
            try parsePMT(buf, payloadStart, payloadLen, pusi)
        case videoPID:
            try videoPES.feed(buf, payloadStart, payloadLen, pusi)
        case audioPID:
            try audioPES.feed(buf, payloadStart, payloadLen, pusi)
        default:
            break
        }
    }

    private func parsePAT(_ buf: [UInt8], _ start: Int, _ len: Int, _ pusi: Bool) {
        guard pmtPID < 0, pusi, len >= 13 else { return }
        let p = start + 1 + Int(buf[start]) // pointer_field
        guard buf[p] == 0x00 else { return } // table_id PAT
        let sectionLen = (Int(buf[p + 1] & 0x0F) << 8) | Int(buf[p + 2])
        // Program loop: 8 bytes of fixed header after table_id/len, then
        // 4-byte entries, 4-byte CRC at the end. First non-zero program
        // wins; Dispatcharr and XC panels serve single-program muxes.
        var q = p + 8
        let end = min(p + 3 + sectionLen - 4, start + len)
        while q + 3 < end {
            let program = (Int(buf[q]) << 8) | Int(buf[q + 1])
            let mapPID = (Int(buf[q + 2] & 0x1F) << 8) | Int(buf[q + 3])
            if program != 0 {
                pmtPID = mapPID
                return
            }
            q += 4
        }
    }

    private func parsePMT(_ buf: [UInt8], _ start: Int, _ len: Int, _ pusi: Bool) throws {
        guard pusi, len >= 17 else { return }
        let p = start + 1 + Int(buf[start]) // pointer_field
        guard buf[p] == 0x02 else { return } // table_id PMT
        let sectionLen = (Int(buf[p + 1] & 0x0F) << 8) | Int(buf[p + 2])
        let sectionEnd = min(p + 3 + sectionLen - 4, start + len) // minus CRC
        let programInfoLen = (Int(buf[p + 10] & 0x0F) << 8) | Int(buf[p + 11])
        var q = p + 12 + programInfoLen
        var video = -1, videoType = -1
        var audio = -1, audioType = -1
        while q + 4 < sectionEnd {
            let streamType = Int(buf[q])
            let esPID = (Int(buf[q + 1] & 0x1F) << 8) | Int(buf[q + 2])
            let esInfoLen = (Int(buf[q + 3] & 0x0F) << 8) | Int(buf[q + 4])
            if video < 0, Self.videoStreamTypes.contains(streamType) {
                video = esPID; videoType = streamType
            }
            if audio < 0, Self.audioStreamTypes.contains(streamType) {
                audio = esPID; audioType = streamType
            }
            q += 5 + esInfoLen
        }
        // Refuse before any media flows: the ingest surfaces this as the
        // user-visible cast failure with the codec name.
        if video >= 0, videoType != Self.streamTypeH264 {
            throw CastUnsupportedCodecError(
                codecName: Self.streamTypeNames[videoType] ?? String(format: "video stream_type 0x%02X", videoType),
                stream: .video)
        }
        if audio >= 0, audioType != Self.streamTypeAACADTS {
            // The AC-3 family either passes through (receiver decodes it)
            // or routes through the on-phone transcode. Everything else
            // refuses.
            guard let source = Self.transcodeSources[audioType] else {
                throw CastUnsupportedCodecError(
                    codecName: Self.streamTypeNames[audioType] ?? String(format: "audio stream_type 0x%02X", audioType),
                    stream: .audio)
            }
            if allowAC3Passthrough, source == .ac3 || source == .eac3 {
                audioPassthrough = source
            } else {
                audioSource = source
            }
        }
        if video < 0 { throw CastUnsupportedCodecError(codecName: "no video stream in PMT", stream: .video) }
        videoPID = video
        audioPID = audio // may stay -1: video-only mux is fine
        if audio < 0 {
            audioPathDescription = "none (video only)"
        } else if let source = audioPassthrough {
            audioPathDescription = "\(source.displayName) passthrough"
        } else if let source = audioSource {
            audioPathDescription = "\(source.displayName) -> AAC stereo"
        } else {
            audioPathDescription = "AAC passthrough"
        }
        pmtSeen = true
    }

    // MARK: PES layer

    /// Accumulates one PES packet per payload_unit_start and hands the
    /// complete elementary payload plus its PTS/DTS (90 kHz, 33-bit) up.
    private final class PESAssembler {
        private let onComplete: (_ payload: [UInt8], _ pts: Int64, _ dts: Int64) throws -> Void
        private var buf: [UInt8] = []
        private var collecting = false

        init(_ onComplete: @escaping (_ payload: [UInt8], _ pts: Int64, _ dts: Int64) throws -> Void) {
            self.onComplete = onComplete
        }

        func feed(_ data: [UInt8], _ start: Int, _ len: Int, _ pusi: Bool) throws {
            if pusi {
                try flush()
                collecting = true
            }
            if collecting { buf.append(contentsOf: data[start..<(start + len)]) }
        }

        func flush() throws {
            guard collecting, !buf.isEmpty else { buf.removeAll(keepingCapacity: true); return }
            let pes = buf
            buf.removeAll(keepingCapacity: true)
            collecting = false
            guard pes.count >= 9, pes[0] == 0, pes[1] == 0, pes[2] == 1 else { return }
            let flags = pes[7] & 0xC0
            let headerLen = Int(pes[8])
            let payloadOff = 9 + headerLen
            guard payloadOff < pes.count else { return }
            var pts: Int64 = -1
            var dts: Int64 = -1
            if flags & 0x80 != 0, headerLen >= 5 {
                pts = Self.readTimestamp(pes, 9)
                dts = (flags & 0x40 != 0 && headerLen >= 10) ? Self.readTimestamp(pes, 14) : pts
            }
            guard pts >= 0 else { return } // unstamped PES is useless to the segmenter
            try onComplete(Array(pes[payloadOff...]), pts, dts)
        }

        private static func readTimestamp(_ b: [UInt8], _ off: Int) -> Int64 {
            ((Int64(b[off]) & 0x0E) << 29)
                | (Int64(b[off + 1]) << 22)
                | ((Int64(b[off + 2]) & 0xFE) << 14)
                | (Int64(b[off + 3]) << 7)
                | ((Int64(b[off + 4]) & 0xFE) >> 1)
        }
    }

    /// 33-bit 90 kHz to monotonic 64-bit. A backwards jump larger than
    /// half the wrap range is a wraparound, not a rewind.
    struct PTSUnwrapper {
        private var last33: Int64 = -1
        private var epoch: Int64 = 0

        mutating func unwrap(_ ts33: Int64) -> Int64 {
            if last33 >= 0 {
                let delta = ts33 - last33
                if delta < -(CastFMP4Remuxer.ptsWrap / 2) {
                    epoch += CastFMP4Remuxer.ptsWrap
                } else if delta > CastFMP4Remuxer.ptsWrap / 2, epoch > 0 {
                    epoch -= CastFMP4Remuxer.ptsWrap
                }
            }
            last33 = ts33
            return epoch + ts33
        }
    }

    // MARK: video path

    private func onVideoAccessUnit(_ payload: [UInt8], pts33: Int64, dts33: Int64) {
        // One PES with PUSI per access unit is the broadcast norm; split
        // Annex B, harvest parameter sets, convert to 4-byte-length AVCC.
        let nals = Self.splitAnnexB(payload)
        guard !nals.isEmpty else { return }
        var keyframe = false
        for nal in nals {
            switch nal[nal.startIndex] & 0x1F {
            case 5: keyframe = true
            case 7: if sps == nil { sps = Array(nal) }
            case 8: if pps == nil { pps = Array(nal) }
            default: break
            }
        }
        maybeEmitInit()
        guard initSent else { return }
        // Segments must open on a keyframe: drop leading non-IDR units at
        // stream start (mid-GOP join) instead of shipping undecodable refs.
        if videoQueue.isEmpty, timelineBase < 0, !keyframe { return }

        let dts = videoClock.unwrap(dts33)
        let pts = Self.unwrapPTSAgainstDTS(pts33, dts)
        if timelineBase < 0 {
            timelineBase = dts
            // The composition offset of the first sample is what the
            // receiver anchors on; see `timelineBasePTS`.
            timelineBasePTS = pts
        }

        if keyframe, let first = videoQueue.first, dts - first.dts >= targetSegmentTicks {
            finalizeSegment(cutDTS: dts)
        }
        // AVCC conversion: length-prefixed NALs, parameter sets kept
        // in-band (a mid-stream resolution change then stays decodable).
        var sample = [UInt8]()
        sample.reserveCapacity(nals.reduce(0) { $0 + 4 + $1.count })
        for nal in nals {
            let n = nal.count
            sample.append(contentsOf: [UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF),
                                       UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)])
            sample.append(contentsOf: nal)
        }
        videoQueue.append(VideoSample(data: sample, dts: dts, pts: pts, keyframe: keyframe))
    }

    /// PTS shares DTS's wrap epoch; unwrap it relative to the unwrapped
    /// DTS instead of running a second independent epoch counter (PTS can
    /// legitimately sit slightly across the wrap point from DTS).
    static func unwrapPTSAgainstDTS(_ pts33: Int64, _ dts64: Int64) -> Int64 {
        let base = dts64 - (dts64 % ptsWrap)
        var pts = base + pts33
        if pts < dts64 - ptsWrap / 2 { pts += ptsWrap }
        if pts > dts64 + ptsWrap / 2 { pts -= ptsWrap }
        return pts
    }

    private static func splitAnnexB(_ payload: [UInt8]) -> [ArraySlice<UInt8>] {
        var nals: [ArraySlice<UInt8>] = []
        var i = 0
        var nalStart = -1
        let n = payload.count
        while i + 2 < n {
            if payload[i] == 0, payload[i + 1] == 0, payload[i + 2] == 1 {
                if nalStart >= 0 {
                    var end = i
                    if end > nalStart, payload[end - 1] == 0 { end -= 1 } // 4-byte start code
                    if end > nalStart { nals.append(payload[nalStart..<end]) }
                }
                nalStart = i + 3
                i += 3
            } else {
                i += 1
            }
        }
        if nalStart >= 0, nalStart < n { nals.append(payload[nalStart..<n]) }
        return nals
    }

    // MARK: audio path

    private func onAudioPES(_ payload: [UInt8], pts33: Int64) throws {
        if let source = audioPassthrough {
            onAC3PassthroughPES(source, payload, pts33: pts33)
        } else if let source = audioSource {
            try onTranscodeAudioPES(source, payload, pts33: pts33)
        } else {
            onADTSAudioPES(payload, pts33: pts33)
        }
    }

    /// AC-3 / E-AC-3 passthrough: frame the elementary stream exactly like
    /// the transcode path does, but queue the whole syncframes as audio
    /// samples. No decode, no encode, original channel layout; the init
    /// segment carries an ac-3 / ec-3 sample entry (dac3 / dec3) and the
    /// playlist names the matching CODECS value, so a receiver that
    /// decodes AC-3 picks the right decoder.
    private func onAC3PassthroughPES(_ source: CastAudioSourceCodec, _ payload: [UInt8], pts33: Int64) {
        var data: [UInt8]
        if audioCarry.isEmpty {
            data = payload
        } else {
            data = audioCarry
            data.append(contentsOf: payload)
        }
        audioCarry = []
        var p = 0
        var framePTS: Int64 = -1
        while p < data.count {
            guard let info = CastAudioTranscoder.parseFrameHeader(source, data, p) else {
                if data.count - p < 8 { break } // possibly a truncated header: carry it
                p += 1 // scan to syncword (junk between frames happens on splices)
                continue
            }
            let next = p + info.frameLength
            if next > data.count { break } // partial frame: carry
            // Reject a false sync inside frame data, same rule the
            // transcode framer uses.
            if next + 1 < data.count, !CastAudioTranscoder.looksLikeSync(source, data, next) {
                p += 1
                continue
            }
            if passthroughConfig == nil,
               let config = CastAudioTranscoder.parseAC3SampleEntryConfig(source, data, p) {
                passthroughConfig = config
                audioFrameTicks = Int64(info.samplesPerFrame) * Self.ticksPerSecond / Int64(info.sampleRate)
                audioPathDescription = "\(source.displayName) \(Self.channelLabel(info.channels)) passthrough"
                if !passthroughLogged {
                    log("audio passthrough active: \(source.displayName) \(info.channels)ch "
                        + "\(info.sampleRate)Hz, codecs=\(config.codecsAttribute)")
                    passthroughLogged = true
                }
                maybeEmitInit()
            }
            if framePTS < 0 { framePTS = audioClock.unwrap(pts33) }
            if initSent, timelineBasePTS >= 0, framePTS >= timelineBasePTS {
                audioQueue.append(AudioSample(data: Array(data[p..<next]), pts: framePTS))
            }
            framePTS += Int64(info.samplesPerFrame) * Self.ticksPerSecond / Int64(info.sampleRate)
            p = next
        }
        if p < data.count { audioCarry = Array(data[p...]) }
    }

    /// Transcode path: frame the elementary stream (AC-3/E-AC-3/MP2
    /// syncframes; `audioCarry` doubles as the generic audio carry),
    /// stamp each frame's PTS (first frame of the PES rides the PES PTS,
    /// followers step by the codec's frame duration, mirroring the ADTS
    /// path), and hand the access units to the transcoder. Its AAC
    /// output flows back through the closures wired in the factory.
    private func onTranscodeAudioPES(_ source: CastAudioSourceCodec, _ payload: [UInt8], pts33: Int64) throws {
        var data: [UInt8]
        if audioCarry.isEmpty {
            data = payload
        } else {
            data = audioCarry
            data.append(contentsOf: payload)
        }
        audioCarry = []
        var p = 0
        var framePTS: Int64 = -1
        while p < data.count {
            guard let info = CastAudioTranscoder.parseFrameHeader(source, data, p) else {
                if data.count - p < 8 { break } // possibly a truncated header: carry it
                p += 1 // scan to syncword (junk between frames happens on splices)
                continue
            }
            let next = p + info.frameLength
            if next > data.count { break } // partial frame: carry
            // Reject a false sync inside frame data: the next frame must
            // start on a syncword when it is already in the buffer.
            if next + 1 < data.count, !CastAudioTranscoder.looksLikeSync(source, data, next) {
                p += 1
                continue
            }
            let t: CastAudioTranscoding
            if let existing = transcoder {
                t = existing
            } else {
                t = transcoderFactory(source, { [weak self] asc, rate in
                    guard let self else { return }
                    self.transcodeASC = asc
                    self.transcodeSampleRate = rate
                    self.audioFrameTicks = 1024 * Self.ticksPerSecond / Int64(rate)
                    self.maybeEmitInit()
                }, { [weak self] frame, pts in
                    guard let self else { return }
                    // Same gate as the passthrough path: audio only queues
                    // once the init exists and video anchored the timeline,
                    // and never before the first video PRESENTATION time.
                    if self.initSent, self.timelineBasePTS >= 0, pts >= self.timelineBasePTS {
                        self.audioQueue.append(AudioSample(data: frame, pts: pts))
                    }
                })
                transcoder = t
            }
            if !transcodeLogged {
                log("audio transcode active: \(source.displayName) \(info.channels)ch \(info.sampleRate)Hz -> AAC-LC stereo")
                audioPathDescription = "\(source.displayName) \(Self.channelLabel(info.channels)) -> AAC stereo"
                transcodeLogged = true
            }
            if framePTS < 0 {
                framePTS = audioClock.unwrap(pts33)
                if expectedSrcAudioPTS >= 0,
                   abs(framePTS - expectedSrcAudioPTS) > CastAudioTranscoder.discontinuityTicks {
                    // Splice/reconnect: flush both codecs; the PTS mapper
                    // re-anchors on the next output stamp.
                    log("audio pts discontinuity (\((framePTS - expectedSrcAudioPTS) / 90)ms), flushing transcode codecs")
                    t.flush()
                }
            }
            try t.feed(data, range: p..<next, ptsTicks: framePTS, info: info)
            framePTS += Int64(info.samplesPerFrame) * Self.ticksPerSecond / Int64(info.sampleRate)
            expectedSrcAudioPTS = framePTS
            p = next
        }
        if p < data.count { audioCarry = Array(data[p...]) }
    }

    private func onADTSAudioPES(_ payload: [UInt8], pts33: Int64) {
        var data: [UInt8]
        if audioCarry.isEmpty {
            data = payload
        } else {
            data = audioCarry
            data.append(contentsOf: payload)
        }
        audioCarry = []
        var p = 0
        var framePTS: Int64 = -1
        while p + 7 <= data.count {
            guard data[p] == 0xFF, data[p + 1] & 0xF0 == 0xF0 else {
                p += 1 // scan to syncword (junk between frames happens on splices)
                continue
            }
            let protectionAbsent = data[p + 1] & 0x01 != 0
            let profile = (Int(data[p + 2]) >> 6) & 0x03
            let freqIndex = (Int(data[p + 2]) >> 2) & 0x0F
            let chanConfig = ((Int(data[p + 2]) & 0x01) << 2) | ((Int(data[p + 3]) >> 6) & 0x03)
            let frameLen = ((Int(data[p + 3]) & 0x03) << 11)
                | (Int(data[p + 4]) << 3)
                | ((Int(data[p + 5]) >> 5) & 0x07)
            if frameLen < 7 || p + frameLen > data.count { break } // partial frame: carry
            let headerLen = protectionAbsent ? 7 : 9
            // channel_configuration 0 means the layout lives in a
            // program_config_element at the start of the raw_data_block,
            // which is exactly what Dispatcharr's AAC output profile
            // emits (ffmpeg `-c:a aac -ac 2`, "Using a PCE to encode
            // channel layout"). Two things break downstream: an
            // AudioSpecificConfig cannot express config 0 at all, and the
            // Google TV Streamer's C2SoftAacDec refuses every frame that
            // still carries the PCE (measured: 5388 lines of "error
            // 0x0005, substituting silence" in one session). Both are
            // fixed losslessly here, per frame: derive the real channel
            // count from the element for the ASC, and drop the element
            // off the front of the block. No transcode, no re-encode.
            var payloadStart = p + headerLen
            var effectiveChanConfig = chanConfig
            if chanConfig == 0,
               let pce = Self.parseAACPCE(data, offset: p + headerLen, end: p + frameLen) {
                // The PCE ends byte-aligned relative to the block start
                // (`parseAACPCE` refuses to report one that does not), so
                // the elements after it begin on a byte boundary and the
                // rest of the block copies over verbatim: no bit
                // shifting, and the block's existing id_syn_ele 7
                // terminator plus its byte alignment still terminate the
                // shortened block correctly.
                payloadStart = p + headerLen + pce.lengthBytes
                effectiveChanConfig = Self.aacChannelConfig(forCount: pce.channels)
                if !aacPCELogged {
                    aacPCELogged = true
                    log("AAC PCE stripped: layout \(pce.channels) ch -> config \(effectiveChanConfig)")
                }
            }
            if payloadStart >= p + frameLen {
                // A frame that is nothing but a PCE carries no audio.
                p += frameLen
                continue
            }
            if aacFreqIndex < 0 {
                aacObjectType = profile + 1 // ADTS profile is MPEG-4 audioObjectType - 1
                aacFreqIndex = freqIndex
                aacChannelConfig = effectiveChanConfig
                // The frame duration has to match the track's declared
                // sample rate, so both come from the one sanitized config.
                let cfg = Self.sanitizedAACConfig(objectType: profile + 1,
                                                  freqIndex: freqIndex,
                                                  channelConfig: effectiveChanConfig)
                audioFrameTicks = 1024 * Self.ticksPerSecond / Int64(cfg.sampleRate)
                maybeEmitInit()
            }
            if initSent, frameLen > headerLen {
                // First frame of the PES rides the PES PTS; followers step
                // by the fixed 1024-sample frame duration. Re-anchoring on
                // every PES keeps drift bounded to one PES worth of frames.
                if framePTS < 0 { framePTS = audioClock.unwrap(pts33) }
                if timelineBasePTS >= 0, framePTS >= timelineBasePTS {
                    audioQueue.append(AudioSample(data: Array(data[payloadStart..<(p + frameLen)]), pts: framePTS))
                }
                framePTS += audioFrameTicks
            }
            p += frameLen
        }
        if p < data.count { audioCarry = Array(data[p...]) }
    }

    /// Audio config for the AAC sample entry, validated against what the
    /// web receiver's parser will accept.
    struct AACTrackConfig: Equatable {
        let objectType: Int
        let freqIndex: Int
        let channelConfig: Int
        let sampleRate: Int
        /// mp4a `channelcount`, kept consistent with `channelConfig`.
        let channels: Int
        /// The 2-byte MPEG-4 AudioSpecificConfig for the esds.
        let asc: [UInt8]
    }

    /// ADTS channel counts per channelConfiguration (ISO 14496-3 Table
    /// 1.19); index 7 is 7.1, so it is 8 channels, not 7.
    private static let aacChannelCounts = [0, 1, 2, 3, 4, 5, 6, 8]

    /// A program_config_element found at the start of a raw_data_block.
    ///
    /// `lengthBytes` is the element's size measured from the block start,
    /// which is always a whole number of bytes: the PCE byte-aligns
    /// relative to the block start before `comment_field_bytes`, and the
    /// comment itself is a whole number of bytes after it (ISO/IEC
    /// 14496-3 4.4.1.1). That is what lets the PCE be removed with a
    /// byte-wise copy instead of shifting the whole remaining payload
    /// left bit by bit; `parseAACPCE` refuses to report a PCE that does
    /// not end aligned, so the byte-wise caller can never corrupt a frame.
    struct AACPCEInfo: Equatable {
        /// Channels the declared layout adds up to: CPE 2, SCE 1, LFE 1.
        let channels: Int
        /// PCE size in bytes, measured from the raw_data_block start.
        let lengthBytes: Int
        /// True when the first front element is a channel_pair_element,
        /// i.e. the element the stripped frame will start with is the
        /// stereo pair a channel_configuration of 2 implies.
        let firstIsCPE: Bool
    }

    /// Parse the program_config_element at `offset`, or return nil when
    /// the raw_data_block does not start with one.
    ///
    /// Dispatcharr's "Web Player (AAC Audio)" output profile (ffmpeg
    /// `-c:a aac -ac 2`) emits ADTS frames whose channel_configuration is
    /// 0 with the real layout carried in a PCE at the start of the
    /// raw_data_block. An AudioSpecificConfig cannot carry config 0
    /// (Chromium's SkipGASpecificConfig does RCHECK(channel_config_ != 0))
    /// and the Google TV Streamer's C2SoftAacDec rejects every frame that
    /// still contains the PCE. Parsing the element gives the remuxer both
    /// halves of the lossless fix: the real channel count for the ASC,
    /// and the exact byte length to drop off the front of each frame.
    ///
    /// Field order is ISO/IEC 14496-3 4.4.1.1.
    static func parseAACPCE(_ data: [UInt8], offset: Int, end: Int) -> AACPCEInfo? {
        guard offset < end, end <= data.count else { return nil }
        var bit = 0 // bit position RELATIVE to the raw_data_block start
        let limit = (end - offset) * 8
        // -1 means "ran past the end of the block"; every caller that can
        // act on that checks for it.
        func read(_ n: Int) -> Int {
            guard bit + n <= limit else { return -1 }
            var v = 0
            for _ in 0..<n {
                let byte = Int(data[offset + (bit >> 3)])
                v = (v << 1) | ((byte >> (7 - (bit & 7))) & 1)
                bit += 1
            }
            return v
        }
        // id_syn_ele: PCE is 0x5. Anything else is a normal element and
        // the frame passes through untouched.
        guard read(3) == 5 else { return nil }
        _ = read(4) // element_instance_tag
        _ = read(2) // object_type
        _ = read(4) // sampling_frequency_index
        let numFront = read(4)
        let numSide = read(4)
        let numBack = read(4)
        let numLFE = read(2)
        let numAssoc = read(3)
        let numCC = read(4)
        guard numCC >= 0 else { return nil }
        // Each mixdown flag is followed by its index only when present.
        if read(1) == 1 { _ = read(4) } // mono_mixdown_element_number
        if read(1) == 1 { _ = read(4) } // stereo_mixdown_element_number
        if read(1) == 1 { _ = read(3) } // matrix_mixdown_idx + pseudo_surround
        var channels = 0
        var firstIsCPE = false
        var firstSeen = false
        // front, side and back elements each carry is_cpe + a 4-bit tag;
        // a channel_pair_element is two channels, a single is one.
        for count in [numFront, numSide, numBack] {
            for _ in 0..<count {
                let isCPE = read(1)
                _ = read(4) // element tag
                guard isCPE >= 0 else { return nil }
                if !firstSeen {
                    firstSeen = true
                    firstIsCPE = isCPE == 1
                }
                channels += isCPE == 1 ? 2 : 1
            }
        }
        for _ in 0..<numLFE {
            _ = read(4) // lfe_element_tag: one channel each
            channels += 1
        }
        for _ in 0..<numAssoc { _ = read(4) } // assoc_data: no channels
        for _ in 0..<numCC {
            _ = read(1) // cc_element_is_ind_sw
            _ = read(4) // valid_cc_element_tag
        }
        guard bit <= limit else { return nil }
        // byte_align() is relative to the raw_data_block start, which is
        // exactly where `bit` is counted from.
        if bit & 7 != 0 { _ = read(8 - (bit & 7)) }
        let commentBytes = read(8)
        guard commentBytes >= 0, bit + commentBytes * 8 <= limit else { return nil }
        bit += commentBytes * 8
        // Spec-guaranteed, asserted anyway: a PCE that did not end on a
        // byte boundary could not be dropped with a byte-wise copy.
        guard bit & 7 == 0, channels > 0 else { return nil }
        return AACPCEInfo(channels: channels, lengthBytes: bit >> 3, firstIsCPE: firstIsCPE)
    }

    /// The inverse of `aacChannelCounts`: the channel_configuration that
    /// declares `count` channels, or 0 when Table 1.19 has no entry for
    /// that count (7 channels is the only gap, since config 7 is 7.1). 0
    /// is then handed to the config sanitizer, which substitutes stereo.
    static func aacChannelConfig(forCount count: Int) -> Int {
        switch count {
        case 1: return 1
        case 2: return 2
        case 3: return 3
        case 4: return 4
        case 5: return 5
        case 6: return 6
        case 8: return 7
        default: return 0
        }
    }

    /// Turn the three ADTS header config fields into an
    /// AudioSpecificConfig the receiver will actually parse.
    ///
    /// The receiver is a Chromium page, and Chromium re-parses the ASC we
    /// write (media/formats/mp4/aac.cc) while parsing `moov`. Three values
    /// there are fatal to the WHOLE init segment, not just to the audio
    /// track, so a verbatim copy of the ADTS header is not safe:
    ///
    ///  - `channelConfiguration` 0 means "the layout is in a program
    ///    config element", which is what ffmpeg's AAC encoder emits for
    ///    layouts outside Table 1.19 (2.1, 3.1, 6.1, 7.0 and friends), so
    ///    a transcoding server hands it to us for real channels. Chromium
    ///    hits `RCHECK(channel_config_ != 0)` in SkipGASpecificConfig and
    ///    fails the append with "stream parsing failed". Nothing in the
    ///    ADTS header recovers the real layout, so the track is declared
    ///    stereo; the decoder still reads the PCE out of the raw frames.
    ///  - `samplingFrequencyIndex` 13 and 14 are reserved and 15 is the
    ///    24-bit explicit-rate escape, which a 2-byte ASC has no room
    ///    for; all three fail Chromium's frequency table lookup. They fall
    ///    back to 48 kHz (index 3), the rate the rest of the remux
    ///    already assumed for an out-of-range index.
    ///  - `audioObjectType` must land in 1...4. ADTS profile + 1 always
    ///    does, but 5 (HE-AAC) and 29 (HE-AACv2) would need extension
    ///    fields a 2-byte ASC cannot carry, so anything else becomes 2
    ///    (AAC-LC).
    static func sanitizedAACConfig(objectType: Int, freqIndex: Int, channelConfig: Int) -> AACTrackConfig {
        let aot = (1...4).contains(objectType) ? objectType : 2
        let index = adtsSampleRates.indices.contains(freqIndex) ? freqIndex : 3
        let config = (1...7).contains(channelConfig) ? channelConfig : 2
        let asc: [UInt8] = [UInt8((aot << 3) | (index >> 1)),
                            UInt8(((index & 1) << 7) | (config << 3))]
        return AACTrackConfig(objectType: aot, freqIndex: index, channelConfig: config,
                              sampleRate: adtsSampleRates[index],
                              channels: aacChannelCounts[config], asc: asc)
    }

    private static let adtsSampleRates = [
        96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000, 22_050,
        16_000, 12_000, 11_025, 8_000, 7_350,
    ]

    // MARK: segmenter

    private func maybeEmitInit() {
        guard !initSent, pmtSeen, sps != nil, pps != nil else { return }
        // Audio config gate: ADTS header on the passthrough path, the
        // encoder's AudioSpecificConfig on the transcode path (which
        // means the first audio already went through both codecs).
        let audioReady: Bool
        if audioPID < 0 {
            audioReady = true
        } else if audioPassthrough != nil {
            audioReady = passthroughConfig != nil
        } else if audioSource != nil {
            audioReady = transcodeASC != nil
        } else {
            audioReady = aacFreqIndex >= 0
        }
        guard audioReady else { return }
        onInitSegment?(buildInitSegment())
        initSent = true
    }

    private func finalizeSegment(cutDTS: Int64) {
        guard !videoQueue.isEmpty else { return }
        let segStart = videoQueue[0].dts
        // Video sample durations come from successor DTS deltas; the last
        // sample's successor is the keyframe that triggered the cut.
        var durations = [Int64](repeating: 0, count: videoQueue.count)
        for i in videoQueue.indices {
            let next = i + 1 < videoQueue.count ? videoQueue[i + 1].dts : cutDTS
            var d = next - videoQueue[i].dts
            if d <= 0 { d = lastVideoDuration }
            durations[i] = d
            lastVideoDuration = d
        }
        // Audio that belongs to this video span; the rest stays queued.
        var segAudio: [AudioSample] = []
        var keepAudio: [AudioSample] = []
        for a in audioQueue {
            if a.pts < cutDTS { segAudio.append(a) } else { keepAudio.append(a) }
        }
        let segment = buildMediaSegment(video: videoQueue, videoDurations: durations, audio: segAudio)
        let durationTicks = cutDTS - segStart
        // Timeline snapshot for the composition callback, taken BEFORE
        // the queues are cleared. These are the same values the tfdt
        // boxes carry (see `buildMoof`), expressed in seconds relative to
        // `timelineBase`, plus this segment's position on the playlist
        // timeline; the sender log needs both to tell whether Shaka's
        // chosen playhead can possibly be inside the buffered range.
        let videoSamples = videoQueue.count
        let audioSamples = segAudio.count
        let firstVideoDTSSeconds = Double(videoQueue[0].dts - timelineBase) / Double(Self.ticksPerSecond)
        let firstVideoPTSSeconds = Double(videoQueue[0].pts - timelineBase) / Double(Self.ticksPerSecond)
        // -1.0 is the "no audio in this segment" sentinel; a real value
        // is never negative because samples below `timelineBasePTS` are
        // dropped at queue time and `timelineBasePTS >= timelineBase`.
        let firstAudioPTSSeconds = segAudio.first
            .map { Double($0.pts - timelineBase) / Double(Self.ticksPerSecond) } ?? -1.0
        let segmentStartSeconds = Double(emittedMediaTicks) / Double(Self.ticksPerSecond)
        emittedMediaTicks += durationTicks
        videoQueue.removeAll(keepingCapacity: true)
        audioQueue = keepAudio
        // Fired BEFORE onMediaSegment so the per-segment timeline line is
        // logged ahead of anything the store/session does with the bytes.
        onSegmentComposition?(videoSamples, audioSamples,
                              firstVideoDTSSeconds, firstVideoPTSSeconds,
                              firstAudioPTSSeconds, segmentStartSeconds)
        onMediaSegment?(segment, durationTicks)
    }

    // MARK: fMP4 writing

    private func buildInitSegment() -> Data {
        let hasAudio = audioPID >= 0
        let dims = (try? Self.parseSPSDimensions(sps!)) ?? (width: 1280, height: 720)
        var out = Data(capacity: 1024)
        out.append(Self.box("ftyp", Self.bytes("iso5"), Self.u32(0), Self.bytes("iso5"), Self.bytes("iso6"), Self.bytes("mp41")))
        var traks = [videoTrak(width: dims.width, height: dims.height)]
        if hasAudio { traks.append(audioTrak()) }
        var trexes = [Self.trex(Self.videoTrackID)]
        if hasAudio { trexes.append(Self.trex(Self.audioTrackID)) }
        let moov = Self.box("moov",
                            Self.mvhd(nextTrackID: hasAudio ? 3 : 2),
                            Self.concat(traks),
                            Self.box("mvex", Self.concat(trexes)))
        out.append(moov)
        return out
    }

    private func buildMediaSegment(video: [VideoSample], videoDurations: [Int64], audio: [AudioSample]) -> Data {
        let videoBytes = video.reduce(0) { $0 + $1.data.count }
        let audioBytes = audio.reduce(0) { $0 + $1.data.count }

        // trun data_offset is from moof start; build the moof once with
        // placeholder offsets to learn its size, then rebuild with real
        // ones (sizes are offset-independent). One sequence number per
        // emitted segment, not per build pass.
        sequenceNumber += 1
        var moof = buildMoof(video: video, videoDurations: videoDurations, audio: audio,
                             videoDataOffset: 0, audioDataOffset: 0)
        let moofSize = moof.count
        moof = buildMoof(video: video, videoDurations: videoDurations, audio: audio,
                         videoDataOffset: moofSize + 8,
                         audioDataOffset: moofSize + 8 + videoBytes)
        var out = Data(capacity: moof.count + 8 + videoBytes + audioBytes)
        out.append(moof)
        out.append(Self.u32(8 + videoBytes + audioBytes))
        out.append(Self.bytes("mdat"))
        for s in video { out.append(contentsOf: s.data) }
        for a in audio { out.append(contentsOf: a.data) }
        return out
    }

    private func buildMoof(video: [VideoSample], videoDurations: [Int64], audio: [AudioSample],
                           videoDataOffset: Int, audioDataOffset: Int) -> Data {
        let mfhd = Self.fullBox("mfhd", 0, 0, Self.u32(sequenceNumber))
        let videoTraf = Self.box(
            "traf",
            // default-base-is-moof so data_offset is moof-relative (CMAF).
            Self.fullBox("tfhd", 0, 0x020000, Self.u32(Self.videoTrackID)),
            Self.fullBox("tfdt", 1, 0, Self.u64(UInt64(video[0].dts - timelineBase))),
            videoTrun(video, videoDurations, dataOffset: videoDataOffset))
        var trafs = [videoTraf]
        if let firstAudio = audio.first {
            trafs.append(Self.box(
                "traf",
                // flags 0x020000 default-base-is-moof, 0x000020
                // default-sample-flags. The audio trun carries no
                // per-sample flags, so without the tfhd default the
                // receiver's parser does not treat our AAC frames as
                // random access points and logs, once per frame (Google TV
                // Streamer, 2026-09-12 14:22:20.237):
                //
                //   Bytestream with audio frame PTS 22666us and DTS
                //   22666us indicated the frame is not a random access
                //   point (key frame). All audio frames are expected to be
                //   key frames for the current audio codec.
                //
                // The first packet after the load's seek is then a non-key
                // packet, which is the "Failed to send audio packet for
                // decoding" that costs every load a FFmpegAudioDecoder ->
                // MediaCodecAudioDecoder swap and a reseek. 0x02000000 is
                // sample_depends_on = 2 ("does not depend on others") with
                // sample_is_non_sync_sample clear, which is the truth for
                // every AAC and AC-3 frame.
                Self.fullBox("tfhd", 0, 0x020020,
                             Self.u32(Self.audioTrackID), Self.u32(0x0200_0000)),
                // No clamp: samples earlier than `timelineBasePTS` are
                // dropped at queue time, and `timelineBasePTS` is never
                // below `timelineBase`, so this is always >= 0 and always
                // the truth. Clamping to 0 declared a segment as starting
                // earlier than it does and overlapped the NEXT segment's
                // audio by the same amount, which is a backwards append
                // one segment into the cast.
                Self.fullBox("tfdt", 1, 0, Self.u64(UInt64(firstAudio.pts - timelineBase))),
                audioTrun(audio, dataOffset: audioDataOffset)))
        }
        return Self.box("moof", mfhd, Self.concat(trafs))
    }

    private func videoTrun(_ video: [VideoSample], _ durations: [Int64], dataOffset: Int) -> Data {
        // flags: data-offset | sample-duration | sample-size | sample-flags |
        // sample-composition-time-offset; version 1 for signed cts.
        var body = Data(capacity: 16 + video.count * 16)
        body.append(Self.u32(video.count))
        body.append(Self.u32(dataOffset))
        for i in video.indices {
            let s = video[i]
            body.append(Self.u32(Int(durations[i])))
            body.append(Self.u32(s.data.count))
            body.append(Self.u32(s.keyframe ? 0x02000000 : 0x01010000))
            body.append(Self.u32(Int(s.pts - s.dts)))
        }
        return Self.fullBox("trun", 1, 0x000F01, body)
    }

    private func audioTrun(_ audio: [AudioSample], dataOffset: Int) -> Data {
        // Fixed per-frame duration; flags: data-offset | duration | size.
        var body = Data(capacity: 16 + audio.count * 8)
        body.append(Self.u32(audio.count))
        body.append(Self.u32(dataOffset))
        for a in audio {
            body.append(Self.u32(Int(audioFrameTicks)))
            body.append(Self.u32(a.data.count))
        }
        return Self.fullBox("trun", 0, 0x000301, body)
    }

    // MARK: moov internals

    private static func mvhd(nextTrackID: Int) -> Data {
        fullBox("mvhd", 0, 0,
                u32(0), u32(0), // creation, modification
                u32(Int(ticksPerSecond)), u32(0), // timescale, duration (live: 0)
                u32(0x00010000), u16(0x0100), u16(0), u32(0), u32(0), // rate, volume, reserved
                matrix(),
                Data(count: 24), // pre_defined
                u32(nextTrackID))
    }

    private static func matrix() -> Data {
        var out = Data(capacity: 36)
        for v in [0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x40000000] { out.append(u32(v)) }
        return out
    }

    private func videoTrak(width: Int, height: Int) -> Data {
        let s = sps!
        let p = pps!
        var avcCBody = Data(capacity: 16 + s.count + p.count)
        avcCBody.append(1) // configurationVersion
        avcCBody.append(s[1]) // AVCProfileIndication
        avcCBody.append(s[2]) // profile_compatibility
        avcCBody.append(s[3]) // AVCLevelIndication
        avcCBody.append(0xFF) // 4-byte NAL lengths (lengthSizeMinusOne = 3)
        avcCBody.append(0xE1) // 1 SPS
        avcCBody.append(Self.u16(s.count)); avcCBody.append(contentsOf: s)
        avcCBody.append(1) // 1 PPS
        avcCBody.append(Self.u16(p.count)); avcCBody.append(contentsOf: p)
        let avcC = Self.box("avcC", avcCBody)

        var avc1Body = Data(capacity: 96 + avcC.count)
        avc1Body.append(Data(count: 6)); avc1Body.append(Self.u16(1)) // reserved, data_reference_index
        avc1Body.append(Data(count: 16)) // pre_defined/reserved
        avc1Body.append(Self.u16(width)); avc1Body.append(Self.u16(height))
        avc1Body.append(Self.u32(0x00480000)); avc1Body.append(Self.u32(0x00480000)) // 72 dpi
        avc1Body.append(Self.u32(0)); avc1Body.append(Self.u16(1)) // reserved, frame_count
        avc1Body.append(Data(count: 32)) // compressorname
        avc1Body.append(Self.u16(0x0018)); avc1Body.append(Self.u16(0xFFFF)) // depth, pre_defined
        avc1Body.append(avcC)
        let avc1 = Self.box("avc1", avc1Body)

        return Self.trak(trackID: Self.videoTrackID, width: width, height: height, volume: 0,
                         handler: "vide", handlerName: "VideoHandler",
                         mediaHeader: Self.fullBox("vmhd", 0, 1, Self.u16(0), Self.u16(0), Self.u16(0), Self.u16(0)),
                         sampleEntry: avc1)
    }

    private func audioTrak() -> Data {
        // Passthrough path: an ac-3 / ec-3 sample entry carrying the
        // source bitstream's own config, so nothing is re-encoded.
        if let config = passthroughConfig {
            return Self.trak(trackID: Self.audioTrackID, width: 0, height: 0, volume: 0x0100,
                             handler: "soun", handlerName: "SoundHandler",
                             mediaHeader: Self.fullBox("smhd", 0, 0, Self.u16(0), Self.u16(0)),
                             sampleEntry: Self.ac3SampleEntry(config))
        }
        // Transcode path: the encoder's own AudioSpecificConfig is the
        // asc, and the track is what the encoder emits (AAC-LC stereo),
        // not what the source mux carried.
        let sampleRate: Int
        let channels: Int
        let asc: [UInt8]
        if let transASC = transcodeASC {
            // AudioToolbox hands back a real AudioSpecificConfig for the
            // stereo AAC-LC it was configured to produce; that one is
            // authoritative and is not second-guessed here.
            asc = transASC
            sampleRate = transcodeSampleRate
            channels = 2
        } else {
            // Passthrough: the ADTS header's three config fields cannot go
            // into the ASC verbatim (see `sanitizedAACConfig`).
            let cfg = Self.sanitizedAACConfig(objectType: aacObjectType,
                                              freqIndex: aacFreqIndex,
                                              channelConfig: aacChannelConfig)
            asc = cfg.asc
            sampleRate = cfg.sampleRate
            channels = cfg.channels
        }
        // ES_Descriptor(3) > DecoderConfig(4) > DecoderSpecificInfo(5) + SLConfig(6).
        var dsi: [UInt8] = [0x05, UInt8(asc.count)]
        dsi.append(contentsOf: asc)
        var dcd = Data(capacity: 32)
        dcd.append(0x04)
        dcd.append(UInt8(13 + dsi.count))
        dcd.append(0x40) // objectTypeIndication: MPEG-4 AAC
        dcd.append(0x15) // streamType audio, upStream 0, reserved 1
        dcd.append(Data(count: 3)) // bufferSizeDB
        dcd.append(Self.u32(0)); dcd.append(Self.u32(0)) // maxBitrate, avgBitrate (unknown)
        dcd.append(contentsOf: dsi)
        let slc = Data([0x06, 0x01, 0x02])
        var es = Data(capacity: 48)
        es.append(0x03)
        es.append(UInt8(3 + dcd.count + slc.count))
        es.append(Self.u16(Self.audioTrackID)) // ES_ID
        es.append(0) // flags
        es.append(dcd)
        es.append(slc)
        let esds = Self.fullBox("esds", 0, 0, es)

        var mp4aBody = Data(capacity: 64 + esds.count)
        mp4aBody.append(Data(count: 6)); mp4aBody.append(Self.u16(1)) // reserved, data_reference_index
        mp4aBody.append(Data(count: 8)) // reserved
        mp4aBody.append(Self.u16(channels)); mp4aBody.append(Self.u16(16)) // channels, samplesize
        mp4aBody.append(Self.u32(0)) // pre_defined/reserved
        mp4aBody.append(Self.fixed16_16(sampleRate)) // 16.16 sample rate
        mp4aBody.append(esds)
        let mp4a = Self.box("mp4a", mp4aBody)

        return Self.trak(trackID: Self.audioTrackID, width: 0, height: 0, volume: 0x0100,
                         handler: "soun", handlerName: "SoundHandler",
                         mediaHeader: Self.fullBox("smhd", 0, 0, Self.u16(0), Self.u16(0)),
                         sampleEntry: mp4a)
    }

    /// `ac-3` (dac3) or `ec-3` (dec3) sample entry for the passthrough
    /// path. dac3 is ETSI TS 102 366 Annex F.4:
    /// fscod(2) bsid(5) bsmod(3) acmod(3) lfeon(1) bit_rate_code(5)
    /// reserved(5). dec3 is F.6 with a single independent substream:
    /// data_rate(13) num_ind_sub(3) then fscod(2) bsid(5) reserved(1)
    /// asvc(1) bsmod(3) acmod(3) lfeon(1) reserved(3) num_dep_sub(4)
    /// reserved(1).
    private static func ac3SampleEntry(_ c: CastAC3SampleEntryConfig) -> Data {
        var specific = Data()
        if c.codec == .eac3 {
            let rate = max(0, min(0x1FFF, c.dataRateKbps))
            specific.append(UInt8((rate >> 5) & 0xFF))
            specific.append(UInt8(((rate & 0x1F) << 3) | 0)) // num_ind_sub = 0 (one substream)
            specific.append(UInt8((c.fscod << 6) | (c.bsid << 1))) // reserved(1) = 0
            specific.append(UInt8((0 << 7) | (c.bsmod << 4) | (c.acmod << 1) | c.lfeon)) // asvc = 0
            specific.append(0) // reserved(3), num_dep_sub(4) = 0, reserved(1)
        } else {
            specific.append(UInt8((c.fscod << 6) | (c.bsid << 1) | (c.bsmod >> 2)))
            specific.append(UInt8(((c.bsmod & 0x03) << 6) | (c.acmod << 3)
                | (c.lfeon << 2) | ((c.bitRateCode >> 3) & 0x03)))
            specific.append(UInt8((c.bitRateCode & 0x07) << 5))
        }
        let configBox = box(c.codec == .eac3 ? "dec3" : "dac3", specific)
        var body = Data(capacity: 64 + configBox.count)
        body.append(Data(count: 6)); body.append(u16(1)) // reserved, data_reference_index
        body.append(Data(count: 8)) // reserved
        body.append(u16(max(1, c.channels))); body.append(u16(16)) // channels, samplesize
        body.append(u32(0)) // pre_defined/reserved
        body.append(fixed16_16(c.sampleRate)) // 16.16 sample rate
        body.append(configBox)
        return box(c.codec == .eac3 ? "ec-3" : "ac-3", body)
    }

    private static func trak(trackID: Int, width: Int, height: Int, volume: Int,
                             handler: String, handlerName: String,
                             mediaHeader: Data, sampleEntry: Data) -> Data {
        let tkhd = fullBox(
            "tkhd", 0, 7, // enabled | in movie | in preview
            u32(0), u32(0), u32(trackID), u32(0), u32(0), // times, id, reserved, duration
            u32(0), u32(0), // reserved
            u16(0), u16(0), u16(volume), u16(0), // layer, alt group, volume, reserved
            matrix(),
            u32(width << 16), u32(height << 16))
        let mdhd = fullBox(
            "mdhd", 0, 0,
            u32(0), u32(0), u32(Int(ticksPerSecond)), u32(0),
            u16(0x55C4), u16(0)) // language "und"
        let hdlr = fullBox(
            "hdlr", 0, 0,
            u32(0), bytes(handler), Data(count: 12),
            Data(handlerName.utf8), Data(count: 1))
        let dinf = box("dinf", fullBox("dref", 0, 0, u32(1), fullBox("url ", 0, 1)))
        let stbl = box(
            "stbl",
            fullBox("stsd", 0, 0, u32(1), sampleEntry),
            fullBox("stts", 0, 0, u32(0)),
            fullBox("stsc", 0, 0, u32(0)),
            fullBox("stsz", 0, 0, u32(0), u32(0)),
            fullBox("stco", 0, 0, u32(0)))
        let minf = box("minf", mediaHeader, dinf, stbl)
        let mdia = box("mdia", mdhd, hdlr, minf)
        return box("trak", tkhd, mdia)
    }

    private static func trex(_ trackID: Int) -> Data {
        fullBox("trex", 0, 0, u32(trackID), u32(1), u32(0), u32(0), u32(0x00010000))
    }

    // MARK: box plumbing

    private static func concat(_ parts: [Data]) -> Data {
        var out = Data(capacity: parts.reduce(0) { $0 + $1.count })
        for p in parts { out.append(p) }
        return out
    }

    private static func box(_ type: String, _ payload: Data...) -> Data {
        let size = 8 + payload.reduce(0) { $0 + $1.count }
        var out = Data(capacity: size)
        out.append(u32(size))
        out.append(bytes(type))
        for p in payload { out.append(p) }
        return out
    }

    private static func fullBox(_ type: String, _ version: Int, _ flags: Int, _ payload: Data...) -> Data {
        var body = Data([UInt8(version),
                         UInt8((flags >> 16) & 0xFF), UInt8((flags >> 8) & 0xFF), UInt8(flags & 0xFF)])
        for p in payload { body.append(p) }
        return box(type, body)
    }

    private static func bytes(_ s: String) -> Data { Data(s.utf8) }

    private static func u16(_ v: Int) -> Data {
        Data([UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
    }

    private static func u32(_ v: Int) -> Data {
        let u = UInt32(truncatingIfNeeded: v)
        return Data([UInt8((u >> 24) & 0xFF), UInt8((u >> 16) & 0xFF), UInt8((u >> 8) & 0xFF), UInt8(u & 0xFF)])
    }

    /// 16.16 fixed point. `u32(rate << 16)` silently truncates once the
    /// rate passes 65535 (96 kHz AAC shifted left by 16 overflows 32
    /// bits and lands on 30464 Hz), so the integer part is clamped.
    private static func fixed16_16(_ v: Int) -> Data {
        u16(max(0, min(0xFFFF, v))) + u16(0)
    }

    private static func u64(_ v: UInt64) -> Data {
        u32(Int(truncatingIfNeeded: Int64(bitPattern: v >> 32))) + u32(Int(truncatingIfNeeded: Int64(bitPattern: v & 0xFFFF_FFFF)))
    }

    private static func findSync(_ buf: [UInt8]) -> Int? {
        var i = 0
        let limit = buf.count - 2 * tsPacket - 1
        while i <= limit {
            if buf[i] == 0x47, buf[i + tsPacket] == 0x47, buf[i + 2 * tsPacket] == 0x47 {
                return i
            }
            i += 1
        }
        return nil
    }

    // MARK: SPS dimensions (best effort; tkhd/avc1 sizing only, decoders
    // read the SPS itself from avcC)

    private struct SPSParseError: Error {}

    static func parseSPSDimensions(_ spsNAL: [UInt8]) throws -> (width: Int, height: Int) {
        // Strip emulation prevention bytes, skip the NAL header byte.
        var rbsp = [UInt8]()
        rbsp.reserveCapacity(spsNAL.count)
        var i = 1
        while i < spsNAL.count {
            if i + 2 < spsNAL.count, spsNAL[i] == 0, spsNAL[i + 1] == 0, spsNAL[i + 2] == 3 {
                rbsp.append(0); rbsp.append(0)
                i += 3
            } else {
                rbsp.append(spsNAL[i])
                i += 1
            }
        }
        var r = BitReader(rbsp)
        let profileIDC = try r.bits(8)
        _ = try r.bits(16) // constraints + level
        _ = try r.ue() // seq_parameter_set_id
        var chromaFormat = 1
        if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134].contains(profileIDC) {
            chromaFormat = try r.ue()
            if chromaFormat == 3 { _ = try r.bits(1) }
            _ = try r.ue(); _ = try r.ue(); _ = try r.bits(1) // bit depths, qpprime
            if try r.bits(1) == 1 { // seq_scaling_matrix_present
                let lists = chromaFormat == 3 ? 12 : 8
                for l in 0..<lists where try r.bits(1) == 1 {
                    try skipScalingList(&r, l < 6 ? 16 : 64)
                }
            }
        }
        _ = try r.ue() // log2_max_frame_num_minus4
        switch try r.ue() { // pic_order_cnt_type
        case 0:
            _ = try r.ue()
        case 1:
            _ = try r.bits(1); _ = try r.se(); _ = try r.se()
            let n = try r.ue()
            for _ in 0..<n { _ = try r.se() }
        default:
            break
        }
        _ = try r.ue(); _ = try r.bits(1) // max_num_ref_frames, gaps_allowed
        let widthMBs = try r.ue() + 1
        let heightMapUnits = try r.ue() + 1
        let frameMBsOnly = try r.bits(1)
        if frameMBsOnly == 0 { _ = try r.bits(1) }
        _ = try r.bits(1) // direct_8x8
        var cropL = 0, cropR = 0, cropT = 0, cropB = 0
        if try r.bits(1) == 1 {
            cropL = try r.ue(); cropR = try r.ue(); cropT = try r.ue(); cropB = try r.ue()
        }
        let cropUnitX = chromaFormat == 0 ? 1 : 2
        let cropUnitY = (chromaFormat <= 1 ? 2 : 1) * (2 - frameMBsOnly)
        let width = widthMBs * 16 - (cropL + cropR) * cropUnitX
        let height = heightMapUnits * 16 * (2 - frameMBsOnly) - (cropT + cropB) * cropUnitY
        guard width > 0, height > 0, width <= 8192, height <= 8192 else { throw SPSParseError() }
        return (width, height)
    }

    private static func skipScalingList(_ r: inout BitReader, _ size: Int) throws {
        var lastScale = 8
        var nextScale = 8
        for _ in 0..<size {
            if nextScale != 0 { nextScale = (lastScale + (try r.se()) + 256) % 256 }
            if nextScale != 0 { lastScale = nextScale }
        }
    }

    private struct BitReader {
        private let data: [UInt8]
        private var pos = 0

        init(_ data: [UInt8]) { self.data = data }

        mutating func bits(_ n: Int) throws -> Int {
            var v = 0
            for _ in 0..<n {
                let byteIndex = pos >> 3
                guard byteIndex < data.count else { throw SPSParseError() }
                v = (v << 1) | ((Int(data[byteIndex]) >> (7 - (pos & 7))) & 1)
                pos += 1
            }
            return v
        }

        mutating func ue() throws -> Int {
            var zeros = 0
            while try bits(1) == 0, zeros < 32 { zeros += 1 }
            return (1 << zeros) - 1 + (zeros > 0 ? try bits(zeros) : 0)
        }

        mutating func se() throws -> Int {
            let k = try ue()
            return k % 2 == 0 ? -(k / 2) : (k + 1) / 2
        }
    }
}
