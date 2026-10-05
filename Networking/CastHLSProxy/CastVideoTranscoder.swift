//
//  CastVideoTranscoder.swift
//  Aerio
//
//  Cast HLS proxy: on-phone video transcode for H.264 the receiver cannot
//  present at full rate (2026-09-26), and for HEVC the receiver cannot
//  present at all (2026-09-27: a 4K HEVC channel was refused outright).
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

/// The video codecs the cast proxy ingests (MPEG-TS stream_type 0x1B and
/// 0x24) and the transcoder writes.
enum CastVideoCodec: Sendable, Equatable {
    case h264, hevc

    /// User-facing codec name: "H.264" or "HEVC".
    var displayName: String {
        switch self {
        case .h264: return "H.264"
        case .hevc: return "HEVC"
        }
    }
}

/// What the remuxer learned from the source SPS (H.264: see
/// `CastFMP4Remuxer.parseSPSInfo`; HEVC: see
/// `CastVideoCodecConfig.hevcStreamInfo`).
struct CastVideoStreamInfo: Sendable, Equatable {
    var codec: CastVideoCodec = .h264
    var width: Int
    var height: Int
    /// H.264 profile_idc, or HEVC general_profile_idc.
    var profileIDC: Int
    /// H.264 constraint_set flags byte (0 for HEVC).
    var constraintFlags: Int
    /// H.264 level_idc (10 x level), or HEVC general_level_idc (30 x level).
    var levelIDC: Int
    /// H.264 frame_mbs_only_flag; for HEVC, not field_seq_flag.
    var progressive: Bool = true
    /// Frames per second from the VUI (or HEVC VPS) timing info, nil when absent.
    var fps: Double?
    var fullRange: Bool = false
    var colourPrimaries: Int?
    var transferCharacteristics: Int?
    var matrixCoefficients: Int?
    /// H.264 VUI max_num_reorder_frames, or HEVC sps_max_num_reorder_pics;
    /// nil when absent.
    var maxNumReorderFrames: Int?
    /// Luma bit depth: a 10-bit HEVC source needs a 10-bit decoder output
    /// and a Main10 encode to keep its HDR signal.
    var bitDepth: Int = 8
    /// chroma_format_idc (1 is 4:2:0).
    var chromaFormat: Int = 1
    /// HEVC general profile_tier_level, the 12 bytes the hvc1 string reads.
    var hevcPTL: [UInt8]?

    /// HDR transfer from the VUI transfer_characteristics: 18 is HLG
    /// (ARIB STD-B67), 16 is PQ (SMPTE ST 2084). nil for SDR or untagged.
    var hdrTransfer: CastHDRTransfer? {
        switch transferCharacteristics {
        case 18: return .hlg
        case 16: return .pq
        default: return nil
        }
    }

    /// An HDR source: shown on an SDR path without a tone map it looks
    /// washed out, so the plan treats HDR as its own capability.
    var isHDR: Bool { hdrTransfer != nil }

    /// RFC 6381 string: avc1 from the SPS header bytes, hvc1 from the PTL.
    var codecString: String {
        switch codec {
        case .h264:
            return String(format: "avc1.%02X%02X%02X", profileIDC & 0xFF, constraintFlags & 0xFF, levelIDC & 0xFF)
        case .hevc:
            return hevcPTL.flatMap { CastVideoCodecConfig.hevcCodecString(hvcC: [1] + $0) } ?? "hvc1"
        }
    }

    /// "4.1" for H.264 level_idc 41 and for HEVC general_level_idc 123.
    var levelLabel: String {
        let tenths = codec == .hevc ? levelIDC / 3 : levelIDC
        return "\(tenths / 10).\(tenths % 10)"
    }

    /// "1920x1080@59.94", or "@?" without VUI timing.
    var label: String { "\(width)x\(height)@\(fps.map(CastVideoPlan.fpsLabel) ?? "?")" }
}

/// The two broadcast HDR transfers.
enum CastHDRTransfer: String, Sendable, Equatable {
    case hlg, pq

    /// "HLG" / "PQ" for log lines.
    var label: String { rawValue.uppercased() }
}

// MARK: - Receiver caps

/// The receiver's own measurement of what it can decode (`mse`, from
/// MediaSource.isTypeSupported) and PRESENT (`display`, from
/// cast.framework canDisplayType). Missing keys read as false.
struct CastReceiverVideoCaps: Sendable, Equatable {
    var mse: [String: Bool]
    /// nil when the receiver page sent no `display` map at all (an older
    /// page); the plan then never transcodes H.264 on its own.
    var display: [String: Bool]?

    func mse(_ key: String) -> Bool { mse[key] == true }
    func display(_ key: String) -> Bool { display?[key] == true }

    /// H.264 at 720p60 is presentable. A receiver page that predates the
    /// `h264_720p60` probe falls back to its `h264_1080p60` answer.
    /// Measured 2026-10-05 on a Chromecast Ultra: a 720p59.94 passthrough
    /// rendered at 30 to 42 fps and the media clock ran at about 0.63x.
    var h264_720p60: Bool { display?["h264_720p60"] ?? display("h264_1080p60") }
    /// HEVC at 720p60 is presentable (same fallback, to `hevc_1080p60`).
    var hevc_720p60: Bool { display?["hevc_720p60"] ?? display("hevc_1080p60") }

    /// HEVC at 1080p60 is presentable.
    var hevc1080: Bool { display("hevc_1080p60") || mse("hvc1") }
    /// HEVC at 4K60 is presentable.
    var hevc4K: Bool { display("hevc_4k60") || mse("hvc1.4k") }

    /// HEVC Main10 in this HDR transfer is presentable at this size class:
    /// 4K needs `hevc_4k60_<t>`, 1080 needs `hevc_1080p60_<t>`, and up to
    /// 720 either that or MSE `hvc1.<t>` (the MSE answer carries no size,
    /// so it only vouches for the smallest class, as `hvc1` does for SDR).
    func hdr(_ t: CastHDRTransfer, width: Int, height: Int) -> Bool {
        let is4K = width > 1920 || height > 1088
        let is1080 = !is4K && (width > 1280 || height > 720)
        if is4K { return display("hevc_4k60_\(t.rawValue)") }
        if is1080 { return display("hevc_1080p60_\(t.rawValue)") }
        return display("hevc_1080p60_\(t.rawValue)") || mse("hvc1.\(t.rawValue)")
    }
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
    typealias Codec = CastVideoCodec
    var codec: Codec
    var width: Int
    var height: Int
    /// 1 keeps every frame; 2 encodes every other presented frame.
    var frameStep: Int
    /// Upper bound on the encoder's average bit rate, bits per second.
    /// The encoder runs at min(measured source rate, this).
    var bitrateCap: Int
    /// HEVC Main10 output that keeps the source HDR transfer, primaries
    /// and matrix. false for every SDR output, including an HDR source
    /// the receiver cannot show as HDR (tone mapped to BT.709 on the phone).
    var hdr: Bool = false

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
    /// nil means passthrough of the source codec.
    var output: CastVideoOutputSpec?
    /// Why (passthrough) or what triggered the transcode.
    var reason: String
    /// What the receiver's answers ruled out for this source, in note
    /// order, from "HEVC", "4K", "1080p60", "1080p", "HDR". Built here from
    /// the same checks that chose the path so the UI never recomputes it.
    /// Empty on passthrough, when forced, and without receiver caps.
    var unsupported: [String] = []
    /// The Developer switch caused this transcode.
    var forced: Bool = false
}

/// One remuxer's decision with the source it was made for. Handed up to the
/// sender so the cast card can say what the receiver could not take and
/// what the phone turned it into.
struct CastVideoPlanOutcome: Sendable, Equatable {
    var source: CastVideoStreamInfo
    var decision: CastVideoDecision

    /// "HEVC 3840x2160 at 50fps", "... HDR" for an HLG / PQ source.
    var sourceDescription: String {
        CastVideoPlan.describe(source.codec, width: source.width, height: source.height, fps: source.fps)
            + (source.isHDR ? " HDR" : "")
    }

    /// "HEVC 1920x1080 at 50fps", "... HDR" when the output keeps HDR;
    /// nil on passthrough.
    var outputDescription: String? {
        decision.output.map {
            CastVideoPlan.describe($0.codec, width: $0.width, height: $0.height, fps: $0.outputFPS(source.fps))
                + ($0.hdr ? " HDR" : "")
        }
    }

    /// The note's receiver line: "Your Travel Chromecast TV doesn't support
    /// HEVC, 4K, HDR", "This receiver doesn't support ..." without a name,
    /// or the Developer switch line; nil on passthrough.
    func receiverLine(deviceName: String?) -> String? {
        guard decision.output != nil else { return nil }
        if decision.forced { return "Transcode forced by the Developer switch" }
        let who = deviceName.flatMap { $0.isEmpty ? nil : "Your \($0)" } ?? "This receiver"
        if decision.unsupported.isEmpty { return "\(who) didn't report what it supports" }
        return "\(who) doesn't support \(decision.unsupported.joined(separator: ", "))"
    }
}

/// Everything the remuxer needs to decide the video path once it has seen
/// the source SPS. Built by the cast sender from the receiver caps and the
/// Developer switches; the session overrides it with `disabledReason` after
/// a VideoToolbox failure.
struct CastVideoPlan: Sendable, Equatable {
    var caps: CastReceiverVideoCaps?
    /// Developer switch `castForceHEVCTranscode`: transcode any source,
    /// HEVC when the receiver presents it, else the H.264 profile.
    var force: Bool = false
    var downProfile: CastTranscodeDownProfile = .p720p60
    /// Set by the session after a VideoToolbox failure: passthrough for the
    /// rest of the session.
    var disabledReason: String?

    static let passthrough = CastVideoPlan(caps: nil)

    /// The decision rule. Pure; unit-tested.
    ///
    /// 1. A source the receiver presents passes through.
    ///    H.264: up to 1280x720 at up to 30 fps, up to 1280x720 above
    ///    30.5 fps when `display.h264_720p60` (or, from an older page
    ///    without that key, `display.h264_1080p60`), 1080 at up to 30 fps when `display.h264_1080p30`,
    ///    1080 at any rate when `display.h264_1080p60`, 4K when
    ///    `display.h264_4k60`.
    ///    HEVC: 4K when `display.hevc_4k60`, 1080 when
    ///    `display.hevc_1080p60` or MSE `hvc1`, up to 720 when MSE `hvc1`.
    /// 2. Otherwise HEVC at the source size when the receiver presents HEVC
    ///    at that size (a 4K source falls to 1080 HEVC at the source frame
    ///    rate when only 1080 HEVC is presentable; an HEVC 4K source always
    ///    does, since re-encoding it at 4K gains nothing).
    /// 3. Otherwise H.264 High 4.1 in the Developer down profile.
    /// HDR (HLG / PQ source): passthrough of an HDR source also needs the
    /// receiver's HDR answer for that transfer at the source size class
    /// (`CastReceiverVideoCaps.hdr`); an SDR-only yes is a transcode, since
    /// HDR presented as SDR looks washed out. A transcode keeps HDR (HEVC
    /// Main10, source tags) only when the output is HEVC, the source is
    /// 10-bit, and the receiver answers yes for the OUTPUT size class;
    /// every other output is SDR BT.709, tone mapped on the phone.
    /// The force switch skips rule 1. Without receiver caps or a `display`
    /// map (an older receiver page) H.264 passes through unless forced;
    /// HEVC transcodes to the H.264 profile instead, because a receiver
    /// that has not answered may not decode HEVC at all (the Chromecast
    /// Ultra answers no to every HEVC key) and the transcode always plays.
    func decide(_ s: CastVideoStreamInfo) -> CastVideoDecision {
        if let disabledReason { return CastVideoDecision(output: nil, reason: disabledReason) }
        let caps = self.caps ?? CastReceiverVideoCaps(mse: [:], display: nil)
        let unmeasured: String? = self.caps == nil ? "receiver caps not measured"
            : (caps.display == nil ? "receiver sent no display caps" : nil)
        let is4K = s.width > 1920 || s.height > 1088
        let is1080 = !is4K && (s.width > 1280 || s.height > 720)
        let fps = s.fps ?? Self.fallbackFPS(s, is4K: is4K)
        let highRate = fps > 31
        let fits: Bool
        switch s.codec {
        case .h264:
            if !force, let unmeasured { return CastVideoDecision(output: nil, reason: unmeasured) }
            if is4K {
                fits = caps.display("h264_4k60")
            } else if is1080 {
                fits = caps.display("h264_1080p60") || (!highRate && caps.display("h264_1080p30"))
            } else {
                fits = fps <= 30.5 || caps.h264_720p60
            }
        case .hevc:
            if is4K {
                fits = caps.display("hevc_4k60")
            } else if is1080 {
                fits = caps.display("hevc_1080p60") || caps.mse("hvc1")
            } else {
                fits = caps.mse("hvc1")
            }
        }
        // An HDR source passes only where the receiver shows that HDR
        // transfer at this size; otherwise it would play as washed-out SDR.
        let hdrFits = s.hdrTransfer.map { caps.hdr($0, width: s.width, height: s.height) } ?? true
        if fits && hdrFits && !force {
            return CastVideoDecision(output: nil, reason: "receiver displays the source")
        }
        let is720High = s.codec == .h264 && !is4K && !is1080 && !fits
        // H.264 1080 above 30.5 fps that the receiver cannot present, on a
        // receiver that cannot hold 60 fps H.264 even at 720 either: the
        // 720p60 profile would play slow too, so halve the rate instead.
        let is1080High = s.codec == .h264 && is1080 && !fits && fps > 30.5 && !caps.h264_720p60
        let trigger = force ? "Developer switch"
            : (unmeasured ?? (is1080High && !caps.hevc1080 ? "receiver does not display 60 fps H.264"
                              : is720High ? "receiver does not display 720p60"
                              : fits ? "receiver does not display \(s.hdrTransfer?.label ?? "HDR") HDR"
                              : "source above receiver display"))
        // The note's "doesn't support" list: only answers the receiver
        // actually gave (none when unmeasured or forced).
        var unsupported: [String] = []
        if !force, unmeasured == nil {
            if s.codec == .hevc && !caps.hevc1080 && !caps.mse("hvc1") { unsupported.append("HEVC") }
            if !fits && is4K { unsupported.append("4K") }
            if !fits && is1080 && s.codec == .h264 {
                unsupported.append(caps.display("h264_1080p30") ? "1080p60" : "1080p")
            }
            if is720High { unsupported.append("720p60") }
            // HDR is named when the receiver shows it at no size, or when
            // it is the only thing that stopped a passthrough.
            if !hdrFits, let t = s.hdrTransfer,
               !caps.hdr(t, width: 1280, height: 720) || unsupported.isEmpty {
                unsupported.append("HDR")
            }
        }
        func out(_ spec: CastVideoOutputSpec) -> CastVideoDecision {
            CastVideoDecision(output: spec, reason: trigger, unsupported: unsupported, forced: force)
        }
        // HDR survives the transcode only as 10-bit HEVC the receiver shows
        // as HDR at the output size.
        func keepsHDR(_ w: Int, _ h: Int) -> Bool {
            guard let t = s.hdrTransfer, s.bitDepth > 8 else { return false }
            return caps.hdr(t, width: w, height: h)
        }
        // H.264 up to 720 above 30.5 fps on a receiver that cannot present
        // 720p60: H.264 at the source size and half the frame rate (the
        // transcoder drops every other decoded frame; output PTS stay the
        // source PTS, so the timeline is continuous).
        if is720High && !force {
            return out(CastVideoOutputSpec(codec: .h264, width: even(s.width), height: even(s.height),
                                            frameStep: 2, bitrateCap: CastVideoOutputSpec.h264Cap))
        }
        if is4K && caps.hevc4K && (s.codec == .h264 || force) {
            return out(CastVideoOutputSpec(codec: .hevc, width: even(s.width), height: even(s.height),
                                            frameStep: 1, bitrateCap: CastVideoOutputSpec.hevc4KCap,
                                            hdr: keepsHDR(s.width, s.height)))
        }
        if caps.hevc1080 {
            let size = Self.fit(s.width, s.height, maxWidth: 1920, maxHeight: 1080)
            return out(CastVideoOutputSpec(codec: .hevc, width: size.width, height: size.height,
                                            frameStep: 1, bitrateCap: CastVideoOutputSpec.hevc1080Cap,
                                            hdr: keepsHDR(size.width, size.height)))
        }
        // No 60 fps H.264 at all: 1080 at half rate, whatever the
        // Developer profile says.
        if is1080High && !force {
            let size = Self.fit(s.width, s.height, maxWidth: 1920, maxHeight: 1080)
            return out(CastVideoOutputSpec(codec: .h264, width: size.width, height: size.height,
                                            frameStep: 2, bitrateCap: CastVideoOutputSpec.h264Cap))
        }
        // 1080p30 needs the receiver to present 1080p30; otherwise 720p.
        let profile: CastTranscodeDownProfile =
            (downProfile == .p1080p30 && (caps.display("h264_1080p30") || caps.display == nil))
            ? .p1080p30 : .p720p60
        switch profile {
        case .p720p60:
            let size = Self.fit(s.width, s.height, maxWidth: 1280, maxHeight: 720)
            return out(CastVideoOutputSpec(codec: .h264, width: size.width, height: size.height,
                                            frameStep: 1, bitrateCap: CastVideoOutputSpec.h264Cap))
        case .p1080p30:
            let size = Self.fit(s.width, s.height, maxWidth: 1920, maxHeight: 1080)
            return out(CastVideoOutputSpec(codec: .h264, width: size.width, height: size.height,
                                            frameStep: highRate ? 2 : 1, bitrateCap: CastVideoOutputSpec.h264Cap))
        }
    }

    /// No VUI timing: the level tells the rate class. H.264 level 4.1 and
    /// up is the 1080p50/60 class; for HEVC that is level 4.1 at 1080 and
    /// 5.1 at 4K (general_level_idc 123 and 153).
    private static func fallbackFPS(_ s: CastVideoStreamInfo, is4K: Bool) -> Double {
        switch s.codec {
        case .h264: return s.levelIDC > 40 ? 60 : 30
        case .hevc: return s.levelIDC >= (is4K ? 153 : 123) ? 60 : 30
        }
    }

    /// `[Cast] video plan: source=avc1.64002A 1920x1080@59.94 receiver
    /// display h264_1080p60=no h264_1080p30=yes hevc_1080p60=no hvc1=no ->
    /// transcode H.264 720p59.94 level 4.1 (8000 kbps)`.
    func logLine(source s: CastVideoStreamInfo, decision d: CastVideoDecision) -> String {
        let caps = self.caps ?? CastReceiverVideoCaps(mse: [:], display: nil)
        func yn(_ b: Bool) -> String { b ? "yes" : "no" }
        var line = "[Cast] video plan: source=\(s.codecString) \(s.label)"
        if s.bitDepth > 8 { line += " \(s.bitDepth)-bit" }
        if let t = s.hdrTransfer { line += " HDR \(t.label)" }
        if !s.progressive { line += " interlaced" }
        if self.caps == nil {
            line += " receiver caps=none"
        } else if caps.display == nil {
            line += " receiver display=none hvc1=\(yn(caps.mse("hvc1")))"
        } else {
            line += " receiver display h264_1080p60=\(yn(caps.display("h264_1080p60")))"
                + " h264_1080p30=\(yn(caps.display("h264_1080p30")))"
            if s.codec == .h264 && s.width <= 1920 && s.height <= 1088 {
                line += " h264_720p60=" + (caps.display?["h264_720p60"].map(yn) ?? "n/a")
            }
            line += " hevc_1080p60=\(yn(caps.display("hevc_1080p60")))"
            if s.codec == .hevc { line += " hevc_4k60=\(yn(caps.display("hevc_4k60")))" }
            line += " hvc1=\(yn(caps.mse("hvc1")))"
            if let t = s.hdrTransfer {
                let k = t.rawValue
                line += " hevc_1080p60_\(k)=\(yn(caps.display("hevc_1080p60_\(k)")))"
                    + " hevc_4k60_\(k)=\(yn(caps.display("hevc_4k60_\(k)")))"
                    + " hvc1.\(k)=\(yn(caps.mse("hvc1.\(k)")))"
            }
        }
        guard let out = d.output else { return line + " -> passthrough (\(d.reason))" }
        let fps = out.outputFPS(s.fps).map(Self.fpsLabel) ?? ""
        let kbps = out.bitrateCap / 1000
        switch out.codec {
        case .hevc:
            let profile = CastVideoTranscoder.outputTenBit(source: s, spec: out) ? "HEVC Main10" : "HEVC"
            line += " -> transcode \(profile) \(out.height)p\(fps) (\(kbps) kbps)"
        case .h264:
            line += " -> transcode H.264 \(out.height)p\(fps) level 4.1 (\(kbps) kbps)"
        }
        if let t = s.hdrTransfer { line += out.hdr ? " HDR \(t.label) kept" : " HDR \(t.label) -> SDR BT.709" }
        if force { line += " [forced]" }
        return line
    }

    /// 59.94 stays 59.94, 50.0 prints as 50, 59.9 as 59.9 (at most two
    /// decimals, trailing zeros trimmed).
    static func fpsLabel(_ fps: Double) -> String {
        var s = String(format: "%.2f", fps)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    /// "HEVC 3840x2160 at 50fps" (Logan's note format, no space before
    /// fps); the frame rate is left out when unknown.
    static func describe(_ codec: CastVideoCodec, width: Int, height: Int, fps: Double?) -> String {
        var s = "\(codec.displayName) \(width)x\(height)"
        if let fps { s += " at \(fpsLabel(fps))fps" }
        return s
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

    /// HEVC SPS fields the hvcC record repeats, plus what the video plan
    /// and the transcoder read.
    struct HEVCSPSInfo: Equatable {
        /// general_profile_space .. general_level_idc: the 12 bytes hvcC
        /// copies verbatim.
        var generalPTL: [UInt8]
        var maxSubLayersMinus1: Int
        var temporalIdNesting: Bool
        var chromaFormatIDC: Int
        var bitDepthLumaMinus8: Int
        var bitDepthChromaMinus8: Int
        /// After the conformance window.
        var width: Int
        var height: Int
        // Everything below is read best effort past the bit depths (the
        // hvcC fields above never depend on it): nil or default when the
        // tail is unreadable or absent.
        /// sps_max_num_reorder_pics of the highest sub-layer.
        var maxNumReorderPics: Int?
        /// time_scale / num_units_in_tick from the VUI timing info.
        var fps: Double?
        /// VUI field_seq_flag: each picture is a field.
        var fieldCoding = false
        var fullRange = false
        var colourPrimaries: Int?
        var transferCharacteristics: Int?
        var matrixCoefficients: Int?

        var generalProfileIDC: Int { Int(generalPTL[0] & 0x1F) }
        var generalLevelIDC: Int { Int(generalPTL[11]) }
    }

    /// Parse an HEVC SPS NAL (2-byte header included, emulation
    /// prevention bytes still in). ITU-T H.265 7.3.2.2 and E.2.1.
    static func parseHEVCSPS(_ nal: [UInt8]) -> HEVCSPSInfo? {
        guard nal.count > 15, (nal[0] >> 1) & 0x3F == 33 else { return nil }
        let rbsp = CastFMP4Remuxer.unescapeRBSP(nal, from: 2)
        guard rbsp.count >= 13 else { return nil }
        let maxSub = Int((rbsp[0] >> 1) & 0x07)
        let nesting = rbsp[0] & 1 == 1
        let ptl = Array(rbsp[1..<13])
        var r = CastFMP4Remuxer.BitReader(rbsp)
        do {
            _ = try r.bits(8) // vps id, max_sub_layers_minus1, nesting
            try skipProfileTierLevel(&r, maxSubLayersMinus1: maxSub)
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
            var info = HEVCSPSInfo(generalPTL: ptl, maxSubLayersMinus1: maxSub, temporalIdNesting: nesting,
                                   chromaFormatIDC: chroma, bitDepthLumaMinus8: luma,
                                   bitDepthChromaMinus8: chromaDepth, width: width, height: height)
            try? parseHEVCSPSTail(&r, maxSub: maxSub, into: &info)
            return info
        } catch {
            return nil
        }
    }

    /// general profile_tier_level (96 bits) plus the sub-layer flags and
    /// sub-layer PTLs, shared by the VPS and the SPS.
    private static func skipProfileTierLevel(_ r: inout CastFMP4Remuxer.BitReader,
                                             maxSubLayersMinus1 maxSub: Int) throws {
        _ = try r.bits(96)
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
    }

    /// SPS from log2_max_pic_order_cnt_lsb_minus4 through the VUI timing
    /// info: the reorder depth, colour description and frame rate.
    private static func parseHEVCSPSTail(_ r: inout CastFMP4Remuxer.BitReader, maxSub: Int,
                                         into info: inout HEVCSPSInfo) throws {
        let log2MaxPOCLsb = try r.ue() + 4
        let orderingForAll = try r.bits(1) == 1
        for _ in (orderingForAll ? 0 : maxSub)...maxSub {
            _ = try r.ue() // sps_max_dec_pic_buffering_minus1
            info.maxNumReorderPics = try r.ue() // the last one read is the highest sub-layer's
            _ = try r.ue() // sps_max_latency_increase_plus1
        }
        for _ in 0..<6 { _ = try r.ue() } // coding / transform block sizes, hierarchy depths
        if try r.bits(1) == 1, try r.bits(1) == 1 { // scaling_list_enabled, sps_scaling_list_data_present
            try skipHEVCScalingListData(&r)
        }
        _ = try r.bits(2) // amp_enabled, sample_adaptive_offset_enabled
        if try r.bits(1) == 1 { // pcm_enabled
            _ = try r.bits(8) // pcm sample bit depths
            _ = try r.ue(); _ = try r.ue()
            _ = try r.bits(1) // pcm_loop_filter_disabled
        }
        let numSets = try r.ue()
        guard numSets <= 64 else { throw CastFMP4Remuxer.SPSParseError() }
        // st_ref_pic_set (7.3.7): an inter-predicted set's length depends
        // on NumDeltaPocs of the set before it.
        var numDeltaPocs: [Int] = []
        for i in 0..<numSets {
            var predicted = false // inter_ref_pic_set_prediction_flag
            if i != 0 { predicted = try r.bits(1) == 1 }
            if predicted {
                _ = try r.bits(1) // delta_rps_sign
                _ = try r.ue() // abs_delta_rps_minus1
                var count = 0
                for _ in 0...numDeltaPocs[i - 1] {
                    var kept = try r.bits(1) == 1 // used_by_curr_pic_flag
                    if !kept { kept = try r.bits(1) == 1 } // use_delta_flag
                    if kept { count += 1 }
                }
                numDeltaPocs.append(count)
            } else {
                let negative = try r.ue()
                let positive = try r.ue()
                guard negative <= 16, positive <= 16 else { throw CastFMP4Remuxer.SPSParseError() }
                for _ in 0..<(negative + positive) { _ = try r.ue(); _ = try r.bits(1) }
                numDeltaPocs.append(negative + positive)
            }
        }
        if try r.bits(1) == 1 { // long_term_ref_pics_present
            let n = try r.ue()
            guard n <= 32 else { throw CastFMP4Remuxer.SPSParseError() }
            for _ in 0..<n { _ = try r.bits(log2MaxPOCLsb); _ = try r.bits(1) }
        }
        _ = try r.bits(2) // sps_temporal_mvp_enabled, strong_intra_smoothing_enabled
        guard try r.bits(1) == 1 else { return } // vui_parameters_present_flag
        if try r.bits(1) == 1 { // aspect_ratio_info_present_flag
            if try r.bits(8) == 255 { _ = try r.bits(32) } // Extended_SAR
        }
        if try r.bits(1) == 1 { _ = try r.bits(1) } // overscan
        if try r.bits(1) == 1 { // video_signal_type_present_flag
            _ = try r.bits(3) // video_format
            info.fullRange = try r.bits(1) == 1
            if try r.bits(1) == 1 { // colour_description_present_flag
                info.colourPrimaries = try r.bits(8)
                info.transferCharacteristics = try r.bits(8)
                info.matrixCoefficients = try r.bits(8)
            }
        }
        if try r.bits(1) == 1 { _ = try r.ue(); _ = try r.ue() } // chroma_loc_info
        _ = try r.bits(1) // neutral_chroma_indication_flag
        info.fieldCoding = try r.bits(1) == 1
        _ = try r.bits(1) // frame_field_info_present_flag
        if try r.bits(1) == 1 { for _ in 0..<4 { _ = try r.ue() } } // default_display_window
        if try r.bits(1) == 1 { // vui_timing_info_present_flag
            info.fps = try readTiming(&r)
        }
    }

    /// num_units_in_tick + time_scale. Unlike H.264 there is no factor of
    /// two: one HEVC tick is one picture.
    private static func readTiming(_ r: inout CastFMP4Remuxer.BitReader) throws -> Double? {
        let unitsInTick = try r.bits(32)
        let timeScale = try r.bits(32)
        guard unitsInTick > 0, timeScale > 0 else { return nil }
        let fps = Double(timeScale) / Double(unitsInTick)
        return fps >= 1 && fps <= 300 ? fps : nil
    }

    /// scaling_list_data() (7.3.4).
    private static func skipHEVCScalingListData(_ r: inout CastFMP4Remuxer.BitReader) throws {
        for sizeId in 0..<4 {
            for _ in stride(from: 0, to: 6, by: sizeId == 3 ? 3 : 1) {
                if try r.bits(1) == 0 { // scaling_list_pred_mode_flag
                    _ = try r.ue() // scaling_list_pred_matrix_id_delta
                } else {
                    if sizeId > 1 { _ = try r.se() } // scaling_list_dc_coef_minus8
                    for _ in 0..<min(64, 1 << (4 + (sizeId << 1))) { _ = try r.se() }
                }
            }
        }
    }

    /// Frame rate from the VPS timing info (7.3.2.1). Broadcast encoders
    /// often put the timing there and leave the SPS VUI without it.
    static func parseHEVCVPSFrameRate(_ nal: [UInt8]) -> Double? {
        guard nal.count > 6, (nal[0] >> 1) & 0x3F == 32 else { return nil }
        var r = CastFMP4Remuxer.BitReader(CastFMP4Remuxer.unescapeRBSP(nal, from: 2))
        do {
            _ = try r.bits(12) // vps id, base layer flags, vps_max_layers_minus1
            let maxSub = try r.bits(3)
            _ = try r.bits(17) // temporal_id_nesting, vps_reserved_0xffff_16bits
            try skipProfileTierLevel(&r, maxSubLayersMinus1: maxSub)
            let orderingForAll = try r.bits(1) == 1
            for _ in (orderingForAll ? 0 : maxSub)...maxSub { _ = try r.ue(); _ = try r.ue(); _ = try r.ue() }
            let maxLayerID = try r.bits(6)
            let numLayerSets = try r.ue() + 1
            guard numLayerSets <= 1024 else { return nil }
            for _ in 1..<max(1, numLayerSets) {
                for _ in 0...maxLayerID { _ = try r.bits(1) } // layer_id_included_flag
            }
            guard try r.bits(1) == 1 else { return nil } // vps_timing_info_present_flag
            return try readTiming(&r)
        } catch {
            return nil
        }
    }

    /// The HEVC source facts the video plan and the transcoder need, from
    /// the SPS (and the VPS for a frame rate the SPS lacks).
    static func hevcStreamInfo(sps: [UInt8], vps: [UInt8]?) -> CastVideoStreamInfo? {
        guard let s = parseHEVCSPS(sps), s.width > 0, s.height > 0, s.width <= 8192, s.height <= 8192 else {
            return nil
        }
        var info = CastVideoStreamInfo(codec: .hevc, width: s.width, height: s.height,
                                       profileIDC: s.generalProfileIDC, constraintFlags: 0,
                                       levelIDC: s.generalLevelIDC, progressive: !s.fieldCoding)
        info.fps = s.fps ?? vps.flatMap(parseHEVCVPSFrameRate)
        info.fullRange = s.fullRange
        info.colourPrimaries = s.colourPrimaries
        info.transferCharacteristics = s.transferCharacteristics
        info.matrixCoefficients = s.matrixCoefficients
        info.maxNumReorderFrames = s.maxNumReorderPics
        info.bitDepth = s.bitDepthLumaMinus8 + 8
        info.chromaFormat = s.chromaFormatIDC
        info.hevcPTL = s.generalPTL
        return info
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
    /// One source access unit: 4-byte-length H.264 or HEVC NAL units with
    /// the parameter sets, AUDs and filler already removed, 90 kHz
    /// unwrapped timestamps, and the parameter sets in force for it
    /// ([SPS, PPS] for H.264, [VPS, SPS, PPS] for HEVC).
    func feed(_ sample: [UInt8], pts: Int64, dts: Int64, keyframe: Bool, parameterSets: [[UInt8]])
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
        let parameterSets: [[UInt8]]
    }

    private struct DecodedFrame: @unchecked Sendable {
        let image: CVImageBuffer
        let pts: Int64
    }

    private let source: CastVideoStreamInfo
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
    private var decoderParameterSets: [[UInt8]] = []
    private var encoder: VTCompressionSession?
    /// HDR to SDR tone map (HDR source, SDR output); nil otherwise.
    private var toneMapper: VTPixelTransferSession?
    private var toneMapPool: CVPixelBufferPool?
    private var toneMapTagsChecked = false
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

    init(source: CastVideoStreamInfo, spec: CastVideoOutputSpec, targetKeyTicks: Int64,
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

    func feed(_ sample: [UInt8], pts: Int64, dts: Int64, keyframe: Bool, parameterSets: [[UInt8]]) {
        var dropped = 0
        var backlogSeconds = 0.0
        var schedule = false
        lock.lock()
        if released || failed { lock.unlock(); return }
        pending.append(InputFrame(data: sample, pts: pts, dts: dts, keyframe: keyframe,
                                  parameterSets: parameterSets))
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
        if frame.keyframe && (decoder == nil || frame.parameterSets != decoderParameterSets) {
            guard makeDecoder(parameterSets: frame.parameterSets) else { return }
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

    /// An HDR source on an SDR output: the frames need a real HDR to SDR
    /// conversion, not just new tags (the Chromecast Ultra case).
    private var toneMaps: Bool { source.isHDR && !spec.hdr }

    /// 10-bit encode: HEVC Main10 that keeps HDR, or a 10-bit SDR HEVC
    /// source re-encoded as HEVC. A tone-mapped output is always 8-bit.
    static func outputTenBit(source: CastVideoStreamInfo, spec: CastVideoOutputSpec) -> Bool {
        spec.codec == .hevc && source.bitDepth > 8 && (spec.hdr || !source.isHDR)
    }

    private func encode(_ d: DecodedFrame) {
        lastReleasedPTS = d.pts
        presentedIndex += 1
        if spec.frameStep > 1, (presentedIndex - 1) % spec.frameStep != 0 { return }
        if encoder == nil {
            guard makeEncoder() else { return }
        }
        guard let encoder else { return }
        var image: CVImageBuffer = d.image
        if toneMaps {
            guard let mapped = toneMap(d.image) else {
                noteError("HDR to SDR conversion failed")
                return
            }
            image = mapped
        }
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
            encoder, imageBuffer: image,
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

    private func makeDecoder(parameterSets: [[UInt8]]) -> Bool {
        let needed = source.codec == .hevc ? 3 : 2
        guard parameterSets.count == needed, parameterSets.allSatisfy({ !$0.isEmpty }) else { return false }
        let (status, formatOut) = Self.makeFormat(parameterSets, codec: source.codec)
        guard status == noErr, let format = formatOut else {
            noteError("source parameter sets rejected (\(status))")
            return false
        }
        // A VPS / SPS / PPS change the running session can take (same size
        // and profile) keeps it; anything else rebuilds it below.
        if let decoder, VTDecompressionSessionCanAcceptFormatDescription(decoder, formatDescription: format) {
            decoderFormat = format
            decoderParameterSets = parameterSets
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
        // 10-bit output when the HEVC encoder keeps it (Main10), and for
        // the HDR tone map: VideoToolbox needs the full 10-bit HLG / PQ
        // signal to map it, and an 8-bit decode would truncate first.
        // Otherwise 8-bit 4:2:0 straight from the decoder.
        let tenBit = source.bitDepth > 8 && (Self.outputTenBit(source: source, spec: spec) || toneMaps)
        let pixelFormat: OSType
        switch (tenBit, source.fullRange) {
        case (true, true): pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        case (true, false): pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        case (false, true): pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        case (false, false): pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }
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
            fail("hardware \(source.codec.displayName) decoder unavailable (\(createStatus))")
            return false
        }
        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        decoder = session
        decoderFormat = format
        decoderParameterSets = parameterSets
        return true
    }

    /// Format description from in-band parameter sets, 4-byte NAL lengths.
    private static func makeFormat(_ sets: [[UInt8]],
                                   codec: CastVideoCodec) -> (OSStatus, CMFormatDescription?) {
        // Contiguous copies: the CoreMedia call wants every set's pointer at
        // once, which nested withUnsafeBufferPointer calls cannot give for
        // a variable count.
        let buffers = sets.map { set -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            p.initialize(from: set, count: set.count)
            return p
        }
        defer { buffers.forEach { $0.deallocate() } }
        let pointers = buffers.map { UnsafePointer($0) }
        let sizes = sets.map { $0.count }
        var format: CMFormatDescription?
        let status: OSStatus
        switch codec {
        case .h264:
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                parameterSetPointers: pointers, parameterSetSizes: sizes,
                nalUnitHeaderLength: 4, formatDescriptionOut: &format)
        case .hevc:
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                parameterSetPointers: pointers, parameterSetSizes: sizes,
                nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format)
        }
        return (status, format)
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
            // Main10 keeps a 10-bit HLG / PQ source's signal; the color
            // tags below carry its BT.2020 primaries and transfer.
            set(kVTCompressionPropertyKey_ProfileLevel,
                Self.outputTenBit(source: source, spec: spec)
                    ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel)
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
        // Colour tags land in the output VUI. A tone-mapped HDR source is
        // BT.709 now; tagging it with the source's BT.2020 / HLG would make
        // the receiver misread the SDR pixels.
        if toneMaps {
            set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
            set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
            set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        } else {
            if let v = Self.colourPrimaries(source.colourPrimaries) { set(kVTCompressionPropertyKey_ColorPrimaries, v) }
            if let v = Self.transferFunction(source.transferCharacteristics) {
                set(kVTCompressionPropertyKey_TransferFunction, v)
            }
            if let v = Self.yCbCrMatrix(source.matrixCoefficients) { set(kVTCompressionPropertyKey_YCbCrMatrix, v) }
        }
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
        case .hevc: target = Self.outputTenBit(source: source, spec: spec) ? "HEVC Main10" : "HEVC Main"
        case .h264: target = "H.264 High 4.1"
        }
        let outFPS = spec.outputFPS(source.fps).map(CastVideoPlan.fpsLabel) ?? "?"
        let hardware = usingHardware.map { CFBooleanGetValue($0) } == false
            ? "VideoToolbox, NOT hardware" : "VideoToolbox hardware"
        let depth = source.bitDepth > 8 ? " \(source.bitDepth)-bit" : ""
        log("video transcode: \(source.codec.displayName) \(source.width)x\(source.height)"
            + "@\(source.fps.map(CastVideoPlan.fpsLabel) ?? "?")\(depth) "
            + "level \(source.levelLabel) -> \(target) \(spec.width)x\(spec.height)@\(outFPS), "
            + "target \(targetBitrate / 1000) kbps (\(hardware))")
        if let t = source.hdrTransfer {
            log(spec.hdr ? "video transcode: HDR \(t.label) kept (receiver displays it)"
                : "video transcode: HDR \(t.label) -> SDR BT.709 (tone mapped on the phone)")
        }
        return true
    }

    // MARK: HDR to SDR

    /// One decoded HDR frame to 8-bit 4:2:0 BT.709. The pixel transfer
    /// session reads the source's colour attachments and, seeing HLG / PQ
    /// in and BT.709 out, performs the tone map itself; retagging alone
    /// is what made the Chromecast Ultra picture washed out.
    private func toneMap(_ src: CVImageBuffer) -> CVImageBuffer? {
        if toneMapper == nil {
            var session: VTPixelTransferSession?
            let st = VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session)
            guard st == noErr, let session else {
                fail("HDR to SDR pixel transfer unavailable (\(st))")
                return nil
            }
            let props: [CFString: CFTypeRef] = [
                kVTPixelTransferPropertyKey_DestinationColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
                kVTPixelTransferPropertyKey_DestinationTransferFunction: kCVImageBufferTransferFunction_ITU_R_709_2,
                kVTPixelTransferPropertyKey_DestinationYCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            ]
            for (key, value) in props {
                let r = VTSessionSetProperty(session, key: key, value: value)
                if r != noErr { log("video transcode: pixel transfer refused \(key) (\(r))") }
            }
            let poolAttrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey: CVPixelBufferGetWidth(src),
                kCVPixelBufferHeightKey: CVPixelBufferGetHeight(src),
                kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
            ]
            var pool: CVPixelBufferPool?
            let ps = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, poolAttrs as CFDictionary, &pool)
            guard ps == kCVReturnSuccess, let pool else {
                VTPixelTransferSessionInvalidate(session)
                fail("HDR to SDR buffer pool unavailable (\(ps))")
                return nil
            }
            toneMapper = session
            toneMapPool = pool
        }
        guard let session = toneMapper, let pool = toneMapPool else { return nil }
        // Without the source's colour attachments VideoToolbox would treat
        // the frame as untagged and copy it without a tone map. The decoder
        // normally attaches them from the SPS VUI; if not, attach them here.
        let tagged = CVBufferCopyAttachment(src, kCVImageBufferTransferFunctionKey, nil) != nil
        if !tagged {
            if let v = Self.colourPrimaries(source.colourPrimaries) {
                CVBufferSetAttachment(src, kCVImageBufferColorPrimariesKey, v, .shouldPropagate)
            }
            if let v = Self.transferFunction(source.transferCharacteristics) {
                CVBufferSetAttachment(src, kCVImageBufferTransferFunctionKey, v, .shouldPropagate)
            }
            if let v = Self.yCbCrMatrix(source.matrixCoefficients) {
                CVBufferSetAttachment(src, kCVImageBufferYCbCrMatrixKey, v, .shouldPropagate)
            }
        }
        if !toneMapTagsChecked {
            toneMapTagsChecked = true
            let tf = CVBufferCopyAttachment(src, kCVImageBufferTransferFunctionKey, nil) as? String ?? "none"
            let cp = CVBufferCopyAttachment(src, kCVImageBufferColorPrimariesKey, nil) as? String ?? "none"
            log("video transcode: decoder output colour tags \(tagged ? "present" : "missing, attached from the SPS VUI")"
                + " (transfer \(tf), primaries \(cp))")
        }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out) == kCVReturnSuccess,
              let out else { return nil }
        // The encoder reads these to confirm what it was handed is BT.709.
        CVBufferSetAttachment(out, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(out, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(out, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        guard VTPixelTransferSessionTransferImage(session, from: src, to: out) == noErr else { return nil }
        return out
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
        decoderParameterSets = []
        if let encoder {
            VTCompressionSessionInvalidate(encoder)
            self.encoder = nil
        }
        if let toneMapper {
            VTPixelTransferSessionInvalidate(toneMapper)
            self.toneMapper = nil
        }
        toneMapPool = nil
        toneMapTagsChecked = false
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
        log("video transcode failed: \(reason); falling back to passthrough")
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
