//
//  RedirectAuthPolicy.swift
//  Aerio
//
//  The one rule for a playlist's sign-in on a followed redirect.
//
//  Measured 2026-11-13 (iOS 27 simulator, loopback stand-in): on every hop it
//  follows, URLSession re-sends the request's X-API-Key, Cookie and
//  X-Emby-Authorization to whatever host the Location names, and a 307 or
//  308 re-sends a POST body too; it drops Authorization on every hop, the
//  same host included. NWHTTPClient forwarded a POST body across hosts the
//  same way. So a Redirect stream profile (jonzey231/AerioTV-Android#159) or
//  any server 30x to another host handed that host the user's API key. Every
//  path that follows redirects with sign-in attached decides each hop here:
//    - the same host and the same effective port (the explicit port, else 80
//      for http and 443 for https): kept, copied back from the original
//      request, so reverse-proxy canonicalization still authenticates,
//      Bearer tokens included;
//    - http to https on the same host: kept only from 80 to 443 or on an
//      unchanged port, the shape of an ordinary TLS upgrade;
//    - another host, another port (a different port can be a different
//      service), or https to http: removed, so the key never reaches a
//      service the user did not configure and never leaves TLS in cleartext.
//    - one exception to https to http (`tlsUpgraded`): Dispatcharr builds
//      absolute redirect URLs with http:// when it does not trust the TLS
//      proxy in front of it, and the app tolerates what the server sends. A
//      same-host hop to http on port 80, or on the https request's own port,
//      from a chain that has been https with the sign-in all along, is
//      followed as https on the original request's port, sign-in kept.
//  Once a hop drops the sign-in, no later hop gets it back. A hop that loses
//  the sign-in but would still re-send a request body (the Direct Connect
//  login's password, a sync upload) is not followed at all.
//  The same rule decides where a playlist's key may go before any redirect:
//  `isOwnAddress` matches a URL against the playlist's Server URL and Local
//  URL, `keyedStream` moves a stream URL saved before the playlist moved
//  onto its current address (or sends it without the key, or not at all
//  with Xtream Codes credentials in it), and `reanchored` keeps
//  server-supplied page links on the address the app is already using.
//
//  Pure Foundation with no app singletons, so
//  Scripts/cast-hls-proxy-tests/run.sh compiles it next to the proxy sources
//  and tests the rule on its own.
//

import Foundation

enum RedirectAuthPolicy {
    /// Headers that carry sign-in: Dispatcharr's API key in either header
    /// shape or its JWT, a session cookie, and the Emby/Jellyfin token
    /// header (MediaServerAPIs).
    static let signInHeaders = ["X-API-Key", "Authorization", "Cookie", "X-Emby-Authorization"]

    /// Header names compare case-insensitively on the wire, so the filter
    /// does too: a dictionary built with "x-api-key" must not slip through.
    static func isSignInHeader(_ name: String) -> Bool {
        signInHeaders.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// `headers` for a request that must not carry sign-in (a player handed
    /// a URL on an address the sign-in may not reach). User-Agent and the
    /// rest carry no secret and stay.
    static func withoutSignIn(_ headers: [String: String]) -> [String: String] {
        headers.filter { !isSignInHeader($0.key) }
    }

    /// True when `headers` carry any sign-in header (names compared
    /// case-insensitively).
    static func headersCarrySignIn(_ headers: [String: String]) -> Bool {
        headers.keys.contains { isSignInHeader($0) }
    }

    /// The headers for a stream request to Dispatcharr's VOD proxy: the key
    /// as X-API-Key only, never Authorization. The VOD proxy copies the
    /// Authorization header of the request that opens a session into the
    /// session's upstream headers and sends it to the provider on every
    /// fetch (apps/proxy/vod_proxy/multi_worker_connection_manager.py, main
    /// 1241b3f lines 1277-1282, dev b0c785d line 1375), so `Authorization:
    /// ApiKey <key>` handed the user's key to their IPTV provider through the
    /// server itself. X-API-Key is read first and never forwarded
    /// (apps/accounts/authentication.py 86-122). An ApiKey Authorization
    /// becomes X-API-Key; a Bearer one is dropped (it is not a header the VOD
    /// proxy reads as a key, and VOD plays without one). Any URL that is not
    /// /proxy/vod/ is returned unchanged.
    static func vodStreamHeaders(_ headers: [String: String], url: URL?) -> [String: String] {
        guard let path = url?.path, path.contains("/proxy/vod/") else { return headers }
        guard let authName = headers.keys.first(where: { $0.caseInsensitiveCompare("Authorization") == .orderedSame })
        else { return headers }
        var out = headers
        let auth = out.removeValue(forKey: authName) ?? ""
        let hasXKey = out.keys.contains { $0.caseInsensitiveCompare("X-API-Key") == .orderedSame }
        let parts = auth.split(separator: " ", maxSplits: 1).map(String.init)
        if !hasXKey, parts.count == 2, parts[0].caseInsensitiveCompare("ApiKey") == .orderedSame,
           !parts[1].trimmingCharacters(in: .whitespaces).isEmpty {
            out["X-API-Key"] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        return out
    }

    /// https to http: the hop would move the request out of TLS.
    static func isDowngrade(from: URL?, to: URL?) -> Bool {
        from?.scheme?.lowercased() == "https" && to?.scheme?.lowercased() == "http"
    }

    /// The port a URL connects to: the explicit one, else 80 for http and
    /// 443 for https. Nil for any other scheme.
    static func effectivePort(_ url: URL?) -> Int? {
        guard let url, let scheme = url.scheme?.lowercased() else { return nil }
        if let port = url.port { return port }
        switch scheme {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    /// True when sign-in sent to `from` may also go to `to`: both http(s),
    /// the same non-empty host (case-insensitive), the same effective port,
    /// and not https to http. The one port change kept is http to https
    /// from 80 to 443, the default ports of an ordinary TLS upgrade. A
    /// missing URL, host, or port fails closed.
    static func keepsSignIn(from: URL?, to: URL?) -> Bool {
        guard let fromScheme = from?.scheme?.lowercased(), fromScheme == "http" || fromScheme == "https",
              let toScheme = to?.scheme?.lowercased(), toScheme == "http" || toScheme == "https",
              let fromHost = from?.host?.lowercased(), !fromHost.isEmpty,
              let toHost = to?.host?.lowercased(), fromHost == toHost,
              let fromPort = effectivePort(from), let toPort = effectivePort(to),
              !isDowngrade(from: from, to: to) else { return false }
        if fromPort == toPort { return true }
        return fromScheme == "http" && toScheme == "https" && fromPort == 80 && toPort == 443
    }

    /// A playlist's own addresses as this rule compares them: its Server URL
    /// and Local URL, trimmed and read as http when they name no scheme (the
    /// Local URL field takes a bare host:port; PlaylistRoute.hostKey reads it
    /// the same way). A blank or hostless value is left out.
    static func ownAddresses(serverURL: String, localURL: String) -> [URL] {
        [serverURL, localURL].compactMap { raw in
            var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { return nil }
            let lower = s.lowercased()
            if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") { s = "http://" + s }
            guard let url = URL(string: s), let host = url.host, !host.isEmpty else { return nil }
            return url
        }
    }

    /// True when `url` is on one of `ownAddresses` by this rule: the same
    /// host and effective port (http to https only from 80 to 443 or on an
    /// unchanged port), never https to http. The only places a playlist's
    /// key may go at all: a stream, the catch-up session, a poster, a logo,
    /// a custom guide URL. Comparing hosts alone let another service on
    /// another port of the same machine, or the same address over plain
    /// http, receive the key.
    static func isOwnAddress(_ url: URL?, ownAddresses: [URL]) -> Bool {
        ownAddresses.contains { keepsSignIn(from: $0, to: url) }
    }

    /// A server-supplied link (a DRF `next` page) moved onto `anchor`'s
    /// scheme, host, and port, keeping only its path and query. The server
    /// builds such links from the address it sees itself on, which behind a
    /// reverse proxy can be plain http or an internal host:port, and the
    /// page walks followed them with the API key attached wherever they
    /// pointed. Re-anchored, the key only goes to the address the previous
    /// page was fetched from, and a link with the wrong scheme or host
    /// still reaches the next page. Relative links resolve against
    /// `anchor`; credentials and fragments in the link are dropped. Nil
    /// when the link is missing or does not parse.
    static func reanchored(_ link: String?, onto anchor: URL) -> URL? {
        guard let link, !link.isEmpty,
              let resolved = URL(string: link, relativeTo: anchor)?.absoluteURL,
              var out = URLComponents(url: resolved, resolvingAgainstBaseURL: false),
              let base = URLComponents(url: anchor, resolvingAgainstBaseURL: false) else { return nil }
        out.scheme = base.scheme
        out.percentEncodedHost = base.percentEncodedHost
        out.port = base.port
        out.user = nil
        out.password = nil
        out.fragment = nil
        return out.url
    }

    /// Paths only the playlist's server serves, where a rebuild may start:
    /// Dispatcharr's proxy (live, VOD, HLS sessions) and the Xtream Codes
    /// stream paths. The same list as AerioTV for Android's StreamAddresses.
    static let serverRouteMarkers = ["/proxy/", "/live/", "/timeshift/", "/movie/", "/series/"]

    /// `url` moved onto `current` when its path is the server's own: from its
    /// first `serverRouteMarkers` segment on, after `current`'s own path
    /// prefix (a server behind a sub-path keeps it), with `url`'s query. Nil
    /// when the path has none of them: that URL is not the server's to move.
    static func rebuiltOnCurrentAddress(_ url: URL, current: URL) -> URL? {
        guard let target = URLComponents(url: url, resolvingAgainstBaseURL: false),
              var base = URLComponents(url: current, resolvingAgainstBaseURL: false) else { return nil }
        let path = target.percentEncodedPath
        guard let marker = serverRouteMarkers.compactMap({ path.range(of: $0) })
                .min(by: { $0.lowerBound < $1.lowerBound }) else { return nil }
        var prefix = base.percentEncodedPath
        while prefix.hasSuffix("/") { prefix.removeLast() }
        base.percentEncodedPath = prefix + String(path[marker.lowerBound...])
        base.percentEncodedQuery = target.percentEncodedQuery
        base.user = nil
        base.password = nil
        base.fragment = nil
        return base.url
    }

    /// True when `url` carries the Xtream Codes `user` and `pass`, as adjacent
    /// path segments (`/live/<user>/<pass>/...`) or as the `username` and
    /// `password` query items.
    static func carriesXtreamCredentials(_ url: URL, user: String, pass: String) -> Bool {
        let u = user.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = pass.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty, !p.isEmpty else { return false }
        let segments = url.pathComponents.filter { $0 != "/" }
        if segments.count > 1, (0..<(segments.count - 1)).contains(where: { segments[$0] == u && segments[$0 + 1] == p }) {
            return true
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items.first { $0.name == "username" }?.value == u && items.first { $0.name == "password" }?.value == p
    }

    /// What a stream request that may carry a playlist's sign-in becomes.
    enum StreamOpen: Equatable {
        /// As is, sign-in included.
        case send(URL)
        /// Rebuilt on the playlist's current address, with the sign-in it uses now.
        case rebuilt(URL)
        /// As is, without the Dispatcharr key.
        case withoutKey(URL)
        /// Not sent at all: Xtream Codes credentials in the URL of an address
        /// the playlist no longer uses.
        case refuse
    }

    /// The gate before every stream request that carries a playlist's
    /// sign-in: the Dispatcharr key in its headers (`carriesKey`) or the
    /// Xtream Codes credentials in its URL (`xtream`). A channel, VOD,
    /// catch-up, or recording URL saved before Edit Playlist moved the Server
    /// URL or Local URL still names the old address, and sending the sign-in
    /// there hands it to whoever has that address now. The same rule as
    /// AerioTV for Android's StreamAddresses: on one of `ownAddresses` as is;
    /// for the active playlist and one of the server's own paths, rebuilt on
    /// `current` (the address in use: the Local URL when its probe reached
    /// it, else the Server URL); otherwise without the key, and not at all
    /// when Xtream Codes credentials are in the URL.
    static func keyedStream(_ url: URL, ownAddresses: [URL], current: URL?, isActive: Bool,
                            carriesKey: Bool, xtream: (user: String, pass: String)? = nil) -> StreamOpen {
        let xtreamInURL = xtream.map { carriesXtreamCredentials(url, user: $0.user, pass: $0.pass) } ?? false
        guard carriesKey || xtreamInURL else { return .send(url) }
        if isOwnAddress(url, ownAddresses: ownAddresses) { return .send(url) }
        if isActive, let current, isOwnAddress(current, ownAddresses: ownAddresses),
           let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
           let rebuilt = rebuiltOnCurrentAddress(url, current: current) {
            return .rebuilt(rebuilt)
        }
        return xtreamInURL ? .refuse : .withoutKey(url)
    }

    /// `url` as it may be requested with the sign-in of the server at one of
    /// `ownAddresses`, or nil. On an own address as is; an absolute http URL
    /// the server reported for its own host (port 80 or the server's port),
    /// as a server behind a TLS proxy it does not trust reports a recording's
    /// file URL, comes back as https on the server's port (`tlsUpgraded`
    /// applied to a first request). AerioTV for Android's serverUrlFor.
    static func serverURL(for url: URL, ownAddresses: [URL]) -> URL? {
        for own in ownAddresses {
            if keepsSignIn(from: own, to: url) { return url }
            if let upgraded = tlsUpgraded(url, previous: own, original: own) { return upgraded }
        }
        return nil
    }

    /// The verdict for one hop to `next` by URL, checked against the URL that
    /// answered with the redirect (`previous`) AND the request the app built
    /// (`original`). `redirect` adds the rest: a chain that already dropped
    /// the sign-in never gets it back, and the https form of a same-host
    /// downgrade (`tlsUpgraded`).
    static func keepsSignIn(next: URL?, previous: URL?, original: URL?) -> Bool {
        keepsSignIn(from: previous ?? original, to: next) && keepsSignIn(from: original ?? previous, to: next)
    }

    /// True when `request` still carries every sign-in header `original` was
    /// sent with, so no hop before it dropped the sign-in. True when the
    /// original carried none.
    static func carriesSignIn(_ request: URLRequest?, of original: URLRequest?) -> Bool {
        guard let original else { return true }
        for name in signInHeaders where original.value(forHTTPHeaderField: name) != nil {
            if request?.value(forHTTPHeaderField: name) == nil { return false }
        }
        return true
    }

    /// True when `request` carries any sign-in header.
    static func hasSignIn(_ request: URLRequest?) -> Bool {
        signInHeaders.contains { request?.value(forHTTPHeaderField: $0) != nil }
    }

    /// The https form of a same-host hop the server sent as plain http, or nil.
    /// Dispatcharr builds absolute redirect URLs (an in-progress recording, a
    /// session) from the scheme it trusts, so behind a TLS proxy it does not
    /// trust they come back http:// although the user only reaches it over
    /// https, and dropping the sign-in there broke those servers. The app
    /// tolerates what the server sends: when the original request and the
    /// one redirected (`previous`) are https, the target is the same host,
    /// and it is http on the default port 80 or on the https request's own
    /// port, the hop is followed as https on the original request's port.
    /// Nil for any other downgrade. As on Android, a server that keeps
    /// answering with its own http form ends at the transport's redirect
    /// limit, still over https.
    static func tlsUpgraded(_ next: URL?, previous: URL?, original: URL?) -> URL? {
        let prior = previous ?? original
        guard let next, let original, let prior,
              original.scheme?.lowercased() == "https", prior.scheme?.lowercased() == "https",
              next.scheme?.lowercased() == "http",
              let host = next.host?.lowercased(), !host.isEmpty,
              host == original.host?.lowercased(), host == prior.host?.lowercased(),
              let targetPort = effectivePort(next), let priorPort = effectivePort(prior),
              targetPort == 80 || targetPort == priorPort,
              var upgraded = URLComponents(url: next, resolvingAgainstBaseURL: false) else { return nil }
        upgraded.scheme = "https"
        let originalPort = effectivePort(original) ?? 443
        upgraded.port = originalPort == 443 ? nil : originalPort
        guard let url = upgraded.url, keepsSignIn(next: url, previous: prior, original: original) else { return nil }
        return url
    }

    /// The request to follow for one hop. `next` is the request the transport
    /// built, `previous` the request that was redirected (URLSession's
    /// `task.currentRequest`), `original` the request the app sent first. A
    /// kept hop gets the original sign-in copied back; a same-host downgrade
    /// from an all-https chain is followed as https (`tlsUpgraded`) with it; a
    /// dropped hop has it removed, and so does every hop after a drop. Nil
    /// means stop at the redirect, so the caller gets the 3xx as its answer:
    /// that happens when a dropped hop would still re-send a body.
    static func redirect(_ next: URLRequest, previous: URLRequest?, original: URLRequest?) -> URLRequest? {
        var out = next
        let previousURL = previous?.url ?? original?.url
        if carriesSignIn(previous ?? original, of: original) {
            if hasSignIn(original),
               let upgraded = tlsUpgraded(next.url, previous: previousURL, original: original?.url) {
                out.url = upgraded
                copySignIn(from: original, to: &out)
                return out
            }
            if keepsSignIn(next: next.url, previous: previousURL, original: original?.url) {
                copySignIn(from: original, to: &out)
                return out
            }
        }
        if next.httpBody != nil || next.httpBodyStream != nil { return nil }
        for name in signInHeaders { out.setValue(nil, forHTTPHeaderField: name) }
        return out
    }

    private static func copySignIn(from original: URLRequest?, to request: inout URLRequest) {
        for name in signInHeaders {
            if let value = original?.value(forHTTPHeaderField: name) {
                request.setValue(value, forHTTPHeaderField: name)
            }
        }
    }
}

/// Stateless redirect delegate for requests whose session has no redirect
/// handling of its own: pass it as the task delegate (`data(for:delegate:)`,
/// `download(for:delegate:)`, `bytes(for:delegate:)`, or `task.delegate`
/// before resume) or as the session delegate of a dedicated session.
/// URLSession asks a task delegate before the session's delegate and
/// forwards whatever it does not implement, so data delivery is untouched.
final class RedirectAuthGuard: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = RedirectAuthGuard()

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(RedirectAuthPolicy.redirect(request, previous: task.currentRequest,
                                                      original: task.originalRequest))
    }
}
