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

// MARK: 2. MPEG audio transcode routing (stream_type 0x03 / 0x04)

/// Stands in for the AudioToolbox transcoder: records what the remuxer
/// framed and hands back one AAC frame per source frame, so the pure
/// framing/PTS logic runs off-device.
final class FakeCastAudioTranscoder: CastAudioTranscoding {
    let onConfig: (_ asc: [UInt8], _ sampleRate: Int) -> Void
    let onFrame: (_ data: [UInt8], _ ptsTicks: Int64) -> Void
    var fedLengths: [Int] = []
    var fedPTS: [Int64] = []
    var flushes = 0
    var released = 0
    private var configSent = false

    init(onConfig: @escaping (_ asc: [UInt8], _ sampleRate: Int) -> Void,
         onFrame: @escaping (_ data: [UInt8], _ ptsTicks: Int64) -> Void) {
        self.onConfig = onConfig
        self.onFrame = onFrame
    }

    func feed(_ data: [UInt8], range: Range<Int>, ptsTicks: Int64, info: CastESFrameInfo) throws {
        if !configSent {
            configSent = true
            // AAC-LC stereo at the source rate: freqIndex 3 is 48 kHz.
            onConfig([0x11, 0x90], info.sampleRate)
        }
        fedLengths.append(range.count)
        fedPTS.append(ptsTicks)
        onFrame([UInt8](repeating: 0x42, count: 64), ptsTicks)
    }

    func flush() { flushes += 1 }
    func release() { released += 1 }
}

/// One MPEG-1 Layer II frame: 48 kHz stereo, 128 kbps, 384 bytes. The
/// payload is filler that cannot be mistaken for a syncword.
func mp2Frame() -> [UInt8] {
    var f = [UInt8](repeating: 0x21, count: 384)
    f[0] = 0xFF
    f[1] = 0xFD // MPEG-1, layer II, no CRC
    f[2] = 0x84 // 128 kbps, 48 kHz, no padding
    f[3] = 0x00 // stereo
    return f
}

/// A transport stream whose PMT declares `audioStreamType` audio on
/// pid 0x101 carrying `audioES`, alongside plain H.264 on pid 0x100.
func mpegAudioFixtureTS(audioStreamType: UInt8, audioES: [UInt8],
                        audioFrameLen: Int, audioFrameTicks: Int64,
                        videoFrames: Int) -> Data {
    var writer = CensusTSWriter()
    let base: Int64 = 10_000
    let pat: [UInt8] = [0x00, 0xB0, 13, 0x00, 0x01, 0xC1, 0, 0, 0, 0x01, 0xF0, 0x00, 0, 0, 0, 0]
    let pmtBody: [UInt8] = [0x00, 0x01, 0xC1, 0, 0,
                            0xE1, 0x00, 0xF0, 0x00,
                            0x1B, 0xE1, 0x00, 0xF0, 0x00,
                            audioStreamType, 0xE1, 0x01, 0xF0, 0x00]
    let pmt: [UInt8] = [0x02, 0xB0, UInt8(pmtBody.count + 4)] + pmtBody + [0, 0, 0, 0]
    writer.psi(pid: 0, table: pat)
    writer.psi(pid: 0x1000, table: pmt)
    let videoFrameTicks: Int64 = 3_000
    var nextAudio = 0
    let audioFrames = audioES.count / audioFrameLen
    for i in 0..<videoFrames {
        let dts = base + Int64(i) * videoFrameTicks
        writer.pes(pid: 0x100, payload: censusPES(streamID: 0xE0,
                                                  payload: censusVideoAU(keyframe: i % 30 == 0),
                                                  pts: dts, dts: dts))
        // One audio PES per two source frames, stamped on the first.
        while nextAudio < audioFrames, base + Int64(nextAudio) * audioFrameTicks <= dts {
            let end = min(nextAudio + 2, audioFrames)
            let bytes = Array(audioES[(nextAudio * audioFrameLen)..<(end * audioFrameLen)])
            writer.pes(pid: 0x101, payload: censusPES(streamID: 0xC0, payload: bytes,
                                                      pts: base + Int64(nextAudio) * audioFrameTicks,
                                                      dts: nil))
            nextAudio = end
        }
    }
    return writer.bytes
}

@MainActor func runMPEGTranscodeChecks() {
    let frameTicks: Int64 = 1152 * CastFMP4Remuxer.ticksPerSecond / 48_000 // 2160
    var es: [UInt8] = []
    for _ in 0..<120 { es.append(contentsOf: mp2Frame()) }

    for streamType: UInt8 in [0x03, 0x04] {
        var fake: FakeCastAudioTranscoder?
        let remuxer = CastFMP4Remuxer(transcoderFactory: { _, onConfig, onFrame in
            let t = FakeCastAudioTranscoder(onConfig: onConfig, onFrame: onFrame)
            fake = t
            return t
        })
        let ts = mpegAudioFixtureTS(audioStreamType: streamType, audioES: es,
                                    audioFrameLen: 384, audioFrameTicks: frameTicks,
                                    videoFrames: 90)
        var threw = false
        do { try remuxer.feed(ts) } catch { threw = true }
        let label = String(format: "0x%02X", Int(streamType))
        expect(!threw, "\(label) MPEG audio is transcoded, not refused")
        guard let t = fake else {
            expect(false, "\(label) reached the transcoder")
            continue
        }
        expect(t.fedLengths.count >= 100, "\(label) framed whole MP2 frames into the transcoder")
        expect(t.fedLengths.allSatisfy { $0 == 384 }, "\(label) every fed frame is one 384-byte syncframe")
        var stepsOK = true
        for i in 1..<t.fedPTS.count where t.fedPTS[i] - t.fedPTS[i - 1] != frameTicks { stepsOK = false }
        expect(stepsOK, "\(label) source frame PTS steps by one MP2 frame duration")
        expectEq(remuxer.audioPathDescription, "MP2 stereo -> AAC stereo", "\(label) audio path description")
        expectEq(remuxer.audioCodecsAttribute, "mp4a.40.2", "\(label) playlist CODECS names the encoder output")
        remuxer.release()
        expectEq(t.released, 1, "\(label) release tears the codecs down")
    }

    // AC-3 without receiver passthrough and without the sender's
    // transcode-aac plan refuses by name, and no transcoder is ever
    // constructed.
    var built = false
    let ac3Remuxer = CastFMP4Remuxer(transcoderFactory: { _, onConfig, onFrame in
        built = true
        return FakeCastAudioTranscoder(onConfig: onConfig, onFrame: onFrame)
    })
    let ac3TS = mpegAudioFixtureTS(audioStreamType: 0x81, audioES: es,
                                   audioFrameLen: 384, audioFrameTicks: frameTicks,
                                   videoFrames: 30)
    var refusedName: String?
    do { try ac3Remuxer.feed(ac3TS) } catch let e as CastUnsupportedCodecError { refusedName = e.codecName }
    catch { refusedName = "other" }
    expectEq(refusedName, "AC-3 audio", "AC-3 refuses by name without a transcode plan")
    expect(!built, "no transcoder is constructed for AC-3 without a transcode plan")

    // transcode-aac plan (receiver answered ac-3=no): AC-3 syncframes go
    // through the transcoder and the rendition declares AAC.
    var ac3ES: [UInt8] = []
    var ac3Frame: [UInt8] = [0x0B, 0x77, 0x00, 0x00, 0x1C, 0x40, 0xE1] // 48 kHz 384 kbps 5.1
    ac3Frame.append(contentsOf: [UInt8](repeating: 0, count: 1536 - ac3Frame.count))
    for _ in 0..<60 { ac3ES.append(contentsOf: ac3Frame) }
    let ac3FrameTicks: Int64 = 1536 * CastFMP4Remuxer.ticksPerSecond / 48_000 // 2880
    var ac3Fake: FakeCastAudioTranscoder?
    var ac3Source: CastAudioSourceCodec?
    var ac3Logs: [String] = []
    let transcodeRemuxer = CastFMP4Remuxer(transcodeAC3: true, log: { ac3Logs.append($0) },
                                           transcoderFactory: { source, onConfig, onFrame in
        ac3Source = source
        let t = FakeCastAudioTranscoder(onConfig: onConfig, onFrame: onFrame)
        ac3Fake = t
        return t
    })
    let ac3TranscodeTS = mpegAudioFixtureTS(audioStreamType: 0x81, audioES: ac3ES,
                                            audioFrameLen: 1536, audioFrameTicks: ac3FrameTicks,
                                            videoFrames: 90)
    var ac3Threw = false
    do { try transcodeRemuxer.feed(ac3TranscodeTS) } catch { ac3Threw = true }
    expect(!ac3Threw, "AC-3 with transcode-aac is transcoded, not refused")
    expect(ac3Source == .ac3, "AC-3 transcoder built for the AC-3 source")
    expect((ac3Fake?.fedLengths.count ?? 0) >= 50, "framed whole AC-3 syncframes into the transcoder")
    expect(ac3Fake?.fedLengths.allSatisfy { $0 == 1536 } ?? false, "every fed AC-3 frame is one syncframe")
    expectEq(transcodeRemuxer.audioCodecsAttribute, "mp4a.40.2", "AC-3 transcode: CODECS names AAC")
    expectEq(transcodeRemuxer.audioPathDescription, "AC-3 5.1 -> AAC stereo", "AC-3 transcode: audio path")
    expect(ac3Logs.contains("transcoding AC-3 5.1 48000 Hz -> AAC-LC stereo (receiver cannot decode AC-3)"),
           "AC-3 transcode: logs the transcoding line")
    let transcodingIdx = ac3Logs.firstIndex { $0.hasPrefix("transcoding AC-3") }
    let activeIdx = ac3Logs.firstIndex { $0.hasPrefix("audio transcode active: AC-3 6ch 48000Hz") }
    expect(transcodingIdx != nil && activeIdx != nil && transcodingIdx! < activeIdx!,
           "AC-3 transcode: transcoding line precedes audio transcode active")
    let gated = ac3Logs.filter { $0.hasPrefix("transcoded audio gated: ") }
    let resumed = ac3Logs.filter { $0.hasPrefix("transcoded audio resumed after ") }
    expect(gated.count == resumed.count, "every gated run of transcoded audio logs its resume")
    if let g = gated.first {
        expect(g.hasPrefix("transcoded audio gated: 1 units dropped, pts ")
               && g.hasSuffix("s below timeline base -0.000s"),
               "gated line logs the first drop before the timeline base exists: \(g)")
    }
    transcodeRemuxer.release()

    // Passthrough wins over the transcode plan when both are set.
    var passthroughBuilt = false
    let bothRemuxer = CastFMP4Remuxer(allowAC3Passthrough: true, transcodeAC3: true,
                                      transcoderFactory: { _, onConfig, onFrame in
        passthroughBuilt = true
        return FakeCastAudioTranscoder(onConfig: onConfig, onFrame: onFrame)
    })
    do { try bothRemuxer.feed(ac3TranscodeTS) } catch {}
    expect(!passthroughBuilt, "AC-3 passthrough takes precedence over the transcode plan")
}

runMPEGTranscodeChecks()

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
    store.setDemuxedInitSegments(generation: gen1, video: Data("init1-avcC".utf8), audio: Data("a1".utf8))
    for _ in 0..<3 {
        store.addSegment(generation: gen1, durationTicks: ticks3s,
                         videoData: Data("vseg".utf8), audioData: Data("aseg".utf8))
    }
    expectEq(store.currentReadyState.segments, 3, "segment count in generation 1")
    // The ready gate is a duration, so the store must total media time too.
    expectEq(store.currentReadyState.mediaTicks, 3 * ticks3s,
             "media ticks in generation 1")

    let gen2 = store.beginGeneration()
    expectEq(store.currentReadyState.segments, 0, "generation bump resets ready count")
    expectEq(store.currentReadyState.mediaTicks, 0, "generation bump resets ready media time")
    // A stale gen-1 publisher must not claim a sequence number.
    store.addSegment(generation: gen1, durationTicks: ticks3s,
                     videoData: Data("stale".utf8), audioData: nil)
    store.setDemuxedInitSegments(generation: gen2, video: Data("init2".utf8), audio: Data("a2".utf8))
    for _ in 0..<2 {
        store.addSegment(generation: gen2, durationTicks: ticks3s,
                         videoData: Data("vseg2".utf8), audioData: Data("aseg2".utf8))
    }

    let text = store.videoPlaylistText()
    let lines = text.split(separator: "\n").map(String.init)
    expect(lines.contains("#EXT-X-VERSION:7"), "version 7")
    expect(lines.contains("#EXT-X-MEDIA-SEQUENCE:0"), "media sequence starts at 0 (5-window covers all 5)")
    expect(lines.contains("#EXT-X-DISCONTINUITY"), "discontinuity tag present at splice")
    expect(lines.contains("#EXT-X-MAP:URI=\"vinit\(gen1).mp4\""), "old generation MAP present")
    expect(lines.contains("#EXT-X-MAP:URI=\"vinit\(gen2).mp4\""), "new generation MAP present")
    expect(!text.contains("ENDLIST"), "no ENDLIST on a live playlist")
    // Contiguous sequence numbering across the splice: seg0..seg4.
    for n in 0...4 { expect(lines.contains("vseg\(n).m4s"), "vseg\(n) advertised") }
    expect(!text.contains("vseg5.m4s"), "stale-generation segment claimed no sequence number")
    // The discontinuity tag must sit immediately before the new
    // generation's MAP and its first segment, with nothing in between
    // (see section 12: no PROGRAM-DATE-TIME, ever).
    if let di = lines.firstIndex(of: "#EXT-X-DISCONTINUITY") {
        expectEq(lines[di + 1], "#EXT-X-MAP:URI=\"vinit\(gen2).mp4\"", "discontinuity precedes new MAP")
    } else {
        expect(false, "discontinuity index")
    }
    expect(lines.contains("#EXTINF:3.000,"), "EXTINF has 3 decimals")

    // Old-generation init + segments stay fetchable until ring eviction.
    expectEq(store.videoInitSegment(generation: gen1), Data("init1-avcC".utf8), "old init retained")
    expectEq(store.awaitSegment(seq: 0, rendition: .video, timeout: 0.05), Data("vseg".utf8),
             "old segment fetchable after splice")

    // Master playlist reflects the CURRENT generation's init (no avcC in
    // init2, so fallback codec string) and carries the load-bearing tags.
    let master = store.demuxedMasterPlaylistText()
    expect(master.contains("CLOSED-CAPTIONS=NONE"), "master carries CLOSED-CAPTIONS=NONE")
    expect(master.contains("BANDWIDTH="), "master carries BANDWIDTH")
    expect(master.contains("mp4a.40.2"), "master carries AAC codec")
    expect(master.contains("video.m3u8"), "master points at the video media playlist")
}

// MARK: 5. ring eviction with init retention

do {
    let store = CastHLSSegmentStore()
    let ticks: Int64 = 3 * 90_000
    let gen1 = store.beginGeneration()
    store.setDemuxedInitSegments(generation: gen1, video: Data("i1".utf8), audio: nil)
    for _ in 0..<3 {
        store.addSegment(generation: gen1, durationTicks: ticks, videoData: Data([1]), audioData: nil)
    }
    let gen2 = store.beginGeneration()
    store.setDemuxedInitSegments(generation: gen2, video: Data("i2".utf8), audio: nil)
    // Ring size 8: after 6 gen2 segments (total 9) one gen1 segment evicts.
    for _ in 0..<6 {
        store.addSegment(generation: gen2, durationTicks: ticks, videoData: Data([2]), audioData: nil)
    }
    expect(store.videoInitSegment(generation: gen1) != nil,
           "gen1 init retained while a gen1 segment is ringed")
    // Push the remaining gen1 segments out (11 total > 8 + 3).
    for _ in 0..<2 {
        store.addSegment(generation: gen2, durationTicks: ticks, videoData: Data([2]), audioData: nil)
    }
    expectEq(store.videoInitSegment(generation: gen1), nil,
             "gen1 init dropped once no ring entry references it")
    expect(store.videoInitSegment(generation: gen2) != nil, "current generation init always retained")
    // The flagged (discontinuity) segment was seg3; it evicts at 12 total.
    var text = store.videoPlaylistText()
    expect(!text.contains("#EXT-X-DISCONTINUITY-SEQUENCE"), "discontinuity-sequence absent while tag in ring")
    for _ in 0..<4 {
        store.addSegment(generation: gen2, durationTicks: ticks, videoData: Data([2]), audioData: nil)
    }
    text = store.videoPlaylistText()
    expect(text.contains("#EXT-X-DISCONTINUITY-SEQUENCE:1"), "discontinuity-sequence increments after tag rolls out")
    expect(!text.contains("#EXT-X-DISCONTINUITY\n#EXT-X-MAP:URI=\"vinit\(gen2)"),
           "no stale discontinuity tag once flagged segment evicted")

    // Live-edge hold semantics: newest+1 blocks briefly then nils on
    // timeout; far future and evicted return nil immediately.
    let t0 = Date()
    expectEq(store.awaitSegment(seq: 15, rendition: .video, timeout: 0.3), nil,
             "newest+1 held until timeout")
    expect(Date().timeIntervalSince(t0) >= 0.25, "newest+1 actually waited")
    let t1 = Date()
    expectEq(store.awaitSegment(seq: 40, rendition: .video, timeout: 5), nil, "far future 404s fast")
    expectEq(store.awaitSegment(seq: 0, rendition: .video, timeout: 5), nil, "evicted 404s fast")
    expect(Date().timeIntervalSince(t1) < 0.2, "no hold for far-future/evicted")
    // Publication wakes a held fetch.
    let publisher = Thread {
        Thread.sleep(forTimeInterval: 0.15)
        store.addSegment(generation: gen2, durationTicks: ticks, videoData: Data([9]), audioData: nil)
    }
    publisher.start()
    expectEq(store.awaitSegment(seq: 15, rendition: .video, timeout: 3), Data([9]),
             "held fetch resolves on publish")
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
    guard let config = CastAudioFrameParser.parseAC3SampleEntryConfig(.ac3, frame, 0) else {
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
    // No audio init, so the master falls back to the attribute the session
    // set from the remuxer.
    store.setDemuxedInitSegments(generation: gen, video: Data("init".utf8), audio: nil)
    expect(store.demuxedMasterPlaylistText().contains(",mp4a.40.2\""),
           "master defaults to the AAC codec")
    store.setAudioCodecsAttribute("ac-3")
    let master = store.demuxedMasterPlaylistText()
    expect(master.contains(",ac-3\""), "master names ac-3 for a passthrough")
    expect(!master.contains("mp4a"), "master drops the AAC codec for a passthrough")
    store.setAudioCodecsAttribute(nil)
    let videoOnly = store.demuxedMasterPlaylistText()
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

/// Per-track spans of one CUT, read out of its two rendition segments:
/// the video rendition carries track 1, the audio rendition track 2.
func cutSpans(_ video: Data, _ audio: Data?) -> [Int: TrackSpan] {
    var spans = segmentSpans(video)
    if let audio { for (id, span) in segmentSpans(audio) { spans[id] = span } }
    return spans
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

    var segments: [(video: Data, audio: Data?)] = []
    let remuxer = CastFMP4Remuxer()
    remuxer.onDemuxedMediaSegments = { v, a, _, _ in segments.append((v, a)) }
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
        let spans = cutSpans(segment.video, segment.audio)
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
@MainActor func ingestOneConnection(_ bytes: Data, limit: Int)
    -> (segments: [(video: Data, audio: Data?)], durations: [Int64]) {
    var segments: [(video: Data, audio: Data?)] = []
    var durations: [Int64] = []
    let remuxer = CastFMP4Remuxer()
    remuxer.onDemuxedMediaSegments = { v, a, ticks, _ in
        segments.append((v, a))
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
    let lastSegA = genA.segments[genA.segments.count - 1]
    let lastA = cutSpans(lastSegA.video, lastSegA.audio)
    let firstB = cutSpans(genB.segments[0].video, genB.segments[0].audio)
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
    store.setDemuxedInitSegments(generation: gen, video: Data("i".utf8), audio: nil)
    for _ in 0..<3 {
        store.addSegment(generation: gen, durationTicks: ticks, videoData: Data([1]), audioData: nil)
    }
    // nextSeq is 3; 3, 4 and 5 are inside the hold window, 6 is not.
    let held = Date()
    expectEq(store.awaitSegment(seq: 5, rendition: .video, timeout: 0.3), nil,
             "two past the edge is held until timeout")
    expect(Date().timeIntervalSince(held) >= 0.25, "two past the edge actually waited")
    let fast = Date()
    expectEq(store.awaitSegment(seq: 6, rendition: .video, timeout: 5), nil,
             "three past the edge 404s fast")
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
    remuxer.onDemuxedMediaSegments = { _, a, _, _ in
        if segment.isEmpty, let a { segment = a }
    }
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
    store.setDemuxedInitSegments(generation: gen, video: Data("init".utf8), audio: nil)
    for _ in 0..<4 {
        store.addSegment(generation: gen, durationTicks: ticks3s, videoData: Data([1]), audioData: nil)
    }

    let first = store.videoPlaylistText()
    expectEq(programDateTimes(first).count, 0, "no EXT-X-PROGRAM-DATE-TIME on a live playlist")
    // The load gate is four segments (CastHLSProxySession.readyMinSegments),
    // so this is the narrowest window the receiver can ever see.
    expectEq(windowSpanSeconds(first), 12.0, "four 3 s segments span 12 s of media")
    expect(windowSpanSeconds(first) - receiverPresentationDelay >= 3.0,
           "first window leaves a seek range at least one target duration wide")

    // Slide the window: windowSize is 5, so six more segments roll the
    // first four out, and the span stays the full five segments.
    for _ in 0..<6 {
        store.addSegment(generation: gen, durationTicks: ticks3s, videoData: Data([1]), audioData: nil)
    }
    let slid = store.videoPlaylistText()
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
    store.setDemuxedInitSegments(generation: gen1, video: Data("i1".utf8), audio: nil)
    for _ in 0..<2 {
        store.addSegment(generation: gen1, durationTicks: ticks3s, videoData: Data([1]), audioData: nil)
    }
    let gen2 = store.beginGeneration()
    store.setDemuxedInitSegments(generation: gen2, video: Data("i2".utf8), audio: nil)
    for _ in 0..<2 {
        store.addSegment(generation: gen2, durationTicks: ticks3s, videoData: Data([2]), audioData: nil)
    }

    let text = store.videoPlaylistText()
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
    remuxer.onDemuxedMediaSegments = { _, _, ticks, _ in durations.append(ticks) }
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
        // Demuxed audio segments carry a single traf; a muxed moof would
        // carry audio second. Either way the audio traf is the last one.
        guard let traf = trafs.last else { continue }
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
        // The AUDIO init is what the PCE decides: its esds carries the ASC.
        remuxer.onDemuxedInitSegments = { _, a in initSegment = a }
        remuxer.onDemuxedMediaSegments = { _, a, _, _ in if let a { segments.append(a) } }
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
    expect(pce.init_ != nil, "the PCE stream emits an audio init segment")
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
    var segments: [(video: Data, audio: Data?)] = []
    var durations: [Int64] = []
    var audioCounts: [Int] = []
    var logs: [String] = []
}

@MainActor func censusRemux(_ bytes: Data) -> CensusResult {
    var result = CensusResult()
    let remuxer = CastFMP4Remuxer(log: { result.logs.append($0) })
    remuxer.onDemuxedMediaSegments = { v, a, ticks, _ in
        result.segments.append((v, a))
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
        guard let audioData = segment.audio, let audio = segmentSpans(audioData)[2] else { continue }
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
    remuxer.onDemuxedInitSegments = { v, _ in initSegment = v }
    remuxer.onDemuxedMediaSegments = { _, _, _, _ in }
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

    expectEq(logs.filter { $0 == "video init: mehd 24h, liveness recorded" }.count, 1,
             "the declared duration is logged once per generation")
    expectEq(logs.filter { $0 == "audio init: mehd 24h, liveness recorded" }.count, 1,
             "the audio rendition declares its duration too")
}

runInitLivenessChecks()

// MARK: 13. DEMUXED renditions (2026-09-13)
//
// Measured on the Google TV Streamer's Cast runtime,
// isTypeSupported("video/mp4; codecs=\"avc1.64002A,ac-3\"") and
// isTypeSupported("video/mp4; codecs=\"ac-3\"") are both false, but
// isTypeSupported("audio/mp4; codecs=\"ac-3\"") is TRUE, and Emby's web
// receiver plays AC-3 through MediaCodecAudioDecoder from a separate audio
// SourceBuffer. One muxed rendition can therefore only ever declare an AAC
// codec string, which is what forces the server-side AAC output profile, so
// the proxy now also serves the pair: vinit/vseg and ainit/aseg.
//
// The Android side runs the same renditions through ffprobe and through a
// real headless Chromium's two SourceBuffers
// (CastDemuxedRenditionTest). What is checked here is the part that has to
// hold identically on both platforms: one traf per rendition segment, the
// same moof sequence number across the three renditions of one cut,
// identical playlist numbering, and an audio EXTINF within one frame of the
// video one.

/// Track IDs of every traf in a segment, in order.
func trafTrackIDs(_ segment: Data) -> [Int64] {
    let b = [UInt8](segment)
    var out: [Int64] = []
    for (type, mStart, mEnd) in boxChildren(b, 0, b.count) where type == "moof" {
        for (t2, tStart, tEnd) in boxChildren(b, mStart, mEnd) where t2 == "traf" {
            for (t3, pStart, _) in boxChildren(b, tStart, tEnd) where t3 == "tfhd" {
                out.append(be32(b, pStart + 4))
            }
        }
    }
    return out
}

/// mfhd sequence_number of a segment.
func moofSequenceNumber(_ segment: Data) -> Int64? {
    let b = [UInt8](segment)
    for (type, mStart, mEnd) in boxChildren(b, 0, b.count) where type == "moof" {
        for (t2, pStart, _) in boxChildren(b, mStart, mEnd) where t2 == "mfhd" {
            return be32(b, pStart + 4)
        }
    }
    return nil
}

/// trun sample counts of a segment, in traf order.
func trunSampleCounts(_ segment: Data) -> [Int64] {
    let b = [UInt8](segment)
    var out: [Int64] = []
    for (type, mStart, mEnd) in boxChildren(b, 0, b.count) where type == "moof" {
        for (t2, tStart, tEnd) in boxChildren(b, mStart, mEnd) where t2 == "traf" {
            for (t3, pStart, _) in boxChildren(b, tStart, tEnd) where t3 == "trun" {
                out.append(be32(b, pStart + 4))
            }
        }
    }
    return out
}

@MainActor func runDemuxedRenditionChecks() {
    guard let bytes = continuityFixtureTS() else {
        print("SKIP demuxed renditions (no ffmpeg fixture)")
        return
    }
    var videoSegments: [Data] = []
    var audioSegments: [Data] = []
    var videoTicks: [Int64] = []
    var audioTicks: [Int64] = []
    var videoInit: Data?
    var audioInit: Data?
    let remuxer = CastFMP4Remuxer()
    remuxer.onDemuxedInitSegments = { v, a in videoInit = v; audioInit = a }
    remuxer.onDemuxedMediaSegments = { v, a, vTicks, aTicks in
        videoSegments.append(v)
        if let a { audioSegments.append(a) }
        videoTicks.append(vTicks)
        audioTicks.append(aTicks)
    }
    var offset = 0
    while offset < bytes.count {
        let n = min(64 * 1024, bytes.count - offset)
        try? remuxer.feed(bytes.subdata(in: offset..<(offset + n)))
        offset += n
    }
    remuxer.release()

    expect(videoInit != nil && audioInit != nil, "demuxed: both init segments emitted")
    expect(videoSegments.count >= 3, "demuxed: segments produced (\(videoSegments.count))")
    expectEq(videoSegments.count, audioSegments.count, "demuxed: one audio segment per video segment")

    // The audio-only moov declares the audio track and nothing else; the
    // video-only moov the reverse. A stray second trak is what would make
    // the receiver's codec string a lie again.
    if let videoInit, let audioInit {
        let vTraks = boxChildren([UInt8](videoInit), 0, videoInit.count)
            .filter { $0.0 == "moov" }
            .flatMap { boxChildren([UInt8](videoInit), $0.1, $0.2) }
            .filter { $0.0 == "trak" }
        let aTraks = boxChildren([UInt8](audioInit), 0, audioInit.count)
            .filter { $0.0 == "moov" }
            .flatMap { boxChildren([UInt8](audioInit), $0.1, $0.2) }
            .filter { $0.0 == "trak" }
        expectEq(vTraks.count, 1, "demuxed: the video init declares one trak")
        expectEq(aTraks.count, 1, "demuxed: the audio init declares one trak")
        expectEq(CastHLSSegmentStore.audioCodecString(from: audioInit), "mp4a.40.2",
                 "demuxed: the audio init's sample entry names the codec")
        expect(CastHLSSegmentStore.audioCodecString(from: videoInit) == nil,
               "demuxed: the video init carries no audio sample entry")
        // The mehd/mvhd 24 h declared duration survives into BOTH
        // renditions: without it Chromium reads liveness as kLive and pins
        // the video renderer to one buffered frame.
        expect(videoInit.range(of: Data("mehd".utf8)) != nil, "demuxed: the video init keeps mehd")
        expect(audioInit.range(of: Data("mehd".utf8)) != nil, "demuxed: the audio init keeps mehd")
    }

    var oneTraf = true
    var rightTrack = true
    var sameSequence = true
    for i in videoSegments.indices {
        if trafTrackIDs(videoSegments[i]) != [1] { oneTraf = false; rightTrack = false }
        if trafTrackIDs(audioSegments[i]) != [2] { oneTraf = false; rightTrack = false }
        let seqs = [moofSequenceNumber(videoSegments[i]),
                    moofSequenceNumber(audioSegments[i])]
        if Set(seqs).count != 1 { sameSequence = false }
    }
    expect(oneTraf, "demuxed: exactly one traf per rendition segment")
    expect(rightTrack, "demuxed: each rendition names the track it always did")
    expect(sameSequence, "demuxed: both renditions of a cut share one moof sequence")

    // Audio census per segment, the rule the muxed shape already obeys: the
    // frames in the segment add up to the duration the playlist declares.
    var frames: Int64 = 0
    var ticks: Int64 = 0
    for i in audioSegments.indices {
        frames += trunSampleCounts(audioSegments[i]).reduce(0, +)
        ticks += audioTicks[i]
    }
    let frameTicks = frames > 0 ? Double(ticks) / Double(frames) : 0
    var censusOK = frames > 0
    for i in audioSegments.indices {
        let count = Double(trunSampleCounts(audioSegments[i]).reduce(0, +))
        let expected = Double(audioTicks[i]) / max(1, frameTicks)
        if abs(expected - count) > 1.0 { censusOK = false }
    }
    expect(censusOK, "demuxed: every audio segment carries the frames its EXTINF calls for")

    // And the playlists the store builds from them.
    let store = CastHLSSegmentStore()
    let gen = store.beginGeneration()
    store.setDemuxedInitSegments(generation: gen, video: videoInit ?? Data(), audio: audioInit)
    for i in videoSegments.indices {
        _ = store.addSegment(generation: gen, durationTicks: videoTicks[i],
                             videoData: videoSegments[i],
                             audioData: i < audioSegments.count ? audioSegments[i] : nil,
                             audioDurationTicks: audioTicks[i])
    }
    let master = store.demuxedMasterPlaylistText()
    expect(master.contains("#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\""),
           "demuxed master: advertises the audio rendition")
    expect(master.contains("URI=\"audio.m3u8\"") && master.contains("AUDIO=\"aud\""),
           "demuxed master: binds the audio group to the variant")
    expect(master.contains(",mp4a.40.2\""), "demuxed master: CODECS names the audio honestly")
    expect(master.contains("CLOSED-CAPTIONS=NONE"), "demuxed master: keeps Shaka's CEA parser off")
    expect(master.hasSuffix("video.m3u8\n"), "demuxed master: points at the video rendition")

    let videoPlaylist = store.videoPlaylistText()
    let audioPlaylist = store.audioPlaylistText()
    func matches(_ text: String, _ pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: 1))
        }
    }
    let vSeqs = matches(videoPlaylist, "vseg([0-9]+)\\.m4s")
    let aSeqs = matches(audioPlaylist, "aseg([0-9]+)\\.m4s")
    expect(!vSeqs.isEmpty, "demuxed playlists: the window is populated")
    expectEq(vSeqs, aSeqs, "demuxed playlists: identical sequence numbering")
    expectEq(matches(videoPlaylist, "#EXT-X-MEDIA-SEQUENCE:([0-9]+)"),
             matches(audioPlaylist, "#EXT-X-MEDIA-SEQUENCE:([0-9]+)"),
             "demuxed playlists: identical MEDIA-SEQUENCE")
    expectEq(matches(videoPlaylist, "#EXT-X-TARGETDURATION:([0-9]+)"),
             matches(audioPlaylist, "#EXT-X-TARGETDURATION:([0-9]+)"),
             "demuxed playlists: identical TARGETDURATION")
    expect(videoPlaylist.contains("#EXT-X-MAP:URI=\"vinit"), "demuxed playlists: video maps vinit")
    expect(audioPlaylist.contains("#EXT-X-MAP:URI=\"ainit"), "demuxed playlists: audio maps ainit")
    let vExtinf = matches(videoPlaylist, "#EXTINF:([0-9.]+)").compactMap(Double.init)
    let aExtinf = matches(audioPlaylist, "#EXTINF:([0-9.]+)").compactMap(Double.init)
    var extinfOK = vExtinf.count == aExtinf.count && !vExtinf.isEmpty
    let frameSeconds = frameTicks / Double(CastFMP4Remuxer.ticksPerSecond)
    for i in vExtinf.indices where i < aExtinf.count {
        if abs(vExtinf[i] - aExtinf[i]) > frameSeconds + 0.001 { extinfOK = false }
    }
    expect(extinfOK, "demuxed playlists: EXTINF differs by less than one audio frame")
}

runDemuxedRenditionChecks()

print(failures == 0 ? "\nALL TESTS PASSED" : "\n\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
