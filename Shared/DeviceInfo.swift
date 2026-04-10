import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Device Info
/// Helpers for the Settings → About page. These live in Shared because
/// SettingsView has separate iOS and tvOS code paths that both need the
/// exact same "what model am I running on" answer and the same
/// "when was the app actually last updated" answer.
enum DeviceInfo {

    /// Returns a human-readable model name for the current device.
    ///
    /// `UIDevice.current.model` returns the generic family string ("iPhone",
    /// "iPad", "Apple TV") which is useless for an About panel. The actual
    /// model is encoded in the kernel's `hw.machine` sysctl as a short
    /// identifier like `iPhone17,1` or `AppleTV14,1`. We translate that to
    /// a friendly name via a lookup table of known identifiers; if we don't
    /// recognize the identifier (new hardware Apple released after this
    /// table was written) we return the raw identifier so the About screen
    /// is still informative rather than showing a generic category.
    ///
    /// Running in the Simulator, `hw.machine` is the host Mac's architecture
    /// (e.g. `arm64`). We detect that via the `SIMULATOR_MODEL_IDENTIFIER`
    /// env var which the Simulator always sets to the simulated device's ID.
    static var modelName: String {
        let identifier = rawHardwareIdentifier
        if let friendly = friendlyNameMap[identifier] { return friendly }
        // Unknown identifier — return it raw so the user can still tell us
        // what their device is when reporting issues.
        return identifier
    }

    private static var rawHardwareIdentifier: String {
        // When running inside a Simulator, hw.machine returns the host Mac's
        // identifier (e.g. "arm64"), not the simulated device. Prefer the
        // env var Apple sets for us.
        if let simID = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"],
           !simID.isEmpty {
            return simID
        }
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let identifier = mirror.children.reduce("") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return result }
            return result + String(UnicodeScalar(UInt8(value)))
        }
        return identifier
    }

    /// Lookup table of known hardware identifiers → human-readable names.
    /// Only covers models the app realistically supports (iOS 18+, tvOS 18+,
    /// iPadOS 18+). Generated from Apple's public model identifier list.
    private static let friendlyNameMap: [String: String] = [
        // MARK: iPhone
        "iPhone14,4": "iPhone 13 mini",
        "iPhone14,5": "iPhone 13",
        "iPhone14,2": "iPhone 13 Pro",
        "iPhone14,3": "iPhone 13 Pro Max",
        "iPhone14,6": "iPhone SE (3rd generation)",
        "iPhone14,7": "iPhone 14",
        "iPhone14,8": "iPhone 14 Plus",
        "iPhone15,2": "iPhone 14 Pro",
        "iPhone15,3": "iPhone 14 Pro Max",
        "iPhone15,4": "iPhone 15",
        "iPhone15,5": "iPhone 15 Plus",
        "iPhone16,1": "iPhone 15 Pro",
        "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone17,3": "iPhone 16",
        "iPhone17,4": "iPhone 16 Plus",
        "iPhone17,1": "iPhone 16 Pro",
        "iPhone17,2": "iPhone 16 Pro Max",
        "iPhone17,5": "iPhone 16e",
        "iPhone18,3": "iPhone 17",
        "iPhone18,4": "iPhone 17 Plus",
        "iPhone18,1": "iPhone 17 Pro",
        "iPhone18,2": "iPhone 17 Pro Max",

        // MARK: iPad
        "iPad13,1":  "iPad Air (4th generation)",
        "iPad13,2":  "iPad Air (4th generation)",
        "iPad13,16": "iPad Air (5th generation)",
        "iPad13,17": "iPad Air (5th generation)",
        "iPad14,8":  "iPad Air 11-inch (M2)",
        "iPad14,9":  "iPad Air 11-inch (M2)",
        "iPad14,10": "iPad Air 13-inch (M2)",
        "iPad14,11": "iPad Air 13-inch (M2)",
        "iPad15,3":  "iPad Air 11-inch (M3)",
        "iPad15,4":  "iPad Air 11-inch (M3)",
        "iPad15,5":  "iPad Air 13-inch (M3)",
        "iPad15,6":  "iPad Air 13-inch (M3)",

        "iPad12,1":  "iPad (9th generation)",
        "iPad12,2":  "iPad (9th generation)",
        "iPad13,18": "iPad (10th generation)",
        "iPad13,19": "iPad (10th generation)",
        "iPad15,7":  "iPad (A16)",
        "iPad15,8":  "iPad (A16)",

        "iPad14,1":  "iPad mini (6th generation)",
        "iPad14,2":  "iPad mini (6th generation)",
        "iPad16,1":  "iPad mini (7th generation)",
        "iPad16,2":  "iPad mini (7th generation)",

        "iPad13,4":  "iPad Pro 11-inch (3rd generation)",
        "iPad13,5":  "iPad Pro 11-inch (3rd generation)",
        "iPad13,6":  "iPad Pro 11-inch (3rd generation)",
        "iPad13,7":  "iPad Pro 11-inch (3rd generation)",
        "iPad13,8":  "iPad Pro 12.9-inch (5th generation)",
        "iPad13,9":  "iPad Pro 12.9-inch (5th generation)",
        "iPad13,10": "iPad Pro 12.9-inch (5th generation)",
        "iPad13,11": "iPad Pro 12.9-inch (5th generation)",
        "iPad14,3":  "iPad Pro 11-inch (4th generation)",
        "iPad14,4":  "iPad Pro 11-inch (4th generation)",
        "iPad14,5":  "iPad Pro 12.9-inch (6th generation)",
        "iPad14,6":  "iPad Pro 12.9-inch (6th generation)",
        "iPad16,3":  "iPad Pro 11-inch (M4)",
        "iPad16,4":  "iPad Pro 11-inch (M4)",
        "iPad16,5":  "iPad Pro 13-inch (M4)",
        "iPad16,6":  "iPad Pro 13-inch (M4)",

        // MARK: Apple TV
        "AppleTV11,1": "Apple TV 4K (2nd generation)",
        "AppleTV14,1": "Apple TV 4K (3rd generation)",
        "AppleTV15,1": "Apple TV 4K (4th generation)",

        // MARK: Simulator architecture identifiers (shouldn't be reached because
        // of the SIMULATOR_MODEL_IDENTIFIER check, but included as a safety net)
        "i386":   "iOS Simulator (i386)",
        "x86_64": "iOS Simulator (x86_64)",
        "arm64":  "iOS Simulator (arm64)",
    ]

    // MARK: - Last Updated

    /// Human-readable "last updated" date for the About screen.
    ///
    /// The bundle's modification date is set to the build time of the .app
    /// when the app is first installed. Because macOS file modification
    /// times are preserved across installs (xcodebuild copies mtime from
    /// the built artifact), on a fresh install the bundle mtime can be
    /// earlier than the install time, older than the first-installed date,
    /// or at the Unix epoch depending on build pipeline quirks.
    ///
    /// The rule: if `bundleModificationDate` is within 1 day of
    /// `firstInstalledDate` (or earlier), the app has never been updated
    /// since install, so return "Never". Otherwise return the bundle's
    /// modification date as a long-form formatted string.
    static var lastUpdatedText: String {
        guard let installDate = firstInstalledDate,
              let updateDate = bundleModificationDate else {
            return "Never"
        }
        // If the bundle mtime is earlier than or within 24 hours of the
        // install date, treat it as "never updated".
        let oneDay: TimeInterval = 86_400
        if updateDate.timeIntervalSince(installDate) < oneDay {
            return "Never"
        }
        return updateDate.formatted(date: .long, time: .omitted)
    }

    /// Human-readable "first installed" date for the About screen, or
    /// "—" if the data container creation date can't be read.
    static var firstInstalledText: String {
        guard let date = firstInstalledDate else { return "—" }
        return date.formatted(date: .long, time: .omitted)
    }

    /// The Documents folder's parent (i.e. the app's data container) is
    /// created at first-install time by iOS. Its creation date is the
    /// most reliable "first installed" signal available to a sandboxed app.
    private static var firstInstalledDate: Date? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let attrs = try? FileManager.default.attributesOfItem(atPath: docs.deletingLastPathComponent().path) else {
            return nil
        }
        return attrs[.creationDate] as? Date
    }

    /// Bundle mtime. Equals the build time of the .app on first install,
    /// and changes when the app is updated (because iOS installs a new
    /// .app bundle on upgrade).
    private static var bundleModificationDate: Date? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: Bundle.main.bundlePath) else {
            return nil
        }
        return attrs[.modificationDate] as? Date
    }
}
