#!/bin/zsh
# Unit tests for the cast HLS proxy's pure logic (PTS ladder, downmix,
# playlist splices, ring eviction, codec strings). The repo has no
# unit-test target (AerioTVUITests is UI-only), so these compile the
# shipping sources directly with swiftc and run on macOS.
set -e
cd "$(dirname "$0")"
SRC=../../Networking/CastHLSProxy
OUT=$(mktemp -d)
# The AirPlay AAC master reads the SPS frame rate with the shipping
# H264SPSTiming; lift it (and VideoRateStandards) out of TSHLSRemuxer.swift
# rather than compiling the whole remuxer.
awk '/^enum VideoRateStandards/,/^}/; /^enum H264SPSTiming/,/^}/' \
    ../../App/TSHLSRemuxer.swift > "$OUT/H264SPSTiming.swift"
xcrun swiftc -swift-version 6 -O -o "$OUT/casthls_tests" \
    main.swift \
    "$SRC/CastFMP4Remuxer.swift" \
    "$SRC/CastHLSSegmentStore.swift" \
    "$SRC/CastAudioFrameParser.swift" \
    "$SRC/CastAudioTranscoder.swift" \
    ../../App/AirPlayAACVariant.swift \
    "$OUT/H264SPSTiming.swift"
"$OUT/casthls_tests"
