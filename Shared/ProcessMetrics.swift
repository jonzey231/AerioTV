import Foundation
import Darwin

/// Lightweight process-wide metrics for diagnostic logging.
///
/// All calls are safe from any thread and cost a few syscalls each
/// (no KVO, no allocations on the hot path). Used by the mpv stats
/// ticker (per-tile) and the refcount helpers to surface the sort
/// of resource-pressure signals that show up as weird
/// `MPV_ERROR_LOADING_FAILED` / TLS-handshake failures on the 2nd
/// concurrent stream but not the 1st — the symptom we couldn't
/// explain until we had numbers to look at.
///
/// iOS/tvOS default per-process FD limit is 256. A single live
/// mpv tile eats roughly 5–7 FDs (1 TCP socket, 1 TLS session, a
/// couple of pipes for the demux→decode handoff, a videotoolbox
/// IOSurface handle, a CoreAudio bus). With 9 tiles that's ~60 FDs
/// which is well under the cap — but if something is leaking
/// (EPG fetches, guide pre-fetch, cloud-kv observers…) we could
/// be pressed against it in a way that invisibly starves the next
/// stream open. The `openFileDescriptorCount()` readout catches
/// exactly that.
enum ProcessMetrics {

    // MARK: - Memory

    /// Physical footprint (≈ Activity Monitor "Memory") in bytes.
    /// Returns 0 if `task_info` fails.
    static func residentSetSizeBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let kr: kern_return_t = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    intPtr,
                    &count
                )
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// RSS formatted as e.g. `"412.7 MB"`.
    static func residentSetSizeMB() -> String {
        let bytes = residentSetSizeBytes()
        return String(format: "%.1f MB", Double(bytes) / (1024.0 * 1024.0))
    }

    // MARK: - File descriptors

    /// Current open file descriptor count, approximate (capped).
    /// Iterates `fstat(fd:)` over FDs 0..< `Self.fdScanCap` — cheap
    /// enough for a 15s stats tick on iOS (soft limit 256) and
    /// reasonable on tvOS (soft limit 2560, but we still cap at 256
    /// for the scan because iterating 2560 `fstat` syscalls per
    /// tile per tick was contributing to the observable UI lag with
    /// 2 concurrent tiles on Apple TV 4K in `.serious` thermal
    /// state).
    ///
    /// A returned count of exactly `Self.fdScanCap` means "at or
    /// above cap" — still a useful signal that the app is nearing
    /// the iOS default limit. For deeper diagnosis of FD leaks,
    /// use Instruments; this counter is just a heartbeat.
    ///
    /// We explicitly avoid `proc_pidinfo`/`PROC_PIDLISTFDS`. It works
    /// on iOS today but Apple has flagged it as a "no-stable-guarantee"
    /// API for store apps; the bounded `fstat` sweep is public,
    /// documented, and correct enough for telemetry.
    static func openFileDescriptorCount() -> Int {
        var count = 0
        var st = Darwin.stat()
        for fd in 0..<Int32(Self.fdScanCap) {
            if fstat(fd, &st) == 0 {
                count += 1
            }
        }
        return count
    }

    /// Max FD we scan in `openFileDescriptorCount()`. iOS default
    /// soft limit is 256; we scan up to that and stop. Going higher
    /// (e.g. tvOS's 2560) buys precision we don't need and costs
    /// real main-thread time on thermally-throttled hardware.
    private static let fdScanCap = 256

    /// Soft FD limit (e.g. `256` on iOS/tvOS by default).
    /// Returns -1 if `getrlimit` fails.
    static func fileDescriptorSoftLimit() -> Int {
        var rlim = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &rlim) == 0 else { return -1 }
        return Int(rlim.rlim_cur)
    }

    // MARK: - Thermal / power

    /// Compact thermal-state string: `"nominal"`, `"fair"`,
    /// `"serious"`, `"critical"`, or `"unknown"`.
    static var thermalStateString: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:   return "nominal"
        case .fair:      return "fair"
        case .serious:   return "serious"
        case .critical:  return "critical"
        @unknown default: return "unknown"
        }
    }

    /// `true` if the user has Low Power Mode on (iOS/iPadOS; always
    /// `false` on tvOS since the API returns `false` there).
    static var isLowPowerMode: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    // MARK: - Summary

    /// One-line summary suitable for log lines:
    /// `"rss=412.7MB fd=37/256 thermal=fair lpm=false"`.
    static func summaryLine() -> String {
        let rss = residentSetSizeMB()
        let fd = openFileDescriptorCount()
        let fdMax = fileDescriptorSoftLimit()
        return "rss=\(rss) fd=\(fd)/\(fdMax) thermal=\(thermalStateString) lpm=\(isLowPowerMode)"
    }
}
