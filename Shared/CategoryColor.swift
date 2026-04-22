import SwiftUI

// MARK: - Program Category Colors
//
// Category-based background tinting for EPG program cells, with
// per-category user-customisable colour overrides.
//
// The bucket taxonomy is Sports / Movies / Kids / News with priority
// order Kids > Sports > News > Movie — a "Kids Sports" program colours
// as Kids, a "News drama" as News, etc. The priority is applied in
// `CategoryColor.bucket(for:)` (outer match order below).
//
// Colour palette: each bucket ships with a Material-Design-600 hex as
// its default (`ProgramCategory.defaultHex`), but users can override
// any of the four via Settings → Guide Display → tap a colour row.
// Overrides are persisted as hex strings in UserDefaults under
// `"categoryColor.<bucket>"` keys (see `storageKey` below) and read
// live on every render — so flipping a colour in Settings repaints
// the guide without an app restart.
//
// The category-string → bucket matcher casefolds the input, splits on
// `/ , ;`, then probes each token against a bucket's aliases. Aliases
// include localised terms (Fußball, Noticias, Jeunesse, etc.) because
// real XMLTV feeds in the wild use them.
//
// Gated by `UserDefaults.standard.bool(forKey: "enableCategoryColors")`
// (default on). When the toggle is off, or a cell has no matching
// category, the cell falls back to the neutral live/focused/default
// tint. When on, focused and currently-airing cells still override
// the category tint so user focus and "now playing" signals stay
// readable.
//
// IMPORTANT: tinting requires EPG data that actually includes
// categories. Coverage by server type:
//   • Dispatcharr — works out of the box. AerioTV fetches
//     `{baseURL}/output/epg` (Dispatcharr's XMLTV output endpoint,
//     which preserves `<category>` tags from the upstream source)
//     instead of the `/api/epg/*` JSON endpoints (which strip
//     categories). See `EPGGuideView.fetchDispatcharr()`.
//   • M3U + XMLTV — works out of the box (we parse the XMLTV
//     source directly via `XMLTVParser`).
//   • Xtream Codes — no category data available today; its
//     `get_short_epg` response doesn't include a genre field.
enum ProgramCategory: String, CaseIterable {
    case sports
    case movie
    case kids
    case news
    // Added after #22 feedback pass — real XMLTV feeds (Dispatcharr's
    // Zap2it / Schedules Direct passthrough in particular) lean on
    // these as distinct genres. Without dedicated buckets, ~10k+
    // programs per user were falling through to the neutral tint.
    case documentary
    case drama
    case comedy
    case reality
    case educational
    case scifi
    case music

    /// Human-readable label used in Settings rows.
    var displayName: String {
        switch self {
        case .sports:      return "Sports"
        case .movie:       return "Movies"
        case .kids:        return "Kids"
        case .news:        return "News"
        case .documentary: return "Documentary"
        case .drama:       return "Drama"
        case .comedy:      return "Comedy"
        case .reality:     return "Reality"
        case .educational: return "Educational"
        case .scifi:       return "Sci-Fi / Fantasy"
        case .music:       return "Music"
        }
    }

    /// SF Symbol shown on the Settings row so the bucket is
    /// immediately recognisable without reading the label.
    var sfSymbol: String {
        switch self {
        case .sports:      return "sportscourt.fill"
        case .movie:       return "film.fill"
        case .kids:        return "figure.2.and.child.holdinghands"
        case .news:        return "newspaper.fill"
        case .documentary: return "doc.text.magnifyingglass"
        case .drama:       return "theatermasks.fill"
        case .comedy:      return "face.smiling.inverse"
        case .reality:     return "tv.fill"
        case .educational: return "graduationcap.fill"
        case .scifi:       return "sparkles.rectangle.stack.fill"
        case .music:       return "music.note"
        }
    }

    /// UserDefaults key for this category's colour override. Missing
    /// key ⇒ use `defaultHex`. Removed key ⇒ same. Stored as a
    /// 6-character uppercase hex string (e.g. `"3949AB"`).
    var storageKey: String { "categoryColor.\(rawValue)" }

    /// Material-Design 600-shade hex — the default when the user
    /// hasn't picked a custom colour. Each bucket picks a distinct
    /// hue so adjacent categories (e.g., Drama + Comedy on a TBS-
    /// style channel) don't blur together visually.
    var defaultHex: String {
        switch self {
        case .sports:      return "3949AB" // Indigo 600
        case .movie:       return "5E35B1" // Deep Purple 600
        case .kids:        return "039BE5" // Light Blue 600
        case .news:        return "43A047" // Green 600
        case .documentary: return "6D4C41" // Brown 600 — editorial weight
        case .drama:       return "C62828" // Red 800 — dramatic contrast
        case .comedy:      return "F9A825" // Yellow 800 — warm / upbeat
        case .reality:     return "EC407A" // Pink 400 — high-vis tabloid
        case .educational: return "00897B" // Teal 600 — calm / studious
        case .scifi:       return "00838F" // Cyan 800 — "cool blue" genre cliché
        case .music:       return "D81B60" // Pink 600 — distinct from reality
        }
    }

    /// Resolved colour for this category: user override if set,
    /// default otherwise. Read fresh on every access so
    /// customisations take effect live.
    var baseColor: Color {
        let hex = UserDefaults.standard.string(forKey: storageKey) ?? defaultHex
        return Color(hex: hex)
    }

    /// Persist a custom colour for this category. Pass `nil` to
    /// clear the override (revert to default). SwiftUI `@AppStorage`
    /// bindings pointing at `storageKey` will fire automatically on
    /// this write, triggering a guide re-render.
    func setCustomHex(_ hex: String?) {
        if let hex, !hex.isEmpty {
            UserDefaults.standard.set(hex.uppercased(), forKey: storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: storageKey)
        }
    }

    /// Substring aliases (all lowercase). Longer / more specific
    /// entries are listed first for readability; the matcher uses
    /// `contains()` so placement within a bucket is cosmetic. The
    /// priority comes from the outer matching order in
    /// `CategoryColor.bucket(for:)`.
    var aliases: [String] {
        switch self {
        case .kids:
            // First priority so "Kids Sports" colours as kids.
            return ["kids", "children", "child", "animated", "animation",
                    "cartoon", "family", "jeunesse", "infantil", "niños",
                    "zeichentrick", "dzieci"]
        case .sports:
            return ["sport", "football", "soccer", "basketball", "baseball",
                    "hockey", "boxing", "rugby", "tennis", "golf",
                    "swimming", "cricket", "nfl", "nba", "mlb", "nhl",
                    "fútbol", "fussball", "fußball"]
        case .news:
            return ["news", "newsmagazine", "current affairs", "noticias",
                    "nachrichten", "journal", "informativo", "weather",
                    "politics", "political"]
        case .documentary:
            return ["documentary", "docudrama", "nature", "biography",
                    "history", "historical", "science"]
        case .educational:
            return ["educational", "educacional", "tutorial", "how-to",
                    "instructional"]
        case .reality:
            return ["reality", "game show", "game-show", "competition reality",
                    "dating", "talk show", "talk", "shopping"]
        case .music:
            return ["music", "concert", "musical", "música"]
        case .scifi:
            return ["science fiction", "sci-fi", "scifi", "fantasy",
                    "supernatural", "horror"]
        case .comedy:
            // Keep this bucket LAST among TV-genre buckets —
            // "Dark comedy" / "Comedy drama" should fall here,
            // while "Sitcom" alone still matches via alias.
            return ["comedy", "sitcom", "stand-up", "stand up"]
        case .drama:
            return ["drama", "crime drama", "crime", "mystery", "thriller",
                    "romance", "suspense"]
        case .movie:
            // Second-to-last — "Film Documentary" would now colour
            // as Documentary (comes first), which is the intended
            // behaviour. "Movie" / "Feature Film" still hit here
            // for generic-tagged films.
            return ["movie", "film", "cine", "feature film", "short film",
                    "cortometraje"]
        }
    }
}

enum CategoryColor {

    /// Settings key for the master enable/disable toggle.
    static let enabledKey = "enableCategoryColors"

    /// The four buckets we've always shipped. These are the ones
    /// the user sees in the main Palette section of Settings →
    /// Guide Display without touching "Add more categories".
    static let defaultBuckets: [ProgramCategory] = [.sports, .movie, .kids, .news]

    /// The additional buckets exposed under "Add more categories"
    /// (per user feedback pass — many XMLTV feeds heavily tag
    /// Documentary / Drama / Comedy / etc. that the original 4
    /// buckets didn't cover). Hidden by default so the stock
    /// Palette stays compact; users who want more granularity
    /// enable them per-bucket via the sub-toggle on each row.
    static let additionalBuckets: [ProgramCategory] = [
        .documentary, .drama, .comedy, .reality,
        .educational, .scifi, .music
    ]

    /// UserDefaults key storing a per-bucket enable flag. Default
    /// when the key is missing: `true` for `defaultBuckets`,
    /// `false` for `additionalBuckets`. Users flip the additional
    /// ones on via the "Add more categories" screen.
    static func enabledKey(for category: ProgramCategory) -> String {
        "categoryBucketEnabled.\(category.rawValue)"
    }

    /// Whether a specific bucket is active for matching right now.
    /// Default 4 are on out of the box; the 7 additional buckets
    /// are off until the user explicitly enables them.
    static func isBucketEnabled(_ category: ProgramCategory) -> Bool {
        let key = enabledKey(for: category)
        if UserDefaults.standard.object(forKey: key) == nil {
            return defaultBuckets.contains(category)
        }
        return UserDefaults.standard.bool(forKey: key)
    }

    static func setBucketEnabled(_ category: ProgramCategory, _ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledKey(for: category))
    }

    // MARK: - Custom Categories
    //
    // Users can define their own `<string, hex>` mappings under
    // Settings → Guide Display → Add More Categories → Custom.
    // Custom entries are checked BEFORE the built-in bucket
    // matching (so a user can, e.g., colour "Horror" — which isn't
    // a built-in bucket — distinctly). Stored as a JSON array of
    // `{match, hex}` objects in UserDefaults so the whole list
    // can be mirrored via `SyncManager` in a single round-trip.
    struct CustomCategory: Identifiable, Codable, Equatable, Hashable {
        /// Stable UUID so edits in the Settings UI don't rebuild
        /// rows underneath the user (and to serve as `Identifiable`
        /// without colliding with `match` duplicates mid-edit).
        let id: UUID
        /// The substring the matcher looks for (case-insensitive).
        /// `"Horror"` matches any `<category>` containing "horror".
        var match: String
        /// 6-character uppercase hex, same format as built-in
        /// buckets' `defaultHex`.
        var hex: String

        init(id: UUID = UUID(), match: String, hex: String) {
            self.id = id
            self.match = match
            self.hex = hex
        }
    }

    static let customCategoriesKey = "customCategoryColors.v1"

    static func loadCustomCategories() -> [CustomCategory] {
        guard let data = UserDefaults.standard.data(forKey: customCategoriesKey),
              let decoded = try? JSONDecoder().decode([CustomCategory].self, from: data)
        else { return [] }
        return decoded
    }

    static func saveCustomCategories(_ list: [CustomCategory]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: customCategoriesKey)
        }
    }

    /// Checks the UserDefault on every call so toggling takes effect
    /// live without an app restart. Default: enabled (key missing ⇒
    /// treat as on), matching Jellyfin's out-of-the-box behaviour.
    static var isEnabled: Bool {
        if UserDefaults.standard.object(forKey: enabledKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// Clear every per-category custom colour, reverting all
    /// buckets to Jellyfin defaults. Invoked by the Settings
    /// "Reset to Defaults" button. The master enable toggle is
    /// deliberately NOT changed — if the user had disabled
    /// category colouring entirely, this just resets the palette
    /// without suddenly turning colouring back on under them.
    static func resetPaletteToDefaults() {
        for category in ProgramCategory.allCases {
            UserDefaults.standard.removeObject(forKey: category.storageKey)
        }
    }

    /// Resolves a free-form XMLTV `<category>` string into a
    /// (colour, label) pair, or `nil` if nothing matches. Matching
    /// order:
    ///   1. User-defined custom categories (if any)
    ///   2. Built-in bucket aliases, in priority: kids → sports →
    ///      news → documentary → educational → reality → music →
    ///      scifi → drama → comedy → movie.
    /// Only buckets the user has flipped on via Settings participate
    /// in step 2. Kids stays first so "Kids Sports" colours as Kids;
    /// Movie stays last so a feature film that's also tagged
    /// "Documentary" colours as Documentary (intentional — the
    /// documentary genre is almost always the more useful signal).
    static func bucket(for raw: String) -> ProgramCategory? {
        guard !raw.isEmpty else { return nil }

        let separators = CharacterSet(charactersIn: ",/;")
        let tokens = raw
            .lowercased()
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let priorityOrder: [ProgramCategory] = [
            .kids, .sports, .news,
            .documentary, .educational, .reality, .music, .scifi,
            .drama, .comedy,
            .movie
        ]

        for token in tokens {
            for bucket in priorityOrder {
                guard isBucketEnabled(bucket) else { continue }
                for alias in bucket.aliases {
                    if token.contains(alias) {
                        return bucket
                    }
                }
            }
        }
        return nil
    }

    /// Custom category match — returns the hex colour if the raw
    /// category string matches a user-defined entry. Checked BEFORE
    /// the built-in bucket matcher so a user who adds "Horror"
    /// sees horror programmes coloured even though Horror isn't a
    /// built-in bucket.
    static func customHex(for raw: String) -> String? {
        guard !raw.isEmpty else { return nil }
        let lowered = raw.lowercased()
        let custom = loadCustomCategories()
        for entry in custom {
            let needle = entry.match.lowercased().trimmingCharacters(in: .whitespaces)
            guard !needle.isEmpty else { continue }
            if lowered.contains(needle) {
                return entry.hex
            }
        }
        return nil
    }

    /// Background colour for a program cell, given its category
    /// string and state (live / focused). Returns `nil` when
    /// category colouring shouldn't apply (feature disabled, no
    /// matching bucket or custom entry, or caller wants the
    /// neutral fallback).
    ///
    /// Opacity values match the existing neutral `cellBackground`
    /// visual weights on tvOS (focused=0.55, live=0.35, default=0.22)
    /// and on iOS (live=0.45, default=0.28).
    static func backgroundColor(
        rawCategory: String,
        isLive: Bool,
        isFocused: Bool
    ) -> Color? {
        guard isEnabled else { return nil }
        // Custom entries win over built-in buckets so user overrides
        // take precedence (documented intent of the Custom section).
        let base: Color
        if let hex = customHex(for: rawCategory) {
            base = Color(hex: hex)
        } else if let bucket = bucket(for: rawCategory) {
            base = bucket.baseColor
        } else {
            return nil
        }
        #if os(tvOS)
        if isFocused { return base.opacity(0.55) }
        if isLive    { return base.opacity(0.35) }
        return base.opacity(0.22)
        #else
        if isLive { return base.opacity(0.45) }
        return base.opacity(0.28)
        #endif
    }
}
