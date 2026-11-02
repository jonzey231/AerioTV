//  DsyncReadiness.swift
//  Aerio
//
//  Readiness gate for keys whose rows are translated from local ids to the
//  server's integer ids (schema section 4). A push of a cache-dependent key
//  waits while its id cache is not built and local rows exist that cannot
//  be translated; a deferred key stays dirty. Port of the Android
//  core/sync/dsync/DsyncReadiness.kt.
//
//  Pure: no UIKit, no SwiftData, no singletons.

import Foundation

enum DsyncReadiness {
    enum Cache: Sendable { case channels, vodCatalog }

    enum Decision: Sendable {
        case push, deferred
        /// Cache built, some rows still untranslated: push the rest, keep the key dirty.
        case pushPartial
    }

    /// The id cache [key] translates through, or nil when it needs none.
    static func cacheFor(_ key: DsyncKey) -> Cache? {
        switch key {
        case .favorites, .recents, .reminders, .collections: return .channels
        case .progress, .watchlist, .hiddenTitles: return .vodCatalog
        default: return nil
        }
    }

    static func decide(_ key: DsyncKey, cacheReady: Bool, unresolvedRows: Int) -> Decision {
        switch cacheFor(key) {
        case nil: return .push
        case .channels?: return cacheReady ? .push : .deferred
        case .vodCatalog?:
            if unresolvedRows <= 0 { return .push }
            return cacheReady ? .pushPartial : .deferred
        }
    }

    /// On a catalog page write mid-sweep: retry a deferred VOD key's push now.
    static func retryDuringSweep(_ key: DsyncKey, cacheReady: Bool, probeMisses: Int) -> Bool {
        cacheFor(key) == .vodCatalog && !cacheReady && probeMisses == 0
    }

    /// Minimum gap between page-write re-checks of the waiting keys.
    static let PAGE_RECHECK_MS: Int64 = 3_000

    /// Whether the key is dirty after this write attempt: a deferred key stays dirty.
    static func dirtyAfter(_ decision: Decision, putOk: Bool, dirtyBefore: Bool) -> Bool {
        switch decision {
        case .deferred, .pushPartial: return true
        case .push: return putOk ? false : dirtyBefore
        }
    }
}
