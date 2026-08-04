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

    func body(content: Content) -> some View {
        content
            .onAppear {
                stack.register(id: id) { dismiss() }
            }
            .onDisappear {
                stack.unregister(id: id)
            }
    }
}

extension View {
    /// Attach to a classic-`NavigationLink(destination:)` destination
    /// pushed within SettingsView's tvOS NavigationStack so the Menu
    /// button can pop it via the `popRequested` binding.
    func trackedAsClassicSettingsChild() -> some View {
        modifier(TrackClassicSettingsChild())
    }
}
#endif
