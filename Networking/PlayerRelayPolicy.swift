//
//  PlayerRelayPolicy.swift
//  Aerio
//
//  Pure logic for the player relay (App/PlayerRelay.swift).
//
//  Measured 2026-11-13 (iOS 27 and tvOS 27 simulators, loopback stand-in):
//  AVPlayer sends its AVURLAsset header fields with every request it makes
//  for an asset, to every host: a segment a playlist names on another host,
//  a segment that 302s elsewhere, an fMP4 init, an AES key, and every range
//  of a progressive MP4 after a 302. FFmpeg (mpv) does the same with its
//  http-header-fields. So a player is never handed a playlist's sign-in.
//  Where a request needs the key (a recording's playlist and every one of
//  its segments, a VOD session that must stay the user's for limits and
//  stats), the player opens a 127.0.0.1 URL with no headers and the relay
//  fetches upstream with the app's redirect rule (RedirectAuthPolicy). The
//  relay rewrites every playlist it serves so each URI the playlist names
//  comes back to the relay, and this file decides, for each such URI, where
//  it is fetched from and whether the sign-in goes with it.
//
//  Pure Foundation with no app singletons, so Scripts/player-relay-tests
//  compiles it with RedirectAuthPolicy.swift and tests it on its own.
//

import Foundation

/// Rewrites an HLS playlist so every URI it names is fetched through the relay.
enum HLSRelayPlaylist {
    /// What a URI names, from the tag that carries it. The relay serves
    /// every kind the same way (it buffers and rewrites whatever answers
    /// with a playlist, and streams the rest); the kind is for its log and
    /// for the LL-HLS directives a player adds to playlist URLs.
    enum Kind: String, Sendable {
        case playlist, segment, key, map, data, other
    }

    /// True when `data` starts like an HLS playlist: an optional UTF-8 BOM
    /// and white space, then #EXTM3U.
    static func looksLikePlaylist(_ data: Data) -> Bool {
        var bytes = [UInt8](data.prefix(64))
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { bytes.removeFirst(3) }
        while let first = bytes.first, first == 0x20 || first == 0x09 || first == 0x0D || first == 0x0A {
            bytes.removeFirst()
        }
        return bytes.starts(with: Array("#EXTM3U".utf8))
    }

    /// Splits an attribute list on the commas outside quoted strings
    /// (RFC 8216 4.2: a quoted-string may hold commas).
    static func splitAttributes(_ list: Substring) -> [Substring] {
        var out: [Substring] = []
        var start = list.startIndex
        var inQuotes = false
        var i = list.startIndex
        while i < list.endIndex {
            let c = list[i]
            if c == "\"" {
                inQuotes.toggle()
            } else if c == ",", !inQuotes {
                out.append(list[start..<i])
                start = list.index(after: i)
            }
            i = list.index(after: i)
        }
        out.append(list[start..<list.endIndex])
        return out
    }

    /// Attributes whose quoted value is a URI the player would fetch: URI
    /// itself (KEY, MAP, MEDIA, I-FRAME-STREAM-INF, PART, PRELOAD-HINT,
    /// RENDITION-REPORT, SESSION-DATA, SESSION-KEY), any *-URI (DATERANGE's
    /// X-ASSET-URI, client attributes), and an interstitial's X-ASSET-LIST.
    static func isURIAttribute(_ name: String) -> Bool {
        let n = name.uppercased()
        return n == "URI" || n.hasSuffix("-URI") || n == "X-ASSET-LIST"
    }

    static func kind(forTag tag: String, attribute: String, attributes: [Substring]) -> Kind {
        switch tag.uppercased() {
        case "#EXT-X-I-FRAME-STREAM-INF", "#EXT-X-MEDIA", "#EXT-X-RENDITION-REPORT":
            return .playlist
        case "#EXT-X-KEY", "#EXT-X-SESSION-KEY":
            return .key
        case "#EXT-X-MAP":
            return .map
        case "#EXT-X-PART":
            return .segment
        case "#EXT-X-PRELOAD-HINT":
            let isMap = attributes.contains {
                $0.trimmingCharacters(in: .whitespaces).uppercased() == "TYPE=MAP"
            }
            return isMap ? .map : .segment
        case "#EXT-X-SESSION-DATA":
            return .data
        case "#EXT-X-DATERANGE":
            return attribute.uppercased() == "X-ASSET-LIST" ? .data : .playlist
        default:
            return .other
        }
    }

    /// `ref` resolved against `base` (the URL the playlist was finally
    /// fetched from, after redirects: RFC 8216 4.1 resolves relative URIs
    /// against the playlist's own URI, which is the redirected one). A
    /// reference with characters URL(string:) refuses (a space) is tried
    /// percent-encoded once.
    static func resolve(_ ref: String, base: URL) -> URL? {
        if let url = URL(string: ref, relativeTo: base)?.absoluteURL { return url }
        if let encoded = ref.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed),
           let url = URL(string: encoded, relativeTo: base)?.absoluteURL { return url }
        return nil
    }

    /// Only http and https URIs go through the relay. data:, skd: (FairPlay)
    /// and every other scheme stay as written: the relay could not fetch
    /// them, and the player never sends headers for them.
    static func isRelayable(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return scheme == "http" || scheme == "https"
    }

    /// `text` with every URI line and every URI attribute resolved against
    /// `base` and replaced by `map(absoluteURL, kind)`. Tags and lines that
    /// name nothing are kept byte for byte (line endings become LF).
    /// EXT-X-CONTENT-STEERING is dropped: its steering manifest names
    /// pathway servers the relay cannot vouch for, and without it the
    /// player uses the playlist's own URIs, all of which are the relay's.
    static func rewrite(_ text: String, base: URL, map: (URL, Kind) -> String) -> String {
        var out: [String] = []
        var nextIsVariant = false
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for raw in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { out.append(""); continue }
            if line.hasPrefix("#") {
                guard line.uppercased().hasPrefix("#EXT") else { out.append(line); continue }
                let colon = line.firstIndex(of: ":")
                let tag = colon.map { String(line[..<$0]) } ?? line
                let upperTag = tag.uppercased()
                if upperTag == "#EXT-X-STREAM-INF" { nextIsVariant = true }
                if upperTag == "#EXT-X-CONTENT-STEERING" { continue }
                guard let colon else { out.append(line); continue }
                let attributes = splitAttributes(line[line.index(after: colon)...])
                var changed = false
                var rebuilt: [String] = []
                rebuilt.reserveCapacity(attributes.count)
                for attribute in attributes {
                    guard let eq = attribute.firstIndex(of: "=") else { rebuilt.append(String(attribute)); continue }
                    let name = attribute[..<eq].trimmingCharacters(in: .whitespaces)
                    let value = attribute[attribute.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                    if isURIAttribute(name), value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\""),
                       let url = resolve(String(value.dropFirst().dropLast()), base: base), isRelayable(url) {
                        let uriKind = kind(forTag: tag, attribute: name, attributes: attributes)
                        rebuilt.append(name + "=\"" + map(url, uriKind) + "\"")
                        changed = true
                    } else {
                        rebuilt.append(String(attribute))
                    }
                }
                out.append(changed ? tag + ":" + rebuilt.joined(separator: ",") : line)
                continue
            }
            let lineKind: Kind = nextIsVariant ? .playlist : .segment
            nextIsVariant = false
            if let url = resolve(line, base: base), isRelayable(url) {
                out.append(map(url, lineKind))
            } else {
                out.append(line)
            }
        }
        return out.joined(separator: "\n")
    }
}

/// GH #93: in-progress server recordings through a locally rewritten
/// playlist. Device 2026-10-12 (f1729e2): Watch from Beginning ran audio
/// from media time 0 while the video output delivered its first frame only
/// at 10.24 s; Resume at ~675 s showed picture at once. The difference is
/// the head of the playlist: it opens with #EXT-X-DISCONTINUITY before
/// seg_00000, and seg_00000's audio starts 1.26 s before its video. So any
/// #EXT-X-DISCONTINUITY ahead of the first segment is dropped, and the
/// start point is written as #EXT-X-START instead of a client-side seek
/// (device 2026-10-12, build 9520249: the seek to 0 raced the live-edge
/// prebuffer and no further media request followed). URIs are left as
/// written; the relay's rewrite resolves them.
enum DVRPlaylistTransform {
    /// `startOffset`: seconds for #EXT-X-START:TIME-OFFSET (PRECISE). 0 =
    /// Watch from Beginning, > 0 = Resume; nil keeps the server's own start
    /// point (live edge). Returns the text, how many leading
    /// discontinuities were dropped, the segment count, and the tags seen
    /// before the first segment (for the log).
    static func apply(_ text: String, startOffset: Double?) -> (text: String, dropped: Int, segments: Int, head: [String]) {
        var out: [String] = []
        var seenSegment = false
        var dropped = 0
        var segments = 0
        var head: [String] = []
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        for raw in normalized.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { out.append(line); continue }
            if line.hasPrefix("#") {
                if startOffset != nil, line.hasPrefix("#EXT-X-START") {
                    head.append(String(line.prefix(80)) + " (replaced)")
                    continue
                }
                if line == "#EXTM3U", let offset = startOffset {
                    out.append(line)
                    out.append(String(format: "#EXT-X-START:TIME-OFFSET=%.3f,PRECISE=YES", offset))
                    continue
                }
                if !seenSegment {
                    if line == "#EXT-X-DISCONTINUITY" {
                        dropped += 1
                        head.append(line + " (dropped)")
                        continue
                    }
                    if !line.hasPrefix("#EXTINF") { head.append(String(line.prefix(80))) }
                }
                if line.hasPrefix("#EXTINF") { seenSegment = true }
                out.append(line)
                continue
            }
            segments += 1
            out.append(line)
        }
        return (out.joined(separator: "\n"), dropped, segments, head)
    }
}

/// The relay's URL rules.
enum PlayerRelayPolicy {
    /// Where a URI that a playlist names is fetched from, and whether the
    /// sign-in goes with it: the redirect rule applied to the playlist's own
    /// final URL. `playlist`: the URL the playlist was finally fetched from;
    /// `playlistKeyed`: that fetch carried the sign-in all the way (no hop
    /// dropped it); `origin`: the URL the app handed the relay.
    ///   - A playlist fetched without the sign-in names nothing that gets it
    ///     (once a hop drops the sign-in, nothing after it regains it, the
    ///     guarded fetchers' rule).
    ///   - The http form of an https server's own host (Dispatcharr builds
    ///     recording segment URLs from the raw scheme behind a TLS proxy it
    ///     does not trust) is fetched as https with the sign-in
    ///     (RedirectAuthPolicy.tlsUpgraded); AVPlayer sent the key over
    ///     cleartext http there.
    ///   - The same host and effective port as both the playlist and the
    ///     origin keeps it; any other host, port, or https to http does not.
    static func upstream(for uri: URL, playlist: URL, playlistKeyed: Bool, origin: URL) -> (url: URL, keyed: Bool) {
        guard playlistKeyed else { return (uri, false) }
        if let upgraded = RedirectAuthPolicy.tlsUpgraded(uri, previous: playlist, original: origin) {
            return (upgraded, true)
        }
        if RedirectAuthPolicy.keepsSignIn(next: uri, previous: playlist, original: origin) {
            return (uri, true)
        }
        return (uri, false)
    }

    /// `upstream` with the LL-HLS delivery directives (`_HLS_msn`,
    /// `_HLS_part`, `_HLS_skip`) the player appended to the relay URL of a
    /// playlist (RFC 8216bis 6.2.5.1). Any other query item the player sent
    /// is not the server's and stays behind; directives already on
    /// `upstream` are replaced.
    static func forwardingHLSDirectives(fromPlayerQuery query: String?, to upstream: URL) -> URL {
        guard let query, !query.isEmpty,
              var components = URLComponents(url: upstream, resolvingAgainstBaseURL: false) else { return upstream }
        let player = URLComponents(string: "x:/?" + query)?.queryItems ?? []
        let directives = player.filter { $0.name.hasPrefix("_HLS_") }
        guard !directives.isEmpty else { return upstream }
        var items = (components.queryItems ?? []).filter { !$0.name.hasPrefix("_HLS_") }
        items.append(contentsOf: directives)
        components.queryItems = items
        return components.url ?? upstream
    }

    /// The last path component of a relay URL: the upstream's own name, so
    /// a player that reads the extension (.m3u8, .ts, .mp4) still can. Never
    /// empty, never a separator.
    static func resourceName(for url: URL) -> String {
        let last = url.lastPathComponent
        guard !last.isEmpty, last != "/" else { return "x" }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#;")
        return last.addingPercentEncoding(withAllowedCharacters: allowed) ?? "x"
    }

    /// `/r/<token>/<id>/<name>` as (token, id), or nil for any other path.
    /// The token is the session's 32 lowercase hex digits.
    static func parseRelayPath(_ path: String) -> (token: String, id: Int)? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 3, parts[0] == "r", parts[1].count == 32,
              parts[1].allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              let id = Int(parts[2]), id >= 0 else { return nil }
        return (String(parts[1]), id)
    }

    /// Dispatcharr recordings answer only with the sign-in, playlist and
    /// every segment alike (apps/channels/api_views.py, the recording
    /// playback gate): there is no header-free form of these URLs.
    static func needsSignInOnEveryRequest(_ url: URL) -> Bool {
        url.path.contains("/api/channels/recordings/")
    }

    /// A player request head parsed: method, target (path and query),
    /// version, headers (names lowercased), and whether the connection
    /// stays open after the response.
    struct RequestHead: Equatable, Sendable {
        let method: String
        let target: String
        let version: String
        let headers: [String: String]
        var keepAlive: Bool {
            let tokens = (headers["connection"] ?? "").lowercased()
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            return version == "HTTP/1.1" ? !tokens.contains("close") : tokens.contains("keep-alive")
        }
        var path: String { String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "") }
        var query: String? {
            let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            return parts.count > 1 ? String(parts[1]) : nil
        }
    }

    /// Parses one HTTP/1.x request head (the bytes before the blank line).
    /// Nil when the request line is not `METHOD TARGET HTTP/x.y`.
    static func parseRequestHead(_ head: String) -> RequestHead? {
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ", omittingEmptySubsequences: true).map(String.init) ?? []
        guard requestLine.count == 3, requestLine[2].uppercased().hasPrefix("HTTP/"),
              requestLine[1].hasPrefix("/") else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard !name.isEmpty else { continue }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return RequestHead(method: requestLine[0].uppercased(), target: requestLine[1],
                           version: requestLine[2].uppercased(), headers: headers)
    }
}
