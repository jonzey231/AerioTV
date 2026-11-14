#!/bin/zsh
# Unit tests for the Dispatcharr request gate (Networking/DispatcharrRequestGate.swift
# and Networking/DispatcharrRateLimitRetry.swift): Retry-After parsing, the
# per-server 429 pause, the rejected-key gate and prompt, the held-key re-check
# schedule, the countdown retry, and the setup sender's key check. Ported from
# Android DispatcharrRateLimitTest, DispatcharrKeyGateTest,
# DispatcharrKeyRecheckScheduleTest, and SetupKeyPreflightTest. The repo has no
# unit-test target, so this compiles the shipping sources with swiftc and runs
# on macOS. Must end with ALL TESTS PASSED.
set -e
cd "$(dirname "$0")"
OUT=$(mktemp -d)
xcrun swiftc -swift-version 6 -O -o "$OUT/dispatcharr_gate_tests" \
    main.swift \
    ../../Networking/DispatcharrRequestGate.swift \
    ../../Networking/DispatcharrRateLimitRetry.swift \
    ../../Networking/RedirectAuthPolicy.swift
"$OUT/dispatcharr_gate_tests"
