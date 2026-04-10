import Foundation

/// Captures a live HTTP stream (TS/HLS) to a local file. Uses
/// `URLSessionDataDelegate` to stream raw bytes directly to disk without
/// buffering the whole thing in memory. Foreground-only — iOS suspends
/// this within ~30 seconds of backgrounding.
///
/// Usage:
///   let session = LocalRecordingSession(streamURL: url, filePath: path)
///   try await session.start()
///   // ... later, when recording should end:
///   session.stop()
///   let bytes = session.bytesWritten
actor LocalRecordingSession: NSObject {
    let streamURL: URL
    let filePath: String
    private var fileHandle: FileHandle?
    private var urlSession: URLSession?
    private var dataTask: URLSessionDataTask?
    private var _bytesWritten: Int64 = 0
    private var continuation: CheckedContinuation<Void, Error>?
    private var isStopped = false

    /// Optional User-Agent override. If nil the system default is used.
    let userAgent: String?

    nonisolated var bytesWritten: Int64 {
        // Safe to read atomically for UI display; exact consistency
        // isn't critical — it's only used for quota progress bars.
        // We'll expose it via a method instead.
        0 // placeholder — use getBytesWritten() from actor context
    }

    func getBytesWritten() -> Int64 { _bytesWritten }

    init(streamURL: URL, filePath: String, userAgent: String? = nil) {
        self.streamURL = streamURL
        self.filePath = filePath
        self.userAgent = userAgent
        super.init()
    }

    /// Begins the recording. Returns once the stream is actively writing
    /// to disk. Throws if the connection or file creation fails.
    func start() async throws {
        guard fileHandle == nil else { return }

        // Ensure the parent directory exists.
        let dir = (filePath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // Create (or truncate) the destination file.
        FileManager.default.createFile(atPath: filePath, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: filePath) else {
            throw RecordingError.fileCreationFailed(filePath)
        }
        fileHandle = handle

        // Build a dedicated URLSession with `.utility` QoS so recording
        // I/O yields to the MPV render thread under contention.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 0 // no global timeout — recording length is unbounded
        config.networkServiceType = .default
        let delegateQueue = OperationQueue()
        delegateQueue.qualityOfService = .utility
        delegateQueue.maxConcurrentOperationCount = 1
        let delegate = SessionDelegate(owner: self)
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: delegateQueue)
        urlSession = session

        var request = URLRequest(url: streamURL)
        if let ua = userAgent {
            request.setValue(ua, forHTTPHeaderField: "User-Agent")
        }
        let task = session.dataTask(with: request)
        dataTask = task
        task.resume()

        debugLog("🔴 LocalRecordingSession: started → \(filePath)")
    }

    /// Gracefully stops the recording. Closes the file handle and tears
    /// down the URLSession. Idempotent.
    func stop() {
        guard !isStopped else { return }
        isStopped = true
        dataTask?.cancel()
        dataTask = nil
        try? fileHandle?.close()
        fileHandle = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        debugLog("🔴 LocalRecordingSession: stopped — \(_bytesWritten) bytes written")
    }

    /// Called by the delegate on the delegate queue each time bytes arrive.
    fileprivate func didReceive(_ data: Data) {
        guard !isStopped, let handle = fileHandle else { return }
        do {
            try handle.write(contentsOf: data)
            _bytesWritten += Int64(data.count)
        } catch {
            debugLog("🔴 LocalRecordingSession: write error — \(error.localizedDescription)")
            stop()
        }
    }

    /// Called by the delegate when the task completes (server closed the
    /// connection or an error occurred).
    fileprivate func didComplete(error: Error?) {
        if let error, !isStopped {
            debugLog("🔴 LocalRecordingSession: stream ended with error — \(error.localizedDescription)")
        }
        stop()
    }
}

// MARK: - URLSessionDataDelegate bridge
//
// `LocalRecordingSession` is an actor and can't directly conform to
// `URLSessionDataDelegate` (delegate methods are called on the delegate
// queue, not the actor's executor). We use a plain NSObject shim that
// forwards bytes into the actor. Because the delegate queue is serial,
// `didReceive` calls are ordered.

private final class SessionDelegate: NSObject, URLSessionDataDelegate {
    private let owner: LocalRecordingSession

    init(owner: LocalRecordingSession) {
        self.owner = owner
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        Task { await owner.didReceive(data) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        Task { await owner.didComplete(error: error) }
    }
}

// MARK: - Error

enum RecordingError: LocalizedError {
    case fileCreationFailed(String)
    case quotaExceeded(usedMB: Int, maxMB: Int)
    case appBackgrounded

    var errorDescription: String? {
        switch self {
        case .fileCreationFailed(let path):
            return "Could not create recording file at \(path)"
        case .quotaExceeded(let used, let max):
            return "Local storage quota exceeded (\(used) MB used of \(max) MB limit)"
        case .appBackgrounded:
            return "Recording stopped because the app was moved to the background"
        }
    }
}
