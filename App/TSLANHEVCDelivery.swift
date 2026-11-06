import Foundation

// AirPlay LAN delivery of an HEVC channel to a non-Apple receiver.
//
// iPhone 2026-11-06 16:07 (ESPN 2 HD, HEVC 3840x2160, Roku 3840R): the
// codec gate put the session on the HEVC fMP4 arm, the receiver read
// init.mp4 twice, never fetched a media segment, and answered AVError
// -11870 / -12927 (Not supported). Every verified non-Apple session
// (2026-09-26) was muxed TS. Logan's decision (2026-11-06): a non-Apple
// receiver gets HEVC in muxed TS first (the AAC-LC stereo rewrite rides
// the same segments), and when the receiver rejects that, the LAN copy
// is re-muxed with an H.264 transcode of the video (VideoToolbox on the
// phone, HDR tone mapped to SDR, 1080p60 cap). The outcome is remembered
// per receiver model so the next session starts on the working arm.
//
// Pure logic, compiled by Scripts/cast-hls-proxy-tests/run.sh: no app
// singletons here. The VideoToolbox transcoder comes in through the
// `CastVideoTranscoding` seam.

/// How the LAN serves an HEVC program to the receiver.
enum AirPlayHEVCArm: String, Sendable, Equatable {
    /// init.mp4 + .m4s (Apple receivers, the loopback path).
    case fmp4
    /// HEVC inside muxed TS segments (VERSION 3, seg.ts).
    case hevcTS
    /// H.264 transcode inside muxed TS segments.
    case h264Transcode

    var label: String {
        switch self {
        case .fmp4: return "HEVC fMP4"
        case .hevcTS: return "HEVC in TS"
        case .h264Transcode: return "H.264 transcode in TS"
        }
    }
}

/// The receiver class the plan is made for.
enum AirPlayReceiverClass: Sendable, Equatable {
    case apple
    case nonApple
    /// No TXT model yet; treated like an Apple receiver (today's path).
    case unknown
}

enum AirPlayHEVCArmSelection {
    /// The arm a fresh session starts on. `remembered` is the last
    /// outcome for this receiver model (nil = none).
    static func select(receiver: AirPlayReceiverClass,
                       remembered: AirPlayHEVCArm?) -> (arm: AirPlayHEVCArm, reason: String) {
        switch receiver {
        case .apple: return (.fmp4, "Apple receiver")
        case .unknown: return (.fmp4, "receiver model unknown, Apple path")
        case .nonApple:
            switch remembered {
            case .h264Transcode?: return (.h264Transcode, "remembered: this receiver rejected HEVC in TS")
            case .hevcTS?: return (.hevcTS, "remembered: this receiver played HEVC in TS")
            case .fmp4?, nil: return (.hevcTS, "non-Apple receiver, first try")
            }
        }
    }

    /// The arm to fall back to after the receiver rejected `current`; nil
    /// when there is nothing left to try.
    static func next(after current: AirPlayHEVCArm) -> AirPlayHEVCArm? {
        switch current {
        case .fmp4: return nil
        case .hevcTS: return .h264Transcode
        case .h264Transcode: return nil
        }
    }
}

// MARK: - HEVC access units out of TS

/// Reassembles the video PID's PES packets of a TS segment into access
/// units: 4-byte-length NAL units (parameter sets, AUD and SEI suffix
/// removed) with 33-bit PTS / DTS, the keyframe flag (IRAP) and the
/// parameter sets in force. Same conventions as the Cast remuxer's
/// transcode input.
final class TSHEVCAccessUnitDemuxer {
    struct AccessUnit {
        var sample: [UInt8]
        var pts33: Int64
        var dts33: Int64
        var keyframe: Bool
        var parameterSets: [[UInt8]]   // [VPS, SPS, PPS]
    }

    private(set) var vps: [UInt8] = []
    private(set) var sps: [UInt8] = []
    private(set) var pps: [UInt8] = []
    private var pes: [UInt8] = []
    private var collecting = false

    var hasParameterSets: Bool { !vps.isEmpty && !sps.isEmpty && !pps.isEmpty }

    /// Access units of `segment` for `videoPID`, in stream order. A PES
    /// still open at the end of the segment is kept for the next call.
    func demux(_ segment: [UInt8], videoPID: Int) -> [AccessUnit] {
        var out: [AccessUnit] = []
        let n = TSLANAudioRewriter.packetSize
        var i = 0
        while i + n <= segment.count {
            defer { i += n }
            guard segment[i] == 0x47 else { continue }
            let pid = (Int(segment[i + 1] & 0x1F) << 8) | Int(segment[i + 2])
            guard pid == videoPID else { continue }
            let p = Array(segment[i..<(i + n)])
            let pusi = p[1] & 0x40 != 0
            guard let off = TSLANAudioRewriter.payloadOffset(p), off < n else { continue }
            if pusi {
                if let au = flush() { out.append(au) }
                collecting = true
            }
            if collecting { pes.append(contentsOf: p[off...]) }
        }
        return out
    }

    /// The PES held open at the end of the last segment.
    func finish() -> AccessUnit? { flush() }

    func reset() {
        pes.removeAll()
        collecting = false
    }

    private func flush() -> AccessUnit? {
        guard collecting, !pes.isEmpty else { pes.removeAll(keepingCapacity: true); return nil }
        let data = pes
        pes.removeAll(keepingCapacity: true)
        collecting = false
        guard data.count >= 9, data[0] == 0, data[1] == 0, data[2] == 1 else { return nil }
        let flags = data[7] & 0xC0
        let headerLen = Int(data[8])
        let payloadOff = 9 + headerLen
        guard payloadOff < data.count, flags & 0x80 != 0, headerLen >= 5 else { return nil }
        let pts = TSLANAudioRewriter.decodePTS(data, 9)
        let dts = (flags & 0x40 != 0 && headerLen >= 10) ? TSLANAudioRewriter.decodePTS(data, 14) : pts
        let nals = Self.splitAnnexB(Array(data[payloadOff...]))
        guard !nals.isEmpty else { return nil }
        var keyframe = false
        var sample: [UInt8] = []
        for nal in nals {
            let type = (nal[nal.startIndex] >> 1) & 0x3F
            switch type {
            case 16...23: keyframe = true
            case 32: vps = Array(nal); continue
            case 33: sps = Array(nal); continue
            case 34: pps = Array(nal); continue
            case 35, 38: continue        // AUD, filler
            default: break
            }
            let c = nal.count
            sample.append(contentsOf: [UInt8((c >> 24) & 0xFF), UInt8((c >> 16) & 0xFF),
                                       UInt8((c >> 8) & 0xFF), UInt8(c & 0xFF)])
            sample.append(contentsOf: nal)
        }
        guard !sample.isEmpty else { return nil }
        return AccessUnit(sample: sample, pts33: pts, dts33: dts, keyframe: keyframe,
                          parameterSets: [vps, sps, pps])
    }

    static func splitAnnexB(_ payload: [UInt8]) -> [ArraySlice<UInt8>] {
        var nals: [ArraySlice<UInt8>] = []
        var i = 0
        var nalStart = -1
        let n = payload.count
        while i + 2 < n {
            if payload[i] == 0, payload[i + 1] == 0, payload[i + 2] == 1 {
                if nalStart >= 0 {
                    var end = i
                    if end > nalStart, payload[end - 1] == 0 { end -= 1 }
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
}

// MARK: - H.264 video replacement inside a TS segment

/// Rebuilds one LAN TS segment with its HEVC video replaced by H.264
/// frames: every packet of the video PID is dropped, the PMT entry for
/// that PID is retyped 0x1B (section CRC recomputed, PCR_PID unchanged,
/// so a PCR that rode the video PID is re-stamped by the muxed frames),
/// and each frame is muxed as one PES on the same PID with its PTS, a PCR
/// on its first packet and the random_access_indicator on keyframes.
/// Frames are interleaved before the first audio PES whose PTS passes
/// theirs; the rest follow the last packet.
enum TSLANVideoReplacer {
    struct Frame {
        /// Annex B access unit (AUD, SPS/PPS on keyframes, slices).
        var accessUnit: [UInt8]
        var pts: Int64
        var keyframe: Bool
    }

    /// The PMT packet with `videoPID`'s stream_type set to `type`, CRC
    /// recomputed. Nil when the PID is not in the ES loop or the packet
    /// is malformed.
    static func retypeVideo(pmt p: [UInt8], videoPID: Int, type: UInt8) -> [UInt8]? {
        let n = TSLANAudioRewriter.packetSize
        guard p.count == n, p[1] & 0x40 != 0, let base = TSLANAudioRewriter.payloadOffset(p), base < n else { return nil }
        let s = base + 1 + Int(p[base])
        guard s + 12 < n, p[s] == 0x02 else { return nil }
        let sectionLength = (Int(p[s + 1] & 0x0F) << 8) | Int(p[s + 2])
        let end = s + 3 + sectionLength - 4
        guard end <= n - 4, end > s + 12 else { return nil }
        let pil = (Int(p[s + 10] & 0x0F) << 8) | Int(p[s + 11])
        var o = s + 12 + pil
        var out = p
        var found = false
        while o + 5 <= end {
            let pid = (Int(p[o + 1] & 0x1F) << 8) | Int(p[o + 2])
            let esil = (Int(p[o + 3] & 0x0F) << 8) | Int(p[o + 4])
            if pid == videoPID { out[o] = type; found = true }
            o += 5 + esil
        }
        guard found else { return nil }
        let crc = TSLANAudioRewriter.crc32MPEG(Array(out[s..<end]))
        out[end] = UInt8(crc >> 24)
        out[end + 1] = UInt8((crc >> 16) & 0xFF)
        out[end + 2] = UInt8((crc >> 8) & 0xFF)
        out[end + 3] = UInt8(crc & 0xFF)
        return out
    }

    /// `segment` with the video replaced. `cc` is the video PID's
    /// continuity counter, carried across segments by the caller. Nil
    /// when the segment has no PAT/PMT or the PMT does not name
    /// `videoPID`.
    static func replace(segment: [UInt8], videoPID: Int, frames: [Frame], cc: inout UInt8) -> [UInt8]? {
        let n = TSLANAudioRewriter.packetSize
        let count = segment.count / n
        guard count > 0 else { return nil }
        func pid(_ i: Int) -> Int { (Int(segment[i * n + 1] & 0x1F) << 8) | Int(segment[i * n + 2]) }
        func packet(_ i: Int) -> [UInt8] { Array(segment[(i * n)..<((i + 1) * n)]) }
        var pmtPID = -1
        for i in 0..<count where segment[i * n] == 0x47 && pid(i) == 0 && segment[i * n + 1] & 0x40 != 0 {
            pmtPID = TSLANAudioRewriter.firstPMTPID(packet(i)) ?? -1
            break
        }
        guard pmtPID >= 0 else { return nil }
        var audioPIDs = Set<Int>()
        var pmtSeen = false
        let sorted = frames.sorted { $0.pts < $1.pts }
        var next = 0
        var out = [UInt8]()
        out.reserveCapacity(segment.count + sorted.reduce(0) { $0 + $1.accessUnit.count + 400 })
        let mask = TSLANAudioRewriter.pts33Mask
        func emit(_ f: Frame) {
            let pcr = (f.pts - TSCardVideoMuxer.pcrLeadTicks) & mask
            out += TSCardVideoMuxer.packetizeVideo(accessUnit: f.accessUnit, pts: f.pts & mask, pcr: pcr,
                                                   pid: videoPID, cc: &cc, randomAccess: f.keyframe)
        }
        for i in 0..<count {
            guard segment[i * n] == 0x47 else { continue }
            let id = pid(i)
            if id == videoPID { continue }
            var p = packet(i)
            if id == pmtPID {
                if p[1] & 0x40 != 0 {
                    guard let info = TSLANAudioRewriter.parsePMT(p), info.videoPID == videoPID,
                          let retyped = retypeVideo(pmt: p, videoPID: videoPID, type: TSCardVideoMuxer.videoStreamType)
                    else { return nil }
                    audioPIDs = Set(info.audio.map(\.pid))
                    p = retyped
                    pmtSeen = true
                }
                out += p
                continue
            }
            if pmtSeen, audioPIDs.contains(id), p[1] & 0x40 != 0, let apts = TSLANAudioRewriter.pesPTS(p) {
                // Video up to this audio PES's time goes first (33-bit safe:
                // a frame more than half the wrap ahead is "behind").
                while next < sorted.count {
                    let d = (apts - sorted[next].pts) & mask
                    guard d < (1 << 32) else { break }
                    emit(sorted[next]); next += 1
                }
            }
            out += p
        }
        guard pmtSeen else { return nil }
        while next < sorted.count { emit(sorted[next]); next += 1 }
        return out
    }

    /// SPS and PPS NAL units out of an avcC box body.
    static func parameterSets(avcC c: [UInt8]) -> (sps: [[UInt8]], pps: [[UInt8]])? {
        guard c.count > 6, c[0] == 1 else { return nil }
        var o = 5
        let numSPS = Int(c[o] & 0x1F); o += 1
        var sps: [[UInt8]] = []
        for _ in 0..<numSPS {
            guard o + 2 <= c.count else { return nil }
            let len = (Int(c[o]) << 8) | Int(c[o + 1]); o += 2
            guard o + len <= c.count else { return nil }
            sps.append(Array(c[o..<(o + len)])); o += len
        }
        guard o < c.count else { return nil }
        let numPPS = Int(c[o]); o += 1
        var pps: [[UInt8]] = []
        for _ in 0..<numPPS {
            guard o + 2 <= c.count else { return nil }
            let len = (Int(c[o]) << 8) | Int(c[o + 1]); o += 2
            guard o + len <= c.count else { return nil }
            pps.append(Array(c[o..<(o + len)])); o += len
        }
        guard !sps.isEmpty, !pps.isEmpty else { return nil }
        return (sps, pps)
    }

    /// An Annex B access unit from the encoder's 4-byte-length sample:
    /// AUD, then SPS + PPS on a keyframe, then the sample's NAL units.
    static func annexB(lengthPrefixed sample: [UInt8], keyframe: Bool,
                       sps: [[UInt8]], pps: [[UInt8]]) -> [UInt8] {
        let start: [UInt8] = [0, 0, 0, 1]
        var au = start + [0x09, 0xF0]
        if keyframe {
            for s in sps { au += start + s }
            for p in pps { au += start + p }
        }
        var o = 0
        while o + 4 <= sample.count {
            let len = (Int(sample[o]) << 24) | (Int(sample[o + 1]) << 16) | (Int(sample[o + 2]) << 8) | Int(sample[o + 3])
            o += 4
            guard len > 0, o + len <= sample.count else { break }
            au += start
            au += sample[o..<(o + len)]
            o += len
        }
        return au
    }
}

// MARK: - Transcode stage (LAN copy with H.264 video)

/// Feeds the HEVC video of each closed TS segment to the phone's video
/// transcoder and keeps the H.264 frames per segment, so the LAN server
/// can rebuild a segment's copy once every frame of its span is back. A
/// segment is complete when a frame at or past the next segment's first
/// PTS has arrived (or the stage was told the source ended). Thread-safe;
/// the transcoder's callbacks arrive through `deliver`.
final class TSLANTranscodeStage: @unchecked Sendable {
    typealias Factory = (CastVideoStreamInfo, CastVideoOutputSpec, Int64,
                         CastVideoTranscodeSink, @escaping CastIngestDelivery) -> CastVideoTranscoding

    /// H.264 High 4.1 for the receiver: 1920x1080 at up to 60 fps.
    static let maxWidth = 1920
    static let maxHeight = 1080
    static let bitrateCap = 10_000_000
    static let keyframeTicks: Int64 = 2 * 90_000

    private let lock = NSLock()
    private let log: (String) -> Void
    private let factory: Factory
    private let deliver: CastIngestDelivery
    private let demuxer = TSHEVCAccessUnitDemuxer()
    private var transcoder: CastVideoTranscoding?
    private var released = false

    private struct Bucket {
        var start: Int64            // first video PTS (unwrapped)
        var end: Int64?             // next segment's start
        var frames: [TSLANVideoReplacer.Frame] = []
        var complete = false
    }
    /// seq -> bucket, in ingest order.
    private var buckets: [(seq: Int, bucket: Bucket)] = []
    private var cache: [Int: Data] = [:]
    private var videoPID = -1
    private var sps: [[UInt8]] = []
    private var pps: [[UInt8]] = []
    private var cc: UInt8 = 0
    private var ptsEpoch: Int64 = 0
    private var lastPTS33: Int64 = -1
    private var anchored = false
    private var framesOut = 0
    private var framesLate = 0
    private(set) var failure: String?
    private(set) var sourceLabel: String?
    private(set) var outputLabel: String?

    /// First seq this stage covers (the LAN playlist lists nothing older).
    private(set) var startSeq = -1

    init(log: @escaping (String) -> Void, factory: @escaping Factory, deliver: @escaping CastIngestDelivery) {
        self.log = log
        self.factory = factory
        self.deliver = deliver
    }

    deinit { transcoder?.release() }

    func release() {
        lock.lock(); released = true; let t = transcoder; transcoder = nil; lock.unlock()
        t?.release()
    }

    /// One closed source segment, in sequence order. `videoPID` is the
    /// program's HEVC PID.
    func ingest(seq: Int, segment: Data, videoPID: Int) {
        lock.lock()
        guard !released, failure == nil else { lock.unlock(); return }
        if startSeq < 0 { startSeq = seq }
        self.videoPID = videoPID
        let aus = demuxer.demux([UInt8](segment), videoPID: videoPID)
        var firstPTS: Int64?
        var toFeed: [(TSHEVCAccessUnitDemuxer.AccessUnit, Int64, Int64)] = []
        for au in aus {
            let dts = unwrap(au.dts33)
            var pts = unwrap33(au.pts33, against: dts)
            if pts < dts { pts = dts }
            if firstPTS == nil, au.keyframe { firstPTS = pts }
            if !anchored {
                guard au.keyframe, demuxer.hasParameterSets else { continue }
                anchored = true
            }
            toFeed.append((au, pts, dts))
        }
        if let firstPTS {
            if let last = buckets.indices.last { buckets[last].bucket.end = firstPTS }
            buckets.append((seq, Bucket(start: firstPTS)))
        }
        // A segment without a keyframe-led AU (not expected on a
        // keyframe-cut ring) extends the previous bucket.
        if transcoder == nil, anchored, !toFeed.isEmpty { buildTranscoder() }
        let t = transcoder
        lock.unlock()
        guard let t else { return }
        for (au, pts, dts) in toFeed {
            t.feed(au.sample, pts: pts, dts: dts, keyframe: au.keyframe, parameterSets: au.parameterSets)
        }
    }

    /// Highest seq whose LAN copy can be produced now (-1 = none).
    var highestCompleteSeq: Int {
        lock.lock(); defer { lock.unlock() }
        return buckets.last(where: { $0.bucket.complete })?.seq ?? -1
    }

    func isComplete(seq: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cache[seq] != nil || buckets.first(where: { $0.seq == seq })?.bucket.complete == true
    }

    /// The LAN copy of `seq` built from `source` (the segment after any
    /// audio rewrite). Nil while the segment's frames are still coming
    /// back or the segment is unknown. `oldestSeq` evicts the cache.
    func produce(seq: Int, source: Data, oldestSeq: Int) -> Data? {
        lock.lock(); defer { lock.unlock() }
        for k in cache.keys where k < oldestSeq { cache[k] = nil }
        buckets.removeAll { $0.seq < oldestSeq - 1 }
        if let cached = cache[seq] { return cached }
        guard let idx = buckets.firstIndex(where: { $0.seq == seq }), buckets[idx].bucket.complete,
              !sps.isEmpty else { return nil }
        let frames = buckets[idx].bucket.frames
        guard let out = TSLANVideoReplacer.replace(segment: [UInt8](source), videoPID: videoPID,
                                                   frames: frames, cc: &cc) else { return nil }
        let data = Data(out)
        cache[seq] = data
        buckets[idx].bucket.frames.removeAll()
        return data
    }

    var stats: String {
        lock.lock(); defer { lock.unlock() }
        return "frames out \(framesOut), late \(framesLate), complete through \(buckets.last(where: { $0.bucket.complete })?.seq ?? -1)"
    }

    // MARK: internals (lock held)

    private func unwrap(_ ts33: Int64) -> Int64 {
        let wrap: Int64 = 1 << 33
        if lastPTS33 >= 0 {
            let d = ts33 - lastPTS33
            if d < -(wrap / 2) { ptsEpoch += wrap } else if d > wrap / 2, ptsEpoch > 0 { ptsEpoch -= wrap }
        }
        lastPTS33 = ts33
        return ptsEpoch + ts33
    }

    private func unwrap33(_ pts33: Int64, against dts: Int64) -> Int64 {
        let wrap: Int64 = 1 << 33
        let base = dts - (dts % wrap)
        var pts = base + pts33
        if pts < dts - wrap / 2 { pts += wrap }
        if pts > dts + wrap / 2 { pts -= wrap }
        return pts
    }

    private func buildTranscoder() {
        guard let info = CastVideoCodecConfig.hevcStreamInfo(sps: demuxer.sps, vps: demuxer.vps) else {
            failure = "HEVC SPS unreadable"
            log("[TS-REMUX] LAN transcode: HEVC SPS unreadable; stage off")
            return
        }
        let size = CastVideoPlan.fit(info.width, info.height, maxWidth: Self.maxWidth, maxHeight: Self.maxHeight)
        let step = (info.fps ?? 0) > 61 ? 2 : 1
        let spec = CastVideoOutputSpec(codec: .h264, width: size.width, height: size.height,
                                       frameStep: step, bitrateCap: Self.bitrateCap, hdr: false)
        sourceLabel = CastVideoPlan.describe(.hevc, width: info.width, height: info.height, fps: info.fps)
            + (info.isHDR ? " HDR" : "")
        outputLabel = CastVideoPlan.describe(.h264, width: size.width, height: size.height, fps: spec.outputFPS(info.fps))
        log("[TS-REMUX] LAN transcode: \(sourceLabel ?? "?") -> \(outputLabel ?? "?")"
            + (info.isHDR ? " SDR BT.709 (tone mapped)" : "") + ", keyframe every 2 s")
        let sink = CastVideoTranscodeSink(
            onFormat: { [weak self] codec, config, w, h in self?.onFormat(codec: codec, config: config, width: w, height: h) },
            onSample: { [weak self] data, pts, keyframe in self?.onSample(data, pts: pts, keyframe: keyframe) },
            onFailure: { [weak self] reason in self?.onFailure(reason) })
        transcoder = factory(info, spec, Self.keyframeTicks, sink, deliver)
    }

    private func onFormat(codec: CastVideoOutputSpec.Codec, config: [UInt8], width: Int, height: Int) {
        lock.lock(); defer { lock.unlock() }
        guard codec == .h264, let sets = TSLANVideoReplacer.parameterSets(avcC: config) else {
            failure = "encoder format unusable (\(codec.displayName))"
            log("[TS-REMUX] LAN transcode: encoder format unusable; stage off")
            return
        }
        sps = sets.sps
        pps = sets.pps
        log("[TS-REMUX] LAN transcode: encoder ready \(width)x\(height), SPS \(sps.first?.count ?? 0) B, PPS \(pps.first?.count ?? 0) B")
    }

    private func onSample(_ data: [UInt8], pts: Int64, keyframe: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard !released, failure == nil, !sps.isEmpty else { return }
        framesOut += 1
        let au = TSLANVideoReplacer.annexB(lengthPrefixed: data, keyframe: keyframe, sps: sps, pps: pps)
        let frame = TSLANVideoReplacer.Frame(accessUnit: au, pts: pts, keyframe: keyframe)
        // The bucket whose span holds this PTS: the last one started at or
        // before it.
        guard let idx = buckets.lastIndex(where: { $0.bucket.start <= pts }) else {
            framesLate += 1
            return
        }
        if cache[buckets[idx].seq] != nil || (buckets[idx].bucket.complete && buckets[idx].bucket.frames.isEmpty) {
            framesLate += 1
            return
        }
        buckets[idx].bucket.frames.append(frame)
        // A frame past a bucket's end completes every earlier bucket.
        for j in 0..<idx where !buckets[j].bucket.complete {
            if let end = buckets[j].bucket.end, pts >= end { buckets[j].bucket.complete = true }
        }
    }

    private func onFailure(_ reason: String) {
        lock.lock(); defer { lock.unlock() }
        failure = reason
        log("[TS-REMUX] LAN transcode failed: \(reason)")
    }
}
