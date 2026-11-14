#!/bin/zsh
# Unit tests for the profile sign-in hold after a server address change
# (Shared/Profiles/ProfileHostHold.swift, review finding A-APP-1): route-change
# detection, the same-server decision, the hold in front of every outbound
# use of a profile's sign-in, the hold surviving a relaunch, the snapshot and
# per-profile tags, the sign-in form's line (KeySignInCopy), and the roster
# sync pause while a profile is held (DsyncRosterPause). The repo has
# no unit-test target, so this compiles the shipping sources with swiftc
# (ProfileStore and its Dispatcharr Sync dependencies, as the dsync tests do)
# and runs on macOS. Must end with ALL TESTS PASSED.
set -e
cd "$(dirname "$0")"
SRC=../../Shared/Dsync
OUT=$(mktemp -d)
xcrun swiftc -swift-version 6 -O -o "$OUT/profile_host_tests" \
    main.swift \
    ../../Shared/Profiles/ProfileHostHold.swift \
    ../../Shared/Profiles/ProfileRules.swift \
    ../../Shared/Profiles/ProfileStore.swift \
    "$SRC/DsyncJSON.swift" \
    "$SRC/DsyncSyncItems.swift" \
    "$SRC/DsyncSchema.swift" \
    "$SRC/DsyncV2.swift" \
    "$SRC/DsyncReadiness.swift" \
    "$SRC/DsyncSettingsValidator.swift" \
    "$SRC/DsyncHeld.swift" \
    "$SRC/SetupSourceChoice.swift" \
    "$SRC/DsyncManagerRules.swift" \
    "$SRC/DsyncSettingsMap.swift" \
    "$SRC/CloudSnapshots.swift" \
    ../../Networking/DispatcharrRequestGate.swift \
    ../../Networking/DispatcharrRateLimitRetry.swift \
    ../../Networking/RedirectAuthPolicy.swift
"$OUT/profile_host_tests"
