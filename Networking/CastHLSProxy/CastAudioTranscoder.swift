//
//  CastAudioTranscoder.swift
//  Aerio
//
//  Cast HLS proxy P2: on-phone audio transcode for muxes whose audio the
//  web receiver cannot decode. Most of the live lineup (Dispatcharr raw
//  TS, typical panels) carries AC-3, E-AC-3, or MP2; Chromecast web
//  receivers cannot decode AC-3 themselves (HDMI passthrough only, and
//  unreliably), so the fix is to decode on the phone with AudioToolbox's
//  AudioConverter, downmix the PCM to stereo, and encode AAC-LC at about
//  160 kbps. H.264 video stays pure passthrough in the remuxer.
//

import Foundation
import AudioToolbox

/// Source codecs the transcode accepts. Anything else refuses by name in
/// the remuxer's PMT gate.
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

    var formatID: AudioFormatID {
        switch self {
        case .ac3: return kAudioFormatAC3
        case .eac3: return kAudioFormatEnhancedAC3
        case .mp2: return kAudioFormatMPEGLayer2
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

/// PTS flow: the source frame's unwrapped 90 kHz ticks anchor an exact
/// rational ladder, and every emitted AAC packet is stamped
/// anchor + n * 1024 * 90000 / sampleRate, computed from the anchor each
/// time so the non-integer 44.1 kHz frame duration never accumulates
/// drift. A stamp past the discontinuity threshold re-anchors; the
/// remuxer additionally calls `flush()` on source PTS jumps > 500 ms.
///
/// Threading: synchronous, driven entirely by the remuxer on the ingest
/// queue. No internal threads.
final class CastAudioTranscoder: CastAudioTranscoding {

    static let targetAACBitrate: UInt32 = 160_000
    static let aacSamplesPerFrame: Int64 = 1024

    /// Source PTS jump treated as a splice/reconnect: flush both codecs
    /// and re-anchor. 500 ms at 90 kHz.
    static let discontinuityTicks: Int64 = 45_000

    /// Regularizes output PTS onto an exact rational ladder anchored at
    /// the first (or post-discontinuity) stamp. Pure; unit-tested.
    struct AACPTSMapper {
        private let sampleRate: Int
        private let discontinuityTicks: Int64
        private var anchorTicks: Int64 = -1
        private var framesSinceAnchor: Int64 = 0

        init(sampleRate: Int, discontinuityTicks: Int64 = CastAudioTranscoder.discontinuityTicks) {
            self.sampleRate = sampleRate
            self.discontinuityTicks = discontinuityTicks
        }

        mutating func map(_ encoderPTSTicks: Int64) -> Int64 {
            if anchorTicks >= 0 {
                let expected = ladder(framesSinceAnchor)
                if abs(encoderPTSTicks - expected) > discontinuityTicks { anchorTicks = -1 }
            }
            if anchorTicks < 0 {
                anchorTicks = encoderPTSTicks
                framesSinceAnchor = 0
            }
            let pts = ladder(framesSinceAnchor)
            framesSinceAnchor += 1
            return pts
        }

        mutating func reset() {
            anchorTicks = -1
            framesSinceAnchor = 0
        }

        private func ladder(_ n: Int64) -> Int64 {
            anchorTicks + n * CastAudioTranscoder.aacSamplesPerFrame * CastFMP4Remuxer.ticksPerSecond / Int64(sampleRate)
        }
    }

    // MARK: elementary-stream frame parsers (pure; unit-tested)

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

    /// Interleaved 16-bit PCM to stereo. Decoders emit the standard
    /// order FL FR C LFE BL BR for 5.1; the mix is the plain coefficient
    /// downmix
    ///   L = FL + 0.707 * C + 0.707 * SL
    ///   R = FR + 0.707 * C + 0.707 * SR
    /// with LFE dropped and the result clamped to 16-bit. Mono
    /// duplicates, stereo passes through untouched. Layouts other than
    /// mono/stereo/3.0/5.1 are approximated by the same index positions
    /// (extras past 5.1 are ignored), which is fine for a cast downmix.
    static func downmixToStereo(_ pcm: [Int16], channels: Int) -> [Int16] {
        if channels == 2 { return pcm }
        if channels <= 0 { return [] }
        let frames = pcm.count / channels
        var out = [Int16](repeating: 0, count: frames * 2)
        for f in 0..<frames {
            let base = f * channels
            if channels == 1 {
                out[2 * f] = pcm[base]
                out[2 * f + 1] = pcm[base]
                continue
            }
            let c = channels >= 3 ? Double(pcm[base + 2]) * 0.707 : 0.0
            let sl = channels >= 5 ? Double(pcm[base + 4]) * 0.707 : 0.0
            let sr = channels >= 6 ? Double(pcm[base + 5]) * 0.707 : 0.0
            out[2 * f] = clamp16(Double(pcm[base]) + c + sl)
            out[2 * f + 1] = clamp16(Double(pcm[base + 1]) + c + sr)
        }
        return out
    }

    private static func clamp16(_ v: Double) -> Int16 {
        Int16(max(-32768, min(32767, v.rounded())))
    }

    // MARK: AudioConverter plumbing (device path)

    private let source: CastAudioSourceCodec
    private let onEncoderConfig: (_ asc: [UInt8], _ sampleRate: Int) -> Void
    private let onAACFrame: (_ data: [UInt8], _ ptsTicks: Int64) -> Void
    private let log: (String) -> Void

    private var decoder: AudioConverterRef?
    private var encoder: AudioConverterRef?
    private var sampleRate = 0
    private var pcmChannels = 0
    /// True when the decoder itself downmixes (multichannel PCM output
    /// was refused by AudioConverterNew, so it decodes straight to
    /// stereo and `downmixToStereo` is skipped).
    private var decoderOutputsStereo = false
    private var mapper: AACPTSMapper?
    private var configDelivered = false

    /// Interleaved stereo PCM waiting for the encoder.
    private var pcmFIFO: [Int16] = []
    /// Ladder anchor: source PTS of the first PCM sample after
    /// init/flush; output packet n is stamped from it (then regularized
    /// by the mapper).
    private var encoderAnchorTicks: Int64 = -1
    private var packetsEmitted: Int64 = 0

    /// One-frame handoff into the decoder's pull callback. Manually
    /// managed storage: AudioConverter keeps reading from the pointer
    /// the callback hands it until the Fill call returns, so the bytes
    /// must live somewhere no Swift array resize can move.
    private var decoderFrameStorage: UnsafeMutableRawPointer?
    private var decoderFrameCapacity = 0
    private var decoderFrameSize = 0
    private var decoderFrameAvailable = false
    private var decoderPacketDescription = AudioStreamPacketDescription()
    /// Encoder pull callback's handoff buffer; same stability contract.
    private var encoderFeedStorage: UnsafeMutableRawPointer?
    private var encoderFeedCapacity = 0

    init(source: CastAudioSourceCodec,
         onEncoderConfig: @escaping (_ asc: [UInt8], _ sampleRate: Int) -> Void,
         onAACFrame: @escaping (_ data: [UInt8], _ ptsTicks: Int64) -> Void,
         log: @escaping (String) -> Void) {
        self.source = source
        self.onEncoderConfig = onEncoderConfig
        self.onAACFrame = onAACFrame
        self.log = log
    }

    deinit { release() }

    /// Queue one source access unit (a whole AC-3/E-AC-3/MP2 frame) and
    /// drain both converters. Called on the ingest queue.
    ///
    /// Throws `CastUnsupportedCodecError` when the platform has no
    /// decoder for the source codec (first call only); any other codec
    /// failure surfaces as an error the session's reconnect path absorbs.
    func feed(_ data: [UInt8], range: Range<Int>, ptsTicks: Int64, info: CastESFrameInfo) throws {
        if decoder == nil { try initConverters(info) }
        let pcm = try decodeFrame(Array(data[range]), info: info)
        guard !pcm.isEmpty else { return }
        let stereo = decoderOutputsStereo ? pcm : Self.downmixToStereo(pcm, channels: pcmChannels)
        if encoderAnchorTicks < 0 {
            encoderAnchorTicks = ptsTicks
            packetsEmitted = 0
        }
        pcmFIFO.append(contentsOf: stereo)
        try drainEncoder()
    }

    /// Splice/reconnect: drop in-flight converter state and let the PTS
    /// ladder re-anchor on the next input stamp.
    func flush() {
        if let decoder { AudioConverterReset(decoder) }
        if let encoder { AudioConverterReset(encoder) }
        pcmFIFO.removeAll(keepingCapacity: true)
        encoderAnchorTicks = -1
        packetsEmitted = 0
        mapper?.reset()
    }

    func release() {
        if let decoder { AudioConverterDispose(decoder) }
        if let encoder { AudioConverterDispose(encoder) }
        decoder = nil
        encoder = nil
        decoderFrameStorage?.deallocate()
        decoderFrameStorage = nil
        decoderFrameCapacity = 0
        encoderFeedStorage?.deallocate()
        encoderFeedStorage = nil
        encoderFeedCapacity = 0
    }

    private struct ConverterError: Error { let status: OSStatus; let stage: String }

    private func initConverters(_ info: CastESFrameInfo) throws {
        var inDesc = AudioStreamBasicDescription(
            mSampleRate: Float64(info.sampleRate),
            mFormatID: source.formatID,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(info.samplesPerFrame),
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(info.channels),
            mBitsPerChannel: 0,
            mReserved: 0)
        var dec: AudioConverterRef?
        var pcmDesc = Self.pcmDescription(sampleRate: info.sampleRate, channels: info.channels)
        var status = AudioConverterNew(&inDesc, &pcmDesc, &dec)
        var outChannels = info.channels
        if status != noErr || dec == nil {
            // Some decoder configurations refuse multichannel PCM output;
            // fall back to letting the decoder downmix to stereo itself.
            pcmDesc = Self.pcmDescription(sampleRate: info.sampleRate, channels: 2)
            status = AudioConverterNew(&inDesc, &pcmDesc, &dec)
            outChannels = 2
        }
        guard status == noErr, let decRef = dec else {
            // Same refusal the remuxer makes for every non-AAC codec:
            // with no platform decoder there is nothing to transcode with.
            throw CastUnsupportedCodecError(codecName: "\(source.displayName) audio")
        }
        decoder = decRef
        pcmChannels = outChannels
        decoderOutputsStereo = outChannels == 2 && info.channels != 2
        sampleRate = info.sampleRate

        var encInDesc = Self.pcmDescription(sampleRate: info.sampleRate, channels: 2)
        var encOutDesc = AudioStreamBasicDescription(
            mSampleRate: Float64(info.sampleRate),
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(Self.aacSamplesPerFrame),
            mBytesPerFrame: 0,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 0,
            mReserved: 0)
        var enc: AudioConverterRef?
        let encStatus = AudioConverterNew(&encInDesc, &encOutDesc, &enc)
        guard encStatus == noErr, let encRef = enc else {
            AudioConverterDispose(decRef)
            decoder = nil
            throw ConverterError(status: encStatus, stage: "aac encoder create")
        }
        encoder = encRef
        var bitrate = Self.targetAACBitrate
        // Best effort; the encoder's default rate is acceptable when the
        // exact 160 kbps point is unsupported at this sample rate.
        _ = AudioConverterSetProperty(encRef, kAudioConverterEncodeBitRate,
                                      UInt32(MemoryLayout<UInt32>.size), &bitrate)
        mapper = AACPTSMapper(sampleRate: info.sampleRate)
        log("audio codecs up: decoder=AudioConverter(\(source.displayName)) "
            + "encoder=AAC-LC stereo \(Self.targetAACBitrate / 1000)kbps @\(info.sampleRate)Hz"
            + (decoderOutputsStereo ? " (decoder downmix)" : ""))
        deliverConfigIfNeeded()
    }

    private static func pcmDescription(sampleRate: Int, channels: Int) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(2 * channels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(2 * channels),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 16,
            mReserved: 0)
    }

    private func deliverConfigIfNeeded() {
        guard !configDelivered else { return }
        // AudioSpecificConfig built by hand: AAC-LC (objectType 2),
        // stereo, at the source sample rate. Deterministic, unlike
        // fishing the esds out of the converter's magic cookie.
        guard let freqIndex = Self.adtsFrequencyIndex(sampleRate) else { return }
        let asc: [UInt8] = [UInt8((2 << 3) | (freqIndex >> 1)),
                            UInt8(((freqIndex & 1) << 7) | (2 << 3))]
        configDelivered = true
        onEncoderConfig(asc, sampleRate)
    }

    private static func adtsFrequencyIndex(_ rate: Int) -> Int? {
        let rates = [96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000, 22_050,
                     16_000, 12_000, 11_025, 8_000, 7_350]
        return rates.firstIndex(of: rate)
    }

    // Sentinel the pull callbacks return when their FIFO is dry; Fill
    // then reports whatever it produced and stops asking.
    private static let noMoreDataNow: OSStatus = 0x6E6F6D6F // "nomo"

    private func decodeFrame(_ frame: [UInt8], info: CastESFrameInfo) throws -> [Int16] {
        guard let decoder else { return [] }
        if frame.count > decoderFrameCapacity {
            decoderFrameStorage?.deallocate()
            decoderFrameCapacity = max(frame.count, 4096)
            decoderFrameStorage = UnsafeMutableRawPointer.allocate(byteCount: decoderFrameCapacity, alignment: 8)
        }
        frame.withUnsafeBytes { decoderFrameStorage!.copyMemory(from: $0.baseAddress!, byteCount: frame.count) }
        decoderFrameSize = frame.count
        decoderFrameAvailable = true
        var out = [Int16]()
        let framesPerCall = info.samplesPerFrame
        var callBuffer = [Int16](repeating: 0, count: framesPerCall * pcmChannels)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        while true {
            var ioPackets = UInt32(framesPerCall)
            var produced: UInt32 = 0
            let status: OSStatus = callBuffer.withUnsafeMutableBytes { raw in
                var bufferList = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(mNumberChannels: UInt32(pcmChannels),
                                          mDataByteSize: UInt32(raw.count),
                                          mData: raw.baseAddress))
                let s = AudioConverterFillComplexBuffer(
                    decoder, Self.decoderInputProc, selfPtr, &ioPackets, &bufferList, nil)
                produced = ioPackets
                return s
            }
            if produced > 0 {
                out.append(contentsOf: callBuffer[0..<(Int(produced) * pcmChannels)])
            }
            if status == Self.noMoreDataNow || produced == 0 {
                if status != noErr, status != Self.noMoreDataNow {
                    throw ConverterError(status: status, stage: "decode")
                }
                break
            }
        }
        return out
    }

    /// Supplies exactly the one pending source frame, then reports dry.
    /// The storage pointer stays valid until the enclosing Fill returns.
    private static let decoderInputProc: AudioConverterComplexInputDataProc = {
        _, ioNumberDataPackets, ioData, outDataPacketDescription, inUserData in
        let self_ = Unmanaged<CastAudioTranscoder>.fromOpaque(inUserData!).takeUnretainedValue()
        guard self_.decoderFrameAvailable, let storage = self_.decoderFrameStorage else {
            ioNumberDataPackets.pointee = 0
            return CastAudioTranscoder.noMoreDataNow
        }
        self_.decoderFrameAvailable = false
        ioData.pointee.mNumberBuffers = 1
        ioData.pointee.mBuffers.mNumberChannels = 0
        ioData.pointee.mBuffers.mDataByteSize = UInt32(self_.decoderFrameSize)
        ioData.pointee.mBuffers.mData = storage
        if let descOut = outDataPacketDescription {
            self_.decoderPacketDescription = AudioStreamPacketDescription(
                mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(self_.decoderFrameSize))
            withUnsafeMutablePointer(to: &self_.decoderPacketDescription) { descOut.pointee = $0 }
        }
        ioNumberDataPackets.pointee = 1
        return noErr
    }

    private func drainEncoder() throws {
        guard let encoder else { return }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var outBuffer = [UInt8](repeating: 0, count: 8192)
        // Only start a Fill when a whole output packet's worth of input
        // is buffered, so the encoder never stalls mid-packet.
        while pcmFIFO.count >= Int(Self.aacSamplesPerFrame) * 2 {
            var ioPackets: UInt32 = 1
            var packetDesc = AudioStreamPacketDescription()
            let status: OSStatus = outBuffer.withUnsafeMutableBytes { raw in
                var bufferList = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(mNumberChannels: 2,
                                          mDataByteSize: UInt32(raw.count),
                                          mData: raw.baseAddress))
                return AudioConverterFillComplexBuffer(
                    encoder, Self.encoderInputProc, selfPtr, &ioPackets, &bufferList, &packetDesc)
            }
            if ioPackets > 0 {
                let size = Int(packetDesc.mDataByteSize)
                let offset = Int(packetDesc.mStartOffset)
                let frame = Array(outBuffer[offset..<(offset + size)])
                let raw = encoderAnchorTicks
                    + packetsEmitted * Self.aacSamplesPerFrame * CastFMP4Remuxer.ticksPerSecond / Int64(sampleRate)
                packetsEmitted += 1
                let pts = mapper != nil ? mapper!.map(raw) : raw
                onAACFrame(frame, pts)
            } else {
                if status != noErr, status != Self.noMoreDataNow {
                    throw ConverterError(status: status, stage: "encode")
                }
                break
            }
        }
    }

    /// Feeds the encoder from the stereo PCM FIFO; reports dry when the
    /// FIFO empties so Fill returns with what it has.
    private static let encoderInputProc: AudioConverterComplexInputDataProc = {
        _, ioNumberDataPackets, ioData, outDataPacketDescription, inUserData in
        let self_ = Unmanaged<CastAudioTranscoder>.fromOpaque(inUserData!).takeUnretainedValue()
        let availableFrames = self_.pcmFIFO.count / 2
        guard availableFrames > 0 else {
            ioNumberDataPackets.pointee = 0
            return CastAudioTranscoder.noMoreDataNow
        }
        let requested = Int(ioNumberDataPackets.pointee)
        let n = min(requested, availableFrames)
        let byteCount = n * 2 * MemoryLayout<Int16>.size
        if byteCount > self_.encoderFeedCapacity {
            self_.encoderFeedStorage?.deallocate()
            self_.encoderFeedCapacity = max(byteCount, 8192)
            self_.encoderFeedStorage = UnsafeMutableRawPointer.allocate(
                byteCount: self_.encoderFeedCapacity, alignment: MemoryLayout<Int16>.alignment)
        }
        self_.pcmFIFO.withUnsafeBytes {
            self_.encoderFeedStorage!.copyMemory(from: $0.baseAddress!, byteCount: byteCount)
        }
        self_.pcmFIFO.removeFirst(n * 2)
        ioData.pointee.mNumberBuffers = 1
        ioData.pointee.mBuffers.mNumberChannels = 2
        ioData.pointee.mBuffers.mDataByteSize = UInt32(byteCount)
        ioData.pointee.mBuffers.mData = self_.encoderFeedStorage
        outDataPacketDescription?.pointee = nil
        ioNumberDataPackets.pointee = UInt32(n)
        return noErr
    }
}
