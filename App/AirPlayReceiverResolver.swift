#if os(iOS)
import AVFoundation
import AVKit
import Foundation
import Network

// MARK: - AirPlay receiver identification (rebuilt 2026-09-24 from the 2026-09-21 log)

/// What the phone knows about the AirPlay receiver the audio session is
/// routed to. Built from the route (`AVAudioSession.currentRoute`) and the
/// `_airplay._tcp` Bonjour TXT record of the matching advertiser.
struct AirPlayReceiver: Equatable, Sendable {
    /// The route's port name, RAW (a Roku advertises `Roku Express 4K `
    /// with a trailing space; the log keeps it verbatim).
    let name: String
    /// False when the route only ever said "AirPlay" (or nothing).
    let nameResolved: Bool
    /// `uid#<fnv1a hex>/<uid length>`, nil when the route carried no uid.
    let uidHash: String?
    /// The route uid carries a MAC address (AirPlay 2 uids do).
    let macPresent: Bool
    /// TXT `model` (`AppleTV14,1`, `Mac16,12`, `3941X2`), nil when unknown.
    let model: String?
    let isApple: Bool

    /// The generic receiver used when nothing could be resolved.
    static let unknown = AirPlayReceiver(name: "AirPlay", nameResolved: false, uidHash: nil,
                                         macPresent: false, model: nil, isApple: false)

    /// Name for the card and the lock screen: the resolved receiver name,
    /// nil while only the generic "AirPlay" label is known (so the UI never
    /// reads "AirPlay · AirPlay").
    var displayName: String? {
        guard nameResolved else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : name
    }

    /// Audio-only receivers (HomePod, AirPort Express) never get the idle
    /// route card: there is no screen to start a channel on.
    var isAudioOnly: Bool {
        guard let model else { return false }
        return model.hasPrefix("AudioAccessory") || model.hasPrefix("AirPort")
    }

    /// Plan section 3: AAC-LC stereo for the receiver, or passthrough.
    func wantsAAC(mode: AirPlayAudioMode) -> Bool {
        switch mode {
        case .passthrough: return false
        case .stereo: return true
        // Device log 2026-09-25 16:22:37 / 16:25:02: the Living Room
        // Apple TV was still unresolved when the plan was decided and got
        // AAC (-> the variant failure). An unresolved receiver (no TXT
        // model) now defaults to passthrough: Apple receivers are the
        // common case, and a Roku on passthrough at worst plays without
        // audio until the late resolve re-plans it to AAC.
        case .automatic: return model != nil && !isApple
        }
    }

    /// `[AVP-AIRPLAY] receiver '...' ...` (plan section 2). The parenthetical
    /// is omitted when the route had no uid (the Roku lines).
    func logLine(mode: AirPlayAudioMode) -> String {
        var line = "[AVP-AIRPLAY] receiver '\(name)'"
        if let uidHash {
            line += " (\(nameResolved ? "name resolved" : "name UNRESOLVED"), \(uidHash)"
            if macPresent { line += ", mac present" }
            line += ")"
        }
        line += " model=\(model ?? "unknown") apple=\(isApple)"
        line += wantsAAC(mode: mode) ? " -> audio AAC-LC stereo" : " -> audio passthrough"
        line += " (mode: \(mode.logLabel))"
        return line
    }

    /// Apple receivers keep AC-3 passthrough (a MacBook Air was apple=true
    /// on 09-21). Unknown model -> false.
    static func isAppleModel(_ model: String?) -> Bool {
        guard let model else { return false }
        return ["AppleTV", "AudioAccessory", "Mac", "iPad", "iPhone"].contains { model.hasPrefix($0) }
    }

    /// Route names that carry no receiver identity: nil, empty, "AirPlay",
    /// and any other name starting "AirPlay" (device log 2026-09-25: the
    /// card once read "AirPlayHandoffDevice", an iOS placeholder route name
    /// during handoff). A real receiver named "AirPlay..." is still
    /// resolved when its Bonjour TXT record matches (`resolveNow`).
    static func isGenericName(_ name: String?) -> Bool {
        guard let name else { return true }
        let t = name.trimmingCharacters(in: .whitespaces)
        return t.isEmpty || t.hasPrefix("AirPlay")
    }
}

/// Resolves the current AirPlay route to an `AirPlayReceiver`: a live
/// `_airplay._tcp` browse keeps a TXT cache per advertised name, and the
/// route's port name / uid pick the entry. Needs `_airplay._tcp` in
/// NSBonjourServices (else the browse fails -65555 NoAuth).
@MainActor
final class AirPlayReceiverResolver {

    static let shared = AirPlayReceiverResolver()

    /// Re-read offsets for a route whose name is still nil / "AirPlay"
    /// (plan open question 9: only the end result was ever logged).
    static let retryLadder: [TimeInterval] = [0.25, 0.5, 1, 2, 4, 8]

    private struct TXTEntry {
        let name: String
        let model: String?
        let deviceID: String?
        /// TXT `pi` / `psi` / `gid`: AirPlay 2 identifiers a route uid
        /// can carry when it has no MAC.
        let identifiers: [String]
        /// Every TXT key and value, for the unresolved-route detail line
        /// only. Held in memory; the log names matching KEYS, never values.
        let txt: [String: String]
    }

    private var browser: NWBrowser?
    private var cache: [String: TXTEntry] = [:]
    /// Browse state and last results time for the route detail line
    /// (2026-11-15: the route stayed "AirPlay" for an hour and the log
    /// could not say whether the browse was even returning results).
    private var browseState = "none"
    private var lastResultsAt: Date?
    private var loggedDetailSignatures: Set<String> = []
    private var restartedAfterFailure = false
    private var ladderToken = UUID()

    /// Fires with each newly resolved receiver (the monitor keeps it for
    /// the card and the lock screen).
    var onReceiverChange: ((AirPlayReceiver?) -> Void)?

    private init() {}

    // MARK: Bonjour

    func startBrowsing() {
        guard browser == nil else { return }
        // Incident 2026-09-25 14:04: this browse was still running (from the
        // launch probe) during a Google Cast session and failed with
        // DefunctConnection 5 s before the cast ingest dropped and the app
        // went silent. Browse only while an AirPlay output exists or a
        // handoff is resolving; everything else stops it (`stopBrowsing`).
        guard Self.currentAirPlayOutput() != nil || handoffInProgress else { return }
        let params = NWParameters()
        params.includePeerToPeer = false
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_airplay._tcp", domain: nil), using: params)
        b.browseResultsChangedHandler = { results, _ in
            var next: [String: TXTEntry] = [:]
            for result in results {
                guard case let .service(name, _, _, _) = result.endpoint else { continue }
                var model: String?
                var deviceID: String?
                var ids: [String] = []
                var all: [String: String] = [:]
                if case let .bonjour(txt) = result.metadata {
                    model = txt["model"]
                    deviceID = txt["deviceid"]
                    ids = ["pi", "psi", "gid"].compactMap { txt[$0] }.filter { $0.count >= 8 }
                    all = txt.dictionary
                }
                let key = name.trimmingCharacters(in: .whitespaces)
                next[key] = TXTEntry(name: key, model: model, deviceID: deviceID, identifiers: ids, txt: all)
            }
            Task { @MainActor in
                let resolver = AirPlayReceiverResolver.shared
                resolver.cache = next
                resolver.lastResultsAt = Date()
                resolver.checkLateResolution()
            }
        }
        b.stateUpdateHandler = { state in
            Task { @MainActor in
                let resolver = AirPlayReceiverResolver.shared
                let label = AirPlayReceiverResolver.stateLabel(state)
                if resolver.browseState != label {
                    debugLog("[AVP-AIRPLAY] receiver browse state: \(resolver.browseState) -> \(label)")
                    resolver.browseState = label
                }
                if case let .failed(error) = state { resolver.browseFailed(error) }
            }
        }
        browser = b
        browseState = "starting"
        lastResultsAt = nil
        b.start(queue: .main)
    }

    /// True while `resolveForHandoff` is waiting on a TXT record.
    private var handoffInProgress = false

    /// Stop the browse (no AirPlay route any more). Also re-arms the single
    /// failure restart for the next route. Incident 2026-09-25.
    func stopBrowsing() {
        lateWatch = false
        lastPublished = nil
        guard let b = browser else { return }
        browser = nil
        browseState = "stopped"
        restartedAfterFailure = false
        b.browseResultsChangedHandler = nil
        b.stateUpdateHandler = nil
        b.cancel()
    }

    private func browseFailed(_ error: NWError) {
        debugLog("[AVP-AIRPLAY] receiver browse failed: \(Self.describe(error))")
        // Incident 2026-09-25: the failure path must never block. Handlers
        // are detached before cancel so a late state update cannot re-enter,
        // and the restart is async, once, and only while a route exists.
        if let b = browser {
            browser = nil
            b.browseResultsChangedHandler = nil
            b.stateUpdateHandler = nil
            b.cancel()
        }
        // One restart after 1 s; after that the resolver falls back to the
        // route name alone.
        guard !restartedAfterFailure else { return }
        restartedAfterFailure = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            MainActor.assumeIsolated { AirPlayReceiverResolver.shared.startBrowsing() }
        }
    }

    /// `-65569: DefunctConnection` style, the dns_sd names for the codes a
    /// browse actually returns.
    static func describe(_ error: NWError) -> String {
        if case let .dns(code) = error {
            let names: [Int32: String] = [
                -65569: "DefunctConnection", -65555: "NoAuth", -65563: "ServiceNotRunning",
                -65570: "PolicyDenied", -65540: "BadParam", -65537: "Unknown",
            ]
            return "\(code): \(names[code] ?? "DNSServiceError")"
        }
        return "\(error)"
    }

    // MARK: Route

    /// The AirPlay output on the current route: raw port name and uid.
    static func currentAirPlayOutput() -> (name: String?, uid: String)? {
        guard let port = AVAudioSession.sharedInstance().currentRoute.outputs
            .first(where: { $0.portType == .airPlay }) else { return nil }
        return (port.portName, port.uid)
    }

    /// Resolve against the route as it stands now. nil when the route has
    /// no AirPlay output at all.
    func resolveNow() -> AirPlayReceiver? {
        guard let out = Self.currentAirPlayOutput() else { return nil }
        var rawName = out.name ?? "AirPlay"
        let trimmed = rawName.trimmingCharacters(in: .whitespaces)
        let uid = out.uid
        let mac = Self.macAddress(in: uid)
        // Name first (a real receiver named "AirPlay..." resolves here),
        // then uid / deviceid (device log 2026-09-25: the route said
        // "AirPlay" while the TXT cache already knew the Apple TV).
        var entry: TXTEntry? = trimmed.isEmpty ? nil : cache[trimmed]
        if entry == nil { entry = Self.matchByUID(uid, mac: mac, in: Array(cache.values)) }
        var nameResolved = !AirPlayReceiver.isGenericName(out.name)
        if let entry, !nameResolved || entry.name == trimmed {
            // A uid match names the receiver by its Bonjour service name.
            if !nameResolved { rawName = entry.name }
            nameResolved = true
        }
        let model = entry?.model
        return AirPlayReceiver(
            name: rawName,
            nameResolved: nameResolved,
            uidHash: uid.isEmpty ? nil : Self.uidHash(uid),
            macPresent: mac != nil,
            model: model,
            isApple: AirPlayReceiver.isAppleModel(model))
    }

    /// The tile's resolve before a handoff: waits up to `timeout` for the
    /// TXT record of the routed receiver (the 09-21 log shows the LAN
    /// start about 2 s after the loopback server came up), then returns
    /// what is known. Always non-nil while an AirPlay output exists.
    func resolveForHandoff(timeout: TimeInterval = 2) async -> AirPlayReceiver {
        handoffInProgress = true
        defer { handoffInProgress = false }
        startBrowsing()
        let deadline = Date().addingTimeInterval(timeout)
        var best = resolveNow() ?? .unknown
        while best.model == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 250_000_000)
            best = resolveNow() ?? best
        }
        if best.model == nil { lateWatch = true }
        if !best.nameResolved { logRouteDetail("handoff, name unresolved") }
        publish(best)
        return best
    }

    /// Plan section 2 retry ladder: the route name can land seconds after
    /// the route itself. Re-reads at each ladder offset; gives up with the
    /// UNRESOLVED line and leaves the receiver unknown.
    func runRetryLadder() {
        startBrowsing()
        let token = UUID()
        ladderToken = token
        if let now = resolveNow(), now.nameResolved {
            if now.model == nil { lateWatch = true }
            publish(now)
            return
        }
        for (i, offset) in Self.retryLadder.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + offset) {
                MainActor.assumeIsolated {
                    let resolver = AirPlayReceiverResolver.shared
                    guard resolver.ladderToken == token else { return }
                    guard let r = resolver.resolveNow() else {
                        resolver.ladderToken = UUID()   // route gone: stop
                        return
                    }
                    if r.nameResolved {
                        resolver.ladderToken = UUID()
                        if r.model == nil { resolver.lateWatch = true }
                        resolver.publish(r)
                    } else if i == Self.retryLadder.count - 1 {
                        resolver.ladderToken = UUID()
                        // Keep resolving in the background (2026-09-25).
                        resolver.lateWatch = true
                        debugLog("[AVP-AIRPLAY] route name still UNRESOLVED after the retry ladder; still resolving in the background (Bonjour browse stays up while the route exists)")
                        resolver.logRouteDetail("unresolved after the retry ladder")
                    }
                }
            }
        }
    }

    func cancelRetryLadder() { ladderToken = UUID() }

    /// uid -> TXT entry: the uid's MAC against `deviceid`, else the uid
    /// containing the `deviceid` (colons stripped) or a `pi`/`psi`/`gid`.
    private static func matchByUID(_ uid: String, mac: String?, in entries: [TXTEntry]) -> TXTEntry? {
        guard !uid.isEmpty else { return nil }
        if let mac, let e = entries.first(where: { $0.deviceID?.uppercased() == mac }) { return e }
        let u = uid.uppercased()
        let bare = u.replacingOccurrences(of: ":", with: "")
        return entries.first { e in
            if let d = e.deviceID?.uppercased(), d.count >= 12,
               u.contains(d) || bare.contains(d.replacingOccurrences(of: ":", with: "")) { return true }
            return e.identifiers.contains { u.contains($0.uppercased()) }
        }
    }

    // MARK: Late resolution (device log 2026-09-25)

    /// Set when the retry ladder / handoff ended without a TXT model:
    /// every browse update and route change re-resolves until the model
    /// (and name) arrive or the route goes away.
    private var lateWatch = false
    private var lastPublished: AirPlayReceiver?

    /// The route exists: browse for as long as it does (device log
    /// 2026-09-25, regression from 1ca7083: a browse started only at
    /// handoff had no results when the plan was decided). Called from the
    /// monitor's route evaluation; `stopBrowsing` still runs when the
    /// route goes (the Cast-session fix).
    func routePresent() {
        startBrowsing()
        checkLateResolution()
    }

    func checkLateResolution() {
        guard lateWatch else { return }
        guard let r = resolveNow() else { lateWatch = false; return }
        guard r != lastPublished, r.nameResolved || r.model != nil else { return }
        if r.nameResolved, lastPublished?.nameResolved != true {
            debugLog("[AVP-AIRPLAY] receiver name resolved late: \(r.name) model=\(r.model ?? "unknown") apple=\(r.isApple)")
        } else if r.model != nil, lastPublished?.model == nil {
            debugLog("[AVP-AIRPLAY] receiver model resolved late: \(r.model ?? "") apple=\(r.isApple) name=\(r.name)")
        }
        if r.model != nil { lateWatch = false }
        publish(r)
    }

    private func publish(_ r: AirPlayReceiver?) {
        lastPublished = r
        // The same detail for a resolved route, once per route uid, so a
        // stuck route can be compared with a working one.
        if let r, r.nameResolved { logRouteDetail("resolved") }
        onReceiverChange?(r)
    }

    // MARK: Route detail (diagnostics, 2026-11-16)

    /// One line describing the route and how it compares with every
    /// advertised receiver. Privacy: the uid and TXT values are never
    /// written; the uid as a shape (run classes and lengths), and per
    /// receiver only which TXT KEYS appear in the uid and which carry a
    /// piece of it. Logged once per (uid, cache names, browse state).
    func logRouteDetail(_ context: String) {
        guard let out = Self.currentAirPlayOutput() else { return }
        let uid = out.uid
        let names = cache.keys.sorted()
        let signature = "\(Self.uidHash(uid))|\(names.joined(separator: ","))|\(browseState)|\(context == "resolved")"
        guard !loggedDetailSignatures.contains(signature) else { return }
        loggedDetailSignatures.insert(signature)

        let age = lastResultsAt.map { "\(Int(Date().timeIntervalSince($0)))s ago" } ?? "never"
        var line = "[AVP-AIRPLAY] route detail (\(context)): port='\(out.name ?? "nil")' generic=\(AirPlayReceiver.isGenericName(out.name))"
        line += " \(Self.uidHash(uid)) shape=\(Self.uidShape(uid)) mac=\(Self.macAddress(in: uid) != nil)"
        line += " browse=\(browser == nil ? "off" : browseState) results=\(age) receivers=\(cache.count)"
        let rows = names.compactMap { name -> String? in
            guard let e = cache[name] else { return nil }
            let m = Self.uidComparison(uid, txt: e.txt)
            return "'\(name)' model=\(e.model ?? "nil") deviceid=\(e.deviceID != nil) ids=\(e.identifiers.count) inUID=[\(m.valuesInUID.joined(separator: ","))] uidPartIn=[\(m.uidRunsIn.joined(separator: ","))]"
        }
        line += rows.isEmpty ? " (no receivers)" : " | " + rows.joined(separator: " | ")
        debugLog(line)
    }

    /// The uid as runs of letters/digits with their separators kept:
    /// `h8-h4-h4-h4-h12` (h hex, d digits, a letters, x mixed). Lengths
    /// and classes only, nothing identifying.
    static func uidShape(_ uid: String) -> String {
        guard !uid.isEmpty else { return "empty" }
        var out = ""
        var run = ""
        func flush() {
            guard !run.isEmpty else { return }
            let digits = run.allSatisfy { $0.isASCII && $0.isNumber }
            let hex = run.allSatisfy { $0.isHexDigit }
            let letters = run.allSatisfy { $0.isLetter }
            let cls = digits ? "d" : hex ? "h" : letters ? "a" : "x"
            out += "\(cls)\(run.count)"
            run = ""
        }
        for ch in uid {
            if ch.isLetter || ch.isNumber { run.append(ch) } else { flush(); out.append(ch.isASCII ? ch : "?") }
        }
        flush()
        return out
    }

    /// Which TXT keys have a value (8+ characters, separators stripped,
    /// case folded) contained in the uid, and which TXT keys contain one
    /// of the uid's own runs of 8+ characters.
    static func uidComparison(_ uid: String, txt: [String: String]) -> (valuesInUID: [String], uidRunsIn: [String]) {
        func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let u = norm(uid)
        let runs = uid.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .map(String.init)
            .filter { $0.count >= 8 }
        var inUID: [String] = []
        var runsIn: [String] = []
        for key in txt.keys.sorted() {
            let v = norm(txt[key] ?? "")
            if v.count >= 8, u.contains(v) { inUID.append(key) }
            if !v.isEmpty, runs.contains(where: { v.contains($0) }) { runsIn.append(key) }
        }
        return (inUID, runsIn)
    }

    static func stateLabel(_ state: NWBrowser.State) -> String {
        switch state {
        case .setup: return "setup"
        case .ready: return "ready"
        case .waiting(let e): return "waiting(\(describe(e)))"
        case .failed(let e): return "failed(\(describe(e)))"
        case .cancelled: return "cancelled"
        @unknown default: return "unknown"
        }
    }

    // MARK: Helpers

    /// First `xx:xx:xx:xx:xx:xx` in the uid, uppercased; nil when none.
    static func macAddress(in uid: String) -> String? {
        let hex = "[0-9A-Fa-f]{2}"
        let pattern = "\(hex)(:\(hex)){5}"
        guard let range = uid.range(of: pattern, options: .regularExpression) else { return nil }
        return uid[range].uppercased()
    }

    /// `uid#<fnv1a-32 hex>/<length>`: identifies the receiver across log
    /// lines without writing its MAC into a shareable log.
    static func uidHash(_ uid: String) -> String {
        var h: UInt32 = 0x811C9DC5
        for b in uid.utf8 {
            h ^= UInt32(b)
            h = h &* 0x0100_0193
        }
        return "uid#\(String(h, radix: 16))/\(uid.utf8.count)"
    }

    // MARK: Launch probe

    private var launchDetector: AVRouteDetector?
    private var launchProbed = false

    /// `[AVP-AIRPLAY] airplay routes detected=... (window: launch)`, once
    /// per process, from the first scene activation.
    func probeRoutesAtLaunch() {
        guard !launchProbed else { return }
        launchProbed = true
        let detector = AVRouteDetector()
        detector.isRouteDetectionEnabled = true
        launchDetector = detector
        startBrowsing()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated {
                let resolver = AirPlayReceiverResolver.shared
                guard let d = resolver.launchDetector else { return }
                debugLog("[AVP-AIRPLAY] airplay routes detected=\(d.multipleRoutesDetected) (window: launch)")
                d.isRouteDetectionEnabled = false
                resolver.launchDetector = nil
                // Incident 2026-09-25: the launch probe used to leave the
                // browse running for the life of the process.
                if AirPlayReceiverResolver.currentAirPlayOutput() == nil { resolver.stopBrowsing() }
            }
        }
    }
}
#endif

// MARK: - HEVC delivery memory (Logan 2026-11-06)

/// Which LAN arm played an HEVC channel on a receiver model, remembered
/// across launches so the next session starts on the working arm instead
/// of re-trying the one the receiver rejected. Keyed by the TXT model
/// (`3840R`); a receiver without a model is never remembered.
@MainActor
enum AirPlayHEVCArmMemory {
    /// v2: v1 entries recorded "HEVC in TS" from segment fetches alone
    /// (2026-11-06 16:43, no picture); they are not read.
    private static let defaultsKey = "airplayHEVCArm.v2"

    static func remembered(model: String?) -> AirPlayHEVCArm? {
        guard let model, !model.isEmpty,
              let raw = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String],
              let v = raw[model] else { return nil }
        return AirPlayHEVCArm(rawValue: v)
    }

    static func remember(model: String?, arm: AirPlayHEVCArm) {
        guard let model, !model.isEmpty else { return }
        var raw = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        guard raw[model] != arm.rawValue else { return }
        raw[model] = arm.rawValue
        UserDefaults.standard.set(raw, forKey: defaultsKey)
        debugLog("[AVP-AIRPLAY] HEVC delivery remembered for model \(model): \(arm.label)")
    }
}
