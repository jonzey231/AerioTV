//
//  MKVFMP4Remuxer.swift
//  Aerio
//
//  Matroska to fragmented-MP4 VOD engine: serves an MKV file to AVPlayer
//  as a fully seekable HLS VOD presentation, remuxing on demand.
//
//  Why: 84% of the measured VOD library is MKV (2026-08-25 ffprobe sample
//  of 58 titles), a container AVFoundation cannot open at all, which is
//  the single gate on removing mpv from the app. Video inside is 100%
//  H.264/HEVC and audio is ~86% AC-3/E-AC-3/AAC - all pure passthrough.
//
//  Design (enabled by Dispatcharr's VOD proxy honouring HTTP Range with
//  a total length, verified 2026-08-25):
//   1. Range-fetch the head: EBML + SeekHead + Info + Tracks. Matroska
//      hands us the decoder configs verbatim (CodecPrivate IS the
//      avcC/hvcC box payload), so no bitstream parsing at all.
//   2. SeekHead -> Cues (usually near the tail): CuePoint list mapping
//      presentation time to Cluster byte offsets, at video keyframes.
//   3. Publish a VOD playlist (#EXT-X-PLAYLIST-TYPE:VOD + ENDLIST) with
//      one segment per cue span. AVPlayer sees the whole timeline up
//      front: instant tune, TRUE random-access seeking.
//   4. A segment request range-fetches exactly its cue span's bytes,
//      parses the clusters, and emits one moof/mdat. ~5-15 MB per
//      request, nothing sequential, nothing buffered beyond AVPlayer's
//      own look-ahead.
//
//  Timestamps: Matroska block timestamps are PRESENTATION times and the
//  blocks are stored in DECODE order. For B-frame H.264/HEVC we assign
//  dts = segment-start + index * median-frame-duration (movies are
//  constant-rate) and carry pts-dts in the trun's signed cts offsets.
//
//  Audio track choice: the FIRST track whose codec the system decodes
//  (AC-3/E-AC-3/AAC), not the first track - a "TrueHD + E-AC-3 + DTS"
//  release plays via its E-AC-3 track instead of refusing.
//
//  Refusals (owner falls back to mpv): no Cues, encrypted/laced-video
//  oddities, video other than AVC/HEVC, no supported audio track when
//  audio exists (DTS/TrueHD-only, FLAC until the ALAC transcode lands).
//
//  Third sibling of CastFMP4Remuxer/LiveFMP4Remuxer; the shared ISO-BMFF
//  plumbing is duplicated a third time, deliberately - extracting it now
//  would churn a soak-tested cast path and a device-verified live path
//  in the same commit as a brand-new engine. Extract once this ships.
//
//  Threading: everything runs on the owner's serial queue. The range
//  fetcher blocks that queue (semaphore) - correct here, because every
//  caller is itself a per-request server handler.
//

import Foundation
import Network

struct MKVRemuxError: Error, CustomStringConvertible {
    let reason: String
    var description: String { reason }
}

// MARK: - Range fetcher

/// Synchronous HTTP Range reader over the VOD proxy. URLSession follows
/// the per-session 301 redirect transparently; `totalLength` comes from
/// the first response's Content-Range.
final class MKVRangeFetcher: @unchecked Sendable {
    private let url: URL
    private let headers: [String: String]
    private let session: URLSession
    private(set) var totalLength: Int64 = 0
    /// Bytes fetched over the fetcher's life, for the [MKV] summary line.
    private(set) var bytesFetched: Int64 = 0

    init(url: URL, headers: [String: String]) {
        self.url = url
        self.headers = headers
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
    }

    func fetch(offset: Int64, length: Int) throws -> Data {
        var request = URLRequest(url: url)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.setValue("bytes=\(offset)-\(offset + Int64(length) - 1)", forHTTPHeaderField: "Range")
        var result: Data?
        var error: Error?
        let sem = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { [weak self] data, response, err in
            defer { sem.signal() }
            if let err { error = err; return }
            guard let http = response as? HTTPURLResponse, http.statusCode == 206 || http.statusCode == 200 else {
                error = MKVRemuxError(reason: "range fetch HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return
            }
            if let self, self.totalLength == 0,
               let range = http.value(forHTTPHeaderField: "Content-Range"),
               let total = range.split(separator: "/").last.flatMap({ Int64($0) }) {
                self.totalLength = total
            }
            result = data
        }
        task.resume()
        if sem.wait(timeout: .now() + 45) == .timedOut {
            task.cancel()
            throw MKVRemuxError(reason: "range fetch timed out")
        }
        if let error { throw error }
        guard let result else { throw MKVRemuxError(reason: "range fetch empty") }
        bytesFetched += Int64(result.count)
        return result
    }

    func invalidate() { session.invalidateAndCancel() }
}

// MARK: - EBML reader

/// Minimal EBML walker over an in-memory buffer. IDs keep their marker
/// bit (matching the spec's element-ID notation); sizes strip it.
struct EBMLReader {
    let data: [UInt8]
    var pos: Int

    init(_ data: [UInt8], at: Int = 0) { self.data = data; pos = at }

    var remaining: Int { data.count - pos }

    mutating func readID() throws -> UInt32 {
        guard pos < data.count else { throw MKVRemuxError(reason: "EBML: id past end") }
        let first = data[pos]
        let len = Self.vintLength(first)
        guard len >= 1, len <= 4, pos + len <= data.count else {
            throw MKVRemuxError(reason: "EBML: bad id length")
        }
        var v: UInt32 = 0
        for i in 0..<len { v = (v << 8) | UInt32(data[pos + i]) }
        pos += len
        return v
    }

    mutating func readSize() throws -> Int64 {
        guard pos < data.count else { throw MKVRemuxError(reason: "EBML: size past end") }
        let first = data[pos]
        let len = Self.vintLength(first)
        guard len >= 1, len <= 8, pos + len <= data.count else {
            throw MKVRemuxError(reason: "EBML: bad size length")
        }
        var v = Int64(first & (0xFF >> len))
        for i in 1..<len { v = (v << 8) | Int64(data[pos + i]) }
        pos += len
        // All-ones payload means "unknown size" (streamed clusters).
        let unknown = (Int64(1) << (7 * len)) - 1
        if v == unknown { v = -1 }
        return v
    }

    mutating func readUInt(_ size: Int) throws -> UInt64 {
        guard size <= 8, pos + size <= data.count else { throw MKVRemuxError(reason: "EBML: uint past end") }
        var v: UInt64 = 0
        for i in 0..<size { v = (v << 8) | UInt64(data[pos + i]) }
        pos += size
        return v
    }

    mutating func readFloat(_ size: Int) throws -> Double {
        let raw = try readUInt(size)
        if size == 4 { return Double(Float(bitPattern: UInt32(truncatingIfNeeded: raw))) }
        if size == 8 { return Double(bitPattern: raw) }
        throw MKVRemuxError(reason: "EBML: bad float size")
    }

    mutating func readBytes(_ size: Int) throws -> [UInt8] {
        guard pos + size <= data.count else { throw MKVRemuxError(reason: "EBML: bytes past end") }
        defer { pos += size }
        return Array(data[pos..<(pos + size)])
    }

    mutating func skip(_ size: Int64) {
        pos += Int(size)
    }

    static func vintLength(_ first: UInt8) -> Int {
        var mask: UInt8 = 0x80
        for i in 1...8 {
            if first & mask != 0 { return i }
            mask >>= 1
        }
        return 0
    }
}

// MARK: - Remuxer

final class MKVFMP4Remuxer: @unchecked Sendable {

    static let ticksPerSecond: Int64 = 90_000
    private static let videoTrackID = 1
    private static let audioTrackID = 2

    // Matroska element IDs used here.
    private enum ID {
        static let segment: UInt32 = 0x18538067
        static let seekHead: UInt32 = 0x114D9B74
        static let seek: UInt32 = 0x4DBB
        static let seekID: UInt32 = 0x53AB
        static let seekPosition: UInt32 = 0x53AC
        static let info: UInt32 = 0x1549A966
        static let timestampScale: UInt32 = 0x2AD7B1
        static let duration: UInt32 = 0x4489
        static let tracks: UInt32 = 0x1654AE6B
        static let trackEntry: UInt32 = 0xAE
        static let trackNumber: UInt32 = 0xD7
        static let trackType: UInt32 = 0x83
        static let codecID: UInt32 = 0x86
        static let codecPrivate: UInt32 = 0x63A2
        static let defaultDuration: UInt32 = 0x23E383
        static let videoBox: UInt32 = 0xE0
        static let pixelWidth: UInt32 = 0xB0
        static let pixelHeight: UInt32 = 0xBA
        static let audioBox: UInt32 = 0xE1
        static let samplingFrequency: UInt32 = 0xB5
        static let channels: UInt32 = 0x9F
        static let contentEncodings: UInt32 = 0x6D80
        static let cues: UInt32 = 0x1C53BB6B
        static let cuePoint: UInt32 = 0xBB
        static let cueTime: UInt32 = 0xB3
        static let cueTrackPositions: UInt32 = 0xB7
        static let cueTrack: UInt32 = 0xF7
        static let cueClusterPosition: UInt32 = 0xF1
        static let cluster: UInt32 = 0x1F43B675
        static let clusterTimestamp: UInt32 = 0xE7
        static let simpleBlock: UInt32 = 0xA3
        static let blockGroup: UInt32 = 0xA0
        static let block: UInt32 = 0xA1
    }

    struct TrackInfo {
        var number: Int
        var codecID: String
        var codecPrivate: [UInt8]
        var width = 0
        var height = 0
        var sampleRate = 48000
        var channels = 2
        var defaultDurationNs: Int64 = 0
    }

    struct CuePointInfo {
        let timeTicks: Int64      // 90 kHz
        let clusterOffset: Int64  // absolute file offset
    }

    struct SegmentInfo {
        let index: Int
        let startTicks: Int64
        let durationTicks: Int64
        let byteStart: Int64
        let byteEnd: Int64        // exclusive
    }

    private let fetcher: MKVRangeFetcher
    private let log: (String) -> Void

    private var timestampScaleNs: Int64 = 1_000_000 // default 1 ms
    private var durationTicks: Int64 = 0
    private var segmentDataStart: Int64 = 0
    private(set) var video: TrackInfo?
    private(set) var audio: TrackInfo?
    private(set) var segmentsMap: [SegmentInfo] = []
    /// Median video frame duration in ticks, for the dts ladder.
    private var frameDurationTicks: Int64 = 1_800

    init(url: URL, headers: [String: String], log: @escaping (String) -> Void) {
        fetcher = MKVRangeFetcher(url: url, headers: headers)
        self.log = log
    }

    func teardown() { fetcher.invalidate() }

    // MARK: Header + cues parse

    /// Fetch and parse everything needed to publish the playlist. Throws
    /// MKVRemuxError with a user-meaningful reason on any unsupported
    /// shape; the owner surfaces it and falls back to mpv.
    func prepare() throws {
        // 2 MB covers EBML + SeekHead + Info + Tracks on every release
        // style seen; Cues position comes from SeekHead so the tail is
        // fetched precisely.
        let head = try fetcher.fetch(offset: 0, length: 2 * 1024 * 1024)
        var r = EBMLReader([UInt8](head))

        // EBML header
        let ebmlID = try r.readID()
        guard ebmlID == 0x1A45DFA3 else { throw MKVRemuxError(reason: "not an EBML/Matroska file") }
        let ebmlSize = try r.readSize()
        r.skip(ebmlSize)

        // Segment
        let segID = try r.readID()
        guard segID == ID.segment else { throw MKVRemuxError(reason: "no Segment element") }
        _ = try r.readSize() // often unknown-size; children run to EOF
        segmentDataStart = Int64(r.pos)

        var cuesOffset: Int64 = -1
        var cuesParsed = false

        // Walk top-level children within the head buffer.
        while r.remaining > 4 {
            let id = try r.readID()
            let size = try r.readSize()
            guard size >= 0 else { break } // unknown-size cluster: header zone over
            switch id {
            case ID.seekHead:
                var sh = EBMLReader(try r.readBytes(Int(size)))
                while sh.remaining > 2 {
                    let sid = try sh.readID()
                    let ssize = try sh.readSize()
                    guard sid == ID.seek else { sh.skip(ssize); continue }
                    var seek = EBMLReader(try sh.readBytes(Int(ssize)))
                    var targetID: UInt64 = 0
                    var position: Int64 = -1
                    while seek.remaining > 2 {
                        let fid = try seek.readID()
                        let fsize = try seek.readSize()
                        switch fid {
                        case ID.seekID: targetID = try seek.readUInt(Int(fsize))
                        case ID.seekPosition: position = Int64(try seek.readUInt(Int(fsize)))
                        default: seek.skip(fsize)
                        }
                    }
                    if targetID == UInt64(ID.cues), position >= 0 {
                        cuesOffset = segmentDataStart + position
                    }
                }
            case ID.info:
                var info = EBMLReader(try r.readBytes(Int(size)))
                var durationRaw = 0.0
                while info.remaining > 2 {
                    let iid = try info.readID()
                    let isize = try info.readSize()
                    switch iid {
                    case ID.timestampScale: timestampScaleNs = Int64(try info.readUInt(Int(isize)))
                    case ID.duration: durationRaw = try info.readFloat(Int(isize))
                    default: info.skip(isize)
                    }
                }
                durationTicks = ticks(fromScaled: Int64(durationRaw))
            case ID.tracks:
                try parseTracks(EBMLReader(try r.readBytes(Int(size))))
            case ID.cues:
                try parseCues(EBMLReader(try r.readBytes(Int(size))))
                cuesParsed = true
            case ID.cluster:
                // Media zone reached; header elements are behind us.
                r.pos = r.data.count
            default:
                r.skip(size)
            }
        }

        guard let v = video else { throw MKVRemuxError(reason: "no supported video track") }
        if !cuesParsed {
            guard cuesOffset > 0 else { throw MKVRemuxError(reason: "no Cues index (unseekable MKV)") }
            // Cues near the tail: fetch generously; the element is tiny
            // relative to the file (a few hundred KB at worst).
            let want = min(Int64(4 * 1024 * 1024), fetcher.totalLength - cuesOffset)
            let tail = try fetcher.fetch(offset: cuesOffset, length: Int(want))
            var cr = EBMLReader([UInt8](tail))
            let cid = try cr.readID()
            guard cid == ID.cues else { throw MKVRemuxError(reason: "SeekHead pointed at non-Cues") }
            let csize = try cr.readSize()
            try parseCues(EBMLReader(try cr.readBytes(min(Int(csize), cr.remaining))))
        }
        guard !segmentsMap.isEmpty else { throw MKVRemuxError(reason: "empty Cues index") }

        if v.defaultDurationNs > 0 {
            frameDurationTicks = max(300, v.defaultDurationNs * Self.ticksPerSecond / 1_000_000_000)
        }
        let mins = Double(durationTicks) / Double(Self.ticksPerSecond) / 60
        log(String(format: "[MKV] prepared: %@ %dx%d + %@, %.0f min, %d segments, cues %@",
                   v.codecID, v.width, v.height, audio?.codecID ?? "no-audio",
                   mins, segmentsMap.count, cuesParsed ? "in-head" : "from-tail"))
    }

    private func parseTracks(_ reader: EBMLReader) throws {
        var r = reader
        var audioCandidates: [TrackInfo] = []
        while r.remaining > 2 {
            let id = try r.readID()
            let size = try r.readSize()
            guard id == ID.trackEntry else { r.skip(size); continue }
            var t = EBMLReader(try r.readBytes(Int(size)))
            var track = TrackInfo(number: 0, codecID: "", codecPrivate: [])
            var type = 0
            var encrypted = false
            while t.remaining > 2 {
                let tid = try t.readID()
                let tsize = try t.readSize()
                switch tid {
                case ID.trackNumber: track.number = Int(try t.readUInt(Int(tsize)))
                case ID.trackType: type = Int(try t.readUInt(Int(tsize)))
                case ID.codecID: track.codecID = String(decoding: try t.readBytes(Int(tsize)), as: UTF8.self)
                case ID.codecPrivate: track.codecPrivate = try t.readBytes(Int(tsize))
                case ID.defaultDuration: track.defaultDurationNs = Int64(try t.readUInt(Int(tsize)))
                case ID.contentEncodings: encrypted = true; t.skip(tsize)
                case ID.videoBox:
                    var vb = EBMLReader(try t.readBytes(Int(tsize)))
                    while vb.remaining > 2 {
                        let vid = try vb.readID()
                        let vsize = try vb.readSize()
                        switch vid {
                        case ID.pixelWidth: track.width = Int(try vb.readUInt(Int(vsize)))
                        case ID.pixelHeight: track.height = Int(try vb.readUInt(Int(vsize)))
                        default: vb.skip(vsize)
                        }
                    }
                case ID.audioBox:
                    var ab = EBMLReader(try t.readBytes(Int(tsize)))
                    while ab.remaining > 2 {
                        let aid = try ab.readID()
                        let asize = try ab.readSize()
                        switch aid {
                        case ID.samplingFrequency: track.sampleRate = Int(try ab.readFloat(Int(asize)))
                        case ID.channels: track.channels = Int(try ab.readUInt(Int(asize)))
                        default: ab.skip(asize)
                        }
                    }
                default: t.skip(tsize)
                }
            }
            if encrypted {
                // ContentEncodings usually means header stripping
                // (compression), which we do not reverse in v1, or DRM.
                if type == 1 { throw MKVRemuxError(reason: "video track uses ContentEncodings") }
                continue
            }
            if type == 1, video == nil {
                // AV1 rides too, as an EXPERIMENT: CodecPrivate is the
                // av1C payload verbatim, so passthrough costs nothing and
                // the device gets to vote - A17-class hardware decodes it,
                // and Plex proves tvOS software decode is at least
                // plausible. If AVPlayer refuses, the item watchdog falls
                // the tile back to mpv and the picker note stays honest.
                guard track.codecID == "V_MPEG4/ISO/AVC"
                    || track.codecID == "V_MPEGH/ISO/HEVC"
                    || track.codecID == "V_AV1" else {
                    throw MKVRemuxError(reason: "video codec \(track.codecID)")
                }
                guard !track.codecPrivate.isEmpty else {
                    throw MKVRemuxError(reason: "video track missing CodecPrivate")
                }
                video = track
            } else if type == 2 {
                audioCandidates.append(track)
            }
        }
        // First SUPPORTED audio track, not first track: a
        // TrueHD+E-AC-3+DTS release plays via its E-AC-3 track.
        let supported = ["A_AC3", "A_EAC3", "A_AAC"]
        audio = audioCandidates.first { c in supported.contains(where: { c.codecID.hasPrefix($0) }) }
        if audio == nil, let first = audioCandidates.first {
            log("[MKV] no playable audio track (have: \(audioCandidates.map(\.codecID).joined(separator: ", "))); refusing")
            throw MKVRemuxError(reason: "audio codec \(first.codecID)")
        }
    }

    private func parseCues(_ reader: EBMLReader) throws {
        var r = reader
        var points: [CuePointInfo] = []
        while r.remaining > 2 {
            let id = try r.readID()
            let size = try r.readSize()
            guard id == ID.cuePoint else { r.skip(size); continue }
            var cp = EBMLReader(try r.readBytes(Int(size)))
            var time: Int64 = -1
            var cluster: Int64 = -1
            while cp.remaining > 2 {
                let cid = try cp.readID()
                let csize = try cp.readSize()
                switch cid {
                case ID.cueTime: time = Int64(try cp.readUInt(Int(csize)))
                case ID.cueTrackPositions:
                    var tp = EBMLReader(try cp.readBytes(Int(csize)))
                    while tp.remaining > 2 {
                        let tid = try tp.readID()
                        let tsize = try tp.readSize()
                        switch tid {
                        case ID.cueClusterPosition:
                            let pos = Int64(try tp.readUInt(Int(tsize)))
                            if cluster < 0 { cluster = segmentDataStart + pos }
                        default: tp.skip(tsize)
                        }
                    }
                default: cp.skip(csize)
                }
            }
            if time >= 0, cluster > 0 {
                points.append(CuePointInfo(timeTicks: ticks(fromScaled: time), clusterOffset: cluster))
            }
        }
        guard points.count >= 2 else {
            segmentsMap = []
            return
        }
        // Coalesce cue spans into ~6s segments: cue cadence varies from
        // one per keyframe (2s) to one per cluster (5s+); merging keeps
        // the playlist and request count sane for a 2h movie.
        let targetTicks: Int64 = 6 * Self.ticksPerSecond
        var merged: [CuePointInfo] = []
        for p in points {
            if let last = merged.last, p.timeTicks - last.timeTicks < targetTicks { continue }
            merged.append(p)
        }
        let total = durationTicks > 0 ? durationTicks : points.last!.timeTicks + targetTicks
        segmentsMap = merged.indices.map { i in
            let start = merged[i].timeTicks
            let end = i + 1 < merged.count ? merged[i + 1].timeTicks : total
            let byteEnd = i + 1 < merged.count ? merged[i + 1].clusterOffset : fetcher.totalLength
            return SegmentInfo(index: i, startTicks: start,
                               durationTicks: max(0, end - start),
                               byteStart: merged[i].clusterOffset, byteEnd: byteEnd)
        }
    }

    private func ticks(fromScaled scaled: Int64) -> Int64 {
        // Scaled timestamps are in TimestampScale ns units.
        scaled * timestampScaleNs * Self.ticksPerSecond / 1_000_000_000
    }

    // MARK: Playlist + init

    func playlistText() -> String {
        var text = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-TARGETDURATION:\(Int((segmentsMap.map { Double($0.durationTicks) }.max() ?? 0) / Double(Self.ticksPerSecond) + 1))
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-MAP:URI="init.mp4"

        """
        for seg in segmentsMap {
            let dur = Double(seg.durationTicks) / Double(Self.ticksPerSecond)
            text += "#EXTINF:\(String(format: "%.3f", dur)),\nseg\(seg.index).m4s\n"
        }
        text += "#EXT-X-ENDLIST\n"
        return text
    }

    func buildInitSegment() -> Data {
        guard let v = video else { return Data() }
        var out = Data(capacity: 1500)
        out.append(Self.box("ftyp", Self.bytes("iso5"), Self.u32(0),
                            Self.bytes("iso5"), Self.bytes("iso6"), Self.bytes("mp41")))
        var traks = [videoTrak(v)]
        if let a = audio { traks.append(audioTrak(a)) }
        var trexes = [Self.trex(Self.videoTrackID)]
        if audio != nil { trexes.append(Self.trex(Self.audioTrackID)) }
        out.append(Self.box("moov",
                            Self.mvhd(nextTrackID: audio != nil ? 3 : 2,
                                      durationTicks: durationTicks),
                            Self.concat(traks),
                            Self.box("mvex", Self.concat(trexes))))
        return out
    }

    private func videoTrak(_ v: TrackInfo) -> Data {
        // CodecPrivate IS the configuration record; wrap it and go.
        let (configType, entryType): (String, String) = {
            switch v.codecID {
            case "V_MPEGH/ISO/HEVC": return ("hvcC", "hvc1")
            case "V_AV1": return ("av1C", "av01")
            default: return ("avcC", "avc1")
            }
        }()
        let configBox = Self.box(configType, Data(v.codecPrivate))
        var entry = Data(capacity: 96 + configBox.count)
        entry.append(Data(count: 6)); entry.append(Self.u16(1))
        entry.append(Data(count: 16))
        entry.append(Self.u16(v.width)); entry.append(Self.u16(v.height))
        entry.append(Self.u32(0x00480000)); entry.append(Self.u32(0x00480000))
        entry.append(Self.u32(0)); entry.append(Self.u16(1))
        entry.append(Data(count: 32))
        entry.append(Self.u16(0x0018)); entry.append(Self.u16(0xFFFF))
        entry.append(configBox)
        let sample = Self.box(entryType, entry)
        return Self.trak(trackID: Self.videoTrackID, width: v.width, height: v.height,
                         volume: 0, handler: "vide", handlerName: "VideoHandler",
                         durationTicks: durationTicks,
                         mediaHeader: Self.fullBox("vmhd", 0, 1, Self.u16(0), Self.u16(0), Self.u16(0), Self.u16(0)),
                         sampleEntry: sample)
    }

    private func audioTrak(_ a: TrackInfo) -> Data {
        let entry: Data
        if a.codecID.hasPrefix("A_AAC") {
            var asc = a.codecPrivate
            if asc.isEmpty {
                // Synthesize AAC-LC ASC from the track's rate/channels.
                let rates = [96000, 88200, 64000, 48000, 44100, 32000, 24000,
                             22050, 16000, 12000, 11025, 8000, 7350]
                let fi = rates.firstIndex(of: a.sampleRate) ?? 3
                asc = [UInt8((2 << 3) | (fi >> 1)), UInt8(((fi & 1) << 7) | (a.channels << 3))]
            }
            var dsi = Data([0x05, UInt8(asc.count)]); dsi.append(contentsOf: asc)
            var dcd = Data([0x04, UInt8(13 + dsi.count), 0x40, 0x15])
            dcd.append(Data(count: 3)); dcd.append(Self.u32(0)); dcd.append(Self.u32(0))
            dcd.append(dsi)
            var esd = Data([0x03, UInt8(3 + dcd.count + 3), 0x00, 0x00, 0x00])
            esd.append(dcd); esd.append(Data([0x06, 0x01, 0x02]))
            entry = Self.box("mp4a", Self.audioSampleEntryBody(channels: a.channels, sampleRate: a.sampleRate),
                             Self.fullBox("esds", 0, 0, esd))
        } else if a.codecID == "A_EAC3" {
            // Minimal dec3; the decoder reads the real BSI from frames.
            var body = Data()
            body.append(Self.u16(0 << 3))
            var sub = 0
            sub |= 0 << 14                       // fscod 48k
            sub |= 16 << 9                       // bsid
            sub |= (a.channels >= 6 ? 7 : 2) << 1 // acmod 3/2 or 2/0
            sub |= (a.channels >= 6 ? 1 : 0)     // lfeon
            body.append(Self.u16(sub)); body.append(0)
            entry = Self.box("ec-3", Self.audioSampleEntryBody(channels: a.channels, sampleRate: a.sampleRate),
                             Self.box("dec3", body))
        } else {
            var v = 0
            v |= 0 << 22    // fscod 48k
            v |= 8 << 17    // bsid
            v |= (a.channels >= 6 ? 7 : 2) << 11
            v |= (a.channels >= 6 ? 1 : 0) << 10
            v |= 15 << 5    // bit_rate_code placeholder (448k)
            let body = Data([UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
            entry = Self.box("ac-3", Self.audioSampleEntryBody(channels: a.channels, sampleRate: a.sampleRate),
                             Self.box("dac3", body))
        }
        return Self.trak(trackID: Self.audioTrackID, width: 0, height: 0, volume: 0x0100,
                         handler: "soun", handlerName: "SoundHandler",
                         durationTicks: durationTicks,
                         mediaHeader: Self.fullBox("smhd", 0, 0, Self.u16(0), Self.u16(0)),
                         sampleEntry: entry)
    }

    // MARK: Segment remux

    private struct Sample {
        let data: [UInt8]
        let ptsTicks: Int64
        let keyframe: Bool
    }

    /// Raw span cache: sequential playback re-reads each byte span up to
    /// three times (as its own segment and as both neighbors); caching the
    /// last few fetches keeps steady-state network cost at ~1x.
    private var spanCache: [(offset: Int64, data: Data)] = []

    private func fetchSpan(offset: Int64, length: Int) throws -> Data {
        if let hit = spanCache.first(where: { $0.offset == offset && $0.data.count == length }) {
            return hit.data
        }
        let data = try fetcher.fetch(offset: offset, length: length)
        spanCache.append((offset, data))
        if spanCache.count > 4 { spanCache.removeFirst() }
        return data
    }

    func buildMediaSegment(_ index: Int) throws -> Data {
        guard index >= 0, index < segmentsMap.count, let v = video else {
            throw MKVRemuxError(reason: "segment index out of range")
        }
        let seg = segmentsMap[index]
        // Parse the NEIGHBOR spans too (2026-08-25 field fix, "weird
        // stutter then audio sync got messed up", 4K 72 HOURS): frames
        // whose timestamps belong to this segment can be physically muxed
        // in the adjacent clusters (audio interleave lead/lag, HEVC
        // reorder stragglers). Fetching only the exact cue span silently
        // LOST those frames - both neighbors' time-trims excluded them -
        // leaving audio holes at boundaries that AVPlayer resyncs over
        // as stutter + accruing desync. The span cache keeps sequential
        // playback at ~1x fetch despite the 3-span parse.
        let loIndex = max(0, index - 1)
        let hiEnd: Int64 = index + 1 < segmentsMap.count
            ? segmentsMap[min(index + 1, segmentsMap.count - 1)].byteEnd
            : seg.byteEnd
        let lo = segmentsMap[loIndex].byteStart
        let length = Int(hiEnd - lo)
        guard length > 0, length < 512 * 1024 * 1024 else {
            throw MKVRemuxError(reason: "absurd segment span \(length) bytes")
        }
        let raw = try fetchSpan(offset: lo, length: length)

        var videoSamples: [Sample] = []
        var audioSamples: [Sample] = []
        var r = EBMLReader([UInt8](raw))
        let nextStart = seg.startTicks + seg.durationTicks
        while r.remaining > 4 {
            let id: UInt32
            do { id = try r.readID() } catch { break }
            let size: Int64
            do { size = try r.readSize() } catch { break }
            guard id == ID.cluster else {
                if size < 0 { break }
                r.skip(size); continue
            }
            // Unknown-size cluster: walk children until the next cluster id.
            let clusterEnd = size >= 0 ? min(r.pos + Int(size), r.data.count) : r.data.count
            var clusterTS: Int64 = 0
            while r.pos < clusterEnd, r.remaining > 2 {
                // Peek for a following cluster in the unknown-size case.
                if size < 0, r.remaining >= 4,
                   r.data[r.pos] == 0x1F, r.data[r.pos + 1] == 0x43,
                   r.data[r.pos + 2] == 0xB6, r.data[r.pos + 3] == 0x75 { break }
                let cid: UInt32
                do { cid = try r.readID() } catch { break }
                let csize: Int64
                do { csize = try r.readSize() } catch { break }
                guard csize >= 0 else { break }
                switch cid {
                case ID.clusterTimestamp:
                    clusterTS = Int64(try r.readUInt(Int(csize)))
                case ID.simpleBlock:
                    try parseBlock(try r.readBytes(Int(csize)), clusterTS: clusterTS,
                                   video: &videoSamples, audio: &audioSamples,
                                   keyframeFromFlags: true)
                case ID.blockGroup:
                    var bg = EBMLReader(try r.readBytes(Int(csize)))
                    var hadReference = false
                    var blockBytes: [UInt8] = []
                    while bg.remaining > 2 {
                        let bid = try bg.readID()
                        let bsize = try bg.readSize()
                        switch bid {
                        case ID.block: blockBytes = try bg.readBytes(Int(bsize))
                        case 0xFB: hadReference = true; bg.skip(bsize) // ReferenceBlock
                        default: bg.skip(bsize)
                        }
                    }
                    if !blockBytes.isEmpty {
                        try parseBlock(blockBytes, clusterTS: clusterTS,
                                       video: &videoSamples, audio: &audioSamples,
                                       keyframeFromFlags: false, groupKeyframe: !hadReference)
                    }
                default:
                    r.skip(csize)
                }
            }
        }

        // Partition, exact by construction over the 3-span parse:
        //  - video: decode-order run from this segment's starting
        //    keyframe (first keyframe with pts >= start, minus half a
        //    frame of slack) up to the NEXT segment's starting keyframe.
        //    Reorder stragglers between the two keyframes ride along
        //    regardless of their pts, which is what decode needs.
        //  - audio: every frame with pts in [start, nextStart) - complete
        //    now that both neighbor spans were parsed.
        let halfFrame = frameDurationTicks / 2
        if let startKey = videoSamples.firstIndex(where: {
            $0.keyframe && $0.ptsTicks >= seg.startTicks - halfFrame }) {
            videoSamples.removeFirst(startKey)
        } else {
            videoSamples.removeAll()
        }
        if let endKey = videoSamples.dropFirst().firstIndex(where: {
            $0.keyframe && $0.ptsTicks >= nextStart - halfFrame }) {
            videoSamples = Array(videoSamples[..<endKey])
        }
        audioSamples = audioSamples.filter { $0.ptsTicks >= seg.startTicks && $0.ptsTicks < nextStart }
        guard !videoSamples.isEmpty else { throw MKVRemuxError(reason: "segment \(index): no video samples") }

        _ = v
        return writeSegment(index: index, seg: seg, video: videoSamples, audio: audioSamples)
    }

    private func parseBlock(_ block: [UInt8], clusterTS: Int64,
                            video: inout [Sample], audio: inout [Sample],
                            keyframeFromFlags: Bool, groupKeyframe: Bool = false) throws {
        var r = EBMLReader(block)
        // Track number is a vint WITH the marker stripped like a size.
        let first = block[0]
        let tlen = EBMLReader.vintLength(first)
        guard tlen >= 1, tlen <= 4 else { return }
        var trackNum = Int(first & (0xFF >> tlen))
        for i in 1..<tlen { trackNum = (trackNum << 8) | Int(block[i]) }
        r.pos = tlen
        let rel = Int16(bitPattern: UInt16(try r.readUInt(2)))
        let flags = try r.readUInt(1)
        let pts = ticks(fromScaled: clusterTS + Int64(rel))
        let keyframe = keyframeFromFlags ? (flags & 0x80) != 0 : groupKeyframe

        let isVideo = trackNum == self.video?.number
        let isAudio = trackNum == self.audio?.number
        guard isVideo || isAudio else { return }

        // Lacing (flags bits 1-2): 0 none, 1 Xiph, 3 EBML, 2 fixed.
        let lacing = Int((flags >> 1) & 0x03)
        var frames: [[UInt8]] = []
        if lacing == 0 {
            frames = [try r.readBytes(r.remaining)]
        } else {
            let count = Int(try r.readUInt(1)) + 1
            var sizes = [Int]()
            switch lacing {
            case 1: // Xiph
                for _ in 0..<(count - 1) {
                    var total = 0
                    while true {
                        let b = Int(try r.readUInt(1))
                        total += b
                        if b != 255 { break }
                    }
                    sizes.append(total)
                }
            case 2: // fixed
                let each = r.remaining / count
                sizes = [Int](repeating: each, count: count - 1)
            case 3: // EBML
                // First size is a plain vint; the rest are SIGNED deltas.
                var er = EBMLReader(block, at: r.pos)
                let firstSize = Int(try er.readSize())
                sizes.append(firstSize)
                var prev = firstSize
                for _ in 1..<(count - 1) {
                    let b0 = er.data[er.pos]
                    let len = EBMLReader.vintLength(b0)
                    var vRaw = Int64(b0 & (0xFF >> len))
                    for i in 1..<len { vRaw = (vRaw << 8) | Int64(er.data[er.pos + i]) }
                    er.pos += len
                    let bias = (Int64(1) << (7 * len - 1)) - 1
                    prev += Int(vRaw - bias)
                    sizes.append(prev)
                }
                r.pos = er.pos
            default:
                break
            }
            for size in sizes { frames.append(try r.readBytes(size)) }
            frames.append(try r.readBytes(r.remaining)) // last frame: remainder
        }

        if isVideo {
            // A laced video block would smear timestamps; unseen in the
            // wild for AVC/HEVC, refuse loudly rather than guess.
            guard frames.count == 1 else { throw MKVRemuxError(reason: "laced video block") }
            video.append(Sample(data: frames[0], ptsTicks: pts, keyframe: keyframe))
        } else {
            // Laced audio frames sit defaultDuration (or frame duration)
            // apart; AC-3/E-AC-3 = 1536 samples, AAC = 1024.
            let samplesPerFrame: Int64 = (self.audio?.codecID.hasPrefix("A_AAC") ?? false) ? 1024 : 1536
            let tick = samplesPerFrame * Self.ticksPerSecond / Int64(max(1, self.audio?.sampleRate ?? 48000))
            for (i, f) in frames.enumerated() {
                audio.append(Sample(data: f, ptsTicks: pts + Int64(i) * tick, keyframe: true))
            }
        }
    }

    private func writeSegment(index: Int, seg: SegmentInfo,
                              video: [Sample], audio: [Sample]) -> Data {
        // dts ladder: blocks are in decode order, timestamps are pts.
        // Constant-rate movies: dts_i = base + i*frameDuration, with the
        // base chosen so cts = pts - dts stays non-negative.
        let n = video.count
        var frameDur = frameDurationTicks
        if n > 2 {
            let sorted = video.map(\.ptsTicks).sorted()
            var deltas: [Int64] = []
            for i in 1..<sorted.count { deltas.append(sorted[i] - sorted[i - 1]) }
            let med = deltas.sorted()[deltas.count / 2]
            if med > 300 { frameDur = med }
        }
        // Deterministic base: seg.startTicks minus a fixed 4-frame reorder
        // lead, so consecutive segments' ladders are CONTINUOUS. The old
        // per-segment min() base made each segment independent and let
        // seams butt up with duplicate/overlapping dts (ffmpeg: "non
        // monotonically increasing dts ... 64 >= 64" exactly at seg
        // boundaries) - a per-seam hiccup. cts floors at 0 for the rare
        // deeper-than-4 reorder rather than breaking monotonic dts.
        let base = seg.startTicks - 4 * frameDur
        let dts = (0..<n).map { base + Int64($0) * frameDur }

        let videoBytes = video.reduce(0) { $0 + $1.data.count }
        let audioBytes = audio.reduce(0) { $0 + $1.data.count }
        // TRUE per-frame durations from successive pts deltas (last frame
        // gets the median). The old single averaged tick smeared any real
        // gap across every frame's declared timing - audible as
        // progressive desync snapping back at each segment (2026-08-25
        // field find). Explicit deltas keep the timeline honest, holes
        // included.
        var audioDurations = [Int64](repeating: 2880, count: audio.count)
        if audio.count > 1 {
            var deltas: [Int64] = []
            for i in 0..<(audio.count - 1) {
                let d = max(300, audio[i + 1].ptsTicks - audio[i].ptsTicks)
                audioDurations[i] = d
                deltas.append(d)
            }
            audioDurations[audio.count - 1] = deltas.sorted()[deltas.count / 2]
        }

        func moof(_ vOff: Int, _ aOff: Int) -> Data {
            let mfhd = Self.fullBox("mfhd", 0, 0, Self.u32(index + 1))
            var vbody = Data(capacity: 16 + n * 16)
            vbody.append(Self.u32(n)); vbody.append(Self.u32(vOff))
            for i in 0..<n {
                vbody.append(Self.u32(Int(frameDur)))
                vbody.append(Self.u32(video[i].data.count))
                vbody.append(Self.u32(video[i].keyframe ? 0x02000000 : 0x01010000))
                vbody.append(Self.u32(Int(max(0, video[i].ptsTicks - dts[i]))))
            }
            let vtraf = Self.box("traf",
                Self.fullBox("tfhd", 0, 0x020000, Self.u32(Self.videoTrackID)),
                Self.fullBox("tfdt", 1, 0, Self.u64(UInt64(max(0, dts[0])))),
                Self.fullBox("trun", 1, 0x000F01, vbody))
            var trafs = [vtraf]
            if let firstAudio = audio.first {
                var abody = Data(capacity: 16 + audio.count * 8)
                abody.append(Self.u32(audio.count)); abody.append(Self.u32(aOff))
                for (i, a) in audio.enumerated() {
                    abody.append(Self.u32(Int(audioDurations[i])))
                    abody.append(Self.u32(a.data.count))
                }
                trafs.append(Self.box("traf",
                    Self.fullBox("tfhd", 0, 0x020000, Self.u32(Self.audioTrackID)),
                    Self.fullBox("tfdt", 1, 0, Self.u64(UInt64(max(0, firstAudio.ptsTicks)))),
                    Self.fullBox("trun", 0, 0x000301, abody)))
            }
            return Self.box("moof", mfhd, Self.concat(trafs))
        }

        var m = moof(0, 0)
        let msize = m.count
        m = moof(msize + 8, msize + 8 + videoBytes)
        var out = Data(capacity: m.count + 8 + videoBytes + audioBytes)
        out.append(m)
        out.append(Self.u32(8 + videoBytes + audioBytes))
        out.append(Self.bytes("mdat"))
        for s in video { out.append(contentsOf: s.data) }
        for a in audio { out.append(contentsOf: a.data) }
        return out
    }

    // MARK: stats

    var summary: String {
        String(format: "[MKV] fetched %.1f MB of %.1f MB",
               Double(fetcher.bytesFetched) / 1_048_576,
               Double(fetcher.totalLength) / 1_048_576)
    }

    // MARK: box plumbing (third sibling; see file header)

    private static func concat(_ parts: [Data]) -> Data {
        var out = Data(capacity: parts.reduce(0) { $0 + $1.count })
        for p in parts { out.append(p) }
        return out
    }

    private static func box(_ type: String, _ payload: Data...) -> Data {
        let size = 8 + payload.reduce(0) { $0 + $1.count }
        var out = Data(capacity: size)
        out.append(u32(size)); out.append(bytes(type))
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
    private static func u16(_ v: Int) -> Data { Data([UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]) }

    private static func u32(_ v: Int) -> Data {
        let u = UInt32(truncatingIfNeeded: v)
        return Data([UInt8((u >> 24) & 0xFF), UInt8((u >> 16) & 0xFF),
                     UInt8((u >> 8) & 0xFF), UInt8(u & 0xFF)])
    }

    private static func u64(_ v: UInt64) -> Data {
        u32(Int(truncatingIfNeeded: Int64(bitPattern: v >> 32)))
            + u32(Int(truncatingIfNeeded: Int64(bitPattern: v & 0xFFFF_FFFF)))
    }

    private static func audioSampleEntryBody(channels: Int, sampleRate: Int) -> Data {
        var b = Data(capacity: 28)
        b.append(Data(count: 6)); b.append(u16(1))
        b.append(Data(count: 8))
        b.append(u16(channels)); b.append(u16(16))
        b.append(u32(0))
        b.append(u32(sampleRate << 16))
        return b
    }

    private static func mvhd(nextTrackID: Int, durationTicks: Int64) -> Data {
        fullBox("mvhd", 0, 0,
                u32(0), u32(0),
                u32(Int(ticksPerSecond)), u32(Int(clamping: durationTicks)),
                u32(0x00010000), u16(0x0100), u16(0), u32(0), u32(0),
                matrix(), Data(count: 24), u32(nextTrackID))
    }

    private static func matrix() -> Data {
        var out = Data(capacity: 36)
        for v in [0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x40000000] { out.append(u32(v)) }
        return out
    }

    private static func trak(trackID: Int, width: Int, height: Int, volume: Int,
                             handler: String, handlerName: String, durationTicks: Int64,
                             mediaHeader: Data, sampleEntry: Data) -> Data {
        let tkhd = fullBox(
            "tkhd", 0, 7,
            u32(0), u32(0), u32(trackID), u32(0), u32(Int(clamping: durationTicks)),
            u32(0), u32(0),
            u16(0), u16(0), u16(volume), u16(0),
            matrix(),
            u32(width << 16), u32(height << 16))
        let mdhd = fullBox(
            "mdhd", 0, 0,
            u32(0), u32(0), u32(Int(ticksPerSecond)), u32(Int(clamping: durationTicks)),
            u16(0x55C4), u16(0))
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
}

// MARK: - VOD loopback server

/// Loopback HLS server for one MKV VOD item: /vod.m3u8, /init.mp4,
/// /segN.m4s remuxed on demand. Sibling of TSHLSRemuxer's server with a
/// static playlist and demand-paged segments instead of a live window.
final class MKVVODServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "mkv-vod-server", qos: .userInitiated)
    private let remuxer: MKVFMP4Remuxer
    private var listener: NWListener?
    private(set) var localPort: UInt16 = 0
    /// Tiny LRU so AVPlayer's occasional segment re-request (seek
    /// landing, bitrate probe) does not refetch megabytes.
    private var cache: [(index: Int, data: Data)] = []

    var onReady: ((URL) -> Void)?
    var onError: ((String) -> Void)?
    /// Geometry / frame rate / 10-bit flag for the tile's display-mode
    /// criteria, derived from the track header (fps from
    /// DefaultDuration, bit depth from the hvcC CodecPrivate).
    var onVideoParameters: ((_ width: Int, _ height: Int, _ fps: Double, _ is10Bit: Bool) -> Void)?

    init(url: URL, headers: [String: String]) {
        remuxer = MKVFMP4Remuxer(url: url, headers: headers) { line in debugLog("[MKV-VOD] \(line)") }
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                try self.remuxer.prepare()
            } catch {
                debugLog("[MKV-VOD] prepare failed: \(error)")
                DispatchQueue.main.async { self.onError?("\(error)") }
                return
            }
            if let v = self.remuxer.video {
                let fps = v.defaultDurationNs > 0 ? 1_000_000_000.0 / Double(v.defaultDurationNs) : 0
                // hvcC byte 17 carries bitDepthLumaMinus8 in its low bits.
                let tenBit = v.codecID == "V_MPEGH/ISO/HEVC"
                    && v.codecPrivate.count > 17
                    && (v.codecPrivate[17] & 0x07) > 0
                DispatchQueue.main.async { self.onVideoParameters?(v.width, v.height, fps, tenBit) }
            }
            do {
                let listener = try NWListener(using: .tcp, on: .any)
                listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    if case .ready = state {
                        self.queue.async {
                            self.localPort = listener.port?.rawValue ?? 0
                            let url = URL(string: "http://127.0.0.1:\(self.localPort)/vod.m3u8")!
                            debugLog("[MKV-VOD] READY -> \(url.absoluteString)")
                            DispatchQueue.main.async { self.onReady?(url) }
                        }
                    }
                }
                listener.start(queue: self.queue)
                self.listener = listener
            } catch {
                debugLog("[MKV-VOD] listener failed: \(error)")
                DispatchQueue.main.async { self.onError?("\(error)") }
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            debugLog("\(self.remuxer.summary)")
            self.listener?.cancel()
            self.listener = nil
            self.remuxer.teardown()
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self, error == nil else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
                let path = head.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                self.respond(connection, path: path)
            } else if isComplete || buffer.count >= 16_384 {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection, path: String) {
        var body: Data
        var contentType = "application/octet-stream"
        var status = "200 OK"
        if path.hasSuffix("vod.m3u8") {
            body = Data(remuxer.playlistText().utf8)
            contentType = "application/vnd.apple.mpegurl"
        } else if path.hasSuffix("init.mp4") {
            body = remuxer.buildInitSegment()
            contentType = "video/mp4"
        } else if path.hasPrefix("/seg"), path.hasSuffix(".m4s"),
                  let index = Int(path.dropFirst(4).dropLast(4)) {
            if let hit = cache.first(where: { $0.index == index }) {
                body = hit.data
            } else {
                do {
                    body = try remuxer.buildMediaSegment(index)
                    cache.append((index, body))
                    if cache.count > 4 { cache.removeFirst() }
                } catch {
                    debugLog("[MKV-VOD] segment \(index) failed: \(error)")
                    body = Data("segment error".utf8)
                    contentType = "text/plain"
                    status = "500 Internal Server Error"
                }
            }
            if status.hasPrefix("200") { contentType = "video/iso.segment" }
        } else {
            body = Data("not found".utf8)
            contentType = "text/plain"
            status = "404 Not Found"
        }
        var response = Data("HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
