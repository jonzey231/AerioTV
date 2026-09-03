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

    // Splice overlap trimmer (Android parity: AerioTV-Android 60f4476,
    // GH #51). Dispatcharr serves a joining connection the last
    // new_client_behind_seconds (~5s default) as an instant burst, so
    // every reconnect used to append a duplicate region with a backwards
    // PTS jump - the demuxer chews through it as visual artifacts and
    // A/V desync when playback crosses the splice. On a discontinuity we
    // snapshot a fingerprint of the last [overlapRun] packet hashes and
    // DISCARD the new connection's packets until that run reappears -
    // the splice then continues bit-exactly. Streaming, nothing held
    // back; bounded by [overlapSearchCap] bytes / [overlapSearchMs] so a
    // server with join replay disabled costs at most a small
    // packet-aligned gap.
    static let overlapRun = 16

    /// GH #55: byte cap on the overlap hunt, now used ONLY when the
    /// stream carries no usable PCR.
    ///
    /// It used to be the primary bound and it was the bug (identical
    /// code shipped on both platforms). The hunt discards as it scans,
    /// so hitting the cap threw away 8 MiB of already-arrived video.
    /// Destro706's Android logs on GH #55 show the fingerprint was
    /// never once found and the cap was hit every time, always within
    /// 436-1068 ms, i.e. the bytes arrive at 60-150 Mbps. That is a
    /// server backlog burst, not live video: the join replay starts
    /// BEHIND our head, so our head fingerprint lies in the burst's
    /// future and can never appear, and we then binned several seconds
    /// of good video and spliced a hard hole. The hole breaks PTS
    /// continuity, which is the audio discontinuity storm in the logs.
    static let overlapSearchCap = 8 * 1024 * 1024
    static let overlapSearchMs: Int64 = 3_000

    /// GH #55: seatbelt for the PCR-steered hunt. Its stop condition is
    /// "the new connection's clock passed our head", which a real replay
    /// always reaches, so this only fires on a runaway backlog or a
    /// server that restamps its clock.
    static let overlapPcrSearchMs: Int64 = 15_000

    /// PCR is a 33-bit 90 kHz counter; it wraps roughly every 26.5 hours.
    private static let pcrWrap: Int64 = 1 << 33

    private var recentHashes: [Int32] = []
    private var spliceTarget: [Int32]?
    private var discardActive = false
    private var matchLen = 0
    private var discardedBytes = 0
    private var discardStartMs: Int64 = 0

    // GH #55 PCR steering. The byte fingerprint only works when the new
    // connection replays bit-identical bytes that our head lies inside;
    // the stream's own clock says definitively whether incoming bytes
    // sit behind our head (replay, discard) or past it (fresh, keep).
    /// Last PCR committed to the buffer, 90 kHz base; -1 = none seen.
    private var headPcr: Int64 = -1
    /// PID that carried `headPcr`, so a second program on the same mux
    /// cannot be mistaken for the clock being tracked.
    private var headPcrPid = -1
    private var spliceAnchorPcr: Int64 = -1
    private var spliceAnchorPid = -1
    /// Set once the discard scan sees any PCR on the anchor PID; while
    /// false the byte cap is still the only available bound.
    private var sawAnchorPcr = false

    /// The NEXT appended bytes come from a fresh connection: drop the
    /// packet-fragment carry and re-scan for TS sync, then arm the
    /// overlap trimmer. Two independent stop signals are armed here: the
    /// head fingerprint (a run of near-identical packets - nulls,
    /// repeated PAT/PMT - would false-match almost anywhere, hence the
    /// variety check) and the head's PCR.
    func markDiscontinuity() {
        lock.lock(); defer { lock.unlock() }
        carry.removeAll(keepingCapacity: true)
        needResync = true
        if recentHashes.count >= Self.overlapRun, Set(recentHashes).count >= 4 {
            spliceTarget = recentHashes
        } else {
            spliceTarget = nil
        }
        spliceAnchorPcr = headPcr
        spliceAnchorPid = headPcrPid
        sawAnchorPcr = false
        // Either signal on its own is enough to trim.
        discardActive = spliceTarget != nil || spliceAnchorPcr >= 0
        matchLen = 0
        discardedBytes = 0
        discardStartMs = 0
    }

    private func endDiscard() {
        discardActive = false
        spliceTarget = nil
        spliceAnchorPcr = -1
        spliceAnchorPid = -1
        sawAnchorPcr = false
    }

    /// FNV-1a over one 188-byte packet at [offset] in [buf].
    private static func packetHash(_ buf: Data, _ offset: Int) -> Int32 {
        var h: Int32 = -2128831035
        let base = buf.startIndex + offset
        for i in 0..<tsPacket {
            h = (h ^ Int32(buf[base + i])) &* 16777619
        }
        return h
    }

    /// The 33-bit 90 kHz PCR base carried by this packet, or nil if it
    /// has none. Layout: byte 3 bits 5-4 are adaptation_field_control; a
    /// value of 2 or 3 means an adaptation field follows at byte 4 as
    /// (length, flags, ...), and flag 0x10 puts the 48-bit PCR in the
    /// next 6 bytes - 33 bits of base, 6 reserved, 9 of extension. Only
    /// the base is needed to order two points in the same stream.
    private static func packetPcr(_ buf: Data, _ offset: Int) -> Int64? {
        let b = buf.startIndex + offset
        guard buf[b] == 0x47 else { return nil }
        let afc = (Int(buf[b + 3]) >> 4) & 0x03
        guard afc == 2 || afc == 3 else { return nil }
        let afLen = Int(buf[b + 4])
        // Needs the flags byte plus 6 PCR bytes, and must stay inside
        // the packet: a malformed length must not read into the next one.
        guard afLen >= 7, 5 + afLen <= tsPacket else { return nil }
        guard Int(buf[b + 5]) & 0x10 != 0 else { return nil }
        return (Int64(buf[b + 6]) << 25)
            | (Int64(buf[b + 7]) << 17)
            | (Int64(buf[b + 8]) << 9)
            | (Int64(buf[b + 9]) << 1)
            | (Int64(buf[b + 10] & 0x80) >> 7)
    }

    private static func packetPid(_ buf: Data, _ offset: Int) -> Int {
        let b = buf.startIndex + offset
        return (Int(buf[b + 1] & 0x1F) << 8) | Int(buf[b + 2])
    }

    /// Signed distance a - b in 90 kHz ticks, tolerating the 33-bit wrap
    /// (a stream that wraps mid-splice must not read as a 26-hour jump
    /// backwards).
    private static func pcrDelta(_ a: Int64, _ b: Int64) -> Int64 {
        var d = a - b
        if d > pcrWrap / 2 { d -= pcrWrap }
        if d < -pcrWrap / 2 { d += pcrWrap }
        return d
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

        var from = 0
        if discardActive {
            // Splice trimmer: discard the new connection's packets for
            // as long as they are content the buffer already holds, then
            // splice. Two stop signals, in priority order:
            //
            //  1. The byte fingerprint of our head. When the replay
            //     really does contain our head, this splices bit-exactly.
            //  2. The stream's own clock. Every PCR says where incoming
            //     bytes sit relative to the head we committed; once one
            //     passes the anchor, the connection has caught up and
            //     everything from that packet on is material we do NOT
            //     have, so the discard ends immediately.
            //
            // Signal 2 is what makes the common failure benign. If the
            // server joins us at or ahead of our head there is no
            // fingerprint to find, and the old byte cap responded by
            // binning 8 MiB of arriving video and splicing a hole,
            // turning a small genuine gap into a multi-second one.
            //
            // The anchor is the last PCR COMMITTED and the head can sit
            // up to one PCR interval past it (~40-100 ms), so this can
            // re-admit that much duplicate. A sub-frame overlap is a far
            // better failure than a hole: the demuxer absorbs it,
            // whereas a hole stalls the audio sink.
            if discardStartMs == 0 { discardStartMs = now }
            var p = 0
            var spliceAt: Int?
            while p < whole {
                let packetStart = p
                if let target = spliceTarget {
                    let h = Self.packetHash(merged, p)
                    if h == target[matchLen] {
                        matchLen += 1
                    } else if h == target[0] {
                        matchLen = 1
                    } else {
                        matchLen = 0
                    }
                    p += Self.tsPacket
                    if matchLen == target.count {
                        debugLog("[REWIND] splice overlap trimmed (\(discardedBytes + p) bytes)")
                        spliceAt = p
                        break
                    }
                } else {
                    p += Self.tsPacket
                }
                if spliceAnchorPcr >= 0,
                   let pcr = Self.packetPcr(merged, packetStart),
                   spliceAnchorPid < 0 || Self.packetPid(merged, packetStart) == spliceAnchorPid {
                    sawAnchorPcr = true
                    let aheadMs = Self.pcrDelta(pcr, spliceAnchorPcr) / 90
                    if aheadMs > 0 {
                        debugLog("[REWIND] splice resynced on stream clock \(aheadMs)ms past head after discarding \(discardedBytes + packetStart) bytes")
                        spliceAt = packetStart
                        break
                    }
                }
            }
            if let at = spliceAt {
                endDiscard()
                from = at
                guard from < whole else { return }
            } else {
                discardedBytes += whole
                let elapsed = now - discardStartMs
                if sawAnchorPcr {
                    // Steering by the clock: the replay is real and every
                    // byte discarded is content we already hold.
                    if elapsed > Self.overlapPcrSearchMs {
                        endDiscard()
                        debugLog("[REWIND] splice clock never passed the head in \(elapsed)ms (\(discardedBytes) bytes); splicing with a gap")
                    }
                } else if discardedBytes > Self.overlapSearchCap || elapsed > Self.overlapSearchMs {
                    endDiscard()
                    debugLog("[REWIND] splice found no head fingerprint and no stream clock within \(discardedBytes) bytes / \(elapsed)ms; splicing with a gap")
                }
                return
            }
        }

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
            if let h = handle {
                try h.write(contentsOf: merged.subdata(in: from..<whole))
            }
            headWallMs = now
            // Keep the head fingerprint and the head clock fresh for the
            // next discontinuity.
            var p = from
            while p < whole {
                recentHashes.append(Self.packetHash(merged, p))
                if recentHashes.count > Self.overlapRun { recentHashes.removeFirst() }
                if let pcr = Self.packetPcr(merged, p) {
                    headPcr = pcr
                    headPcrPid = Self.packetPid(merged, p)
                }
                p += Self.tsPacket
            }
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
        // Wait for the first segment on a brand-new session with NO
        // fixed deadline: engine liveness is the bound. ATV field
        // captures proved any wall-clock cap here is a losing race -
        // Dispatcharr can HOLD the connect socket ~10s while priming a
        // cold channel upstream and then 500 (the engine reconnects and
        // wins on a later attempt), so a capped wait expired exactly
        // when the server was about to deliver, failed mpv's open, and
        // ran the whole fallback ladder ON TOP of the remaining prime
        // time (22.8s to first frame, measured). Blocking here keeps
        // mpv in its normal "opening" state, identical to the direct
        // path waiting on ffmpeg's connect; a truly dead channel closes
        // the buffer (engine attempt cap) and exits immediately.
        while segments.isEmpty && !buffer.closed {
            Thread.sleep(forTimeInterval: 0.1)
            // GH #60: this runs on libmpv's own C pthread, which has NO
            // draining autorelease pool - every Foundation temporary made
            // here would stay pinned for the life of the stream thread.
            segments = autoreleasepool { LiveRewindBuffer.listSegments(in: buffer.sessionDir) }
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
            // GH #60 (the 4K jetsam leak): this read loop runs on libmpv's own
            // C pthread, which never drains an autorelease pool. The old
            // FileHandle.read(upToCount:) returned an autoreleased NSData per
            // ~64KiB chunk, so EVERY streamed byte stayed pinned until the
            // stream thread exited - RSS grew at exactly the stream bitrate
            // (~3 MB/s on 4K) into the ~2 GB jetsam kill. Read straight into
            // mpv's buffer with POSIX read() instead: zero Foundation
            // temporaries on the hot path.
            if let h = handle {
                var n: Int = -1
                repeat {
                    n = Darwin.read(h.fileDescriptor, dest, nbytes)
                } while n == -1 && errno == EINTR
                if n > 0 { return n }
                // n == 0 (grown-to-EOF) or error: fall through to the
                // segment-advance / wait logic below, same as before.
            }
            // Current segment exhausted or grown-to-EOF: periodically
            // check whether a newer segment exists to advance into.
            // Foundation work below is wrapped in autoreleasepool for the
            // same no-pool-on-this-thread reason.
            if listCountdown <= 0 {
                listCountdown = 5
                let fresh = autoreleasepool { LiveRewindBuffer.listSegments(in: buffer.sessionDir) }
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
                        autoreleasepool {
                            try? handle?.close()
                            handle = try? FileHandle(forReadingFrom: segments[segIndex].url)
                        }
                        continue
                    }
                    segments = fresh
                    // GH #67: re-sync the index into the FRESH list. Once the
                    // ring starts evicting (rewind depth reached, ~30 min in)
                    // every re-list shifts the array left; adopting `fresh`
                    // while keeping the OLD index made segIndex drift off the
                    // end, currentStart read -1, and the evicted-segment
                    // guard above misfired -> reader error -> the player's
                    // recovery re-tuned a LIVE viewer at the buffer tail, a
                    // full rewind-depth into the past (KTLA log 2026-07-29,
                    // "re-tune 1787s behind live" at the 35-minute mark).
                    segIndex = freshIdx
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

    /// Retention as a USER concept died in the 2026-07-11 settings
    /// rework ("we don't really care how long the files are stored ...
    /// just delete the buffered video after an hour"): buffered video
    /// is removed this long after its session goes quiet. Fixed;
    /// liveRewindRetentionHours is dormant (Android
    /// TimeshiftController.FIXED_RETENTION_MS parity).
    var retentionMs: Int64 { 60 * 60 * 1000 }

    /// The Storage Limit SETTING was removed (user directive
    /// 2026-07-11: retention is the only user-facing knob, with storage
    /// estimates shown under it). This is the invisible seatbelt that
    /// replaced it: the buffer may use its current footprint plus
    /// whatever free space the volume has above a 2 GB floor, so a long
    /// retention on a full disk evicts oldest video instead of filling
    /// the device. Recomputed on every enforcement pass. The old
    /// liveRewindBudgetGB default stays as the fallback if free space
    /// can't be read.
    var budgetBytes: Int64 {
        // Plain volumeAvailableCapacityKey: the "ImportantUsage" variant
        // is unavailable on tvOS. Slightly conservative (doesn't count
        // OS-purgeable space) - fine for a seatbelt.
        let values = try? rootDir.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        guard let free = values?.volumeAvailableCapacity.map({ Int64($0) }) else {
            // Free space unreadable: fall back to the old default cap.
            return 10 * 1024 * 1024 * 1024
        }
        let floor: Int64 = 2 * 1024 * 1024 * 1024
        return currentUsageBytes() + max(0, free - floor)
    }

    /// Total bytes of buffered media (.ts and fMP4 .m4s) across all session dirs (rewind
    /// segments AND AVPlayer spill files), for the free-space budget.
    private func currentUsageBytes() -> Int64 {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: rootDir, includingPropertiesForKeys: nil)) ?? []
        var total: Int64 = 0
        for dir in dirs where dir.hasDirectoryPath {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            for f in files where ["ts", "m4s"].contains(f.pathExtension) {
                total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
        }
        return total
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
    /// Whether THIS session has ever delivered a byte. Gates the
    /// reconnect budget: a proven-alive stream gets patience (20
    /// attempts), a never-primed one fails fast (5) so a dead channel
    /// closes the buffer and unblocks the reader's open promptly.
    private var everReceivedData = false
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

    // MARK: - External window (AVPlayer container Live Rewind)
    //
    // The AVPlayer engine's rewind is TSHLSRemuxer's disk spill + a
    // playlist advertising the whole spilled window - native AVPlayer
    // seeking IS the rewind, no relay, no LiveRewindBuffer. The chrome,
    // however, is gated entirely on this engine's published state
    // (buffering / timeshifting / tailWallMs / headWallMs). External-
    // window mode lets that path light the same chrome: the AVPlayer
    // progress driver pumps the window it reads from seekableTimeRanges
    // into these fields, and nothing else in the engine runs.
    private(set) var externalWindowActive = false
    /// Which tile owns the external window. Session hand-offs (Jump to
    /// Channel) run the INCOMING tile's begin before the OUTGOING tile's
    /// end - without ownership, the begin was refused (buffering still
    /// true) and the stale end then killed the fresh session's chrome.
    private var externalWindowOwner: String?

    @MainActor
    func beginExternalWindow(owner: String) {
        // A live mpv relay owns `buffering` outright; never fight it.
        guard !buffering || externalWindowActive else { return }
        externalWindowOwner = owner
        externalWindowActive = true
        timeshifting = false
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        tailWallMs = now
        headWallMs = now
        buffering = true
        DebugLogger.shared.log("[LiveRewind] external window began (AVPlayer, owner \(owner))",
                               category: "Playback", level: .info)
    }

    @MainActor
    func updateExternalWindow(tailWallMs tail: Int64, headWallMs head: Int64) {
        guard externalWindowActive else { return }
        // Same delta-gate as the relay window timer: second resolution
        // is all the transport needs, and every write re-renders chrome.
        if abs(tail - tailWallMs) >= 1_000 { tailWallMs = tail }
        if abs(head - headWallMs) >= 1_000 { headWallMs = head }
    }

    @MainActor
    func endExternalWindow(owner: String) {
        guard externalWindowActive, externalWindowOwner == owner else { return }
        externalWindowOwner = nil
        externalWindowActive = false
        buffering = false
        timeshifting = false
        DebugLogger.shared.log("[LiveRewind] external window ended (owner \(owner))",
                               category: "Playback", level: .info)
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
        everReceivedData = false
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
        let finished = activeBuffer
        activeBuffer?.close()
        activeBuffer = nil
        stateLock.unlock()
        // Android parity (Discord: di5cord20, Formuler Z11, app storage past
        // 3 GB). A closed session's directory is DEAD BYTES: `LiveRewindReader`
        // is only ever constructed against the ACTIVE `LiveRewindBuffer`, and
        // `startSession` always mints a fresh directory, so nothing can open a
        // session again once it has ended. They were nevertheless kept for the
        // full hour of `retentionMs` and measured against a budget that is
        // "current usage plus free space above the floor" - not a ceiling at
        // all on a device with room to spare. Every channel change therefore
        // stranded up to a depth's worth of transport stream, and 30 minutes of
        // HD runs to a gigabyte or two.
        //
        // Delete it as soon as the session ends. No feature is lost, because no
        // feature could ever have used it; `reapAtLaunch` and the periodic
        // sweep stay as the net for a process that dies mid-session, which is
        // now the only way a directory survives. Done off the state lock: this
        // is filesystem work and nothing else needs to wait for it.
        if let dir = finished?.sessionDir {
            DispatchQueue.global(qos: .utility).async {
                try? FileManager.default.removeItem(at: dir)
                debugLog("[REWIND] released buffer \(dir.lastPathComponent)")
            }
        }
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

    /// Tick counter for the ~5-minute in-session sweep below. Instance
    /// property (not a captured local) so strict concurrency checking
    /// doesn't flag the mutation inside the timer closure; only the
    /// main-runloop timer touches it.
    private var windowTicks = 0

    @MainActor
    private func startWindowTimer() {
        windowTimer?.invalidate()
        windowTicks = 0
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
            self.windowTicks += 1
            if self.windowTicks % 600 == 0 {
                DispatchQueue.global(qos: .utility).async {
                    self.pruneExpired()
                    self.enforceBudget()
                }
            }
        }
    }

    // MARK: retention + budget

    /// Launch-time reaper (user clarification 2026-07-11: buffered video
    /// dies an hour after the SESSION ends - practically, often at the
    /// NEXT app launch, since the app usually isn't running to see the
    /// hour pass). The in-session timer only sweeps while a session is
    /// rolling, so AerioApp calls this once at startup.
    func startupSweep() {
        DispatchQueue.global(qos: .utility).async {
            self.pruneExpired()
            self.enforceBudget()
            // Catch-up spool leftovers: CatchupHTTPReader deletes its
            // spool on close and sweeps stale files when a NEW catch-up
            // session starts - but a killed app leaks multi-GB .ts
            // files that then sit in Caches until the user happens to
            // replay something. On tvOS that bloat invites the system
            // to purge the ENTIRE app data container under storage
            // pressure (observed 2026-07-11: the field ATV came up
            // hasCompletedOnboarding=false after a day of leaked
            // spools). Sweep anything over an hour old here too.
            let spoolDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("CatchupSpool", isDirectory: true)
            let cutoff = Date().addingTimeInterval(-3600)
            let files = (try? FileManager.default.contentsOfDirectory(
                at: spoolDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for f in files {
                let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if (m ?? .distantPast) < cutoff {
                    try? FileManager.default.removeItem(at: f)
                }
            }
        }
    }

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
        // Enumerate every .ts/.m4s under the root by modification date, not
        // just parseable seg_<wallMs> names: the AVPlayer spill files
        // (seg<seq>.ts in avp_sess_ dirs) were invisible to the budget.
        let dirs = (try? FileManager.default.contentsOfDirectory(at: rootDir, includingPropertiesForKeys: nil)) ?? []
        var segs: [(url: URL, mtime: Date, size: Int64)] = []
        for dir in dirs where dir.hasDirectoryPath {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
            for f in files where ["ts", "m4s"].contains(f.pathExtension) {
                let vals = try? f.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                segs.append((f, vals?.contentModificationDate ?? .distantPast, Int64(vals?.fileSize ?? 0)))
            }
        }
        // Hoist: budgetBytes now enumerates the disk (free-space
        // seatbelt), so reading it per loop iteration would be
        // quadratic in segment count.
        let budget = budgetBytes
        var total = segs.reduce(0) { $0 + $1.size }
        for seg in segs.sorted(by: { $0.mtime < $1.mtime }) {
            if total <= budget { break }
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
        if reconnectAttempts != 0 || !everReceivedData {
            stateLock.lock()
            reconnectAttempts = 0
            everReceivedData = true
            stateLock.unlock()
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
        let cap = everReceivedData ? 20 : 5
        let expectedBuffer = activeBuffer
        stateLock.unlock()
        guard isCurrent, alive else { return }
        // Live connection dropped: reconnect with backoff; the writer
        // realigns on the fresh mid-packet join.
        guard attempt <= cap else {
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
    private var finished = false
    private var failed = false
    private var bytesWritten: Int64 = 0
    private var readOffset: Int64 = 0
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var nwTask: Task<Void, Never>?
    private let spoolURL: URL
    private var writeHandle: FileHandle?
    private var readHandle: FileHandle?

    /// Disk spool, NOT suspend/resume flow control: Dispatcharr sends
    /// the whole remaining archive at line rate (~66 MB/s measured), so
    /// a suspended task blocks the server's writes for tens of seconds
    /// per drain cycle and the server times the connection out (ATV
    /// field capture: stream died ~65s in; only the EOF re-tune saved
    /// it). The spool accepts at line rate, the reader tails it at
    /// playback rate, and the file is deleted on close.
    init(url: URL, headers: [String: String]) {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CatchupSpool", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Sweep leftovers from crashed sessions (anything over an hour
        // old cannot belong to a live reader).
        if let leftovers = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) {
            let cutoff = Date().addingTimeInterval(-3600)
            for f in leftovers {
                let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if (m ?? .distantPast) < cutoff { try? FileManager.default.removeItem(at: f) }
            }
        }
        spoolURL = dir.appendingPathComponent(UUID().uuidString + ".ts")
        FileManager.default.createFile(atPath: spoolURL.path, contents: nil)
        writeHandle = try? FileHandle(forWritingTo: spoolURL)
        readHandle = try? FileHandle(forReadingFrom: spoolURL)
        super.init()
        if writeHandle == nil || readHandle == nil {
            failed = true
            return
        }
        // Transport choice. Plain-HTTP to a DOMAIN can fail URLSession with ATS
        // -1022 even under NSAllowsArbitraryLoads (the same iOS quirk HTTPRouter
        // dodges for API calls), and the URLSession relay can't follow the
        // reverse-proxy's http->https 301 either -- so remote catch-up over an
        // NGINX/Cloudflare-fronted http URL died with "unrecognized file format"
        // (spike9172 field report). Route those through NWHTTPClient's streaming
        // NWConnection path (cleartext-capable + follows the redirect). https and
        // http-to-IP (LAN) work fine on URLSession, so keep them there.
        if Self.needsNWStreaming(url) {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
            nwTask = Task.detached { [weak self] in
                do {
                    // 30s IDLE deadline (reset per chunk): a large archive streams
                    // at line rate, a stalled connection is still cut.
                    let resp = try await NWHTTPClient.stream(for: request, timeout: 30) { [weak self] chunk in
                        self?.appendSpool(chunk)
                    }
                    if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                        debugLog("[CATCHUP-RELAY] NW HTTP \(http.statusCode)")
                        self?.markFailed()
                    } else {
                        self?.markFinished()
                    }
                } catch {
                    // Whatever spooled still plays, then EOF; the player's
                    // catch-up EOF re-tune recovers the position (mirrors the
                    // URLSession didCompleteWithError path).
                    debugLog("[CATCHUP-RELAY] NW connection ended: \(error.localizedDescription)")
                    self?.markFinished()
                }
            }
            return
        }
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

    /// http-to-DOMAIN needs the NWConnection path (URLSession -1022s under
    /// ATS/HSTS and can't follow the http->https 301). https and http-to-IP
    /// (LAN, allowed by NSAllowsLocalNetworking) stay on URLSession.
    private static func needsNWStreaming(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http", let host = url.host, !host.isEmpty else { return false }
        return !isIPLiteral(host)
    }

    private static func isIPLiteral(_ host: String) -> Bool {
        if host.contains(":") { return true }   // IPv6 literal (URL.host strips brackets)
        let parts = host.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { Int($0) != nil }   // IPv4 dotted quad
    }

    /// Append body bytes to the spool + wake the reader. Shared by the
    /// URLSession delegate and the NWConnection stream sink.
    private func appendSpool(_ data: Data) {
        cond.lock()
        do {
            try writeHandle?.write(contentsOf: data)
            bytesWritten += Int64(data.count)
        } catch {
            debugLog("[CATCHUP-RELAY] spool write failed: \(error)")
            failed = true
        }
        cond.signal()
        cond.unlock()
    }

    private func markFinished() {
        cond.lock(); finished = true; cond.signal(); cond.unlock()
    }

    private func markFailed() {
        cond.lock(); failed = true; cond.signal(); cond.unlock()
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
        appendSpool(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        cond.lock()
        if let error, (error as NSError).code != NSURLErrorCancelled {
            // Mid-stream drop: whatever is spooled still plays, then EOF;
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
        while readOffset >= bytesWritten {
            if failed { return -1 }
            if finished { return 0 }
            cond.wait()
        }
        let want = min(nbytes, Int(bytesWritten - readOffset))
        // GH #60: POSIX read straight into mpv's buffer. The old
        // FileHandle.read(upToCount:) autoreleased an NSData per chunk on
        // libmpv's pool-less stream thread, pinning the whole catch-up
        // stream in RSS (same 4K-bitrate leak as the live rewind reader).
        guard let rh = readHandle else { return failed ? -1 : 0 }
        var n: Int = -1
        repeat {
            n = Darwin.read(rh.fileDescriptor, dest, want)
        } while n == -1 && errno == EINTR
        guard n > 0 else { return failed ? -1 : 0 }
        readOffset += Int64(n)
        return n
    }

    func close() {
        cond.lock()
        finished = true
        cond.signal()
        cond.unlock()
        nwTask?.cancel()
        task?.cancel()
        session?.invalidateAndCancel()
        try? writeHandle?.close()
        try? readHandle?.close()
        try? FileManager.default.removeItem(at: spoolURL)
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
