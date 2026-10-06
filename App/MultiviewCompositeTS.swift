//
//  MultiviewCompositeTS.swift
//  Aerio
//
//  Phone-side Multiview composite (Logan 2026-10-06, part 2): the pure
//  pieces. A receiver that cannot run Multiview itself (the Chromecast web
//  receiver, any AirPlay receiver) gets ONE live MPEG-TS that the phone
//  builds: the grid composed on the GPU and encoded with VideoToolbox, plus
//  the focused tile's audio as AAC-LC stereo 48 kHz. That TS is served on
//  loopback and ingested by the existing pipelines exactly like a channel
//  (CastHLSProxySession for Cast, TSHLSRemuxer's LAN path for AirPlay).
//
//  Everything here is pure (no AVFoundation, no app singletons) so
//  Scripts/cast-hls-proxy-tests compiles and tests it: the grid layout at
//  1280x720, the key-frame policy, the TS muxer for a live H.264 stream
//  with real PTS, the tile-tap TS demuxer and the audio clock mapping.
//

import Foundation
import CoreGraphics

// MARK: - Layout

/// Where each tile sits in the 1280x720 composite. Same rect tables the
/// local Multiview uses (`MultiviewGridMath`), with a small black gutter so
/// the thin tile borders read, and each video letterboxed inside its tile.
enum MultiviewCompositeLayout {
    static let width = 1280
    static let height = 720
    static let fps = 30
    /// The phone composes at most this many tiles (CPU/thermal cap).
    static let maxTiles = 4
    /// Black gutter between tiles, in composite pixels.
    static let spacing: CGFloat = 4
    /// Thin border on every tile, and the focused tile's highlight.
    /// Android parity: 2 px gray on every tile, 4 px white on the focused one.
    static let borderWidth: CGFloat = 2
    static let focusBorderWidth: CGFloat = 4

    /// Tile rects in tile order for `count` tiles (2 to 4), in the
    /// composite's top-left-origin pixel space, snapped to whole pixels.
    static func tileRects(count: Int, mode: MultiviewLayoutMode = .auto) -> [CGRect] {
        let n = max(0, min(count, maxTiles))
        let container = CGSize(width: width, height: height)
        return MultiviewGridMath.rects(for: mode, count: n, in: container, spacing: spacing)
            .map { $0.integral.intersection(CGRect(origin: .zero, size: container)) }
    }

    /// The video's aspect-fit rect inside `tile` (letterbox or pillarbox),
    /// centered, whole pixels. `aspect` is width / height; anything not
    /// positive is treated as 16:9.
    static func videoRect(in tile: CGRect, aspect: CGFloat) -> CGRect {
        let a = aspect > 0 && aspect.isFinite ? aspect : 16.0 / 9.0
        var w = tile.width
        var h = w / a
        if h > tile.height {
            h = tile.height
            w = h * a
        }
        let x = tile.minX + (tile.width - w) / 2
        let y = tile.minY + (tile.height - h) / 2
        return CGRect(x: x.rounded(), y: y.rounded(), width: w.rounded(), height: h.rounded())
    }

    /// The four border strips of `rect`, `width` thick, drawn inside it.
    static func borderStrips(_ rect: CGRect, width: CGFloat) -> [CGRect] {
        guard rect.width > 2 * width, rect.height > 2 * width else { return [rect] }
        return [
            CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: width),
            CGRect(x: rect.minX, y: rect.maxY - width, width: rect.width, height: width),
            CGRect(x: rect.minX, y: rect.minY + width, width: width, height: rect.height - 2 * width),
            CGRect(x: rect.maxX - width, y: rect.minY + width, width: width, height: rect.height - 2 * width),
        ]
    }

    /// Top-left-origin rect to the bottom-left-origin space CoreImage uses.
    static func flipped(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: CGFloat(height) - r.maxY, width: r.width, height: r.height)
    }
}

// MARK: - Key frames

/// Forced IDR policy: the first frame, the first frame at or after 2 s
/// since the last IDR, and (Android parity, 2026-10-06) the first frame at
/// or after every 3 s boundary of the stream. The downstream segmenters
/// (the Cast remuxer and TSHLSRemuxer) cut at the first key frame at or
/// after their 3 s target; with only the 2 s cadence they cut at 4 s, the
/// 3 s IDRs make them cut at 3 s.
struct MultiviewKeyframePolicy {
    static let intervalTicks: Int64 = 2 * 90_000
    static let segmentTicks: Int64 = 3 * 90_000
    private(set) var lastKeyPTS: Int64 = -1
    private var firstPTS: Int64 = -1
    private var lastPTS: Int64 = -1

    mutating func isKeyframe(pts: Int64) -> Bool {
        defer { lastPTS = pts }
        if firstPTS < 0 || pts < lastPTS {
            firstPTS = pts
            lastKeyPTS = pts
            return true
        }
        let crossedSegment = (pts - firstPTS) / Self.segmentTicks > (lastPTS - firstPTS) / Self.segmentTicks
        if crossedSegment || pts - lastKeyPTS >= Self.intervalTicks {
            lastKeyPTS = pts
            return true
        }
        return false
    }
}

// MARK: - TS muxer (live H.264 + AAC)

/// MPEG-TS for the composite: PAT, PMT (H.264 on 0x100 carrying the PCR,
/// ADTS AAC on 0x101), video PES per access unit with its real PTS, audio
/// PES per ADTS frame. PAT/PMT go out before every key frame so a reader
/// that joins at a key frame has the program at once.
struct MultiviewCompositeTSMuxer {
    static let pmtPID = 0x1000
    static let videoPID = 0x0100
    static let audioPID = 0x0101
    static let audioStreamType: UInt8 = 0x0F
    private static let packetSize = TSLANAudioRewriter.packetSize

    private var patCC: UInt8 = 0
    private var pmtCC: UInt8 = 0
    private var videoCC: UInt8 = 0
    private var audioCC: UInt8 = 0
    /// PCR lead behind the video PTS it is stamped against.
    static let pcrLeadTicks: Int64 = 9_000

    /// PAT + PMT, two packets.
    mutating func programTables() -> [UInt8] {
        var out = Self.psiPacket(pid: 0, section: Self.patSection(), cc: patCC)
        patCC = (patCC + 1) & 0x0F
        out += Self.psiPacket(pid: Self.pmtPID, section: Self.pmtSection(), cc: pmtCC)
        pmtCC = (pmtCC + 1) & 0x0F
        return out
    }

    /// One Annex B access unit. Key frames are led by PAT/PMT and carry the
    /// random access indicator; every video PES carries a PCR.
    mutating func video(accessUnit: [UInt8], pts: Int64, keyframe: Bool) -> [UInt8] {
        var out = keyframe ? programTables() : []
        let mask = TSLANAudioRewriter.pts33Mask
        out += TSCardVideoMuxer.packetizeVideo(accessUnit: accessUnit, pts: pts & mask,
                                               pcr: (pts - Self.pcrLeadTicks) & mask,
                                               pid: Self.videoPID, cc: &videoCC,
                                               randomAccess: keyframe)
        return out
    }

    /// One ADTS AAC frame (header included).
    mutating func audio(adtsFrame: [UInt8], pts: Int64) -> [UInt8] {
        TSLANAudioRewriter.packetizePES(payload: adtsFrame, pts: pts & TSLANAudioRewriter.pts33Mask,
                                        pid: Self.audioPID, cc: &audioCC)
    }

    static func patSection() -> [UInt8] {
        var s: [UInt8] = [0x00, 0xB0, 0x00, 0x00, 0x01, 0xC1, 0x00, 0x00,
                          0x00, 0x01, 0xE0 | UInt8((pmtPID >> 8) & 0x1F), UInt8(pmtPID & 0xFF)]
        return sealed(&s)
    }

    static func pmtSection() -> [UInt8] {
        var s: [UInt8] = [0x02, 0xB0, 0x00, 0x00, 0x01, 0xC1, 0x00, 0x00,
                          0xE0 | UInt8((videoPID >> 8) & 0x1F), UInt8(videoPID & 0xFF),
                          0xF0, 0x00,
                          TSCardVideoMuxer.videoStreamType, 0xE0 | UInt8((videoPID >> 8) & 0x1F),
                          UInt8(videoPID & 0xFF), 0xF0, 0x00,
                          audioStreamType, 0xE0 | UInt8((audioPID >> 8) & 0x1F),
                          UInt8(audioPID & 0xFF), 0xF0, 0x00]
        return sealed(&s)
    }

    /// Fill section_length and append the CRC.
    private static func sealed(_ s: inout [UInt8]) -> [UInt8] {
        let length = s.count - 3 + 4
        s[1] = (s[1] & 0xF0) | UInt8((length >> 8) & 0x0F)
        s[2] = UInt8(length & 0xFF)
        let crc = TSLANAudioRewriter.crc32MPEG(s)
        return s + [UInt8(crc >> 24), UInt8((crc >> 16) & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8(crc & 0xFF)]
    }

    private static func psiPacket(pid: Int, section: [UInt8], cc: UInt8) -> [UInt8] {
        var p: [UInt8] = [0x47, 0x40 | UInt8((pid >> 8) & 0x1F), UInt8(pid & 0xFF), 0x10 | (cc & 0x0F), 0x00]
        p += section
        p += [UInt8](repeating: 0xFF, count: packetSize - p.count)
        return p
    }
}

// MARK: - Tile tap demuxer

/// One audio PES from a tile's ingest.
struct MultiviewTapAudioPES {
    var streamType: UInt8
    var pts: Int64
    var payload: [UInt8]
}

/// Minimal TS demuxer over a tile's raw ingest bytes (any chunking): finds
/// the PMT's first audio stream and hands back its PES payloads with their
/// 33-bit PTS. Video and everything else are skipped.
struct MultiviewTapDemuxer {
    private static let packetSize = TSLANAudioRewriter.packetSize
    private var carry: [UInt8] = []
    private var pmtPID = -1
    private(set) var audioPID = -1
    private(set) var audioStreamType: UInt8 = 0
    private var pes: [UInt8] = []

    mutating func reset() {
        carry.removeAll()
        pmtPID = -1
        audioPID = -1
        audioStreamType = 0
        pes.removeAll()
    }

    mutating func feed(_ data: [UInt8]) -> [MultiviewTapAudioPES] {
        carry += data
        var out: [MultiviewTapAudioPES] = []
        var i = 0
        // Resync on the sync byte if the chunking ever leaves us off it.
        while i + Self.packetSize <= carry.count {
            if carry[i] != 0x47 { i += 1; continue }
            let p = Array(carry[i..<(i + Self.packetSize)])
            i += Self.packetSize
            handle(p, into: &out)
        }
        carry.removeFirst(i)
        return out
    }

    private mutating func handle(_ p: [UInt8], into out: inout [MultiviewTapAudioPES]) {
        let pid = (Int(p[1] & 0x1F) << 8) | Int(p[2])
        let pusi = p[1] & 0x40 != 0
        if pid == 0, pusi {
            if let pmt = TSLANAudioRewriter.firstPMTPID(p) { pmtPID = pmt }
            return
        }
        if pid == pmtPID, pusi, let info = TSLANAudioRewriter.parsePMT(p) {
            if let a = info.audio.first, a.pid != audioPID || a.type != audioStreamType {
                flush(into: &out)
                audioPID = a.pid
                audioStreamType = a.type
            }
            return
        }
        guard pid == audioPID, let payload = TSLANAudioRewriter.payload(p) else { return }
        if pusi { flush(into: &out) }
        if pusi || !pes.isEmpty { pes += payload }
    }

    /// Emit the PES gathered so far, if it parses.
    private mutating func flush(into out: inout [MultiviewTapAudioPES]) {
        defer { pes.removeAll(keepingCapacity: true) }
        guard pes.count >= 14, pes[0] == 0, pes[1] == 0, pes[2] == 1, pes[7] & 0x80 != 0 else { return }
        let headerLength = Int(pes[8])
        let start = 9 + headerLength
        guard start <= pes.count else { return }
        out.append(MultiviewTapAudioPES(streamType: audioStreamType,
                                        pts: TSLANAudioRewriter.decodePTS(pes, 9),
                                        payload: Array(pes[start...])))
    }
}

// MARK: - Audio clock

/// Maps the focused tile's source audio PTS onto the composite clock.
///
/// The composite clock is the phone's host clock in 90 kHz ticks. The tile
/// shows (on the phone) the source frame at `displayedSourcePTS`; that
/// frame is what the composite carries now, so its audio must sound now:
/// offset = compositeNow - displayedSourcePTS. The offset is fixed at the
/// anchor and kept until the source jumps (a discontinuity or a new focus
/// tile), so the audio stays continuous. Frames that map at or below what
/// was already emitted (`floor`) are dropped.
struct MultiviewAudioClock {
    /// A source jump larger than this re-anchors.
    static let jumpTicks: Int64 = 5 * 90_000
    private(set) var offset: Int64?
    private var lastSourcePTS: Int64 = -1

    mutating func reanchor() {
        offset = nil
        lastSourcePTS = -1
    }

    /// The composite PTS for `sourcePTS` (33-bit), or nil when it falls at
    /// or below `floor` (already covered). `displayedSourcePTS` and
    /// `compositeNow` are only read when (re)anchoring.
    mutating func map(sourcePTS raw: Int64, compositeNow: Int64,
                      displayedSourcePTS: () -> Int64, floor: Int64) -> Int64? {
        let src = unwrap(raw)
        if offset == nil || (lastSourcePTS >= 0 && abs(src - lastSourcePTS) > Self.jumpTicks) {
            // Frames that land inside audio already sent are dropped below;
            // the muxer fills any gap with silence.
            offset = compositeNow - unwrap(displayedSourcePTS(), near: src)
        }
        lastSourcePTS = src
        let mapped = src + (offset ?? 0)
        return mapped > floor ? mapped : nil
    }

    /// 33-bit PTS unwrapped against the last one seen.
    private func unwrap(_ raw: Int64) -> Int64 {
        unwrap(raw, near: lastSourcePTS)
    }

    private func unwrap(_ raw: Int64, near ref: Int64) -> Int64 {
        let period = TSLANAudioRewriter.pts33Mask + 1
        guard ref >= 0 else { return raw }
        var v = (ref & ~TSLANAudioRewriter.pts33Mask) + (raw & TSLANAudioRewriter.pts33Mask)
        if v - ref > period / 2 { v -= period }
        if ref - v > period / 2 { v += period }
        return v
    }
}

// MARK: - ADTS

enum MultiviewADTS {
    struct Header: Equatable {
        var headerLength: Int
        var frameLength: Int
        var sampleRate: Int
        var channels: Int
        var objectType: Int
        var frequencyIndex: Int
    }

    static let sampleRates = [96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000, 22_050,
                              16_000, 12_000, 11_025, 8_000, 7_350]

    static func parse(_ b: [UInt8], _ o: Int) -> Header? {
        guard o + 7 <= b.count, b[o] == 0xFF, b[o + 1] & 0xF0 == 0xF0 else { return nil }
        let protectionAbsent = b[o + 1] & 0x01 != 0
        let objectType = Int((b[o + 2] >> 6) & 0x03) + 1
        let freq = Int((b[o + 2] >> 2) & 0x0F)
        let channels = Int((b[o + 2] & 0x01) << 2) | Int((b[o + 3] >> 6) & 0x03)
        let length = (Int(b[o + 3] & 0x03) << 11) | (Int(b[o + 4]) << 3) | Int((b[o + 5] >> 5) & 0x07)
        let headerLength = protectionAbsent ? 7 : 9
        guard freq < sampleRates.count, length > headerLength else { return nil }
        return Header(headerLength: headerLength, frameLength: length, sampleRate: sampleRates[freq],
                      channels: channels, objectType: objectType, frequencyIndex: freq)
    }

    /// AudioSpecificConfig (2 bytes) for an ADTS header.
    static func audioSpecificConfig(_ h: Header) -> [UInt8] {
        [UInt8((h.objectType << 3) | (h.frequencyIndex >> 1)),
         UInt8(((h.frequencyIndex & 1) << 7) | (max(0, min(h.channels, 7)) << 3))]
    }
}
