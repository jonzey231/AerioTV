import SwiftUI
import SwiftData

@MainActor
@Observable
final class ServerConnectionViewModel {
    var name: String = ""
    var serverType: ServerType = .dispatcharrAPI
    var baseURL: String = ""      // M3U URL for m3uPlaylist, server base URL for xtreamCodes
    var username: String = ""
    var password: String = ""
    var apiKey: String = ""       // Dispatcharr personal API key
    var dispatcharrXMLTVURL: String = "" // Optional XMLTV override for Dispatcharr (empty = use API)
    var epgURL: String = ""       // Optional EPG URL for m3uPlaylist
    var localURL: String = ""     // LAN URL (e.g. http://192.168.1.10:9191)
    var localEPGURL: String = ""  // Local EPG URL for M3U when on LAN

    var isVerifying: Bool = false
    var verificationSuccess: Bool = false
    var verificationError: String? = nil
    var verifiedServerName: String? = nil
    /// v1.6.20: auto-detected Dispatcharr auth header shape (X-API-Key
    /// only, dual, or bearer) discovered during `verifyConnection`.
    /// The Add/Edit Server view persists this onto the new
    /// `ServerConnection.dispatcharrAuthMode` field so subsequent API
    /// calls and stream playback use the same shape — Aerio doesn't
    /// have to re-detect on every cold start, and Dispatcharr
    /// deployments that reject `X-API-Key`-alone with HTTP 401
    /// (the bug three users hit on private deployments in v1.6.19)
    /// stay connected after the initial discovery.
    var discoveredDispatcharrAuthMode: DispatcharrAuthHeaderMode? = nil

    var isFormValid: Bool {
        guard !name.isEmpty, !baseURL.isEmpty else { return false }
        switch serverType {
        case .m3uPlaylist:
            return !baseURL.isEmpty
        case .xtreamCodes:
            return !username.isEmpty && !password.isEmpty
        case .dispatcharrAPI:
            return !apiKey.isEmpty
        }
    }

    func verifyConnection() async {
        guard isFormValid else { return }
        isVerifying = true
        verificationError = nil
        verificationSuccess = false
        verifiedServerName = nil
        discoveredDispatcharrAuthMode = nil

        // Silent one-shot retry. Some reverse-proxy / LB setups (Cloudflare
        // Tunnel, Traefik with cold upstreams, nginx with slow_start) return
        // the login SPA shell or a transient 5xx on the first hit and serve
        // real JSON on the next. Retrying once invisibly makes a valid setup
        // "just work" instead of the user having to tap Test Connection twice.
        //
        // We deliberately retry on ALL errors: the 400ms extra wait on a
        // genuinely-bad configuration is a tiny price compared to the
        // frustration of a false-negative on a good one.
        do {
            try await runVerifyAttempt()
        } catch {
            try? await Task.sleep(nanoseconds: 400_000_000)
            do {
                try await runVerifyAttempt()
            } catch let error as APIError {
                verificationError = error.errorDescription
            } catch {
                verificationError = error.localizedDescription
            }
        }

        isVerifying = false
    }

    /// One verify pass. Throws on failure so `verifyConnection()` can decide
    /// whether to retry. On success, sets `verifiedServerName` +
    /// `verificationSuccess` directly.
    ///
    /// v1.6.9 hot-fix: when the user types an `http://` URL whose
    /// domain is on iOS's HSTS preload list (a list inherited from
    /// Chromium that gets baked into every iOS release), ATS blocks
    /// the connection with `NSURLErrorAppTransportSecurityRequiresSecureConnection`
    /// (-1022) **regardless of `NSAllowsArbitraryLoads`** — the
    /// global Info.plist exemption beats the default ATS posture
    /// but doesn't override HSTS preloading for specific domains.
    /// IP-literal URLs (e.g. `http://192.168.1.10:9191`) work
    /// because HSTS rules are domain-scoped and don't match
    /// IP literals. So when verify gets the -1022 error against an
    /// `http://<domain>` URL, we silently retry with the URL upgraded
    /// to `https://`. Most reseller backends serve both schemes
    /// (Cloudflare in front, automatic Let's Encrypt, etc.); the
    /// HTTPS retry just works. We then mutate `baseURL` to the
    /// upgraded scheme so the saved server uses HTTPS for every
    /// subsequent request, not just verify.
    private func runVerifyAttempt() async throws {
        switch serverType {
        case .m3uPlaylist:
            // Verify M3U by fetching and checking for #EXTM3U header.
            // Wrapped through `withATSScheme­Upgrade` so domain-HTTP
            // playlists blocked by HSTS auto-promote to HTTPS.
            try await withATSSchemeUpgrade(originalURL: baseURL) { url in
                guard let parsed = URL(string: url) else { throw APIError.invalidURL }
                // v1.6.10: routed through HTTPRouter so M3U URLs hosted
                // on HSTS-preloaded TLDs (`.app`, `.dev`, …) reach
                // their servers via NWConnection rather than being
                // blocked at the URLSession HSTS layer.
                let (data, response) = try await HTTPRouter.data(from: parsed)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    throw APIError.serverError((response as? HTTPURLResponse)?.statusCode ?? -1)
                }
                guard let content = String(data: data, encoding: .utf8),
                      content.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") else {
                    throw APIError.decodingError(NSError(domain: "M3U", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "URL does not appear to be a valid M3U playlist"]))
                }
                let channelCount = content.components(separatedBy: "#EXTINF:").count - 1
                self.verifiedServerName = "\(channelCount) channels found"
                self.verificationSuccess = true
            }

        case .xtreamCodes:
            try await withATSSchemeUpgrade(originalURL: normalizedURL) { url in
                let api = XtreamCodesAPI(baseURL: url, username: self.username, password: self.password)
                let info = try await api.verifyConnection()
                self.verifiedServerName = info.userInfo.username
                self.verificationSuccess = true
            }

        case .dispatcharrAPI:
            try await withATSSchemeUpgrade(originalURL: normalizedURL) { url in
                // Default authMode `.xapikey` — v1.6.16+ behavior.
                // verifyConnection auto-falls-back to `.both` and
                // `.bearer` on HTTP 401, returning the working shape
                // in `info.discoveredAuthMode` so the caller can
                // persist it on the SwiftData model.
                let api = DispatcharrAPI(baseURL: url, auth: .apiKey(self.apiKey))
                let info = try await api.verifyConnection()
                // Prefer a friendly name if provided; otherwise show version.
                if let name = info.serverName, !name.isEmpty {
                    self.verifiedServerName = name
                } else {
                    self.verifiedServerName = "v\(info.version ?? "unknown")"
                }
                self.discoveredDispatcharrAuthMode = info.discoveredAuthMode
                self.verificationSuccess = true
            }
        }
    }

    /// Runs `attempt(url)` against the original URL first; if iOS's
    /// HSTS layer blocks it with `NSURLErrorAppTransportSecurityRequiresSecureConnection`,
    /// retries with the URL upgraded to `https://` and — on success
    /// — mutates `baseURL` so the persisted record uses the working
    /// scheme. v1.6.9 fix for `http://<domain>` Xtream / Dispatcharr
    /// URLs blocked by iOS's HSTS preload list. See
    /// `runVerifyAttempt` doc for the full rationale.
    ///
    /// Only swaps `http://` → `https://`. URLs that already start
    /// with `https://`, `file://`, or anything else are passed
    /// through unchanged. IP-literal HTTP URLs are also passed
    /// through (they're never HSTS-blocked, so the retry would be
    /// pointless and could break setups where the local server only
    /// serves HTTP).
    private func withATSSchemeUpgrade(originalURL: String,
                                      attempt: (String) async throws -> Void) async throws {
        do {
            try await attempt(originalURL)
        } catch let error as NSError where shouldRetryWithHTTPS(error: error) {
            // Only auto-upgrade real http:// domain URLs. IP literals
            // can't be HSTS-preloaded so falling here means something
            // else is wrong — bubble the original error up.
            guard let upgraded = httpsUpgradedURL(originalURL) else { throw error }
            debugLog("ATS-UPGRADE: \(originalURL) failed (\(error.code) \(error.localizedDescription)) → retrying as \(upgraded)")
            do {
                try await attempt(upgraded)
                debugLog("ATS-UPGRADE: \(upgraded) succeeded → persisting upgraded scheme")
                // Persist the working scheme so the saved record + every
                // subsequent runtime API call uses HTTPS automatically.
                // For .m3uPlaylist `baseURL` is the M3U URL; for the API
                // types it's the server base. Both store in the same
                // field, so a single assignment is sufficient.
                if upgraded != originalURL {
                    self.baseURL = upgraded
                }
            } catch {
                debugLog("ATS-UPGRADE: HTTPS retry ALSO failed: \(error)")
                // HTTPS retry also failed. Bubble whichever error is
                // more informative — usually the HTTPS error has the
                // real reason (e.g. cert-mismatch, server-down).
                throw error
            }
        }
    }

    /// True when the failure looks like "the server doesn't speak plain
    /// HTTP on the URL the user typed" — in which case retrying with
    /// HTTPS has a real chance of succeeding. Covers two scenarios:
    ///   • -1022 ATS-required-secure: the original v1.6.9 case. iOS
    ///     refuses the HTTP attempt outright.
    ///   • -1004 cannot-connect-to-host: server is HTTPS-only (only
    ///     listens on 443, not 80). Common with Cloudflare-fronted
    ///     panels — the front-end serves HTTPS and never opens 80.
    /// We deliberately do NOT include -1003 (DNS fail) or -1006 (cannot
    /// resolve host) — those mean the host is unreachable at the name
    /// layer, and HTTPS won't help. Same for genuine timeouts (-1001):
    /// HTTPS retry burns another 20s without any reason to expect a
    /// different outcome.
    private func shouldRetryWithHTTPS(error: NSError) -> Bool {
        switch error.code {
        case NSURLErrorAppTransportSecurityRequiresSecureConnection,
             NSURLErrorCannotConnectToHost:
            return true
        default:
            return false
        }
    }

    /// Returns `originalURL` with the scheme swapped from `http://`
    /// to `https://` when the host is a domain (not an IP literal).
    /// Returns `nil` for any URL that shouldn't auto-upgrade — IP
    /// literals, already-HTTPS URLs, or unparseable strings.
    private func httpsUpgradedURL(_ originalURL: String) -> String? {
        guard originalURL.hasPrefix("http://") else { return nil }
        guard let components = URLComponents(string: originalURL),
              let host = components.host,
              !host.isEmpty else { return nil }
        // Skip IP literals. ATS / HSTS don't apply to them, so the
        // -1022 error here came from somewhere else and an upgrade
        // would mask the real cause.
        if isIPLiteral(host) { return nil }
        var upgraded = components
        upgraded.scheme = "https"
        return upgraded.url?.absoluteString
    }

    /// Naive IPv4 / IPv6 detection. We only need to distinguish
    /// "domain that could be HSTS-preloaded" from "literal IP that
    /// can't be" — the host syntax is sufficient for that. Doesn't
    /// validate the address itself.
    private func isIPLiteral(_ host: String) -> Bool {
        // IPv6 literals arrive bracketed in URLs (`[::1]`); URLComponents
        // strips the brackets in `host`, so detect via colon density.
        if host.contains(":") { return true }
        // IPv4 dotted-quad: every component is digits-only.
        let parts = host.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { Int($0) != nil }
    }

    func buildServerConnection() -> ServerConnection {
        let server = ServerConnection(
            name: name,
            type: serverType,
            baseURL: serverType == .m3uPlaylist ? baseURL : normalizedURL,
            username: username,
            password: password,
            apiKey: apiKey,
            epgURL: epgURL,
            localURL: localURL,
            localEPGURL: localEPGURL
        )
        server.dispatcharrXMLTVURL = dispatcharrXMLTVURL
        // v1.6.20: persist the auth header shape that worked during
        // verifyConnection so subsequent API calls and stream playback
        // skip re-discovery and immediately speak the right shape.
        // Empty string (the model default) means "haven't verified
        // yet"; ServerConnection.dispatcharrHeaderMode falls back to
        // `.both` in that case for back-compat with stream-playback
        // header construction.
        if let mode = discoveredDispatcharrAuthMode {
            server.dispatcharrAuthMode = mode.rawValue
        }
        return server
    }

    func reset() {
        name = ""
        baseURL = ""
        username = ""
        password = ""
        apiKey = ""
        dispatcharrXMLTVURL = ""
        epgURL = ""
        localURL = ""
        localEPGURL = ""
        isVerifying = false
        verificationSuccess = false
        verificationError = nil
        verifiedServerName = nil
        discoveredDispatcharrAuthMode = nil
    }

    private var normalizedURL: String {
        var url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.hasSuffix("/") { url = String(url.dropLast()) }
        if !url.hasPrefix("http://") && !url.hasPrefix("https://") {
            url = "http://" + url
        }
        return url
    }
}
