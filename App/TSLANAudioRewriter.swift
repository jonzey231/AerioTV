//
//  TSLANAudioRewriter.swift
//  Aerio
//
//  AirPlay LAN audio rewrite (2026-09-26). AirPlay always serves the
//  remuxer's TS LAN playlist; for a receiver that cannot decode AC-3 /
//  E-AC-3 (Roku) the LAN copy of each segment carries AAC-LC stereo in
//  place of the source audio, muxed into the SAME TS segment. Video and
//  every other packet are copied untouched; segment boundaries, durations
//  and the playlist are the remuxer's own.
//
//  Pure logic plus the shared Cast transcoder, no networking and no app
//  singletons, so Scripts/cast-hls-proxy-tests compiles it as is.
//

import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
import VideoToolbox

/// Rewrites one TS segment at a time, in sequence order, for LAN delivery:
/// - the PMT names the rewritten audio PID as stream_type 0x0F (ADTS AAC),
///   drops the other audio entries, and gets a fresh CRC32;
/// - the source audio PES on that PID is decoded, downmixed and encoded to
///   AAC-LC stereo by `CastAudioTranscoder`, and the AAC frames go back
///   out as ADTS PES on the same PID with regenerated continuity counters;
/// - packets of the other audio PIDs are dropped;
/// - everything else, including the PCR on the video PID, is copied.
///
/// Stateful (transcoder, PES carry, continuity counter): feed segments in
/// order and call `reset()` on a gap. Not thread-safe; `TSLANAudioStage`
/// serializes it.
final class TSLANAudioRewriter {

    static let packetSize = 188
    static let aacStreamType: UInt8 = 0x0F
    static let audioStreamID: UInt8 = 0xC0
    static let pts33Mask: Int64 = (1 << 33) - 1

    typealias TranscoderFactory = (CastAudioSourceCodec,
                                   @escaping (_ asc: [UInt8], _ sampleRate: Int) -> Void,
                                   @escaping (_ data: [UInt8], _ ptsTicks: Int64) -> Void) -> CastAudioTranscoding

    private let log: (String) -> Void
    private let transcoderFactory: TranscoderFactory
    private let canDecode: (CastAudioSourceCodec) -> Bool

    // Program state, learned from the segment's own PAT / PMT.
    private var pmtPID = -1
    private var videoPID = -1
    private var targetPID = -1
    private var droppedPIDs = Set<Int>()
    private var source: CastAudioSourceCodec?
    private var lastPMTIn: [UInt8] = []
    private var lastPMTOut: [UInt8]?

    // Transcode state.
    private var transcoder: CastAudioTranscoding?
    private var transcoderSource: CastAudioSourceCodec?
    private var aacFreqIndex: Int?
    private var aacOut: [(data: [UInt8], pts: Int64)] = []
    private var pesBuffer: [UInt8]?
    private var esCarry: [UInt8] = []
    private var runPTS: Int64 = -1
    private var lastUnwrapped: Int64 = -1
    /// First video PTS after a (re)start. AAC frames stamped before it are
    /// dropped: the encoder starts on the first decodable audio frame, which
    /// on a mid-GOP cut precedes the segment's first picture, and the
    /// encoder's first packets carry its priming. Same gate as the Cast
    /// remuxer's "transcoded audio gated" path.
    private var gatePTS: Int64 = -1
    private var gatedUnits = 0
    private var audioCC: UInt8 = 0

    /// Set once the transcode could not run; every later segment passes
    /// through unchanged.
    private(set) var failed = false
    private var activeLogged = false
    private var unsupportedLogged = false
    private var pcrLogged = false

    init(log: @escaping (String) -> Void,
         canDecode: @escaping (CastAudioSourceCodec) -> Bool = CastAudioTranscoder.canDecode,
         transcoderFactory: TranscoderFactory? = nil) {
        self.log = log
        self.canDecode = canDecode
        self.transcoderFactory = transcoderFactory ?? { source, onConfig, onFrame in
            CastAudioTranscoder(source: source, onEncoderConfig: onConfig, onAACFrame: onFrame, log: log)
        }
    }

    deinit { transcoder?.release() }

    /// A gap or a backward jump in the sequence: drop codec and PES state
    /// and re-anchor on the next segment. The continuity counter keeps
    /// counting.
    func reset() {
        transcoder?.flush()
        aacOut.removeAll()
        pesBuffer = nil
        esCarry = []
        runPTS = -1
        gatePTS = -1
        gatedUnits = 0
    }

    // MARK: Segment

    /// The LAN copy of one TS segment. Returns the input unchanged when the
    /// audio is not rewritable (no AC-3 / E-AC-3 PID, no decoder, PCR on the
    /// audio PID) or the transcode failed.
    func rewrite(_ segment: Data) -> Data {
        guard !failed else { return segment }
        let bytes = [UInt8](segment)
        let n = Self.packetSize
        var out = [UInt8]()
        out.reserveCapacity(bytes.count)
        var i = 0
        while i + n <= bytes.count {
            let p = Array(bytes[i..<(i + n)])
            i += n
            guard p[0] == 0x47 else { out.append(contentsOf: p); continue }
            let pid = (Int(p[1] & 0x1F) << 8) | Int(p[2])
            let pusi = p[1] & 0x40 != 0
            if pid == 0 {
                if pusi, let pmt = Self.firstPMTPID(p) { pmtPID = pmt }
                out.append(contentsOf: p)
            } else if pid == pmtPID {
                out.append(contentsOf: rewritePMTPacket(p))
            } else if pid == targetPID, source != nil {
                if pusi {
                    finishPES(into: &out)
                    pesBuffer = Self.payload(p).map { Array($0) } ?? []
                } else if pesBuffer != nil, let pl = Self.payload(p) {
                    pesBuffer!.append(contentsOf: pl)
                }
            } else if droppedPIDs.contains(pid) {
                continue
            } else {
                if pid == videoPID, pusi, gatePTS < 0, let pts = Self.pesPTS(p) {
                    gatePTS = unwrap(pts)
                }
                out.append(contentsOf: p)
            }
            if failed { return segment }
        }
        if i < bytes.count { out.append(contentsOf: bytes[i...]) }
        if source != nil { finishPES(into: &out) }
        if failed { return segment }
        return Data(out)
    }

    // MARK: PMT

    private func rewritePMTPacket(_ p: [UInt8]) -> [UInt8] {
        if p == lastPMTIn, let cached = lastPMTOut { return cached }
        lastPMTIn = p
        lastPMTOut = nil
        guard let info = Self.parsePMT(p) else { return p }
        videoPID = info.videoPID
        let target = info.audio.first { $0.type == 0x81 || $0.type == 0x87 }
        let codec: CastAudioSourceCodec? = target.map { $0.type == 0x87 ? .eac3 : .ac3 }
        guard let target, let codec else {
            if !unsupportedLogged {
                unsupportedLogged = true
                let types = info.audio.map { String(format: "0x%02X", $0.type) }.joined(separator: ",")
                log("LAN audio: source audio [\(types)] is not AC-3 / E-AC-3, not supported by the transcoder; LAN audio stays passthrough")
            }
            deactivate()
            return p
        }
        guard canDecode(codec) else {
            if !unsupportedLogged {
                unsupportedLogged = true
                log("LAN audio: no platform decoder for \(codec.displayName); LAN audio stays passthrough")
            }
            deactivate()
            return p
        }
        guard info.pcrPID != target.pid else {
            if !pcrLogged {
                pcrLogged = true
                log("LAN audio: PCR rides the audio PID \(target.pid); LAN audio stays passthrough")
            }
            deactivate()
            return p
        }
        guard let rewritten = Self.rewritePMT(p, targetPID: target.pid) else { return p }
        if targetPID != target.pid || source != codec {
            if targetPID >= 0 { reset() }
            targetPID = target.pid
            source = codec
        }
        droppedPIDs = Set(info.audio.map(\.pid).filter { $0 != target.pid })
        lastPMTOut = rewritten
        return rewritten
    }

    private func deactivate() {
        targetPID = -1
        source = nil
        droppedPIDs = []
    }

    struct PMTInfo: Equatable {
        var pcrPID: Int
        var videoPID: Int
        var audio: [AudioES]
        /// stream_type of `videoPID` (0x1B H.264, 0x24 HEVC), 0 when none.
        var videoType: UInt8 = 0
        struct AudioES: Equatable { var pid: Int; var type: UInt8 }
    }

    /// True for an ES entry the remuxer treats as audio, plus DVB-style
    /// private data (0x06) carrying an AC-3 / E-AC-3 descriptor.
    static func isAudio(type: UInt8, descriptors: ArraySlice<UInt8>) -> Bool {
        switch type {
        case 0x81, 0x87, 0x0F, 0x03, 0x04, 0x11: return true
        case 0x06:
            var d = descriptors.startIndex
            while d + 1 < descriptors.endIndex {
                let tag = descriptors[d]
                if tag == 0x6A || tag == 0x7A { return true }
                d += 2 + Int(descriptors[d + 1])
            }
            return false
        default: return false
        }
    }

    /// Offset of the section (after the pointer field) in a PMT packet.
    private static func sectionStart(_ p: [UInt8]) -> Int? {
        guard p.count == packetSize, p[1] & 0x40 != 0, let base = payloadOffset(p), base < packetSize else { return nil }
        let s = base + 1 + Int(p[base])
        guard s + 12 < packetSize, p[s] == 0x02 else { return nil }
        return s
    }

    static func parsePMT(_ p: [UInt8]) -> PMTInfo? {
        guard let s = sectionStart(p) else { return nil }
        let sectionLength = (Int(p[s + 1] & 0x0F) << 8) | Int(p[s + 2])
        let end = s + 3 + sectionLength - 4
        guard end <= packetSize else { return nil }
        let pcr = (Int(p[s + 8] & 0x1F) << 8) | Int(p[s + 9])
        let pil = (Int(p[s + 10] & 0x0F) << 8) | Int(p[s + 11])
        var o = s + 12 + pil
        var info = PMTInfo(pcrPID: pcr, videoPID: -1, audio: [])
        while o + 5 <= end {
            let type = p[o]
            let pid = (Int(p[o + 1] & 0x1F) << 8) | Int(p[o + 2])
            let esil = (Int(p[o + 3] & 0x0F) << 8) | Int(p[o + 4])
            guard o + 5 + esil <= end else { break }
            let desc = p[(o + 5)..<(o + 5 + esil)]
            if [0x1B, 0x24, 0x01, 0x02].contains(type) {
                if info.videoPID < 0 { info.videoPID = pid; info.videoType = type }
            } else if isAudio(type: type, descriptors: desc) {
                info.audio.append(.init(pid: pid, type: type))
            }
            o += 5 + esil
        }
        return info
    }

    /// The PMT packet with `targetPID` declared as ADTS AAC (0x0F, only its
    /// ISO 639 language descriptor kept), every other audio entry removed,
    /// section_length and CRC32 recomputed. The TS header (PID, CC) is kept;
    /// an adaptation field, if any, is dropped. Nil when the section does
    /// not fit one packet or is malformed.
    static func rewritePMT(_ p: [UInt8], targetPID: Int) -> [UInt8]? {
        guard let s = sectionStart(p) else { return nil }
        let sectionLength = (Int(p[s + 1] & 0x0F) << 8) | Int(p[s + 2])
        let end = s + 3 + sectionLength - 4
        guard end <= packetSize else { return nil }
        let pil = (Int(p[s + 10] & 0x0F) << 8) | Int(p[s + 11])
        let esStart = s + 12 + pil
        guard esStart <= end else { return nil }
        var section = Array(p[s..<esStart])
        var o = esStart
        var found = false
        while o + 5 <= end {
            let type = p[o]
            let pid = (Int(p[o + 1] & 0x1F) << 8) | Int(p[o + 2])
            let esil = (Int(p[o + 3] & 0x0F) << 8) | Int(p[o + 4])
            guard o + 5 + esil <= end else { return nil }
            let desc = p[(o + 5)..<(o + 5 + esil)]
            if pid == targetPID {
                found = true
                var kept = [UInt8]()
                var d = desc.startIndex
                while d + 1 < desc.endIndex {
                    let len = Int(desc[d + 1])
                    guard d + 2 + len <= desc.endIndex else { break }
                    if desc[d] == 0x0A { kept.append(contentsOf: desc[d..<(d + 2 + len)]) }
                    d += 2 + len
                }
                section.append(aacStreamType)
                section.append(p[o + 1])
                section.append(p[o + 2])
                section.append(0xF0 | UInt8((kept.count >> 8) & 0x0F))
                section.append(UInt8(kept.count & 0xFF))
                section.append(contentsOf: kept)
            } else if !isAudio(type: type, descriptors: desc) {
                section.append(contentsOf: p[o..<(o + 5 + esil)])
            }
            o += 5 + esil
        }
        guard found else { return nil }
        let newLength = section.count - 3 + 4
        section[1] = (section[1] & 0xF0) | UInt8((newLength >> 8) & 0x0F)
        section[2] = UInt8(newLength & 0xFF)
        let crc = crc32MPEG(section)
        section.append(contentsOf: [UInt8(crc >> 24), UInt8((crc >> 16) & 0xFF),
                                    UInt8((crc >> 8) & 0xFF), UInt8(crc & 0xFF)])
        guard 5 + section.count <= packetSize else { return nil }
        var out = [UInt8](repeating: 0xFF, count: packetSize)
        out[0] = 0x47
        out[1] = p[1]
        out[2] = p[2]
        out[3] = 0x10 | (p[3] & 0x0F) // payload only, same CC
        out[4] = 0x00                 // pointer field
        out.replaceSubrange(5..<(5 + section.count), with: section)
        return out
    }

    /// CRC-32/MPEG-2 (poly 0x04C11DB7, init all ones, no reflection, no
    /// final xor), as PSI sections carry it.
    static func crc32MPEG(_ data: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 {
                crc = crc & 0x8000_0000 != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1
            }
        }
        return crc
    }

    // MARK: Audio

    private func finishPES(into out: inout [UInt8]) {
        guard let buffered = pesBuffer else { return }
        pesBuffer = nil
        guard let source, buffered.count >= 9, buffered[0] == 0, buffered[1] == 0, buffered[2] == 1 else { return }
        // A declared PES_packet_length bounds the payload.
        let declared = (Int(buffered[4]) << 8) | Int(buffered[5])
        let pes = declared > 0 && 6 + declared < buffered.count ? Array(buffered[0..<(6 + declared)]) : buffered
        let headerEnd = 9 + Int(pes[8])
        guard headerEnd <= pes.count else { return }
        var pesPTS: Int64?
        if pes[7] & 0x80 != 0, pes.count >= 14 { pesPTS = unwrap(Self.decodePTS(pes, 9)) }
        let carryLen = esCarry.count
        var data = esCarry
        data.append(contentsOf: pes[headerEnd...])
        esCarry = []
        var usedPESPTS = false
        var p = 0
        while p < data.count {
            guard let info = CastAudioFrameParser.parseFrameHeader(source, data, p) else {
                if data.count - p < 8 { break }
                p += 1
                continue
            }
            let next = p + info.frameLength
            if next > data.count { break }
            if next + 1 < data.count, !CastAudioFrameParser.looksLikeSync(source, data, next) {
                p += 1
                continue
            }
            let frameTicks = Int64(info.samplesPerFrame) * 90_000 / Int64(info.sampleRate)
            var pts = runPTS
            if p >= carryLen, !usedPESPTS, let pesPTS {
                usedPESPTS = true
                if runPTS >= 0, abs(pesPTS - runPTS) > CastAudioTranscoder.discontinuityTicks {
                    log("LAN audio: pts discontinuity (\((pesPTS - runPTS) / 90) ms), flushing transcode codecs")
                    transcoder?.flush()
                }
                pts = pesPTS
            }
            guard pts >= 0 else { p = next; continue }
            runPTS = pts + frameTicks
            do {
                let t = try transcoderFor(source)
                if !activeLogged {
                    activeLogged = true
                    log("LAN audio: \(source.displayName) \(info.channels)ch -> AAC-LC stereo muxed into TS (PID \(targetPID), PMT rewritten)")
                }
                try t.feed(data, range: p..<next, ptsTicks: pts, info: info)
            } catch {
                failed = true
                log("LAN audio: \(source.displayName) transcode failed (\(error)); LAN audio falls back to passthrough")
                return
            }
            p = next
        }
        if p < data.count { esCarry = Array(data[p...]) }
        emitAAC(into: &out)
    }

    private func transcoderFor(_ source: CastAudioSourceCodec) throws -> CastAudioTranscoding {
        if let t = transcoder, transcoderSource == source { return t }
        transcoder?.release()
        let t = transcoderFactory(source, { [weak self] _, rate in
            self?.aacFreqIndex = Self.adtsFrequencyIndex(rate)
        }, { [weak self] frame, pts in
            self?.aacOut.append((frame, pts))
        })
        transcoder = t
        transcoderSource = source
        return t
    }

    /// The AAC frames the encoder produced so far, gated, as one ADTS PES.
    private func emitAAC(into out: inout [UInt8]) {
        guard !aacOut.isEmpty else { return }
        let frames = aacOut
        aacOut.removeAll(keepingCapacity: true)
        guard let freq = aacFreqIndex else { return }
        var payload = [UInt8]()
        var firstPTS: Int64?
        for f in frames {
            if gatePTS < 0 || f.pts < gatePTS {
                gatedUnits += 1
                if gatedUnits == 1 {
                    log(String(format: "LAN audio: transcoded audio gated, pts %.3fs below the first video pts %.3fs",
                               Double(f.pts) / 90_000, Double(gatePTS) / 90_000))
                }
                continue
            }
            if firstPTS == nil { firstPTS = f.pts }
            payload.append(contentsOf: Self.adtsHeader(payloadLength: f.data.count, frequencyIndex: freq))
            payload.append(contentsOf: f.data)
        }
        guard let firstPTS else { return }
        out.append(contentsOf: Self.packetizePES(payload: payload, pts: firstPTS & Self.pts33Mask,
                                                 pid: targetPID, cc: &audioCC))
    }

    private func unwrap(_ pts33: Int64) -> Int64 {
        guard lastUnwrapped >= 0 else { lastUnwrapped = pts33; return pts33 }
        let period: Int64 = 1 << 33
        var v = (lastUnwrapped & ~Self.pts33Mask) + pts33
        if v - lastUnwrapped > period / 2 { v -= period }
        if lastUnwrapped - v > period / 2 { v += period }
        if v < 0 { v += period }
        lastUnwrapped = v
        return v
    }

    // MARK: Packet helpers (pure)

    static func adtsFrequencyIndex(_ rate: Int) -> Int? {
        [96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000, 22_050,
         16_000, 12_000, 11_025, 8_000, 7_350].firstIndex(of: rate)
    }

    /// 7-byte ADTS header, AAC-LC, no CRC.
    static func adtsHeader(payloadLength: Int, frequencyIndex: Int, channels: Int = 2) -> [UInt8] {
        let len = payloadLength + 7
        return [0xFF, 0xF1,
                UInt8((1 << 6) | (frequencyIndex << 2) | ((channels >> 2) & 1)),
                UInt8(((channels & 3) << 6) | ((len >> 11) & 3)),
                UInt8((len >> 3) & 0xFF),
                UInt8(((len & 7) << 5) | 0x1F),
                0xFC]
    }

    static func encodePTS(_ pts: Int64) -> [UInt8] {
        [UInt8(0x21 | ((pts >> 29) & 0x0E)),
         UInt8((pts >> 22) & 0xFF),
         UInt8(((pts >> 14) & 0xFE) | 1),
         UInt8((pts >> 7) & 0xFF),
         UInt8(((pts << 1) & 0xFE) | 1)]
    }

    static func decodePTS(_ b: [UInt8], _ o: Int) -> Int64 {
        (Int64(b[o] & 0x0E) << 29) | (Int64(b[o + 1]) << 22) | (Int64(b[o + 2] & 0xFE) << 14)
            | (Int64(b[o + 3]) << 7) | (Int64(b[o + 4]) >> 1)
    }

    /// One PES (stream_id 0xC0, PTS only) split into 188-byte TS packets on
    /// `pid`; the last packet is padded with adaptation-field stuffing. `cc`
    /// is the PID's continuity counter, advanced per packet.
    static func packetizePES(payload: [UInt8], pts: Int64, pid: Int, cc: inout UInt8) -> [UInt8] {
        var pes: [UInt8] = [0x00, 0x00, 0x01, audioStreamID]
        let pesLength = 3 + 5 + payload.count
        let lengthField = pesLength <= 0xFFFF ? pesLength : 0
        pes.append(UInt8(lengthField >> 8))
        pes.append(UInt8(lengthField & 0xFF))
        pes.append(contentsOf: [0x80, 0x80, 0x05])
        pes.append(contentsOf: encodePTS(pts))
        pes.append(contentsOf: payload)
        var out = [UInt8]()
        out.reserveCapacity((pes.count / 184 + 1) * packetSize)
        var o = 0
        var first = true
        while o < pes.count {
            let remaining = pes.count - o
            var header: [UInt8] = [0x47,
                                   UInt8((first ? 0x40 : 0) | ((pid >> 8) & 0x1F)),
                                   UInt8(pid & 0xFF)]
            if remaining >= 184 {
                header.append(0x10 | (cc & 0x0F))
                out.append(contentsOf: header)
                out.append(contentsOf: pes[o..<(o + 184)])
                o += 184
            } else {
                header.append(0x30 | (cc & 0x0F))
                let afLength = 183 - remaining
                out.append(contentsOf: header)
                out.append(UInt8(afLength))
                if afLength > 0 {
                    out.append(0x00)
                    if afLength > 1 { out.append(contentsOf: [UInt8](repeating: 0xFF, count: afLength - 1)) }
                }
                out.append(contentsOf: pes[o...])
                o = pes.count
            }
            cc = (cc + 1) & 0x0F
            first = false
        }
        return out
    }

    /// Offset of the payload in a TS packet (after any adaptation field).
    static func payloadOffset(_ p: [UInt8]) -> Int? {
        let afc = (p[3] >> 4) & 0x03
        guard afc & 0x01 != 0 else { return nil }
        var off = 4
        if afc & 0x02 != 0 { off += 1 + Int(p[4]) }
        return off < packetSize ? off : nil
    }

    static func payload(_ p: [UInt8]) -> ArraySlice<UInt8>? {
        payloadOffset(p).map { p[$0...] }
    }

    static func pesPTS(_ p: [UInt8]) -> Int64? {
        guard let o = payloadOffset(p), o + 14 <= packetSize,
              p[o] == 0, p[o + 1] == 0, p[o + 2] == 1, p[o + 7] & 0x80 != 0 else { return nil }
        return decodePTS(p, o + 9)
    }

    static func firstPMTPID(_ p: [UInt8]) -> Int? {
        guard let base = payloadOffset(p) else { return nil }
        var o = base + 1 + Int(p[base])
        guard o + 8 < packetSize, p[o] == 0x00 else { return nil }
        let sectionLength = (Int(p[o + 1] & 0x0F) << 8) | Int(p[o + 2])
        let end = min(o + 3 + sectionLength - 4, packetSize)
        o += 8
        while o + 4 <= end {
            let program = (Int(p[o]) << 8) | Int(p[o + 1])
            let pid = (Int(p[o + 2] & 0x1F) << 8) | Int(p[o + 3])
            if program != 0 { return pid }
            o += 4
        }
        return nil
    }
}

/// Thread-safe front of `TSLANAudioRewriter` for the LAN server: produces
/// each segment's LAN copy lazily on its first LAN request, in sequence
/// order (feeding any skipped segments first), and caches it until the
/// remuxer's ring evicts the source.
final class TSLANAudioStage: @unchecked Sendable {

    /// A request further ahead than this re-anchors instead of catching up.
    static let maxCatchUp = 8

    private let lock = NSLock()
    private let rewriter: TSLANAudioRewriter
    private var cache: [Int: Data] = [:]
    private var nextSeq = -1

    init(rewriter: TSLANAudioRewriter) {
        self.rewriter = rewriter
    }

    /// The source segments the caller must supply to `produce` for `seq`
    /// (empty when cached).
    func sourcesNeeded(for seq: Int) -> [Int] {
        lock.lock(); defer { lock.unlock() }
        if cache[seq] != nil { return [] }
        if nextSeq >= 0, seq >= nextSeq, seq - nextSeq < Self.maxCatchUp { return Array(nextSeq...seq) }
        return [seq]
    }

    /// The LAN copy of `seq`, rewriting `sources` (any order) first. Nil
    /// when `seq` is neither cached nor among the sources. `oldestSeq` is
    /// the oldest segment the remuxer still holds; older cache entries go.
    /// `discontinuities` are the seqs that open a new source (a channel
    /// flip in place or a Switch Stream change): the old source's codec
    /// and PES state must not run into the new one, whose PTS clock is
    /// unrelated.
    func produce(seq: Int, sources: [(seq: Int, data: Data)], oldestSeq: Int,
                 discontinuities: Set<Int> = []) -> Data? {
        lock.lock(); defer { lock.unlock() }
        for s in sources.sorted(by: { $0.seq < $1.seq }) where cache[s.seq] == nil {
            if s.seq != nextSeq || discontinuities.contains(s.seq) { rewriter.reset() }
            cache[s.seq] = rewriter.rewrite(s.data)
            nextSeq = s.seq + 1
        }
        let result = cache[seq]
        for k in cache.keys where k < oldestSeq { cache[k] = nil }
        return result
    }

    var cachedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return cache.count
    }
}

// MARK: - Audio-only card video (AirPlay LAN)

/// AirPlay LAN copy of an audio-only program (GH #90 follow-up): the
/// receiver (Roku, Apple TV) shows black for a TS with no video track, so
/// the LAN segments get a static picture, the app's audio-only logo card,
/// as an H.264 elementary stream muxed into the SAME TS segment:
/// - the PMT gains a stream_type 0x1B entry on an unused PID, which also
///   becomes the PCR_PID; section_length and CRC32 are recomputed;
/// - each segment carries the card access unit (AUD + SPS + PPS + IDR, one
///   pre-encoded picture) right after its PAT/PMT, so every segment opens
///   on an IDR and decodes on its own, then again every `1 / fps` s of
///   audio PTS, each time with PTS equal to the audio PES it precedes;
/// - a PCR rides the video PID on every IDR and in adaptation-only packets
///   at least every 100 ms of audio PTS, a fixed lead behind the audio;
/// - every original packet is copied untouched.
///
/// Pure logic, no encoder: the caller supplies the encoded access unit.
enum TSCardVideoMuxer {

    static let videoStreamType: UInt8 = 0x1B
    static let videoStreamID: UInt8 = 0xE0
    /// PCR lead behind the PTS it is stamped against (100 ms).
    static let pcrLeadTicks: Int64 = 9_000
    static let pcrIntervalTicks: Int64 = 9_000
    static let candidatePIDs = [0x0100, 0x01E0, 0x1011, 0x0200, 0x0300, 0x1FF0]
    private static let packetSize = TSLANAudioRewriter.packetSize
    private static let mask = TSLANAudioRewriter.pts33Mask

    /// The segment with the card video muxed in, or nil when it cannot be
    /// (no PAT/PMT, the PMT already lists video, no audio PES with a PTS,
    /// or the PMT section does not fit one packet). `cc` is the video
    /// PID's continuity counter, carried across segments by the caller.
    static func inject(segment: [UInt8], accessUnit: [UInt8], fps: Int,
                       cc: inout UInt8) -> [UInt8]? {
        let n = segment.count / packetSize
        guard n > 0, !accessUnit.isEmpty, fps > 0 else { return nil }
        func packet(_ i: Int) -> [UInt8] { Array(segment[(i * packetSize)..<((i + 1) * packetSize)]) }
        func pid(_ i: Int) -> Int {
            (Int(segment[i * packetSize + 1] & 0x1F) << 8) | Int(segment[i * packetSize + 2])
        }
        // Program layout from the segment's own PAT / PMT.
        var pmtPID = -1
        var usedPIDs = Set<Int>([0, 0x1FFF])
        for i in 0..<n {
            guard segment[i * packetSize] == 0x47 else { return nil }
            usedPIDs.insert(pid(i))
            if pmtPID < 0, pid(i) == 0, segment[i * packetSize + 1] & 0x40 != 0 {
                pmtPID = TSLANAudioRewriter.firstPMTPID(packet(i)) ?? -1
            }
        }
        guard pmtPID >= 0 else { return nil }
        var info: TSLANAudioRewriter.PMTInfo?
        for i in 0..<n where pid(i) == pmtPID {
            if let pi = TSLANAudioRewriter.parsePMT(packet(i)) { info = pi; break }
        }
        guard let info, info.videoPID < 0, let audioPID = info.audio.first?.pid else { return nil }
        for a in info.audio { usedPIDs.insert(a.pid) }
        guard let videoPID = candidatePIDs.first(where: { !usedPIDs.contains($0) }) else { return nil }
        // First audio PTS: the first card picture is stamped with it.
        var firstPTS: Int64?
        for i in 0..<n where pid(i) == audioPID && segment[i * packetSize + 1] & 0x40 != 0 {
            if let p = TSLANAudioRewriter.pesPTS(packet(i)) { firstPTS = p; break }
        }
        guard let firstPTS else { return nil }

        let interval = Int64(90_000 / fps)
        var out = [UInt8]()
        out.reserveCapacity(segment.count + (accessUnit.count + 400) * (fps * 4))
        var lastVideoPTS: Int64 = -1
        var lastPCR: Int64 = -1
        func delta(_ a: Int64, _ b: Int64) -> Int64 { (a - b) & mask }
        func emitFrame(pts: Int64) {
            let pcr = (pts - pcrLeadTicks) & mask
            out += packetizeVideo(accessUnit: accessUnit, pts: pts, pcr: pcr, pid: videoPID, cc: &cc)
            lastVideoPTS = pts
            lastPCR = pcr
        }
        for i in 0..<n {
            var p = packet(i)
            let id = pid(i)
            if id == pmtPID {
                if p[1] & 0x40 != 0 {
                    guard let rewritten = addVideoToPMT(p, videoPID: videoPID) else { return nil }
                    p = rewritten
                }
                out += p
                continue
            }
            if id == 0 || id == 0x1FFF { out += p; continue }
            if lastVideoPTS < 0 { emitFrame(pts: firstPTS) }
            if id == audioPID, p[1] & 0x40 != 0, let apts = TSLANAudioRewriter.pesPTS(p) {
                let sinceVideo = delta(apts, lastVideoPTS)
                if sinceVideo >= interval, sinceVideo < (1 << 32) {
                    emitFrame(pts: apts)
                } else {
                    let pcr = (apts - pcrLeadTicks) & mask
                    let sincePCR = delta(pcr, lastPCR)
                    if sincePCR >= pcrIntervalTicks, sincePCR < (1 << 32) {
                        out += pcrPacket(pid: videoPID, pcr: pcr, cc: cc)
                        lastPCR = pcr
                    }
                }
            }
            out += p
        }
        if lastVideoPTS < 0 { return nil }
        return out
    }

    /// The PMT packet with an H.264 entry for `videoPID` first in the ES
    /// loop and PCR_PID moved to it. Nil when malformed or too long.
    static func addVideoToPMT(_ p: [UInt8], videoPID: Int) -> [UInt8]? {
        guard let base = TSLANAudioRewriter.payloadOffset(p) else { return nil }
        let s = base + 1 + Int(p[base])
        guard s + 12 < packetSize, p[s] == 0x02 else { return nil }
        let sectionLength = (Int(p[s + 1] & 0x0F) << 8) | Int(p[s + 2])
        let end = s + 3 + sectionLength - 4             // start of the CRC
        guard end <= packetSize - 4, end > s + 12 else { return nil }
        let pil = (Int(p[s + 10] & 0x0F) << 8) | Int(p[s + 11])
        let esStart = s + 12 + pil
        guard esStart <= end else { return nil }
        var section = Array(p[s..<esStart])
        section[8] = (section[8] & 0xE0) | UInt8((videoPID >> 8) & 0x1F)
        section[9] = UInt8(videoPID & 0xFF)
        section += [videoStreamType, 0xE0 | UInt8((videoPID >> 8) & 0x1F), UInt8(videoPID & 0xFF), 0xF0, 0x00]
        section += p[esStart..<end]
        let newLength = section.count - 3 + 4
        section[1] = (section[1] & 0xF0) | UInt8((newLength >> 8) & 0x0F)
        section[2] = UInt8(newLength & 0xFF)
        let crc = TSLANAudioRewriter.crc32MPEG(section)
        section += [UInt8(crc >> 24), UInt8((crc >> 16) & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8(crc & 0xFF)]
        var out = Array(p[0..<s]) + section
        guard out.count <= packetSize else { return nil }
        out += [UInt8](repeating: 0xFF, count: packetSize - out.count)
        return out
    }

    static func encodePCR(_ base: Int64) -> [UInt8] {
        let b = base & mask
        return [UInt8((b >> 25) & 0xFF), UInt8((b >> 17) & 0xFF), UInt8((b >> 9) & 0xFF),
                UInt8((b >> 1) & 0xFF), UInt8(((b & 1) << 7) | 0x7E), 0x00]
    }

    static func decodePCR(_ p: [UInt8]) -> Int64? {
        guard p.count == packetSize, (p[3] >> 4) & 0x02 != 0, p[4] >= 7, p[5] & 0x10 != 0 else { return nil }
        return (Int64(p[6]) << 25) | (Int64(p[7]) << 17) | (Int64(p[8]) << 9)
            | (Int64(p[9]) << 1) | (Int64(p[10]) >> 7)
    }

    /// Adaptation-field-only packet carrying a PCR (continuity counter not
    /// advanced: no payload).
    static func pcrPacket(pid: Int, pcr: Int64, cc: UInt8) -> [UInt8] {
        var p: [UInt8] = [0x47, UInt8((pid >> 8) & 0x1F), UInt8(pid & 0xFF),
                          0x20 | ((cc &- 1) & 0x0F), 183, 0x10]
        p += encodePCR(pcr)
        p += [UInt8](repeating: 0xFF, count: packetSize - p.count)
        return p
    }

    /// One video PES (PTS only) in TS packets: the first carries the PCR and,
    /// when `randomAccess` (a key frame), the random_access_indicator; the
    /// last is padded with adaptation stuffing.
    static func packetizeVideo(accessUnit: [UInt8], pts: Int64, pcr: Int64, pid: Int,
                               cc: inout UInt8, randomAccess: Bool = true) -> [UInt8] {
        var pes: [UInt8] = [0x00, 0x00, 0x01, videoStreamID]
        let pesLength = 3 + 5 + accessUnit.count
        let lengthField = pesLength <= 0xFFFF ? pesLength : 0
        pes += [UInt8(lengthField >> 8), UInt8(lengthField & 0xFF), 0x80, 0x80, 0x05]
        pes += TSLANAudioRewriter.encodePTS(pts & mask)
        pes += accessUnit
        var out = [UInt8]()
        out.reserveCapacity((pes.count / 176 + 2) * packetSize)
        var o = 0
        var first = true
        while o < pes.count {
            var header: [UInt8] = [0x47, UInt8((first ? 0x40 : 0) | ((pid >> 8) & 0x1F)), UInt8(pid & 0xFF)]
            var af: [UInt8] = []
            if first { af = [randomAccess ? 0x50 : 0x10] + encodePCR(pcr) }    // random_access + PCR
            let room = 184 - (af.isEmpty ? 0 : 1 + af.count)
            let remaining = pes.count - o
            if remaining < room {
                // Stuff the adaptation field so the payload ends the packet.
                let stuffing = room - remaining - (af.isEmpty ? 1 : 0)
                if af.isEmpty {
                    af = stuffing > 0 ? [0x00] + [UInt8](repeating: 0xFF, count: stuffing - 1) : []
                    // An empty AF with length 0 takes one byte; handled below.
                    header.append(0x30 | (cc & 0x0F))
                    out += header
                    out.append(UInt8(af.count))
                    out += af
                } else {
                    af += [UInt8](repeating: 0xFF, count: stuffing)
                    header.append(0x30 | (cc & 0x0F))
                    out += header
                    out.append(UInt8(af.count))
                    out += af
                }
                out += pes[o...]
                o = pes.count
            } else {
                header.append((af.isEmpty ? 0x10 : 0x30) | (cc & 0x0F))
                out += header
                if !af.isEmpty { out.append(UInt8(af.count)); out += af }
                out += pes[o..<(o + room)]
                o += room
            }
            cc = (cc + 1) & 0x0F
            first = false
        }
        return out
    }
}

/// Thread-safe front of `TSCardVideoMuxer` for the LAN server: caches each
/// segment's card copy and carries the video continuity counter from one
/// segment to the next when they are produced in order.
final class TSLANCardStage: @unchecked Sendable {
    let accessUnit: [UInt8]
    let fps: Int
    private let lock = NSLock()
    private var cache: [Int: Data] = [:]
    private var ccAfter: [Int: UInt8] = [:]

    init(accessUnit: [UInt8], fps: Int) {
        self.accessUnit = accessUnit
        self.fps = fps
    }

    /// The card copy of `segment` (seq `seq`), or nil when it cannot carry
    /// the card (the caller serves the segment as it is).
    func produce(seq: Int, segment: Data, oldestSeq: Int) -> Data? {
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[seq] { return hit }
        var cc = ccAfter[seq - 1] ?? 0
        guard let out = TSCardVideoMuxer.inject(segment: [UInt8](segment), accessUnit: accessUnit,
                                                fps: fps, cc: &cc) else { return nil }
        let data = Data(out)
        cache[seq] = data
        ccAfter[seq] = cc
        for k in cache.keys where k < oldestSeq { cache[k] = nil; ccAfter[k] = nil }
        return data
    }
}

/// One still picture to one H.264 IDR access unit in Annex B form (AUD,
/// SPS, PPS, IDR slices) with VideoToolbox, the platform encoder. Used once
/// per card (channel), not per segment: the same bytes are re-stamped.
enum TSCardFrameEncoder {
    static let width = 1280
    static let height = 720

    /// Nil on any encoder failure (the caller keeps the audio-only TS).
    static func encodeIDR(_ image: CGImage) -> [UInt8]? {
        guard let pixels = pixelBuffer(image) else { return nil }
        var sessionOut: VTCompressionSession?
        let created = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &sessionOut)
        guard created == noErr, let session = sessionOut else { return nil }
        defer { VTCompressionSessionInvalidate(session) }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_H264_Main_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: 1))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: 1_500_000))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: 1))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ColorPrimaries, value: kCVImageBufferColorPrimaries_ITU_R_709_2)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_TransferFunction, value: kCVImageBufferTransferFunction_ITU_R_709_2)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_YCbCrMatrix, value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        guard VTCompressionSessionPrepareToEncodeFrames(session) == noErr else { return nil }
        final class Box: @unchecked Sendable { var au: [UInt8]? }
        let box = Box()
        let props = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixels, presentationTimeStamp: CMTime(value: 0, timescale: 90_000),
            duration: CMTime(value: 90_000, timescale: 90_000), frameProperties: props,
            infoFlagsOut: nil) { st, _, sample in
                guard st == noErr, let sample else { return }
                box.au = annexB(sample)
            }
        guard status == noErr else { return nil }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        return box.au
    }

    private static func pixelBuffer(_ image: CGImage) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                                      kCVPixelBufferCGImageCompatibilityKey: true,
                                      kCVPixelBufferCGBitmapContextCompatibilityKey: true]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary, &pb) == kCVReturnSuccess, let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pb
    }

    /// AVCC sample (4-byte lengths) plus the format's SPS / PPS to Annex B,
    /// led by an access unit delimiter.
    private static func annexB(_ sample: CMSampleBuffer) -> [UInt8]? {
        guard let format = CMSampleBufferGetFormatDescription(sample),
              let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let start: [UInt8] = [0, 0, 0, 1]
        var out: [UInt8] = start + [0x09, 0x10]
        var count = 0
        var headerLength: Int32 = 4
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                           parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                           nalUnitHeaderLengthOut: &headerLength)
        guard count >= 2, headerLength == 4 else { return nil }
        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let ptr else { return nil }
            out += start
            out += UnsafeBufferPointer(start: ptr, count: size)
        }
        let length = CMBlockBufferGetDataLength(block)
        var data = [UInt8](repeating: 0, count: length)
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &data) == noErr else { return nil }
        var o = 0
        var sawIDR = false
        while o + 4 <= length {
            let n = Int(data[o]) << 24 | Int(data[o + 1]) << 16 | Int(data[o + 2]) << 8 | Int(data[o + 3])
            o += 4
            guard n > 0, o + n <= length else { return nil }
            let type = data[o] & 0x1F
            if type == 5 { sawIDR = true }
            if type != 9 { out += start; out += data[o..<(o + n)] }   // AUD already leads
            o += n
        }
        return sawIDR ? out : nil
    }
}
