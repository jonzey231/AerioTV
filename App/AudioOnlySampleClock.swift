// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Rewrites the PTS (and DTS) of an audio-only program's primary audio
/// PES from a running sample clock.
///
/// Some providers stamp audio PES with PTS rounded to whole milliseconds
/// and nudge them ahead every few seconds (measured 2026-10-15 on a
/// SiriusXM AAC-LC 44.1 kHz feed: up to 0.88 ms off the sample clock per
/// PES, 3.1 to 4.4 ms jumps about every 10 s). AVPlayer renders audio to
/// the PES timestamps, so it pads or drops samples at every boundary and
/// the listener hears a tap about every 0.1 s. Counting the frames in
/// the elementary stream gives the true timeline:
/// `pts = base + samplesSoFar / sampleRate`.
///
/// Resync to the source PTS (one audible step) when it differs from the
/// computed value by more than 80 ms, goes backwards, the sample rate
/// changes, or the caller requests it (discontinuity, source switch).
/// Otherwise the computed clock wins; when the slow drift against the
/// source passes 60 ms it is slewed back at 1 ms per PES.
///
/// Pure logic: no app singletons, so the test scripts can compile it.
struct AudioOnlySampleClock {
    private static let wrap: Int64 = 1 << 33
    private static let resyncTicks: Int64 = 80 * 90      // 80 ms
    private static let slewStartTicks: Int64 = 60 * 90   // 60 ms
    private static let slewStepTicks: Int64 = 90         // 1 ms per PES
    private static let slewDoneTicks: Int64 = 2 * 90     // within 2 ms

    var streamType: UInt8
    var primaryPID: Int

    /// Unwrapped 90 kHz base, samples counted since the base, their rate.
    private var baseTicks: Int64 = 0
    private var samples: Int64 = 0
    private var rate = 0
    private var hasBase = false
    private var pendingResync: String?
    private var lastSourceTicks: Int64 = -1
    private var slewing = false
    private var loggedRewrite = false
    private var samplesPerFrameSeen = 0
    private var samplesAtLastStamp: Int64 = 0

    // Frame parser state carried across TS packets and PES boundaries.
    private var carry: [UInt8] = []
    private var skip = 0

    init(streamType: UInt8, primaryPID: Int) {
        self.streamType = streamType
        self.primaryPID = primaryPID
    }

    /// Stream types whose frame headers this clock can count.
    static func supports(_ type: UInt8) -> Bool {
        [0x0F, 0x81, 0x87, 0x03, 0x04].contains(type)
    }

    /// The next PES with a PTS takes the source PTS as the new base.
    /// A nil reason resyncs silently (first PES of a tune).
    mutating func requestResync(_ reason: String?) {
        pendingResync = reason ?? ""
        carry.removeAll()
        skip = 0
        slewing = false
    }

    /// Feed one primary-audio TS packet in arrival order. Returns the
    /// packet with its PES timestamps rewritten (unchanged when it does
    /// not open a PES with a PTS) plus any log lines.
    mutating func process(_ packet: Data) -> (packet: Data, logs: [String]) {
        guard packet.count == 188, Self.supports(streamType) else { return (packet, []) }
        var p = [UInt8](packet)
        let pusi = (p[1] & 0x40) != 0
        guard var off = Self.payloadStart(p) else { return (packet, []) }
        var logs: [String] = []
        var changed = false
        if pusi {
            guard off + 9 <= 188, p[off] == 0, p[off + 1] == 0, p[off + 2] == 1 else {
                return (packet, [])
            }
            let flags = p[off + 7] >> 6
            let headerEnd = off + 9 + Int(p[off + 8])
            if flags >= 2, off + 14 <= 188 {
                let src = Self.readTS(p, off + 9)
                let out = stamp(source: src, logs: &logs)
                if out != src {
                    Self.writeTS(&p, off + 9, out)
                    if flags == 3, off + 19 <= 188 {
                        let dts = Self.readTS(p, off + 14)
                        let delta = Self.signedDelta(out, src)
                        Self.writeTS(&p, off + 14, ((dts + delta) % Self.wrap + Self.wrap) % Self.wrap)
                    }
                    changed = true
                }
            }
            off = headerEnd
        }
        if off < 188 { feed(p[off..<188]) }
        return (changed ? Data(p) : packet, logs)
    }

    // MARK: Clock

    private var computedTicks: Int64 {
        guard rate > 0 else { return baseTicks }
        return baseTicks + (samples * 90_000 + Int64(rate / 2)) / Int64(rate)
    }

    private mutating func rebase(_ src: Int64) {
        baseTicks = src
        samples = 0
        hasBase = true
        slewing = false
    }

    /// The timestamp to write for a PES whose source PTS is `src`.
    private mutating func stamp(source src: Int64, logs: inout [String]) -> Int64 {
        defer { lastSourceTicks = src; samplesAtLastStamp = samples }
        if let reason = pendingResync {
            pendingResync = nil
            if hasBase, !reason.isEmpty {
                let diff = Self.signedDelta(src, computedTicks % Self.wrap)
                logs.append(Self.resyncLine(diff, reason))
            }
            rebase(src)
            return src
        }
        // No frames counted since the last PES: the parser lost the
        // stream, so the source is the only timeline there is.
        guard hasBase, rate > 0, samples > samplesAtLastStamp else {
            rebase(src)
            return src
        }
        let computed = computedTicks % Self.wrap
        let diff = Self.signedDelta(src, computed)
        let backwards = lastSourceTicks >= 0 && Self.signedDelta(src, lastSourceTicks) < 0
        if abs(diff) > Self.resyncTicks || backwards {
            logs.append(Self.resyncLine(diff, backwards ? "source went backwards" : nil))
            rebase(src)
            return src
        }
        if !loggedRewrite {
            loggedRewrite = true
            logs.append("[TS-REMUX] audio-only PTS rewritten from the sample clock (frame \(samplesPerFrameSeen) samples at \(rate) Hz)")
        }
        if !slewing, abs(diff) > Self.slewStartTicks {
            slewing = true
            logs.append(String(format: "[TS-REMUX] audio-only clock drift %+.1f ms against the source; slewing 1 ms per PES",
                               Double(diff) / 90))
        }
        if slewing {
            if abs(diff) <= Self.slewDoneTicks {
                slewing = false
            } else {
                baseTicks += max(-Self.slewStepTicks, min(Self.slewStepTicks, diff))
            }
        }
        return computedTicks % Self.wrap
    }

    private static func resyncLine(_ diff: Int64, _ reason: String?) -> String {
        let ms = Double(abs(diff)) / 90
        let dir = diff >= 0 ? "ahead" : "behind"
        let why = reason.map { " (\($0))" } ?? ""
        return String(format: "[TS-REMUX] audio-only clock resync: source %@ by %.1f ms%@", dir, ms, why)
    }

    /// Account one frame of `count` samples at `frameRate` Hz.
    private mutating func countFrame(samples count: Int, rate frameRate: Int) {
        guard frameRate > 0, count > 0 else { return }
        if frameRate != rate {
            if rate > 0, hasBase {
                // Fold what was counted at the old rate into the base.
                baseTicks = computedTicks
                samples = 0
            }
            rate = frameRate
        }
        samplesPerFrameSeen = count
        samples += Int64(count)
    }

    // MARK: Frame parsing

    private mutating func feed(_ bytes: ArraySlice<UInt8>) {
        var buf = carry
        buf.append(contentsOf: bytes)
        carry.removeAll(keepingCapacity: true)
        var i = skip
        skip = 0
        while i < buf.count {
            let need = headerLength
            if i + need > buf.count {
                carry = Array(buf[i...])
                return
            }
            if let frame = parseFrame(buf, i) {
                if frame.samples > 0 { countFrame(samples: frame.samples, rate: frame.rate) }
                i += frame.length
            } else {
                i += 1
            }
        }
        skip = i - buf.count
    }

    private var headerLength: Int {
        switch streamType {
        case 0x0F: return 7
        case 0x81, 0x87: return 6
        default: return 4
        }
    }

    /// Length in bytes, samples (0 for a dependent substream) and rate of
    /// the frame whose header starts at `i`, or nil when no sync is there.
    private func parseFrame(_ b: [UInt8], _ i: Int) -> (length: Int, samples: Int, rate: Int)? {
        switch streamType {
        case 0x0F: return Self.parseADTS(b, i)
        case 0x81, 0x87: return Self.parseAC3(b, i)
        default: return Self.parseMPEG(b, i)
        }
    }

    static func parseADTS(_ b: [UInt8], _ i: Int) -> (length: Int, samples: Int, rate: Int)? {
        guard b[i] == 0xFF, (b[i + 1] & 0xF6) == 0xF0 else { return nil }
        let rates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
        let fi = Int(b[i + 2] >> 2) & 0x0F
        guard fi < rates.count else { return nil }
        let len = (Int(b[i + 3] & 0x03) << 11) | (Int(b[i + 4]) << 3) | (Int(b[i + 5]) >> 5)
        guard len > 7 else { return nil }
        let blocks = Int(b[i + 6] & 0x03) + 1
        return (len, 1024 * blocks, rates[fi])
    }

    static func parseAC3(_ b: [UInt8], _ i: Int) -> (length: Int, samples: Int, rate: Int)? {
        guard b[i] == 0x0B, b[i + 1] == 0x77 else { return nil }
        let bsid = Int(b[i + 5] >> 3)
        if bsid <= 10 {
            let fscod = Int(b[i + 4] >> 6)
            let code = Int(b[i + 4] & 0x3F)
            guard fscod < 3, code < 38 else { return nil }
            let kbps = [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 448, 512, 576, 640][code / 2]
            let words: Int
            switch fscod {
            case 0: words = kbps * 2
            case 1: words = kbps * 320 / 147 + (code & 1)
            default: words = kbps * 3
            }
            return (words * 2, 1536, [48000, 44100, 32000][fscod])
        }
        guard bsid <= 16 else { return nil }
        let strmtyp = Int(b[i + 2] >> 6)
        let words = ((Int(b[i + 2] & 0x07) << 8) | Int(b[i + 3])) + 1
        let fscod = Int(b[i + 4] >> 6)
        let rate: Int
        let blocks: Int
        if fscod == 3 {
            let fscod2 = Int(b[i + 4] >> 4) & 0x03
            guard fscod2 < 3 else { return nil }
            rate = [24000, 22050, 16000][fscod2]
            blocks = 6
        } else {
            rate = [48000, 44100, 32000][fscod]
            blocks = [1, 2, 3, 6][Int(b[i + 4] >> 4) & 0x03]
        }
        // Dependent substreams extend the independent frame's audio.
        return (words * 2, strmtyp == 1 ? 0 : 256 * blocks, rate)
    }

    static func parseMPEG(_ b: [UInt8], _ i: Int) -> (length: Int, samples: Int, rate: Int)? {
        guard b[i] == 0xFF, (b[i + 1] & 0xE0) == 0xE0 else { return nil }
        let version = Int(b[i + 1] >> 3) & 0x03      // 3 MPEG-1, 2 MPEG-2, 0 MPEG-2.5
        let layer = Int(b[i + 1] >> 1) & 0x03        // 3 L1, 2 L2, 1 L3
        let bri = Int(b[i + 2] >> 4)
        let sri = Int(b[i + 2] >> 2) & 0x03
        guard version != 1, layer != 0, bri > 0, bri < 15, sri < 3 else { return nil }
        let pad = Int(b[i + 2] >> 1) & 0x01
        let v1 = version == 3
        let tables: [[Int]] = [
            [32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448],   // V1 L1
            [32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384],      // V1 L2
            [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320],       // V1 L3
            [32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256],      // V2 L1
            [8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160],           // V2 L2/L3
        ]
        let table = v1 ? (layer == 3 ? 0 : layer == 2 ? 1 : 2) : (layer == 3 ? 3 : 4)
        let bitrate = tables[table][bri - 1] * 1000
        let rate = [44100, 48000, 32000][sri] / (v1 ? 1 : version == 2 ? 2 : 4)
        switch layer {
        case 3: return ((12 * bitrate / rate + pad) * 4, 384, rate)
        case 2: return (144 * bitrate / rate + pad, 1152, rate)
        default:
            return v1 ? (144 * bitrate / rate + pad, 1152, rate)
                      : (72 * bitrate / rate + pad, 576, rate)
        }
    }

    // MARK: TS / PES helpers

    static func payloadStart(_ p: [UInt8]) -> Int? {
        switch (p[3] >> 4) & 0x03 {
        case 0x01: return 4
        case 0x03:
            let start = 5 + Int(p[4])
            return start < 188 ? start : nil
        default: return nil
        }
    }

    static func readTS(_ p: [UInt8], _ o: Int) -> Int64 {
        (Int64(p[o] >> 1) & 0x07) << 30 | Int64(p[o + 1]) << 22
            | (Int64(p[o + 2] >> 1) & 0x7F) << 15 | Int64(p[o + 3]) << 7 | Int64(p[o + 4] >> 1)
    }

    /// Writes a 33-bit timestamp, keeping the 4-bit prefix and setting
    /// the three marker bits.
    static func writeTS(_ p: inout [UInt8], _ o: Int, _ v: Int64) {
        p[o] = (p[o] & 0xF0) | UInt8((v >> 29) & 0x0E) | 0x01
        p[o + 1] = UInt8((v >> 22) & 0xFF)
        p[o + 2] = UInt8((v >> 14) & 0xFE) | 0x01
        p[o + 3] = UInt8((v >> 7) & 0xFF)
        p[o + 4] = UInt8((v << 1) & 0xFE) | 0x01
    }

    /// a - b on the 33-bit circle, in (-2^32, 2^32].
    static func signedDelta(_ a: Int64, _ b: Int64) -> Int64 {
        var d = (a - b) % wrap
        if d > wrap / 2 { d -= wrap }
        if d <= -wrap / 2 { d += wrap }
        return d
    }
}
