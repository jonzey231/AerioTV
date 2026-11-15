//
//  TSHLSPlaylist.swift
//  Aerio
//
//  Media playlist text for TSHLSRemuxer (loopback, LAN and in-process
//  copies). Pulled out of the remuxer on 2026-09-27 for the seamless
//  AirPlay channel flip: the flip splices a new channel into the SAME
//  playlist (EXT-X-DISCONTINUITY on the new source's first segment, media
//  sequence continuing), and that splice has to be testable off-device.
//
//  Pure logic, no app singletons, so Scripts/cast-hls-proxy-tests
//  compiles it as is.
//

import Foundation

enum TSHLSPlaylist {

    /// One listed segment: its sequence number, EXTINF duration and URI.
    struct Entry: Equatable {
        let seq: Int
        let duration: Double
        let uri: String
    }

    /// The playlist served before any segment exists.
    static func emptyText(targetDuration: Int) -> String {
        "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:\(targetDuration)\n#EXT-X-MEDIA-SEQUENCE:0\n"
    }

    /// EXT-X-DISCONTINUITY-SEQUENCE of a window starting at `firstSeq`: the
    /// count of tagged segments that already slid out ahead of it. Every
    /// window variant (live RAM, Live Rewind spill, inlined, event, LAN)
    /// derives it from the same tagged-seq set, so the value stays
    /// consistent across reloads and across variants (RFC 8216 6.2.2).
    static func discontinuitySequence(firstSeq: Int, discontinuitySeqs: Set<Int>) -> Int {
        discontinuitySeqs.filter { $0 < firstSeq }.count
    }

    /// The media playlist for `window` (non-empty, ascending seq).
    /// `mapURI` is the EXT-X-MAP URI of the fMP4 arm (nil on the TS arm).
    static func render(window: [Entry], targetDuration: Int, version: Int,
                       discontinuitySeqs: Set<Int>, eventPlaylist: Bool,
                       mapURI: String?, complete: Bool) -> String {
        guard let first = window.first else { return emptyText(targetDuration: targetDuration) }
        var text = "#EXTM3U\n#EXT-X-VERSION:\(version)\n#EXT-X-TARGETDURATION:\(targetDuration)\n"
            + "#EXT-X-MEDIA-SEQUENCE:\(first.seq)\n"
        // Only written once a discontinuity exists, so a session that
        // never flipped serves byte-identical playlists to before.
        if !discontinuitySeqs.isEmpty {
            text += "#EXT-X-DISCONTINUITY-SEQUENCE:\(discontinuitySequence(firstSeq: first.seq, discontinuitySeqs: discontinuitySeqs))\n"
        }
        if eventPlaylist {
            text += "#EXT-X-PLAYLIST-TYPE:EVENT\n"
        }
        if let mapURI {
            text += "#EXT-X-MAP:URI=\"\(mapURI)\"\n"
        }
        for segment in window {
            if discontinuitySeqs.contains(segment.seq) {
                text += "#EXT-X-DISCONTINUITY\n"
            }
            text += "#EXTINF:\(String(format: "%.3f", segment.duration)),\n"
            text += "\(segment.uri)\n"
        }
        if complete {
            text += "#EXT-X-ENDLIST\n"
        }
        return text
    }

    /// True once a receiver fetched a segment of the generation that
    /// starts at `generationFirstSeq` (the flip's discontinuity seq).
    /// `receiverHighestSeq` is -1 until the receiver fetched anything.
    static func receiverCrossed(receiverHighestSeq: Int, generationFirstSeq: Int) -> Bool {
        receiverHighestSeq >= 0 && receiverHighestSeq >= generationFirstSeq
    }
}

/// The per-session path token on every URL a LAN stream listener hands out
/// (the AirPlay copy in TSHLSRemuxer and the Cast proxy). Both listeners
/// accept any device on the network, so the token is what makes the URL the
/// only way in: 128 random bits as the first path segment
/// ("/<token>/live.m3u8"), and any request without it gets 404. It is a
/// random value made for the session, never a key, and every log line
/// writes it as "<token>".
///
/// Pure logic, no app singletons, so Scripts/cast-hls-proxy-tests
/// compiles it as is.
enum LANStreamToken {
    /// 128 random bits (SystemRandomNumberGenerator, which on Apple
    /// platforms is the system's cryptographic generator) as 32 lowercase
    /// hex characters.
    static func make() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// The path a listener hands out for `resource` ("live.m3u8").
    static func path(_ resource: String, token: String) -> String {
        "/\(token)/" + (resource.hasPrefix("/") ? String(resource.dropFirst()) : resource)
    }

    /// The request path below the token ("/live.m3u8"), or nil when the
    /// request does not start with this session's token. The token bytes
    /// are compared in constant time.
    static func strip(_ requestPath: String, token: String) -> String? {
        let prefix = Array("/\(token)/".utf8)
        let path = Array(requestPath.utf8)
        guard !token.isEmpty, path.count >= prefix.count else { return nil }
        var diff: UInt8 = 0
        for i in 0..<prefix.count { diff |= path[i] ^ prefix[i] }
        guard diff == 0 else { return nil }
        return "/" + String(decoding: path[prefix.count...], as: UTF8.self)
    }

    /// `playlist` with every URI it lists under the token: URI lines and
    /// URI="..." attributes. A data: URI or an absolute URL stays as it is.
    static func tokenize(playlist: String, token: String) -> String {
        playlist.components(separatedBy: "\n").map { line -> String in
            if line.isEmpty { return line }
            guard line.hasPrefix("#") else { return uri(line, token: token) }
            guard line.contains("URI=\"") else { return line }
            var out = ""
            var rest = Substring(line)
            while let open = rest.range(of: "URI=\"") {
                out += rest[..<open.upperBound]
                rest = rest[open.upperBound...]
                guard let close = rest.firstIndex(of: "\"") else { break }
                out += uri(String(rest[..<close]), token: token)
                rest = rest[close...]
            }
            return out + rest
        }.joined(separator: "\n")
    }

    /// One URI under the token.
    static func uri(_ uri: String, token: String) -> String {
        if uri.hasPrefix("data:") || uri.contains("://") { return uri }
        return path(uri, token: token)
    }

    /// `text` (a URL, a request line, a playlist) with any token written
    /// as "<token>", for the log.
    static func redacted(_ text: String) -> String {
        text.replacingOccurrences(of: "/[0-9a-f]{32}(?=/|$|[?\\s])", with: "/<token>", options: .regularExpression)
    }
}
