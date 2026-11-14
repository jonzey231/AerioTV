// Player relay pure-logic tests: the HLS playlist rewrite (every URI line
// and URI-bearing attribute, relative-URI resolution), the DVR playlist
// transform, the relay's URL rule (which URIs carry the sign-in, the TLS
// proxy upgrade, the drop after a dropped hop), the LL-HLS directives, the
// relay path and request-head parsing, and the VOD header rule.

import Foundation

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var checks = 0

func check(_ cond: Bool, _ msg: String, line: Int = #line) {
    checks += 1
    if !cond { failures += 1; print("FAIL \(line): \(msg)") }
}

func eq<T: Equatable>(_ a: T, _ b: T, _ msg: String, line: Int = #line) {
    check(a == b, "\(msg): expected \(b), got \(a)", line: line)
}

func u(_ s: String) -> URL { URL(string: s)! }

/// Rewrites with a map that records every (URL, kind) and writes R<n>.
func rewrite(_ text: String, base: String) -> (text: String, seen: [(String, HLSRelayPlaylist.Kind)]) {
    var seen: [(String, HLSRelayPlaylist.Kind)] = []
    let out = HLSRelayPlaylist.rewrite(text, base: u(base)) { url, kind in
        seen.append((url.absoluteString, kind))
        return "http://127.0.0.1:1/r/t/\(seen.count - 1)/x"
    }
    return (out, seen)
}

// MARK: - looksLikePlaylist

check(HLSRelayPlaylist.looksLikePlaylist(Data("#EXTM3U\n#EXT-X-VERSION:3\n".utf8)), "plain playlist")
check(HLSRelayPlaylist.looksLikePlaylist(Data([0xEF, 0xBB, 0xBF] + Array("#EXTM3U\n".utf8))), "BOM ahead of the tag")
check(HLSRelayPlaylist.looksLikePlaylist(Data(" \r\n\t#EXTM3U".utf8)), "white space ahead of the tag")
check(!HLSRelayPlaylist.looksLikePlaylist(Data("<!doctype html><html>".utf8)), "an HTML page is not a playlist")
check(!HLSRelayPlaylist.looksLikePlaylist(Data()), "empty is not a playlist")
check(!HLSRelayPlaylist.looksLikePlaylist(Data([0x47, 0x40, 0x00, 0x10])), "TS bytes are not a playlist")
check(!HLSRelayPlaylist.looksLikePlaylist(Data("#EXTINF:2,\nseg.ts".utf8)), "no #EXTM3U, not a playlist")

// MARK: - splitAttributes

do {
    let parts = HLSRelayPlaylist.splitAttributes(#"BANDWIDTH=1,CODECS="avc1.4d401e,mp4a.40.2",URI="a,b.m3u8""#[...])
    eq(parts.map(String.init), ["BANDWIDTH=1", #"CODECS="avc1.4d401e,mp4a.40.2""#, #"URI="a,b.m3u8""#], "commas inside quotes stay")
}

// MARK: - rewrite: media playlist, relative URIs

do {
    let text = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:2\n#EXTINF:2.0, a title, with commas\nseg0.ts\n#EXTINF:2.0,\nsub/seg1.ts\n#EXTINF:2.0,\n../up/seg2.ts\n#EXTINF:2.0,\n/root/seg3.ts\n#EXTINF:2.0,\n//cdn.example.net/seg4.ts\n#EXTINF:2.0,\nseg5.ts?token=abc&x=1\n#EXTINF:2.0,\nhttp://other.example:8080/seg6.ts\n#EXT-X-ENDLIST\n"
    let r = rewrite(text, base: "https://srv.example:8443/proxy/hls/tok/index.m3u8")
    eq(r.seen.map { $0.0 }, [
        "https://srv.example:8443/proxy/hls/tok/seg0.ts",
        "https://srv.example:8443/proxy/hls/tok/sub/seg1.ts",
        "https://srv.example:8443/proxy/hls/up/seg2.ts",
        "https://srv.example:8443/root/seg3.ts",
        "https://cdn.example.net/seg4.ts",
        "https://srv.example:8443/proxy/hls/tok/seg5.ts?token=abc&x=1",
        "http://other.example:8080/seg6.ts",
    ], "every relative form resolves against the playlist URL")
    check(r.seen.allSatisfy { $0.1 == .segment }, "media playlist URI lines are segments")
    check(r.text.contains("#EXTINF:2.0, a title, with commas"), "EXTINF titles are kept")
    check(r.text.contains("#EXT-X-TARGETDURATION:2") && r.text.contains("#EXT-X-ENDLIST"), "other tags kept")
    check(!r.text.contains("seg0.ts") && !r.text.contains("other.example"), "no upstream URI is left for the player")
    eq(r.text.components(separatedBy: "\n").filter { $0.hasPrefix("http://127.0.0.1:1/r/t/") }.count, 7, "seven relay URIs")
}

do {
    // Relative URIs resolve against the FINAL URL after a redirect.
    let r = rewrite("#EXTM3U\n#EXTINF:4,\n0.ts\n", base: "http://disp.example:9191/proxy/hls/abc123/index.m3u8")
    eq(r.seen.first?.0, "http://disp.example:9191/proxy/hls/abc123/0.ts", "Dispatcharr token segment")
}

do {
    // A query-only reference and a fragment.
    let r = rewrite("#EXTM3U\n#EXTINF:4,\n?part=2\n#EXTINF:4,\nseg.ts#frag\n", base: "http://h.example/p/index.m3u8?sig=1")
    eq(r.seen.map { $0.0 }, ["http://h.example/p/index.m3u8?part=2", "http://h.example/p/seg.ts#frag"], "query-only and fragment references")
}

do {
    // A space in a segment name (refused by URL(string:)) is percent-encoded.
    let r = rewrite("#EXTM3U\n#EXTINF:4,\nmy seg.ts\n", base: "http://h.example/p/index.m3u8")
    eq(r.seen.first?.0, "http://h.example/p/my%20seg.ts", "space encoded")
}

do {
    // CRLF line endings and padded URI lines.
    let r = rewrite("#EXTM3U\r\n#EXTINF:2,\r\n  seg0.ts  \r\n", base: "http://h.example/p/index.m3u8")
    eq(r.seen.first?.0, "http://h.example/p/seg0.ts", "CRLF and padding")
    check(!r.text.contains("\r"), "output lines end in LF")
}

// MARK: - rewrite: multivariant playlist

do {
    let text = """
    #EXTM3U
    #EXT-X-VERSION:7
    #EXT-X-INDEPENDENT-SEGMENTS
    #EXT-X-SESSION-DATA:DATA-ID="com.example.title",VALUE="A, B"
    #EXT-X-SESSION-DATA:DATA-ID="com.example.lyrics",URI="lyrics.json"
    #EXT-X-SESSION-KEY:METHOD=SAMPLE-AES,URI="https://keys.example/k1",KEYFORMAT="identity"
    #EXT-X-CONTENT-STEERING:SERVER-URI="https://steer.example/manifest.json",PATHWAY-ID="CDN-A"
    #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",LANGUAGE="en",DEFAULT=YES,URI="audio/en/index.m3u8"
    #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",URI="https://subs.example/en.m3u8"
    #EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS,GROUP-ID="cc",NAME="CC1",INSTREAM-ID="CC1"
    #EXT-X-STREAM-INF:BANDWIDTH=900000,CODECS="avc1.4d401e,mp4a.40.2",RESOLUTION=640x360,AUDIO="aud"
    video/360/index.m3u8
    #EXT-X-STREAM-INF:BANDWIDTH=3000000,CODECS="avc1.640028,mp4a.40.2"
    https://cdn.example/1080/index.m3u8
    #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=200000,CODECS="avc1.4d401e",URI="video/360/iframe.m3u8"
    """
    let r = rewrite(text, base: "http://own.example:9191/vod/master.m3u8")
    eq(r.seen.map { $0.0 }, [
        "http://own.example:9191/vod/lyrics.json",
        "https://keys.example/k1",
        "http://own.example:9191/vod/audio/en/index.m3u8",
        "https://subs.example/en.m3u8",
        "http://own.example:9191/vod/video/360/index.m3u8",
        "https://cdn.example/1080/index.m3u8",
        "http://own.example:9191/vod/video/360/iframe.m3u8",
    ], "every multivariant URI, in order")
    eq(r.seen.map { $0.1 }, [.data, .key, .playlist, .playlist, .playlist, .playlist, .playlist], "kinds")
    check(!r.text.contains("CONTENT-STEERING") && !r.text.contains("steer.example"), "content steering dropped")
    check(r.text.contains(#"#EXT-X-SESSION-DATA:DATA-ID="com.example.title",VALUE="A, B""#), "SESSION-DATA without a URI kept")
    check(r.text.contains(#"CODECS="avc1.4d401e,mp4a.40.2",RESOLUTION=640x360,AUDIO="aud""#), "STREAM-INF attributes kept")
    check(r.text.contains(#"#EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS,GROUP-ID="cc",NAME="CC1",INSTREAM-ID="CC1""#), "MEDIA without a URI kept")
    check(r.text.contains(#"#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",LANGUAGE="en",DEFAULT=YES,URI="http://127.0.0.1:1/r/t/2/x""#),
          "MEDIA URI replaced in place, other attributes kept")
    check(r.text.contains(#"#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=200000,CODECS="avc1.4d401e",URI="http://127.0.0.1:1/r/t/6/x""#),
          "I-FRAME-STREAM-INF URI replaced")
}

// MARK: - rewrite: keys, maps, byte ranges

do {
    let text = """
    #EXTM3U
    #EXT-X-VERSION:7
    #EXT-X-TARGETDURATION:4
    #EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x00000000000000000000000000000001
    #EXT-X-MAP:URI="init.mp4",BYTERANGE="720@0"
    #EXTINF:4,
    #EXT-X-BYTERANGE:1000@720
    media.mp4
    #EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://fairplay-key-id",KEYFORMAT="com.apple.streamingkeydelivery"
    #EXTINF:4,
    #EXT-X-BYTERANGE:1200
    media.mp4
    #EXT-X-KEY:METHOD=AES-128,URI="data:text/plain;base64,AAAAAAAAAAAAAAAAAAAAAA=="
    #EXTINF:4,
    seg3.m4s
    #EXT-X-KEY:METHOD=NONE
    #EXTINF:4,
    seg4.m4s
    """
    let r = rewrite(text, base: "http://own.example/rec/index.m3u8")
    eq(r.seen.map { $0.0 }, [
        "http://own.example/rec/key.bin",
        "http://own.example/rec/init.mp4",
        "http://own.example/rec/media.mp4",
        "http://own.example/rec/media.mp4",
        "http://own.example/rec/seg3.m4s",
        "http://own.example/rec/seg4.m4s",
    ], "key, map, byte-range media, segments")
    eq(r.seen.map { $0.1 }, [.key, .map, .segment, .segment, .segment, .segment], "kinds")
    check(r.text.contains(#"#EXT-X-KEY:METHOD=AES-128,URI="http://127.0.0.1:1/r/t/0/x",IV=0x00000000000000000000000000000001"#), "KEY IV kept")
    check(r.text.contains(#"#EXT-X-MAP:URI="http://127.0.0.1:1/r/t/1/x",BYTERANGE="720@0""#), "MAP BYTERANGE kept")
    check(r.text.contains("#EXT-X-BYTERANGE:1000@720") && r.text.contains("#EXT-X-BYTERANGE:1200"), "BYTERANGE tags kept (the player sends Range to the relay)")
    check(r.text.contains(#"URI="skd://fairplay-key-id""#), "skd: key left as written")
    check(r.text.contains(#"URI="data:text/plain;base64,AAAAAAAAAAAAAAAAAAAAAA==""#), "data: key left as written")
    check(r.text.contains("#EXT-X-KEY:METHOD=NONE"), "METHOD=NONE kept")
}

// MARK: - rewrite: low-latency HLS and interstitials

do {
    let text = """
    #EXTM3U
    #EXT-X-VERSION:9
    #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=1.0,CAN-SKIP-UNTIL=12.0
    #EXT-X-PART-INF:PART-TARGET=0.33334
    #EXT-X-SKIP:SKIPPED-SEGMENTS=3
    #EXTINF:4.0,
    fileSequence269.mp4
    #EXT-X-PART:DURATION=0.33334,URI="filePart270.0.mp4",INDEPENDENT=YES
    #EXT-X-PRELOAD-HINT:TYPE=PART,URI="filePart270.1.mp4"
    #EXT-X-PRELOAD-HINT:TYPE=MAP,URI="init2.mp4",BYTERANGE-START=0
    #EXT-X-RENDITION-REPORT:URI="../1M/waitForMSN.php",LAST-MSN=273,LAST-PART=2
    #EXT-X-DATERANGE:ID="ad1",CLASS="com.apple.hls.interstitial",START-DATE="2026-11-13T20:00:00Z",X-ASSET-URI="https://ads.example/ad.m3u8",X-RESUME-OFFSET=0
    #EXT-X-DATERANGE:ID="ad2",CLASS="com.apple.hls.interstitial",START-DATE="2026-11-13T20:10:00Z",X-ASSET-LIST="https://ads.example/list.json"
    #EXT-X-FOO:URI="custom.bin"
    # a comment with URI="not-a-tag.ts"
    """
    let r = rewrite(text, base: "https://live.example/2M/waitForMSN.php?_HLS_msn=273")
    eq(r.seen.map { $0.0 }, [
        "https://live.example/2M/fileSequence269.mp4",
        "https://live.example/2M/filePart270.0.mp4",
        "https://live.example/2M/filePart270.1.mp4",
        "https://live.example/2M/init2.mp4",
        "https://live.example/1M/waitForMSN.php",
        "https://ads.example/ad.m3u8",
        "https://ads.example/list.json",
        "https://live.example/2M/custom.bin",
    ], "LL-HLS parts, hints, reports, interstitial assets, unknown tags")
    eq(r.seen.map { $0.1 }, [.segment, .segment, .segment, .map, .playlist, .playlist, .data, .other], "kinds")
    check(r.text.contains("#EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=1.0,CAN-SKIP-UNTIL=12.0"), "SERVER-CONTROL kept")
    check(r.text.contains("#EXT-X-SKIP:SKIPPED-SEGMENTS=3"), "SKIP kept")
    check(r.text.contains(#"LAST-MSN=273,LAST-PART=2"#), "RENDITION-REPORT attributes kept")
    check(r.text.contains("BYTERANGE-START=0"), "PRELOAD-HINT byte range kept")
    check(r.text.contains("X-RESUME-OFFSET=0"), "DATERANGE attributes kept")
    check(r.text.contains(#"# a comment with URI="not-a-tag.ts""#), "comments untouched")
}

do {
    // An unquoted URI attribute is not a URI per RFC 8216: left alone.
    let r = rewrite("#EXTM3U\n#EXT-X-MAP:URI=init.mp4\n", base: "http://h.example/p/x.m3u8")
    check(r.seen.isEmpty && r.text.contains("#EXT-X-MAP:URI=init.mp4"), "unquoted URI left as written")
}

do {
    // Lowercase tag names (not RFC, seen in the wild) are read the same.
    let r = rewrite("#EXTM3U\n#ext-x-stream-inf:BANDWIDTH=1\nlow.m3u8\n", base: "http://h.example/p/master.m3u8")
    eq(r.seen.first?.1, .playlist, "lowercase STREAM-INF marks the variant line")
}

// MARK: - DVRPlaylistTransform

do {
    let text = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-PLAYLIST-TYPE:EVENT\n#EXT-X-DISCONTINUITY\n#EXTINF:2,\nseg_00000.ts\n#EXT-X-DISCONTINUITY\n#EXTINF:2,\nseg_00001.ts\n"
    let r = DVRPlaylistTransform.apply(text, startOffset: nil)
    eq(r.dropped, 1, "the leading discontinuity is dropped")
    eq(r.segments, 2, "two segments")
    eq(r.text.components(separatedBy: "\n").filter { $0 == "#EXT-X-DISCONTINUITY" }.count, 1, "a later discontinuity stays")
    check(!r.text.contains("EXT-X-START"), "no start point without an offset")
    check(r.text.contains("seg_00000.ts") && r.text.contains("seg_00001.ts"), "URIs left as written")
}

do {
    let text = "#EXTM3U\n#EXT-X-START:TIME-OFFSET=-12\n#EXT-X-DISCONTINUITY\n#EXT-X-DISCONTINUITY\n#EXTINF:2,\nseg_00000.ts\n"
    let r = DVRPlaylistTransform.apply(text, startOffset: 0)
    eq(r.dropped, 2, "two leading discontinuities dropped")
    check(r.text.hasPrefix("#EXTM3U\n#EXT-X-START:TIME-OFFSET=0.000,PRECISE=YES\n"), "start point right after EXTM3U")
    check(!r.text.contains("TIME-OFFSET=-12"), "the server's start point is replaced")
    let resume = DVRPlaylistTransform.apply(text, startOffset: 675.5)
    check(resume.text.contains("#EXT-X-START:TIME-OFFSET=675.500,PRECISE=YES"), "resume offset")
    let keep = DVRPlaylistTransform.apply(text, startOffset: nil)
    check(keep.text.contains("#EXT-X-START:TIME-OFFSET=-12"), "nil offset keeps the server's start point")
}

// MARK: - PlayerRelayPolicy.upstream

do {
    let origin = u("https://dvr.example/api/channels/recordings/7/file/")
    let playlist = u("https://dvr.example/api/channels/recordings/7/hls/index.m3u8")
    var r = PlayerRelayPolicy.upstream(for: u("http://dvr.example/api/channels/recordings/7/hls/seg_00001.ts"),
                                       playlist: playlist, playlistKeyed: true, origin: origin)
    eq(r.url.absoluteString, "https://dvr.example/api/channels/recordings/7/hls/seg_00001.ts", "TLS proxy form fetched as https")
    check(r.keyed, "and it keeps the sign-in")
    r = PlayerRelayPolicy.upstream(for: u("https://dvr.example/api/channels/recordings/7/hls/seg_00002.ts"),
                                   playlist: playlist, playlistKeyed: true, origin: origin)
    check(r.keyed && r.url.absoluteString.hasPrefix("https://dvr.example/"), "same https host keeps it")
    r = PlayerRelayPolicy.upstream(for: u("https://cdn.provider.example/seg.ts"), playlist: playlist, playlistKeyed: true, origin: origin)
    check(!r.keyed && r.url.host == "cdn.provider.example", "another host: no sign-in, URL unchanged")
    r = PlayerRelayPolicy.upstream(for: u("https://dvr.example:8443/seg.ts"), playlist: playlist, playlistKeyed: true, origin: origin)
    check(!r.keyed, "another port: no sign-in")
    r = PlayerRelayPolicy.upstream(for: u("http://dvr.example:8080/seg.ts"), playlist: playlist, playlistKeyed: true, origin: origin)
    check(!r.keyed && r.url.scheme == "http", "http on another port is no TLS proxy form: no sign-in, no upgrade")
    r = PlayerRelayPolicy.upstream(for: u("https://dvr.example/seg.ts"), playlist: playlist, playlistKeyed: false, origin: origin)
    check(!r.keyed, "a playlist fetched without the sign-in names nothing that gets it")
}

do {
    let origin = u("https://tv.example:8443/proxy/vod/movie/u/vod_1_2")
    let playlist = u("https://tv.example:8443/proxy/vod/movie/u/vod_1_2")
    let r = PlayerRelayPolicy.upstream(for: u("http://tv.example:8443/x.ts"), playlist: playlist, playlistKeyed: true, origin: origin)
    eq(r.url.absoluteString, "https://tv.example:8443/x.ts", "http on the https port becomes https on that port")
    check(r.keyed, "keyed")
}

do {
    let origin = u("http://192.168.1.10:9191/proxy/ts/stream/abc?output_format=hls")
    let playlist = u("http://192.168.1.10:9191/proxy/hls/tok/index.m3u8")
    var r = PlayerRelayPolicy.upstream(for: u("http://192.168.1.10:9191/proxy/hls/tok/5.ts"), playlist: playlist, playlistKeyed: true, origin: origin)
    check(r.keyed, "plain http LAN server: same host and port keeps it")
    r = PlayerRelayPolicy.upstream(for: u("https://192.168.1.10:9191/proxy/hls/tok/5.ts"), playlist: playlist, playlistKeyed: true, origin: origin)
    check(r.keyed, "http to https on an unchanged port keeps it")
    r = PlayerRelayPolicy.upstream(for: u("http://192.168.1.11:9191/x.ts"), playlist: playlist, playlistKeyed: true, origin: origin)
    check(!r.keyed, "a neighbour on the LAN does not")
    r = PlayerRelayPolicy.upstream(for: u("http://192.168.1.10:9191/x.ts"), playlist: u("http://provider.example/live.m3u8"),
                                   playlistKeyed: true, origin: origin)
    check(!r.keyed, "judged against the playlist's own URL too")
}

// MARK: - LL-HLS directives, names, paths

do {
    let up = u("https://live.example/2M/index.m3u8?sig=abc")
    eq(PlayerRelayPolicy.forwardingHLSDirectives(fromPlayerQuery: "_HLS_msn=273&_HLS_part=2", to: up).absoluteString,
       "https://live.example/2M/index.m3u8?sig=abc&_HLS_msn=273&_HLS_part=2", "directives appended, server query kept")
    eq(PlayerRelayPolicy.forwardingHLSDirectives(fromPlayerQuery: "_HLS_skip=YES&other=1", to: u("https://l.example/i.m3u8?_HLS_msn=1")).absoluteString,
       "https://l.example/i.m3u8?_HLS_skip=YES", "old directives replaced, other player items dropped")
    eq(PlayerRelayPolicy.forwardingHLSDirectives(fromPlayerQuery: "foo=1", to: up), up, "no directive, no change")
    eq(PlayerRelayPolicy.forwardingHLSDirectives(fromPlayerQuery: nil, to: up), up, "no query, no change")
}

eq(PlayerRelayPolicy.resourceName(for: u("http://h/a/index.m3u8")), "index.m3u8", "name keeps the extension")
eq(PlayerRelayPolicy.resourceName(for: u("http://h/a/b%20c.ts?x=1")), "b%20c.ts", "name percent-encoded, no query")
eq(PlayerRelayPolicy.resourceName(for: u("http://h/")), "x", "root path")
eq(PlayerRelayPolicy.resourceName(for: u("http://h")), "x", "no path")
eq(PlayerRelayPolicy.resourceName(for: u("http://h/a/vod_1_2")), "vod_1_2", "extensionless session id")

do {
    let token = "0123456789abcdef0123456789abcdef"
    let p = PlayerRelayPolicy.parseRelayPath("/r/\(token)/42/seg.ts")
    eq(p?.token, token, "token")
    eq(p?.id, 42, "id")
    check(PlayerRelayPolicy.parseRelayPath("/r/\(token)/0/") != nil, "id 0 with an empty name")
    check(PlayerRelayPolicy.parseRelayPath("/r/\(token.uppercased())/1/x") == nil, "uppercase token refused")
    check(PlayerRelayPolicy.parseRelayPath("/r/abc/1/x") == nil, "short token refused")
    check(PlayerRelayPolicy.parseRelayPath("/r/\(token)/one/x") == nil, "non-numeric id refused")
    check(PlayerRelayPolicy.parseRelayPath("/r/\(token)/-1/x") == nil, "negative id refused")
    check(PlayerRelayPolicy.parseRelayPath("/x/\(token)/1/x") == nil, "other prefix refused")
    check(PlayerRelayPolicy.parseRelayPath("/") == nil, "root refused")
}

check(PlayerRelayPolicy.needsSignInOnEveryRequest(u("https://d.example/api/channels/recordings/9/file/")), "recording file")
check(PlayerRelayPolicy.needsSignInOnEveryRequest(u("https://d.example/sub/api/channels/recordings/9/hls/index.m3u8")), "recording HLS behind a sub-path")
check(!PlayerRelayPolicy.needsSignInOnEveryRequest(u("https://d.example/proxy/vod/movie/u/vod_1_2")), "a VOD session is not")

// MARK: - Request heads

do {
    let h = PlayerRelayPolicy.parseRequestHead("GET /r/t/1/index.m3u8?_HLS_msn=3 HTTP/1.1\r\nHost: 127.0.0.1:5\r\nRange: bytes=0-1\r\nUser-Agent: AppleCoreMedia/1.0\r\nX-Playback-Session-Id: A")
    eq(h?.method, "GET", "method")
    eq(h?.path, "/r/t/1/index.m3u8", "path")
    eq(h?.query, "_HLS_msn=3", "query")
    eq(h?.headers["range"], "bytes=0-1", "headers lowercased")
    eq(h?.keepAlive, true, "HTTP/1.1 keeps alive by default")
    eq(PlayerRelayPolicy.parseRequestHead("GET /x HTTP/1.1\r\nConnection: close")?.keepAlive, false, "Connection: close")
    eq(PlayerRelayPolicy.parseRequestHead("GET /x HTTP/1.0")?.keepAlive, false, "HTTP/1.0 closes by default")
    eq(PlayerRelayPolicy.parseRequestHead("GET /x HTTP/1.0\r\nConnection: Keep-Alive")?.keepAlive, true, "HTTP/1.0 keep-alive")
    eq(PlayerRelayPolicy.parseRequestHead("head /x HTTP/1.1")?.method, "HEAD", "method uppercased")
    check(PlayerRelayPolicy.parseRequestHead("GET http://evil.example/ HTTP/1.1") == nil, "absolute-form target refused")
    check(PlayerRelayPolicy.parseRequestHead("garbage") == nil, "garbage refused")
    check(PlayerRelayPolicy.parseRequestHead("GET /x SPDY/3") == nil, "non-HTTP version refused")
    eq(PlayerRelayPolicy.parseRequestHead("GET /x HTTP/1.1")?.query, nil, "no query")
}

// MARK: - VOD headers (X-API-Key only)

do {
    let vod = u("http://d.example:9191/proxy/vod/movie/uuid/vod_1_2?stream_id=4")
    eq(RedirectAuthPolicy.vodStreamHeaders(["X-API-Key": "k", "Authorization": "ApiKey k", "User-Agent": "ua"], url: vod),
       ["X-API-Key": "k", "User-Agent": "ua"], "both: Authorization dropped")
    eq(RedirectAuthPolicy.vodStreamHeaders(["Authorization": "ApiKey k"], url: vod), ["X-API-Key": "k"], "ApiKey becomes X-API-Key")
    eq(RedirectAuthPolicy.vodStreamHeaders(["authorization": "apikey k", "user-agent": "ua"], url: vod),
       ["X-API-Key": "k", "user-agent": "ua"], "lowercase names and scheme")
    eq(RedirectAuthPolicy.vodStreamHeaders(["Authorization": "Bearer jwt.a.b"], url: vod), [:], "Bearer dropped")
    eq(RedirectAuthPolicy.vodStreamHeaders(["x-api-key": "k", "Authorization": "Bearer t"], url: vod), ["x-api-key": "k"], "X-API-Key kept as named")
    eq(RedirectAuthPolicy.vodStreamHeaders(["Authorization": "ApiKey "], url: vod), [:], "an empty ApiKey is dropped, not moved")
    eq(RedirectAuthPolicy.vodStreamHeaders(["X-API-Key": "k", "Authorization": "ApiKey k"], url: u("http://d.example/sub/proxy/vod/episode/u/s")),
       ["X-API-Key": "k"], "sub-path deployment")
    let live = ["X-API-Key": "k", "Authorization": "ApiKey k"]
    eq(RedirectAuthPolicy.vodStreamHeaders(live, url: u("http://d.example/proxy/ts/stream/u")), live, "live TS unchanged")
    eq(RedirectAuthPolicy.vodStreamHeaders(live, url: u("http://d.example/api/channels/recordings/1/file/")), live, "recordings unchanged")
    eq(RedirectAuthPolicy.vodStreamHeaders(live, url: nil), live, "no URL unchanged")
    eq(RedirectAuthPolicy.vodStreamHeaders(["User-Agent": "ua"], url: vod), ["User-Agent": "ua"], "nothing to move")
}

check(RedirectAuthPolicy.headersCarrySignIn(["x-api-key": "k"]), "lowercase X-API-Key is sign-in")
check(RedirectAuthPolicy.headersCarrySignIn(["Cookie": "a=b"]), "Cookie is sign-in")
check(!RedirectAuthPolicy.headersCarrySignIn(["User-Agent": "ua", "Accept": "*/*"]), "UA and Accept are not")
eq(RedirectAuthPolicy.withoutSignIn(["X-API-Key": "k", "authorization": "a", "User-Agent": "ua"]), ["User-Agent": "ua"], "withoutSignIn keeps the rest")

print("\(checks) checks, \(failures) failures")
if failures == 0 { print("ALL TESTS PASSED") } else { exit(1) }
