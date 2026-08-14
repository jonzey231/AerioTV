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
    expectEq(store.currentSegmentsInGeneration, 3, "segment count in generation 1")

    let gen2 = store.beginGeneration()
    expectEq(store.currentSegmentsInGeneration, 0, "generation bump resets ready count")
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
    // The discontinuity tag must sit immediately before gen2's MAP+first segment.
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

print(failures == 0 ? "\nALL TESTS PASSED" : "\n\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
