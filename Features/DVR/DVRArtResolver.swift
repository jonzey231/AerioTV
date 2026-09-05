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

    static func kind(for rec: Recording) -> DVRContentKind {
        let category = (rec.epgCategory ?? "").lowercased()
        let title = rec.programTitle.lowercased()
        let sub = (rec.subTitle ?? "").lowercased()
        let desc = rec.programDescription.lowercased()
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
                if !a.isEmpty, !b.isEmpty { return (a, b) }
            }
        }
        return nil
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
            if a.split(separator: " ").count <= 5, !a.isEmpty, !b.isEmpty { return (a, b) }
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
        (rec.posterURL ?? "").isEmpty || (rec.backdropURL ?? "").isEmpty
            || (rec.subTitle ?? "").isEmpty || rec.seasonNumber == nil
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
            for rec in todo {
                guard !Task.isCancelled else { return }
                let hadArt = !(rec.posterURL ?? "").isEmpty
                if !hadArt, let url = await resolveOne(rec, modelContext: modelContext) {
                    rec.posterURL = url
                    resolved += 1
                } else if hadArt {
                    // Episode identity only (the art is already there).
                    _ = epgProgram(for: rec, modelContext: modelContext)
                }
                // Landscape art for the hero and cards: a portrait poster
                // crops badly in 16:9 (Suits, Aquaman; Logan 2026-09-05).
                if (rec.backdropURL ?? "").isEmpty, let b = await backdrop(for: rec) {
                    rec.backdropURL = b
                }
                if modelContext.hasChanges { try? modelContext.save() }
                version += 1
                try? await Task.sleep(for: .milliseconds(120))
            }
            debugLog("[DVR-ART] done, \(resolved) of \(todo.count) resolved")
        }
    }

    private func resolveOne(_ rec: Recording, modelContext: ModelContext) async -> String? {
        // 1. EPG programme poster + category, matched by title and air window
        //    (the recording's channelID and the feed's tvg-id differ).
        if let program = epgProgram(for: rec, modelContext: modelContext), !program.posterURL.isEmpty {
            return program.posterURL
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
        return await tmdbArt(title: rec.programTitle, isMovie: kind == .movie, size: "w780")
    }

    private func tmdbArt(title: String, isMovie: Bool, size: String) async -> String? {
        guard TMDBPosters.isEnabled, let apiKey = TMDBPosters.apiKey else { return nil }
        let entry = await TMDBService.lookupArt(title: title, isMovie: isMovie, apiKey: apiKey)
        // 16:9 cards and the hero: landscape art first.
        if let b = entry?.backdrop, !b.isEmpty { return TMDBService.imageURL(path: b, size: size)?.absoluteString }
        if let p = entry?.poster, !p.isEmpty { return TMDBService.imageURL(path: p, size: "w500")?.absoluteString }
        return nil
    }

    private func backdrop(for rec: Recording) async -> String? {
        let kind = DVRClassifier.kind(for: rec)
        guard TMDBPosters.isEnabled, let apiKey = TMDBPosters.apiKey else { return nil }
        let entry = await TMDBService.lookupArt(title: rec.programTitle, isMovie: kind == .movie, apiKey: apiKey)
        guard let b = entry?.backdrop, !b.isEmpty else { return nil }
        return TMDBService.imageURL(path: b, size: "w1280")?.absoluteString
    }

    private func epgProgram(for rec: Recording, modelContext: ModelContext) -> EPGProgram? {
        let title = rec.programTitle
        let sid = rec.serverID
        let start = rec.scheduledStart
        let end = rec.scheduledEnd
        var descriptor = FetchDescriptor<EPGProgram>(
            predicate: #Predicate<EPGProgram> { p in
                p.serverID == sid && p.title == title && p.startTime < end && p.endTime > start
            }
        )
        descriptor.fetchLimit = 1
        guard let program = try? modelContext.fetch(descriptor).first else { return nil }
        // Episode identity and category from the guide, when the row has
        // none (local and XC recordings never get them from a server).
        if (rec.epgCategory ?? "").isEmpty, !program.category.isEmpty { rec.epgCategory = program.category }
        if (rec.subTitle ?? "").isEmpty, let sub = program.subTitle, !sub.isEmpty { rec.subTitle = sub }
        if rec.seasonNumber == nil, let s = program.season { rec.seasonNumber = s }
        if rec.episodeNumber == nil, let e = program.episode { rec.episodeNumber = e }
        return program
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
