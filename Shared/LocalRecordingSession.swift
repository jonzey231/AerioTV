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
        // write(contentsOf:) throws Swift errors; the legacy write(_:)
        // raises an uncatchable ObjC exception on ENOSPC, which is a
        // realistic state here (tvOS Caches on a full 32GB box, or a
        // marathon session outrunning the budget sweep). On failure the
        // buffer self-closes; the reader EOFs and the player's relay
        // recovery takes over.
        do {
            if let h = handle { try h.write(contentsOf: merged.prefix(whole)) }
            headWallMs = now
        } catch {
            debugLog("[REWIND] segment write failed (\(error)); closing buffer")
            closed = true
            try? handle?.close()
            handle = nil
        }
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
        // Live join: slightly behind head so reads never starve, but
        // tight enough that "Go Live" lands near true live. 4s tested
        // safe but read as "3-5s delayed" on the ATV (offset + mpv's
        // ~1s startup buffering); 1.5s keeps enough runway because the
        // writer appends per network chunk (sub-second cadence) and a
        // longer provider stall is absorbed by mpv's own cache, with
        // the direct-stream fallback behind it. Rewind: clamp into the
        // window.
        let target: Int64
        if let t = fromWallMs {
            target = max(buffer.tailWallMs, min(t, buffer.headWallMs))
        } else {
            target = max(buffer.tailWallMs, buffer.headWallMs - 1_500)
        }
        startWallMs = target
        // Wait for the first segment on a brand-new session. 10s: a cold
        // channel tune can hit a transient prime-up 500 from Dispatcharr
        // followed by the engine's reconnect backoff before the first
        // byte lands (observed live on the ATV: 500 at +2s, data ~+5s).
        // A shorter "fail fast" deadline was tried and made tunes SLOWER:
        // the open failure only kicks off the re-tune/fallback ladder,
        // which costs more than waiting out the reconnect. A genuinely
        // dead session closes the buffer and exits this loop early.
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
    /// Directory-listing throttle for the read loop. Instance state, not
    /// per-call: at the live head mpv issues short reads in bursts, and
    /// a per-call counter would still re-list on nearly every call.
    private var listCountdown = 0

    func read(into dest: UnsafeMutableRawPointer, max nbytes: Int) -> Int {
        var waits = 0
        // Directory-listing throttle: at the live head the reader idles
        // in this loop constantly (mpv read-ahead pacing), and an
        // unthrottled loop re-listed the whole session directory (up to
        // ~700 files at 120-min depth) on EVERY 100ms wait. The current
        // file keeps growing in place, so most waits resume without any
        // listing; a segment roll only needs discovering within its
        // ~6-10s cadence, and the reader's head cushion plus mpv's
        // demuxer buffer absorb the <=0.5s worst-case discovery delay.
        while true {
            if let h = handle,
               let data = try? h.read(upToCount: nbytes),
               !data.isEmpty {
                data.withUnsafeBytes { raw in
                    dest.copyMemory(from: raw.baseAddress!, byteCount: data.count)
                }
                return data.count
            }
            // Current segment exhausted or grown-to-EOF: periodically
            // check whether a newer segment exists to advance into.
            if listCountdown <= 0 {
                listCountdown = 5
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
            }
            if buffer.closed { return 0 }
            if waits > 600 { return -1 } // 60s stalled: give up
            waits += 1
            listCountdown -= 1
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

    /// P2 settings-backed bounds (Android liveRewindRetentionHours /
    /// liveRewindBudgetGB parity). Defaults: 24 hours, 10 GB.
    var retentionMs: Int64 {
        let hours = UserDefaults.standard.integer(forKey: "liveRewindRetentionHours")
        return Int64(hours > 0 ? hours : 24) * 60 * 60 * 1000
    }
    var budgetBytes: Int64 {
        let gb = UserDefaults.standard.integer(forKey: "liveRewindBudgetGB")
        return Int64(gb > 0 ? gb : 10) * 1024 * 1024 * 1024
    }

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
        // tvOS: mkdir under Application Support fails with EPERM on a
        // PHYSICAL box (verified via device console 2026-07-10; the
        // simulator does not enforce it). Caches is the platform's only
        // large-file location; the OS may purge it, which is acceptable
        // for a regenerable rewind buffer.
        #if os(tvOS)
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        #else
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        #endif
        return base.appendingPathComponent("LiveRewind", isDirectory: true)
    }

    /// Begin buffering; returns false when the pref is off or setup
    /// failed (caller falls back to direct playback).
    func startSession(channelID: String, channelName: String, streamURL: URL, headers: [String: String]) -> Bool {
        guard isEnabled else { return false }
        stopSession()
        // Retention + budget sweep OFF the caller's thread: swapStream
        // routes through here on MAIN during a channel flip, and the
        // sweep walks every session directory on disk. A brand-new
        // session dir is never stale (mtime = now) and budget eviction
        // of the active session's oldest segments is the designed
        // behavior, so running the sweep concurrently is safe.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.pruneExpired()
            self?.enforceBudget()
        }
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
        // Un-invalidated URLSessions leak (each holds its delegate and
        // OperationQueue); a reconnecting session replaced the previous
        // one every cycle without invalidating it.
        urlSession?.invalidateAndCancel()
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
        var ticks = 0
        windowTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, let b = self.bufferForReader else { return }
            Task { @MainActor in
                // Delta-gate: every @Published write re-renders PlayerView
                // and the chrome whether or not the value changed; second
                // resolution is all the transport needs.
                if abs(b.tailWallMs - self.tailWallMs) >= 1_000 { self.tailWallMs = b.tailWallMs }
                if abs(b.headWallMs - self.headWallMs) >= 1_000 { self.headWallMs = b.headWallMs }
            }
            // Every ~5 minutes, re-run the retention + budget sweep so a
            // single marathon session (120-min depth on a UHD channel
            // can outgrow the budget) converges without waiting for the
            // next channel tune.
            ticks += 1
            if ticks % 600 == 0 {
                DispatchQueue.global(qos: .utility).async {
                    self.pruneExpired()
                    self.enforceBudget()
                }
            }
        }
    }

    // MARK: retention + budget

    private func pruneExpired() {
        let cutoff = Date().addingTimeInterval(-Double(retentionMs) / 1000)
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
        // Enumerate EVERY .ts under the root by modification date, not
        // just parseable seg_<wallMs> names: the AVPlayer spill files
        // (seg<seq>.ts in avp_sess_ dirs) were invisible to the budget.
        let dirs = (try? FileManager.default.contentsOfDirectory(at: rootDir, includingPropertiesForKeys: nil)) ?? []
        var segs: [(url: URL, mtime: Date, size: Int64)] = []
        for dir in dirs where dir.hasDirectoryPath {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
            for f in files where f.pathExtension == "ts" {
                let vals = try? f.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                segs.append((f, vals?.contentModificationDate ?? .distantPast, Int64(vals?.fileSize ?? 0)))
            }
        }
        var total = segs.reduce(0) { $0 + $1.size }
        for seg in segs.sorted(by: { $0.mtime < $1.mtime }) {
            if total <= budgetBytes { break }
            total -= seg.size
            try? FileManager.default.removeItem(at: seg.url)
        }
    }
}

extension LiveRewindEngine: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        // A non-200 (Dispatcharr prime-up 500, 401 re-auth window, 503
        // under load) must not pour an HTML error body into the TS
        // buffer. Cancel AND schedule the reconnect EXPLICITLY: the
        // disposition-cancel surfaces in didCompleteWithError as
        // NSURLErrorCancelled, which that handler rightly filters as
        // our own teardown - relying on it meant a prime-up 500 never
        // reconnected and the tune sat on an empty buffer until the
        // reader deadline (ATV field capture, twice).
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            debugLog("[REWIND] live connect HTTP \(http.statusCode); treating as drop")
            completionHandler(.cancel)
            handleConnectionDrop(session: session, reason: "HTTP \(http.statusCode)")
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // Resolved PER APPEND (the Android channel-change race fix):
        // whichever session is current receives the bytes.
        guard let buffer = bufferForReader, !buffer.closed else { return }
        // Data is flowing again: refund the reconnect budget so the
        // 20-attempt cap only counts CONSECUTIVE failures. Without this
        // a long session on a drop-prone provider hit the cap hours
        // later and silently closed mid-watch.
        if reconnectAttempts != 0 {
            stateLock.lock(); reconnectAttempts = 0; stateLock.unlock()
        }
        buffer.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Cancellation is OUR teardown (stopSession / a superseded
        // connect) or the non-200 disposition, which schedules its own
        // reconnect in the response handler - never a drop to retry here.
        if let e = error as NSError?, e.code == NSURLErrorCancelled { return }
        handleConnectionDrop(session: session, reason: error?.localizedDescription ?? "eof")
    }

    private func handleConnectionDrop(session: URLSession, reason: String) {
        stateLock.lock()
        // Session-identity guard: a completion from a PREVIOUS channel's
        // connection must not schedule a reconnect against the CURRENT
        // session (a stale reconnect dialed the new channel's URL a
        // second time and interleaved two byte streams into one buffer).
        let isCurrent = session === urlSession
        let alive = activeBuffer != nil && activeBuffer?.closed == false
        if isCurrent { reconnectAttempts += 1 }
        let attempt = reconnectAttempts
        let expectedBuffer = activeBuffer
        stateLock.unlock()
        guard isCurrent, alive else { return }
        // Live connection dropped: reconnect with backoff; the writer
        // realigns on the fresh mid-packet join.
        guard attempt <= 20 else {
            debugLog("[REWIND] connection lost permanently; closing session")
            stopSession()
            return
        }
        let delay = min(5.0, 0.5 * Double(attempt))
        debugLog("[REWIND] connection dropped (\(reason)); reconnect #\(attempt) in \(delay)s")
        Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            // The session this reconnect was scheduled for must still be
            // the active one when the backoff fires.
            guard let expected = expectedBuffer,
                  self.bufferForReader === expected, !expected.closed else { return }
            self.connect()
        }
    }
}

// MARK: - Catch-up HTTP relay (task #140 device fix)

/// Streams a Dispatcharr/XC timeshift URL to mpv through the aeriocu://
/// stream_cb protocol. The direct http path failed on a physical box:
/// ffmpeg's open-time end-of-duration probe issues a second request, and
/// Dispatcharr binds each timeshift session to the connection that
/// created it, so the probe killed the real stream ("no audio or video
/// data played"; the seekable=0 options provably did not suppress the
/// probe). A custom protocol with no seek/size callbacks makes the
/// probe impossible: one connection, followed 301 and all, exactly like
/// Android's UnboundedLengthDataSource.
///
/// Flow control: Dispatcharr serves the archive at line rate (measured
/// ~66 MB/s on LAN), so the reader suspends the URLSession task above
/// a high-water mark and resumes below a low-water mark; without that
/// a 2-hour programme would balloon straight into memory.
final class CatchupHTTPReader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let cond = NSCondition()
    private var chunks: [Data] = []
    private var buffered = 0
    private var finished = false
    private var failed = false
    private var suspended = false
    private var session: URLSession?
    private var task: URLSessionDataTask?

    private static let highWater = 8 * 1024 * 1024
    private static let lowWater = 4 * 1024 * 1024

    init(url: URL, headers: [String: String]) {
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 0
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let s = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        session = s
        var request = URLRequest(url: url)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let t = s.dataTask(with: request)
        task = t
        t.resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            debugLog("[CATCHUP-RELAY] HTTP \(http.statusCode)")
            cond.lock(); failed = true; cond.signal(); cond.unlock()
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        cond.lock()
        chunks.append(data)
        buffered += data.count
        if buffered > Self.highWater, !suspended {
            suspended = true
            dataTask.suspend()
        }
        cond.signal()
        cond.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        cond.lock()
        if let error, (error as NSError).code != NSURLErrorCancelled {
            // Mid-stream drop: whatever is buffered still plays, then EOF;
            // the player's catch-up EOF re-tune recovers the position.
            debugLog("[CATCHUP-RELAY] connection ended: \(error.localizedDescription)")
        }
        finished = true
        cond.signal()
        cond.unlock()
    }

    /// Blocking read for mpv's stream thread. 0 = EOF, -1 = failure.
    func read(into dest: UnsafeMutableRawPointer, max nbytes: Int) -> Int {
        cond.lock()
        defer { cond.unlock() }
        while chunks.isEmpty {
            if failed { return -1 }
            if finished { return 0 }
            cond.wait()
        }
        var first = chunks[0]
        let n = min(nbytes, first.count)
        first.withUnsafeBytes { raw in
            dest.copyMemory(from: raw.baseAddress!, byteCount: n)
        }
        if n == first.count {
            chunks.removeFirst()
        } else {
            chunks[0] = first.subdata(in: n..<first.count)
        }
        buffered -= n
        if suspended, buffered < Self.lowWater {
            suspended = false
            task?.resume()
        }
        return n
    }

    func close() {
        cond.lock()
        finished = true
        cond.signal()
        cond.unlock()
        task?.cancel()
        session?.invalidateAndCancel()
    }
}

/// URL wrapping for the aeriocu:// protocol plus the headers handoff to
/// the stream_cb open callback (which has no coordinator context).
enum CatchupRelay {
    /// Set by the player right before a catch-up loadfile.
    nonisolated(unsafe) static var currentHeaders: [String: String] = [:]

    static func wrap(_ url: URL) -> URL {
        let b64 = Data(url.absoluteString.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        return URL(string: "aeriocu://\(b64)") ?? url
    }

    static func unwrap(_ uri: String) -> URL? {
        guard uri.hasPrefix("aeriocu://") else { return nil }
        var b64 = String(uri.dropFirst("aeriocu://".count))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let str = String(data: data, encoding: .utf8) else { return nil }
        return URL(string: str)
    }
}
