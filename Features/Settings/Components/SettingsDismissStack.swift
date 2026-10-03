//
//  SettingsDismissStack.swift
//  Aerio
//
//  Extracted verbatim from SettingsView.swift (Settings redesign Phase 1,
//  SettingsUIRedesign.md A4). No behavior change intended in this move.
//

import SwiftUI
import SwiftData

#if os(tvOS)  // Phase 1 split: re-opened, block spanned the extraction cut
@MainActor
final class SettingsDismissStack: ObservableObject {
    /// LIFO stack of registered classic-pushed destinations. Keyed by
    /// a per-view UUID so we can unregister reliably even if appears
    /// and disappears interleave during a transition.
    private var entries: [(id: UUID, dismiss: () -> Void)] = []

    /// Mirrors `entries.count`. Published so SettingsView can react
    /// via `.onReceive`.
    @Published fileprivate(set) var depth: Int = 0

    func register(id: UUID, dismiss: @escaping () -> Void) {
        // Replace any existing entry for this id so re-registrations
        // (e.g. onAppear firing again after a view re-mount) don't
        // duplicate. Keep stack order stable by leaving the position.
        if let idx = entries.firstIndex(where: { $0.id == id }) {
            entries[idx] = (id, dismiss)
        } else {
            entries.append((id, dismiss))
        }
        depth = entries.count
    }

    func unregister(id: UUID) {
        entries.removeAll { $0.id == id }
        depth = entries.count
    }

    /// Pops the innermost registered destination (LIFO). Safe no-op
    /// when empty.
    func popTop() {
        guard let last = entries.last else { return }
        last.dismiss()
    }
}

/// Registers the view with the parent SettingsView's
/// `SettingsDismissStack` on appear so the Menu-button handler can
/// pop it even though it was pushed via classic `NavigationLink`
/// (which bypasses `navPath`).
struct TrackClassicSettingsChild: ViewModifier {
    @EnvironmentObject var stack: SettingsDismissStack
    @Environment(\.dismiss) private var dismiss
    @State private var id = UUID()
    /// [SETTINGS] trace name; nil logs nothing here (the caller logs).
    var logName: String? = nil

    func body(content: Content) -> some View {
        content
            .onAppear {
                stack.register(id: id) { dismiss() }
                if let logName { SettingsFocusLog.log("push \(logName) (classic, depth \(stack.depth))") }
            }
            .onDisappear {
                stack.unregister(id: id)
                if let logName {
                    SettingsFocusLog.log("pop \(logName) (classic, depth \(stack.depth))")
                    SettingsFocusLog.scheduleLanding(after: "pop \(logName)")
                }
            }
            .settingsLogPage(logName)
    }
}

extension View {
    /// Attach to a classic-`NavigationLink(destination:)` destination
    /// pushed within SettingsView's tvOS NavigationStack so the Menu
    /// button can pop it via the `popRequested` binding.
    func trackedAsClassicSettingsChild(_ logName: String? = "child") -> some View {
        modifier(TrackClassicSettingsChild(logName: logName))
    }
}

// MARK: - [SETTINGS] focus trace (tvOS, instrumentation only)

/// Settings focus and navigation trace for the Apple TV "Back does not
/// return to the row I came from" reports. Writes single-line `[SETTINGS]`
/// entries through debugLog, alongside the app-wide [FOCUS]/[PRESS] trace.
@MainActor
enum SettingsFocusLog {
    /// Last Settings row that reported gaining focus ("page / row").
    private(set) static var lastFocused: String = "none"

    static func log(_ message: String) {
        debugLog("[SETTINGS] \(message)")
    }

    static func rowFocused(page: String, row: String) {
        lastFocused = "\(page) / \(row)"
        log("focus \(lastFocused)")
    }

    /// Logs which row last reported focus 300 ms after a sheet close or pop.
    static func scheduleLanding(after event: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            log("landing after \(event): \(lastFocused)")
        }
    }
}

private struct SettingsLogPageKey: EnvironmentKey {
    static let defaultValue: String = "Settings"
}

extension EnvironmentValues {
    var settingsLogPage: String {
        get { self[SettingsLogPageKey.self] }
        set { self[SettingsLogPageKey.self] = newValue }
    }
}

/// Reports a row's focus gain under the enclosing page name.
private struct SettingsRowFocusLogModifier: ViewModifier {
    let title: String
    let isFocused: Bool
    @Environment(\.settingsLogPage) private var page

    func body(content: Content) -> some View {
        content.onChange(of: isFocused) { _, focused in
            if focused { SettingsFocusLog.rowFocused(page: page, row: title) }
        }
    }
}

extension View {
    /// Names the Settings page for rows beneath it in the [SETTINGS] trace.
    @ViewBuilder
    func settingsLogPage(_ name: String?) -> some View {
        if let name { environment(\.settingsLogPage, name) } else { self }
    }

    func settingsRowFocusLog(_ title: String, isFocused: Bool) -> some View {
        modifier(SettingsRowFocusLogModifier(title: title, isFocused: isFocused))
    }
}
#endif

extension View {
    /// tvOS: logs "sheet open/close <name>" (with a landing line after the
    /// close) and names the page for rows inside it. iOS: no-op.
    @ViewBuilder
    func settingsSheetLog(_ name: String) -> some View {
        #if os(tvOS)
        self
            .onAppear { SettingsFocusLog.log("sheet open \(name)") }
            .onDisappear {
                SettingsFocusLog.log("sheet close \(name)")
                SettingsFocusLog.scheduleLanding(after: "sheet close \(name)")
            }
            .settingsLogPage(name)
        #else
        self
        #endif
    }

    /// tvOS: logs "push/pop <name>" for a NavigationStack destination (with
    /// a landing line after the pop) and names the page. iOS: no-op.
    @ViewBuilder
    func settingsPushLog(_ name: String) -> some View {
        #if os(tvOS)
        self
            .onAppear { SettingsFocusLog.log("push \(name)") }
            .onDisappear {
                SettingsFocusLog.log("pop \(name)")
                SettingsFocusLog.scheduleLanding(after: "pop \(name)")
            }
            .settingsLogPage(name)
        #else
        self
        #endif
    }
}
