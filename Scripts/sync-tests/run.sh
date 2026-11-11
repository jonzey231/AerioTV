#!/bin/zsh
# iCloud sync ordering rules (Shared/SyncRules.swift): preference stamps,
# the per-entry watch-progress merge, and the credential rule. The repo has
# no unit-test target, so this compiles the shipping source with swiftc and
# runs on macOS. Must end with ALL TESTS PASSED.
set -e
cd "$(dirname "$0")"
OUT=$(mktemp -d)
xcrun swiftc -swift-version 6 -O -o "$OUT/sync_tests" \
    main.swift \
    ../../Shared/SyncRules.swift
"$OUT/sync_tests"
