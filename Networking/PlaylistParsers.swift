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

    static func parseExtINF(_ line: String) -> [String: String] {
        var result: [String: String] = [:]

        if let commaIndex = line.lastIndex(of: ",") {
            let name = String(line[line.index(after: commaIndex)...])
                .trimmingCharacters(in: .whitespaces)
            result["name"] = name
        }

        let attrPattern = #"([\w-]+)="([^"]*)""#
        if let regex = try? NSRegularExpression(pattern: attrPattern) {
            let nsLine = line as NSString
            let matches = regex.matches(in: line, range: NSRange(line.startIndex..., in: line))
            for match in matches {
                if match.numberOfRanges == 3 {
                    let key = nsLine.substring(with: match.range(at: 1)).lowercased()
                    let value = nsLine.substring(with: match.range(at: 2))
                    result[key] = value
                }
            }
        }
        return result
    }

    static func fetchAndParse(url: URL) async throws -> [M3UChannel] {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: config)
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
    private var currentCategory = ""
    private var currentStart = ""
    private var currentStop = ""
    private var currentElement = ""
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
        if elementName == "programme" {
            insideProgramme  = true
            currentChannelID = attributeDict["channel"] ?? ""
            currentStart     = attributeDict["start"] ?? ""
            currentStop      = attributeDict["stop"] ?? ""
            currentTitle     = ""
            currentDesc      = ""
            currentCategory  = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard insideProgramme else { return }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch currentElement {
        case "title":    currentTitle    += trimmed
        case "desc":     currentDesc     += trimmed
        case "category": currentCategory += trimmed
        default: break
        }
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
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
                    category:    currentCategory
                ))
            }
        }
    }

    private func parseXMLTVDate(_ str: String) -> Date? {
        let s = str.trimmingCharacters(in: .whitespaces)
        let f1 = DateFormatter()
        f1.dateFormat = "yyyyMMddHHmmss Z"
        if let d = f1.date(from: s) { return d }
        let f2 = DateFormatter()
        f2.dateFormat = "yyyyMMddHHmmss"
        f2.timeZone = TimeZone(abbreviation: "UTC")
        return f2.date(from: s)
    }
}
