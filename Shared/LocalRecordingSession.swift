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
private final class StreamFileWriter: @unchecked Sendable {
    // @unchecked Sendable: every access to `handle` / `bytes` is serialized by
    // `lock`, so the type is genuinely safe to hand to the URLSession delegate
    // (a Sendable-conforming class) and read from the actor.
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
    private let onComplete: @Sendable (Error?) -> Void

    init(writer: StreamFileWriter, onComplete: @escaping @Sendable (Error?) -> Void) {
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

// MARK: - Live Rewind (timeshift buffer engine)
//
// Port of the Android Live Rewind engine (AerioTV-Android
// core/timeshift/, verified on the Google TV Streamer), with the Apple
// twist that makes it simpler: the app owns the ONE live connection and
// the player consumes from the buffer, so pausing the player never
// stops the buffer from filling. No independent-filler dance.
//
// - Segments are plain slices of the wire TS byte stream: seg_<wallMs>.ts,
//   ~6s each, cut on 188-byte packet boundaries. Readers stitch them
//   back bit-identically.
// - Every NEW connection joins Dispatcharr's /proxy/ts mid-packet, so
//   the writer re-scans for a three-packet-verified 0x47 sync before
//   consuming bytes (the "constant freezing" fix from the Android
//   field test).
// - The rewind depth rings the active session; a retention reaper and
//   a storage budget bound total disk across sessions.
// - mpv consumes via the "aeriots" stream_cb protocol registered in
//   MPVPlayerView (live = head-follow; rewind = re-tune at an offset).
//   The AVPlayer dev engine will consume via TSHLSRemuxer fed from
//   this same connection (P1 phase 2).

/// One rolling buffer session for a live channel. Thread-safe writer;
/// created and owned by `LiveRewindEngine`.
final class LiveRewindBuffer: @unchecked Sendable {
    static let segmentMs: Int64 = 6_000
    static let tsPacket = 188

    let sessionDir: URL
    let sessionStartMs: Int64
    private let depthMs: Int64
    private let lock = NSLock()
    private var handle: FileHandle?
    private var currentSegStartMs: Int64 = 0
    private var carry = Data()
    private var needResync = true
    private(set) var closed = false

    /// Wall time of the newest byte on disk (the buffer's live edge).
    /// Plain vars guarded by `lock`; snapshot reads are fine for UI.
    private(set) var headWallMs: Int64
    /// Wall time of the oldest byte still on disk (ring tail).
    private(set) var tailWallMs: Int64

    init(sessionDir: URL, depthMs: Int64) {
        self.sessionDir = sessionDir
        self.sessionStartMs = Int64(Date().timeIntervalSince1970 * 1000)
        self.depthMs = depthMs
        self.headWallMs = sessionStartMs
        self.tailWallMs = sessionStartMs
    }

    /// The NEXT appended bytes come from a fresh connection: drop the
    /// packet-fragment carry and re-scan for TS sync.
    func markDiscontinuity() {
        lock.lock(); defer { lock.unlock() }
        carry.removeAll(keepingCapacity: true)
        needResync = true
    }

    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard !closed, !data.isEmpty else { return }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var merged = carry.isEmpty ? data : carry + data
        if needResync {
            guard let sync = Self.findSync(in: merged) else {
                // Keep a tail so a boundary-spanning pattern is found.
                carry = merged.suffix(Self.tsPacket * 2 + 1)
                return
            }
            merged = merged.subdata(in: sync..<merged.count)
            needResync = false
        }
        let whole = (merged.count / Self.tsPacket) * Self.tsPacket
        carry = whole < merged.count ? merged.subdata(in: whole..<merged.count) : Data()
        guard whole > 0 else { return }

        if handle == nil || now - currentSegStartMs >= Self.segmentMs {
            rollSegmentLocked(now: now)
        }
        handle?.write(merged.prefix(whole))
        headWallMs = now
    }

    /// First index with 0x47 at i, i+188, i+376 (three-packet verify).
    static func findSync(in buf: Data) -> Int? {
        let p = tsPacket
        guard buf.count > 2 * p else { return nil }
        let limit = buf.count - 2 * p - 1
        var i = 0
        while i <= limit {
            if buf[buf.startIndex + i] == 0x47,
               buf[buf.startIndex + i + p] == 0x47,
               buf[buf.startIndex + i + 2 * p] == 0x47 {
                return i
            }
            i += 1
        }
        return nil
    }

    private func rollSegmentLocked(now: Int64) {
        try? handle?.close()
        let url = sessionDir.appendingPathComponent("seg_\(now).ts")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        currentSegStartMs = now
        // Ring: evict segments fully past the rewind depth.
        let cutoff = now - depthMs
        for seg in Self.listSegments(in: sessionDir) where seg.startWallMs + Self.segmentMs < cutoff {
            try? FileManager.default.removeItem(at: seg.url)
        }
        tailWallMs = Self.listSegments(in: sessionDir).first?.startWallMs ?? now
    }

    struct Segment { let url: URL; let startWallMs: Int64 }

    static func listSegments(in dir: URL) -> [Segment] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { url -> Segment? in
            let name = url.lastPathComponent
            guard name.hasPrefix("seg_"), name.hasSuffix(".ts"),
                  let ms = Int64(name.dropFirst(4).dropLast(3)) else { return nil }
            return Segment(url: url, startWallMs: ms)
        }.sorted { $0.startWallMs < $1.startWallMs }
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        closed = true
        try? handle?.close()
        handle = nil
    }
}

/// Sequential reader over a session's segment files, starting at a
/// wall-clock time; tails the writer at the head. One instance per mpv
/// stream_cb open. Mirrors Android's TimeshiftDataSource: byte offset
/// inside a segment is interpolated (TS is near-CBR over 6s), the
/// demuxer resyncs on the next packet.
final class LiveRewindReader: @unchecked Sendable {
    private let buffer: LiveRewindBuffer
    private var segments: [LiveRewindBuffer.Segment]
    private var segIndex = 0
    private var handle: FileHandle?
    private(set) var startWallMs: Int64 = 0

    /// mode: fromWallMs == nil means "live" (join a few seconds behind
    /// the head so playback has runway).
    init?(buffer: LiveRewindBuffer, fromWallMs: Int64?) {
        self.buffer = buffer
        self.segments = LiveRewindBuffer.listSegments(in: buffer.sessionDir)
        // Live join: 4s behind head. Rewind: clamp into the window.
        let target: Int64
        if let t = fromWallMs {
            target = max(buffer.tailWallMs, min(t, buffer.headWallMs))
        } else {
            target = max(buffer.tailWallMs, buffer.headWallMs - 4_000)
        }
        startWallMs = target
        // Wait briefly for the first segment on a brand-new session.
        var tries = 0
        while segments.isEmpty && tries < 100 && !buffer.closed {
            Thread.sleep(forTimeInterval: 0.1)
            segments = LiveRewindBuffer.listSegments(in: buffer.sessionDir)
            tries += 1
        }
        guard !segments.isEmpty else { return nil }
        segIndex = max(0, segments.lastIndex(where: { $0.startWallMs <= target }) ?? 0)
        let seg = segments[segIndex]
        guard let h = try? FileHandle(forReadingFrom: seg.url) else { return nil }
        let segEnd = segments.indices.contains(segIndex + 1)
            ? segments[segIndex + 1].startWallMs : buffer.headWallMs
        let span = max(1, segEnd - seg.startWallMs)
        let size = (try? FileManager.default.attributesOfItem(atPath: seg.url.path)[.size] as? Int64) ?? 0
        var offset = Int64(Double(size) * (Double(target - seg.startWallMs) / Double(span)))
        offset -= offset % Int64(LiveRewindBuffer.tsPacket)
        try? h.seek(toOffset: UInt64(max(0, offset)))
        handle = h
    }

    /// Blocking read: waits at the write head (the mpv stream thread is
    /// dedicated, brief sleeps are fine). Returns 0 only when the
    /// session is closed and drained (EOF), -1 on unrecoverable error.
    func read(into dest: UnsafeMutableRawPointer, max nbytes: Int) -> Int {
        var waits = 0
        while true {
            if let h = handle,
               let data = try? h.read(upToCount: nbytes),
               !data.isEmpty {
                data.withUnsafeBytes { raw in
                    dest.copyMemory(from: raw.baseAddress!, byteCount: data.count)
                }
                return data.count
            }
            // Current segment exhausted: advance if a newer one exists.
            let fresh = LiveRewindBuffer.listSegments(in: buffer.sessionDir)
            if !fresh.isEmpty {
                let currentStart = segments.indices.contains(segIndex)
                    ? segments[segIndex].startWallMs : -1
                guard let freshIdx = fresh.firstIndex(where: { $0.startWallMs == currentStart }) else {
                    // Ring evicted the segment under us (paused past the
                    // rewind depth). Error out; the player-side recovery
                    // re-tunes at the buffer tail.
                    return -1
                }
                if freshIdx < fresh.count - 1 {
                    segments = fresh
                    segIndex = freshIdx + 1
                    try? handle?.close()
                    handle = try? FileHandle(forReadingFrom: segments[segIndex].url)
                    continue
                }
                segments = fresh
            }
            if buffer.closed { return 0 }
            if waits > 600 { return -1 } // 60s stalled: give up
            waits += 1
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    func close() {
        try? handle?.close()
        handle = nil
    }
}

/// Session arbiter + the app-owned live connection. Fullscreen
/// single-stream live only (v1 scope); PlayerView/MPV start and stop
/// sessions around playback.
final class LiveRewindEngine: NSObject, ObservableObject, @unchecked Sendable {
    static let shared = LiveRewindEngine()

    static let defaultRetentionMs: Int64 = 24 * 60 * 60 * 1000
    static let defaultBudgetBytes: Int64 = 10 * 1024 * 1024 * 1024

    /// UI-facing state (mirrors Android's TimeshiftController.State).
    @Published private(set) var buffering = false
    @Published var timeshifting = false
    @Published var baseWallMs: Int64 = 0
    @Published private(set) var tailWallMs: Int64 = 0
    @Published private(set) var headWallMs: Int64 = 0

    /// Guards every mutable field below. mpv's queue, the URLSession
    /// delegate queue, and the main thread all call in; the buffer
    /// itself has its own lock.
    private let stateLock = NSLock()
    private(set) var activeBuffer: LiveRewindBuffer?
    private var urlSession: URLSession?
    private var task: URLSessionDataTask?
    private var reconnectAttempts = 0
    private(set) var liveURL: URL?
    private(set) var liveHeaders: [String: String] = [:]
    private var windowTimer: Timer?
    /// Wall time the CURRENT mpv reader started at; written by the
    /// stream_cb open callback (mpv thread), read by the position
    /// mapping. The player's base offset for display math.
    private(set) var readerBaseWallMs: Int64 = 0

    func noteTimeshifting(_ on: Bool) {
        Task { @MainActor in self.timeshifting = on }
    }

    func noteReaderStart(_ wallMs: Int64) {
        stateLock.lock(); readerBaseWallMs = wallMs; stateLock.unlock()
        Task { @MainActor in self.baseWallMs = wallMs }
    }

    /// Thread-safe buffer access for the stream_cb open callback.
    var bufferForReader: LiveRewindBuffer? {
        stateLock.lock(); defer { stateLock.unlock() }
        return activeBuffer
    }

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "liveRewindEnabled")
    }
    var depthMinutes: Int {
        let v = UserDefaults.standard.integer(forKey: "liveRewindDepthMinutes")
        return v > 0 ? v : 30
    }

    private var rootDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("LiveRewind", isDirectory: true)
    }

    /// Begin buffering; returns false when the pref is off or setup
    /// failed (caller falls back to direct playback).
    func startSession(channelID: String, channelName: String, streamURL: URL, headers: [String: String]) -> Bool {
        guard isEnabled else { return false }
        stopSession()
        pruneExpired()
        enforceBudget()
        let dir = rootDir.appendingPathComponent("sess_\(Int64(Date().timeIntervalSince1970 * 1000))", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // Rewind buffers are large and regenerable: never in iCloud
            // backups (first backup-exclusion use in this codebase).
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableDir = dir
            try? mutableDir.setResourceValues(values)
        } catch {
            debugLog("[REWIND] session dir create failed: \(error)")
            return false
        }
        let buffer = LiveRewindBuffer(sessionDir: dir, depthMs: Int64(depthMinutes) * 60_000)
        stateLock.lock()
        activeBuffer = buffer
        liveURL = streamURL
        liveHeaders = headers
        reconnectAttempts = 0
        stateLock.unlock()
        Task { @MainActor in
            self.buffering = true
            self.timeshifting = false
            self.baseWallMs = 0
            self.tailWallMs = buffer.sessionStartMs
            self.headWallMs = buffer.sessionStartMs
            self.startWindowTimer()
        }
        connect()
        debugLog("[REWIND] session start \(dir.lastPathComponent) channel=\(channelName)")
        return true
    }

    func stopSession() {
        stateLock.lock()
        task?.cancel()
        task = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        activeBuffer?.close()
        activeBuffer = nil
        stateLock.unlock()
        Task { @MainActor in
            self.windowTimer?.invalidate()
            self.windowTimer = nil
            self.buffering = false
            self.timeshifting = false
        }
    }

    private func connect() {
        stateLock.lock()
        let url0 = liveURL
        let buffer0 = activeBuffer
        stateLock.unlock()
        guard let url = url0, let buffer = buffer0, !buffer.closed else { return }
        buffer.markDiscontinuity()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 0
        config.timeoutIntervalForRequest = 30
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        var request = URLRequest(url: url)
        stateLock.lock()
        urlSession = session
        let headers = liveHeaders
        stateLock.unlock()
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        if headers["User-Agent"] == nil {
            request.setValue(DeviceInfo.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        }
        let t = session.dataTask(with: request)
        stateLock.lock(); task = t; stateLock.unlock()
        t.resume()
    }

    @MainActor
    private func startWindowTimer() {
        windowTimer?.invalidate()
        windowTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, let b = self.bufferForReader else { return }
            Task { @MainActor in
                self.tailWallMs = b.tailWallMs
                self.headWallMs = b.headWallMs
            }
        }
    }

    // MARK: retention + budget

    private func pruneExpired() {
        let cutoff = Date().addingTimeInterval(-Double(Self.defaultRetentionMs) / 1000)
        let dirs = (try? FileManager.default.contentsOfDirectory(at: rootDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for dir in dirs {
            let newest = LiveRewindBuffer.listSegments(in: dir).last
                .flatMap { try? FileManager.default.attributesOfItem(atPath: $0.url.path)[.modificationDate] as? Date }
            let stamp = newest
                ?? ((try? FileManager.default.attributesOfItem(atPath: dir.path)[.modificationDate] as? Date) ?? .distantPast)
            if stamp < cutoff { try? FileManager.default.removeItem(at: dir) }
        }
    }

    private func enforceBudget() {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: rootDir, includingPropertiesForKeys: nil)) ?? []
        var segs: [(url: URL, start: Int64, size: Int64)] = []
        for dir in dirs where dir.hasDirectoryPath {
            for seg in LiveRewindBuffer.listSegments(in: dir) {
                let size = (try? FileManager.default.attributesOfItem(atPath: seg.url.path)[.size] as? Int64) ?? 0
                segs.append((seg.url, seg.startWallMs, size))
            }
        }
        var total = segs.reduce(0) { $0 + $1.size }
        for seg in segs.sorted(by: { $0.start < $1.start }) {
            if total <= Self.defaultBudgetBytes { break }
            total -= seg.size
            try? FileManager.default.removeItem(at: seg.url)
        }
    }
}

extension LiveRewindEngine: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // Resolved PER APPEND (the Android channel-change race fix):
        // whichever session is current receives the bytes.
        guard let buffer = bufferForReader, !buffer.closed else { return }
        buffer.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        stateLock.lock()
        let alive = activeBuffer != nil && activeBuffer?.closed == false
        reconnectAttempts += 1
        let attempt = reconnectAttempts
        stateLock.unlock()
        guard alive else { return }
        // Live connection dropped: reconnect with backoff; the writer
        // realigns on the fresh mid-packet join.
        guard attempt <= 20 else {
            debugLog("[REWIND] connection lost permanently; closing session")
            stopSession()
            return
        }
        let delay = min(5.0, 0.5 * Double(attempt))
        debugLog("[REWIND] connection dropped (\(error?.localizedDescription ?? "eof")); reconnect #\(attempt) in \(delay)s")
        Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard self.bufferForReader?.closed == false else { return }
            self.connect()
        }
    }
}
