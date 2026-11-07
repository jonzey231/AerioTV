#!/bin/zsh
# Pure-logic tests for the EPG background sweep diff (Shared/EPGDayDiff.swift),
# port of the Android EpgDayDiffTest. No unit-test target exists, so this
# compiles the shipping source with swiftc and runs it on macOS.
set -e
cd "$(dirname "$0")"
OUT=$(mktemp -d)
xcrun swiftc -swift-version 6 -O -o "$OUT/epgdiff_tests" main.swift ../../Shared/EPGDayDiff.swift
"$OUT/epgdiff_tests"
