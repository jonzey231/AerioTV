#!/bin/zsh
# Unit tests for the cast HLS proxy's pure logic (PTS ladder, downmix,
# playlist splices, ring eviction, codec strings). The repo has no
# unit-test target (AerioTVUITests is UI-only), so these compile the
# shipping sources directly with swiftc and run on macOS.
set -e
cd "$(dirname "$0")"
SRC=../../Networking/CastHLSProxy
OUT=$(mktemp -d)
xcrun swiftc -swift-version 6 -O -o "$OUT/casthls_tests" \
    main.swift \
    "$SRC/CastFMP4Remuxer.swift" \
    "$SRC/CastHLSSegmentStore.swift" \
    "$SRC/CastAudioTranscoder.swift"
"$OUT/casthls_tests"
