// CLI test harness for the cast HLS proxy's pure logic. The repo has no
// unit-test target (AerioTVUITests is UI-only), so these run via swiftc
// on macOS against the shipping source files.

import Foundation

var failures = 0
@MainActor func expect(_ cond: Bool, _ label: String) {
    if cond {
        print("PASS \(label)")
    } else {
        failures += 1
        print("FAIL \(label)")
    }
}
@MainActor func expectEq<T: Equatable>(_ a: T, _ b: T, _ label: String) {
    if a == b {
        print("PASS \(label)")
    } else {
        failures += 1
        print("FAIL \(label): \(a) != \(b)")
    }
}

// MARK: 1. AAC PTS ladder / re-anchor

do {
    var mapper = CastAudioTranscoder.AACPTSMapper(sampleRate: 44_100)
    let frame: Int64 = 1024 * 90_000 // divided by 44100 per step, exact each time
    // Anchor at a non-zero pts; ladder computed from anchor each frame.
    let anchor: Int64 = 1_234_567
    var raws: [Int64] = []
    for n in 0..<1000 { raws.append(anchor + Int64(n) * frame / 44_100) }
    var lastOut: Int64 = -1
    var okLadder = true
    for (n, raw) in raws.enumerated() {
        let out = mapper.map(raw)
        let expected = anchor + Int64(n) * frame / 44_100
        if out != expected { okLadder = false }
        if out <= lastOut { okLadder = false }
        lastOut = out
    }
    expect(okLadder, "pts ladder exact at 44.1kHz over 1000 frames (no cumulative drift)")
    // The 1000th frame: 1000*1024/44100 s = 23.219954... s = 2089795.9 ticks.
    // Ladder value stays anchored (no per-frame rounding accumulation).
    expectEq(mapper.map(anchor + 1000 * frame / 44_100), anchor + 1000 * frame / 44_100,
             "ladder frame 1000 computed from anchor")
    // Re-anchor: a jump of 600ms (54000 ticks) past the ladder re-anchors.
    let jumped = anchor + 1001 * frame / 44_100 + 54_000
    expectEq(mapper.map(jumped), jumped, "re-anchor on >500ms jump")
    // And the next frame steps from the new anchor.
    expectEq(mapper.map(jumped + frame / 44_100), jumped + frame / 44_100, "post-re-anchor step")
    // A small deviation (< 500ms) does NOT re-anchor: output stays on ladder.
    var m2 = CastAudioTranscoder.AACPTSMapper(sampleRate: 48_000)
    _ = m2.map(0)
    let step48: Int64 = 1024 * 90_000 / 48_000 // 1920
    expectEq(m2.map(step48 + 40_000), step48, "jitter under threshold stays on ladder")
}

// MARK: 2. downmix coefficients

do {
    // One 5.1 frame: FL FR C LFE SL SR.
    let pcm: [Int16] = [1000, 2000, 1000, 32000, 1000, 2000]
    let out = CastAudioTranscoder.downmixToStereo(pcm, channels: 6)
    // L = 1000 + 707 + 707 = 2414; R = 2000 + 707 + 1414 = 4121. LFE dropped.
    expectEq(out, [2414, 4121], "5.1 downmix coefficients (LFE dropped)")
    expectEq(CastAudioTranscoder.downmixToStereo([123, -456], channels: 2), [123, -456],
             "stereo passthrough untouched")
    expectEq(CastAudioTranscoder.downmixToStereo([777], channels: 1), [777, 777],
             "mono duplicates")
    // Clamp: FL near max plus center must clamp, not wrap.
    let loud: [Int16] = [32000, -32000, 32000, 0, 0, 0]
    let clamped = CastAudioTranscoder.downmixToStereo(loud, channels: 6)
    expectEq(clamped[0], 32767, "positive clamp")
    expectEq(clamped[1], Int16(-32000 + 22624), "negative side mixes normally")
}

// MARK: 3. master playlist codec string from synthetic avcC

do {
    var initSeg = Data([0, 0, 0, 0, 0x66, 0x74, 0x79, 0x70]) // noise + ftyp-ish
    initSeg.append(Data("avcC".utf8))
    initSeg.append(Data([1, 0x64, 0x00, 0x28, 0xFF, 0xE1])) // ver, profile, compat, level
    expectEq(CastHLSSegmentStore.avcCodecString(from: initSeg), "avc1.640028",
             "avc1.PPCCLL derived from avcC")
    expectEq(CastHLSSegmentStore.avcCodecString(from: Data([1, 2, 3])), nil,
             "no avcC yields nil")
}

// MARK: 4. playlist generation across a splice

do {
    let store = CastHLSSegmentStore()
    let ticks3s: Int64 = 3 * 90_000
    let gen1 = store.beginGeneration()
    store.setInitSegment(generation: gen1, data: Data("init1-avcC".utf8))
    for _ in 0..<3 { store.addSegment(generation: gen1, data: Data("seg".utf8), durationTicks: ticks3s) }
    expectEq(store.currentReadyState.segments, 3, "segment count in generation 1")
    // The ready gate is a duration, so the store must total media time too.
    expectEq(store.currentReadyState.mediaTicks, 3 * ticks3s,
             "media ticks in generation 1")

    let gen2 = store.beginGeneration()
    expectEq(store.currentReadyState.segments, 0, "generation bump resets ready count")
    expectEq(store.currentReadyState.mediaTicks, 0, "generation bump resets ready media time")
    // A stale gen-1 publisher must not claim a sequence number.
    store.addSegment(generation: gen1, data: Data("stale".utf8), durationTicks: ticks3s)
    store.setInitSegment(generation: gen2, data: Data("init2".utf8))
    for _ in 0..<2 { store.addSegment(generation: gen2, data: Data("seg2".utf8), durationTicks: ticks3s) }

    let text = store.mediaPlaylistText()
    let lines = text.split(separator: "\n").map(String.init)
    expect(lines.contains("#EXT-X-VERSION:7"), "version 7")
    expect(lines.contains("#EXT-X-MEDIA-SEQUENCE:0"), "media sequence starts at 0 (5-window covers all 5)")
    expect(lines.contains("#EXT-X-DISCONTINUITY"), "discontinuity tag present at splice")
    expect(lines.contains("#EXT-X-MAP:URI=\"init\(gen1).mp4\""), "old generation MAP present")
    expect(lines.contains("#EXT-X-MAP:URI=\"init\(gen2).mp4\""), "new generation MAP present")
    expect(!text.contains("ENDLIST"), "no ENDLIST on a live playlist")
    // Contiguous sequence numbering across the splice: seg0..seg4.
    for n in 0...4 { expect(lines.contains("seg\(n).m4s"), "seg\(n) advertised") }
    expect(!text.contains("seg5.m4s"), "stale-generation segment claimed no sequence number")
    // The discontinuity tag must sit immediately before the new
    // generation's MAP and its first segment, with nothing in between
    // (see section 12: no PROGRAM-DATE-TIME, ever).
    if let di = lines.firstIndex(of: "#EXT-X-DISCONTINUITY") {
        expectEq(lines[di + 1], "#EXT-X-MAP:URI=\"init\(gen2).mp4\"", "discontinuity precedes new MAP")
    } else {
        expect(false, "discontinuity index")
    }
    expect(lines.contains("#EXTINF:3.000,"), "EXTINF has 3 decimals")

    // Old-generation init + segments stay fetchable until ring eviction.
    expectEq(store.initSegment(generation: gen1), Data("init1-avcC".utf8), "old init retained")
    expectEq(store.awaitSegment(seq: 0, timeout: 0.05), Data("seg".utf8), "old segment fetchable after splice")

    // Master playlist reflects the CURRENT generation's init (no avcC in
    // init2, so fallback codec string) and carries the load-bearing tags.
    let master = store.masterPlaylistText()
    expect(master.contains("CLOSED-CAPTIONS=NONE"), "master carries CLOSED-CAPTIONS=NONE")
    expect(master.contains("BANDWIDTH="), "master carries BANDWIDTH")
    expect(master.contains("mp4a.40.2"), "master carries AAC codec")
    expect(master.contains("live.m3u8"), "master points at media playlist")
}

// MARK: 5. ring eviction with init retention

do {
    let store = CastHLSSegmentStore()
    let ticks: Int64 = 3 * 90_000
    let gen1 = store.beginGeneration()
    store.setInitSegment(generation: gen1, data: Data("i1".utf8))
    for _ in 0..<3 { store.addSegment(generation: gen1, data: Data([1]), durationTicks: ticks) }
    let gen2 = store.beginGeneration()
    store.setInitSegment(generation: gen2, data: Data("i2".utf8))
    // Ring size 8: after 6 gen2 segments (total 9) one gen1 segment evicts.
    for _ in 0..<6 { store.addSegment(generation: gen2, data: Data([2]), durationTicks: ticks) }
    expect(store.initSegment(generation: gen1) != nil, "gen1 init retained while a gen1 segment is ringed")
    // Push the remaining gen1 segments out (11 total > 8 + 3).
    for _ in 0..<2 { store.addSegment(generation: gen2, data: Data([2]), durationTicks: ticks) }
    expectEq(store.initSegment(generation: gen1), nil, "gen1 init dropped once no ring entry references it")
    expect(store.initSegment(generation: gen2) != nil, "current generation init always retained")
    // The flagged (discontinuity) segment was seg3; it evicts at 12 total.
    var text = store.mediaPlaylistText()
    expect(!text.contains("#EXT-X-DISCONTINUITY-SEQUENCE"), "discontinuity-sequence absent while tag in ring")
    for _ in 0..<4 { store.addSegment(generation: gen2, data: Data([2]), durationTicks: ticks) }
    text = store.mediaPlaylistText()
    expect(text.contains("#EXT-X-DISCONTINUITY-SEQUENCE:1"), "discontinuity-sequence increments after tag rolls out")
    expect(!text.contains("#EXT-X-DISCONTINUITY\n#EXT-X-MAP:URI=\"init\(gen2)"),
           "no stale discontinuity tag once flagged segment evicted")

    // Live-edge hold semantics: newest+1 blocks briefly then nils on
    // timeout; far future and evicted return nil immediately.
    let t0 = Date()
    expectEq(store.awaitSegment(seq: 15, timeout: 0.3), nil, "newest+1 held until timeout")
    expect(Date().timeIntervalSince(t0) >= 0.25, "newest+1 actually waited")
    let t1 = Date()
    expectEq(store.awaitSegment(seq: 40, timeout: 5), nil, "far future 404s fast")
    expectEq(store.awaitSegment(seq: 0, timeout: 5), nil, "evicted 404s fast")
    expect(Date().timeIntervalSince(t1) < 0.2, "no hold for far-future/evicted")
    // Publication wakes a held fetch.
    let publisher = Thread {
        Thread.sleep(forTimeInterval: 0.15)
        store.addSegment(generation: gen2, data: Data([9]), durationTicks: ticks)
    }
    publisher.start()
    expectEq(store.awaitSegment(seq: 15, timeout: 3), Data([9]), "held fetch resolves on publish")
}

// MARK: 6. remuxer PTS unwrap helpers

do {
    var clock = CastFMP4Remuxer.PTSUnwrapper()
    let nearWrap: Int64 = (1 << 33) - 900
    expectEq(clock.unwrap(nearWrap), nearWrap, "pre-wrap passthrough")
    expectEq(clock.unwrap(100), (1 << 33) + 100, "33-bit wraparound unwraps monotonic")
    let dts64: Int64 = (1 << 33) + 50
    expectEq(CastFMP4Remuxer.unwrapPTSAgainstDTS(150, dts64), (1 << 33) + 150,
             "pts unwraps against dts epoch")
    expectEq(CastFMP4Remuxer.unwrapPTSAgainstDTS((1 << 33) - 100, dts64), (1 << 33) - 100,
             "pts slightly behind wrap point stays in epoch")
}

// MARK: 7. AC-3 passthrough sample-entry config + playlist CODECS

do {
    // Synthesized AC-3 syncframe header: 48 kHz (fscod 0), 384 kbps
    // (frmsizecod 28 -> bit_rate_code 14), bsid 8, bsmod 0, acmod 7 (3/2)
    // with LFE -> 5.1, 1536 bytes per frame.
    var frame: [UInt8] = [0x0B, 0x77, 0x00, 0x00, 0x1C, 0x40, 0xE1]
    frame.append(contentsOf: [UInt8](repeating: 0, count: 1536 - frame.count))
    guard let config = CastAudioTranscoder.parseAC3SampleEntryConfig(.ac3, frame, 0) else {
        expect(false, "AC-3 sample entry config parsed")
        exit(1)
    }
    expectEq(config.fscod, 0, "dac3 fscod")
    expectEq(config.bsid, 8, "dac3 bsid")
    expectEq(config.bsmod, 0, "dac3 bsmod")
    expectEq(config.acmod, 7, "dac3 acmod")
    expectEq(config.lfeon, 1, "dac3 lfeon")
    expectEq(config.bitRateCode, 14, "dac3 bit_rate_code")
    expectEq(config.sampleRate, 48_000, "AC-3 sample rate")
    expectEq(config.channels, 6, "AC-3 channel count (5.1)")
    expectEq(config.samplesPerFrame, 1536, "AC-3 samples per frame")
    expectEq(config.codecsAttribute, "ac-3", "AC-3 CODECS attribute")

    let store = CastHLSSegmentStore()
    let gen = store.beginGeneration()
    store.setInitSegment(generation: gen, data: Data("init".utf8))
    expect(store.masterPlaylistText().contains(",mp4a.40.2\""), "master defaults to the AAC codec")
    store.setAudioCodecsAttribute("ac-3")
    let master = store.masterPlaylistText()
    expect(master.contains(",ac-3\""), "master names ac-3 for a passthrough")
    expect(!master.contains("mp4a"), "master drops the AAC codec for a passthrough")
    store.setAudioCodecsAttribute(nil)
    let videoOnly = store.masterPlaylistText()
    expect(!videoOnly.contains("mp4a") && !videoOnly.contains("ac-3"),
           "video-only master names no audio codec")
}

// MARK: 9. segment-run continuity against a real transport stream
//
// Added 2026-09-12 after Logan's "launches now but it's frozen" on a
// Google TV Streamer. The failure was reproduced in a real Chromium
// MediaSource: the Cast receiver appends our muxed segments in MSE
// 'sequence' AppendMode (Shaka's HLS default; Chromium logs the
// multitrack warning on every one of our loads). In that mode Chromium
// ignores tfdt and re-anchors each append on the PRESENTATION timestamp
// of the first coded frame, so two properties of the emitted bytes
// decide whether the receiver plays or freezes:
//
//  1. No audio may sit before the first video presentation time. Audio
//     that does lands before zero and Chromium drops and truncates it
//     ("Dropping audio frame (DTS -24000us ...)", "Truncating audio
//     buffer which overlaps append window start"), and the truncated
//     frame then fails to decode and costs the load a decoder swap.
//  2. Both tracks must run continuously across consecutive segments, so
//     no hole can open between appends. In Chromium a run of eight of
//     these segments buffers as ONE range in both 'segments' and
//     'sequence' mode; with a segment missing, sequence mode turns the
//     honest 6 s hole into a 0.147 s one the video renderer never
//     crosses while the audio plays straight through it.
//
// Skips itself when ffmpeg is absent so a machine without Homebrew
// still runs the rest of the suite.

/// One segment's per-track span, in 90 kHz ticks, read back out of the
/// moof: tfdt, tfdt + the trun sample durations, and the minimum
/// presentation time.
struct TrackSpan {
    var start: Int64 = 0
    var end: Int64 = 0
    var minPTS: Int64 = 0
}

func be32(_ b: [UInt8], _ o: Int) -> Int64 {
    (Int64(b[o]) << 24) | (Int64(b[o + 1]) << 16) | (Int64(b[o + 2]) << 8) | Int64(b[o + 3])
}

func boxType(_ b: [UInt8], _ o: Int) -> String {
    String(bytes: b[(o + 4)..<(o + 8)], encoding: .ascii) ?? ""
}

/// Children of a box body, as (type, bodyStart, boxEnd).
func boxChildren(_ b: [UInt8], _ start: Int, _ end: Int) -> [(String, Int, Int)] {
    var out: [(String, Int, Int)] = []
    var o = start
    while o + 8 <= end {
        var size = Int(be32(b, o))
        if size == 0 { size = end - o }
        if size < 8 || o + size > end { break }
        out.append((boxType(b, o), o + 8, o + size))
        o += size
    }
    return out
}

/// Per-track spans of one media segment, keyed by track id.
func segmentSpans(_ segment: Data) -> [Int: TrackSpan] {
    let b = [UInt8](segment)
    var result: [Int: TrackSpan] = [:]
    for (type, start, end) in boxChildren(b, 0, b.count) where type == "moof" {
        for (trafType, trafStart, trafEnd) in boxChildren(b, start, end) where trafType == "traf" {
            var trackID = -1
            var span = TrackSpan()
            var total: Int64 = 0
            var minPTS = Int64.max
            for (childType, childStart, _) in boxChildren(b, trafStart, trafEnd) {
                switch childType {
                case "tfhd":
                    trackID = Int(be32(b, childStart + 4))
                case "tfdt":
                    span.start = b[childStart] == 1
                        ? (be32(b, childStart + 4) << 32) | be32(b, childStart + 8)
                        : be32(b, childStart + 4)
                case "trun":
                    let version = Int(b[childStart])
                    let flags = Int(be32(b, childStart) & 0xFF_FFFF)
                    let count = Int(be32(b, childStart + 4))
                    var p = childStart + 8
                    if flags & 0x1 != 0 { p += 4 }   // data offset
                    if flags & 0x4 != 0 { p += 4 }   // first sample flags
                    var decode: Int64 = 0
                    for _ in 0..<count {
                        var duration: Int64 = 0
                        if flags & 0x100 != 0 { duration = be32(b, p); p += 4 }
                        if flags & 0x200 != 0 { p += 4 } // size
                        if flags & 0x400 != 0 { p += 4 } // flags
                        if flags & 0x800 != 0 {
                            let raw = be32(b, p)
                            // version 1 composition offsets are signed.
                            let cto = version == 1 ? Int64(Int32(truncatingIfNeeded: raw)) : raw
                            minPTS = min(minPTS, decode + cto)
                            p += 4
                        } else {
                            minPTS = min(minPTS, decode)
                        }
                        decode += duration
                        total += duration
                    }
                default:
                    break
                }
            }
            if trackID > 0 {
                span.end = span.start + total
                span.minPTS = span.start + (minPTS == Int64.max ? 0 : minPTS)
                result[trackID] = span
            }
        }
    }
    return result
}

/// The shared real-transport-stream fixture: H.264 with B-frames plus
/// AAC-LC in MPEG-TS, built once per machine and cached in the temp dir.
/// nil when ffmpeg is not installed.
func continuityFixtureTS() -> Data? {
    let ffmpeg = "/opt/homebrew/bin/ffmpeg"
    guard FileManager.default.isExecutableFile(atPath: ffmpeg) else { return nil }
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("cast-hls-continuity", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let ts = dir.appendingPathComponent("bframes.ts")
    if !FileManager.default.fileExists(atPath: ts.path) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = [
            "-y", "-v", "error",
            "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=30:duration=40",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=40",
            // B-frames on purpose: the composition offset of the first
            // sample is what the receiver anchors a sequence-mode append
            // on, and it is what used to push our audio below zero.
            "-c:v", "libx264", "-preset", "veryfast", "-bf", "3", "-g", "90", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-b:a", "192k", "-ac", "2", "-ar", "48000",
            "-f", "mpegts", ts.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
    guard let bytes = try? Data(contentsOf: ts), !bytes.isEmpty else { return nil }
    return bytes
}

@MainActor func runSegmentContinuityChecks() {
    guard let bytes = continuityFixtureTS() else {
        print("SKIP segment-run continuity (no ffmpeg fixture)")
        return
    }

    var segments: [Data] = []
    let remuxer = CastFMP4Remuxer()
    remuxer.onMediaSegment = { data, _ in segments.append(data) }
    var offset = 0
    while offset < bytes.count {
        let n = min(64 * 1024, bytes.count - offset)
        try? remuxer.feed(bytes.subdata(in: offset..<(offset + n)))
        offset += n
    }
    expect(segments.count >= 6, "a real transport stream yields at least 6 segments (\(segments.count))")
    guard segments.count >= 6 else { return }

    // One AAC frame at 48 kHz: the largest quantization error the audio
    // partition can carry at a segment boundary.
    let frameTicks = 1024 * CastFMP4Remuxer.ticksPerSecond / 48_000
    var previousVideoEnd: Int64 = -1
    var previousAudioEnd: Int64 = -1
    var audioNeverPrecedesVideo = true
    var videoContiguous = true
    var audioContiguous = true
    var audioKeepsUp = true
    for (index, segment) in segments.enumerated() {
        let spans = segmentSpans(segment)
        guard let video = spans[1], let audio = spans[2] else {
            expect(false, "segment \(index) carries both trafs")
            return
        }
        if index == 0 {
            // Property 1: a sequence-mode append anchors on video.minPTS,
            // so any audio below it is dropped or truncated by Chromium.
            if audio.start < video.minPTS { audioNeverPrecedesVideo = false }
        } else {
            // Property 2: no holes between appends, in either track.
            if video.start != previousVideoEnd { videoContiguous = false }
            if audio.start != previousAudioEnd { audioContiguous = false }
        }
        // The audio partition trails the video cut by at most a few
        // frames; more than that and the seam starts accumulating.
        if video.end - audio.end >= frameTicks * 9 { audioKeepsUp = false }
        previousVideoEnd = video.end
        previousAudioEnd = audio.end
    }
    expect(audioNeverPrecedesVideo, "no audio before the first video presentation time")
    expect(videoContiguous, "video runs contiguously across every segment boundary")
    expect(audioContiguous, "audio runs contiguously across every segment boundary")
    expect(audioKeepsUp, "audio never trails the video cut by more than the frame quantum")
}

runSegmentContinuityChecks()

// MARK: 9b. the channel-change splice leaves ONE contiguous range
//
// Measured on the Google TV Streamer (session22.txt, 17:23:50 and
// 17:25:14): at every channel change the receiver reported a 122-123 ms
// hole in its buffered range ("buffered=[38.072-43.937][44.060-51.358]"),
// then flapped between seeking and BUFFERING and gap-jumped. The old
// generation's audio stopped 103 ms before the EXTINF total its playlist
// declared, because provider audio trails its video in the mux and the
// audio for the outgoing segment's last ~120 ms was still queued for a
// segment the channel change threw away. Shaka parses our
// EXT-X-DISCONTINUITY with sequenceMode false and places the next
// generation at the accumulated EXTINF position, so that shortfall is a
// hole in the track INTERSECTION Chromium reports.

/// A transport stream whose AUDIO timestamps trail its video by
/// `audioLagSeconds` at the same position in the mux, which is what every
/// measured provider feed looks like (session22.txt, gen 7: a segment
/// starting at video dts 40.040 carried audio from 39.927). Built by
/// offsetting the VIDEO input, so no timestamp is negative. 60 fps with
/// one B-frame of reorder matches the measured feed's 16 to 34 ms
/// presentation-over-decode offset, which with the 21.33 ms audio frame
/// quantum is the irreducible part of the seam.
func audioLagFixtureTS() -> Data? {
    let ffmpeg = "/opt/homebrew/bin/ffmpeg"
    guard FileManager.default.isExecutableFile(atPath: ffmpeg) else { return nil }
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("cast-hls-continuity", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let ts = dir.appendingPathComponent("audiolag60.ts")
    if !FileManager.default.fileExists(atPath: ts.path) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = [
            "-y", "-v", "error",
            "-itsoffset", "0.12",
            "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=60:duration=30",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=30",
            "-c:v", "libx264", "-preset", "veryfast", "-bf", "1", "-g", "120", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-b:a", "192k", "-ac", "2", "-ar", "48000",
            "-f", "mpegts", ts.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
    guard let bytes = try? Data(contentsOf: ts), !bytes.isEmpty else { return nil }
    return bytes
}

/// One ingest connection: feed `limit` bytes in wire-sized chunks, then
/// the per-connection teardown the session always runs.
@MainActor func ingestOneConnection(_ bytes: Data, limit: Int) -> (segments: [Data], durations: [Int64]) {
    var segments: [Data] = []
    var durations: [Int64] = []
    let remuxer = CastFMP4Remuxer()
    remuxer.onMediaSegment = { data, ticks in
        segments.append(data)
        durations.append(ticks)
    }
    var offset = 0
    while offset < limit {
        let n = min(64 * 1024, limit - offset)
        try? remuxer.feed(bytes.subdata(in: offset..<(offset + n)))
        offset += n
    }
    remuxer.release()
    return (segments, durations)
}

@MainActor func runSpliceContinuityChecks() {
    guard let bytes = audioLagFixtureTS() else {
        print("SKIP channel-change splice continuity (no ffmpeg fixture)")
        return
    }
    let frameTicks = 1024 * CastFMP4Remuxer.ticksPerSecond / 48_000

    // The channel change lands mid-segment: the ingest stops partway
    // through the stream, the session begins a new generation, and a fresh
    // remuxer serves it (one remuxer per ingest connection).
    let genA = ingestOneConnection(bytes, limit: Int(Double(bytes.count) * 0.6))
    let genB = ingestOneConnection(bytes, limit: Int(Double(bytes.count) * 0.4))
    expect(genA.segments.count >= 3, "generation A produced segments (\(genA.segments.count))")
    expect(genB.segments.count >= 2, "generation B produced segments (\(genB.segments.count))")
    guard genA.segments.count >= 3, genB.segments.count >= 2 else { return }

    let playlistEndA = genA.durations.reduce(0, +)
    let lastA = segmentSpans(genA.segments[genA.segments.count - 1])
    let firstB = segmentSpans(genB.segments[0])
    guard let videoA = lastA[1], let audioA = lastA[2],
          let videoB = firstB[1], let audioB = firstB[2] else {
        expect(false, "both generations carry both trafs at the seam")
        return
    }
    // The old range ends at min(video end, audio end) and the new one
    // starts at max(video start, audio start), because Chromium reports a
    // two-track SourceBuffer as the INTERSECTION of its tracks.
    let oldEnd = min(videoA.end, audioA.end)
    let newStart = playlistEndA + max(videoB.minPTS, audioB.start)
    let holeMs = Double(newStart - oldEnd) * 1000.0 / Double(CastFMP4Remuxer.ticksPerSecond)
    print(String(format: "SPLICE HOLE %.1f ms (playlist end %ld, video end %ld, audio end %ld)",
                 holeMs, playlistEndA, videoA.end, audioA.end))
    // The generation's tail must end both tracks together, or the playlist
    // promises media one of them does not have.
    expect(abs(videoA.end - audioA.end) <= frameTicks,
           "the generation tail ends video and audio within one audio frame "
           + "(video \(videoA.end), audio \(audioA.end))")
    // ONE contiguous range across the splice: 40 ms is inside what a
    // single video reorder delay and a single audio frame allow, and far
    // below the 122 ms hole the receiver flapped on.
    expect(Double(newStart - oldEnd) < Double(CastFMP4Remuxer.ticksPerSecond) * 0.04,
           String(format: "the splice hole is %.1f ms, under the 40 ms quantum", holeMs))
}

runSpliceContinuityChecks()

// MARK: 10. near-future segment fetches are held, not 404ed
//
// A 404 makes Shaka drop the segment and re-sync to the live edge, which
// skips segments; see the continuity notes above for why a skipped
// segment freezes the picture.

do {
    let store = CastHLSSegmentStore()
    let ticks: Int64 = 3 * 90_000
    let gen = store.beginGeneration()
    store.setInitSegment(generation: gen, data: Data("i".utf8))
    for _ in 0..<3 { store.addSegment(generation: gen, data: Data([1]), durationTicks: ticks) }
    // nextSeq is 3; 3, 4 and 5 are inside the hold window, 6 is not.
    let held = Date()
    expectEq(store.awaitSegment(seq: 5, timeout: 0.3), nil, "two past the edge is held until timeout")
    expect(Date().timeIntervalSince(held) >= 0.25, "two past the edge actually waited")
    let fast = Date()
    expectEq(store.awaitSegment(seq: 6, timeout: 5), nil, "three past the edge 404s fast")
    expect(Date().timeIntervalSince(fast) < 0.2, "no hold beyond the future window")
}


// MARK: 11. the audio traf declares its samples as sync samples
//
// Chromium's parser reads sample flags from the trun, then the tfhd
// default, then the trex default. Our audio trun carries no per-sample
// flags, so the tfhd default is what decides whether the receiver treats
// an AAC frame as a random access point. Without it Chromium logs, once
// per frame, "indicated the frame is not a random access point (key
// frame)" and the first packet after the load's seek fails to decode
// (Google TV Streamer, 2026-09-12 14:22:20.237 and .246).

/// default_sample_flags of one traf's tfhd, or nil when the box does not
/// carry the field at all.
func audioTfhdDefaultSampleFlags(_ segment: Data, trackID: Int64) -> Int64? {
    let b = [UInt8](segment)
    for (type, mStart, mEnd) in boxChildren(b, 0, b.count) where type == "moof" {
        for (t2, tStart, tEnd) in boxChildren(b, mStart, mEnd) where t2 == "traf" {
            for (t3, pStart, pEnd) in boxChildren(b, tStart, tEnd) where t3 == "tfhd" {
                guard pEnd - pStart >= 8 else { continue }
                let boxFlags = (Int64(b[pStart + 1]) << 16) | (Int64(b[pStart + 2]) << 8) | Int64(b[pStart + 3])
                guard be32(b, pStart + 4) == trackID else { continue }
                // Optional fields in ISO order; we never set the earlier
                // ones, but skip them properly so the reader stays honest.
                var o = pStart + 8
                if boxFlags & 0x01 != 0 { o += 8 }
                if boxFlags & 0x02 != 0 { o += 4 }
                if boxFlags & 0x08 != 0 { o += 4 }
                if boxFlags & 0x10 != 0 { o += 4 }
                guard boxFlags & 0x20 != 0, o + 4 <= pEnd else { return nil }
                return be32(b, o)
            }
        }
    }
    return nil
}

do {
    // Two AAC frames is enough: the flags live in the tfhd, not per sample.
    let remuxer = CastFMP4Remuxer()
    var segment = Data()
    remuxer.onMediaSegment = { data, _ in if segment.isEmpty { segment = data } }
    if let fixture = continuityFixtureTS() {
        var offset = 0
        while offset < fixture.count, segment.isEmpty {
            let n = min(64 * 1024, fixture.count - offset)
            try? remuxer.feed(fixture.subdata(in: offset..<(offset + n)))
            offset += n
        }
    }
    if segment.isEmpty {
        print("SKIP audio sync-sample flags (no fixture segment)")
    } else if let flags = audioTfhdDefaultSampleFlags(segment, trackID: 2) {
        // bit 16 is sample_is_non_sync_sample; it must be clear.
        expect(flags & 0x0001_0000 == 0, "audio samples are declared sync samples")
        // bits 25-24 are sample_depends_on; 2 is "does not depend on others".
        expectEq(Int((flags >> 24) & 0x03), 2, "audio samples depend on no others")
    } else {
        expect(false, "the audio tfhd sets default-sample-flags")
    }
}

// MARK: 8. AudioSpecificConfig sanitizing for the web receiver's parser

do {
    // Chromium re-parses the ASC we put in the esds while parsing moov
    // (media/formats/mp4/aac.cc). Three values there fail the whole init
    // append with "Append: stream parsing failed", so the builder must
    // never emit them, whatever the ADTS header said.

    // Plain AAC-LC 48 kHz stereo rides through untouched.
    let stereo = CastFMP4Remuxer.sanitizedAACConfig(objectType: 2, freqIndex: 3, channelConfig: 2)
    expectEq(stereo.asc, [0x11, 0x90], "AAC-LC 48k stereo ASC unchanged")
    expectEq(stereo.sampleRate, 48_000, "48k sample rate")
    expectEq(stereo.channels, 2, "stereo channel count")

    // channelConfiguration 0 means "layout is in a program config
    // element", which ffmpeg's AAC encoder emits for layouts outside
    // Table 1.19 (2.1, 3.1, 6.1, 7.0). Chromium's SkipGASpecificConfig
    // does RCHECK(channel_config_ != 0), so 0 must never reach the ASC.
    let pce = CastFMP4Remuxer.sanitizedAACConfig(objectType: 2, freqIndex: 3, channelConfig: 0)
    expectEq(pce.channelConfig, 2, "PCE-signalled layout (config 0) declared stereo")
    expectEq(pce.channels, 2, "mp4a channelcount matches the ASC, not max(1, 0)")
    expectEq(pce.asc, [0x11, 0x90], "config 0 never reaches the ASC")

    // Reserved (13, 14) and escape (15) frequency indexes fail
    // Chromium's frequency table lookup; 15's 24-bit explicit rate does
    // not fit a 2-byte ASC at all. All fall back to index 3 / 48 kHz,
    // which is what the frame-duration math already assumed.
    for bad in [13, 14, 15, 99] {
        let c = CastFMP4Remuxer.sanitizedAACConfig(objectType: 2, freqIndex: bad, channelConfig: 2)
        expectEq(c.freqIndex, 3, "frequency index \(bad) falls back to 48 kHz index")
        expectEq(c.sampleRate, 48_000, "frequency index \(bad) sample rate")
    }

    // audioObjectType must land in 1...4; 5 (HE-AAC) and 29 (HE-AACv2)
    // need extension fields a 2-byte ASC cannot carry.
    for bad in [0, 5, 29, 31] {
        let c = CastFMP4Remuxer.sanitizedAACConfig(objectType: bad, freqIndex: 3, channelConfig: 2)
        expectEq(c.objectType, 2, "object type \(bad) falls back to AAC-LC")
    }
    expectEq(CastFMP4Remuxer.sanitizedAACConfig(objectType: 1, freqIndex: 3, channelConfig: 2).objectType, 1,
             "AAC Main (1) is in range and survives")

    // channelConfiguration 7 is 7.1, so eight channels, not seven.
    expectEq(CastFMP4Remuxer.sanitizedAACConfig(objectType: 2, freqIndex: 3, channelConfig: 7).channels, 8,
             "config 7 is 7.1 (8 channels)")
    // 44.1 kHz mono, to prove the index/rate pairing is not hardcoded.
    let mono441 = CastFMP4Remuxer.sanitizedAACConfig(objectType: 2, freqIndex: 4, channelConfig: 1)
    expectEq(mono441.sampleRate, 44_100, "index 4 is 44.1 kHz")
    expectEq(mono441.channels, 1, "mono channel count")

    // Exhaustive: over every value the 2-bit ADTS profile, 4-bit
    // frequency index and 3-bit channel configuration fields can carry,
    // the emitted ASC must decode back to values Chromium accepts.
    var allSafe = true
    for aot in 0...31 {
        for fi in 0...15 {
            for ch in 0...7 {
                let c = CastFMP4Remuxer.sanitizedAACConfig(objectType: aot, freqIndex: fi, channelConfig: ch)
                guard c.asc.count == 2 else { allSafe = false; continue }
                let decodedAOT = Int(c.asc[0]) >> 3
                let decodedFreq = ((Int(c.asc[0]) & 0x07) << 1) | (Int(c.asc[1]) >> 7)
                let decodedChan = (Int(c.asc[1]) >> 3) & 0x0F
                // The 3 low bits are GASpecificConfig: frameLengthFlag,
                // dependsOnCoreCoder, extensionFlag, all zero.
                let gaBits = Int(c.asc[1]) & 0x07
                if !(1...4).contains(decodedAOT) { allSafe = false }
                if decodedFreq > 12 { allSafe = false }
                if decodedChan < 1 || decodedChan > 7 { allSafe = false }
                if gaBits != 0 { allSafe = false }
                if decodedAOT != c.objectType || decodedFreq != c.freqIndex
                    || decodedChan != c.channelConfig { allSafe = false }
            }
        }
    }
    expect(allSafe, "every ADTS header value yields a Chromium-parseable 2-byte ASC")
}

// MARK: 12. NO EXT-X-PROGRAM-DATE-TIME, and a window Shaka can seek in
//
// PROGRAM-DATE-TIME was added on 2026-09-12 (a6a443f) and removed the
// same day. The anchor it was derived from was the wall clock at the
// moment a segment was STORED, one whole segment later than the media
// that segment begins with, so every stamp ran a segment ahead of its
// own media. Shaka makes a PDT the authority for segment POSITIONS
// (hls_parser.js createSegments_ -> SegmentReference.syncAgainst, and
// setInitialProgramDateTime in determineDuration_), so its live window
// slid past the media in the buffer: the receiver reported
// seek=[51.368-52.373] against buffered=[46.537-51.593] with the
// playhead at 51.357, outside its own seek range, BUFFERING forever.
//
// These tests pin the shape the receiver needs instead: no absolute
// clock at all, and a window whose MEDIA SPAN exceeds the receiver's
// presentation delay, because Shaka's live seek range is
//   [availEnd - segmentAvailabilityDuration, availEnd - presentationDelay]
// (presentation_timeline.js getSafeSeekRangeStart / getSeekRangeEnd) with
// segmentAvailabilityDuration taken from the window span
// (hls_parser.js determineDuration_ -> getLiveDuration_). A window
// narrower than the delay leaves no seek range at all.

/// Every EXT-X-PROGRAM-DATE-TIME value in a playlist, in order.
@MainActor func programDateTimes(_ playlist: String) -> [String] {
    playlist.split(separator: "\n").compactMap { line in
        line.hasPrefix("#EXT-X-PROGRAM-DATE-TIME:")
            ? String(line.dropFirst("#EXT-X-PROGRAM-DATE-TIME:".count))
            : nil
    }
}

/// Total EXTINF seconds advertised by a playlist: the window media span
/// Shaka turns into its availability duration.
@MainActor func windowSpanSeconds(_ playlist: String) -> Double {
    playlist.split(separator: "\n").compactMap { line -> Double? in
        guard line.hasPrefix("#EXTINF:") else { return nil }
        let value = line.dropFirst("#EXTINF:".count).split(separator: ",").first ?? ""
        return Double(value)
    }.reduce(0, +)
}

/// What the receiver page configures as Shaka's presentation delay
/// (LIVE_START_BEHIND_SECONDS in receiver.html).
let receiverPresentationDelay = 4.0

do {
    let store = CastHLSSegmentStore()
    let ticks3s: Int64 = 3 * 90_000
    let gen = store.beginGeneration()
    store.setInitSegment(generation: gen, data: Data("init".utf8))
    for _ in 0..<4 { store.addSegment(generation: gen, data: Data([1]), durationTicks: ticks3s) }

    let first = store.mediaPlaylistText()
    expectEq(programDateTimes(first).count, 0, "no EXT-X-PROGRAM-DATE-TIME on a live playlist")
    // The load gate is four segments (CastHLSProxySession.readyMinSegments),
    // so this is the narrowest window the receiver can ever see.
    expectEq(windowSpanSeconds(first), 12.0, "four 3 s segments span 12 s of media")
    expect(windowSpanSeconds(first) - receiverPresentationDelay >= 3.0,
           "first window leaves a seek range at least one target duration wide")

    // Slide the window: windowSize is 5, so six more segments roll the
    // first four out, and the span stays the full five segments.
    for _ in 0..<6 { store.addSegment(generation: gen, data: Data([1]), durationTicks: ticks3s) }
    let slid = store.mediaPlaylistText()
    expect(slid.contains("#EXT-X-MEDIA-SEQUENCE:5"), "window head advanced with the ring")
    expectEq(programDateTimes(slid).count, 0, "still no PROGRAM-DATE-TIME after the window slid")
    expectEq(windowSpanSeconds(slid), 15.0, "a full window spans five segments")
}

// A playlist built across a discontinuity carries no absolute clock
// either: the discontinuity plus the new EXT-X-MAP is the whole
// timeline-and-codec change contract.
do {
    let store = CastHLSSegmentStore()
    let ticks3s: Int64 = 3 * 90_000
    let gen1 = store.beginGeneration()
    store.setInitSegment(generation: gen1, data: Data("i1".utf8))
    for _ in 0..<2 { store.addSegment(generation: gen1, data: Data([1]), durationTicks: ticks3s) }
    let gen2 = store.beginGeneration()
    store.setInitSegment(generation: gen2, data: Data("i2".utf8))
    for _ in 0..<2 { store.addSegment(generation: gen2, data: Data([2]), durationTicks: ticks3s) }

    let text = store.mediaPlaylistText()
    let lines = text.split(separator: "\n").map(String.init)
    expectEq(programDateTimes(text).count, 0, "no PROGRAM-DATE-TIME across a splice")
    if let discIndex = lines.firstIndex(of: "#EXT-X-DISCONTINUITY") {
        expect(discIndex + 1 < lines.count
               && lines[discIndex + 1].hasPrefix("#EXT-X-MAP:"),
               "EXT-X-MAP immediately follows EXT-X-DISCONTINUITY")
    } else {
        expect(false, "EXT-X-MAP immediately follows EXT-X-DISCONTINUITY")
    }
}

// onSegmentComposition against the real transport stream: the numbers the
// proxy log prints must be non-negative (a negative presentation time is
// exactly the audio-below-zero failure section 9 covers) and the playlist
// timeline (segmentStartSeconds) must accumulate to the emitted durations.
@MainActor func runSegmentCompositionChecks() {
    guard let bytes = continuityFixtureTS() else {
        print("SKIP onSegmentComposition timeline (no ffmpeg fixture)")
        return
    }
    struct Composition {
        let video: Int, audio: Int
        let vdts: Double, vpts: Double, apts: Double, start: Double
    }
    var compositions: [Composition] = []
    var durations: [Int64] = []
    let remuxer = CastFMP4Remuxer()
    remuxer.onSegmentComposition = { v, a, vdts, vpts, apts, start in
        compositions.append(Composition(video: v, audio: a, vdts: vdts, vpts: vpts,
                                        apts: apts, start: start))
    }
    remuxer.onMediaSegment = { _, ticks in durations.append(ticks) }
    var offset = 0
    while offset < bytes.count {
        let n = min(64 * 1024, bytes.count - offset)
        try? remuxer.feed(bytes.subdata(in: offset..<(offset + n)))
        offset += n
    }
    expect(compositions.count >= 6,
           "onSegmentComposition fires for every segment (\(compositions.count))")
    expectEq(compositions.count, durations.count,
             "one composition callback per emitted segment")
    guard compositions.count >= 6, compositions.count == durations.count else { return }

    expect(compositions.allSatisfy { $0.vpts >= 0 },
           "firstVideoPTSSeconds is non-negative for every segment")
    expect(compositions.allSatisfy { $0.apts >= 0 },
           "firstAudioPTSSeconds is non-negative for every segment (fixture has audio throughout)")
    expect(compositions.allSatisfy { $0.vdts >= 0 && $0.video > 0 && $0.audio > 0 },
           "every segment reports samples on both tracks at a non-negative DTS")
    // The first segment of a generation starts the playlist timeline at 0.
    expect(abs(compositions[0].start) < 1e-9, "the first segment starts the playlist timeline at 0")
    // segmentStartSeconds accumulates to the sum of the emitted durations,
    // within one 90 kHz tick.
    let tick = 1.0 / Double(CastFMP4Remuxer.ticksPerSecond)
    var running: Int64 = 0
    var accumulates = true
    for (index, c) in compositions.enumerated() {
        if abs(c.start - Double(running) / Double(CastFMP4Remuxer.ticksPerSecond)) > tick {
            accumulates = false
        }
        running += durations[index]
    }
    expect(accumulates, "segmentStartSeconds accumulates to the sum of the emitted durations")
    let total = Double(running) / Double(CastFMP4Remuxer.ticksPerSecond)
    let lastEnd = compositions[compositions.count - 1].start
        + Double(durations[durations.count - 1]) / Double(CastFMP4Remuxer.ticksPerSecond)
    expect(abs(total - lastEnd) <= tick,
           "the last segment ends at the total emitted duration")
}

// MARK: 13. AAC program_config_element stripping
//
// Added 2026-09-12 after a Google TV Streamer cast of a Dispatcharr
// "Web Player (AAC Audio)" channel played video with silence: the
// server's ffmpeg (`-c:a aac -ac 2`) emits ADTS frames with
// channel_configuration 0 and a program_config_element at the start of
// every raw_data_block ("Using a PCE to encode channel layout"), and
// C2SoftAacDec rejected all of them (5388 lines of "error 0x0005,
// substituting silence"). Transcoding is not allowed and neither are
// server changes, so the frames are fixed losslessly: parse the PCE,
// take the real channel count from it, and drop its bytes off the front
// of the block.

/// A program_config_element built bit by bit: `front` front elements,
/// every one a channel_pair_element, optionally one LFE, and a comment of
/// `comment` bytes.
/// Build a PCE from explicit element lists. `front`/`side`/`back` are
/// (is_cpe, tag) pairs, `lfeTags` are LFE instance tags. The default is
/// the Dispatcharr stereo shape: one front CPE, nothing else.
func buildPCEElements(
    freqIndex: Int = 3,
    front: [(Int, Int)] = [(1, 0)],
    side: [(Int, Int)] = [],
    back: [(Int, Int)] = [],
    lfeTags: [Int] = [],
    comment: Int = 0
) -> [UInt8] {
    var bits: [Int] = []
    func put(_ value: Int, _ width: Int) {
        for i in stride(from: width - 1, through: 0, by: -1) { bits.append((value >> i) & 1) }
    }
    put(5, 3) // id_syn_ele = PCE
    put(0, 4) // element_instance_tag
    put(1, 2) // object_type (AAC-LC)
    put(freqIndex, 4)
    put(front.count, 4); put(side.count, 4); put(back.count, 4)
    put(lfeTags.count, 2); put(0, 3); put(0, 4) // num_lfe/assoc_data/valid_cc
    put(0, 1); put(0, 1); put(0, 1) // no mono/stereo/matrix mixdown
    for (isCPE, tag) in front + side + back { put(isCPE, 1); put(tag, 4) }
    for tag in lfeTags { put(tag, 4) } // lfe_element_tag
    while bits.count % 8 != 0 { bits.append(0) } // byte_align()
    put(comment, 8) // comment_field_bytes
    for _ in 0..<comment { put(0x41, 8) }
    var out: [UInt8] = []
    for i in stride(from: 0, to: bits.count, by: 8) {
        var b = 0
        for j in 0..<8 { b = (b << 1) | bits[i + j] }
        out.append(UInt8(b))
    }
    return out
}

func buildPCE(freqIndex: Int = 3, front: Int = 1, lfe: Int = 0, comment: Int = 0) -> [UInt8] {
    var bits: [Int] = []
    func put(_ value: Int, _ width: Int) {
        for i in stride(from: width - 1, through: 0, by: -1) { bits.append((value >> i) & 1) }
    }
    put(5, 3) // id_syn_ele = PCE
    put(0, 4) // element_instance_tag
    put(1, 2) // object_type (AAC-LC)
    put(freqIndex, 4)
    put(front, 4); put(0, 4); put(0, 4) // num_front/side/back
    put(lfe, 2); put(0, 3); put(0, 4) // num_lfe/assoc_data/valid_cc
    put(0, 1); put(0, 1); put(0, 1) // no mono/stereo/matrix mixdown
    for _ in 0..<front { put(1, 1); put(0, 4) } // is_cpe = 1, tag 0
    for _ in 0..<lfe { put(0, 4) } // lfe_element_tag
    while bits.count % 8 != 0 { bits.append(0) } // byte_align()
    put(comment, 8) // comment_field_bytes
    for _ in 0..<comment { put(0x41, 8) }
    var out: [UInt8] = []
    for i in stride(from: 0, to: bits.count, by: 8) {
        var b = 0
        for j in 0..<8 { b = (b << 1) | bits[i + j] }
        out.append(UInt8(b))
    }
    return out
}

do {
    // The Dispatcharr shape: one front CPE, nothing else, empty comment.
    let pce = buildPCE()
    let block = pce + [0x21, 0x00, 0x00, 0x00]
    if let info = CastFMP4Remuxer.parseAACPCE(block, offset: 0, end: block.count) {
        expectEq(info.channels, 2, "a stereo PCE reports two channels")
        expectEq(info.lengthBytes, pce.count, "PCE length measured in whole bytes")
        expect(info.firstIsCPE, "the first front element is a channel pair")
    } else {
        expect(false, "a stereo PCE parses")
    }

    // The property the lossless strip rests on: the element always ends on
    // a byte boundary relative to the block start, whatever its element
    // counts and comment length, because byte_align() precedes
    // comment_field_bytes (ISO/IEC 14496-3 4.4.1.1). Only then can the
    // rest of the block be copied byte-wise instead of shifted bit by bit.
    var alwaysAligned = true
    for comment in 0...3 {
        for front in 1...3 {
            for lfe in 0...1 {
                let bytes = buildPCE(front: front, lfe: lfe, comment: comment)
                let blk = bytes + [0x21, 0x00, 0x00, 0x00]
                guard let info = CastFMP4Remuxer.parseAACPCE(blk, offset: 0, end: blk.count),
                      info.lengthBytes == bytes.count,
                      info.channels == front * 2 + lfe else {
                    alwaysAligned = false
                    continue
                }
            }
        }
    }
    expect(alwaysAligned, "every PCE shape ends byte-aligned with the channel count the layout implies")

    // id_syn_ele 0 (SCE), 1 (CPE) and 7 (TERM) are not PCEs: those frames
    // must pass through untouched.
    var nonPCEIgnored = true
    for synEle in [0, 1, 2, 3, 4, 6, 7] {
        let blk: [UInt8] = [UInt8(synEle << 5), 0x11, 0x22, 0x33]
        if CastFMP4Remuxer.parseAACPCE(blk, offset: 0, end: blk.count) != nil { nonPCEIgnored = false }
    }
    expect(nonPCEIgnored, "a block that does not start with a PCE is reported as absent")

    // A truncated element is refused rather than guessed at: a wrong
    // length would shift the whole payload and silence the frame.
    var truncationRefused = true
    for cut in 1..<pce.count {
        if CastFMP4Remuxer.parseAACPCE(pce, offset: 0, end: cut) != nil { truncationRefused = false }
    }
    expect(truncationRefused, "a truncated PCE is refused rather than guessed")

    // Channel count back to a Table 1.19 configuration. 7 channels has no
    // entry (config 7 is 7.1), so it falls to 0 and the sanitizer makes it
    // stereo.
    // Table 1.19 is an element ORDER plus tags, not a channel count. The
    // layout ffmpeg emits for "5.1(side)" (measured: front CPE(0) +
    // SCE(0), side SCE(1), back CPE(1), no LFE element) adds up to six
    // channels and still matches no configuration, so it must report 0
    // and be refused rather than stripped and declared as config 6, which
    // ffmpeg's aac and aac_fixed decoders reject on 189 of 189 frames and
    // the Google TV Streamer's C2SoftAacDec on 4360 of 4360.
    let ffmpeg51Side = buildPCEElements(
        front: [(1, 0), (0, 0)], side: [(0, 1)], back: [(1, 1)])
    let side51Block = ffmpeg51Side + [0x21, 0x00, 0x00, 0x00]
    let side51 = CastFMP4Remuxer.parseAACPCE(side51Block, offset: 0, end: side51Block.count)
    expectEq(side51?.channels ?? -1, 6, "ffmpeg's 5.1(side) PCE declares six channels")
    expectEq(side51?.impliedChannelConfig ?? -1, 0,
        "ffmpeg's 5.1(side) element order matches no channel_configuration")
    let real51 = buildPCEElements(
        front: [(0, 0), (1, 0)], back: [(1, 1)], lfeTags: [0])
    let real51Block = real51 + [0x21, 0x00, 0x00, 0x00]
    let real51Info = CastFMP4Remuxer.parseAACPCE(real51Block, offset: 0, end: real51Block.count)
    expectEq(real51Info?.impliedChannelConfig ?? -1, 6,
        "a PCE that restates Table 1.19's 5.1 order is config 6 and strips safely")
    let stereoPCE = CastFMP4Remuxer.parseAACPCE(
        buildPCEElements() + [0x21, 0x00, 0x00, 0x00], offset: 0,
        end: buildPCEElements().count + 4)
    expectEq(stereoPCE?.impliedChannelConfig ?? -1, 2,
        "the Dispatcharr stereo PCE is config 2")

    expectEq(CastFMP4Remuxer.aacChannelConfig(forCount: 2), 2, "2 channels is config 2")
    expectEq(CastFMP4Remuxer.aacChannelConfig(forCount: 6), 6, "6 channels is config 6 (5.1)")
    expectEq(CastFMP4Remuxer.aacChannelConfig(forCount: 8), 7, "8 channels is config 7 (7.1)")
    expectEq(CastFMP4Remuxer.aacChannelConfig(forCount: 7), 0, "7 channels has no configuration")
    expectEq(CastFMP4Remuxer.sanitizedAACConfig(
        objectType: 2, freqIndex: 3,
        channelConfig: CastFMP4Remuxer.aacChannelConfig(forCount: 7)).channelConfig, 2,
        "an unmappable count still yields a legal stereo ASC")
}

/// Rewrite every ADTS frame of `adts` to channel_configuration 0 with a
/// stereo PCE spliced in ahead of the raw_data_block, growing
/// aac_frame_length to match: byte for byte the shape Dispatcharr emits.
///
/// Synthesized rather than asked of ffmpeg because ffmpeg's AAC encoder
/// refuses every two-channel layout outside plain stereo, so it cannot be
/// made to produce this case locally. Synthesizing also buys the stronger
/// assertion: the frames under the PCE are the untouched fixture's
/// frames, so a correct strip has to reproduce them exactly.
func injectPCE(_ adts: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []
    var p = 0
    while p + 7 <= adts.count {
        let protectionAbsent = adts[p + 1] & 0x01 != 0
        let headerLen = protectionAbsent ? 7 : 9
        let freqIndex = (Int(adts[p + 2]) >> 2) & 0x0F
        let frameLen = ((Int(adts[p + 3]) & 0x03) << 11) | (Int(adts[p + 4]) << 3)
            | ((Int(adts[p + 5]) >> 5) & 0x07)
        if frameLen < headerLen || p + frameLen > adts.count { break }
        let pce = buildPCE(freqIndex: freqIndex)
        let newLen = frameLen + pce.count
        var header = Array(adts[p..<(p + headerLen)])
        // channel_configuration is the low bit of byte 2 plus the top two
        // bits of byte 3; zero all three, then restate the frame length.
        header[2] &= 0xFE
        header[3] &= 0x3F
        header[3] = (header[3] & 0xFC) | UInt8((newLen >> 11) & 0x03)
        header[4] = UInt8((newLen >> 3) & 0xFF)
        header[5] = (header[5] & 0x1F) | UInt8((newLen & 0x07) << 5)
        out += header
        out += pce
        out += Array(adts[(p + headerLen)..<(p + frameLen)])
        p += frameLen
    }
    return out
}

/// The continuity fixture with its audio rewritten to carry a PCE, plus
/// the untouched original, both as transport streams. nil without ffmpeg.
func pceFixtureTS() -> (plain: Data, pce: Data)? {
    let ffmpeg = "/opt/homebrew/bin/ffmpeg"
    guard FileManager.default.isExecutableFile(atPath: ffmpeg) else { return nil }
    guard let plain = continuityFixtureTS() else { return nil }
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("cast-hls-continuity", isDirectory: true)
    let pceTS = dir.appendingPathComponent("pce.ts")
    if !FileManager.default.fileExists(atPath: pceTS.path) {
        let source = dir.appendingPathComponent("bframes.ts")
        let adts = dir.appendingPathComponent("plain.aac")
        let injected = dir.appendingPathComponent("pce.aac")
        func ffmpegRun(_ args: [String]) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpeg)
            process.arguments = args
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
        ffmpegRun(["-y", "-v", "error", "-i", source.path, "-map", "0:a", "-c", "copy",
                   "-f", "adts", adts.path])
        guard let raw = try? Data(contentsOf: adts) else { return nil }
        try? Data(injectPCE([UInt8](raw))).write(to: injected)
        ffmpegRun(["-y", "-v", "error", "-i", source.path, "-i", injected.path,
                   "-map", "0:v", "-map", "1:a", "-c", "copy", "-f", "mpegts", pceTS.path])
    }
    guard let pce = try? Data(contentsOf: pceTS), !pce.isEmpty else { return nil }
    return (plain, pce)
}

/// Every audio sample of every segment, cut out of the mdat with the
/// second traf's trun sizes and data_offset.
@MainActor func audioSampleHex(_ segments: [Data]) -> [String] {
    var out: [String] = []
    for segment in segments {
        let b = [UInt8](segment)
        var moofStart = -1
        var o = 0
        while o + 8 <= b.count {
            let size = Int(be32(b, o))
            if size < 8 { break }
            if boxType(b, o) == "moof" { moofStart = o; break }
            o += size
        }
        guard moofStart >= 0 else { continue }
        let moofEnd = moofStart + Int(be32(b, moofStart))
        let trafs = boxChildren(b, moofStart + 8, moofEnd).filter { $0.0 == "traf" }
        guard trafs.count >= 2 else { continue }
        let traf = trafs[1]
        for child in boxChildren(b, traf.1, traf.2) where child.0 == "trun" {
            let count = Int(be32(b, child.1 + 4))
            // data_offset is relative to the moof start.
            var cursor = moofStart + Int(be32(b, child.1 + 8))
            var q = child.1 + 12
            for _ in 0..<count {
                let len = Int(be32(b, q + 4))
                guard cursor + len <= b.count else { break }
                out.append(b[cursor..<(cursor + len)].map { String(format: "%02x", $0) }.joined())
                cursor += len
                q += 8
            }
        }
    }
    return out
}

@MainActor func runPCEStripChecks() {
    guard let fixtures = pceFixtureTS() else {
        print("SKIP AAC PCE strip against a real transport stream (no ffmpeg fixture)")
        return
    }
    func remux(_ bytes: Data) -> (init_: Data?, segments: [Data], logs: [String]) {
        var segments: [Data] = []
        var logs: [String] = []
        var initSegment: Data?
        let remuxer = CastFMP4Remuxer(log: { logs.append($0) })
        remuxer.onInitSegment = { initSegment = $0 }
        remuxer.onMediaSegment = { data, _ in segments.append(data) }
        var offset = 0
        while offset < bytes.count {
            let n = min(64 * 1024, bytes.count - offset)
            try? remuxer.feed(bytes.subdata(in: offset..<(offset + n)))
            offset += n
        }
        return (initSegment, segments, logs)
    }
    let plain = remux(fixtures.plain)
    let pce = remux(fixtures.pce)

    expect(pce.segments.count >= 6, "the PCE stream still segments (\(pce.segments.count))")
    expect(pce.init_ != nil, "the PCE stream emits an init segment")
    // Same declared track as the untouched stereo stream: the PCE said one
    // front channel pair, so the ASC says config 2 and nothing about the
    // init segment changes.
    if let a = plain.init_, let b = pce.init_ {
        expectEq([UInt8](b), [UInt8](a), "the PCE stream's init segment matches the stereo stream's")
    }
    // Announced once for the session, not once per frame.
    let stripLogs = pce.logs.filter { $0.hasPrefix("AAC PCE stripped:") }
    expectEq(stripLogs.count, 1, "the PCE strip is logged exactly once")
    expectEq(stripLogs.first ?? "", "AAC PCE stripped: layout 2 ch matches config 2",
             "the log line names the derived layout and config")
    expect(plain.logs.filter { $0.hasPrefix("AAC PCE stripped:") }.isEmpty,
           "a stream without a PCE logs no strip")

    // Losslessness on the bytes: aligned by CONTENT, because every source
    // frame grew by the PCE, which repacks the PES and shifts both the
    // first frame that clears the video presentation gate and where the
    // last partial segment ends. From the first shared frame onward the
    // two sample streams must be the same frames in the same order.
    let plainSamples = audioSampleHex(plain.segments)
    let pceSamples = audioSampleHex(pce.segments)
    expect(plainSamples.count >= 200, "audio samples extracted (\(plainSamples.count))")
    guard let first = plainSamples.first, let offset = pceSamples.firstIndex(of: first) else {
        expect(false, "the stereo run's first frame appears in the PCE run")
        return
    }
    expect(true, "the stereo run's first frame appears in the PCE run")
    let common = min(plainSamples.count, pceSamples.count - offset)
    expect(common >= 200, "a long shared run to compare (\(common))")
    var identical = true
    for i in 0..<max(0, common) where plainSamples[i] != pceSamples[i + offset] { identical = false }
    expect(identical, "every audio frame is byte-identical after the PCE strip")

    // The decoder's verdict, not ours: init + segments written out as one
    // fMP4 and fully decoded. ffmpeg prints nothing on a clean decode, so
    // any AAC error (the "substituting silence" class of failure the
    // Streamer hit) shows up here as output.
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("cast-hls-continuity", isDirectory: true)
    for (name, run) in [("pce-strip.mp4", pce), ("stereo.mp4", plain)] {
        var file = Data()
        file.append(run.init_ ?? Data())
        for segment in run.segments.prefix(4) { file.append(segment) }
        let url = dir.appendingPathComponent(name)
        try? file.write(to: url)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        process.arguments = ["-v", "error", "-i", url.path, "-f", "null", "-"]
        let pipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = pipe
        try? process.run()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        expect(text.isEmpty, "\(name) decodes with no ffmpeg errors: \(text)")
    }

    // The AudioSpecificConfig the esds carries: AAC-LC, 48 kHz, config 2.
    // 0x05 is the DecoderSpecificInfo tag, then its 2-byte length-and-ASC.
    if let initSegment = pce.init_ {
        let b = [UInt8](initSegment)
        var found = false
        for i in 0..<max(0, b.count - 3) where b[i] == 0x05 && b[i + 1] == 0x02 {
            if b[i + 2] == 0x11 && b[i + 3] == 0x90 { found = true }
        }
        expect(found, "the esds ASC says AAC-LC 48 kHz channel configuration 2")
    }
}

runPCEStripChecks()


// MARK: 14. audio frame census: nothing lost, nothing re-stamped
//
// Added 2026-09-13 after a live cast to the Google TV Streamer was
// measured on the device: the media clock ratio read 1.0000 and Chromium
// decoded 60 fps with zero drops, yet SurfaceFlinger presented about 47
// fps and Chromium logged audio DEMUXER_UNDERFLOW. The proxy's
// per-segment census was the tell: ESPNU 4.00 s segments carried 179 to
// 189 AAC frames where 187.5 belong.
//
// Two defects produced that, and both are measured here:
//
//  1. The carried partial frame was re-stamped. A PES PTS describes the
//     first access unit that COMMENCES in its payload, so a frame carried
//     in from the previous PES must keep the running clock's time; riding
//     the new PES PTS put it, and every follower, one frame late. On the
//     real capture the mux makes this worse: every audio PES is stamped
//     exactly 9600 ticks (five frames) after the one before it while
//     about one PES in six carries six frames, so every such PES
//     re-stamped a frame that had already been emitted.
//  2. Audio that arrived after the cut keyframe was lost to the splicer.
//     Provider audio trails its video, so a segment's last ~170 ms of
//     audio was unparsed when the cut keyframe arrived, and those frames
//     opened the NEXT segment below its own start. The cut now waits.
//
// The primary fixture is a real ESPNU capture of the Dispatcharr AAC
// output profile; it is too large to check in, so the path is overridable
// with CAST_TS_FIXTURE and the check skips when the capture is absent.
// The synthetic fixture always runs: it packs audio PES at byte offsets
// that ignore frame boundaries, which ffmpeg's own TS muxer never does.

/// ADTS frames in a raw elementary stream, counted header by header.
func countADTSFrames(_ b: [UInt8]) -> Int {
    var p = 0
    var n = 0
    while p + 7 <= b.count {
        if b[p] != 0xFF || (b[p + 1] & 0xF0) != 0xF0 { p += 1; continue }
        let len = (Int(b[p + 3] & 0x03) << 11) | (Int(b[p + 4]) << 3) | (Int(b[p + 5]) >> 5)
        if len <= 7 || p + len > b.count { p += 1; continue }
        n += 1
        p += len
    }
    return n
}

struct CensusResult {
    var segments: [Data] = []
    var durations: [Int64] = []
    var audioCounts: [Int] = []
    var logs: [String] = []
}

@MainActor func censusRemux(_ bytes: Data) -> CensusResult {
    var result = CensusResult()
    let remuxer = CastFMP4Remuxer(log: { result.logs.append($0) })
    remuxer.onMediaSegment = { data, ticks in
        result.segments.append(data)
        result.durations.append(ticks)
    }
    remuxer.onSegmentComposition = { _, audio, _, _, _, _ in result.audioCounts.append(audio) }
    var offset = 0
    while offset < bytes.count {
        let n = min(64 * 1024, bytes.count - offset)
        try? remuxer.feed(bytes.subdata(in: offset..<(offset + n)))
        offset += n
    }
    remuxer.release() // the generation's tail segment counts too
    return result
}

/// Audio pts continuity across every segment boundary, plus the frames
/// counted. Within a segment the trun's fixed durations make the timeline
/// contiguous by construction, so the boundaries are what can break.
@MainActor func censusChecks(_ label: String, _ result: CensusResult,
                             inputFrames: Int, lossAllowance: Int, minSegments: Int) {
    let frameTicks = 1024 * CastFMP4Remuxer.ticksPerSecond / 48_000
    expect(result.segments.count >= minSegments,
           "\(label): at least \(minSegments) segments (\(result.segments.count))")
    guard result.segments.count >= minSegments else { return }

    var contiguous = true
    var previousEnd: Int64 = -1
    var framesInBoxes = 0
    for segment in result.segments {
        guard let audio = segmentSpans(segment)[2] else { continue }
        if previousEnd >= 0, abs(audio.start - previousEnd) > 1 { contiguous = false }
        previousEnd = audio.end
        framesInBoxes += Int((audio.end - audio.start) / frameTicks)
    }
    let output = result.audioCounts.reduce(0, +)
    print("[census \(label)] input=\(inputFrames) output=\(output) segments=\(result.segments.count) "
        + "per=\(result.audioCounts)")
    expect(contiguous, "\(label): audio runs contiguously across every segment boundary")
    expectEq(framesInBoxes, output, "\(label): every counted frame reached a segment")
    expect(output >= inputFrames - lossAllowance,
           "\(label): no audio frame lost (input \(inputFrames), output \(output), "
         + "allowance \(lossAllowance))")
    expect(output <= inputFrames, "\(label): output cannot exceed input")

    // The emitted media is fully covered by audio: a lost frame shows up
    // here as a shortfall even when the fixture's own ends are ragged.
    let declared = result.durations.reduce(0, +)
    let covered = Int64(output) * frameTicks
    expect(covered >= declared - 2 * frameTicks,
           String(format: "%@: audio covers %.3f s of the %.3f s declared", label,
                  Double(covered) / 90_000.0, Double(declared) / 90_000.0))

    // Per-segment census: every interior segment carries what its own
    // duration calls for, to within the frame a boundary quantizes away.
    var interiorOK = true
    for (i, ticks) in result.durations.enumerated() {
        if i == 0 || i == result.durations.count - 1 { continue }
        let expected = Double(ticks) / Double(frameTicks)
        let actual = Double(result.audioCounts[i])
        if abs(expected - actual) > 1.5 { interiorOK = false }
    }
    expect(interiorOK, "\(label): every interior segment carries the frames its duration calls for")
}

// ---- the real capture ----

@MainActor func runRealCaptureCensus() {
    let ffmpeg = "/opt/homebrew/bin/ffmpeg"
    let path = ProcessInfo.processInfo.environment["CAST_TS_FIXTURE"]
        ?? "/private/tmp/claude-501/-Users-loganjones-Documents-xcode-iOSDev/4567b156-2e97-48d3-a8d7-44b0e9a3fd9a/scratchpad/espnu-aac-60s.ts"
    guard FileManager.default.isExecutableFile(atPath: ffmpeg),
          let bytes = try? Data(contentsOf: URL(fileURLWithPath: path)), !bytes.isEmpty else {
        print("SKIP real-capture audio census (no capture at \(path))")
        return
    }
    // The input frame count comes from the raw ADTS demux of the same
    // stream, which is the provider's count by definition.
    let adts = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("cast-hls-census-espnu.aac")
    if !FileManager.default.fileExists(atPath: adts.path) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-y", "-v", "error", "-i", path,
                             "-map", "0:a:0", "-c", "copy", "-f", "adts", adts.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
    guard let demuxed = try? Data(contentsOf: adts) else {
        print("SKIP real-capture audio census (ffmpeg could not demux the ADTS)")
        return
    }
    let input = countADTSFrames([UInt8](demuxed))
    // Only the audio before the first kept video keyframe may go missing:
    // one GOP of 59.94 fps video is 2.002 s, i.e. 94 AAC frames, plus the
    // handful parsed before the init segment existed.
    censusChecks("espnu", censusRemux(bytes), inputFrames: input, lossAllowance: 100, minSegments: 12)
}

runRealCaptureCensus()

// ---- a synthetic stream whose every audio PES straddles frames ----

struct CensusTSWriter {
    private var out = Data()
    private var continuity: [Int: Int] = [:]

    var bytes: Data { out }

    mutating func psi(pid: Int, table: [UInt8]) {
        var section = [UInt8](repeating: 0xFF, count: 184)
        section[0] = 0 // pointer_field
        for (i, b) in table.enumerated() { section[i + 1] = b }
        packet(pid: pid, body: section, pusi: true, adaptation: false)
    }

    mutating func pes(pid: Int, payload: [UInt8]) {
        var off = 0
        var pusi = true
        while off < payload.count {
            let n = min(184, payload.count - off)
            var body: [UInt8]
            if n == 184 {
                body = Array(payload[off..<(off + n)])
            } else {
                // Stuff the short final packet with an adaptation field,
                // the way a real mux does.
                let stuffing = 184 - n
                body = [UInt8](repeating: 0xFF, count: 184)
                body[0] = UInt8(stuffing - 1)
                if stuffing >= 2 { body[1] = 0 }
                for i in 0..<n { body[stuffing + i] = payload[off + i] }
            }
            packet(pid: pid, body: body, pusi: pusi, adaptation: n != 184)
            pusi = false
            off += n
        }
    }

    private mutating func packet(pid: Int, body: [UInt8], pusi: Bool, adaptation: Bool) {
        let cc = continuity[pid] ?? 0
        continuity[pid] = (cc + 1) & 0x0F
        var p = [UInt8](repeating: 0, count: 188)
        p[0] = 0x47
        p[1] = UInt8((pusi ? 0x40 : 0) | ((pid >> 8) & 0x1F))
        p[2] = UInt8(pid & 0xFF)
        p[3] = UInt8((adaptation ? 0x30 : 0x10) | cc)
        for i in 0..<184 { p[4 + i] = body[i] }
        out.append(contentsOf: p)
    }
}

func censusPTSBytes(_ marker: Int, _ ts: Int64) -> [UInt8] {
    [UInt8((marker << 4) | (Int((ts >> 30) & 0x07) << 1) | 1),
     UInt8((ts >> 22) & 0xFF),
     UInt8((Int((ts >> 15) & 0x7F) << 1) | 1),
     UInt8((ts >> 7) & 0xFF),
     UInt8((Int(ts & 0x7F) << 1) | 1)]
}

func censusPES(streamID: Int, payload: [UInt8], pts: Int64, dts: Int64?) -> [UInt8] {
    let stamps = dts == nil ? censusPTSBytes(2, pts) : censusPTSBytes(3, pts) + censusPTSBytes(1, dts!)
    var body: [UInt8] = [0, 0, 1, UInt8(streamID), 0, 0, 0x80, dts == nil ? 0x80 : 0xC0,
                         UInt8(stamps.count)]
    body.append(contentsOf: stamps)
    body.append(contentsOf: payload)
    let length = body.count - 6
    body[4] = UInt8((length >> 8) & 0xFF)
    body[5] = UInt8(length & 0xFF)
    return body
}

/// One ADTS AAC-LC 48 kHz stereo frame. The payload is constant filler
/// that can never be mistaken for a syncword, so the remuxer's false-sync
/// guard has nothing to trip on and the census counts frames.
func censusADTSFrame(_ frameLen: Int) -> [UInt8] {
    var f = [UInt8](repeating: 0x21, count: frameLen)
    f[0] = 0xFF
    f[1] = 0xF1 // MPEG-4, layer 00, no CRC
    f[2] = UInt8((1 << 6) | (3 << 2)) // AAC-LC, 48 kHz, channel config high bit 0
    f[3] = UInt8((1 << 6) | ((frameLen >> 11) & 0x03)) // channel config 2
    f[4] = UInt8((frameLen >> 3) & 0xFF)
    f[5] = UInt8(((frameLen & 0x07) << 5) | 0x1F)
    f[6] = 0xFC
    return f
}

func censusVideoAU(keyframe: Bool) -> [UInt8] {
    let sps: [UInt8] = [0x67, 0x42, 0xC0, 0x1E, 0xD9, 0x00, 0xF0, 0x11, 0x7E, 0xF0, 0x3C, 0x80]
    let pps: [UInt8] = [0x68, 0xCE, 0x3C, 0x80]
    var slice = [UInt8](repeating: 0x10, count: 400)
    slice[0] = keyframe ? 0x65 : 0x41
    let start: [UInt8] = [0, 0, 0, 1]
    return start + sps + start + pps + start + slice
}

/// A transport stream whose audio PES are cut at byte offsets that have
/// nothing to do with frame boundaries, so the carry runs on nearly every
/// PES. `audioLagTicks` delays the audio in MUX ORDER, which is what puts
/// a segment's last frames behind the keyframe that cuts it.
func straddlingCensusTS(videoFrames: Int, videoFrameTicks: Int64, gop: Int,
                        frameLen: Int, audioLagTicks: Int64) -> (Data, Int) {
    let frameTicks = 1024 * CastFMP4Remuxer.ticksPerSecond / 48_000
    let base: Int64 = 10_000
    var writer = CensusTSWriter()
    let audioFrames = Int((Int64(videoFrames) * videoFrameTicks) / frameTicks) + 4
    var es: [UInt8] = []
    es.reserveCapacity(audioFrames * frameLen)
    for _ in 0..<audioFrames { es.append(contentsOf: censusADTSFrame(frameLen)) }
    let cuts = [frameLen * 2 + 57, frameLen * 3 - 31, frameLen + 7, frameLen * 4 + 13]
    var audioPES: [(start: Int, end: Int, pts: Int64)] = []
    var off = 0
    var cut = 0
    while off < es.count {
        var end = min(off + cuts[cut % cuts.count], es.count)
        cut += 1
        let firstFrame = (off + frameLen - 1) / frameLen
        // A payload in which no frame COMMENCES would be sent without a
        // PTS and the remuxer drops unstamped PES, so grow this one until
        // a frame starts in it.
        while firstFrame * frameLen >= end, end < es.count {
            end = min(end + cuts[cut % cuts.count], es.count)
            cut += 1
        }
        if firstFrame * frameLen >= end { break }
        audioPES.append((off, end, base + Int64(firstFrame) * frameTicks))
        off = end
    }
    // PAT pointing at a PMT on pid 0x1000: H.264 on 0x100, ADTS on 0x101.
    let pat: [UInt8] = [0x00, 0xB0, 13, 0x00, 0x01, 0xC1, 0, 0, 0, 0x01, 0xF0, 0x00, 0, 0, 0, 0]
    let pmtBody: [UInt8] = [0x00, 0x01, 0xC1, 0, 0,
                            0xE1, 0x00, 0xF0, 0x00,
                            0x1B, 0xE1, 0x00, 0xF0, 0x00,
                            0x0F, 0xE1, 0x01, 0xF0, 0x00]
    let pmt: [UInt8] = [0x02, 0xB0, UInt8(pmtBody.count + 4)] + pmtBody + [0, 0, 0, 0]
    writer.psi(pid: 0, table: pat)
    writer.psi(pid: 0x1000, table: pmt)
    var next = 0
    for i in 0..<videoFrames {
        let dts = base + Int64(i) * videoFrameTicks
        writer.pes(pid: 0x100, payload: censusPES(streamID: 0xE0, payload: censusVideoAU(keyframe: i % gop == 0),
                                                  pts: dts, dts: dts))
        while next < audioPES.count, audioPES[next].pts <= dts - audioLagTicks {
            let a = audioPES[next]
            writer.pes(pid: 0x101, payload: censusPES(streamID: 0xC0, payload: Array(es[a.start..<a.end]),
                                                      pts: a.pts, dts: nil))
            next += 1
        }
    }
    while next < audioPES.count {
        let a = audioPES[next]
        writer.pes(pid: 0x101, payload: censusPES(streamID: 0xC0, payload: Array(es[a.start..<a.end]),
                                                  pts: a.pts, dts: nil))
        next += 1
    }
    return (writer.bytes, countADTSFrames(es))
}

@MainActor func runStraddleCensus() {
    // 12 s of 30 fps video, a keyframe every second, 400-byte AAC frames.
    // The loss allowance covers the fixture's ragged ends only: the head
    // frames below the first video presentation time and the tail video
    // that outlives the audio (one GOP, 48 frames).
    let (aligned, alignedFrames) = straddlingCensusTS(videoFrames: 360, videoFrameTicks: 3_000,
                                                      gop: 30, frameLen: 400, audioLagTicks: 0)
    censusChecks("straddle", censusRemux(aligned), inputFrames: alignedFrames,
                 lossAllowance: 52, minSegments: 3)

    // The measured provider shape: audio about 170 ms behind its video in
    // mux order, so every segment's last 8 frames parse after the cut.
    let (trailing, trailingFrames) = straddlingCensusTS(videoFrames: 360, videoFrameTicks: 3_000,
                                                        gop: 30, frameLen: 400, audioLagTicks: 15_300)
    censusChecks("trailing", censusRemux(trailing), inputFrames: trailingFrames,
                 lossAllowance: 52, minSegments: 3)
}

runStraddleCensus()

// MARK: 15. the init segment declares a duration (no Chromium low delay)
//
// Added 2026-09-13: Chromium logged "Video rendering in low delay mode" for
// our stream and SurfaceFlinger presented only about 46 of 60 fps on the
// Google TV Streamer. mp4_stream_parser.cc reads liveness as kLive unless
// mvex/mehd fragment_duration > 0, or mvhd duration is neither 0 nor the
// all-ones sentinel, and kLive pins video_renderer_impl.cc to one buffered
// frame with no underflow growth. The init segment therefore declares 24 h
// in both boxes.

@MainActor func runInitLivenessChecks() {
    let (bytes, _) = straddlingCensusTS(videoFrames: 90, videoFrameTicks: 3_000,
                                        gop: 30, frameLen: 400, audioLagTicks: 0)
    var initSegment: Data?
    var logs: [String] = []
    let remuxer = CastFMP4Remuxer(log: { logs.append($0) })
    remuxer.onInitSegment = { initSegment = $0 }
    remuxer.onMediaSegment = { _, _ in }
    var offset = 0
    while offset < bytes.count {
        let n = min(64 * 1024, bytes.count - offset)
        try? remuxer.feed(bytes.subdata(in: offset..<(offset + n)))
        offset += n
    }
    guard let initSegment else {
        expect(false, "the fixture emits an init segment")
        return
    }
    let b = [UInt8](initSegment)
    func find(_ type: String) -> Int? {
        let t = [UInt8](type.utf8)
        guard b.count >= 4 else { return nil }
        for i in 0...(b.count - 4) where Array(b[i..<(i + 4)]) == t { return i }
        return nil
    }
    func u64(at i: Int) -> UInt64 {
        var v: UInt64 = 0
        for k in 0..<8 { v = (v << 8) | UInt64(b[i + k]) }
        return v
    }
    let expected: UInt64 = 86_400 * UInt64(CastFMP4Remuxer.ticksPerSecond)

    // mehd sits inside mvex, ahead of the trex boxes.
    guard let mehd = find("mehd"), let mvex = find("mvex"), let trex = find("trex") else {
        expect(false, "the init segment carries mvex with mehd before trex")
        return
    }
    expect(mvex < mehd && mehd < trex, "mehd sits inside mvex, before the trex boxes")
    // type(4) version+flags(4), then the 64-bit fragment_duration.
    expect(b[mehd + 4] == 1, "mehd is version 1 (64-bit fragment_duration)")
    expectEq(u64(at: mehd + 8), expected, "mehd fragment_duration is 24 h in the movie timescale")

    // mvhd version 1: type(4) version+flags(4) creation(8) modification(8)
    // timescale(4) duration(8).
    guard let mvhd = find("mvhd") else {
        expect(false, "the init segment carries mvhd")
        return
    }
    expect(b[mvhd + 4] == 1, "mvhd is version 1 (64-bit duration)")
    var timescale: UInt32 = 0
    for k in 0..<4 { timescale = (timescale << 8) | UInt32(b[mvhd + 24 + k]) }
    expectEq(timescale, UInt32(CastFMP4Remuxer.ticksPerSecond), "mvhd timescale unchanged")
    let declared = u64(at: mvhd + 28)
    expectEq(declared, expected, "mvhd duration matches mehd (not the all-ones sentinel)")
    expect(declared != UInt64.max, "mvhd duration is not the unknown-duration sentinel")

    expectEq(logs.filter { $0 == "init: mehd 24h, liveness recorded" }.count, 1,
             "the declared duration is logged once per generation")
}

runInitLivenessChecks()

print(failures == 0 ? "\nALL TESTS PASSED" : "\n\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
