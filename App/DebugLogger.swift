import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Debug-only print wrapper — compiles to nothing in release builds.
/// Replaces scattered emoji `print()` calls so they never leak in production.
@inline(__always)
func debugLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print(message())
    #endif
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

    /// The URL of the active log file (in the Documents directory).
    var logFileURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("aerio_debug_logs.txt")
    }

    /// Human-readable file size of the current log.
    var logFileSizeString: String {
        guard let url = logFileURL,
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return "Empty"
        }
        switch size {
        case 0:                    return "Empty"
        case 1..<1_024:            return "\(size) B"
        case 1_024..<(1_024*1_024): return "\(size / 1_024) KB"
        default:                   return String(format: "%.1f MB", Double(size) / Double(1_024 * 1_024))
        }
    }

    private init() {}

    // MARK: - Credential Sanitization

    /// Replaces password-like path segments in Xtream Codes stream URLs with "***".
    /// Xtream URL format: /movie/<user>/<password>/<id>.ext  or /series/… or /live/…
    /// Also strips API key query parameters.
    private static let xtreamPathRegex = try! NSRegularExpression(
        pattern: #"/(movie|series|live)/([^/]+)/([^/]+)/"#)
    private static let apiKeyRegex = try! NSRegularExpression(
        pattern: #"(api[_-]?key=)[^&\s]+"#, options: .caseInsensitive)

    static func sanitize(_ message: String) -> String {
        var result = message
        let r1 = NSRange(result.startIndex..., in: result)
        result = xtreamPathRegex.stringByReplacingMatches(in: result, range: r1,
                                                          withTemplate: "/$1/$2/***/")
        let r2 = NSRange(result.startIndex..., in: result)
        result = apiKeyRegex.stringByReplacingMatches(in: result, range: r2,
                                                      withTemplate: "$1***")
        return result
    }

    // MARK: - Enable / Disable

    @MainActor func enable() {
        UserDefaults.standard.set(true, forKey: "debugLoggingEnabled")
        writeSessionHeader()
    }

    func disable() {
        // Write a final entry then close.
        let entry = formatEntry(level: .lifecycle, category: "Logger",
                                message: "Debug logging disabled by user")
        queue.async { [weak self] in self?.appendToFile(entry) }
        UserDefaults.standard.set(false, forKey: "debugLoggingEnabled")
    }

    func clearLogs() {
        queue.async { [weak self] in
            guard let url = self?.logFileURL else { return }
            try? FileManager.default.removeItem(at: url)
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
    func logError(_ error: Error,
                  context: String,
                  file: String = #file,
                  function: String = #function,
                  line: Int = #line) {
        guard isEnabled else { return }
        let src = "\(URL(fileURLWithPath: file).lastPathComponent):\(line) \(function)"
        let msg = "[\(context)] \(error.localizedDescription) | \(String(describing: error))"
        let entry = formatEntry(level: .error, category: "Error", message: msg, source: src)
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
    func logPlayback(event: String, url: String? = nil, detail: String? = nil) {
        guard isEnabled else { return }
        var msg = event
        if let u = url    { msg += " | \(u)" }
        if let d = detail { msg += " | \(d)" }
        let entry = formatEntry(level: .lifecycle, category: "Playback", message: msg)
        queue.async { [weak self] in self?.appendToFile(entry) }
    }

    /// Log an EPG operation.
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
        let entry = formatEntry(level: level, category: "EPG", message: msg)
        queue.async { [weak self] in self?.appendToFile(entry) }
    }

    /// Log a channel list load operation.
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
        let entry = formatEntry(level: level, category: "Channels", message: msg)
        queue.async { [weak self] in self?.appendToFile(entry) }
    }

    /// Log an app lifecycle event (foreground, background, launch, terminate).
    func logLifecycle(_ event: String) {
        guard isEnabled else { return }
        let entry = formatEntry(level: .lifecycle, category: "Lifecycle", message: event)
        queue.async { [weak self] in self?.appendToFile(entry) }
    }

    /// Log a timed operation for performance tracking.
    func logPerformance(operation: String, duration: TimeInterval, detail: String? = nil) {
        guard isEnabled else { return }
        var msg = "\(operation): \(String(format: "%.2f ms", duration * 1_000))"
        if let d = detail { msg += " | \(d)" }
        let entry = formatEntry(level: .perf, category: "Performance", message: msg)
        queue.async { [weak self] in self?.appendToFile(entry) }
    }

    /// Log a decoding / parsing error with the raw payload snippet.
    func logDecodeError(type: String, error: Error, payloadSnippet: String? = nil) {
        guard isEnabled else { return }
        var msg = "Decode failed for \(type): \(error.localizedDescription)"
        if let snippet = payloadSnippet {
            let preview = snippet.prefix(200)
            msg += " | payload: \(preview)"
        }
        let entry = formatEntry(level: .error, category: "Decode", message: msg)
        queue.async { [weak self] in self?.appendToFile(entry) }
    }

    // MARK: - Session Header

    @MainActor private func writeSessionHeader() {
        // Capture @MainActor-isolated UIDevice values before entering the background queue.
#if canImport(UIKit)
        let capturedModel   = UIDevice.current.model
        let capturedSysName = UIDevice.current.systemName
        let capturedSysVer  = UIDevice.current.systemVersion
#endif
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
            Aerio Debug Session — \(self.timestampFormatter.string(from: Date()))
            App Version : \(version) (\(build))
            Device      : \(deviceModel)
            System      : \(systemInfo)
            Memory      : \(memInfo)
            ════════════════════════════════════════════════════════

            """
            self.appendToFile(header)
        }
    }

    // MARK: - Formatting & I/O

    private func formatEntry(level: LogLevel,
                             category: String,
                             message: String,
                             source: String? = nil) -> String {
        let ts  = timestampFormatter.string(from: Date())
        var line = "[\(ts)] \(level.icon) [\(level.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0))] [\(category)] \(message)"
        if let src = source { line += "  — \(src)" }
        return line + "\n"
    }

    private func appendToFile(_ text: String) {
        guard let url = logFileURL else { return }
        guard let data = text.data(using: .utf8) else { return }

        // Rotate if the file has grown beyond the limit.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int, size > maxFileSize {
            rotateLog(at: url)
        }

        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(data)
            }
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Rename the current log to debug_logs_archive.txt and start fresh.
    private func rotateLog(at url: URL) {
        let archiveURL = url.deletingLastPathComponent()
            .appendingPathComponent("aerio_debug_logs_archive.txt")
        try? FileManager.default.removeItem(at: archiveURL)
        try? FileManager.default.moveItem(at: url, to: archiveURL)
        let note = "[\(timestampFormatter.string(from: Date()))] ℹ️ [INFO    ] [Logger] Log rotated — previous log saved as aerio_debug_logs_archive.txt\n"
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
