import Foundation
import Network
#if canImport(UIKit)
import UIKit
#endif

#if DEBUG
/// Serial queue that absorbs Debug console writes OFF the calling thread.
/// A synchronous `print()` blocks the caller whenever the Xcode console pipe
/// backs up. On mpv's event-drain loop (`mpvQueue`) and render thread that
/// backpressure stalls mpv's core: its bounded event queue fills, the core
/// thread blocks trying to enqueue the next event, and a VOD/DVR file demuxer
/// stops reading (the Debug-only "first frame then freeze" that does NOT exist
/// in Release, where every debugLog compiles to nothing). Deferring only the
/// write keeps every mpv thread non-blocking; the serial queue preserves order.
private let _debugConsoleQueue = DispatchQueue(label: "com.aerio.debugconsole", qos: .utility)
#endif

/// Debug-only print wrapper. Compiles to nothing in release builds.
/// Replaces scattered emoji `print()` calls so they never leak in production.
/// The string is built synchronously (cheap) but WRITTEN asynchronously, so a
/// blocked console pipe can never stall the caller's thread (see the queue
/// comment above for why that matters on the mpv threads).
@inline(__always)
func debugLog(_ message: @autoclosure () -> String) {
    // Build the line in every configuration. The autoclosure means
    // construction cost is paid only inside this call, so a caller's
    // expression is not evaluated until we are sure we want it (Release
    // builds still pay the line build, but that is the same cost the
    // file-write needs anyway).
    let line = message()
    #if DEBUG
    // stdout only matters in Debug (Xcode console attached). Stays
    // inside the DEBUG guard so Release builds do not pay the queue
    // hop for a console nobody reads.
    _debugConsoleQueue.async { print(line) }
    #endif
    // v1.7.x: also route to the on-disk log file when Developer
    // Settings has Debug Logging on. captureFreeFunctionLog is a no-op
    // when isEnabled is false, so the off-by-default Release path pays
    // only the cheap UserDefaults read. THIS CALL DELIBERATELY RUNS IN
    // BOTH DEBUG AND RELEASE - Archie explicitly asked for the firehose
    // to land in the file on every build, since the tvOS Share Log File
    // flow has to work for TestFlight community testers too (they have
    // no Xcode-attached Mac to spy on stdout). Pre-fix the whole body
    // including this call was inside #if DEBUG, so the TestFlight log
    // file stayed empty even with the toggle on.
    DebugLogger.shared.captureFreeFunctionLog(line)
}

// Safe array subscript used by PlayerView logging.
extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Log Level

enum LogLevel: String, CaseIterable {
    case debug    = "DEBUG"
    case info     = "INFO"
    case warning  = "WARN"
    case error    = "ERROR"
    case critical = "CRITICAL"
    case network  = "NET"
    case perf     = "PERF"
    case lifecycle = "LIFECYCLE"

    var icon: String {
        switch self {
        case .debug:    return "🔍"
        case .info:     return "ℹ️"
        case .warning:  return "⚠️"
        case .error:    return "❌"
        case .critical: return "🔴"
        case .network:  return "🌐"
        case .perf:     return "⚡"
        case .lifecycle: return "🔄"
        }
    }
}

// MARK: - Debug Logger

/// Thread-safe, file-backed debug logger.
/// Log file is written to the app's Documents directory, which is exposed in
/// the iOS Files app under On My iPhone > Aerio (requires UIFileSharingEnabled in Info.plist).
final class DebugLogger: @unchecked Sendable {
    static let shared = DebugLogger()

    // Serial queue for all file I/O — prevents data races.
    private let queue = DispatchQueue(label: "com.aerio.debuglogger", qos: .utility)

    // Maximum log file size before rotation (10 MB).
    private let maxFileSize: Int = 10 * 1_024 * 1_024

    private let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private let dateOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    // MARK: - Public State

    /// Whether debug logging is currently active.
    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "debugLoggingEnabled") }
    }

    /// The URL of the active log file.
    ///
    /// v1.7.x: moved from .documentDirectory to .cachesDirectory after
    /// the 2026-06-05 field test from Archie's Apple TV showed every
    /// write to /var/mobile/.../Documents/aerio_debug_logs.txt failing
    /// with "You don't have permission to save the file ... in the
    /// folder 'Documents'." tvOS sandboxes Documents read-only for the
    /// app's own container - iOS allows app-Documents writes, tvOS does
    /// not. Apple's documented writable scratch location on every
    /// platform is .cachesDirectory, and logs are exactly the kind of
    /// regenerable diagnostic content it was designed for. The file is
    /// still served by the tvOS Share Log File LAN HTTP path and the
    /// iOS UIActivityViewController path, which both take a URL and do
    /// not care where in the sandbox it lives.
    var logFileURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("aerio_debug_logs.txt")
    }

    /// Human-readable file size of the current log.
    var logFileSizeString: String {
        // Total across the active log AND any rotated archives, so the
        // size row reflects what "Delete All Logs" actually frees (the
        // 10MB rotation parks an archive sibling that previously never
        // showed up here and could never be deleted).
        let size = Self.allLogFileURLs().reduce(0) { total, url in
            total + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        switch size {
        case 0:                    return "Empty"
        case 1..<1_024:            return "\(size) B"
        case 1_024..<(1_024*1_024): return "\(size / 1_024) KB"
        default:                   return String(format: "%.1f MB", Double(size) / Double(1_024 * 1_024))
        }
    }

    /// Every log artifact in the caches directory: the active
    /// aerio_debug_logs.txt plus any rotated archives. Prefix-matched so
    /// a future rotation scheme (timestamped archives) is covered too.
    private static func allLogFileURLs() -> [URL] {
        guard let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
              let contents = try? FileManager.default.contentsOfDirectory(
                  at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return [] }
        return contents.filter { $0.lastPathComponent.hasPrefix("aerio_debug_logs") }
    }

    private init() {}

    // MARK: - Credential Sanitization
    //
    // Defence-in-depth for the debug log file. Every string path that
    // reaches `appendToFile` is now routed through `sanitize()` so no
    // credential — embedded in a URL, a header, a JSON body snippet,
    // or an error message — can land on disk. Patterns below are
    // ordered by risk; extending the list means adding one `NSRegular`
    // pattern plus one replacement line in `sanitize()`.
    //
    // If you add a new auth surface (e.g. OAuth, a new media server),
    // audit call sites with `grep -R "DebugLogger.shared.log\|debugLog"`
    // for any new vector and extend this list accordingly.

    /// Xtream path-segment credentials: `/live/<user>/<pass>/<id>.ts`
    /// etc. Catches the three stream-type prefixes Xtream supports.
    /// Preserves `<user>` on purpose so operators can correlate log
    /// lines with specific accounts when debugging — only the password
    /// slot is redacted.
    private static let xtreamPathRegex = try! NSRegularExpression(
        pattern: #"/(movie|series|live)/([^/]+)/([^/]+)/"#)
    /// Xtream query-param credentials — used by the `/player_api.php`
    /// and `/get.php` endpoints: `?username=X&password=Y&action=…`.
    /// Separate from the path-segment regex above because Xtream's
    /// API and stream endpoints use different auth encodings.
    private static let xtreamQueryParamRegex = try! NSRegularExpression(
        pattern: #"([?&](?:username|password)=)[^&\s]+"#, options: .caseInsensitive)
    /// `?api_key=...` query param. Used by Emby/Jellyfin + some
    /// legacy Dispatcharr paths.
    private static let apiKeyRegex = try! NSRegularExpression(
        pattern: #"(api[_-]?key=)[^&\s]+"#, options: .caseInsensitive)
    /// HTTP authorisation header values — defensive for the case where
    /// URLSession stringifies a failed request (header + URL both land
    /// in `error.localizedDescription`). Covers the three schemes the
    /// app uses: `Authorization: Bearer …` (Dispatcharr JWT),
    /// `Authorization: ApiKey …` / `X-API-Key: …` (Dispatcharr API
    /// key), and `X-Plex-Token: …` (Plex). Header value is bounded by
    /// whitespace, comma, semicolon, or quote so we don't eat past
    /// the value.
    private static let authHeaderRegex = try! NSRegularExpression(
        pattern: #"(?i)(Authorization|X-API-Key|X-Plex-Token):\s*([^\s,;"]+)"#)
    /// Emby/Jellyfin "Token=..." fragment inside
    /// `X-Emby-Authorization: MediaBrowser Client="…", Token="…"`.
    /// Separate from `authHeaderRegex` because the token sits inside
    /// a comma-separated value list rather than being the entire
    /// header value.
    private static let embyTokenRegex = try! NSRegularExpression(
        pattern: #"(?i)(Token=)"[^"]+""#)
    /// JWT `access`/`refresh` pairs in JSON response bodies. Triggers
    /// primarily from `logDecodeError(payloadSnippet:)` when a login
    /// response fails to decode — the raw JSON would otherwise include
    /// the tokens in plaintext. The 20-char minimum avoids false
    /// positives on short unrelated fields.
    private static let jwtInJsonRegex = try! NSRegularExpression(
        pattern: #""(access|refresh)"\s*:\s*"[^"]{20,}""#)
    /// HTTP basic-auth userinfo embedded in a URL: `scheme://user:pass@host`.
    /// Common in raw M3U playlists, which the Xtream path/query regexes above
    /// do NOT cover. Redacts the whole userinfo to `***@`, keeping the scheme
    /// and host so the log still shows which server was contacted.
    private static let urlUserInfoRegex = try! NSRegularExpression(
        pattern: #"(://)[^/@\s]+@"#)
    /// Generic credential-bearing query params beyond the Xtream
    /// username/password/api_key set: token, auth, sig, signature, secret,
    /// pass, pwd, hash, key. Raw M3U / CDN stream URLs frequently carry one
    /// of these. Over-redaction here is harmless; a missed credential is not.
    private static let sensitiveQueryParamRegex = try! NSRegularExpression(
        pattern: #"([?&](?:token|auth|authkey|sig|signature|secret|pass|pwd|hash|key)=)[^&\s]+"#,
        options: .caseInsensitive)

    static func sanitize(_ message: String) -> String {
        var result = message
        func apply(_ regex: NSRegularExpression, _ template: String) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        apply(urlUserInfoRegex,      "$1***@")
        apply(xtreamPathRegex,       "/$1/$2/***/")
        apply(xtreamQueryParamRegex, "$1***")
        apply(apiKeyRegex,           "$1***")
        apply(sensitiveQueryParamRegex, "$1***")
        apply(authHeaderRegex,       "$1: ***")
        apply(embyTokenRegex,        #"$1"***""#)
        apply(jwtInJsonRegex,        #""$1": "***""#)
        return result
    }

    // MARK: - Enable / Disable

    @MainActor func enable() {
        UserDefaults.standard.set(true, forKey: "debugLoggingEnabled")
        // v1.7.x diag: log the path we are about to write to, so an
        // Xcode-attached tester can see the actual sandbox URL and
        // cross-check it against what the [DebugLogger][diag] appendToFile
        // breadcrumbs report. The mismatch case (writing to one path,
        // size-read from another) was a real hypothesis worth ruling out.
        print("[DebugLogger][diag] enable() called; isEnabled=\(isEnabled) logFileURL=\(logFileURL?.path ?? "<nil>")")
        writeSessionHeader()
    }

    func disable() {
        // Write a final entry then close.
        let entry = formatEntry(level: .lifecycle, category: "Logger",
                                message: "Debug logging disabled by user")
        queue.async { [weak self] in self?.appendToFile(entry) }
        UserDefaults.standard.set(false, forKey: "debugLoggingEnabled")
    }

    /// Delete EVERY log artifact: the active log plus all rotated
    /// archives. The previous version removed only the active file, so
    /// the 10MB rotation archive lingered forever with no way to delete
    /// it from the app.
    func clearLogs() {
        queue.async {
            // Drop the replay ring too: a deliberate clear must not be
            // undone by the purge-recovery replay on the next line.
            self.ring.removeAll()
            self.ringStart = 0
            self.lastValidationAt = .distantPast
            self.needsRevalidation = false
            for url in Self.allLogFileURLs() {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - General Logging

    /// Log a free-form message with automatic source location.
    func log(_ message: String,
             category: String = "App",
             level: LogLevel = .info,
             file: String = #file,
             function: String = #function,
             line: Int = #line) {
        guard isEnabled else { return }
        let src = "\(URL(fileURLWithPath: file).lastPathComponent):\(line)"
        let entry = formatEntry(level: level, category: category,
                                message: DebugLogger.sanitize(message), source: src)
        queue.async { [weak self] in self?.appendToFile(entry) }
    }

    /// Log a caught error with full context.
    ///
    /// v1.6.8 (Codex D4): both the localized description and the
    /// `String(describing: error)` dump can embed the full URL
    /// that failed (URLSession typically formats
    /// `NSErrorFailingURLStringKey` into its description), which on
    /// an Xtream stream URL would include user + password. Route the
    /// composed message through `sanitize` so those slots get
    /// redacted before disk.
    func logError(_ error: Error,
                  context: String,
                  file: String = #file,
                  function: String = #function,
                  line: Int = #line) {
        guard isEnabled else { return }
        let src = "\(URL(fileURLWithPath: file).lastPathComponent):\(line) \(function)"
        let msg = "[\(context)] \(error.localizedDescription) | \(String(describing: error))"
        let entry = formatEntry(level: .error, category: "Error",
                                message: DebugLogger.sanitize(msg), source: src)
        queue.async { [weak self] in self?.appendToFile(entry) }
    }

    // MARK: - Specialised Logging

    /// Log a network request/response with timing.
    func logNetwork(method: String,
                    url: String,
                    statusCode: Int? = nil,
                    duration: TimeInterval? = nil,
                    bytesReceived: Int? = nil,
                    error: Error? = nil) {
        guard isEnabled else { return }
        var parts = ["\(method) \(DebugLogger.sanitize(url))"]
        if let code = statusCode   { parts.append("→ HTTP \(code)") }
        if let ms   = duration     { parts.append(String(format: "%.0f ms", ms * 1_000)) }
        if let bytes = bytesReceived { parts.append("\(bytes >= 1_024 ? "\(bytes/1_024) KB" : "\(bytes) B")") }
        if let err = error         { parts.append("ERROR: \(err.localizedDescription)") }
        let level: LogLevel = error != nil ? .error : (statusCode.map { $0 >= 400 } ?? false ? .warning : .network)
        let entry = formatEntry(level: level, category: "Network", message: parts.joined(separator: " | "))
        queue.async { [weak self] in self?.appendToFile(entry) }
    }

    /// Log a stream playback event.
    ///
    /// v1.6.8 (Codex D4): URLs passed here can include Xtream
    /// path-segment credentials (`/live/<user>/<pass>/…`) when the
    /// app falls back to legacy Xtream streaming endpoints, or
    /// query-param credentials on M3U playlists. Route through
    /// `sanitize` so those get redacted before disk.
    func logPlayback(event: String, url: String? = nil, detail: String? = nil) {
        guard isEnabled else { return }
        var msg = event
        if let u = url    { msg += " | \(u)" }
        if let d = detail { msg += " | \(d)" }
        let entry = formatEntry(level: .lifecycle, category: "Playback",
                                message: DebugLogger.sanitize(msg))
        queue.async { [weak self] in self?.appendToFile(entry) }
    }

    /// Log an EPG operation.
    ///
    /// v1.6.8 (Codex D4): `error.localizedDescription` on a URLSession
    /// fetch failure can embed the full XMLTV URL — potentially an
    /// Xtream `/xmltv.php?username=…&password=…` endpoint. Sanitize
    /// the composed message.
    func logEPG(event: String,
                channelID: String? = nil,
                count: Int? = nil,
                duration: TimeInterval? = nil,
                error: Error? = nil) {
        guard isEnabled else { return }
        var msg = event
        if let id  = channelID { msg += " | tvg_id: \(id)" }
        if let n   = count     { msg += " | \(n) programs" }
        if let ms  = duration  { msg += " | \(String(format: "%.0f ms", ms * 1_000))" }
        if let err = error     { msg += " | \(err.localizedDescription)" }
        let level: LogLevel = error != nil ? .warning : .info
        let entry = formatEntry(level: level, category: "EPG",
                                message: DebugLogger.sanitize(msg))
        queue.async { [weak self] in self?.appendToFile(entry) }
    }

    /// Log a channel list load operation.
    ///
    /// v1.6.8 (Codex D4): sanitized for the same reason as `logEPG`
    /// — the error description can expose the playlist URL.
    func logChannelLoad(serverType: String,
                        channelCount: Int? = nil,
                        duration: TimeInterval? = nil,
                        error: Error? = nil) {
        guard isEnabled else { return }
        var msg = "loadChannels [\(serverType)]"
        if let n  = channelCount { msg += " | \(n) channels" }
        if let ms = duration     { msg += " | \(String(format: "%.0f ms", ms * 1_000))" }
        if let err = error       { msg += " | \(err.localizedDescription)" }
        let level: LogLevel = error != nil ? .error : .info
        let entry = formatEntry(level: level, category: "Channels",
                                message: DebugLogger.sanitize(msg))
        queue.async { [weak self] in self?.appendToFile(entry) }
    }

    /// Log an app lifecycle event (foreground, background, launch, terminate).
    /// Sanitised like every other structured sink: callers pass static
    /// strings today, but routing through `sanitize` keeps this from
    /// becoming an unredacted hole if a future caller includes dynamic data.
    func logLifecycle(_ event: String) {
        guard isEnabled else { return }
        let entry = formatEntry(level: .lifecycle, category: "Lifecycle",
                                message: DebugLogger.sanitize(event))
        queue.async { [weak self] in self?.appendToFile(entry) }
    }

    /// Log a timed operation for performance tracking.
    ///
    /// v1.6.8 (Codex D4): sanitised — callers sometimes include URLs
    /// or auth headers in the `detail` field.
    func logPerformance(operation: String, duration: TimeInterval, detail: String? = nil) {
        guard isEnabled else { return }
        var msg = "\(operation): \(String(format: "%.2f ms", duration * 1_000))"
        if let d = detail { msg += " | \(d)" }
        let entry = formatEntry(level: .perf, category: "Performance",
                                message: DebugLogger.sanitize(msg))
        queue.async { [weak self] in self?.appendToFile(entry) }
    }

    /// Log a decoding / parsing error with the raw payload snippet.
    ///
    /// v1.6.8 (Codex D4): **highest-risk sanitizer target** — the
    /// raw payload prefix can be the first 200 characters of a
    /// Dispatcharr login response which contains
    /// `{"access":"<jwt>","refresh":"<jwt>"}`. The JWT regex in
    /// `sanitize()` specifically handles this case.
    func logDecodeError(type: String, error: Error, payloadSnippet: String? = nil) {
        guard isEnabled else { return }
        var msg = "Decode failed for \(type): \(error.localizedDescription)"
        if let snippet = payloadSnippet {
            let preview = snippet.prefix(200)
            msg += " | payload: \(preview)"
        }
        let entry = formatEntry(level: .error, category: "Decode",
                                message: DebugLogger.sanitize(msg))
        queue.async { [weak self] in self?.appendToFile(entry) }
    }

    // MARK: - Session Header

    /// Re-emit the session header for an ALREADY-enabled logger. Called on
    /// app launch so every session in a shared log file opens with the
    /// device + build + connection block, not just the session where the
    /// user first flipped the toggle (Logan 2026-08-12: reports should
    /// answer "which device, what connection" without asking).
    @MainActor func logSessionStart() {
        guard isEnabled else { return }
        writeSessionHeader()
    }

    /// Hardware identifier (e.g. "AppleTV14,1", "iPhone16,1"). UIDevice.model
    /// only says "Apple TV" / "iPhone", which is never enough to tell a 4K
    /// box from an HD one in a perf report.
    private static func machineIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { buf in
            String(decoding: buf.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    /// One-shot connection snapshot appended right after the session header.
    /// General transport only (wired / wifi / cellular) -- no SSIDs, no IPs;
    /// the file gets attached to public GitHub issues.
    private func logConnectionSnapshot() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            monitor.cancel()
            guard let self else { return }
            let transport: String
            if path.usesInterfaceType(.wiredEthernet) { transport = "ethernet" }
            else if path.usesInterfaceType(.wifi) { transport = "wifi" }
            else if path.usesInterfaceType(.cellular) { transport = "cellular" }
            else if path.status == .satisfied { transport = "other" }
            else { transport = "none" }
            let expensive = path.isExpensive ? " (expensive)" : ""
            let line = "Connection  : \(transport)\(expensive)\n"
            self.queue.async { [weak self] in self?.appendToFile(line) }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
    }

    @MainActor private func writeSessionHeader() {
        // Capture @MainActor-isolated UIDevice values before entering the background queue.
#if canImport(UIKit)
        let capturedModel   = UIDevice.current.model
        let capturedSysName = UIDevice.current.systemName
        let capturedSysVer  = UIDevice.current.systemVersion
#endif
        let machine = Self.machineIdentifier()
        queue.async { [weak self] in
            guard let self else { return }
#if canImport(UIKit)
            let deviceModel = capturedModel
            let systemInfo  = "\(capturedSysName) \(capturedSysVer)"
            let memInfo     = self.memoryUsageString()
#else
            let deviceModel  = "Mac"
            let v = ProcessInfo.processInfo.operatingSystemVersion
            let systemInfo   = "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
            let memInfo      = "N/A"
#endif
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
            let build   = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
            let header = """

            ════════════════════════════════════════════════════════
            Aerio Debug Session: \(self.timestampFormatter.string(from: Date()))
            App Version : \(version) (\(build))
            Device      : \(deviceModel) (\(machine))
            System      : \(systemInfo)
            Memory      : \(memInfo)
            ════════════════════════════════════════════════════════

            """
            // Purge forensics (2026-09-12): record what the file system
            // actually had at launch, BEFORE the first append recreates
            // anything, so a vanished log is visible in the next session.
            let logPath = self.logFileURL?.path
            let present = logPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
            var bytes = 0
            if let logPath, let attrs = try? FileManager.default.attributesOfItem(atPath: logPath),
               let size = attrs[.size] as? Int { bytes = size }
            let archivePresent = self.logFileURL.map {
                FileManager.default.fileExists(atPath: $0.deletingLastPathComponent()
                    .appendingPathComponent("aerio_debug_logs_archive.txt").path)
            } ?? false
            self.appendToFile(header)
            self.appendToFile("[\(self.timestampFormatter.string(from: Date()))] [LOG] file present=\(present) size=\(bytes) archive=\(archivePresent)\n")
        }
        logConnectionSnapshot()
    }

    // MARK: - Free-function (`debugLog`) capture

    /// Sink for the `debugLog(_:)` free-function firehose. Called from
    /// every `debugLog(...)` call site in Debug builds. When the user
    /// has Debug Logging turned on in Developer Settings, the message
    /// is sanitized (creds, api_key, Authorization, JWTs scrubbed) and
    /// appended to `aerio_debug_logs.txt` so the Share Log File path
    /// actually has content to share. No-op when logging is off, so the
    /// non-tester path stays exactly as the existing stdout-only path.
    /// v1.7.x: deliberately does NOT add the `formatEntry` decorations
    /// (timestamp + level + category brackets) because the existing
    /// callers already include their own emoji prefixes and contextual
    /// tags; we just prepend a short `[HH:mm:ss.SSS]` so each line is
    /// timestamped and append the newline.
    func captureFreeFunctionLog(_ text: String) {
        guard isEnabled else { return }
        let ts = timestampFormatter.string(from: Date())
        let sanitized = Self.sanitize(text)
        let line = "[\(ts)] \(sanitized)\n"
        queue.async { [weak self] in self?.appendToFile(line) }
    }

    // MARK: - Formatting & I/O

    private func formatEntry(level: LogLevel,
                             category: String,
                             message: String,
                             source: String? = nil) -> String {
        let ts  = timestampFormatter.string(from: Date())
        var line = "[\(ts)] \(level.icon) [\(level.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0))] [\(category)] \(message)"
        if let src = source { line += "  | \(src)" }
        return line + "\n"
    }

    private func appendToFile(_ text: String) {
        guard let url = logFileURL else {
            // v1.7.x diag: shout to stdout if we have no URL. tvOS's
            // .documentDirectory has historically been the right path
            // for app-purgeable user files, but if FileManager ever
            // returns an empty list for any reason every write would
            // silently no-op and the file would stay "Empty" forever.
            // This print lets a tester paired with Xcode see the cause.
            print("[DebugLogger][diag] appendToFile FAILED: logFileURL is nil")
            return
        }
        guard let data = text.data(using: .utf8) else {
            print("[DebugLogger][diag] appendToFile FAILED: utf8 encode returned nil (len=\(text.count))")
            return
        }

        // 2026-09-12 (Archie field capture from the Apple TV): the log
        // file AND its rotated archive vanished from Library/Caches
        // while the app kept running. tvOS purges Caches under storage
        // pressure with no notification, so every line written after
        // the purge used to land in a file nobody looked at, or worse,
        // the in-flight state said "exists" and the append silently
        // went nowhere. The write path now revalidates the file (at
        // most once per second, so a firehose line costs nothing) and
        // recreates it with the in-memory ring replayed on top, so a
        // purge costs at most the last second instead of the session.
        let now = Date()
        var mustValidate = needsRevalidation
        if !mustValidate, now.timeIntervalSince(lastValidationAt) >= Self.validationInterval {
            mustValidate = true
        }

        if mustValidate {
            lastValidationAt = now
            needsRevalidation = false
            let exists = FileManager.default.fileExists(atPath: url.path)
            if !exists {
                recreateFile(at: url)
            } else if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                      let size = attrs[.size] as? Int, size > maxFileSize {
                // Rotation is part of the same once-per-second check so
                // the steady-state line cost is one write, no stat.
                rotateLog(at: url)
            }
        }

        // Record the line in the ring BEFORE the write so a failed write
        // followed by a recreate still replays it.
        appendToRing(text)

        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
            if !appendDiagFirstWriteLogged {
                appendDiagFirstWriteLogged = true
                print("[DebugLogger][diag] first append OK: \(data.count) B at \(url.path)")
            }
        } catch {
            // The file went away (or turned unwritable) between the
            // validation above and this write: force a revalidation on
            // the very next line instead of waiting out the interval.
            needsRevalidation = true
            if !appendDiagFailureLogged {
                appendDiagFailureLogged = true
                print("[DebugLogger][diag] appendToFile FileHandle error at \(url.path): \(error.localizedDescription) (further failures suppressed)")
            }
        }
    }

    // MARK: - Purge recovery

    /// How often the write path is allowed to stat the log file. Every
    /// line would mean one syscall per debugLog on the firehose.
    private static let validationInterval: TimeInterval = 1.0
    /// Maximum lines kept in memory for replay after a purge.
    private static let ringCapacity = 2_000

    private var lastValidationAt: Date = .distantPast
    /// Set when a write fails, so the next line revalidates immediately
    /// rather than after the interval.
    private var needsRevalidation = false
    /// Ring of the most recent log lines (each already newline-terminated).
    /// Queue-confined: only touched from `queue`, so no lock is needed.
    private var ring: [String] = []
    private var ringStart = 0

    private func appendToRing(_ text: String) {
        if ring.count < Self.ringCapacity {
            ring.append(text)
        } else {
            ring[ringStart] = text
            ringStart = (ringStart + 1) % Self.ringCapacity
        }
    }

    private func ringContents() -> [String] {
        guard ring.count == Self.ringCapacity else { return ring }
        return Array(ring[ringStart...]) + Array(ring[..<ringStart])
    }

    /// Recreate a log file that disappeared under us, seeding it with the
    /// buffered lines so the recovered file is not an empty hole.
    private func recreateFile(at url: URL) {
        let buffered = ringContents()
        var seed = "[\(timestampFormatter.string(from: Date()))] [LOG] file recreated (previous file missing)\n"
        if !buffered.isEmpty {
            seed += "[\(timestampFormatter.string(from: Date()))] [LOG] replayed \(buffered.count) buffered lines\n"
            seed += buffered.joined()
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (seed.data(using: .utf8) ?? Data()).write(to: url, options: .atomic)
        } catch {
            needsRevalidation = true
            if !appendDiagFailureLogged {
                appendDiagFailureLogged = true
                print("[DebugLogger][diag] recreate FAILED at \(url.path): \(error.localizedDescription) (further failures suppressed)")
            }
        }
    }

    /// One-shot guards so the stdout breadcrumbs print at most once per
    /// process per outcome. Pre-fix the success breadcrumb fired every
    /// 50 writes (still readable but noisy on a steady firehose), and
    /// the failure breadcrumb fired once per failed write (which on the
    /// pre-fix .documentDirectory bug printed the same error hundreds
    /// of times per session - the very transcript Archie sent that
    /// surfaced the sandbox issue).
    private var appendDiagFirstWriteLogged = false
    private var appendDiagFailureLogged = false

    /// Rename the current log to debug_logs_archive.txt and start fresh.
    private func rotateLog(at url: URL) {
        let archiveURL = url.deletingLastPathComponent()
            .appendingPathComponent("aerio_debug_logs_archive.txt")
        try? FileManager.default.removeItem(at: archiveURL)
        try? FileManager.default.moveItem(at: url, to: archiveURL)
        let note = "[\(timestampFormatter.string(from: Date()))] ℹ️ [INFO    ] [Logger] Log rotated, previous log saved as aerio_debug_logs_archive.txt\n"
        try? note.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    // MARK: - Helpers

#if canImport(UIKit)
    private func memoryUsageString() -> String {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return "N/A" }
        let mb = Double(info.resident_size) / (1_024 * 1_024)
        return String(format: "%.1f MB resident", mb)
    }
#endif
}


/// Tab switch latency probe (2026-09-06): counts body evaluations per view
/// and flushes one line per second so the log shows how many times each
/// tab root and each channel row re-rendered around a switch.
import Combine

@MainActor
enum TabProbe {
    private static var subs: [AnyCancellable] = []
    private static var probed = false
    /// Counts objectWillChange sends per store, once per session.
    static func probePublishers(channelStore: ChannelStore, nowPlaying: NowPlayingManager,
                                favorites: FavoritesStore, collections: ChannelCollectionsStore,
                                guide: GuideStore) {
        guard !probed else { return }
        probed = true
        subs.append(channelStore.objectWillChange.sink { _ in body("pub:channelStore") })
        subs.append(nowPlaying.objectWillChange.sink { _ in body("pub:nowPlaying") })
        subs.append(favorites.objectWillChange.sink { _ in body("pub:favorites") })
        subs.append(collections.objectWillChange.sink { _ in body("pub:collections") })
        subs.append(guide.objectWillChange.sink { _ in body("pub:guide") })
        subs.append(guide.$programs.dropFirst().sink { _ in body("pub:guide.programs") })
        subs.append(guide.$isLoading.dropFirst().sink { _ in body("pub:guide.isLoading") })
    }
    private static var counts: [String: Int] = [:]
    private static var distinct: [String: Set<String>] = [:]
    private static var flushScheduled = false
    static func body(_ name: String, key: String? = nil) {
        counts[name, default: 0] += 1
        if let key { distinct[name, default: []].insert(key) }
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            // Guide rows get their own [RENDER] line (Logan 2026-09-12): the
            // question "did a publish re-evaluate 20 visible cells or all 903
            // rows" has to be answerable by grepping one tag.
            let renderKeys = ["GuideProgramCell", "GuideChannelRow", "ChannelRow"]
            let renderLine = counts.sorted { $0.key < $1.key }
                .filter { renderKeys.contains($0.key) }
                .map { "\($0.key)=\($0.value)" + (distinct[$0.key].map { " (\($0.count) distinct)" } ?? "") }
                .joined(separator: " ")
            let line = counts.sorted { $0.key < $1.key }.map {
                "\($0.key)=\($0.value)" + (distinct[$0.key].map { " (\($0.count) distinct)" } ?? "")
            }.joined(separator: " ")
            counts.removeAll(); distinct.removeAll()
            flushScheduled = false
            debugLog("[TAB] bodies/1s: \(line)")
            if !renderLine.isEmpty {
                debugLog("[RENDER] rows evaluated in the last second: \(renderLine)")
            }
        }
    }
}

#if canImport(UIKit)
/// Input-to-frame latency + render-load probe (Logan 2026-09-12: "I need you
/// to not guess. Add something in logging so you can see it.").
///
/// Three questions the existing [PRESS]/[FOCUS]/[HANG]/[TAB] lines could not
/// answer on their own:
///  1. How long does a press take to be handled, and how long until the NEXT
///     frame is actually presented. [HANG] only reports single blocks over its
///     threshold, so a main thread that is 90% busy in 200ms chunks looks
///     healthy while every press still waits seconds.
///  2. How many program cells / rows are ALIVE (not "bodies evaluated"), how
///     many CALayers the render server is carrying, and how long the slowest
///     frame took.
///  3. How long a press takes to move focus.
///
/// All three are cheap: one CADisplayLink while the guide is on screen, two
/// integer counters, and one layer-tree walk per second.
@MainActor
enum InputProbe {
    private struct Pending {
        let name: String
        let start: CFTimeInterval
        var handled: CFTimeInterval?
        var focus: CFTimeInterval?
        var logged = false
    }
    private static var pending: Pending?

    /// Called the moment the app receives the press / touch, BEFORE it is
    /// delivered. `name` is the key ("DOWN", "SELECT", "TOUCH").
    static func begin(_ name: String) {
        // A press that arrives while the previous one is still unresolved
        // means the queue is backing up: flush the old one so the log shows
        // both, with the stale one marked.
        if var old = pending, !old.logged {
            old.logged = true
            pending = nil
            debugLog("[INPUT] \(old.name) superseded after \(ms(CACurrentMediaTime() - old.start))ms (next press arrived first)")
        }
        pending = Pending(name: name, start: CACurrentMediaTime())
        // Labels the run loop turn this press causes, so a long turn that no
        // publish explains is attributed to the input instead of going
        // unattributed (2026-09-12 item e).
        MainThreadWatchdog.shared.notePublish("input \(name)")
        // End of this runloop turn = the handler (and the SwiftUI update it
        // triggered) has finished on the main thread.
        DispatchQueue.main.async {
            guard var p = pending, !p.logged, p.handled == nil else { return }
            p.handled = CACurrentMediaTime()
            pending = p
        }
        FrameProbe.armInputFrameCapture()
    }

    /// Called from the [FOCUS] tracer when the focus system reports a move.
    static func noteFocusChange() {
        guard var p = pending, p.focus == nil else { return }
        p.focus = CACurrentMediaTime()
        pending = p
    }

    /// Called by FrameProbe on the first presented frame after a press.
    static func notePresentedFrame(_ at: CFTimeInterval) {
        guard var p = pending, !p.logged else { return }
        p.logged = true
        pending = nil
        let handled = p.handled ?? at
        var line = "[INPUT] \(p.name) received -> handled \(ms(handled - p.start))ms"
        line += " -> next frame presented \(ms(at - p.start))ms"
        if let f = p.focus {
            line += " -> focus moved \(ms(f - p.start))ms"
        } else {
            line += " -> focus unchanged"
        }
        debugLog(line)
    }

    private static func ms(_ seconds: CFTimeInterval) -> Int { Int((seconds * 1000).rounded()) }

    /// iOS has no press event to swizzle, so a recognizer that never
    /// recognizes anything is attached to the key window: it sees every
    /// touch down without consuming or delaying it.
    private final class TouchSpy: UIGestureRecognizer {
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            InputProbe.begin("TOUCH")
            state = .failed
        }
    }
    private static var spy: TouchSpy?
    static func installTouchSpy() {
        guard spy == nil,
              let window = UIApplication.shared.connectedScenes
                .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return }
        let g = TouchSpy(target: nil, action: nil)
        g.cancelsTouchesInView = false
        g.delaysTouchesBegan = false
        g.delaysTouchesEnded = false
        window.addGestureRecognizer(g)
        spy = g
        debugLog("[INPUT] touch spy installed on key window")
    }
}

/// Scoped main-thread stopwatch (Logan 2026-09-12: name the work, do not
/// guess). Logs `[SLOW] <label> Nms` only when the block exceeds `threshold`,
/// so the steady state costs one CACurrentMediaTime pair and nothing is logged.
@MainActor
enum Slow {
    @discardableResult
    static func time<T>(_ label: String, threshold: Double = 0.03, _ body: () -> T) -> T {
        let t0 = CACurrentMediaTime()
        let out = body()
        let dt = CACurrentMediaTime() - t0
        if dt >= threshold { debugLog("[SLOW] \(label) \(Int((dt * 1000).rounded()))ms") }
        return out
    }
}

/// Live view/layer census. `cell` / `row` are incremented from onAppear and
/// decremented from onDisappear, so the number is what EXISTS, not what was
/// evaluated (the [TAB]/[RENDER] body counters already cover evaluation).
@MainActor
enum LiveCensus {
    private(set) static var cells = 0
    private(set) static var rows = 0
    static func cellAppeared() { cells += 1 }
    static func cellDisappeared() { cells = max(0, cells - 1) }
    static func rowAppeared() { rows += 1 }
    /// Programs compared while building each row's visible-cell slice. Shows
    /// whether the per-row lookup over the resident 72 h map is the cost.
    static var progsScanned = 0
    static func noteScan(_ n: Int) { progsScanned += n }
    static func rowDisappeared() { rows = max(0, rows - 1) }

    /// Total CALayers under the key window. Walked once per second only.
    static func layerCount() -> Int {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return 0 }
        func walk(_ layer: CALayer) -> Int {
            var n = 1
            for sub in layer.sublayers ?? [] { n += walk(sub) }
            return n
        }
        return walk(window.layer)
    }
}

/// CADisplayLink-backed frame timer. Started while the guide is on screen so
/// the log carries real frame intervals (the render server's load) next to the
/// live cell / layer counts.
@MainActor
final class FrameProbe: NSObject {
    static let shared = FrameProbe()
    private var link: CADisplayLink?
    private var lastFrame: CFTimeInterval = 0
    private var frames = 0
    private var slowFrames = 0
    private var worst: CFTimeInterval = 0
    private var lastInterval: CFTimeInterval = 0
    private var lastReport: CFTimeInterval = 0
    private var captureNextFrame = false
    private var owner = ""
    /// Refcounted: the guide and the iPhone channel list both want the probe,
    /// and one of them disappearing must not stop it under the other.
    private var clients = 0

    static func start(_ owner: String) {
        let p = shared
        p.clients += 1
        guard p.link == nil else { return }
        p.owner = owner
        p.frames = 0; p.slowFrames = 0; p.worst = 0; p.lastFrame = 0
        p.lastReport = CACurrentMediaTime()
        let link = CADisplayLink(target: p, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        p.link = link
        InputProbe.installTouchSpy()
        debugLog("[RENDER] frame probe on (\(owner))")
    }

    static func stop() {
        let p = shared
        p.clients = max(0, p.clients - 1)
        guard p.clients == 0 else { return }
        p.link?.invalidate()
        p.link = nil
        debugLog("[RENDER] frame probe off (\(p.owner))")
    }

    static func armInputFrameCapture() { shared.captureNextFrame = true }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        if lastFrame > 0 {
            lastInterval = now - lastFrame
            frames += 1
            if lastInterval > worst { worst = lastInterval }
            if lastInterval > 0.1 { slowFrames += 1 }
        }
        lastFrame = now
        if captureNextFrame {
            captureNextFrame = false
            InputProbe.notePresentedFrame(CACurrentMediaTime())
        }
        guard now - lastReport >= 1.0 else { return }
        lastReport = now
        let f = frames, slow = slowFrames
        let worstMS = Int((worst * 1000).rounded())
        let lastMS = Int((lastInterval * 1000).rounded())
        frames = 0; slowFrames = 0; worst = 0
        let scanned = LiveCensus.progsScanned
        LiveCensus.progsScanned = 0
        debugLog("[RENDER] live cells \(LiveCensus.cells), live rows \(LiveCensus.rows), layers ~\(LiveCensus.layerCount()), frames \(f)/s, last frame \(lastMS)ms, worst \(worstMS)ms, frames over 100ms: \(slow), programs scanned \(scanned)")
    }
}
#endif

// MARK: - Main Thread Sampling Profiler
//
// Why this exists (2026-09-12): the Apple TV guide spends 236-523 ms of main
// run loop time on EVERY D-pad DOWN press (n=16, median 248 ms), plus 1322 ms
// "after seedEPGCache return" and 974 ms "after loadFromCache replay #1", and
// none of our own [SLOW] breadcrumbs fire at all (nothing over 30 ms). So the
// time is inside SwiftUI/UIKit work we do not own and cannot instrument by
// hand. xctrace cannot attach to the Apple TV from this Mac (attach by name,
// by pid, and launch all fail), so the profiler has to live in the app.
//
// Shape: the MainThreadWatchdog run loop observer already brackets every main
// turn (afterWaiting -> beforeWaiting). It tells this class when a turn opens
// and closes. A dedicated sampling thread waits 100 ms after a turn opens; if
// that same turn is still open it samples the MAIN thread every 10 ms until it
// closes, using thread_suspend + thread_get_state(ARM_THREAD_STATE64) and a
// manual frame-pointer walk into a preallocated buffer. Nothing is allocated,
// locked or logged while main is suspended (any of those can deadlock against
// a malloc or os_unfair_lock main itself is holding). Symbolication with
// dladdr and the aggregation happen after the turn ends, on the sampler
// thread, so main never pays for them.
//
// Permission note: thread_get_state on a suspended thread IS permitted for
// threads of one's OWN task on tvOS and iOS device builds. The restriction
// people hit is cross-task (task_for_pid), which needs entitlements we do not
// have and do not need here. No entitlement, no debugger, no get-task-allow
// is required for self-inspection.
//
// Permanent, but gated on exactly the same switch the watchdog uses
// (DebugLogger.isEnabled / Developer Settings > Debug Logging). With the
// logger off the sampler thread is never even created.
#if arch(arm64)
final class MainThreadProfiler: @unchecked Sendable {
    static let shared = MainThreadProfiler()

    /// A turn must exceed this before sampling starts.
    private static let slowTurnThreshold: TimeInterval = 0.100
    /// Sampling period once armed.
    private static let samplePeriod: TimeInterval = 0.010
    /// Deepest frame-pointer walk per sample.
    private static let maxFrames = 48
    /// Sample ceiling per turn (48 * 600 * 8 bytes = 230 KB, a 6 s turn).
    private static let maxSamples = 600
    /// Reports per rolling minute.
    private static let maxProfilesPerMinute = 20
    /// Frames listed per report.
    private static let topFrames = 12
    private static let topLeaves = 5

    // MARK: Shared state
    //
    // Written by main (the run loop observer), read by the sampler thread.
    // `turnSeq` is the handshake: it increments on every turn close, so the
    // sampler can tell "still the turn I armed for" from "a later turn" with a
    // single scalar read and no lock. Scalar loads/stores of a UInt64 on arm64
    // are atomic; the only consumer is a liveness check, so ordering slop of
    // one sampling period is harmless.
    private var turnSeq: UInt64 = 0
    private var turnOpen: Bool = false
    private var turnStart: CFAbsoluteTime = 0
    private let reportLock = NSLock()
    private var reportMs: Int = 0
    private var reportLabel: String?

    // MARK: Sampling buffers (preallocated once, reused forever)

    private let frames: UnsafeMutablePointer<UInt64>
    private let frameCounts: UnsafeMutablePointer<Int32>
    private var sampleCount = 0

    // MARK: Main thread identity / stack bounds

    private var mainMachThread: mach_port_t = 0
    private var stackLow: UInt64 = 0
    private var stackHigh: UInt64 = 0

    private let wake = DispatchSemaphore(value: 0)
    private var started = false
    private var profileTimes: [CFAbsoluteTime] = []

    private init() {
        frames = UnsafeMutablePointer<UInt64>.allocate(capacity: Self.maxFrames * Self.maxSamples)
        frames.initialize(repeating: 0, count: Self.maxFrames * Self.maxSamples)
        frameCounts = UnsafeMutablePointer<Int32>.allocate(capacity: Self.maxSamples)
        frameCounts.initialize(repeating: 0, count: Self.maxSamples)
    }

    // MARK: Lifecycle

    /// Call from the main thread, once, when the watchdog arms its observer.
    /// No-op unless Debug Logging is on.
    func startIfEnabled() {
        guard !started, DebugLogger.shared.isEnabled else { return }
        started = true
        // mach_thread_self() returns a right that the caller owns; this one is
        // deliberately kept for the life of the process.
        mainMachThread = mach_thread_self()
        let top = UInt64(UInt(bitPattern: pthread_get_stackaddr_np(pthread_self())))
        let size = UInt64(pthread_get_stacksize_np(pthread_self()))
        stackHigh = top
        stackLow = top > size ? top - size : 0
        let t = Thread { [weak self] in self?.sampleLoop() }
        t.name = "com.aerio.mainprofiler"
        t.stackSize = 512 * 1024
        t.qualityOfService = .userInteractive
        t.start()
        debugLog("[PROFILE] main-thread sampler armed: turns > \(Int(Self.slowTurnThreshold * 1000))ms sampled every \(Int(Self.samplePeriod * 1000))ms, \(Self.maxFrames) frames")
    }

    // MARK: Observer hooks (main thread only)

    /// Run loop afterWaiting: a new main turn has begun.
    func noteTurnStart(_ now: CFAbsoluteTime) {
        guard started else { return }
        turnStart = now
        turnOpen = true
        wake.signal()
    }

    /// Run loop beforeWaiting: the turn has finished. `ms` and `label` are the
    /// same values the [HANG] line reports.
    func noteTurnEnd(ms: Int, label: String?) {
        guard started else { return }
        turnOpen = false
        reportLock.lock()
        reportMs = ms
        reportLabel = label
        reportLock.unlock()
        turnSeq &+= 1
    }

    // MARK: Sampler thread

    private func sampleLoop() {
        while true {
            wake.wait()
            // Drain any extra signals from fast turns we will not sample.
            let seq = turnSeq
            Thread.sleep(forTimeInterval: Self.slowTurnThreshold)
            guard turnOpen, turnSeq == seq else { continue }

            sampleCount = 0
            while turnOpen, turnSeq == seq, sampleCount < Self.maxSamples {
                captureOneSample()
                Thread.sleep(forTimeInterval: Self.samplePeriod)
            }
            let captured = sampleCount
            guard captured > 0 else { continue }
            // Wait for the close to publish ms/label if it has not landed yet.
            var spins = 0
            while turnSeq == seq, spins < 200 {
                Thread.sleep(forTimeInterval: 0.005)
                spins += 1
            }
            reportLock.lock()
            let ms = reportMs
            let label = reportLabel
            reportLock.unlock()
            guard allowProfile() else { continue }
            report(samples: captured, turnMs: ms, label: label)
        }
    }

    /// Suspend main, read its register state, walk the frame-pointer chain into
    /// the preallocated buffer, resume. Absolutely no allocation, locking,
    /// logging or ObjC/Swift runtime calls between suspend and resume.
    private func captureOneSample() {
        let thread = mainMachThread
        guard thread != 0 else { return }
        let slot = frames + (sampleCount * Self.maxFrames)
        var depth: Int32 = 0

        guard thread_suspend(thread) == KERN_SUCCESS else { return }

        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<UInt32>.size)
        let kr = withUnsafeMutablePointer(to: &state) { statePtr -> kern_return_t in
            statePtr.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { raw in
                thread_get_state(thread, thread_state_flavor_t(ARM_THREAD_STATE64), raw, &count)
            }
        }
        if kr == KERN_SUCCESS {
            let pc = UInt64(state.__pc)
            let lr = UInt64(state.__lr)
            var fp = UInt64(state.__fp)
            if pc != 0 { slot[Int(depth)] = pc; depth += 1 }
            if lr != 0, depth < Int32(Self.maxFrames) { slot[Int(depth)] = lr; depth += 1 }
            var previousFP: UInt64 = 0
            while depth < Int32(Self.maxFrames),
                  fp != 0,
                  fp > previousFP,                       // chain must climb
                  fp % 16 == 0,                          // AAPCS64 alignment
                  fp >= stackLow,
                  fp + 16 <= stackHigh {
                let record = UnsafeRawPointer(bitPattern: UInt(fp))
                guard let record else { break }
                let nextFP = record.load(fromByteOffset: 0, as: UInt64.self)
                let retAddr = record.load(fromByteOffset: 8, as: UInt64.self)
                if retAddr == 0 { break }
                slot[Int(depth)] = retAddr
                depth += 1
                previousFP = fp
                fp = nextFP
            }
        }

        thread_resume(thread)

        guard depth > 0 else { return }
        frameCounts[sampleCount] = depth
        sampleCount += 1
    }

    // MARK: Rate limiting

    private func allowProfile() -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        profileTimes.removeAll { now - $0 > 60 }
        guard profileTimes.count < Self.maxProfilesPerMinute else { return false }
        profileTimes.append(now)
        return true
    }

    // MARK: Symbolication + aggregation (sampler thread, main already running)

    private func report(samples: Int, turnMs: Int, label: String?) {
        var inclusive: [String: Int] = [:]
        var leaves: [String: Int] = [:]
        var symbolCache: [UInt64: String] = [:]
        var seenInSample = Set<String>()

        for s in 0..<samples {
            let depth = Int(frameCounts[s])
            guard depth > 0 else { continue }
            let slot = frames + (s * Self.maxFrames)
            seenInSample.removeAll(keepingCapacity: true)
            for f in 0..<depth {
                let addr = slot[f]
                let name: String
                if let cached = symbolCache[addr] {
                    name = cached
                } else {
                    let resolved = Self.symbolize(addr)
                    symbolCache[addr] = resolved
                    name = resolved
                }
                // Inclusive: count a function once per sample even if recursive.
                if seenInSample.insert(name).inserted {
                    inclusive[name, default: 0] += 1
                }
                if f == 0 { leaves[name, default: 0] += 1 }
            }
        }

        let suffix = label.map { " \($0)" } ?? ""
        debugLog("[PROFILE] turn \(turnMs)ms\(suffix): \(samples) samples")
        for (name, n) in inclusive.sorted(by: { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }).prefix(Self.topFrames) {
            debugLog("  \(Self.pct(n, samples))  \(name)")
        }
        debugLog("[PROFILE]   leaves:")
        for (name, n) in leaves.sorted(by: { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }).prefix(Self.topLeaves) {
            debugLog("  \(Self.pct(n, samples))  \(name)")
        }
    }

    private static func pct(_ n: Int, _ total: Int) -> String {
        let p = total > 0 ? Int((Double(n) / Double(total) * 100).rounded()) : 0
        return String(format: "%2d%%", min(p, 100))
    }

    /// dladdr-based symbolication. CoreSymbolication is not available to us, so
    /// a debug build yields Swift-mangled names; demangle through
    /// swift_demangle when the runtime exposes it (it does on device, it is
    /// public in libswiftCore), otherwise print the mangled name as-is.
    private static func symbolize(_ addr: UInt64) -> String {
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(bitPattern: UInt(addr)), &info) != 0 else {
            return String(format: "0x%llx (unknown)", addr)
        }
        let image: String
        if let fname = info.dli_fname {
            let path = String(cString: fname)
            image = (path as NSString).lastPathComponent
        } else {
            image = "?"
        }
        guard let sname = info.dli_sname else {
            let offset = addr - UInt64(UInt(bitPattern: info.dli_fbase))
            return String(format: "%@ +0x%llx (%@)", "<no symbol>", offset, image)
        }
        let raw = String(cString: sname)
        return "\(demangle(raw)) (\(image))"
    }

    private typealias SwiftDemangleFn = @convention(c) (
        UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32
    ) -> UnsafeMutablePointer<CChar>?

    private static let demangler: SwiftDemangleFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle") else { return nil }
        return unsafeBitCast(sym, to: SwiftDemangleFn.self)
    }()

    private static func demangle(_ name: String) -> String {
        guard name.hasPrefix("$s") || name.hasPrefix("_$s") || name.hasPrefix("$S"),
              let fn = demangler else { return name }
        return name.withCString { cstr -> String in
            guard let out = fn(cstr, strlen(cstr), nil, nil, 0) else { return name }
            defer { free(out) }
            return String(cString: out)
        }
    }
}
#endif
