#!/bin/zsh
# Unit tests for the player relay's pure logic (Networking/PlayerRelayPolicy.swift
# and the VOD header rule in Networking/RedirectAuthPolicy.swift): the HLS
# playlist rewrite for every URI line and URI attribute, relative URIs, the
# DVR playlist transform, which URIs carry the sign-in, the LL-HLS
# directives, relay paths, request heads, and X-API-Key only for VOD. The
# repo has no unit-test target, so this compiles the shipping sources with
# swiftc and runs on macOS. Must end with ALL TESTS PASSED.
set -e
cd "$(dirname "$0")"
OUT=$(mktemp -d)
xcrun swiftc -swift-version 6 -O -o "$OUT/player_relay_tests" \
    main.swift \
    ../../Networking/PlayerRelayPolicy.swift \
    ../../Networking/RedirectAuthPolicy.swift
"$OUT/player_relay_tests"
