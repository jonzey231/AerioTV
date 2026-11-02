#!/bin/zsh
# Unit tests for the search pure logic (Shared/LiveSearchMatcher.swift),
# ported from the Android Live TV search rules (LiveSearchMatcher.kt,
# DisplayChannels.kt computeLiveSearch) and the Global Search caps
# (SearchViewModel.kt). The repo has no unit-test target, so this compiles
# the shipping source directly with swiftc and runs it on macOS.
set -e
cd "$(dirname "$0")"
OUT=$(mktemp -d)
xcrun swiftc -swift-version 6 -O -o "$OUT/search_tests" \
    main.swift \
    ../../Shared/LiveSearchMatcher.swift
"$OUT/search_tests"
