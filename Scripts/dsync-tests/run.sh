#!/bin/zsh
# Unit tests for the Dispatcharr Sync pure logic (Shared/Dsync), ported
# from the Android DsyncCoexistenceTest, DsyncManualTest, HeldProgressTest,
# ConvergeRoundTripTest (pure parts), and SetupSourceChoiceTest. The repo
# has no unit-test target (AerioTVUITests is UI-only), so these compile
# the shipping sources directly with swiftc and run on macOS.
set -e
cd "$(dirname "$0")"
SRC=../../Shared/Dsync
OUT=$(mktemp -d)
xcrun swiftc -swift-version 6 -O -o "$OUT/dsync_tests" \
    main.swift \
    "$SRC/DsyncJSON.swift" \
    "$SRC/DsyncSyncItems.swift" \
    "$SRC/DsyncSchema.swift" \
    "$SRC/DsyncV2.swift" \
    "$SRC/DsyncReadiness.swift" \
    "$SRC/DsyncSettingsValidator.swift" \
    "$SRC/DsyncHeld.swift" \
    "$SRC/SetupSourceChoice.swift"
"$OUT/dsync_tests"
