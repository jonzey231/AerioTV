import Foundation

/// Captures a live HTTP stream (TS/HLS) to a local file. Uses
/// `URLSessionDataDelegate` to stream raw bytes directly to disk without
/// buffering the whole thing in memory. Foreground-only - iOS suspends
/// this within ~30 seconds of backgrounding.
///
/// Usage:
///   let session = LocalRecordingSession(streamURL: url, filePath: path)
///   try await session.start()   // fire-and-forget; see start() docs
///   // ... later, when recording should end:
///   await session.stop()
///   let bytes = await session.getBytesWritten()
actor LocalRecordingSession: NSObject {
    let streamURL: URL
    let filePath: String
    /// Optional User-Agent override. If nil the system default is used.
    let userAgent: String?

    private var writer: StreamFileWriter?
    private var urlSession: URLSession?
    private var dataTask: URLSessionDataTask?
    private var isStopped = false

    /// Bytes written to disk so far. Backed by the lock-guarded writer, so it
    /// stays accurate after stop() (the writer is closed but retained). Reads
    /// 0 before start().
    func getBytesWritten() -> Int64 { writer?.byteCount ?? 0 }

    init(streamURL: URL, filePath: String, userAgent: String? = nil) {
        self.streamURL = streamURL
        self.filePath = filePath
        self.userAgent = userAgent
        super.init()
    }

    /// Begins the recording. This is fire-and-forget: it creates the file and
    /// kicks off the data task, then returns. It throws ONLY on local file /
    /// directory setup failure. A bad URL or unreachable host is not surfaced
    /// here - the task simply captures 0 bytes and reports the failure later
    /// via the completion path. (An earlier version's doc claimed start()
    /// waited for the first byte and threw on connection failure; it never
    /// did, and the unused `continuation` field that would have implemented
    /// that has been removed.)
    func start() async throws {
        guard writer == nil else { return }

        // Ensure the parent directory exists.
        let dir = (filePath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // Create (or truncate) the destination file via the writer.
        guard let w = StreamFileWriter(path: filePath) else {
            throw RecordingError.fileCreationFailed(filePath)
        }
        writer = w

        // Build a dedicated URLSession with `.utility` QoS so recording
        // I/O yields to the MPV render thread under contention.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 0 // no global timeout - recording length is unbounded
        config.networkServiceType = .default
        let delegateQueue = OperationQueue()
        delegateQueue.qualityOfService = .utility
        delegateQueue.maxConcurrentOperationCount = 1 // serial: chunks arrive in order
        // The delegate appends each chunk SYNCHRONOUSLY on this serial queue,
        // so bytes land on disk in arrival order. The previous version hopped
        // every chunk onto the actor via `Task { await didReceive(data) }`;
        // those per-chunk tasks were scheduled independently on the actor's
        // executor with no ordering guarantee, so writes could run out of
        // order and scramble the .ts (mpv then failed to demux it). Writing
        // inline on the serial delegate queue removes that race entirely.
        let delegate = SessionDelegate(writer: w) { [weak self] err in
            Task { await self?.didComplete(error: err) }
        }
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
    /// down the URLSession. Idempotent. The writer is closed but kept so
    /// getBytesWritten() still returns the final count afterward.
    func stop() {
        guard !isStopped else { return }
        isStopped = true
        dataTask?.cancel()
        dataTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        writer?.close()
        debugLog("🔴 LocalRecordingSession: stopped - \(writer?.byteCount ?? 0) bytes written")
    }

    /// Called by the delegate when the task completes (server closed the
    /// connection, an error occurred, or we cancelled it on a write failure).
    fileprivate func didComplete(error: Error?) {
        if let error, !isStopped {
            debugLog("🔴 LocalRecordingSession: stream ended with error - \(error.localizedDescription)")
        }
        stop()
    }
}

// MARK: - Serial file writer (thread-safe, lock-guarded)
//
// Owns the FileHandle OFF the actor so the URLSession delegate can append
// bytes synchronously on its serial delegate queue, preserving arrival order
// (the whole point of the recording fix). The lock only guards the rare
// overlap between a late delegate write and the actor's stop()-driven
// close(); on the steady-state write path it is uncontended.
private final class StreamFileWriter {
    private let lock = NSLock()
    private var handle: FileHandle?
    private var bytes: Int64 = 0

    init?(path: String) {
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let h = FileHandle(forWritingAtPath: path) else { return nil }
        handle = h
    }

    /// Appends a chunk in order. Returns false on a write error (the caller
    /// should cancel the task). A write after close() is a silent no-op.
    @discardableResult
    func write(_ data: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let h = handle else { return true }
        do {
            try h.write(contentsOf: data)
            bytes += Int64(data.count)
            return true
        } catch {
            return false
        }
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        try? handle?.close()
        handle = nil
    }

    var byteCount: Int64 {
        lock.lock(); defer { lock.unlock() }
        return bytes
    }
}

// MARK: - URLSessionDataDelegate bridge
//
// `LocalRecordingSession` is an actor and can't directly conform to
// `URLSessionDataDelegate` (delegate methods are called on the delegate
// queue, not the actor's executor). This plain NSObject shim writes each
// chunk straight to the lock-guarded writer on the serial delegate queue,
// so writes stay in arrival order without hopping onto the actor.

private final class SessionDelegate: NSObject, URLSessionDataDelegate {
    private let writer: StreamFileWriter
    private let onComplete: (Error?) -> Void

    init(writer: StreamFileWriter, onComplete: @escaping (Error?) -> Void) {
        self.writer = writer
        self.onComplete = onComplete
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        // Synchronous, ordered append on the serial delegate queue.
        if !writer.write(data) {
            debugLog("🔴 LocalRecordingSession: write error - cancelling task")
            dataTask.cancel() // triggers didCompleteWithError → onComplete → stop()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        onComplete(error)
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
