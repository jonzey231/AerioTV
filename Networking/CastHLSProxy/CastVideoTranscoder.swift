//
//  CastVideoTranscoder.swift
//  Aerio
//
//  Cast HLS proxy: on-phone video transcode for H.264 the receiver cannot
//  present at full rate (2026-09-26).
//
//  Measured on a Chromecast Ultra: its Cast runtime decodes H.264 1080p at
//  about 47 frames per second on every path (MSE and native), so 1080p50/60
//  H.264 plays at 0.66x to 0.93x. The same device answers canDisplayType
//  true for H.264 1080p30 and for avc1.640029. So the phone decodes the
//  source with the platform hardware decoder and re-encodes with the
//  platform hardware encoder (VideoToolbox only; no third-party encoder),
//  into one of two output profiles chosen from the receiver's caps:
//
//   - HEVC Main at the source resolution and frame rate, when the receiver
//     presents HEVC 1080p60 (`display.hevc_1080p60`, or MSE `hvc1`).
//   - H.264 High level 4.1, when it does not: 1280x720 at the source frame
//     rate (the default, keeps sports motion) or the source resolution at
//     half the frame rate (Developer picker "1080p30").
//
//  The output rides the same demuxed fMP4 HLS the receiver already plays;
//  the audio path is untouched.
//
//  File layout: the pure pieces (stream info, receiver caps, the plan and
//  its decision, codec strings, hvcC building) come first and compile in
//  the CLI tests; the VideoToolbox session wrapper is last.
//

import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

// MARK: - Source stream info

/// What the remuxer learned from the source H.264 SPS (see
/// `CastFMP4Remuxer.parseSPSInfo`).
struct CastH264StreamInfo: Sendable, Equatable {
    var width: Int
    var height: Int
    var profileIDC: Int
    var constraintFlags: Int
    var levelIDC: Int
    /// frame_mbs_only_flag: false for PAFF / MBAFF interlaced coding.
    var progressive: Bool = true
    /// Frames per second from the VUI timing info, nil when absent.
    var fps: Double?
    var fullRange: Bool = false
    var colourPrimaries: Int?
    var transferCharacteristics: Int?
    var matrixCoefficients: Int?
    /// VUI bitstream_restriction max_num_reorder_frames, nil when absent.
    var maxNumReorderFrames: Int?

    /// RFC 6381 avc1 string from the SPS header bytes.
    var codecString: String {
        String(format: "avc1.%02X%02X%02X", profileIDC & 0xFF, constraintFlags & 0xFF, levelIDC & 0xFF)
    }

    /// "4.1" for level_idc 41.
    var levelLabel: String { "\(levelIDC / 10).\(levelIDC % 10)" }

    /// "1920x1080@59.94", or "@?" without VUI timing.
    var label: String { "\(width)x\(height)@\(fps.map(CastVideoPlan.fpsLabel) ?? "?")" }
}

// MARK: - Receiver caps

/// The receiver's own measurement of what it can decode (`mse`, from
/// MediaSource.isTypeSupported) and PRESENT (`display`, from
/// cast.framework canDisplayType). Missing keys read as false.
struct CastReceiverVideoCaps: Sendable, Equatable {
    var mse: [String: Bool]
    /// nil when the receiver page sent no `display` map at all (an older
    /// page); the plan then never transcodes on its own.
    var display: [String: Bool]?

    func mse(_ key: String) -> Bool { mse[key] == true }
    func display(_ key: String) -> Bool { display?[key] == true }

    /// HEVC at 1080p60 is presentable.
    var hevc1080: Bool { display("hevc_1080p60") || mse("hvc1") }
    /// HEVC at 4K60 is presentable.
    var hevc4K: Bool { display("hevc_4k60") || mse("hvc1.4k") }
}

/// Developer picker `castTranscodeDownProfile`: the H.264 output shape when
/// the receiver cannot present HEVC.
enum CastTranscodeDownProfile: String, Sendable, CaseIterable {
    /// 1280x720 at the source frame rate (default: keeps sports motion).
    case p720p60 = "720p60"
    /// Source resolution (at most 1920x1080) at half the frame rate for
    /// 50/60p sources: every other presented frame is encoded.
    case p1080p30 = "1080p30"
}

/// One transcode output.
struct CastVideoOutputSpec: Sendable, Equatable {
    enum Codec: Sendable, Equatable { case hevc, h264 }
    var codec: Codec
    var width: Int
    var height: Int
    /// 1 keeps every frame; 2 encodes every other presented frame.
    var frameStep: Int
    /// Upper bound on the encoder's average bit rate, bits per second.
    /// The encoder runs at min(measured source rate, this).
    var bitrateCap: Int

    static let hevc1080Cap = 12_000_000
    static let hevc4KCap = 25_000_000
    static let h264Cap = 8_000_000
    /// H.264 High level 4.1 (profile_idc 100, level_idc 41).
    static let h264Level41 = 41

    func outputFPS(_ sourceFPS: Double?) -> Double? {
        sourceFPS.map { $0 / Double(max(1, frameStep)) }
    }
}

/// The plan's answer for one source.
struct CastVideoDecision: Sendable, Equatable {
    /// nil means H.264 passthrough.
    var output: CastVideoOutputSpec?
    /// Why (passthrough) or what triggered the transcode.
    var reason: String
}

/// Everything the remuxer needs to decide the video path once it has seen
/// the source SPS. Built by the cast sender from the receiver caps and the
/// Developer switches; the session overrides it with `disabledReason` after
/// a VideoToolbox failure.
struct CastVideoPlan: Sendable, Equatable {
    var caps: CastReceiverVideoCaps?
    /// Developer switch `castForceHEVCTranscode`: transcode any H.264
    /// source, HEVC when the receiver presents it, else the H.264 profile.
    var force: Bool = false
    var downProfile: CastTranscodeDownProfile = .p720p60
    /// Set by the session after a VideoToolbox failure: passthrough for the
    /// rest of the session.
    var disabledReason: String?

    static let passthrough = CastVideoPlan(caps: nil)

    /// The decision rule. Pure; unit-tested.
    ///
    /// 1. A source the receiver presents as H.264 passes through: anything
    ///    up to 1280x720 at any rate (a lower pixel rate than 1080p30), 1080
    ///    at up to 30 fps when `display.h264_1080p30`, 1080 at any rate when
    ///    `display.h264_1080p60`, 4K when `display.h264_4k60`.
    /// 2. Otherwise HEVC at the source size when the receiver presents HEVC
    ///    at that size (a 4K source falls to 1080 HEVC when only 1080 HEVC
    ///    is presentable).
    /// 3. Otherwise H.264 High 4.1 in the Developer down profile.
    /// The force switch skips rule 1. Without a `display` map (an older
    /// receiver page) the plan passes through unless forced.
    func decide(_ s: CastH264StreamInfo) -> CastVideoDecision {
        if let disabledReason { return CastVideoDecision(output: nil, reason: disabledReason) }
        let caps = self.caps ?? CastReceiverVideoCaps(mse: [:], display: nil)
        if !force {
            if self.caps == nil { return CastVideoDecision(output: nil, reason: "receiver caps not measured") }
            if caps.display == nil { return CastVideoDecision(output: nil, reason: "receiver sent no display caps") }
        }
        let is4K = s.width > 1920 || s.height > 1088
        let is1080 = !is4K && (s.width > 1280 || s.height > 720)
        // No VUI timing: level 4.1 and up is the 1080p50/60 class.
        let fps = s.fps ?? (s.levelIDC > 40 ? 60 : 30)
        let highRate = fps > 31
        let fits: Bool
        if is4K {
            fits = caps.display("h264_4k60")
        } else if is1080 {
            fits = caps.display("h264_1080p60") || (!highRate && caps.display("h264_1080p30"))
        } else {
            fits = true
        }
        if fits && !force {
            return CastVideoDecision(output: nil, reason: "receiver displays the source")
        }
        let trigger = force ? "Developer switch" : "source above receiver display"
        if is4K && caps.hevc4K {
            return CastVideoDecision(
                output: CastVideoOutputSpec(codec: .hevc, width: even(s.width), height: even(s.height),
                                            frameStep: 1, bitrateCap: CastVideoOutputSpec.hevc4KCap),
                reason: trigger)
        }
        if caps.hevc1080 {
            let size = Self.fit(s.width, s.height, maxWidth: 1920, maxHeight: 1080)
            return CastVideoDecision(
                output: CastVideoOutputSpec(codec: .hevc, width: size.width, height: size.height,
                                            frameStep: 1, bitrateCap: CastVideoOutputSpec.hevc1080Cap),
                reason: trigger)
        }
        // 1080p30 needs the receiver to present 1080p30; otherwise 720p.
        let profile: CastTranscodeDownProfile =
            (downProfile == .p1080p30 && (caps.display("h264_1080p30") || caps.display == nil))
            ? .p1080p30 : .p720p60
        switch profile {
        case .p720p60:
            let size = Self.fit(s.width, s.height, maxWidth: 1280, maxHeight: 720)
            return CastVideoDecision(
                output: CastVideoOutputSpec(codec: .h264, width: size.width, height: size.height,
                                            frameStep: 1, bitrateCap: CastVideoOutputSpec.h264Cap),
                reason: trigger)
        case .p1080p30:
            let size = Self.fit(s.width, s.height, maxWidth: 1920, maxHeight: 1080)
            return CastVideoDecision(
                output: CastVideoOutputSpec(codec: .h264, width: size.width, height: size.height,
                                            frameStep: highRate ? 2 : 1, bitrateCap: CastVideoOutputSpec.h264Cap),
                reason: trigger)
        }
    }

    /// `[Cast] video plan: source=avc1.64002A 1920x1080@59.94 receiver
    /// display h264_1080p60=no h264_1080p30=yes hevc_1080p60=no hvc1=no ->
    /// transcode H.264 720p59.94 level 4.1 (8000 kbps)`.
    func logLine(source s: CastH264StreamInfo, decision d: CastVideoDecision) -> String {
        let caps = self.caps ?? CastReceiverVideoCaps(mse: [:], display: nil)
        func yn(_ b: Bool) -> String { b ? "yes" : "no" }
        var line = "[Cast] video plan: source=\(s.codecString) \(s.label)"
        if !s.progressive { line += " interlaced" }
        if self.caps == nil {
            line += " receiver caps=none"
        } else if caps.display == nil {
            line += " receiver display=none hvc1=\(yn(caps.mse("hvc1")))"
        } else {
            line += " receiver display h264_1080p60=\(yn(caps.display("h264_1080p60")))"
                + " h264_1080p30=\(yn(caps.display("h264_1080p30")))"
                + " hevc_1080p60=\(yn(caps.display("hevc_1080p60")))"
                + " hvc1=\(yn(caps.mse("hvc1")))"
        }
        guard let out = d.output else { return line + " -> passthrough (\(d.reason))" }
        let fps = out.outputFPS(s.fps).map(Self.fpsLabel) ?? ""
        let kbps = out.bitrateCap / 1000
        switch out.codec {
        case .hevc:
            line += " -> transcode HEVC \(out.height)p\(fps) (\(kbps) kbps)"
        case .h264:
            line += " -> transcode H.264 \(out.height)p\(fps) level 4.1 (\(kbps) kbps)"
        }
        if force { line += " [forced]" }
        return line
    }

    /// 59.94 stays 59.94, 50.0 prints as 50.
    static func fpsLabel(_ fps: Double) -> String {
        abs(fps - fps.rounded()) < 0.005 ? String(format: "%.0f", fps) : String(format: "%.2f", fps)
    }

    /// Scale (w, h) down to fit inside the box, preserving aspect, even
    /// dimensions; never scales up.
    static func fit(_ w: Int, _ h: Int, maxWidth: Int, maxHeight: Int) -> (width: Int, height: Int) {
        guard w > 0, h > 0 else { return (maxWidth, maxHeight) }
        if w <= maxWidth && h <= maxHeight { return (even(w), even(h)) }
        let scale = min(Double(maxWidth) / Double(w), Double(maxHeight) / Double(h))
        return (even(Int((Double(w) * scale).rounded())), even(Int((Double(h) * scale).rounded())))
    }
}

private func even(_ v: Int) -> Int { max(2, v & ~1) }

// MARK: - Codec configuration records and strings

/// Pure helpers for the avcC / hvcC records and their RFC 6381 strings.
enum CastVideoCodecConfig {

    /// avcC payload (the box body) for one SPS and one PPS, 4-byte NAL
    /// lengths.
    static func avcCPayload(sps s: [UInt8], pps p: [UInt8]) -> Data {
        var body = Data(capacity: 16 + s.count + p.count)
        body.append(1) // configurationVersion
        body.append(s.count > 1 ? s[1] : 0) // AVCProfileIndication
        body.append(s.count > 2 ? s[2] : 0) // profile_compatibility
        body.append(s.count > 3 ? s[3] : 0) // AVCLevelIndication
        body.append(0xFF) // 4-byte NAL lengths (lengthSizeMinusOne = 3)
        body.append(0xE1) // 1 SPS
        body.append(UInt8((s.count >> 8) & 0xFF)); body.append(UInt8(s.count & 0xFF))
        body.append(contentsOf: s)
        body.append(1) // 1 PPS
        body.append(UInt8((p.count >> 8) & 0xFF)); body.append(UInt8(p.count & 0xFF))
        body.append(contentsOf: p)
        return body
    }

    /// RFC 6381 / ISO 14496-15 Annex E codec string from an hvcC payload
    /// (the box body, starting at configurationVersion):
    /// hvc1.[A-C]<profile>.<reversed compat hex>.<L|H><level>[.<constraint>]*
    /// with trailing zero constraint bytes omitted, e.g. hvc1.1.6.L153.B0.
    static func hevcCodecString(hvcC p: [UInt8]) -> String? {
        guard p.count >= 13, p[0] == 1 else { return nil }
        let space = Int(p[1] >> 6)
        let tier = Int((p[1] >> 5) & 1)
        let profile = Int(p[1] & 0x1F)
        let compat = (UInt32(p[2]) << 24) | (UInt32(p[3]) << 16) | (UInt32(p[4]) << 8) | UInt32(p[5])
        var reversed: UInt32 = 0
        for bit in 0..<32 where compat & (1 << UInt32(bit)) != 0 {
            reversed |= 1 << UInt32(31 - bit)
        }
        var constraints = Array(p[6..<12])
        while let last = constraints.last, last == 0 { constraints.removeLast() }
        var s = "hvc1." + ["", "A", "B", "C"][space] + "\(profile)"
        s += "." + String(reversed, radix: 16, uppercase: true)
        s += "." + (tier == 1 ? "H" : "L") + "\(p[12])"
        for c in constraints { s += String(format: ".%02X", c) }
        return s
    }

    /// HEVC SPS fields the hvcC record repeats.
    struct HEVCSPSInfo: Equatable {
        /// general_profile_space .. general_level_idc: the 12 bytes hvcC
        /// copies verbatim.
        var generalPTL: [UInt8]
        var maxSubLayersMinus1: Int
        var temporalIdNesting: Bool
        var chromaFormatIDC: Int
        var bitDepthLumaMinus8: Int
        var bitDepthChromaMinus8: Int
        var width: Int
        var height: Int
    }

    /// Parse an HEVC SPS NAL (2-byte header included, emulation
    /// prevention bytes still in).
    static func parseHEVCSPS(_ nal: [UInt8]) -> HEVCSPSInfo? {
        guard nal.count > 15, (nal[0] >> 1) & 0x3F == 33 else { return nil }
        let rbsp = CastFMP4Remuxer.unescapeRBSP(nal, from: 2)
        guard rbsp.count >= 13 else { return nil }
        let maxSub = Int((rbsp[0] >> 1) & 0x07)
        let nesting = rbsp[0] & 1 == 1
        let ptl = Array(rbsp[1..<13])
        var r = CastFMP4Remuxer.BitReader(rbsp)
        do {
            _ = try r.bits(8 + 96) // vps id .. nesting, general PTL
            var subProfile = [Bool](), subLevel = [Bool]()
            for _ in 0..<maxSub {
                subProfile.append(try r.bits(1) == 1)
                subLevel.append(try r.bits(1) == 1)
            }
            if maxSub > 0 { for _ in maxSub..<8 { _ = try r.bits(2) } }
            for i in 0..<maxSub {
                if subProfile[i] { _ = try r.bits(88) }
                if subLevel[i] { _ = try r.bits(8) }
            }
            _ = try r.ue() // sps_seq_parameter_set_id
            let chroma = try r.ue()
            if chroma == 3 { _ = try r.bits(1) }
            var width = try r.ue()
            var height = try r.ue()
            if try r.bits(1) == 1 { // conformance_window_flag
                let l = try r.ue(), rr = try r.ue(), t = try r.ue(), b = try r.ue()
                let subW = (chroma == 1 || chroma == 2) ? 2 : 1
                let subH = chroma == 1 ? 2 : 1
                width -= (l + rr) * subW
                height -= (t + b) * subH
            }
            let luma = try r.ue()
            let chromaDepth = try r.ue()
            return HEVCSPSInfo(generalPTL: ptl, maxSubLayersMinus1: maxSub, temporalIdNesting: nesting,
                               chromaFormatIDC: chroma, bitDepthLumaMinus8: luma,
                               bitDepthChromaMinus8: chromaDepth, width: width, height: height)
        } catch {
            return nil
        }
    }

    /// hvcC payload from one VPS, SPS and PPS (4-byte NAL lengths). The
    /// production path takes the record VideoToolbox writes; this builds
    /// the same record from the parameter sets when that atom is missing.
    static func buildHVCC(vps: [UInt8], sps: [UInt8], pps: [UInt8]) -> [UInt8]? {
        guard let info = parseHEVCSPS(sps) else { return nil }
        var out: [UInt8] = [1]
        out += info.generalPTL
        out += [0xF0, 0x00] // reserved + min_spatial_segmentation_idc 0
        out.append(0xFC) // reserved + parallelismType 0
        out.append(0xFC | UInt8(info.chromaFormatIDC & 0x03))
        out.append(0xF8 | UInt8(info.bitDepthLumaMinus8 & 0x07))
        out.append(0xF8 | UInt8(info.bitDepthChromaMinus8 & 0x07))
        out += [0x00, 0x00] // avgFrameRate unspecified
        out.append(UInt8(((info.maxSubLayersMinus1 + 1) & 0x07) << 3)
                   | (info.temporalIdNesting ? 0x04 : 0) | 0x03) // lengthSizeMinusOne 3
        out.append(3) // numOfArrays
        for (type, nal) in [(32, vps), (33, sps), (34, pps)] {
            out.append(0x80 | UInt8(type)) // array_completeness 1
            out += [0x00, 0x01]
            out += [UInt8((nal.count >> 8) & 0xFF), UInt8(nal.count & 0xFF)]
            out += nal
        }
        return out
    }
}

// MARK: - Remuxer seam

/// What the transcoder hands back to the remuxer, always on the ingest
/// queue (through the delivery hop), in this order: one format, then the
/// samples; or one failure.
struct CastVideoTranscodeSink: @unchecked Sendable {
    /// `config` is the avcC or hvcC box body for the init segment.
    var onFormat: (_ codec: CastVideoOutputSpec.Codec, _ config: [UInt8], _ width: Int, _ height: Int) -> Void
    /// One access unit, 4-byte NAL lengths, presentation order. DTS equals
    /// PTS: the encoder never reorders.
    var onSample: (_ data: [UInt8], _ pts: Int64, _ keyframe: Bool) -> Void
    /// Any VideoToolbox failure: the session falls back to passthrough.
    var onFailure: (_ reason: String) -> Void
}

/// Abstraction over the VideoToolbox transcoder so the remuxer's pure logic
/// stays testable off-device.
protocol CastVideoTranscoding: AnyObject {
    /// One source access unit: 4-byte-length H.264 NAL units with the
    /// parameter sets, AUDs and filler already removed, 90 kHz unwrapped
    /// timestamps, and the SPS / PPS in force for it.
    func feed(_ sample: [UInt8], pts: Int64, dts: Int64, keyframe: Bool, sps: [UInt8], pps: [UInt8])
    func release()
}

/// Thread hop onto the ingest queue (the session's serial queue).
typealias CastIngestDelivery = @Sendable (@escaping @Sendable () -> Void) -> Void

/// The log closure the remuxer carries is not Sendable; the session's
/// implementation is (it only calls `debugLog`).
struct CastUncheckedLog: @unchecked Sendable {
    let fn: (String) -> Void
    func callAsFunction(_ s: String) { fn(s) }
}

// MARK: - VideoToolbox transcoder

/// Decode (VTDecompressionSession, hardware) -> reorder to presentation
/// order -> encode (VTCompressionSession, hardware, realtime, no frame
/// reordering) on a private serial queue; never on the remux queue.
///
/// PTS flow: every decoded frame keeps its source PTS, the encoder is given
/// that PTS and hands it back untouched, and with frame reordering off the
/// output DTS equals its PTS, so the video rides the source clock and audio
/// sync is exactly what the passthrough had. Frames are released to the
/// encoder in PTS order from a small reorder buffer; one that arrives below
/// the last released PTS is dropped (and the buffer grows) so the output is
/// strictly monotonic.
///
/// Key frames: the first encoded frame and then the first frame at or after
/// each `targetKeyTicks` of media are forced IDRs, which is exactly the
/// remuxer's cut rule (first keyframe at or after the segment target), so
/// every segment cut lands on an encoder IDR and segments stay at ~3 s.
final class CastVideoTranscoder: CastVideoTranscoding, @unchecked Sendable {

    /// Encoder falling behind: the input backlog bound. The spec is "drop
    /// if more than 1 s behind", but the Dispatcharr proxy delivers its
    /// bytes in 8 to 9.5 s bursts (measured 2026-09-14), so a whole burst
    /// sits in this queue for a moment by design. The bound is therefore
    /// 1 s of lag beyond the largest measured burst.
    static let maxBacklogTicks: Int64 = 11 * CastFMP4Remuxer.ticksPerSecond
    /// Encodes in flight inside VideoToolbox before the work queue waits.
    static let maxInFlight = 8
    /// Consecutive decode or encode errors that end the transcode.
    static let maxConsecutiveErrors = 90
    /// Source bitrate measurement window.
    static let bitrateWindowTicks: Int64 = 4 * CastFMP4Remuxer.ticksPerSecond
    /// Stats line cadence.
    static let statsInterval: TimeInterval = 10

    private struct InputFrame {
        let data: [UInt8]
        let pts: Int64
        let dts: Int64
        let keyframe: Bool
        let sps: [UInt8]
        let pps: [UInt8]
    }

    private struct DecodedFrame: @unchecked Sendable {
        let image: CVImageBuffer
        let pts: Int64
    }

    private let source: CastH264StreamInfo
    private let spec: CastVideoOutputSpec
    private let targetKeyTicks: Int64
    private let sink: CastVideoTranscodeSink
    private let deliver: CastIngestDelivery
    private let log: CastUncheckedLog
    private let work = DispatchQueue(label: "com.aerio.casthls.videotranscode", qos: .userInitiated)

    // MARK: state guarded by `lock`
    private let lock = NSLock()
    private var pending: [InputFrame] = []
    private var drainScheduled = false
    private var released = false
    private var failed = false
    private var formatDelivered = false
    private var encodedFrames = 0
    private var encodedSinceStats = 0
    private var droppedBacklog = 0
    private var droppedEncoder = 0
    private var droppedLate = 0
    private var decodeErrors = 0
    private var inFlight = 0
    private var reorderCount = 0
    /// NAL length size of the encoder's output samples (VideoToolbox uses 4).
    private var outputNALLength = 4

    /// Waited on by the work queue while `inFlight` is at the cap.
    private let inFlightCondition = NSCondition()

    // MARK: work-queue state
    private var decoder: VTDecompressionSession?
    private var decoderFormat: CMVideoFormatDescription?
    private var decoderSPS: [UInt8] = []
    private var decoderPPS: [UInt8] = []
    private var encoder: VTCompressionSession?
    private var waitingForKey = true
    private var reorder: [DecodedFrame] = []
    private var reorderDepth: Int
    private var lastReleasedPTS: Int64 = -1
    private var anchorPTS: Int64 = -1
    private var lastKeyPTS: Int64 = -1
    private var presentedIndex = 0
    private var consecutiveErrors = 0
    private var sessionResets = 0
    private var targetBitrate: Int
    private var bitrateBytes = 0
    private var bitrateStartDTS: Int64 = -1
    private var bitrateMeasured = false
    private var decodeScratch: [DecodedFrame] = []
    private let scratchLock = NSLock()

    private var statsTimer: DispatchSourceTimer?
    private var statsStartedAt = Date()
    private var thermalObserver: NSObjectProtocol?
    private var lastThermal: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState

    init(source: CastH264StreamInfo, spec: CastVideoOutputSpec, targetKeyTicks: Int64,
         sink: CastVideoTranscodeSink, deliver: @escaping CastIngestDelivery,
         log: @escaping (String) -> Void) {
        self.source = source
        self.spec = spec
        self.targetKeyTicks = targetKeyTicks
        self.sink = sink
        self.deliver = deliver
        self.log = CastUncheckedLog(fn: log)
        self.targetBitrate = spec.bitrateCap
        if let n = source.maxNumReorderFrames {
            reorderDepth = min(16, max(0, n))
        } else {
            reorderDepth = source.profileIDC == 66 ? 0 : 4
        }
        startStatsTimer()
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.noteThermalChange()
        }
    }

    deinit {
        statsTimer?.cancel()
        if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) }
    }

    // MARK: ingest side

    func feed(_ sample: [UInt8], pts: Int64, dts: Int64, keyframe: Bool, sps: [UInt8], pps: [UInt8]) {
        var dropped = 0
        var backlogSeconds = 0.0
        var schedule = false
        lock.lock()
        if released || failed { lock.unlock(); return }
        pending.append(InputFrame(data: sample, pts: pts, dts: dts, keyframe: keyframe, sps: sps, pps: pps))
        // Drop whole GOPs from the front: a partial GOP cannot be decoded,
        // so the queue always restarts on a source IDR.
        while let first = pending.first, let last = pending.last,
              last.dts - first.dts > Self.maxBacklogTicks {
            pending.removeFirst(); dropped += 1
            while let f = pending.first, !f.keyframe { pending.removeFirst(); dropped += 1 }
        }
        if dropped > 0 {
            droppedBacklog += dropped
            if let first = pending.first, let last = pending.last {
                backlogSeconds = Double(last.dts - first.dts) / Double(CastFMP4Remuxer.ticksPerSecond)
            }
        }
        if !drainScheduled { drainScheduled = true; schedule = true }
        lock.unlock()
        if dropped > 0 {
            log(String(format: "video transcode: encoder behind, dropped %d source frames (backlog now %.1f s)",
                       dropped, backlogSeconds))
        }
        if schedule { work.async { [weak self] in self?.drain() } }
    }

    func release() {
        lock.lock()
        released = true
        pending.removeAll()
        lock.unlock()
        statsTimer?.cancel()
        statsTimer = nil
        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
            self.thermalObserver = nil
        }
        // Unblock a work queue waiting on the in-flight cap.
        inFlightCondition.lock()
        inFlightCondition.broadcast()
        inFlightCondition.unlock()
        work.async { [self] in
            self.teardownSessions()
        }
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return released || failed
    }

    // MARK: work queue

    private func drain() {
        while true {
            lock.lock()
            if released || failed || pending.isEmpty {
                drainScheduled = false
                lock.unlock()
                return
            }
            let frame = pending.removeFirst()
            lock.unlock()
            process(frame)
        }
    }

    private func process(_ frame: InputFrame) {
        measureBitrate(frame)
        if waitingForKey && !frame.keyframe { return }
        if frame.keyframe && (decoder == nil || frame.sps != decoderSPS || frame.pps != decoderPPS) {
            guard makeDecoder(sps: frame.sps, pps: frame.pps) else { return }
        }
        guard let decoder, let decoderFormat else { return }
        if waitingForKey {
            waitingForKey = false
            if anchorPTS < 0 { anchorPTS = frame.pts }
        }
        guard let sampleBuffer = Self.makeSampleBuffer(frame.data, pts: frame.pts, dts: frame.dts,
                                                       format: decoderFormat) else {
            noteError("could not wrap a source frame")
            return
        }
        scratchLock.lock(); decodeScratch.removeAll(keepingCapacity: true); scratchLock.unlock()
        var infoOut = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(
            decoder, sampleBuffer: sampleBuffer, flags: [], infoFlagsOut: &infoOut
        ) { [weak self] status, _, imageBuffer, pts, _ in
            guard let self else { return }
            guard status == noErr, let imageBuffer, pts.isValid else {
                self.lock.lock(); self.decodeErrors += 1; self.lock.unlock()
                return
            }
            let ticks = CMTimeConvertScale(pts, timescale: Int32(CastFMP4Remuxer.ticksPerSecond),
                                           method: .roundHalfAwayFromZero).value
            self.scratchLock.lock()
            self.decodeScratch.append(DecodedFrame(image: imageBuffer, pts: ticks))
            self.scratchLock.unlock()
        }
        if status != noErr {
            lock.lock(); decodeErrors += 1; lock.unlock()
            if status == kVTInvalidSessionErr {
                // Invalidated under us (media services reset, background
                // policy): rebuild on the next source IDR.
                resetSessions(reason: "decoder session invalidated (\(status))")
                return
            }
            noteError("decode failed (\(status))")
            waitingForKey = true
            return
        }
        VTDecompressionSessionWaitForAsynchronousFrames(decoder)
        scratchLock.lock()
        let decoded = decodeScratch
        decodeScratch.removeAll(keepingCapacity: true)
        scratchLock.unlock()
        if !decoded.isEmpty { consecutiveErrors = 0 }
        for frame in decoded { enqueueDecoded(frame) }
    }

    private func enqueueDecoded(_ d: DecodedFrame) {
        // Leading pictures of the first GOP present before the IDR the
        // remuxer anchored its timeline on.
        if anchorPTS >= 0, d.pts < anchorPTS { return }
        if lastReleasedPTS >= 0, d.pts <= lastReleasedPTS {
            lock.lock(); droppedLate += 1; lock.unlock()
            if reorderDepth < 16 {
                reorderDepth += 1
                log("video transcode: decoded frame arrived out of order, reorder depth now \(reorderDepth)")
            }
            return
        }
        let at = reorder.firstIndex { $0.pts > d.pts } ?? reorder.count
        reorder.insert(d, at: at)
        while reorder.count > reorderDepth {
            encode(reorder.removeFirst())
        }
        lock.lock(); reorderCount = reorder.count; lock.unlock()
    }

    private func encode(_ d: DecodedFrame) {
        lastReleasedPTS = d.pts
        presentedIndex += 1
        if spec.frameStep > 1, (presentedIndex - 1) % spec.frameStep != 0 { return }
        if encoder == nil {
            guard makeEncoder() else { return }
        }
        guard let encoder else { return }
        let forceKey = lastKeyPTS < 0 || d.pts - lastKeyPTS >= targetKeyTicks
        if forceKey { lastKeyPTS = d.pts }
        // In-flight cap: wait here (the work queue), never on the remux queue.
        inFlightCondition.lock()
        while inFlight >= Self.maxInFlight && !isStopped {
            if !inFlightCondition.wait(until: Date(timeIntervalSinceNow: 2)) {
                inFlightCondition.unlock()
                fail("encoder stalled with \(Self.maxInFlight) frames in flight")
                return
            }
        }
        inFlight += 1
        inFlightCondition.unlock()
        if isStopped { finishInFlight(); return }
        let props: CFDictionary? = forceKey
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        let status = VTCompressionSessionEncodeFrame(
            encoder, imageBuffer: d.image,
            presentationTimeStamp: CMTime(value: d.pts, timescale: Int32(CastFMP4Remuxer.ticksPerSecond)),
            duration: .invalid, frameProperties: props, infoFlagsOut: nil
        ) { [weak self] status, infoFlags, sampleBuffer in
            guard let self else { return }
            self.finishInFlight()
            self.onEncoded(status: status, infoFlags: infoFlags, sampleBuffer: sampleBuffer)
        }
        if status != noErr {
            finishInFlight()
            if status == kVTInvalidSessionErr {
                resetSessions(reason: "encoder session invalidated (\(status))")
                return
            }
            noteError("encode failed (\(status))")
        }
    }

    private func finishInFlight() {
        inFlightCondition.lock()
        inFlight = max(0, inFlight - 1)
        inFlightCondition.signal()
        inFlightCondition.unlock()
    }

    // MARK: encoder output (VideoToolbox thread)

    private func onEncoded(status: OSStatus, infoFlags: VTEncodeInfoFlags, sampleBuffer: CMSampleBuffer?) {
        if isStopped { return }
        guard status == noErr, let sampleBuffer else {
            if infoFlags.contains(.frameDropped) || status == noErr {
                lock.lock(); droppedEncoder += 1; lock.unlock()
            } else {
                log("video transcode: encoder output error \(status)")
            }
            return
        }
        if infoFlags.contains(.frameDropped) {
            lock.lock(); droppedEncoder += 1; lock.unlock()
            return
        }
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        lock.lock()
        let needFormat = !formatDelivered
        lock.unlock()
        if needFormat {
            guard let config = Self.configRecord(format, codec: spec.codec) else {
                fail("encoder produced no \(spec.codec == .hevc ? "hvcC" : "avcC") parameter sets")
                return
            }
            let dims = CMVideoFormatDescriptionGetDimensions(format)
            lock.lock()
            formatDelivered = true
            outputNALLength = config.nalLength
            lock.unlock()
            let sink = self.sink
            let codec = spec.codec
            let record = config.record
            deliver { sink.onFormat(codec, record, Int(dims.width), Int(dims.height)) }
        }
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let length = CMBlockBufferGetDataLength(block)
        var bytes = [UInt8](repeating: 0, count: length)
        let copyStatus = bytes.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
        }
        guard copyStatus == noErr else { return }
        lock.lock()
        let nalLength = outputNALLength
        encodedFrames += 1
        encodedSinceStats += 1
        lock.unlock()
        if nalLength != 4 { bytes = Self.toFourByteLengths(bytes, nalLength: nalLength) }
        let pts = CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                                     timescale: Int32(CastFMP4Remuxer.ticksPerSecond),
                                     method: .roundHalfAwayFromZero).value
        var keyframe = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[CFString: Any]], let first = attachments.first,
           let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            keyframe = !notSync
        }
        let sink = self.sink
        let data = bytes
        let isKey = keyframe
        deliver { sink.onSample(data, pts, isKey) }
    }

    // MARK: sessions

    private func makeDecoder(sps: [UInt8], pps: [UInt8]) -> Bool {
        guard !sps.isEmpty, !pps.isEmpty else { return false }
        var format: CMFormatDescription?
        let status = sps.withUnsafeBufferPointer { s in
            pps.withUnsafeBufferPointer { p in
                let pointers = [s.baseAddress!, p.baseAddress!]
                let sizes = [s.count, p.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            }
        }
        guard status == noErr, let format else {
            noteError("source parameter sets rejected (\(status))")
            return false
        }
        if let decoder, VTDecompressionSessionCanAcceptFormatDescription(decoder, formatDescription: format) {
            decoderFormat = format
            decoderSPS = sps
            decoderPPS = pps
            return true
        }
        if let old = decoder {
            // Parameter set change: finish what the old session holds first.
            VTDecompressionSessionWaitForAsynchronousFrames(old)
            VTDecompressionSessionInvalidate(old)
            decoder = nil
        }
        let decoderSpec: [CFString: Any] = [
            kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true,
        ]
        let pixelFormat = source.fullRange
            ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        var attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
        ]
        // Output size differs from the source (720p profile, 4K to 1080
        // HEVC): the hardware decoder scales into the destination buffers.
        if spec.width != source.width || spec.height != source.height {
            attrs[kCVPixelBufferWidthKey] = spec.width
            attrs[kCVPixelBufferHeightKey] = spec.height
        }
        var session: VTDecompressionSession?
        let createStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: format,
            decoderSpecification: decoderSpec as CFDictionary,
            imageBufferAttributes: attrs as CFDictionary,
            outputCallback: nil, decompressionSessionOut: &session)
        guard createStatus == noErr, let session else {
            fail("hardware H.264 decoder unavailable (\(createStatus))")
            return false
        }
        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        decoder = session
        decoderFormat = format
        decoderSPS = sps
        decoderPPS = pps
        return true
    }

    private func makeEncoder() -> Bool {
        let encoderSpec: [CFString: Any] = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
        ]
        var session: VTCompressionSession?
        let codecType = spec.codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault, width: Int32(spec.width), height: Int32(spec.height),
            codecType: codecType, encoderSpecification: encoderSpec as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else {
            fail("hardware \(spec.codec == .hevc ? "HEVC" : "H.264") encoder unavailable (\(status))")
            return false
        }
        func set(_ key: CFString, _ value: CFTypeRef) {
            let st = VTSessionSetProperty(session, key: key, value: value)
            if st != noErr { log("video transcode: encoder refused \(key) (\(st))") }
        }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        switch spec.codec {
        case .hevc:
            set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel)
        case .h264:
            set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_4_1)
            set(kVTCompressionPropertyKey_H264EntropyMode, kVTH264EntropyMode_CABAC)
        }
        // Forced IDRs every `targetKeyTicks` set the real cadence (see the
        // class comment). The encoder's own cap sits one second past it as
        // a safety net: at exactly the target it would place its own IDR a
        // frame BEFORE the target (179.82 frames at 59.94) and the forced
        // one right after, two IDRs per segment.
        let keySeconds = Double(targetKeyTicks) / Double(CastFMP4Remuxer.ticksPerSecond)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: keySeconds + 1))
        set(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: targetBitrate))
        if let fps = spec.outputFPS(source.fps) {
            set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: fps))
        }
        if let v = Self.colourPrimaries(source.colourPrimaries) { set(kVTCompressionPropertyKey_ColorPrimaries, v) }
        if let v = Self.transferFunction(source.transferCharacteristics) {
            set(kVTCompressionPropertyKey_TransferFunction, v)
        }
        if let v = Self.yCbCrMatrix(source.matrixCoefficients) { set(kVTCompressionPropertyKey_YCbCrMatrix, v) }
        let prepare = VTCompressionSessionPrepareToEncodeFrames(session)
        if prepare != noErr {
            VTCompressionSessionInvalidate(session)
            fail("encoder prepare failed (\(prepare))")
            return false
        }
        var usingHardware: CFBoolean?
        _ = withUnsafeMutablePointer(to: &usingHardware) {
            VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                                  allocator: nil, valueOut: UnsafeMutableRawPointer($0))
        }
        encoder = session
        let target: String
        switch spec.codec {
        case .hevc: target = "HEVC Main"
        case .h264: target = "H.264 High 4.1"
        }
        let outFPS = spec.outputFPS(source.fps).map(CastVideoPlan.fpsLabel) ?? "?"
        let hardware = usingHardware.map { CFBooleanGetValue($0) } == false
            ? "VideoToolbox, NOT hardware" : "VideoToolbox hardware"
        log("video transcode: H.264 \(source.width)x\(source.height)@\(source.fps.map(CastVideoPlan.fpsLabel) ?? "?") "
            + "level \(source.levelLabel) -> \(target) \(spec.width)x\(spec.height)@\(outFPS), "
            + "target \(targetBitrate / 1000) kbps (\(hardware))")
        return true
    }

    /// Drop both sessions and restart on the next source IDR (session
    /// invalidation). Repeated resets end the transcode.
    private func resetSessions(reason: String) {
        sessionResets += 1
        log("video transcode: \(reason); rebuilding at the next IDR (reset \(sessionResets))")
        teardownSessions()
        reorder.removeAll()
        waitingForKey = true
        lastKeyPTS = -1
        if sessionResets >= 5 { fail("\(reason), \(sessionResets) resets") }
    }

    private func teardownSessions() {
        if let decoder {
            VTDecompressionSessionInvalidate(decoder)
            self.decoder = nil
        }
        decoderFormat = nil
        decoderSPS = []
        decoderPPS = []
        if let encoder {
            VTCompressionSessionInvalidate(encoder)
            self.encoder = nil
        }
    }

    private func noteError(_ what: String) {
        consecutiveErrors += 1
        if consecutiveErrors == 1 || consecutiveErrors % 30 == 0 {
            log("video transcode: \(what) (\(consecutiveErrors) in a row)")
        }
        if consecutiveErrors >= Self.maxConsecutiveErrors {
            fail("\(what), \(consecutiveErrors) errors in a row")
        }
    }

    private func fail(_ reason: String) {
        lock.lock()
        if failed || released { lock.unlock(); return }
        failed = true
        pending.removeAll()
        lock.unlock()
        log("video transcode failed: \(reason); falling back to H.264 passthrough")
        let sink = self.sink
        deliver { sink.onFailure(reason) }
    }

    // MARK: bitrate

    /// The first `bitrateWindowTicks` of source media set the encoder target
    /// to min(source rate, profile cap).
    private func measureBitrate(_ frame: InputFrame) {
        guard !bitrateMeasured else { return }
        if bitrateStartDTS < 0 { bitrateStartDTS = frame.dts }
        bitrateBytes += frame.data.count
        let span = frame.dts - bitrateStartDTS
        guard span >= Self.bitrateWindowTicks else { return }
        bitrateMeasured = true
        let measured = Int(Double(bitrateBytes) * 8 * Double(CastFMP4Remuxer.ticksPerSecond) / Double(span))
        let target = max(1_000_000, min(measured, spec.bitrateCap))
        log("video transcode: source measured \(measured / 1000) kbps, encoder target \(target / 1000) kbps")
        guard target != targetBitrate else { return }
        targetBitrate = target
        if let encoder {
            VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AverageBitRate,
                                 value: NSNumber(value: target))
        }
    }

    // MARK: stats and thermal

    private func startStatsTimer() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + Self.statsInterval, repeating: Self.statsInterval)
        timer.setEventHandler { [weak self] in self?.logStats() }
        statsTimer = timer
        statsStartedAt = Date()
        timer.resume()
    }

    private func logStats() {
        lock.lock()
        if released || failed { lock.unlock(); return }
        let now = Date()
        let elapsed = max(0.001, now.timeIntervalSince(statsStartedAt))
        statsStartedAt = now
        let fps = Double(encodedSinceStats) / elapsed
        encodedSinceStats = 0
        let queued = pending.count
        let backlog = (pending.last.map { $0.dts } ?? 0) - (pending.first.map { $0.dts } ?? 0)
        let reordering = reorderCount
        let drops = (droppedBacklog, droppedEncoder, droppedLate)
        let errors = decodeErrors
        lock.unlock()
        inFlightCondition.lock()
        let flying = inFlight
        inFlightCondition.unlock()
        var line = String(format: "video transcode: encoded %.1f fps, queue %d (%.1f s) reorder %d in flight %d",
                          fps, queued, Double(backlog) / Double(CastFMP4Remuxer.ticksPerSecond),
                          reordering, flying)
        if drops.0 + drops.1 + drops.2 > 0 {
            line += ", dropped backlog=\(drops.0) encoder=\(drops.1) late=\(drops.2)"
        }
        if errors > 0 { line += ", decode errors=\(errors)" }
        line += ", thermal=\(Self.thermalName(ProcessInfo.processInfo.thermalState))"
        log(line)
    }

    private func noteThermalChange() {
        let state = ProcessInfo.processInfo.thermalState
        lock.lock()
        let old = lastThermal
        lastThermal = state
        let stopped = released || failed
        lock.unlock()
        guard !stopped, old != state else { return }
        log("video transcode: thermal state \(Self.thermalName(old)) -> \(Self.thermalName(state))")
    }

    private static func thermalName(_ s: ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    // MARK: helpers

    private static func makeSampleBuffer(_ data: [UInt8], pts: Int64, dts: Int64,
                                         format: CMFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        let n = data.count
        guard n > 0, CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: n,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: n, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block else { return nil }
        let copied = data.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: n)
        }
        guard copied == noErr else { return nil }
        let scale = Int32(CastFMP4Remuxer.ticksPerSecond)
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMTime(value: pts, timescale: scale),
                                        decodeTimeStamp: CMTime(value: dts, timescale: scale))
        var size = n
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        return status == noErr ? sample : nil
    }

    /// The init segment's avcC / hvcC body. VideoToolbox's own record when
    /// the format carries one (lengthSizeMinusOne forced to 3, samples are
    /// rewritten to match), otherwise built from the parameter sets.
    private static func configRecord(_ format: CMFormatDescription,
                                     codec: CastVideoOutputSpec.Codec) -> (record: [UInt8], nalLength: Int)? {
        var sets: [[UInt8]] = []
        var count = 0
        var nalLength: Int32 = 4
        var index = 0
        repeat {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status: OSStatus
            switch codec {
            case .hevc:
                status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: &count,
                    nalUnitHeaderLengthOut: &nalLength)
            case .h264:
                status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: &count,
                    nalUnitHeaderLengthOut: &nalLength)
            }
            guard status == noErr, let pointer else { break }
            sets.append(Array(UnsafeBufferPointer(start: pointer, count: size)))
            index += 1
        } while index < count
        let atomKey = codec == .hevc ? "hvcC" : "avcC"
        if let atoms = CMFormatDescriptionGetExtension(
            format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any],
           let data = atoms[atomKey] as? Data {
            var record = [UInt8](data)
            switch codec {
            case .hevc where record.count > 21: record[21] |= 0x03
            case .h264 where record.count > 4: record[4] |= 0x03
            default: break
            }
            return (record, Int(nalLength))
        }
        switch codec {
        case .hevc:
            func nal(_ type: UInt8) -> [UInt8]? { sets.first { ($0.first.map { ($0 >> 1) & 0x3F }) == type } }
            guard let vps = nal(32), let sps = nal(33), let pps = nal(34),
                  let record = CastVideoCodecConfig.buildHVCC(vps: vps, sps: sps, pps: pps) else { return nil }
            return (record, Int(nalLength))
        case .h264:
            func nal(_ type: UInt8) -> [UInt8]? { sets.first { ($0.first.map { $0 & 0x1F }) == type } }
            guard let sps = nal(7), let pps = nal(8) else { return nil }
            return ([UInt8](CastVideoCodecConfig.avcCPayload(sps: sps, pps: pps)), Int(nalLength))
        }
    }

    /// Rewrite N-byte NAL length prefixes as 4-byte ones.
    private static func toFourByteLengths(_ bytes: [UInt8], nalLength: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + 16)
        var p = 0
        while p + nalLength <= bytes.count {
            var n = 0
            for i in 0..<nalLength { n = (n << 8) | Int(bytes[p + i]) }
            p += nalLength
            guard p + n <= bytes.count else { break }
            out += [UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
            out += bytes[p..<(p + n)]
            p += n
        }
        return out
    }

    private static func colourPrimaries(_ code: Int?) -> CFString? {
        switch code {
        case 1: return kCVImageBufferColorPrimaries_ITU_R_709_2
        case 5: return kCVImageBufferColorPrimaries_EBU_3213
        case 6: return kCVImageBufferColorPrimaries_SMPTE_C
        case 9: return kCVImageBufferColorPrimaries_ITU_R_2020
        default: return nil
        }
    }

    private static func transferFunction(_ code: Int?) -> CFString? {
        switch code {
        case 1, 6, 14, 15: return kCVImageBufferTransferFunction_ITU_R_709_2
        case 16: return kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        case 18: return kCVImageBufferTransferFunction_ITU_R_2100_HLG
        default: return nil
        }
    }

    private static func yCbCrMatrix(_ code: Int?) -> CFString? {
        switch code {
        case 1: return kCVImageBufferYCbCrMatrix_ITU_R_709_2
        case 5, 6: return kCVImageBufferYCbCrMatrix_ITU_R_601_4
        case 9: return kCVImageBufferYCbCrMatrix_ITU_R_2020
        default: return nil
        }
    }
}
