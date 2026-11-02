#!/bin/zsh
# Unit tests for "Set up a TV from your phone" and the QR code parser
# (Shared/Setup/SetupProtocol.swift), ported from Android SetupProtocolTest,
# ScannedCodeTest, and CodeTextImportTest, plus the RFC 7748 and RFC 5869
# vectors and a sealed-envelope vector produced by a Java port of Android's
# SetupCrypto. The repo has no unit-test target, so this compiles the
# shipping source with swiftc and runs on macOS. Must end with ALL TESTS PASSED.
set -e
cd "$(dirname "$0")"
OUT=$(mktemp -d)
xcrun swiftc -swift-version 6 -O -o "$OUT/setup_tests" \
    main.swift \
    ../../Shared/Setup/SetupProtocol.swift
"$OUT/setup_tests"
