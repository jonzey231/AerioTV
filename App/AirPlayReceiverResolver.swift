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
        case .automatic: return !isApple
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

    /// Route names that carry no receiver identity.
    static func isGenericName(_ name: String?) -> Bool {
        guard let name else { return true }
        let t = name.trimmingCharacters(in: .whitespaces)
        return t.isEmpty || t == "AirPlay"
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
        let model: String?
        let deviceID: String?
    }

    private var browser: NWBrowser?
    private var cache: [String: TXTEntry] = [:]
    private var restartedAfterFailure = false
    private var ladderToken = UUID()

    /// Fires with each newly resolved receiver (the monitor keeps it for
    /// the card and the lock screen).
    var onReceiverChange: ((AirPlayReceiver?) -> Void)?

    private init() {}

    // MARK: Bonjour

    func startBrowsing() {
        guard browser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = false
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_airplay._tcp", domain: nil), using: params)
        b.browseResultsChangedHandler = { results, _ in
            var next: [String: TXTEntry] = [:]
            for result in results {
                guard case let .service(name, _, _, _) = result.endpoint else { continue }
                var model: String?
                var deviceID: String?
                if case let .bonjour(txt) = result.metadata {
                    model = txt["model"]
                    deviceID = txt["deviceid"]
                }
                next[name.trimmingCharacters(in: .whitespaces)] = TXTEntry(model: model, deviceID: deviceID)
            }
            Task { @MainActor in AirPlayReceiverResolver.shared.cache = next }
        }
        b.stateUpdateHandler = { state in
            guard case let .failed(error) = state else { return }
            Task { @MainActor in AirPlayReceiverResolver.shared.browseFailed(error) }
        }
        browser = b
        b.start(queue: .main)
    }

    private func browseFailed(_ error: NWError) {
        debugLog("[AVP-AIRPLAY] receiver browse failed: \(Self.describe(error))")
        browser?.cancel()
        browser = nil
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
        let rawName = out.name ?? "AirPlay"
        let nameResolved = !AirPlayReceiver.isGenericName(out.name)
        let uid = out.uid
        let mac = Self.macAddress(in: uid)
        var entry: TXTEntry?
        if nameResolved {
            entry = cache[rawName.trimmingCharacters(in: .whitespaces)]
        }
        if entry == nil, let mac {
            entry = cache.values.first { $0.deviceID?.uppercased() == mac }
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
        startBrowsing()
        let deadline = Date().addingTimeInterval(timeout)
        var best = resolveNow() ?? .unknown
        while best.model == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 250_000_000)
            best = resolveNow() ?? best
        }
        onReceiverChange?(best)
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
            onReceiverChange?(now)
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
                        resolver.onReceiverChange?(r)
                    } else if i == Self.retryLadder.count - 1 {
                        resolver.ladderToken = UUID()
                        debugLog("[AVP-AIRPLAY] route name still UNRESOLVED after the retry ladder; card and lock screen stay on the generic label, receiver stays unknown")
                    }
                }
            }
        }
    }

    func cancelRetryLadder() { ladderToken = UUID() }

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
            }
        }
    }
}
#endif
