#!/bin/zsh
# Unit tests for the mid-play AirPlay handover hold
# (App/AirPlayMidPlayHold.swift): external playback stays off while the LAN
# item is prepared, comes back on for every outcome, a stale handover never
# releases a newer one's hold, and the player resumes after the swap unless
# the user paused. The repo has no unit-test target, so this compiles the
# shipping source directly with swiftc and runs it on macOS.
set -e
cd "$(dirname "$0")"
OUT=$(mktemp -d)
xcrun swiftc -swift-version 6 -O -o "$OUT/airplay_midplay_tests" \
    main.swift \
    ../../App/AirPlayMidPlayHold.swift
"$OUT/airplay_midplay_tests"
