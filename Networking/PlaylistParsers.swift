import Foundation
import Compression

// MARK: - M3U Parsed Channel
struct M3UChannel: Identifiable {
    var id = UUID()
    var name: String
    var url: String
    var groupTitle: String
    var tvgID: String
    var tvgName: String
    var tvgLogo: String
    /// `tvg-chno` from the playlist, preserved verbatim (trimmed of
    /// whitespace). v1.7.x: stored as `String?` (was `Int?`) so ATSC
    /// over-the-air `major.minor` numbers like "2.1" / "5.1" survive
    /// parsing. The previous `Int(rawString)` coercion silently
    /// returned `nil` for any decimal-valued `tvg-chno`, which made
    /// the channel-list builder fall through to a 1-based-index
    /// fallback (a channel with `tvg-chno="2.1"` sitting in slot 2
    /// would display as "2", slot 3 as "3", and so on). Field
    /// report from "the Moterator" (Discord 2026-05-11) confirmed
    /// the symptom on broadcast lineups.
    var channelNumber: String?
    var rawAttributes: [String: String]
}

// MARK: - M3U Parser
struct M3UParser {

    /// Deterministic, reload-stable channel id for an M3U entry,
    /// derived from the stream URL.
    ///
    /// v1.7.3: M3U channels previously took `ChannelDisplayItem.id`
    /// from `M3UChannel.id`, a fresh `UUID()` regenerated on every
    /// parse. Anything keyed by that id (favorites, now-playing
    /// restore, multiview tile identity) therefore reset on each
    /// playlist refresh. The stream URL is the stable per-channel
    /// attribute, so we key off it instead.
    ///
    /// The URL is HASHED, not embedded: this id is persisted to
    /// UserDefaults, mirrored to iCloud KVS, and written to the Top
    /// Shelf keychain, and some M3U URLs carry credentials in the
    /// path (the same reason we never log `streamURLs`). FNV-1a is
    /// used rather than Swift's `Hasher`, whose seed is randomized
    /// per launch and would not be stable across launches/devices.
    static func stableChannelID(forStreamURL url: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in url.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return "m3u_" + String(hash, radix: 16)
    }

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
                    // v1.7.x: preserve the raw `tvg-chno` string so
                    // decimal channel numbers survive. See
                    // `M3UChannel.channelNumber` doc comment.
                    let chno: String? = {
                        guard let raw = attrs["tvg-chno"] else { return nil }
                        let trimmed = raw.trimmingCharacters(in: .whitespaces)
                        return trimmed.isEmpty ? nil : trimmed
                    }()
                    let channel = M3UChannel(
                        name: attrs["name"] ?? "Unknown Channel",
                        url: urlLine,
                        groupTitle: attrs["group-title"] ?? "",
                        tvgID: attrs["tvg-id"] ?? "",
                        tvgName: attrs["tvg-name"] ?? "",
                        tvgLogo: attrs["tvg-logo"] ?? "",
                        channelNumber: chno,
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

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        return URLSession(configuration: config)
    }()

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

    /// v1.7.3: filter-during-parse channel allowlist. When non-nil,
    /// any `<programme>` whose `channel=` attribute (lowercased) is
    /// NOT in this set is skipped entirely: its title / desc /
    /// category text is never accumulated and no `ParsedEPGProgram`
    /// is appended. This keeps the working set tiny when parsing a
    /// huge XMLTV source (a 10k-channel Gracenote feed) against a
    /// user with only ~300 channels, only the ~3% of programmes
    /// that match a known channel survive. `nil` keeps everything
    /// (back-compat for small-file callers).
    private var knownChannelIDs: Set<String>?
    /// True while parsing a `<programme>` whose channel isn't in
    /// `knownChannelIDs`. Suppresses text accumulation + the final
    /// append so a skipped programme costs almost nothing.
    private var skippingProgramme = false

    // MARK: - Public entry points
    static func parse(data: Data) -> [ParsedEPGProgram] {
        let instance = XMLTVParser()
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = instance
        xmlParser.parse()
        return instance.programmes
    }

    /// Parse an XMLTV document straight off an `InputStream` (used by
    /// the gzip path so the decompressed bytes are pulled
    /// incrementally rather than held whole in memory). `knownChannelIDs`,
    /// when supplied, filters programmes during parse so only the
    /// channels the user actually has survive (see the parser's
    /// `knownChannelIDs` property).
    static func parse(stream: InputStream, knownChannelIDs: Set<String>?) -> [ParsedEPGProgram] {
        let instance = XMLTVParser()
        instance.knownChannelIDs = knownChannelIDs
        let xmlParser = XMLParser(stream: stream)
        xmlParser.delegate = instance
        xmlParser.parse()
        return instance.programmes
    }

    /// Fetches and parses an XMLTV document.
    ///
    /// `headers` lets callers attach auth that the XMLTV endpoint
    /// requires. Dispatcharr's `/output/epg` returns HTTP 403 on
    /// locked-down deployments (e.g. Freyguy1975's Synology setup,
    /// v1.6.22) when called without an X-API-Key + Authorization
    /// pair, even though the same key works for `/api/epg/grid/`.
    /// Passing `DispatcharrAPI.streamAuthHeaders` here closes the
    /// gap. Empty dict for M3U / public XMLTV URLs preserves the
    /// previous behaviour.
    ///
    /// v1.7.3: transparently handles gzip-compressed XMLTV
    /// (`.xml.gz`). Detection is by URL extension, response
    /// `Content-Type` (`application/x-gzip` / `application/gzip`),
    /// or the `1f 8b` magic bytes. When `knownChannelIDs` is
    /// supplied, the gzip path filters programmes during parse so a
    /// huge multi-thousand-channel feed boils down to just the
    /// user's channels (FadiFC's request: a 552 MB-uncompressed
    /// Gracenote feed parsed against ~300 channels yields only the
    /// ~3% that match). Uncompressed XMLTV ignores `knownChannelIDs`
    /// and keeps the existing whole-document parse for back-compat.
    static func fetchAndParse(
        url: URL,
        headers: [String: String] = [:],
        knownChannelIDs: Set<String>? = nil
    ) async throws -> [ParsedEPGProgram] {
        var request = URLRequest(url: url)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }

        // Gzip is detectable from the URL extension before we even
        // hit the network; combined with the response content-type
        // and the magic-byte sniff below, all three RFC-1952
        // signal paths are covered.
        let extLooksGzipped = url.pathExtension.lowercased() == "gz"

        // Use a download task so the (possibly hundreds of MB)
        // compressed body lands on disk, not in a `Data` in RAM.
        let (tempURL, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw APIError.serverError(http.statusCode)
        }

        let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased()
        let ctLooksGzipped = contentType.map {
            $0.contains("gzip") || $0.contains("x-gzip")
        } ?? false
        let magicLooksGzipped = fileStartsWithGzipMagic(tempURL)

        guard extLooksGzipped || ctLooksGzipped || magicLooksGzipped else {
            // Plain XMLTV. Preserve the existing whole-document parse.
            // (knownChannelIDs filtering is a gzip-path optimization;
            // uncompressed feeds are small enough to parse whole.)
            let data = try Data(contentsOf: tempURL)
            return parse(data: data)
        }

        // Gzip path. Stream-decompress the temp file to a second
        // temp file (bounded memory, ~64 KB working set), then parse
        // the decompressed XML off an InputStream with optional
        // channel filtering. The decompressed file is transient and
        // deleted on return.
        let decompressedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("aerio-xmltv-\(UUID().uuidString).xml")
        defer { try? FileManager.default.removeItem(at: decompressedURL) }
        try streamDecompressGzip(from: tempURL, to: decompressedURL)
        guard let stream = InputStream(url: decompressedURL) else {
            throw APIError.invalidResponse
        }
        return parse(stream: stream, knownChannelIDs: knownChannelIDs)
    }

    // MARK: - Gzip streaming decompression (v1.7.3)

    /// Cheap magic-byte sniff: reads the first 2 bytes of a file and
    /// checks for the gzip signature `1f 8b`. Final detection
    /// fallback when the URL extension and Content-Type are
    /// inconclusive (some servers send `application/octet-stream`).
    private static func fileStartsWithGzipMagic(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 2), head.count == 2 else { return false }
        return head[head.startIndex] == 0x1f && head[head.startIndex + 1] == 0x8b
    }

    /// Streams a gzip file through Apple's `Compression` framework
    /// and writes the decompressed bytes to `destURL`. Bounded
    /// memory: reads + writes in 64 KB chunks, never materializing
    /// the (potentially multi-GB) decompressed payload in RAM.
    ///
    /// gzip = RFC 1952 header + raw DEFLATE (RFC 1951) + 8-byte
    /// trailer. `Compression`'s `.zlib` algorithm decodes raw
    /// DEFLATE, so we skip the variable-length gzip header up front
    /// and feed the remaining DEFLATE stream to an `InputFilter`.
    /// The trailer (CRC32 + ISIZE) is harmless trailing data the
    /// filter stops reading at the DEFLATE end-of-stream marker.
    private static func streamDecompressGzip(from sourceURL: URL, to destURL: URL) throws {
        guard let input = InputStream(url: sourceURL) else {
            throw APIError.invalidResponse
        }
        input.open()
        defer { input.close() }

        try skipGzipHeader(input)

        FileManager.default.createFile(atPath: destURL.path, contents: nil)
        guard let output = OutputStream(url: destURL, append: false) else {
            throw APIError.invalidResponse
        }
        output.open()
        defer { output.close() }

        let bufferSize = 64 * 1024
        // InputFilter pulls compressed DEFLATE bytes from `input`
        // (now positioned past the gzip header) on demand and yields
        // decompressed bytes via `readData(ofLength:)`.
        let filter = try InputFilter(.decompress, using: .zlib, bufferCapacity: bufferSize) { (count: Int) -> Data? in
            var buf = [UInt8](repeating: 0, count: count)
            let n = input.read(&buf, maxLength: count)
            if n <= 0 { return nil }
            return Data(buf[0..<n])
        }
        while let chunk = try filter.readData(ofLength: bufferSize), !chunk.isEmpty {
            var bytes = [UInt8](chunk)
            var offset = 0
            while offset < bytes.count {
                let written = output.write(&bytes[offset], maxLength: bytes.count - offset)
                if written <= 0 {
                    throw APIError.invalidResponse
                }
                offset += written
            }
        }
    }

    /// Advances `input` past the gzip header per RFC 1952 so the
    /// stream is positioned at the start of the DEFLATE payload.
    /// Handles the optional FEXTRA / FNAME / FCOMMENT / FHCRC fields
    /// the FLG byte may enable. Reads sequentially (InputStream has
    /// no seek), which is fine since the header is tiny.
    private static func skipGzipHeader(_ input: InputStream) throws {
        func readByte() throws -> UInt8 {
            var b: UInt8 = 0
            let n = input.read(&b, maxLength: 1)
            guard n == 1 else { throw APIError.invalidResponse }
            return b
        }
        let id1 = try readByte()
        let id2 = try readByte()
        guard id1 == 0x1f, id2 == 0x8b else {
            throw APIError.invalidResponse   // not gzip after all
        }
        _ = try readByte()             // CM (compression method)
        let flg = try readByte()       // FLG
        for _ in 0..<6 { _ = try readByte() }   // MTIME(4) + XFL(1) + OS(1)

        // FEXTRA
        if flg & 0x04 != 0 {
            let xlen0 = Int(try readByte())
            let xlen1 = Int(try readByte())
            let xlen = xlen0 | (xlen1 << 8)
            for _ in 0..<xlen { _ = try readByte() }
        }
        // FNAME (zero-terminated)
        if flg & 0x08 != 0 {
            while try readByte() != 0 {}
        }
        // FCOMMENT (zero-terminated)
        if flg & 0x10 != 0 {
            while try readByte() != 0 {}
        }
        // FHCRC
        if flg & 0x02 != 0 {
            _ = try readByte()
            _ = try readByte()
        }
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
            // v1.7.3: decide up-front whether this programme survives
            // the channel filter. The `channel=` attribute is present
            // at start, so we can short-circuit before accumulating
            // any text.
            if let known = knownChannelIDs {
                skippingProgramme = !known.contains(currentChannelID.lowercased())
            } else {
                skippingProgramme = false
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard insideProgramme, !skippingProgramme else { return }
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
        if insideProgramme && !skippingProgramme {
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
            // v1.7.3: a filtered-out programme resets state and bails
            // without appending. Reset the flag here so the next
            // programme re-evaluates against the allowlist.
            if skippingProgramme {
                skippingProgramme = false
                return
            }
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
