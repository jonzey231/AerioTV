//
//  LiveFMP4Remuxer.swift
//  Aerio
//
//  MPEG-TS to fragmented-MP4 (CMAF) remuxer for the LOCAL live pipeline:
//  the HEVC arm of TSHLSRemuxer. Apple's HLS authoring rules only admit
//  HEVC in fMP4 segments (rule 1.5), so the TS-passthrough segmenter that
//  carries H.264 can never carry a UHD channel; this produces the init +
//  media segments that can. Field driver (2026-08-25, Sky Sports Main
//  Event UHD): mpv's fallback decode of 4K50 HEVC HDR drops up to 334
//  frames per 15s window on an Apple TV 4K; AVPlayer decodes the same
//  stream in silicon via this path.
//
//  Deliberately a SIBLING of CastFMP4Remuxer, not a refactor of it: that
//  file survived a 4h10m hardware soak and its behavior is contractual
//  (Android parity), so its H.264 + transcode-to-AAC pipeline is not
//  touched. The ~120 lines of ISO-BMFF box plumbing they share are
//  duplicated here on purpose; if a third fMP4 producer ever appears,
//  extract the primitives then.
//
//  Differences from the cast pipeline, all deliberate:
//   - Video is HEVC (hvc1 + hvcC), parameter sets kept in-band too so a
//     mid-stream resolution change stays decodable.
//   - Audio is PASSTHROUGH: AC-3 ('ac-3' + dac3), E-AC-3 ('ec-3' + dec3),
//     or ADTS AAC ('mp4a' + esds). No transcode: AVPlayer hands the
//     compressed bitstream to the system pipeline, which is exactly the
//     Atmos/5.1 win the remux engine exists for. (The cast path MUST
//     transcode because a Chromecast web receiver cannot decode AC-3.)
//   - HDR needs no explicit handling here: transfer characteristics
//     (PQ/HLG) and mastering metadata travel in the HEVC VUI and SEI,
//     which ride inside the samples and hvcC untouched.
//
//  Threading contract: everything runs on the owner's serial queue
//  (TSHLSRemuxer.queue). No locks, no @Sendable, matching the TS path.
//

import Foundation

/// A PMT combination this pipeline cannot carry; the owner surfaces the
/// name and falls the session back to mpv.
struct LiveFMP4UnsupportedError: Error, CustomStringConvertible {
    let codecName: String
    var description: String { "unsupported codec: \(codecName)" }
}

final class LiveFMP4Remuxer {

    static let ticksPerSecond: Int64 = 90_000
    private static let tsPacket = 188
    private static let ptsWrap: Int64 = 1 << 33
    private static let videoTrackID = 1
    private static let audioTrackID = 2

    /// Fires once, as soon as VPS/SPS/PPS (and the audio config when the
    /// PMT declares audio) have been seen: ftyp + moov.
    var onInitSegment: ((Data) -> Void)?
    /// One CMAF media segment (moof + mdat), cut on IRAP keyframes.
    /// `durationSeconds` is the video span.
    var onMediaSegment: ((Data, Double) -> Void)?
    var onError: ((LiveFMP4UnsupportedError) -> Void)?
    var onPMT: ((String) -> Void)?
    /// Fires once, after the first segment's worth of samples: the
    /// stream's real geometry, measured frame rate, and whether it is a
    /// 10-bit (HDR-class) mux. The tile uses it to set
    /// AVDisplayManager.preferredDisplayCriteria - a bare AVPlayerLayer
    /// gets NO automatic display-mode match (that is an
    /// AVPlayerViewController perk), so without this the panel stays at
    /// the home-screen 4K SDR 60 no matter what plays.
    var onVideoParameters: ((_ width: Int, _ height: Int, _ fps: Double, _ is10Bit: Bool) -> Void)?

    /// Steady-state cut threshold plus the startup ramp, mirroring the
    /// TS segmenter: the first `rampSegments` cut at `rampSeconds` so
    /// tune-in accumulates a playable window sooner where the feed's
    /// GOP cadence allows it.
    private let targetTicks: Int64
    private let rampTicks: Int64
    private let rampSegments: Int
    private let log: (String) -> Void

    init(targetSegmentSeconds: Double,
         rampSegmentSeconds: Double,
         rampSegments: Int,
         log: @escaping (String) -> Void) {
        self.targetTicks = Int64(targetSegmentSeconds * Double(Self.ticksPerSecond))
        self.rampTicks = Int64(rampSegmentSeconds * Double(Self.ticksPerSecond))
        self.rampSegments = rampSegments
        self.log = log
    }

    // MARK: TS layer state

    private var carry: [UInt8] = []
    private var needResync = true
    private var pmtPID = -1
    private var videoPID = -1
    private var audioPID = -1
    private var audioStreamType = 0
    private var pmtSeen = false
    private var failed = false

    private lazy var videoPES = PESAssembler { [weak self] payload, pts, dts in
        self?.onVideoAccessUnit(payload, pts33: pts, dts33: dts)
    }
    private lazy var audioPES = PESAssembler { [weak self] payload, pts, _ in
        self?.onAudioPES(payload, pts33: pts)
    }

    // MARK: codec config

    private var vps: [UInt8]?
    private var sps: [UInt8]?
    private var pps: [UInt8]?
    private var initSent = false

    /// Parsed audio setup, filled from the first frame header.
    private enum AudioConfig {
        case ac3(sampleRate: Int, channels: Int, dac3: Data)
        case eac3(sampleRate: Int, channels: Int, dec3: Data)
        case aac(sampleRate: Int, channels: Int, asc: [UInt8])
    }
    private var audioConfig: AudioConfig?
    /// Per-frame duration in 90 kHz ticks (AC-3/E-AC-3: 1536 samples,
    /// AAC: 1024 samples, at the track sample rate).
    private var audioFrameTicks: Int64 = 0
    private var audioCarry: [UInt8] = []

    // MARK: timeline + queues

    private var videoClock = PTSUnwrapper90k()
    private var audioClock = PTSUnwrapper90k()
    private var timelineBase: Int64 = -1

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
    private var lastVideoDuration: Int64 = 1_800 // 50 fps fallback for the first delta
    private var sequenceNumber = 0
    private var emittedSegments = 0
    private var videoParamsSent = false
    private var parsedSPSInfo: HEVCSPSInfo?

    // MARK: - Ingest

    /// Feed raw TS bytes off the wire. Joins mid-stream: waits for the
    /// repeating PAT/PMT, so the owner may hand over after it has already
    /// consumed the head of the stream.
    func feed(_ data: Data) {
        guard !failed else { return }
        carry.append(contentsOf: data)
        if needResync {
            guard let sync = Self.findSync(carry) else {
                if carry.count > 4 * 188 { carry.removeFirst(carry.count - 2 * 188) }
                return
            }
            if sync > 0 { carry.removeFirst(sync) }
            needResync = false
        }
        var offset = 0
        while carry.count - offset >= Self.tsPacket {
            if carry[offset] != 0x47 {
                carry.removeFirst(offset)
                needResync = true
                return
            }
            parsePacket(carry, offset)
            if failed { return }
            offset += Self.tsPacket
        }
        carry.removeFirst(offset)
    }

    private func fail(_ name: String) {
        guard !failed else { return }
        failed = true
        onError?(LiveFMP4UnsupportedError(codecName: name))
    }

    // MARK: TS packet / PSI parsing

    private func parsePacket(_ buf: [UInt8], _ off: Int) {
        let pid = (Int(buf[off + 1] & 0x1F) << 8) | Int(buf[off + 2])
        let pusi = (buf[off + 1] & 0x40) != 0
        let afc = (buf[off + 3] >> 4) & 0x03
        guard afc & 0x01 != 0 else { return } // no payload
        var payload = off + 4
        if afc & 0x02 != 0 { payload += 1 + Int(buf[off + 4]) } // adaptation field
        guard payload < off + Self.tsPacket else { return }
        let len = off + Self.tsPacket - payload

        if pid == 0 {
            parsePAT(buf, payload, len, pusi)
        } else if pid == pmtPID, !pmtSeen {
            parsePMT(buf, payload, len, pusi)
        } else if pid == videoPID {
            try? videoPES.feed(buf, payload, len, pusi)
        } else if pid == audioPID {
            try? audioPES.feed(buf, payload, len, pusi)
        }
    }

    private func parsePAT(_ buf: [UInt8], _ start: Int, _ len: Int, _ pusi: Bool) {
        guard pmtPID < 0, pusi, len > 1 else { return }
        let section = start + 1 + Int(buf[start])
        var offset = section + 8
        while offset + 3 < start + len {
            let program = (Int(buf[offset]) << 8) | Int(buf[offset + 1])
            let pid = (Int(buf[offset + 2] & 0x1F) << 8) | Int(buf[offset + 3])
            if program != 0 { pmtPID = pid; return }
            offset += 4
        }
    }

    private func parsePMT(_ buf: [UInt8], _ start: Int, _ len: Int, _ pusi: Bool) {
        guard pusi, len > 1 else { return }
        let section = start + 1 + Int(buf[start])
        guard section + 12 < start + len else { return }
        let sectionLength = (Int(buf[section + 1] & 0x0F) << 8) | Int(buf[section + 2])
        let programInfoLength = (Int(buf[section + 10] & 0x0F) << 8) | Int(buf[section + 11])
        var offset = section + 12 + programInfoLength
        let sectionEnd = min(section + 3 + sectionLength - 4, start + len)

        var video: (pid: Int, type: Int)?
        var audio: (pid: Int, type: Int)?
        while offset + 4 < sectionEnd {
            let streamType = Int(buf[offset])
            let esPID = (Int(buf[offset + 1] & 0x1F) << 8) | Int(buf[offset + 2])
            let esInfoLength = (Int(buf[offset + 3] & 0x0F) << 8) | Int(buf[offset + 4])
            switch streamType {
            case 0x24:
                if video == nil { video = (esPID, streamType) }
            case 0x1B, 0x01, 0x02, 0x10:
                if video == nil { video = (esPID, streamType) }
            case 0x81, 0x87, 0x0F:
                if audio == nil { audio = (esPID, streamType) }
            case 0x03, 0x04, 0x11:
                if audio == nil { audio = (esPID, streamType) }
            default:
                break
            }
            offset += 5 + esInfoLength
        }
        guard let v = video else { return }
        pmtSeen = true
        // This pipeline exists FOR HEVC; anything else was either the TS
        // path's job (H.264) or nobody's (MPEG-2). The owner routes before
        // instantiating, so these are defensive.
        guard v.type == 0x24 else {
            fail(v.type == 0x1B ? "H.264 routed to fMP4 arm" : "MPEG-2 video")
            return
        }
        videoPID = v.pid
        if let a = audio {
            guard a.type == 0x81 || a.type == 0x87 || a.type == 0x0F else {
                fail(a.type == 0x11 ? "AAC-LATM audio" : "MP2 audio")
                return
            }
            audioPID = a.pid
            audioStreamType = a.type
        }
        let audioName = ["none", "AC-3", "E-AC-3", "AAC"][
            audioPID < 0 ? 0 : (audioStreamType == 0x81 ? 1 : (audioStreamType == 0x87 ? 2 : 3))]
        onPMT?("HEVC video PID \(videoPID), audio \(audioName)")
    }

    // MARK: - HEVC video path

    private func onVideoAccessUnit(_ payload: [UInt8], pts33: Int64, dts33: Int64) {
        let nals = Self.splitAnnexB(payload)
        guard !nals.isEmpty else { return }
        var keyframe = false
        for nal in nals {
            let type = Int(nal[nal.startIndex] >> 1) & 0x3F
            switch type {
            case 16...21: keyframe = true // IRAP: BLA/IDR/CRA
            case 32: if vps == nil { vps = Array(nal) }
            case 33: if sps == nil { sps = Array(nal) }
            case 34: if pps == nil { pps = Array(nal) }
            default: break
            }
        }
        maybeEmitInit()
        guard initSent else { return }
        if videoQueue.isEmpty, timelineBase < 0, !keyframe { return }

        let dts = videoClock.unwrap(dts33)
        let pts = Self.unwrapPTSAgainstDTS(pts33, dts)
        if timelineBase < 0 { timelineBase = dts }

        let cutAt = emittedSegments < rampSegments ? rampTicks : targetTicks
        if keyframe, let first = videoQueue.first, dts - first.dts >= cutAt {
            finalizeSegment(cutDTS: dts)
        }
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

    // MARK: - Audio passthrough path

    private func onAudioPES(_ payload: [UInt8], pts33: Int64) {
        let pts = audioClock.unwrap(pts33)
        audioCarry.append(contentsOf: payload)
        switch audioStreamType {
        case 0x81: splitSyncframes(basePTS: pts, eac3: false)
        case 0x87: splitSyncframes(basePTS: pts, eac3: true)
        case 0x0F: splitADTS(basePTS: pts)
        default: break
        }
    }

    /// Chop the carried AC-3/E-AC-3 bytes into whole syncframes. One
    /// syncframe = 1536 PCM samples = one fMP4 sample. The PES PTS stamps
    /// the FIRST frame that STARTS in this PES; successors advance by the
    /// fixed frame duration, which is how every TS muxer spaces them.
    private func splitSyncframes(basePTS: Int64, eac3: Bool) {
        var pts = basePTS
        var i = 0
        while audioCarry.count - i >= 8 {
            guard audioCarry[i] == 0x0B, audioCarry[i + 1] == 0x77 else { i += 1; continue }
            let frameSize = eac3
                ? Self.eac3FrameSize(audioCarry, i)
                : Self.ac3FrameSize(audioCarry, i)
            guard let size = frameSize, size >= 8 else { i += 1; continue }
            guard audioCarry.count - i >= size else { break } // partial tail
            if audioConfig == nil {
                configureDolby(Array(audioCarry[i..<(i + size)]), eac3: eac3)
                guard audioConfig != nil else { i += size; continue }
                maybeEmitInit()
            }
            audioQueue.append(AudioSample(data: Array(audioCarry[i..<(i + size)]), pts: pts))
            pts += audioFrameTicks
            i += size
        }
        audioCarry.removeFirst(i)
        trimAudioCarry()
    }

    private func splitADTS(basePTS: Int64) {
        var pts = basePTS
        var i = 0
        while audioCarry.count - i >= 7 {
            guard audioCarry[i] == 0xFF, (audioCarry[i + 1] & 0xF0) == 0xF0 else { i += 1; continue }
            let protectionAbsent = audioCarry[i + 1] & 0x01
            let headerLen = protectionAbsent == 1 ? 7 : 9
            let frameLen = (Int(audioCarry[i + 3] & 0x03) << 11)
                | (Int(audioCarry[i + 4]) << 3)
                | (Int(audioCarry[i + 5]) >> 5)
            guard frameLen > headerLen else { i += 1; continue }
            guard audioCarry.count - i >= frameLen else { break }
            if audioConfig == nil {
                let objectType = (Int(audioCarry[i + 2]) >> 6) + 1
                let freqIndex = (Int(audioCarry[i + 2]) >> 2) & 0x0F
                let channels = ((Int(audioCarry[i + 2]) & 0x01) << 2) | (Int(audioCarry[i + 3]) >> 6)
                let rates = [96000, 88200, 64000, 48000, 44100, 32000,
                             24000, 22050, 16000, 12000, 11025, 8000, 7350]
                guard freqIndex < rates.count, channels > 0 else { i += frameLen; continue }
                let rate = rates[freqIndex]
                let asc: [UInt8] = [UInt8((objectType << 3) | (freqIndex >> 1)),
                                    UInt8(((freqIndex & 1) << 7) | (channels << 3))]
                audioConfig = .aac(sampleRate: rate, channels: channels, asc: asc)
                audioFrameTicks = 1024 * Self.ticksPerSecond / Int64(rate)
                log("[FMP4] audio: AAC \(rate)Hz \(channels)ch (passthrough)")
                maybeEmitInit()
            }
            let start = i + headerLen
            audioQueue.append(AudioSample(data: Array(audioCarry[start..<(i + frameLen)]), pts: pts))
            pts += audioFrameTicks
            i += frameLen
        }
        audioCarry.removeFirst(i)
        trimAudioCarry()
    }

    /// A corrupt stretch must not grow the carry without bound.
    private func trimAudioCarry() {
        if audioCarry.count > 64 * 1024 { audioCarry.removeAll(keepingCapacity: true) }
    }

    // MARK: Dolby frame headers

    /// AC-3 (ETSI TS 102 366 4.3): frame bytes from fscod + frmsizecod.
    private static let ac3BitrateKbps = [
        32, 32, 40, 40, 48, 48, 56, 56, 64, 64, 80, 80, 96, 96, 112, 112,
        128, 128, 160, 160, 192, 192, 224, 224, 256, 256, 320, 320, 384, 384,
        448, 448, 512, 512, 576, 576, 640, 640,
    ]

    private static func ac3FrameSize(_ b: [UInt8], _ i: Int) -> Int? {
        guard b.count - i >= 5 else { return nil }
        let fscod = Int(b[i + 4]) >> 6
        let frmsizecod = Int(b[i + 4]) & 0x3F
        guard frmsizecod < ac3BitrateKbps.count else { return nil }
        let rate = ac3BitrateKbps[frmsizecod]
        switch fscod {
        case 0: return rate * 4                                      // 48 kHz
        case 1: return (rate * 1000 * 1536 / 44100 / 16 + (frmsizecod & 1)) * 2 // 44.1 kHz
        case 2: return rate * 6                                      // 32 kHz
        default: return nil
        }
    }

    private static func eac3FrameSize(_ b: [UInt8], _ i: Int) -> Int? {
        guard b.count - i >= 5 else { return nil }
        let frmsiz = (Int(b[i + 2] & 0x07) << 8) | Int(b[i + 3])
        return (frmsiz + 1) * 2
    }

    /// Parse the first syncframe's BSI for the sample entry + dac3/dec3.
    private func configureDolby(_ frame: [UInt8], eac3: Bool) {
        var r = BitReader90k(Array(frame.dropFirst(2))) // past 0x0B77
        do {
            if eac3 {
                _ = try r.bits(2)  // strmtyp
                _ = try r.bits(3)  // substreamid
                let frmsiz = try r.bits(11)
                let fscod = try r.bits(2)
                var sampleRate = [48000, 44100, 32000, 0][fscod]
                var numblks = 6
                if fscod == 3 {
                    let fscod2 = try r.bits(2)
                    sampleRate = [24000, 22050, 16000, 0][fscod2]
                } else {
                    numblks = [1, 2, 3, 6][try r.bits(2)]
                }
                guard sampleRate > 0 else { return }
                let acmod = try r.bits(3)
                let lfeon = try r.bits(1)
                let channels = Self.ac3Channels(acmod: acmod, lfeon: lfeon)
                // dec3: data_rate(13) num_ind_sub-1(3); per sub:
                // fscod(2) bsid(5) reserved(1) asvc(1) bsmod(3) acmod(3)
                // lfeon(1) reserved(3) num_dep_sub(4) reserved(1)
                let dataRateKbps = min(8191, ((frmsiz + 1) * 2 * sampleRate) / (numblks * 256) * 8 / 1000)
                var body = Data()
                body.append(Self.u16((dataRateKbps << 3) | 0)) // one independent substream
                let a = (0 << 6) | (16 << 1) | 0 // fscod placeholder below
                _ = a
                var sub = 0
                sub |= fscod << 14
                sub |= 16 << 9        // bsid 16
                sub |= 0 << 8         // reserved/asvc
                sub |= 0 << 5         // bsmod
                sub |= acmod << 1
                sub |= lfeon
                body.append(Self.u16(sub << 0))
                body.append(0) // num_dep_sub(4)=0 + reserved
                audioConfig = .eac3(sampleRate: sampleRate, channels: channels,
                                    dec3: Self.box("dec3", body))
                audioFrameTicks = Int64(numblks * 256) * Self.ticksPerSecond / Int64(sampleRate)
                log("[FMP4] audio: E-AC-3 \(sampleRate)Hz \(channels)ch (passthrough)")
            } else {
                _ = try r.bits(16) // crc1
                let fscod = try r.bits(2)
                _ = try r.bits(6)  // frmsizecod
                let bsid = try r.bits(5)
                let bsmod = try r.bits(3)
                let acmod = try r.bits(3)
                if (acmod & 0x1) != 0, acmod != 0x1 { _ = try r.bits(2) } // cmixlev
                if (acmod & 0x4) != 0 { _ = try r.bits(2) }               // surmixlev
                if acmod == 0x2 { _ = try r.bits(2) }                     // dsurmod
                let lfeon = try r.bits(1)
                let frmsizecod = Int(frame[4]) & 0x3F
                let sampleRate = [48000, 44100, 32000, 0][fscod]
                guard sampleRate > 0 else { return }
                let channels = Self.ac3Channels(acmod: acmod, lfeon: lfeon)
                // dac3: fscod(2) bsid(5) bsmod(3) acmod(3) lfeon(1)
                // bit_rate_code(5) reserved(5)
                var v = 0
                v |= fscod << 22
                v |= bsid << 17
                v |= bsmod << 14
                v |= acmod << 11
                v |= lfeon << 10
                v |= (frmsizecod >> 1) << 5
                let body = Data([UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
                audioConfig = .ac3(sampleRate: sampleRate, channels: channels,
                                   dac3: Self.box("dac3", body))
                audioFrameTicks = 1536 * Self.ticksPerSecond / Int64(sampleRate)
                log("[FMP4] audio: AC-3 \(sampleRate)Hz \(channels)ch (passthrough)")
            }
        } catch {
            // Malformed first frame: try again on the next one.
            audioConfig = nil
        }
    }

    private static func ac3Channels(acmod: Int, lfeon: Int) -> Int {
        let front = [2, 1, 2, 3, 3, 4, 4, 5][acmod]
        return front + lfeon
    }

    // MARK: - Segmenter

    private func maybeEmitInit() {
        guard !initSent, pmtSeen, sps != nil, pps != nil, vps != nil else { return }
        guard audioPID < 0 || audioConfig != nil else { return }
        onInitSegment?(buildInitSegment())
        initSent = true
    }

    private func finalizeSegment(cutDTS: Int64) {
        guard !videoQueue.isEmpty else { return }
        let segStart = videoQueue[0].dts
        var durations = [Int64](repeating: 0, count: videoQueue.count)
        for i in videoQueue.indices {
            let next = i + 1 < videoQueue.count ? videoQueue[i + 1].dts : cutDTS
            var d = next - videoQueue[i].dts
            if d <= 0 { d = lastVideoDuration }
            durations[i] = d
            lastVideoDuration = d
        }
        var segAudio: [AudioSample] = []
        var keepAudio: [AudioSample] = []
        for a in audioQueue {
            if a.pts < cutDTS {
                // Audio that predates the video timeline belongs to the
                // mid-GOP video we dropped waiting for the first IRAP; a
                // GOP's worth piles up during tune-in. Shipping it shifts
                // the WHOLE audio track late by that pile (the tfdt clamp
                // hid the negative offset) - heard on device 2026-08-25 as
                // a constant 3-5s A/V desync on the fMP4 arm. Discard it;
                // the matching video was never sent either.
                if a.pts >= timelineBase { segAudio.append(a) }
            } else {
                keepAudio.append(a)
            }
        }
        if !videoParamsSent, let info = parsedSPSInfo, durations.count >= 8 {
            videoParamsSent = true
            let sorted = durations.sorted()
            let median = Double(sorted[sorted.count / 2])
            let fps = median > 0 ? Double(Self.ticksPerSecond) / median : 0
            log("[FMP4] video: \(info.width)x\(info.height) \(String(format: "%.2f", fps))fps \(info.bitDepthLuma)-bit")
            onVideoParameters?(info.width, info.height, fps, info.bitDepthLuma > 8)
        }
        let segment = buildMediaSegment(video: videoQueue, videoDurations: durations, audio: segAudio)
        let durationTicks = cutDTS - segStart
        videoQueue.removeAll(keepingCapacity: true)
        audioQueue = keepAudio
        emittedSegments += 1
        onMediaSegment?(segment, Double(durationTicks) / Double(Self.ticksPerSecond))
    }

    // MARK: - fMP4 writing

    private func buildInitSegment() -> Data {
        let dims = (try? Self.parseHEVCSPS(sps!)) ?? HEVCSPSInfo.fallback
        parsedSPSInfo = dims
        var out = Data(capacity: 1500)
        out.append(Self.box("ftyp", Self.bytes("iso5"), Self.u32(0),
                            Self.bytes("iso5"), Self.bytes("iso6"), Self.bytes("mp41")))
        var traks = [videoTrak(info: dims)]
        if audioConfig != nil { traks.append(audioTrak()) }
        var trexes = [Self.trex(Self.videoTrackID)]
        if audioConfig != nil { trexes.append(Self.trex(Self.audioTrackID)) }
        out.append(Self.box("moov",
                            Self.mvhd(nextTrackID: audioConfig != nil ? 3 : 2),
                            Self.concat(traks),
                            Self.box("mvex", Self.concat(trexes))))
        log("[FMP4] init segment: HEVC \(dims.width)x\(dims.height), \(out.count) bytes")
        return out
    }

    private func videoTrak(info: HEVCSPSInfo) -> Data {
        let v = vps!, s = sps!, p = pps!
        // hvcC (ISO 14496-15 8.3.3.1), fields from the SPS
        // profile_tier_level so VideoToolbox sees the true profile/level
        // (Main 10 for HDR).
        var c = Data(capacity: 40 + v.count + s.count + p.count)
        c.append(1) // configurationVersion
        c.append(UInt8((info.profileSpace << 6) | (info.tierFlag << 5) | info.profileIDC))
        c.append(contentsOf: info.compatFlags)     // 4 bytes
        c.append(contentsOf: info.constraintFlags) // 6 bytes
        c.append(UInt8(info.levelIDC))
        c.append(Self.u16(0xF000)) // min_spatial_segmentation_idc = 0
        c.append(0xFC)             // parallelismType = 0
        c.append(UInt8(0xFC | info.chromaFormatIDC))
        c.append(UInt8(0xF8 | (info.bitDepthLuma - 8)))
        c.append(UInt8(0xF8 | (info.bitDepthChroma - 8)))
        c.append(Self.u16(0))      // avgFrameRate
        c.append(UInt8((0 << 6) | (info.numTemporalLayers << 3) | (info.temporalIdNested << 2) | 3))
        c.append(3) // numOfArrays
        for (type, nal) in [(32, v), (33, s), (34, p)] {
            c.append(UInt8(0x80 | type)) // array_completeness = 1
            c.append(Self.u16(1))
            c.append(Self.u16(nal.count))
            c.append(contentsOf: nal)
        }
        let hvcC = Self.box("hvcC", c)

        var entry = Data(capacity: 96 + hvcC.count)
        entry.append(Data(count: 6)); entry.append(Self.u16(1))
        entry.append(Data(count: 16))
        entry.append(Self.u16(info.width)); entry.append(Self.u16(info.height))
        entry.append(Self.u32(0x00480000)); entry.append(Self.u32(0x00480000))
        entry.append(Self.u32(0)); entry.append(Self.u16(1))
        entry.append(Data(count: 32))
        entry.append(Self.u16(0x0018)); entry.append(Self.u16(0xFFFF))
        entry.append(hvcC)
        let hvc1 = Self.box("hvc1", entry)
        return Self.trak(trackID: Self.videoTrackID, width: info.width, height: info.height,
                         volume: 0, handler: "vide", handlerName: "VideoHandler",
                         mediaHeader: Self.fullBox("vmhd", 0, 1, Self.u16(0), Self.u16(0), Self.u16(0), Self.u16(0)),
                         sampleEntry: hvc1)
    }

    private func audioTrak() -> Data {
        guard let config = audioConfig else { return Data() }
        let sampleRate: Int
        let channels: Int
        let entry: Data
        switch config {
        case let .ac3(rate, ch, dac3):
            sampleRate = rate; channels = ch
            entry = Self.box("ac-3", Self.audioSampleEntryBody(channels: ch, sampleRate: rate), dac3)
        case let .eac3(rate, ch, dec3):
            sampleRate = rate; channels = ch
            entry = Self.box("ec-3", Self.audioSampleEntryBody(channels: ch, sampleRate: rate), dec3)
        case let .aac(rate, ch, asc):
            sampleRate = rate; channels = ch
            // esds: ES_Descriptor > DecoderConfig (0x40 AAC) > DecSpecificInfo(ASC)
            var dsi = Data([0x05, UInt8(asc.count)]); dsi.append(contentsOf: asc)
            var dcd = Data([0x04, UInt8(13 + dsi.count), 0x40, 0x15])
            dcd.append(Data(count: 3))          // bufferSizeDB
            dcd.append(Self.u32(0)); dcd.append(Self.u32(0)) // max/avg bitrate
            dcd.append(dsi)
            var esd = Data([0x03, UInt8(3 + dcd.count + 3), 0x00, 0x00, 0x00])
            esd.append(dcd)
            esd.append(Data([0x06, 0x01, 0x02])) // SLConfig
            entry = Self.box("mp4a", Self.audioSampleEntryBody(channels: ch, sampleRate: rate),
                             Self.fullBox("esds", 0, 0, esd))
        }
        _ = sampleRate
        _ = channels
        return Self.trak(trackID: Self.audioTrackID, width: 0, height: 0, volume: 0x0100,
                         handler: "soun", handlerName: "SoundHandler",
                         mediaHeader: Self.fullBox("smhd", 0, 0, Self.u16(0), Self.u16(0)),
                         sampleEntry: entry)
    }

    private static func audioSampleEntryBody(channels: Int, sampleRate: Int) -> Data {
        var b = Data(capacity: 28)
        b.append(Data(count: 6)); b.append(u16(1)) // reserved, data_reference_index
        b.append(Data(count: 8))                   // reserved
        b.append(u16(channels)); b.append(u16(16)) // channelcount, samplesize
        b.append(u32(0))                           // pre_defined, reserved
        b.append(u32(sampleRate << 16))
        return b
    }

    private func buildMediaSegment(video: [VideoSample], videoDurations: [Int64], audio: [AudioSample]) -> Data {
        let videoBytes = video.reduce(0) { $0 + $1.data.count }
        let audioBytes = audio.reduce(0) { $0 + $1.data.count }
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
        var body = Data(capacity: 16 + audio.count * 8)
        body.append(Self.u32(audio.count))
        body.append(Self.u32(dataOffset))
        for a in audio {
            body.append(Self.u32(Int(audioFrameTicks)))
            body.append(Self.u32(a.data.count))
        }
        return Self.fullBox("trun", 0, 0x000301, body)
    }

    // MARK: - HEVC SPS parsing

    struct HEVCSPSInfo {
        var width: Int
        var height: Int
        var profileSpace: Int
        var tierFlag: Int
        var profileIDC: Int
        var compatFlags: [UInt8]     // 4
        var constraintFlags: [UInt8] // 6
        var levelIDC: Int
        var chromaFormatIDC: Int
        var bitDepthLuma: Int
        var bitDepthChroma: Int
        var numTemporalLayers: Int
        var temporalIdNested: Int

        /// 4K Main 10 guess if the SPS refuses to parse; the in-band
        /// parameter sets still carry the truth for the decoder.
        static let fallback = HEVCSPSInfo(
            width: 3840, height: 2160, profileSpace: 0, tierFlag: 0, profileIDC: 2,
            compatFlags: [0x20, 0, 0, 0], constraintFlags: [0x90, 0, 0, 0, 0, 0],
            levelIDC: 153, chromaFormatIDC: 1, bitDepthLuma: 10, bitDepthChroma: 10,
            numTemporalLayers: 1, temporalIdNested: 0)
    }

    private struct ParseError: Error {}

    static func parseHEVCSPS(_ nal: [UInt8]) throws -> HEVCSPSInfo {
        // Strip the 2-byte NAL header, remove emulation prevention.
        var rbsp = [UInt8]()
        rbsp.reserveCapacity(nal.count)
        var i = 2
        while i < nal.count {
            if i + 2 < nal.count, nal[i] == 0, nal[i + 1] == 0, nal[i + 2] == 3 {
                rbsp.append(0); rbsp.append(0); i += 3
            } else {
                rbsp.append(nal[i]); i += 1
            }
        }
        var r = BitReader90k(rbsp)
        _ = try r.bits(4) // sps_video_parameter_set_id
        let maxSubLayersMinus1 = try r.bits(3)
        let nesting = try r.bits(1)
        // profile_tier_level(1, maxSubLayersMinus1)
        let profileSpace = try r.bits(2)
        let tier = try r.bits(1)
        let profileIDC = try r.bits(5)
        var compat = [UInt8](); for _ in 0..<4 { compat.append(UInt8(try r.bits(8))) }
        var constraint = [UInt8](); for _ in 0..<6 { constraint.append(UInt8(try r.bits(8))) }
        let level = try r.bits(8)
        var subProfilePresent = [Bool](); var subLevelPresent = [Bool]()
        for _ in 0..<maxSubLayersMinus1 {
            subProfilePresent.append(try r.bits(1) == 1)
            subLevelPresent.append(try r.bits(1) == 1)
        }
        if maxSubLayersMinus1 > 0 {
            for _ in maxSubLayersMinus1..<8 { _ = try r.bits(2) }
        }
        for j in 0..<maxSubLayersMinus1 {
            if subProfilePresent[j] { _ = try r.bits(88) }
            if subLevelPresent[j] { _ = try r.bits(8) }
        }
        _ = try r.ue() // sps_seq_parameter_set_id
        let chroma = try r.ue()
        if chroma == 3 { _ = try r.bits(1) }
        var width = try r.ue()
        var height = try r.ue()
        if try r.bits(1) == 1 { // conformance_window
            let l = try r.ue(), rt = try r.ue(), t = try r.ue(), b = try r.ue()
            let subWidthC = (chroma == 1 || chroma == 2) ? 2 : 1
            let subHeightC = chroma == 1 ? 2 : 1
            width -= (l + rt) * subWidthC
            height -= (t + b) * subHeightC
        }
        let bitDepthLuma = try r.ue() + 8
        let bitDepthChroma = try r.ue() + 8
        guard width > 0, height > 0, width <= 8192, height <= 8192,
              bitDepthLuma >= 8, bitDepthLuma <= 16 else { throw ParseError() }
        return HEVCSPSInfo(
            width: width, height: height, profileSpace: profileSpace, tierFlag: tier,
            profileIDC: profileIDC, compatFlags: compat, constraintFlags: constraint,
            levelIDC: level, chromaFormatIDC: chroma,
            bitDepthLuma: bitDepthLuma, bitDepthChroma: bitDepthChroma,
            numTemporalLayers: maxSubLayersMinus1 + 1, temporalIdNested: nesting)
    }

    // MARK: - Shared TS/PES machinery (sibling of CastFMP4Remuxer's)

    private final class PESAssembler {
        private var buffer: [UInt8] = []
        private var pts: Int64 = -1
        private var dts: Int64 = -1
        private let onUnit: ([UInt8], Int64, Int64) throws -> Void

        init(onUnit: @escaping ([UInt8], Int64, Int64) throws -> Void) {
            self.onUnit = onUnit
        }

        func feed(_ data: [UInt8], _ start: Int, _ len: Int, _ pusi: Bool) throws {
            if pusi {
                try flush()
                guard len >= 9,
                      data[start] == 0, data[start + 1] == 0, data[start + 2] == 1 else { return }
                let flags = data[start + 7]
                let headerLen = Int(data[start + 8])
                var newPTS: Int64 = -1
                var newDTS: Int64 = -1
                if flags & 0x80 != 0, len >= 14 {
                    newPTS = Self.readTimestamp(data, start + 9)
                    newDTS = newPTS
                    if flags & 0x40 != 0, len >= 19 {
                        newDTS = Self.readTimestamp(data, start + 14)
                    }
                }
                pts = newPTS
                dts = newDTS
                let payloadStart = start + 9 + headerLen
                if payloadStart < start + len {
                    buffer.append(contentsOf: data[payloadStart..<(start + len)])
                }
            } else if pts >= 0 {
                buffer.append(contentsOf: data[start..<(start + len)])
            }
        }

        func flush() throws {
            guard !buffer.isEmpty, pts >= 0 else { buffer.removeAll(keepingCapacity: true); return }
            let unit = buffer
            buffer.removeAll(keepingCapacity: true)
            try onUnit(unit, pts, dts >= 0 ? dts : pts)
        }

        private static func readTimestamp(_ b: [UInt8], _ off: Int) -> Int64 {
            (Int64(b[off] & 0x0E) << 29)
                | (Int64(b[off + 1]) << 22)
                | (Int64(b[off + 2] & 0xFE) << 14)
                | (Int64(b[off + 3]) << 7)
                | (Int64(b[off + 4]) >> 1)
        }
    }

    struct PTSUnwrapper90k {
        private var last: Int64 = -1
        private var epoch: Int64 = 0

        mutating func unwrap(_ ts33: Int64) -> Int64 {
            if last >= 0 {
                let prev33 = last % LiveFMP4Remuxer.ptsWrap
                if ts33 < prev33 - LiveFMP4Remuxer.ptsWrap / 2 { epoch += 1 }
            }
            let v = epoch * LiveFMP4Remuxer.ptsWrap + ts33
            last = v
            return v
        }
    }

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

    struct BitReader90k {
        private let data: [UInt8]
        private var pos = 0

        init(_ data: [UInt8]) { self.data = data }

        mutating func bits(_ n: Int) throws -> Int {
            var v = 0
            for _ in 0..<n {
                let byteIndex = pos >> 3
                guard byteIndex < data.count else { throw LiveFMP4ParseError() }
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
    }

    struct LiveFMP4ParseError: Error {}

    // MARK: box plumbing (sibling of CastFMP4Remuxer's; see file header)

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
        return Data([UInt8((u >> 24) & 0xFF), UInt8((u >> 16) & 0xFF),
                     UInt8((u >> 8) & 0xFF), UInt8(u & 0xFF)])
    }

    private static func u64(_ v: UInt64) -> Data {
        u32(Int(truncatingIfNeeded: Int64(bitPattern: v >> 32)))
            + u32(Int(truncatingIfNeeded: Int64(bitPattern: v & 0xFFFF_FFFF)))
    }

    private static func mvhd(nextTrackID: Int) -> Data {
        fullBox("mvhd", 0, 0,
                u32(0), u32(0),
                u32(Int(ticksPerSecond)), u32(0),
                u32(0x00010000), u16(0x0100), u16(0), u32(0), u32(0),
                matrix(),
                Data(count: 24),
                u32(nextTrackID))
    }

    private static func matrix() -> Data {
        var out = Data(capacity: 36)
        for v in [0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x40000000] { out.append(u32(v)) }
        return out
    }

    private static func trak(trackID: Int, width: Int, height: Int, volume: Int,
                             handler: String, handlerName: String,
                             mediaHeader: Data, sampleEntry: Data) -> Data {
        let tkhd = fullBox(
            "tkhd", 0, 7,
            u32(0), u32(0), u32(trackID), u32(0), u32(0),
            u32(0), u32(0),
            u16(0), u16(0), u16(volume), u16(0),
            matrix(),
            u32(width << 16), u32(height << 16))
        let mdhd = fullBox(
            "mdhd", 0, 0,
            u32(0), u32(0), u32(Int(ticksPerSecond)), u32(0),
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
