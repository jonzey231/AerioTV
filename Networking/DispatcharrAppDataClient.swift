//  DispatcharrAppDataClient.swift
//  Aerio
//
//  Dispatcharr Sync transport: the per-user App Data endpoints
//  (Dispatcharr apps/accounts, "users/me/app-data/"), called exactly as the
//  Android DispatcharrClient.appData* and DispatcharrSyncManager fetch and
//  put paths call them:
//    GET    /api/accounts/users/me/app-data/        keys and sizes ({"apps":[{"key","bytes"}]})
//    GET    /api/accounts/users/me/app-data/<key>/  one stored value (404 key_not_found)
//    PUT    /api/accounts/users/me/app-data/<key>/  full replace (413 value_too_large /
//                                                    total_too_large, 409 max_apps)
//    DELETE /api/accounts/users/me/app-data/<key>/  the key migrations only
//    GET    /api/accounts/users/me/                 the signed-in username, which names the key
//  Auth is the DispatcharrAPI the app already builds for Direct Connect
//  (same headers, same 401 recovery via dataWithJWTRetry, which also covers
//  Android's "take the current credential and try once more").
//
//  Size caps: like Android there is no byte guard before a PUT; the full
//  value goes up and a 413 walks the DsyncV2.TRIMS sequence one step per
//  retry. Logs carry the App Data key name, byte counts, and statuses only;
//  never a body, URL, API key, or token.
//
//  Not wired into any app flow yet (Dispatcharr Sync part 1 of 5).

import Foundation

struct DispatcharrAppDataClient {
    let api: DispatcharrAPI

    /// One App Data response: HTTP status, the server's `code` on an error, and the body.
    struct AppDataResult: Sendable {
        let status: Int
        let code: String?
        let body: Data?
        var ok: Bool { (200...299).contains(status) }
    }

    static let collectionPath = "/api/accounts/users/me/app-data/"
    static func keyPath(_ key: String) -> String { collectionPath + key + "/" }

    // MARK: Raw calls (nil = network failure)

    /// GET /api/accounts/users/me/app-data/ (keys and sizes).
    func appDataList() async -> AppDataResult? { await send("GET", Self.collectionPath, body: nil) }

    /// GET /api/accounts/users/me/app-data/<key>/.
    func appDataGet(_ key: String) async -> AppDataResult? { await send("GET", Self.keyPath(key), body: nil) }

    /// PUT /api/accounts/users/me/app-data/<key>/ with the compact JSON [body] (full replace).
    func appDataPut(_ key: String, body: String) async -> AppDataResult? { await send("PUT", Self.keyPath(key), body: Data(body.utf8)) }

    /// DELETE /api/accounts/users/me/app-data/<key>/.
    func appDataDelete(_ key: String) async -> AppDataResult? { await send("DELETE", Self.keyPath(key), body: nil) }

    /// GET /api/accounts/users/me/: the username the App Data key is named for
    /// (DsyncKeyName). Nil on any failure; the caller retries on the next pull.
    func username() async -> String? {
        guard let r = await send("GET", "/api/accounts/users/me/", body: nil), r.ok else { return nil }
        let name = r.body.flatMap(DsyncJSONParser.parse)?.asObject?["username"]?.asStr ?? ""
        return name.isEmpty ? nil : name
    }

    private func send(_ method: String, _ path: String, body: Data?) async -> AppDataResult? {
        guard let url = try? api.appDataURL(path: path) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        api.appDataHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        if let body { request.httpBody = body }
        guard let (data, response) = try? await api.dataWithJWTRetry(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        let ok = (200...299).contains(http.statusCode)
        let code = ok ? nil : DsyncJSONParser.parse(data)?.asObject?["code"]?.asStr
        return AppDataResult(status: http.statusCode, code: code, body: data)
    }

    // MARK: List (DispatcharrSyncManager.pull)

    enum ListOutcome: Sendable {
        /// 5xx or no response: try again later.
        case failed
        /// 401 or 403: paused for this profile.
        case paused(Int)
        /// Any other non-2xx.
        case rejected(Int)
        /// Server sizes by App Data key name.
        case ok([String: Int64])
    }

    func list(reason: String) async -> ListOutcome {
        let r = await appDataList()
        guard let r, r.status < 500 else {
            debugLog("[DSYNC] list failed status=\(r.map { String($0.status) } ?? "network") (\(reason))")
            return .failed
        }
        if r.status == 401 || r.status == 403 {
            debugLog("[DSYNC] list status=\(r.status); paused for this profile")
            return .paused(r.status)
        }
        guard r.ok else {
            debugLog("[DSYNC] list status=\(r.status) code=\(r.code ?? "null")")
            return .rejected(r.status)
        }
        var sizes: [String: Int64] = [:]
        for el in r.body.flatMap(DsyncJSONParser.parse)?.asObject?["apps"]?.asArray ?? [] {
            guard let o = el.asObject, let name = o["key"]?.asStr else { continue }
            sizes[name] = o["bytes"]?.asLong ?? 0
        }
        return .ok(sizes)
    }

    // MARK: Fetch one bucket (DispatcharrSyncManager.fetchBucket)

    enum Fetched: Sendable {
        case absent
        case failed
        case malformed
        case tooNew(Int)
        case got(DsyncV2.Bucket, bytes: Int)
    }

    func fetchBucket(_ wire: String) async -> Fetched {
        let r = await appDataGet(wire)
        guard let r, r.status < 500 else {
            debugLog("[DSYNC] get \(wire) status=\(r.map { String($0.status) } ?? "network")")
            return .failed
        }
        if r.status == 404 { return .absent }
        guard r.ok else {
            debugLog("[DSYNC] get \(wire) status=\(r.status) code=\(r.code ?? "null")")
            return .failed
        }
        guard let raw = r.body.flatMap(DsyncJSONParser.parse)?.asObject else {
            debugLog("[DSYNC] malformed \(wire)")
            return .malformed
        }
        switch DsyncV2.decode(raw) {
        case .ok(let bucket): return .got(bucket, bytes: r.body?.count ?? 0)
        case .tooNew(let v):
            debugLog("[DSYNC] skip \(wire) v\(v) > v\(DsyncV2.SCHEMA)")
            return .tooNew(v)
        case .malformed:
            debugLog("[DSYNC] malformed \(wire)")
            return .malformed
        }
    }

    // MARK: Put one bucket (DispatcharrSyncManager.put and the 413 loop)

    enum PutStatus: Sendable { case ok, retry, tooLarge, full, auth, rejected }

    /// One PUT of [value] for the category [key]; the status line names both.
    func put(_ wire: String, key: DsyncKey, value: DsyncObject) async -> (PutStatus, AppDataResult?) {
        let body = DsyncJSONEncoder.encode(value)
        let bytes = body.utf8.count
        let r = await appDataPut(wire, body: body)
        debugLog("[DSYNC] put \(wire) (\(key.suffix)) bytes=\(bytes) status=\(r.map { String($0.status) } ?? "network")\(r?.code.map { " code=\($0)" } ?? "")")
        guard let r, r.status < 500 else { return (.retry, r) }
        if r.ok { return (.ok, r) }
        switch r.status {
        case 413: return (.tooLarge, r)
        case 409: return (.full, r)
        case 401, 403: return (.auth, r)
        default: return (.rejected, r)
        }
    }

    /// The next 413 trim at or after [from]; the trimmed value and the step to try after it.
    static func nextTrim(_ value: DsyncObject, from: Int) -> (DsyncObject, Int)? {
        var i = from
        while i < DsyncV2.TRIMS.count {
            let t = DsyncV2.applyTrim(value, i)
            let label = DsyncV2.TRIMS[i].label
            i += 1
            if let t, t != value {
                debugLog("[DSYNC] 413: trimmed \(label)")
                return (t, i)
            }
        }
        return nil
    }

    /// PUT with the 413 trim loop: returns the final status and the value
    /// the server accepted (or the last one tried).
    func putTrimming(_ wire: String, key: DsyncKey, value: DsyncObject) async -> (PutStatus, DsyncObject) {
        var v = value
        var step = 0
        while true {
            let (s, _) = await put(wire, key: key, value: v)
            guard s == .tooLarge else { return (s, v) }
            guard let next = Self.nextTrim(v, from: step) else {
                debugLog("[DSYNC] \(wire) still too large after every trim; stopped until the next change")
                return (.tooLarge, v)
            }
            v = next.0
            step = next.1
        }
    }
}

/// The per-category pull lines, copied from DispatcharrSyncManager.kt, for
/// the pull and apply path (parts 2 to 5). Counts and key names only.
enum DsyncLogLines {
    static func pullApplied(_ key: DsyncKey, bytes: Int) -> String { "[DSYNC] pull \(key.suffix) bytes=\(bytes) applied" }
    static func pullNotNewer(_ key: DsyncKey, bytes: Int) -> String { "[DSYNC] pull \(key.suffix) bytes=\(bytes) not newer" }
    static func pullKeptLocal(_ key: DsyncKey, bytes: Int) -> String { "[DSYNC] pull \(key.suffix) bytes=\(bytes) kept local (local change newer)" }
    static func pullMergedLocal(_ key: DsyncKey, bytes: Int) -> String { "[DSYNC] pull \(key.suffix) bytes=\(bytes) merged with local change" }
    static func pullMergedRow(_ key: DsyncKey, bytes: Int) -> String { "[DSYNC] pull \(key.suffix) bytes=\(bytes) merged per row" }
    static func pullSeeding(_ key: DsyncKey, bytes: Int) -> String { "[DSYNC] pull \(key.suffix) bytes=\(bytes) empty on server, first pull: seeding from local" }
    static func pullChoiceApplied(_ key: DsyncKey, bytes: Int) -> String { "[DSYNC] pull \(key.suffix) bytes=\(bytes) applied (setup choice, stamp not newer)" }
    static func pullDone(reason: String, read: Int, server: Int) -> String { "[DSYNC] pull done (\(reason)) read=\(read) server=\(server)" }
    static func malformedCategory(_ key: DsyncKey) -> String { "[DSYNC] malformed category \(key.suffix)" }
}
