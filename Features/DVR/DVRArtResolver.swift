import SwiftUI
import SwiftData

// MARK: - Content kind

/// What a recording is, as far as the DVR tab can tell. Drives the
/// filter pills and which art source is worth asking.
enum DVRContentKind: String, CaseIterable, Identifiable {
    case movie, series, sports, news, kids, other
    var id: String { rawValue }

    var label: String {
        switch self {
        case .movie:  return "Movies"
        case .series: return "TV Shows"
        case .sports: return "Sports"
        case .news:   return "News"
        case .kids:   return "Kids"
        case .other:  return "Other"
        }
    }
}

enum DVRClassifier {
    private static let sportsWords: [String] = [
        "sport", "football", "soccer", "basketball", "baseball", "hockey", "nfl", "nba",
        "mlb", "nhl", "ncaa", "golf", "tennis", "racing", "nascar", "formula 1", "f1",
        "ufc", "mma", "boxing", "wrestling", "wwe", "olympic", "cricket", "rugby",
        "motogp", "lacrosse", "volleyball", "playoffs", "championship", "premier league",
        "la liga", "bundesliga", "serie a", "champions league"
    ]
    private static let movieWords = ["movie", "film", "cinema"]
    private static let newsWords = ["news", "newscast", "current affairs", "weather", "politics", "public affairs"]
    private static let newsTitleWords = ["news", "newshour", "nightly", "60 minutes", "dateline", "meet the press",
                                         "face the nation", "this week", "good morning america", "today show"]
    private static let kidsWords = ["kids", "children", "preschool", "family", "cartoon"]
    private static let seriesWords = [
        "series", "episode", "sitcom", "drama", "comedy", "reality", "talk", "animation",
        "documentary", "game show", "soap", "crime", "sci-fi", "science fiction", "fantasy",
        "mystery", "variety"
    ]

    /// Memoised per recording and inputs: the tab classifies every row on
    /// each render, and the newscast regex is the expensive part.
    nonisolated(unsafe) private static var memo: [String: DVRContentKind] = [:]

    static func kind(for rec: Recording) -> DVRContentKind {
        let category = (rec.epgCategory ?? "").lowercased()
        let title = rec.programTitle.lowercased()
        let sub = (rec.subTitle ?? "").lowercased()
        let desc = rec.programDescription.lowercased()
        let key = "\(rec.id)|\(category)|\(title)|\(sub)|\(desc.hashValue)|\(rec.seasonNumber ?? -1)|\(rec.episodeNumber ?? -1)"
        if let k = memo[key] { return k }
        let k = classify(category: category, title: title, sub: sub, desc: desc, rec: rec)
        if memo.count > 2000 { memo.removeAll() }
        memo[key] = k
        return k
    }

    private static func classify(category: String, title: String, sub: String, desc: String,
                                 rec: Recording) -> DVRContentKind {
        if sportsWords.contains(where: { category.contains($0) }) { return .sports }
        if newsWords.contains(where: { category.contains($0) }) { return .news }
        if kidsWords.contains(where: { category.contains($0) }) { return .kids }
        if newsTitleWords.contains(where: { title.contains($0) }) { return .news }
        // Local newscasts: "NBC 4 at 11", "News at 6:30", "Eyewitness News".
        if title.range(of: #"\bat \d{1,2}(:\d{2})?\s*(am|pm)?$"#, options: .regularExpression) != nil { return .news }
        if desc.contains("news coverage") || desc.contains("local news") || desc.contains("regional news")
            || desc.contains("headlines") || desc.hasPrefix("news") { return .news }
        // Real episode identity only: date-coded "S2026 E905" says nothing.
        if rec.displaySeasonEpisode != nil { return .series }
        if movieWords.contains(where: { category.contains($0) }) { return .movie }
        if seriesWords.contains(where: { category.contains($0) }) { return .series }
        if sportsWords.contains(where: { title.contains($0) }) { return .sports }
        if !sub.isEmpty { return .series }
        // No EPG hints: a long single airing reads as a movie, a short one
        // as an episode of something.
        let minutes = rec.scheduledEnd.timeIntervalSince(rec.scheduledStart) / 60
        if minutes >= 80 { return .movie }
        if minutes >= 15 { return .series }
        return .other
    }

    /// "Chiefs at Ravens" / "Arsenal vs Chelsea" -> (home, away) for the
    /// sports lookups. nil when no matchup can be read.
    static func teams(in text: String) -> (String, String)? {
        let separators = [" at ", " vs. ", " vs ", " v ", " @ ", " versus "]
        for sep in separators {
            if let range = text.range(of: sep, options: .caseInsensitive) {
                let a = clean(text[..<range.lowerBound])
                let b = clean(text[range.upperBound...])
                if isTeamLike(a), isTeamLike(b) { return (a, b) }
            }
        }
        return nil
    }

    /// A team or school name: one to four words, each a proper noun or a
    /// number ("Miami Hurricanes", "49ers", "Ohio State"). Talk-show blurbs
    /// also contain " at " ("SVP's up at midnight and bringing his ...",
    /// SportsCenter With Scott Van Pelt, 2026-09-05) and used to pass as a
    /// matchup, sending every studio show to TheSportsDB.
    static func isTeamLike(_ s: String) -> Bool {
        let words = s.split(separator: " ")
        guard (1...4).contains(words.count) else { return false }
        return words.allSatisfy { w in
            guard let c = w.first else { return false }
            if c.isNumber { return true }
            // "of" / "and" / "the" inside a name ("Sisters of the Poor") only
            // when they are not the first word.
            if c.isLowercase { return w != words.first && ["of", "the", "and", "de", "del", "la"].contains(w.lowercased()) }
            return c.isUppercase
        }
    }

    /// Matchup from a programme description: "The Stanford Cardinal host
    /// the Miami Hurricanes at Stanford Stadium..." and the like. Only the
    /// first sentence is read; the verb phrase splits the two sides and
    /// anything after " at " / " in " (the venue) is dropped.
    static func teamsInDescription(_ text: String) -> (String, String)? {
        guard let sentence = text.components(separatedBy: CharacterSet(charactersIn: ".!?\n")).first,
              !sentence.isEmpty else { return nil }
        let verbs = [" host the ", " hosts the ", " host ", " hosts ", " take on the ", " takes on the ",
                     " take on ", " takes on ", " face the ", " faces the ", " face ", " faces ",
                     " visit the ", " visits the ", " visit ", " visits ", " play the ", " plays the ",
                     " meet the ", " meets the ", " battle the ", " battles the ", " welcome the ",
                     " welcomes the ", " travel to the ", " travels to the ", " travel to ", " travels to "]
        for verb in verbs {
            guard let range = sentence.range(of: verb, options: .caseInsensitive) else { continue }
            let a = clean(sentence[..<range.lowerBound])
            var rest = String(sentence[range.upperBound...])
            for stop in [" at ", " in ", " for ", " on ", ",", " as ", " to "] {
                if let r = rest.range(of: stop, options: .caseInsensitive) { rest = String(rest[..<r.lowerBound]) }
            }
            let b = clean(rest[...])
            if isTeamLike(a), isTeamLike(b) { return (a, b) }
        }
        return teams(in: sentence)
    }

    private static func clean(_ s: Substring) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["The ", "the ", "No. "] where t.hasPrefix(prefix) { t = String(t.dropFirst(prefix.count)) }
        // "#5 Miami Hurricanes" / "(12) Stanford"
        t = t.replacingOccurrences(of: #"^(#|No\.\s?)?\d+\s+|^\(\d+\)\s+"#, with: "", options: .regularExpression)
        return t
    }
}

// MARK: - Art resolver

/// Fills `Recording.posterURL` for rows that have none. Order of trust:
/// the server's own art (already on the row from reconcile), the EPG
/// programme poster, then TMDB (movies, shows; needs the user's key) or
/// TheSportsDB (sports; free, no key). Anything found is written onto
/// the row so it persists; misses are remembered for the session only.
@MainActor
final class DVRArtResolver: ObservableObject {
    static let shared = DVRArtResolver()

    @Published private(set) var version = 0
    private var attempted: Set<UUID> = []
    private var task: Task<Void, Never>?

    private func needsWork(_ rec: Recording) -> Bool {
        !hasPoster(rec) || (rec.backdropURL ?? "").isEmpty
            || (rec.subTitle ?? "").isEmpty || rec.seasonNumber == nil
    }

    /// Rows resolved before 2026-09-05 hold a landscape TMDB backdrop in the
    /// poster slot (the resolver preferred it for the 16:9 cards). The phone
    /// library is a portrait grid now, so those rows get a real poster.
    private func hasPoster(_ rec: Recording) -> Bool {
        guard let url = rec.posterURL, !url.isEmpty else { return false }
        return !(url.contains("image.tmdb.org") && url.contains("/w780/"))
    }

    func resolve(_ recordings: [Recording], modelContext: ModelContext) {
        let todo = recordings.filter { rec in
            needsWork(rec) && !attempted.contains(rec.id)
                && !rec.programTitle.trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard !todo.isEmpty else { return }
        todo.forEach { attempted.insert($0.id) }
        debugLog("[DVR-ART] resolving art for \(todo.count) recording(s)")
        let previous = task
        task = Task { @MainActor in
            await previous?.value
            var resolved = 0
            var changed = false
            for rec in todo {
                guard !Task.isCancelled else { return }
                let hadArt = hasPoster(rec)
                let url = hadArt ? nil : await resolveOne(rec, modelContext: modelContext)
                if hadArt {
                    // Episode identity only (the art is already there).
                    _ = await epgProgram(for: rec, modelContext: modelContext)
                }
                // Landscape art for the hero and cards: a portrait poster
                // crops badly in 16:9 (Suits, Aquaman; Logan 2026-09-05).
                let b = (rec.backdropURL ?? "").isEmpty ? await backdrop(for: rec) : nil
                // The row may have been deleted by the 30 s reconcile while
                // the lookups ran; a write to a deleted model traps.
                guard rec.modelContext != nil, !rec.isDeleted else { continue }
                if let url { rec.posterURL = url; resolved += 1 }
                if let b { rec.backdropURL = b }
                if modelContext.hasChanges { try? modelContext.save(); changed = true }
                try? await Task.sleep(for: .milliseconds(120))
            }
            // One re-render per pass, and only when something landed: a bump
            // per recording re-rendered the tab eight times while it was
            // fading in (DVR-PERF trace 2026-09-05 15:05).
            if changed { version += 1 }
            debugLog("[DVR-ART] done, \(resolved) of \(todo.count) resolved")
        }
    }

    private func resolveOne(_ rec: Recording, modelContext: ModelContext) async -> String? {
        // 1. EPG programme poster + category, matched by title and air window
        //    (the recording's channelID and the feed's tvg-id differ).
        let program = await epgProgram(for: rec, modelContext: modelContext)
        if let program, !program.posterURL.isEmpty {
            return program.posterURL
        }
        // 1b. Dispatcharr strips artwork from the bulk grid, so the cached
        //     row has none; the per-program detail endpoint still carries the
        //     XMLTV icon (Gracenote guides put one on every program).
        if let pid = program?.programID,
           let art = await dispatcharrDetailArt(programID: pid, rec: rec, modelContext: modelContext) {
            return art
        }
        let kind = DVRClassifier.kind(for: rec)
        // 2. Sports: the event or a team from TheSportsDB when a matchup can
        //    be read. Studio shows ("The Hoop Collective") have none and fall
        //    through to TMDB like any other show (Logan 2026-09-05).
        if kind == .sports,
           let art = await TheSportsDB.artwork(title: rec.programTitle, subTitle: rec.subTitle ?? "",
                                               description: rec.programDescription) {
            return art
        }
        // 3. TMDB, when the user has a key: movies as movies, everything
        //    else as a TV title (news and sports programmes are listed too).
        if let art = await tmdbArt(title: rec.programTitle, isMovie: kind == .movie) { return art }
        // 4. The loaded Movies / TV Shows library: many recordings are shows
        //    the provider also carries on demand (Logan 2026-09-05). Library
        //    art is TMDB-first itself when a key is set, provider poster
        //    otherwise.
        return libraryPoster(title: rec.programTitle, isMovie: kind == .movie)
    }

    private func libraryPoster(title: String, isMovie: Bool) -> String? {
        let wanted = LibraryMatcher.cleanTitle(title).lowercased()
        guard !wanted.isEmpty else { return nil }
        let store = VODStore.shared
        let primary = isMovie ? store.movies : store.series
        let secondary = isMovie ? store.series : store.movies
        for pool in [primary, secondary] {
            guard let item = pool.first(where: { LibraryMatcher.cleanTitle($0.name).lowercased() == wanted }) else { continue }
            if let url = TMDBArtCache.shared.posterURL(for: item) ?? item.posterURL {
                debugLog("[DVR-ART] library poster for \(title): \(item.displayName)")
                return url.absoluteString
            }
        }
        return nil
    }

    private var dispatcharrAPIs: [String: DispatcharrAPI] = [:]

    private func dispatcharrAPI(for rec: Recording, modelContext: ModelContext) -> (DispatcharrAPI, String)? {
        guard let uuid = UUID(uuidString: rec.serverID) else { return nil }
        let servers = (try? modelContext.fetch(FetchDescriptor<ServerConnection>())) ?? []
        guard let server = servers.first(where: { $0.id == uuid }), server.type == .dispatcharrAPI else { return nil }
        let base = server.effectiveBaseURL
        guard !base.isEmpty, !server.effectiveApiKey.isEmpty else { return nil }
        if let api = dispatcharrAPIs[rec.serverID] { return (api, base) }
        let api = DispatcharrAPI(baseURL: base,
                                 auth: .apiKey(server.effectiveApiKey),
                                 userAgent: server.effectiveUserAgent,
                                 authMode: server.dispatcharrHeaderMode,
                                 serverID: server.id,
                                 savedUsername: server.dispatcharrCredentialType == .usernamePassword
                                     ? server.username : nil)
        dispatcharrAPIs[rec.serverID] = api
        return (api, base)
    }

    /// Poster from `/api/epg/programs/{id}/`. Gracenote (TMS) icons come as
    /// 4:3 `_h9_` assets; the same asset id serves a 2:3 `_v8_` (960x1440),
    /// which fills the phone poster grid. The landscape original goes to
    /// the backdrop slot when it is still empty.
    private func dispatcharrDetailArt(programID: Int, rec: Recording, modelContext: ModelContext) async -> String? {
        guard let (api, base) = dispatcharrAPI(for: rec, modelContext: modelContext) else { return nil }
        guard let detail = try? await api.getProgramDetail(id: programID),
              let raw = detail.bestPosterString,
              let url = VODService.resolveImageURL(raw, base: base, size: "w500") else { return nil }
        let landscape = url.absoluteString
        var poster = landscape
        if let portrait = await Self.tmsPortraitVariant(of: url) {
            poster = portrait
            if (rec.backdropURL ?? "").isEmpty, rec.modelContext != nil, !rec.isDeleted { rec.backdropURL = landscape }
        }
        debugLog("[DVR-ART] Dispatcharr program \(programID) art for \(rec.programTitle): \(poster)")
        return poster
    }

    /// `.../p123_b_h9_ag.jpg` -> `.../p123_b_v8_ag.jpg` when the CDN has it
    /// (one HEAD; falls back to the 480x720 `_v7_`). Only for tmsimg hosts.
    nonisolated private static func tmsPortraitVariant(of url: URL) async -> String? {
        guard let host = url.host?.lowercased(), host.hasSuffix("tmsimg.com") else { return nil }
        let s = url.absoluteString
        guard let r = s.range(of: #"_h\d+_"#, options: .regularExpression) else { return nil }
        for code in ["_v8_", "_v7_"] {
            let candidate = s.replacingCharacters(in: r, with: code)
            guard let u = URL(string: candidate) else { continue }
            var req = URLRequest(url: u, timeoutInterval: 8)
            req.httpMethod = "HEAD"
            if let (_, resp) = try? await URLSession.shared.data(for: req),
               (resp as? HTTPURLResponse)?.statusCode == 200 {
                return candidate
            }
        }
        return nil
    }

    /// One TMDB search per title and kind for the session: the poster and
    /// the backdrop steps both ask for the same entry.
    private var tmdbEntries: [String: TMDBArtCache.Entry?] = [:]

    private func tmdbEntry(title: String, isMovie: Bool) async -> TMDBArtCache.Entry? {
        guard TMDBPosters.isEnabled, let apiKey = TMDBPosters.apiKey else { return nil }
        let key = "\(isMovie ? "m" : "t"):\(LibraryMatcher.cleanTitle(title))"
        if let cached = tmdbEntries[key] { return cached }
        let entry = await TMDBService.lookupArt(title: title, isMovie: isMovie, apiKey: apiKey)
        if entry != nil { tmdbEntries[key] = entry }   // a failed call retries next pass
        return entry
    }

    /// The poster slot holds portrait art (the phone library grid); the
    /// 16:9 cards and the hero read `backdropURL` first and fall back here.
    private func tmdbArt(title: String, isMovie: Bool) async -> String? {
        let entry = await tmdbEntry(title: title, isMovie: isMovie)
        if let p = entry?.poster, !p.isEmpty { return TMDBService.imageURL(path: p, size: "w500")?.absoluteString }
        if let b = entry?.backdrop, !b.isEmpty { return TMDBService.imageURL(path: b, size: "w1280")?.absoluteString }
        return nil
    }

    private func backdrop(for rec: Recording) async -> String? {
        let kind = DVRClassifier.kind(for: rec)
        let entry = await tmdbEntry(title: rec.programTitle, isMovie: kind == .movie)
        guard let b = entry?.backdrop, !b.isEmpty else { return nil }
        return TMDBService.imageURL(path: b, size: "w1280")?.absoluteString
    }

    /// Plain values from the matching EPG programme, fetched on a background
    /// context: the programme table is hundreds of thousands of rows and the
    /// fetch ran on the main actor per recording (the DVR tab switch lagged,
    /// Logan 2026-09-05).
    private struct EPGMatch: Sendable {
        let posterURL: String
        let programID: Int?
        let category: String
        let subTitle: String?
        let season: Int?
        let episode: Int?
    }

    private func epgProgram(for rec: Recording, modelContext: ModelContext) async -> EPGMatch? {
        let title = rec.programTitle
        let sid = rec.serverID
        let start = rec.scheduledStart
        let end = rec.scheduledEnd
        let container = modelContext.container
        let match: EPGMatch? = await Task.detached(priority: .utility) {
            let ctx = ModelContext(container)
            var descriptor = FetchDescriptor<EPGProgram>(
                predicate: #Predicate<EPGProgram> { p in
                    p.serverID == sid && p.title == title && p.startTime < end && p.endTime > start
                }
            )
            descriptor.fetchLimit = 1
            guard let p = try? ctx.fetch(descriptor).first else { return nil }
            return EPGMatch(posterURL: p.posterURL, programID: p.programID, category: p.category,
                            subTitle: p.subTitle, season: p.season, episode: p.episode)
        }.value
        guard let match else { return nil }
        // Episode identity and category from the guide, when the row has
        // none (local and XC recordings never get them from a server).
        if (rec.epgCategory ?? "").isEmpty, !match.category.isEmpty { rec.epgCategory = match.category }
        if (rec.subTitle ?? "").isEmpty, let sub = match.subTitle, !sub.isEmpty { rec.subTitle = sub }
        if rec.seasonNumber == nil, let s = match.season { rec.seasonNumber = s }
        if rec.episodeNumber == nil, let e = match.episode { rec.episodeNumber = e }
        return match
    }
}

// MARK: - TheSportsDB

/// Free event / team art for sports recordings. No key needed for the
/// public v1 endpoint; we only read images.
enum TheSportsDB {
    private static let base = "https://www.thesportsdb.com/api/v1/json/123"

    static func artwork(title: String, subTitle: String, description: String = "") async -> String? {
        // The matchup usually lives in the episode name ("Chiefs at Ravens");
        // some feeds put it in the title ("NFL Football: Chiefs at Ravens"),
        // and generic titles ("College Football") only name the teams in the
        // description (Logan 2026-09-05).
        var matchups: [(String, String)] = []
        for text in [subTitle, title, title.components(separatedBy: ":").last ?? ""] {
            if let m = DVRClassifier.teams(in: text) { matchups.append(m) }
        }
        if let m = DVRClassifier.teamsInDescription(description) { matchups.append(m) }
        for (a, b) in matchups {
            debugLog("[DVR-ART] sports matchup \(a) vs \(b)")
            if let art = await eventArt(home: a, away: b) { return art }
            if let art = await teamArt(name: a) { return art }
            if let art = await teamArt(name: b) { return art }
        }
        return nil
    }

    private static func eventArt(home: String, away: String) async -> String? {
        let query = "\(home)_vs_\(away)".replacingOccurrences(of: " ", with: "_")
        guard let json = await get("/searchevents.php", query: [URLQueryItem(name: "e", value: query)]),
              let events = json["event"] as? [[String: Any]] else { return nil }
        for e in events {
            for key in ["strThumb", "strPoster", "strFanart", "strBanner"] {
                if let s = e[key] as? String, !s.isEmpty { return s }
            }
        }
        return nil
    }

    private static func teamArt(name: String) async -> String? {
        guard let json = await get("/searchteams.php", query: [URLQueryItem(name: "t", value: name)]),
              let teams = json["teams"] as? [[String: Any]], let t = teams.first else { return nil }
        for key in ["strFanart1", "strTeamFanart1", "strStadiumThumb", "strTeamBadge", "strBadge"] {
            if let s = t[key] as? String, !s.isEmpty { return s }
        }
        return nil
    }

    private static func get(_ path: String, query: [URLQueryItem]) async -> [String: Any]? {
        guard var comps = URLComponents(string: base + path) else { return nil }
        comps.queryItems = query
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
