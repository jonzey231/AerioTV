import Foundation

// MARK: - M3U Parsed Channel
struct M3UChannel: Identifiable {
    var id = UUID()
    var name: String
    var url: String
    var groupTitle: String
    var tvgID: String
    var tvgName: String
    var tvgLogo: String
    var channelNumber: Int?
    var rawAttributes: [String: String]
}

// MARK: - M3U Parser
struct M3UParser {

    static func parse(content: String) -> [M3UChannel] {
        var channels: [M3UChannel] = []
        let lines = content.components(separatedBy: .newlines)
        var i = 0

        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("#EXTINF:") {
                let attrs = parseExtINF(line)
                var urlLine = ""
                var j = i + 1
                while j < lines.count {
                    let candidate = lines[j].trimmingCharacters(in: .whitespaces)
                    if !candidate.isEmpty && !candidate.hasPrefix("#") {
                        urlLine = candidate
                        i = j
                        break
                    }
                    j += 1
                }

                if !urlLine.isEmpty {
                    let channel = M3UChannel(
                        name: attrs["name"] ?? "Unknown Channel",
                        url: urlLine,
                        groupTitle: attrs["group-title"] ?? "",
                        tvgID: attrs["tvg-id"] ?? "",
                        tvgName: attrs["tvg-name"] ?? "",
                        tvgLogo: attrs["tvg-logo"] ?? "",
                        channelNumber: attrs["tvg-chno"].flatMap { Int($0) },
                        rawAttributes: attrs
                    )
                    channels.append(channel)
                }
            }
            i += 1
        }
        return channels
    }

    // Compiled once — reused for every #EXTINF line (thousands of times for large playlists).
    private static let attrRegex = try! NSRegularExpression(pattern: #"([\w-]+)="([^"]*)""#)

    static func parseExtINF(_ line: String) -> [String: String] {
        var result: [String: String] = [:]

        if let commaIndex = line.lastIndex(of: ",") {
            let name = String(line[line.index(after: commaIndex)...])
                .trimmingCharacters(in: .whitespaces)
            result["name"] = name
        }

        let nsLine = line as NSString
        let matches = attrRegex.matches(in: line, range: NSRange(line.startIndex..., in: line))
        for match in matches {
            if match.numberOfRanges == 3 {
                let key = nsLine.substring(with: match.range(at: 1)).lowercased()
                let value = nsLine.substring(with: match.range(at: 2))
                result[key] = value
            }
        }
        return result
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    static func fetchAndParse(url: URL) async throws -> [M3UChannel] {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw APIError.invalidResponse
        }
        guard let content = String(data: data, encoding: .utf8) ??
                            String(data: data, encoding: .isoLatin1) else {
            throw APIError.decodingError(
                NSError(domain: "M3U", code: 0,
                        userInfo: [NSLocalizedDescriptionKey: "Could not decode playlist"])
            )
        }
        return parse(content: content)
    }
}

// MARK: - Parsed EPG Program
struct ParsedEPGProgram {
    let channelID: String
    let title: String
    let description: String
    let startTime: Date
    let endTime: Date
    let category: String
}

// MARK: - XMLTV Parser (class required for NSObject/XMLParserDelegate)
final class XMLTVParser: NSObject, XMLParserDelegate {

    private var programmes: [ParsedEPGProgram] = []
    private var currentChannelID = ""
    private var currentTitle = ""
    private var currentDesc = ""
    /// Accumulated as a list instead of a single string because real
    /// XMLTV feeds (Schedules Direct, Zap2it via Dispatcharr) emit
    /// one `<category>` element per tag — e.g. `<category>Episode
    /// </category><category>Series</category><category>Reality
    /// </category><category>Law</category>` — and the previous
    /// `currentCategory += trimmed` form concatenated all four into
    /// the single string `"EpisodeSeriesRealityLaw"`. That surfaced
    /// in the Program Info modal as one absurd merged pill. Joining
    /// with a comma at programme-close time lets the pill renderer
    /// (which already splits on `,/;`) produce one pill per tag.
    private var currentCategories: [String] = []
    private var currentStart = ""
    private var currentStop = ""
    private var currentElement = ""
    /// Text accumulator for the currently-open text-bearing element
    /// (`<title>`, `<desc>`, or `<category>`). Reset by
    /// `didStartElement` and consumed by `didEndElement`. The old
    /// parser trimmed each `foundCharacters` fragment before
    /// appending, which silently dropped word-internal boundaries
    /// when `Foundation.XMLParser` chose to yield text in multiple
    /// chunks — e.g. `<title>Hello World</title>` could surface as
    /// `"HelloWorld"` if the parser split on the space. Codex C1
    /// flagged this; accumulating raw text and trimming once at
    /// close time fixes it.
    private var currentText = ""
    private var insideProgramme = false

    // MARK: - Public entry points
    static func parse(data: Data) -> [ParsedEPGProgram] {
        let instance = XMLTVParser()
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = instance
        xmlParser.parse()
        return instance.programmes
    }

    static func fetchAndParse(url: URL) async throws -> [ParsedEPGProgram] {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: config)
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw APIError.invalidResponse
        }
        return parse(data: data)
    }

    // MARK: - XMLParserDelegate
    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        // Reset the per-element text accumulator on every new
        // element so the previous element's trailing content /
        // inter-element whitespace doesn't leak in. This is
        // independent of `insideProgramme` — we want `currentText`
        // clean even for structural elements like `<tv>` that
        // don't have consumed text.
        currentText = ""
        if elementName == "programme" {
            insideProgramme   = true
            currentChannelID  = attributeDict["channel"] ?? ""
            currentStart      = attributeDict["start"] ?? ""
            currentStop       = attributeDict["stop"] ?? ""
            currentTitle      = ""
            currentDesc       = ""
            currentCategories = []
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard insideProgramme else { return }
        // Accumulate the raw fragment. Trimming happens once in
        // `didEndElement` so multi-chunk text (e.g. "Hello " +
        // "World" from a single `<title>Hello World</title>`) stays
        // intact. See `currentText` doc for the bug this fixes.
        currentText += string
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        if insideProgramme {
            let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            switch elementName {
            case "title":
                // First non-empty `<title>` wins — XMLTV in the wild
                // sometimes emits a second localised title element
                // per programme; the first is the canonical one.
                if currentTitle.isEmpty && !trimmed.isEmpty {
                    currentTitle = trimmed
                }
            case "desc":
                // Same "first wins" policy as title — localised
                // `<desc lang="...">` duplicates would otherwise
                // collide.
                if currentDesc.isEmpty && !trimmed.isEmpty {
                    currentDesc = trimmed
                }
            case "category":
                // Each `<category>` is a separate entry. Empty
                // elements (rare but seen) are skipped so the
                // joined output doesn't get `",,"` noise the pill
                // splitter would have to clean up.
                if !trimmed.isEmpty {
                    currentCategories.append(trimmed)
                }
            default: break
            }
        }
        if elementName == "programme" {
            insideProgramme = false
            if let start = parseXMLTVDate(currentStart),
               let stop  = parseXMLTVDate(currentStop),
               !currentTitle.isEmpty {
                programmes.append(ParsedEPGProgram(
                    channelID:   currentChannelID,
                    title:       currentTitle,
                    description: currentDesc,
                    startTime:   start,
                    endTime:     stop,
                    category:    currentCategories.joined(separator: ",")
                ))
            }
        }
    }

    private static let xmltvFmtTZ: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMddHHmmss Z"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    private static let xmltvFmtUTC: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMddHHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(abbreviation: "UTC")
        return f
    }()

    private func parseXMLTVDate(_ str: String) -> Date? {
        let s = str.trimmingCharacters(in: .whitespaces)
        if let d = Self.xmltvFmtTZ.date(from: s) { return d }
        return Self.xmltvFmtUTC.date(from: s)
    }
}
