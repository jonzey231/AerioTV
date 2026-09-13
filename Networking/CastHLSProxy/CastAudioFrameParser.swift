//
//  CastAudioFrameParser.swift
//  Aerio
//
//  Pure elementary-stream frame parsers for the cast HLS proxy, shared
//  by the passthrough framer and the MPEG audio transcoder. AAC and
//  (when the receiver reports support) AC-3 / E-AC-3 pass through
//  untouched, MPEG audio transcodes to AAC, and anything else is refused
//  by name. These parsers have no AudioToolbox dependency.
//

import Foundation

/// Source codecs the proxy can frame: AC-3 / E-AC-3 for passthrough and
/// MPEG audio for the transcode. Anything else refuses by name in the
/// remuxer's PMT gate.
enum CastAudioSourceCodec {
    case ac3
    case eac3
    case mp2

    var displayName: String {
        switch self {
        case .ac3: return "AC-3"
        case .eac3: return "E-AC-3"
        case .mp2: return "MP2"
        }
    }

}

/// Parsed elementary-stream frame header: everything the framer and the
/// decoder configuration need.
struct CastESFrameInfo {
    let frameLength: Int
    let sampleRate: Int
    let samplesPerFrame: Int
    let channels: Int
}

/// Bitstream fields an AC-3 / E-AC-3 passthrough needs to write the
/// `dac3` / `dec3` sample-entry box. Receivers that decode AC-3 pick
/// their decoder from that box plus the playlist CODECS attribute, so the
/// values are read from the first syncframe rather than assumed.
struct CastAC3SampleEntryConfig {
    let codec: CastAudioSourceCodec
    let fscod: Int
    let bsid: Int
    let bsmod: Int
    let acmod: Int
    let lfeon: Int
    /// AC-3 `bit_rate_code` (frmsizecod >> 1); unused for E-AC-3.
    let bitRateCode: Int
    /// E-AC-3 `data_rate` in kbit/s; unused for AC-3.
    let dataRateKbps: Int
    let sampleRate: Int
    let channels: Int
    let samplesPerFrame: Int

    /// RFC 6381 codec name for the HLS CODECS attribute.
    var codecsAttribute: String { codec == .eac3 ? "ec-3" : "ac-3" }
}

/// Elementary-stream frame header parsers (pure; unit-tested by
/// Scripts/cast-hls-proxy-tests).
enum CastAudioFrameParser {

    private static let ac3SampleRates = [48_000, 44_100, 32_000]
    private static let ac3BitratesKbps = [
        32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 448, 512, 576, 640,
    ]
    /// Full-bandwidth channels per acmod (A/52 table 5.8); lfeon adds one.
    private static let ac3AcmodChannels = [2, 1, 2, 3, 3, 4, 4, 5]
    private static let eac3Blocks = [1, 2, 3, 6]
    private static let mpeg1L2Bitrates = [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384]
    private static let mpeg1L3Bitrates = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
    private static let mpeg2Bitrates = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
    private static let mpegSampleRates = [44_100, 48_000, 32_000]

    /// Parse the frame header at `off`; nil when `off` is not a
    /// plausible frame start (the caller scans on).
    static func parseFrameHeader(_ codec: CastAudioSourceCodec, _ data: [UInt8], _ off: Int) -> CastESFrameInfo? {
        switch codec {
        case .ac3: return parseAC3Header(data, off)
        case .eac3: return parseEAC3Header(data, off)
        case .mp2: return parseMPEGAudioHeader(data, off)
        }
    }

    /// Cheap syncword check, used to reject false syncs by verifying the
    /// NEXT frame starts where the parsed length says.
    static func looksLikeSync(_ codec: CastAudioSourceCodec, _ data: [UInt8], _ off: Int) -> Bool {
        switch codec {
        case .ac3, .eac3:
            return off + 1 < data.count && data[off] == 0x0B && data[off + 1] == 0x77
        case .mp2:
            return off + 1 < data.count && data[off] == 0xFF && data[off + 1] & 0xE0 == 0xE0
        }
    }

    /// Full bitstream config for the passthrough sample entry. Returns
    /// nil for anything that is not a parseable AC-3 / E-AC-3 syncframe
    /// at `off` (the caller scans on, exactly like the framer does).
    static func parseAC3SampleEntryConfig(_ codec: CastAudioSourceCodec,
                                          _ data: [UInt8], _ off: Int) -> CastAC3SampleEntryConfig? {
        guard let info = parseFrameHeader(codec, data, off), off + 6 <= data.count else { return nil }
        switch codec {
        case .ac3:
            guard off + 7 <= data.count else { return nil }
            let fscod = (Int(data[off + 4]) >> 6) & 0x03
            let frmsizecod = Int(data[off + 4]) & 0x3F
            let bsid = (Int(data[off + 5]) >> 3) & 0x1F
            let bsmod = Int(data[off + 5]) & 0x07
            let acmod = (Int(data[off + 6]) >> 5) & 0x07
            // Same variable-field walk parseAC3Header does for lfeon.
            var bit = 3
            if acmod & 0x01 != 0, acmod != 1 { bit += 2 }
            if acmod & 0x04 != 0 { bit += 2 }
            if acmod == 2 { bit += 2 }
            let lfeon = (Int(data[off + 6]) >> (7 - bit)) & 1
            return CastAC3SampleEntryConfig(
                codec: .ac3, fscod: fscod, bsid: bsid, bsmod: bsmod, acmod: acmod, lfeon: lfeon,
                bitRateCode: frmsizecod >> 1, dataRateKbps: 0,
                sampleRate: info.sampleRate, channels: info.channels,
                samplesPerFrame: info.samplesPerFrame)
        case .eac3:
            let b4 = Int(data[off + 4])
            let fscod = (b4 >> 6) & 0x03
            let acmod = (b4 >> 1) & 0x07
            let lfeon = b4 & 0x01
            let bsid = off + 5 < data.count ? (Int(data[off + 5]) >> 3) & 0x1F : 16
            // bsmod sits behind E-AC-3's variable mixing metadata; 0
            // (complete main) is what every muxer writes for a broadcast
            // main program and what receivers assume.
            let dataRate = info.samplesPerFrame > 0
                ? info.frameLength * 8 * info.sampleRate / info.samplesPerFrame / 1000
                : 0
            return CastAC3SampleEntryConfig(
                codec: .eac3, fscod: fscod, bsid: bsid, bsmod: 0, acmod: acmod, lfeon: lfeon,
                bitRateCode: 0, dataRateKbps: dataRate,
                sampleRate: info.sampleRate, channels: info.channels,
                samplesPerFrame: info.samplesPerFrame)
        case .mp2:
            return nil
        }
    }

    private static func parseAC3Header(_ data: [UInt8], _ off: Int) -> CastESFrameInfo? {
        guard off + 7 <= data.count, looksLikeSync(.ac3, data, off) else { return nil }
        let fscod = (Int(data[off + 4]) >> 6) & 0x03
        let frmsizecod = Int(data[off + 4]) & 0x3F
        guard fscod != 3, frmsizecod < ac3BitratesKbps.count * 2 else { return nil }
        let bitrate = ac3BitratesKbps[frmsizecod >> 1]
        let words: Int
        switch fscod {
        case 0: words = 2 * bitrate
        case 1: words = 320 * bitrate / 147 + (frmsizecod & 1)
        default: words = 3 * bitrate
        }
        // acmod and lfeon sit behind variable mix-level fields; the whole
        // walk fits inside byte 6 (A/52 5.4.2).
        let acmod = (Int(data[off + 6]) >> 5) & 0x07
        var bit = 3
        if acmod & 0x01 != 0, acmod != 1 { bit += 2 } // cmixlev
        if acmod & 0x04 != 0 { bit += 2 }             // surmixlev
        if acmod == 2 { bit += 2 }                    // dsurmod
        let lfeon = (Int(data[off + 6]) >> (7 - bit)) & 1
        return CastESFrameInfo(frameLength: words * 2, sampleRate: ac3SampleRates[fscod],
                               samplesPerFrame: 1536, channels: ac3AcmodChannels[acmod] + lfeon)
    }

    private static func parseEAC3Header(_ data: [UInt8], _ off: Int) -> CastESFrameInfo? {
        guard off + 6 <= data.count, looksLikeSync(.eac3, data, off) else { return nil }
        let strmtyp = (Int(data[off + 2]) >> 6) & 0x03
        guard strmtyp != 3 else { return nil }
        let frmsiz = ((Int(data[off + 2]) & 0x07) << 8) | Int(data[off + 3])
        let b4 = Int(data[off + 4])
        let fscod = (b4 >> 6) & 0x03
        let sampleRate: Int
        let blocks: Int
        if fscod == 3 {
            let fscod2 = (b4 >> 4) & 0x03
            guard fscod2 != 3 else { return nil }
            sampleRate = ac3SampleRates[fscod2] / 2
            blocks = 6
        } else {
            sampleRate = ac3SampleRates[fscod]
            blocks = eac3Blocks[(b4 >> 4) & 0x03]
        }
        let acmod = (b4 >> 1) & 0x07
        let lfeon = b4 & 0x01
        return CastESFrameInfo(frameLength: (frmsiz + 1) * 2, sampleRate: sampleRate,
                               samplesPerFrame: blocks * 256, channels: ac3AcmodChannels[acmod] + lfeon)
    }

    private static func parseMPEGAudioHeader(_ data: [UInt8], _ off: Int) -> CastESFrameInfo? {
        guard off + 4 <= data.count, looksLikeSync(.mp2, data, off) else { return nil }
        let b2 = Int(data[off + 1])
        let version = (b2 >> 3) & 0x03 // 3 MPEG-1, 2 MPEG-2, 0 MPEG-2.5
        let layer = (b2 >> 1) & 0x03   // 2 layer II, 1 layer III
        guard version != 1, layer != 0, layer != 3 else { return nil } // reserved / layer I
        let b3 = Int(data[off + 2])
        let bitrateIndex = (b3 >> 4) & 0x0F
        let srIndex = (b3 >> 2) & 0x03
        let padding = (b3 >> 1) & 0x01
        guard bitrateIndex != 0, bitrateIndex != 15, srIndex != 3 else { return nil }
        let mpeg1 = version == 3
        let bitrate: Int
        if mpeg1, layer == 2 {
            bitrate = mpeg1L2Bitrates[bitrateIndex]
        } else if mpeg1 {
            bitrate = mpeg1L3Bitrates[bitrateIndex]
        } else {
            bitrate = mpeg2Bitrates[bitrateIndex]
        }
        let sampleRate: Int
        switch version {
        case 3: sampleRate = mpegSampleRates[srIndex]
        case 2: sampleRate = mpegSampleRates[srIndex] / 2
        default: sampleRate = mpegSampleRates[srIndex] / 4
        }
        let samples = (mpeg1 || layer == 2) ? 1152 : 576
        let frameLen = samples / 8 * bitrate * 1000 / sampleRate + padding
        let channels = ((Int(data[off + 3]) >> 6) & 0x03) == 3 ? 1 : 2
        return CastESFrameInfo(frameLength: frameLen, sampleRate: sampleRate,
                               samplesPerFrame: samples, channels: channels)
    }
}
