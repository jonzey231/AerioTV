#!/bin/zsh
# Unit tests for the Cast launch intent (App/CastLaunchIntent.swift): which
# receiver each picker entry launches, the launch-credentials wire strings
# shared with the Android sender and TV app, and how the intent carries over
# a device switch, a session end, a failed start, and an app restart. The
# repo has no unit-test target, so this compiles the shipping source
# directly with swiftc and runs it on macOS.
set -e
cd "$(dirname "$0")"
OUT=$(mktemp -d)
xcrun swiftc -swift-version 6 -O -o "$OUT/cast_launch_tests" \
    main.swift \
    ../../App/CastLaunchIntent.swift
"$OUT/cast_launch_tests"
