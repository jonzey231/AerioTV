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
    let codecName: String
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

    private let targetSegmentTicks: Int64
    private let log: (String) -> Void
    /// Injectable for the CLI tests (AudioToolbox codecs are not
    /// exercised there); production uses the real transcoder.
    private let transcoderFactory: (CastAudioSourceCodec,
                                    @escaping (_ asc: [UInt8], _ sampleRate: Int) -> Void,
                                    @escaping (_ data: [UInt8], _ ptsTicks: Int64) -> Void) -> CastAudioTranscoding

    init(targetSegmentTicks: Int64 = 3 * CastFMP4Remuxer.ticksPerSecond,
         log: @escaping (String) -> Void = { _ in },
         transcoderFactory: ((CastAudioSourceCodec,
                              @escaping (_ asc: [UInt8], _ sampleRate: Int) -> Void,
                              @escaping (_ data: [UInt8], _ ptsTicks: Int64) -> Void) -> CastAudioTranscoding)? = nil) {
        self.targetSegmentTicks = targetSegmentTicks
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
    /// Where the source audio clock should continue; a jump past the
    /// discontinuity threshold flushes the codecs (splice/reconnect).
    private var expectedSrcAudioPTS: Int64 = -1

    // MARK: timeline

    private var videoClock = PTSUnwrapper()
    private var audioClock = PTSUnwrapper()
    /// First queued video DTS; every tfdt is relative to this so the
    /// receiver's timeline starts near zero.
    private var timelineBase: Int64 = -1

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
                codecName: Self.streamTypeNames[videoType] ?? String(format: "video stream_type 0x%02X", videoType))
        }
        if audio >= 0, audioType != Self.streamTypeAACADTS {
            // The AC-3 family routes through the on-phone transcode
            // instead of refusing (the web receiver cannot decode it and
            // HDMI passthrough is a lottery). Everything else refuses.
            guard let source = Self.transcodeSources[audioType] else {
                throw CastUnsupportedCodecError(
                    codecName: Self.streamTypeNames[audioType] ?? String(format: "audio stream_type 0x%02X", audioType))
            }
            audioSource = source
        }
        if video < 0 { throw CastUnsupportedCodecError(codecName: "no video stream in PMT") }
        videoPID = video
        audioPID = audio // may stay -1: video-only mux is fine
        if audio < 0 {
            audioPathDescription = "none (video only)"
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
        if timelineBase < 0 { timelineBase = dts }

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
        if let source = audioSource {
            try onTranscodeAudioPES(source, payload, pts33: pts33)
        } else {
            onADTSAudioPES(payload, pts33: pts33)
        }
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
                    // once the init exists and video anchored the timeline.
                    if self.initSent, self.timelineBase >= 0 {
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
            if aacFreqIndex < 0 {
                aacObjectType = profile + 1 // ADTS profile is MPEG-4 audioObjectType - 1
                aacFreqIndex = freqIndex
                aacChannelConfig = chanConfig
                let rate = Self.adtsSampleRates.indices.contains(freqIndex) ? Self.adtsSampleRates[freqIndex] : 48_000
                audioFrameTicks = 1024 * Self.ticksPerSecond / Int64(rate)
                maybeEmitInit()
            }
            if initSent, frameLen > headerLen {
                // First frame of the PES rides the PES PTS; followers step
                // by the fixed 1024-sample frame duration. Re-anchoring on
                // every PES keeps drift bounded to one PES worth of frames.
                if framePTS < 0 { framePTS = audioClock.unwrap(pts33) }
                if timelineBase >= 0 {
                    audioQueue.append(AudioSample(data: Array(data[(p + headerLen)..<(p + frameLen)]), pts: framePTS))
                }
                framePTS += audioFrameTicks
            }
            p += frameLen
        }
        if p < data.count { audioCarry = Array(data[p...]) }
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
        videoQueue.removeAll(keepingCapacity: true)
        audioQueue = keepAudio
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
                Self.fullBox("tfhd", 0, 0x020000, Self.u32(Self.audioTrackID)),
                Self.fullBox("tfdt", 1, 0, Self.u64(UInt64(max(0, firstAudio.pts - timelineBase)))),
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
        // Transcode path: the encoder's own AudioSpecificConfig is the
        // asc, and the track is what the encoder emits (AAC-LC stereo),
        // not what the source mux carried.
        let sampleRate: Int
        let channels: Int
        let asc: [UInt8]
        if let transASC = transcodeASC {
            asc = transASC
            sampleRate = transcodeSampleRate
            channels = 2
        } else {
            sampleRate = Self.adtsSampleRates.indices.contains(aacFreqIndex)
                ? Self.adtsSampleRates[aacFreqIndex] : 48_000
            channels = max(1, aacChannelConfig)
            asc = [UInt8((aacObjectType << 3) | (aacFreqIndex >> 1)),
                   UInt8(((aacFreqIndex & 1) << 7) | (aacChannelConfig << 3))]
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
        mp4aBody.append(Self.u32(sampleRate << 16)) // 16.16 sample rate
        mp4aBody.append(esds)
        let mp4a = Self.box("mp4a", mp4aBody)

        return Self.trak(trackID: Self.audioTrackID, width: 0, height: 0, volume: 0x0100,
                         handler: "soun", handlerName: "SoundHandler",
                         mediaHeader: Self.fullBox("smhd", 0, 0, Self.u16(0), Self.u16(0)),
                         sampleEntry: mp4a)
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
