//
//  TVSettingsSplitView.swift
//  Aerio
//
//  Settings redesign Phase 3 (SettingsUIRedesign.md A3): the tvOS two-pane
//  Settings root. A fixed-width rail of categories on the left, the selected
//  detail pane on the right, replacing the full-width stacked root list.
//
//  Focus contract (adapted from GroupSidebar, the proven in-app tvOS rail):
//  - Browse-by-focus: focusing a rail row selects it after a ~150ms debounce,
//    so fast scrolling does not thrash detail rebuilds.
//  - Flush rule: any movement of focus INTO the detail pane applies a pending
//    debounced selection FIRST, so focus can never land in a pane the
//    debounce is about to replace.
//  - Click on a rail row flushes and pushes focus into the detail pane.
//  - Left from the detail's leading column returns to the rail via
//    focusSection adjacency.
//  - `focusedPane` (bound to the two focus sections) is the ONE source of
//    truth for "is focus in the detail pane"; the host binds it to the Menu
//    semantics (Menu in detail returns to the rail; Menu in the rail exits
//    to the tab bar).
//
//  The host (SettingsView) supplies the rail items and the per-route detail
//  builder, so this view owns geometry and focus only, not content.
//

#if os(tvOS)
import SwiftUI

struct TVSettingsRailItem: Identifiable {
    let id: String
    let route: SettingsRoute
    let label: String
    let icon: String
    let iconColor: Color
    var subtitle: String? = nil
}

struct TVSettingsSplitView<Detail: View>: View {
    let items: [TVSettingsRailItem]
    @Binding var selection: SettingsRoute
    /// Reported up to the host for the Menu-press semantics.
    @Binding var focusInDetail: Bool
    /// Incremented by the host to force focus back onto the rail
    /// (the Menu-in-detail path).
    let railReturnToken: Int
    @ViewBuilder let detail: (SettingsRoute) -> Detail

    private enum Pane: Hashable { case rail, detail }
    @FocusState private var focusedPane: Pane?
    @FocusState private var focusedRow: String?
    @State private var pendingSelection: SettingsRoute?
    @State private var debounceTask: Task<Void, Never>?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            railColumn
                .frame(width: SettingsMetrics.tvRailWidth)
                .focusSection()
                .focused($focusedPane, equals: .rail)

            detailColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .focusSection()
                .focused($focusedPane, equals: .detail)
        }
        .onChange(of: focusedPane) { _, pane in
            if pane == .detail { flushPendingSelection() }
            focusInDetail = (pane == .detail)
        }
        .onChange(of: focusedRow) { _, id in
            // Belt-and-braces: a focused rail row always means "not detail",
            // even if the container-level focusedPane binding lags.
            if id != nil { focusInDetail = false }
            guard let id,
                  let item = items.first(where: { $0.id == id }) else { return }
            scheduleSelection(item.route)
        }
        .onChange(of: railReturnToken) { _, _ in
            assertRailFocus()
        }
        .onAppear {
            assertRailFocus()
        }
    }

    // MARK: Selection debounce

    private func scheduleSelection(_ route: SettingsRoute) {
        guard route != selection else {
            pendingSelection = nil
            debounceTask?.cancel()
            return
        }
        pendingSelection = route
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if pendingSelection == route {
                    selection = route
                    pendingSelection = nil
                }
            }
        }
    }

    private func flushPendingSelection() {
        debounceTask?.cancel()
        if let pending = pendingSelection {
            selection = pending
            pendingSelection = nil
        }
    }

    /// Land focus on the rail row for the current selection, retrying while
    /// the row realizes (a lone FocusState write is dropped during layout —
    /// the GroupSidebar pattern).
    private func assertRailFocus() {
        let target = items.first(where: { $0.route == selection })?.id ?? items.first?.id
        guard let target else { return }
        Task { @MainActor in
            for _ in 0..<10 {
                focusedRow = target
                try? await Task.sleep(nanoseconds: 60_000_000)
                if focusedRow == target { break }
            }
        }
    }

    // MARK: Rail

    @Namespace private var railFocusNS

    private var railColumn: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(items) { item in
                    railRow(item)
                }
            }
            .padding(.vertical, 40)
            .padding(.leading, 60)   // overscan-safe start padding
            .padding(.trailing, 16)
        }
        .background(Color.appBackground)
        .focusScope(railFocusNS)
        // Known-issue fix: on first entry the focus engine preferred the
        // detail pane over the onAppear assert loop. defaultFocus makes the
        // rail the engine's own first choice, so the assert loop only has
        // to keep it there.
        .defaultFocus($focusedRow, items.first?.id)
        .prefersDefaultFocus(in: railFocusNS)
    }

    @ViewBuilder
    private func railRow(_ item: TVSettingsRailItem) -> some View {
        Button {
            debounceTask?.cancel()
            pendingSelection = nil
            selection = item.route
            focusedPane = .detail
        } label: {
            HStack(spacing: 14) {
                Image(systemName: item.icon)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(item.iconColor)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.label)
                        .font(.system(size: 26, weight: .medium))
                        .foregroundColor(.textPrimary)
                        .lineLimit(1)
                    if let subtitle = item.subtitle {
                        Text(subtitle)
                            .font(.system(size: 18))
                            .foregroundColor(.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(TVRailRowStyle(isSelected: item.route == selection))
        .focused($focusedRow, equals: item.id)
    }

    // MARK: Detail

    private var detailColumn: some View {
        // Each pane view brings its own ScrollView; the host caps content at
        // the v1.7.5 reading column, which inside the ~1400pt pane renders as
        // fill-with-margins (the desired look, plan A3).
        detail(selection)
            .frame(maxWidth: SettingsMetrics.tvReadingColumnWidth)
            .frame(maxWidth: .infinity, alignment: .center)
            .id(selectionIdentity)
            // Phase 5: soften the pane swap. The id change replaces the
            // whole subtree; animating on the identity crossfades the
            // outgoing/incoming panes instead of hard-cutting.
            .animation(.easeInOut(duration: 0.18), value: selectionIdentity)
    }

    /// Reset pane scroll state when the pane CHANGES, without tearing the
    /// view down on unrelated state churn.
    private var selectionIdentity: String {
        switch selection {
        case .category(let dest):    return "cat-\(dest.rawValue)"
        case .server(let id):        return "srv-\(id.uuidString)"
        case .editServer(let id):    return "edit-\(id.uuidString)"
        case .myRecordings:          return "recordings"
        }
    }
}

/// Rail row chrome per plan A3: minHeight 80, focus scale 1.02, accent 0.18
/// wash on focus, with a persistent tint for the selected row so the rail
/// shows which pane is displayed even while focus is in the detail.
private struct TVRailRowStyle: ButtonStyle {
    let isSelected: Bool
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 18)
            .frame(minHeight: 80)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isFocused
                          ? Color.accentPrimary.opacity(0.18)
                          : isSelected
                            ? Color.cardBackground
                            : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isFocused ? Color.accentPrimary : Color.clear, lineWidth: 2)
            )
            .scaleEffect(isFocused ? 1.02 : 1.0)
            .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}
#endif
