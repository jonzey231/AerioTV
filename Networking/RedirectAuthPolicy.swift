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
//  A hop that loses the sign-in but would still re-send a request body (the
//  Direct Connect login's password, a sync upload) is not followed at all.
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

    /// The verdict for one hop to `next`, checked against the URL that
    /// answered with the redirect (`previous`) AND the request the app built
    /// (`original`): a chain that leaves the host or port and comes back
    /// never gets the sign-in again.
    static func keepsSignIn(next: URL?, previous: URL?, original: URL?) -> Bool {
        keepsSignIn(from: previous ?? original, to: next) && keepsSignIn(from: original ?? previous, to: next)
    }

    /// The request to follow for one hop. `next` is the request the transport
    /// built, `previous` the URL that answered with the redirect, `original`
    /// the request the app sent first. A kept hop gets the original sign-in
    /// copied back; a dropped hop has it removed. Nil means stop at the
    /// redirect, so the caller gets the 3xx as its answer: that happens when
    /// a dropped hop would still re-send a body.
    static func redirect(_ next: URLRequest, previous: URL?, original: URLRequest?) -> URLRequest? {
        var out = next
        if keepsSignIn(next: next.url, previous: previous, original: original?.url) {
            for name in signInHeaders {
                if let value = original?.value(forHTTPHeaderField: name) {
                    out.setValue(value, forHTTPHeaderField: name)
                }
            }
            return out
        }
        if next.httpBody != nil || next.httpBodyStream != nil { return nil }
        for name in signInHeaders { out.setValue(nil, forHTTPHeaderField: name) }
        return out
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
        completionHandler(RedirectAuthPolicy.redirect(request,
                                                      previous: response.url ?? task.currentRequest?.url,
                                                      original: task.originalRequest))
    }
}
