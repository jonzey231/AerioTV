//
//  HTTPRouter.swift
//  Aerio
//
//  v1.6.10 — Routes outbound HTTP requests to the correct transport.
//  URLSession is the default for every request and remains the right
//  choice for TLS, IP literals, and TLDs that aren't on iOS's HSTS
//  preload list. Plain-HTTP requests against HSTS-preloaded TLDs
//  (`.app`, `.dev`, `.page`, `.new`, …) get redirected to
//  `NWHTTPClient`, which uses Network.framework / NWConnection
//  underneath ATS — the only path that actually reaches those
//  servers in plain HTTP.
//
//  Why this shim exists, condensed:
//    • iOS's HSTS preload list is inherited from Chromium and baked
//      into every system release. ~50 TLDs are force-upgraded to
//      HTTPS at the URL-loading layer regardless of
//      `NSAllowsArbitraryLoads`.
//    • Many IPTV reseller panels run on `.app` (Cloudflare-friendly
//      registrar pricing, branding) without TLS on a non-standard
//      port (`http://example.app:8080`). Competitor IPTV apps
//      (TiviMate, iMPlayer, Dispatcharr's web UI) reach those
//      panels by going below URLSession.
//    • Apple DTS confirmed (Quinn): ATS / HSTS apply only to
//      URLSession. Network.framework is explicitly outside that
//      enforcement.
//
//  Routing rules:
//    1. https://  → URLSession. NWHTTPClient handles TLS too, but
//       URLSession's TLS stack is more battle-tested (HTTP/2, ALPN,
//       session resumption, certificate pinning hooks). No reason
//       to bypass it.
//    2. http://<ip>  → URLSession. ATS doesn't HSTS-preload IP
//       literals, and many home/LAN setups serve plain HTTP from
//       IPs. URLSession is fine here.
//    3. http://<host on preloaded TLD>  → NWHTTPClient. URLSession
//       refuses these regardless of Info.plist; this is the whole
//       reason the router exists.
//    4. http://<other domain>  → URLSession. Info.plist
//       `NSAllowsArbitraryLoads` covers this case correctly.
//

import Foundation

/// Drop-in URLSession replacement that picks the right transport per
/// request. Call sites in StreamingAPIs use this exclusively so verify,
/// EPG, channel-load, VOD, and any future endpoint inherit the routing
/// rules without per-call awareness.
enum HTTPRouter {

    // MARK: - Public API

    static func data(from url: URL,
                     using session: URLSession = .shared) async throws -> (Data, URLResponse) {
        // Hard route: HSTS-preloaded TLD plain HTTP — URLSession will
        // always refuse, so go straight to NWConnection.
        if shouldUseNWConnection(for: url) {
            return try await NWHTTPClient.data(from: url)
        }
        // Soft route: URLSession first; if it fails with a transport
        // error that NWConnection might handle differently, try
        // NWConnection as a fallback before giving up. Covers cases
        // where URLSession's HSTS cache, an in-process proxy, or
        // some iOS-internal restriction blocks a host that NWConnection
        // can still reach. v1.6.10 second-pass fix for IPTV reseller
        // panels that work in Dispatcharr (server-side requests) but
        // were getting NSURLErrorCannotConnectToHost in Aerio.
        do {
            return try await session.data(from: url)
        } catch let error as NSError where shouldFallbackToNWConnection(error: error) {
            debugLog("HTTPRouter: URLSession failed for \(url.absoluteString) (code=\(error.code) \(error.localizedDescription)) → NWConnection fallback")
            do {
                return try await NWHTTPClient.data(from: url)
            } catch {
                // NWConnection ALSO failed. Throw the URLSession error;
                // it's typically more localized / actionable.
                debugLog("HTTPRouter: NWConnection fallback ALSO failed: \(error)")
                throw error  // re-throws inner (NWConnection) error — see below
            }
        }
    }

    static func data(for request: URLRequest,
                     using session: URLSession = .shared) async throws -> (Data, URLResponse) {
        if let url = request.url, shouldUseNWConnection(for: url) {
            return try await NWHTTPClient.data(for: request)
        }
        do {
            return try await session.data(for: request)
        } catch let error as NSError where shouldFallbackToNWConnection(error: error) {
            let urlStr = request.url?.absoluteString ?? "<unknown>"
            debugLog("HTTPRouter: URLSession failed for \(urlStr) (code=\(error.code) \(error.localizedDescription)) → NWConnection fallback")
            do {
                return try await NWHTTPClient.data(for: request)
            } catch {
                debugLog("HTTPRouter: NWConnection fallback ALSO failed: \(error)")
                throw error
            }
        }
    }

    // MARK: - Routing decision

    /// Returns `true` when the request should bypass URLSession because
    /// iOS's HSTS preload list will refuse to send it as plain HTTP.
    static func shouldUseNWConnection(for url: URL) -> Bool {
        // Only plain http:// is gated by HSTS preload. https:// goes
        // through URLSession unconditionally.
        guard let scheme = url.scheme?.lowercased(), scheme == "http" else { return false }
        guard let host = url.host, !host.isEmpty else { return false }
        // IP literals are never HSTS-preloaded — URLSession is fine.
        if isIPLiteral(host) { return false }
        // Domain on preloaded TLD → NWConnection is the only way.
        return isHostOnPreloadedTLD(host)
    }

    /// Returns `true` when a URLSession failure looks transport-level
    /// (vs application-level like 404/auth). These are cases where
    /// retrying through NWConnection has a real chance of succeeding —
    /// URLSession sometimes refuses connections that the underlying
    /// network actually permits, due to its HSTS cache, ATS heuristics,
    /// or in-process state we can't introspect.
    private static func shouldFallbackToNWConnection(error: NSError) -> Bool {
        // Only react to URLSession's own NSURLErrorDomain.
        guard error.domain == NSURLErrorDomain else { return false }
        switch error.code {
        case NSURLErrorAppTransportSecurityRequiresSecureConnection, // -1022
             NSURLErrorCannotConnectToHost,                          // -1004
             NSURLErrorSecureConnectionFailed,                       // -1200
             NSURLErrorServerCertificateUntrusted,                   // -1202
             NSURLErrorServerCertificateHasBadDate,                  // -1201
             NSURLErrorServerCertificateNotYetValid,                 // -1204
             NSURLErrorServerCertificateHasUnknownRoot:              // -1203
            return true
        default:
            return false
        }
    }

    // MARK: - Host inspection

    /// Naive IPv4 / IPv6 detection. We only need to distinguish
    /// "domain that could be HSTS-preloaded" from "literal IP that
    /// can't be" — host syntax is sufficient.
    private static func isIPLiteral(_ host: String) -> Bool {
        // IPv6 literals arrive bracketed in URLs (`[::1]`); URL.host
        // strips brackets, so colon density catches them.
        if host.contains(":") { return true }
        // IPv4 dotted-quad: every component is digits-only.
        let parts = host.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { Int($0) != nil }
    }

    /// Returns true if `host`'s effective TLD is on iOS's HSTS preload
    /// list. We check the last label, which is sufficient for the
    /// gTLDs Google preloaded — they're all single-label.
    private static func isHostOnPreloadedTLD(_ host: String) -> Bool {
        guard let lastDot = host.lastIndex(of: ".") else { return false }
        let tld = host[host.index(after: lastDot)...].lowercased()
        return preloadedHSTSTLDs.contains(String(tld))
    }

    // MARK: - HSTS preload TLD list

    /// gTLDs Google preloaded into the HSTS list at the TLD level.
    /// These are baked into Chromium's preload list and inherited by
    /// every iOS release. The list barely changes — Google has
    /// stopped adding TLD-wide preloads — so a static set is fine.
    ///
    /// Source: Chromium `transport_security_state_static.json`,
    /// filtered to entries with `"include_subdomains": true` whose
    /// name has no dot. Cross-checked against
    /// https://hstspreload.org/.
    ///
    /// We intentionally do NOT include domain-level preloads
    /// (`facebook.com`, `paypal.com`, etc.) — those are individual
    /// sites and the entry would balloon to thousands. For our use
    /// case (IPTV resellers picking cheap gTLDs) the TLD-level list
    /// is the right granularity.
    static let preloadedHSTSTLDs: Set<String> = [
        // Google-owned gTLDs (preloaded as a set in 2017–2018)
        "app", "dev", "page", "new", "day",
        "foo", "gle", "esq", "fly", "rsvp",
        "eat", "ing", "meme", "phd", "prof", "boo",
        "dad", "channel", "nexus",
        // Misc Google brand TLDs
        "google", "gmail", "hangout", "meet", "play", "search", "youtube",
        "android", "chrome",
        // File-format gTLDs Google preloaded
        "zip", "mov",
        // Other corporate brand gTLDs that ended up on the list
        "bank", "insurance",
        "hotmail", "windows", "skype", "azure", "office", "bing", "xbox", "microsoft",
        "amazon", "audible", "fire", "imdb", "kindle", "prime", "silk", "zappos",
        "fujitsu"
    ]
}
