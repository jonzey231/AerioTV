import Foundation

/// Sort orders offered on the Movies and TV Shows grids.
///
/// The set is fixed by the redesign dossier (section 5.5) and is deliberately
/// identical on Android, so the two platforms stay describable by one sentence
/// in the docs and one row in a support reply.
enum MediaSort: String, CaseIterable, Identifiable, Sendable {
    case title
    case dateAdded
    case releaseYear
    case rating
    case random

    var id: String { rawValue }

    var label: String {
        switch self {
        case .title: return "Title"
        case .dateAdded: return "Date Added"
        case .releaseYear: return "Release Year"
        case .rating: return "Rating"
        case .random: return "Random"
        }
    }

    /// The alpha-jump rail only makes sense against an alphabetical ordering.
    /// Every other sort hides it rather than showing a rail whose letters do
    /// not correspond to anything on screen.
    var supportsAlphaJump: Bool { self == .title }
}

/// Pure sort/filter layer for the browse grids.
///
/// Deliberately free of SwiftUI and SwiftData, exactly like `HomeRowsBuilder`:
/// ordering rules are the part most likely to be argued about and revised, so
/// they live somewhere that can be reasoned about and exercised directly rather
/// than only through a rendered grid on a television.
///
/// `VODDisplayItem` carries only what the poster card renders, so the two
/// fields that sorting needs and it lacks (server add time, normalised sort
/// title) are supplied by the caller. The catalog owns `createdAt`; the sort
/// title is derived here through the same `MediaSortTitle` the ingest actor
/// used, so a title sorts identically whether it came from the catalog or from
/// a live server response.
enum MediaGridQuery {

    /// Order `items` for display.
    ///
    /// - Parameters:
    ///   - createdAt: server add time by item id. Items missing an entry sort
    ///     last under Date Added rather than being dropped, mirroring the
    ///     undated-sorts-after-dated rule already used by the Home shelves.
    ///   - seed: session-stable value for `.random`. Held for the life of the
    ///     tab so scrolling away and back does not reshuffle the library under
    ///     the user, which is the one thing that makes a Random sort useless.
    static func apply(sort: MediaSort,
                      to items: [VODDisplayItem],
                      createdAt: [String: Date] = [:],
                      seed: UInt64 = 0) -> [VODDisplayItem] {
        switch sort {
        case .title:
            return items.sorted { lhs, rhs in
                let l = MediaSortTitle.make(from: lhs.name)
                let r = MediaSortTitle.make(from: rhs.name)
                if l != r { return l < r }
                return lhs.id < rhs.id
            }

        case .dateAdded:
            return items.sorted { lhs, rhs in
                switch (createdAt[lhs.id], createdAt[rhs.id]) {
                case let (l?, r?):
                    if l != r { return l > r }         // newest first
                    return lhs.id < rhs.id
                case (nil, _?): return false           // undated sorts after dated
                case (_?, nil): return true
                default: return lhs.id < rhs.id
                }
            }

        case .releaseYear:
            return items.sorted { lhs, rhs in
                let l = Int(lhs.releaseYear)
                let r = Int(rhs.releaseYear)
                switch (l, r) {
                case let (l?, r?):
                    if l != r { return l > r }         // newest first
                    return lhs.id < rhs.id
                case (nil, _?): return false
                case (_?, nil): return true
                default: return lhs.id < rhs.id
                }
            }

        case .rating:
            return items.sorted { lhs, rhs in
                // displayRating is already blanked for absent or zero ratings
                // upstream, so an empty string genuinely means "unrated".
                let l = Double(lhs.rating)
                let r = Double(rhs.rating)
                switch (l, r) {
                case let (l?, r?):
                    if l != r { return l > r }         // highest first
                    return lhs.id < rhs.id
                case (nil, _?): return false
                case (_?, nil): return true
                default: return lhs.id < rhs.id
                }
            }

        case .random:
            // Sorting on a derived key rather than calling shuffled(): the key
            // depends only on (seed, id), so the same library and the same seed
            // always produce the same order, and an item arriving from a later
            // catalog page slots in deterministically instead of reshuffling
            // everything already on screen.
            return items.sorted { lhs, rhs in
                let l = shuffleKey(for: lhs.id, seed: seed)
                let r = shuffleKey(for: rhs.id, seed: seed)
                if l != r { return l < r }
                return lhs.id < rhs.id
            }
        }
    }

    /// First index in `items` for each alpha bucket, in rail order.
    ///
    /// Only buckets that actually exist are returned, so the rail never offers
    /// a letter that jumps nowhere. Assumes `items` is already Title-sorted;
    /// the caller guarantees that by only showing the rail for `.title`.
    static func alphaIndex(for items: [VODDisplayItem]) -> [(bucket: String, index: Int)] {
        var seen = Set<String>()
        var out: [(String, Int)] = []
        for (index, item) in items.enumerated() {
            let bucket = MediaSortTitle.bucket(for: MediaSortTitle.make(from: item.name))
            if seen.insert(bucket).inserted {
                out.append((bucket, index))
            }
        }
        // "#" is produced by any non-letter first character and can therefore
        // appear anywhere in a Title-sorted list depending on the locale's
        // collation; pin it to the top so the rail always reads # A B C.
        return out.sorted { lhs, rhs in
            if lhs.0 == "#" { return rhs.0 != "#" }
            if rhs.0 == "#" { return false }
            return lhs.0 < rhs.0
        }
    }

    /// SplitMix64 finalizer over the item id mixed with the session seed. Cheap,
    /// well distributed, and no shared RNG state to make ordering depend on the
    /// order in which rows happen to be visited.
    ///
    /// The id is hashed with FNV-1a rather than `hashValue`: Swift seeds
    /// `Hashable` randomly per process, which would make this function's output
    /// unreproducible and untestable, and would quietly move the source of
    /// per-session freshness out of `seed` where the caller can see it.
    private static func shuffleKey(for id: String, seed: UInt64) -> UInt64 {
        var h: UInt64 = 0xCBF29CE484222325
        for byte in id.utf8 {
            h = (h ^ UInt64(byte)) &* 0x100000001B3
        }
        var z = seed &+ h &+ 0x9E3779B97F4A7C15
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
