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
    /// Re-renders on a live theme change (sync apply, profile switch); the Color tokens read ThemeManager.shared directly.
    @ObservedObject private var themeLive = ThemeManager.shared
    let items: [TVSettingsRailItem]
    @Binding var selection: SettingsRoute
    /// Reported up to the host for the Menu-press semantics.
    @Binding var focusInDetail: Bool
    /// Incremented by the host to force focus back onto the rail
    /// (the Menu-in-detail path).
    let railReturnToken: Int
    /// Incremented by the host to push focus INTO the detail pane (the
    /// `aerio://settings/<page>` screenshot path, which selects a rail item
    /// programmatically and then needs focus on the pane it opened).
    var detailFocusToken: Int = 0
    @ViewBuilder let detail: (SettingsRoute) -> Detail

    private enum Pane: Hashable { case rail, detail }
    @FocusState private var focusedPane: Pane?
    @FocusState private var focusedRow: String?
    @FocusState private var entryCatcherFocused: Bool
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
                // Left from a page: the engine's own search lands on the
                // geometrically nearest rail row and the onChange below
                // then moves focus to the page's row, a visible two-step
                // flash (simulator trace 2026-11-06 14:34:06: "@623,808 ->
                // @60,799 Remote Control", then "Live TV" 63 ms later).
                // This strip at the pane's leading edge is the nearest
                // thing to the left of every detail row, so the engine
                // takes it first, and the strip redirects to the page's
                // own row in that same move. Mounted only while focus is
                // in the detail pane (SwiftUI registers a UIKit item's
                // focusability at insertion, so toggling it later is not
                // seen), which also keeps Right from the rail untouched.
                // Outside the pane's `.focused` so the strip never counts
                // as detail focus.
                .overlay(alignment: .leading) {
                    if focusedPane == .detail {
                        TVRailReturnGuide { assertRailFocus() }
                        .frame(width: 24)
                        .frame(maxHeight: .infinity)
                    }
                }
                // Entry catcher: mounted only while focus is outside both
                // panes (tab bar). Down from the far-right Settings pill
                // otherwise lands on the first detail row and bounces to
                // the rail 70 ms later (trace 2026-09-05 00:28:00). The
                // strip is the nearest thing below the pill, takes the hop
                // invisibly and forwards to the rail; it unmounts as soon
                // as a pane has focus so Up from the detail pane still
                // reaches the tab bar. Outside the pane's `.focused` so
                // taking it never flips focusedPane.
                .overlay(alignment: .top) {
                    if focusedPane == nil {
                        Color.clear
                            .frame(maxWidth: .infinity)
                            .frame(height: 1)
                            .focusable(true)
                            .focused($entryCatcherFocused)
                    }
                }
        }
        .onChange(of: entryCatcherFocused) { _, on in
            if on {
                SettingsFocusLog.log("focus set rail: entry catcher took focus from tab bar")
                assertRailFocus()
            }
        }
        .onChange(of: focusedPane) { old, pane in
            SettingsFocusLog.log("pane focus \(String(describing: old)) -> \(String(describing: pane))")
            if pane == .detail { flushPendingSelection() }
            // Back on the rail from a page: keep the page's own row (the
            // engine's default can still pick the first row).
            if old == .detail, pane == .rail,
               let row = items.first(where: { $0.route == selection })?.id, focusedRow != row {
                SettingsFocusLog.log("focus set rail: return to the page's row \(row)")
                focusedRow = row
            }
            focusInDetail = (pane == .detail)
            TVSettingsNavState.shared.focusInPanes = (pane != nil)
        }
        .onChange(of: focusedRow) { _, id in
            // Belt-and-braces: a focused rail row always means "not detail",
            // even if the container-level focusedPane binding lags.
            if id != nil { focusInDetail = false }
            TVSettingsNavState.shared.railFocus = id.flatMap { id in items.first(where: { $0.id == id })?.route }
            guard let id,
                  let item = items.first(where: { $0.id == id }) else { return }
            SettingsFocusLog.rowFocused(page: "Rail", row: item.label)
            if TVSettingsNavState.shared.holdsSelection, item.route != selection {
                SettingsFocusLog.log("rail selection held for a restore: \(item.route) not taken")
                if TVSettingsNavState.shared.holdReturnsToRail { assertRailFocus() }
                return
            }
            scheduleSelection(item.route)
        }
        .onChange(of: railReturnToken) { _, _ in
            SettingsFocusLog.log("focus set rail: railReturnToken (Menu in detail or deep link)")
            assertRailFocus()
        }
        .onChange(of: detailFocusToken) { _, _ in
            SettingsFocusLog.log("focus set detail: detailFocusToken (deep link)")
            assertDetailFocus()
        }
        .onChange(of: selection) { old, new in
            SettingsFocusLog.log("rail selection \(old) -> \(new)")
        }
        // Down from the Settings pill lands geometrically in the detail
        // pane (the pill is far right; the nearest row below it is a
        // playlist, trace 2026-09-05 00:25:57) and defaultFocus does not
        // override that. Redirect only that hop: a move whose previous
        // item was a tab bar pill. Focus returning from a pushed page or
        // moving right off the rail is left alone.
        .onReceive(NotificationCenter.default.publisher(for: UIFocusSystem.didUpdateNotification)) { note in
            guard let ctx = note.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext,
                  let prev = ctx.previouslyFocusedItem,
                  String(describing: type(of: prev)) == "UITabBarButton" else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                if focusedPane == .detail {
                    SettingsFocusLog.log("focus set rail: Down from tab bar landed in detail")
                    assertRailFocus()
                }
            }
        }
        .onAppear {
            // Only when focus is already inside the panes. tvOS selects a
            // tab as soon as its pill is focused, which mounts this view;
            // asserting here then pulled focus off the Settings pill onto
            // the Playlists row 0.6 s later with no press (trace
            // 2026-09-05 00:22:14, "Settings auto-selects Playlists").
            // Down from the pill still lands on the rail via defaultFocus.
            if focusedPane != nil {
                SettingsFocusLog.log("focus set rail: split view appeared with focus in a pane")
                assertRailFocus()
            }
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
    /// the row realizes (a lone FocusState write is dropped during layout,
    /// the GroupSidebar pattern).
    private func assertRailFocus() {
        let target = items.first(where: { $0.route == selection })?.id ?? items.first?.id
        guard let target else { return }
        Task { @MainActor in
            for attempt in 0..<10 {
                focusedRow = target
                try? await Task.sleep(nanoseconds: 60_000_000)
                if focusedRow == target {
                    SettingsFocusLog.log("focus set rail: focusedRow = \(target) took on attempt \(attempt + 1)")
                    return
                }
            }
            SettingsFocusLog.log("focus set rail: focusedRow = \(target) did not take after 10 attempts")
        }
    }

    /// Move focus into the detail pane, retrying while the pane realizes
    /// (same dropped-FocusState-write problem `assertRailFocus` solves).
    private func assertDetailFocus() {
        flushPendingSelection()
        Task { @MainActor in
            for attempt in 0..<10 {
                focusedPane = .detail
                try? await Task.sleep(nanoseconds: 60_000_000)
                if focusedPane == .detail {
                    SettingsFocusLog.log("focus set detail: focusedPane = detail took on attempt \(attempt + 1)")
                    return
                }
            }
            SettingsFocusLog.log("focus set detail: focusedPane = detail did not take after 10 attempts")
        }
    }

    // MARK: Rail

    @Namespace private var railFocusNS

    private var railColumn: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: RailMetrics.rowGap) {
                ForEach(items) { item in
                    railRow(item)
                }
            }
            // Room for the focus ring (a 2 pt stroke centered on the row's
            // edge) inside the clip below.
            .padding(.vertical, RailMetrics.ringRoom)
            .padding(.leading, 60)   // overscan-safe start padding
            .padding(.trailing, 16)
        }
        // The whole rail fits without scrolling, so it never moves: the row
        // pitch (RailMetrics) fits 12 rows, Android TV's count with its
        // Updates row, between the resting top and the bottom safe area at
        // the default text size; Apple uses the same pitch for its 11.
        // Larger text sizes can still overflow, and then the rail scrolls.
        // A tvOS ScrollView does not clip, so scrolled rows drew above the
        // rail into the tab bar's band (device report 2026-11-12); they now
        // clip at the rail's resting top, level with the detail card's top,
        // because the clip sits inside the top padding. Drawing only: focus
        // and the detail pane are unchanged.
        .clipped()
        .padding(.top, RailMetrics.restingTop - RailMetrics.ringRoom)
        .background(Color.appBackground)
        .focusScope(railFocusNS)
        // Known-issue fix: on first entry the focus engine preferred the
        // detail pane over the onAppear assert loop. defaultFocus makes the
        // rail the engine's own first choice, so the assert loop only has
        // to keep it there.
        // The CURRENT page's row, so Left from a page returns to its own
        // entry, not Playlists (tvOS review 2026-11-05).
        .defaultFocus($focusedRow, items.first(where: { $0.route == selection })?.id ?? items.first?.id)
        .prefersDefaultFocus(in: railFocusNS)
    }

    @ViewBuilder
    private func railRow(_ item: TVSettingsRailItem) -> some View {
        Button {
            debounceTask?.cancel()
            pendingSelection = nil
            selection = item.route
            SettingsFocusLog.log("focus set detail: rail row \(item.label) clicked")
            focusedPane = .detail
        } label: {
            HStack(spacing: 14) {
                Image(systemName: item.icon)
                    .scaledFont(.system(size: 24, weight: .semibold))
                    .foregroundColor(item.iconColor)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.label)
                        .scaledFont(.system(size: 26, weight: .medium))
                        .foregroundColor(.textPrimary)
                        .lineLimit(1)
                    if let subtitle = item.subtitle {
                        Text(subtitle)
                            .scaledFont(.system(size: 18).subtext())
                            .foregroundColor(Color.contrastText(.textTertiary))
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
        }
    }
}

/// The Left-from-detail catcher. A UIFocusGuide cannot do this job here:
/// SwiftUI's hosting view never enumerates a non-focusable UIKit subview
/// as a focus item container, so a guide inside it is invisible to the
/// engine (simulator 2026-11-06 14:41: enabled, in the window, frame
/// 510,157 24x863, `focusItems(in:)` never queried). A focusable UIKit
/// view IS found (the PressCatcherView precedent): the strip is the
/// engine's pick for Left from any detail row, it cancels that update in
/// `shouldUpdateFocus` (nothing moves, no flash), and `redirect` writes
/// the page's row through the host's FocusState, which the engine applies
/// as one move from the detail row to that row (trace: a single
/// "[FOCUS] none: @623,808 -> @60,283"). The strip is never focused;
/// `didUpdateFocus` is the belt-and-braces path if it ever were.
private struct TVRailReturnGuide: UIViewRepresentable {
    let redirect: () -> Void

    func makeUIView(context: Context) -> UIView {
        // Own container so a focus replicant, if one is ever made, lands
        // in a legitimate UIKit hierarchy (TVPressOverlay precedent). User
        // interaction stays on: UIKit never focuses a view under a
        // non-interactive ancestor.
        let container = UIView()
        let catcher = CatcherView(frame: .zero)
        catcher.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(catcher)
        NSLayoutConstraint.activate([
            catcher.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            catcher.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            catcher.topAnchor.constraint(equalTo: container.topAnchor),
            catcher.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        catcher.redirect = redirect
        return container
    }

    func updateUIView(_ view: UIView, context: Context) {
        view.subviews.compactMap({ $0 as? CatcherView }).first?.redirect = redirect
    }

    final class CatcherView: UIView {
        var redirect: (() -> Void)?
        /// The engine re-asks up to five times after a veto (simulator
        /// trace 2026-11-06 14:52); one redirect per press is enough.
        private var lastRedirect = Date.distantPast

        override var canBecomeFocused: Bool { true }

        override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
            guard context.nextFocusedItem === self else { return super.shouldUpdateFocus(in: context) }
            if Date().timeIntervalSince(lastRedirect) > 0.25 {
                lastRedirect = Date()
                SettingsFocusLog.log("rail guide: Left from the detail pane cancelled, redirecting to the page's row")
                DispatchQueue.main.async { [weak self] in self?.redirect?() }
            }
            return false
        }

        override func didUpdateFocus(in context: UIFocusUpdateContext,
                                     with coordinator: UIFocusAnimationCoordinator) {
            super.didUpdateFocus(in: context, with: coordinator)
            if context.nextFocusedItem === self {
                SettingsFocusLog.log("rail guide: strip took focus, redirecting to the page's row")
                redirect?()
            }
        }
    }
}

/// Rail geometry, in points. 12 rows x 64 + 11 gaps x 4 = 812, which fits
/// the 823 between the resting top (40 below the rail's top edge) and the
/// bottom safe area. The 26/18 pt label and subtitle measure 55 pt at the
/// default text size, inside the 64 pt row.
private enum RailMetrics {
    static let rowHeight: CGFloat = 64
    static let rowGap: CGFloat = 4
    /// The first row's top, below the rail's top edge (unchanged from the
    /// scrolling rail's 40 pt top padding). The pane shares this line.
    static let restingTop: CGFloat = TVSettingsPaneMetrics.topLine
    static let ringRoom: CGFloat = 2
}

/// The one container geometry for every Settings rail page (owner
/// 2026-11-13, Apple TV device check), taken from the Live TV page. Before,
/// pages used three: Playlists and Sync padded 40 (cards 8 pt wider each
/// side, the first card level with the rail's first row), Player, Movies &
/// TV Shows, and Remote Control padded 80 by 60 (32 pt narrower each side,
/// the first eyebrow 12 pt lower), and the rest padded 48.
enum TVSettingsPaneMetrics {
    /// The rail's resting top, below the panes' top edge: the pane's scroll
    /// area starts here, so content scrolls up to this line and fades out
    /// at it, never under the tab bar.
    static let topLine: CGFloat = 40
    /// The first element's top at rest, below the pane's top edge (the Live
    /// TV page's eyebrow: just below the rail's first row top).
    static let firstElementTop: CGFloat = 48
    /// Leading and trailing inset inside the centered reading column.
    static let horizontal: CGFloat = 48
    static let bottom: CGFloat = 48
    /// Scrolled content fades out over this band at the top line (as What's
    /// New's list does under its header).
    static let fadeHeight: CGFloat = 30
    /// How far content may still draw below the pane (into the bottom
    /// overscan band, to the screen's edge).
    static let bottomOverhang: CGFloat = 80
}

/// Every Settings rail page's scroll container: one x, width, top, and
/// eyebrow position (TVSettingsPaneMetrics). Content scrolls up to the
/// rail's top line and fades out there; at rest nothing is faded.
/// Pushed pages (Sync Categories, a playlist's detail and Edit Playlist,
/// subgroup pages) use it too, with their title as the first element:
/// their rows stop and fade at the same line, below the tab bar and the
/// profile avatar (Apple TV device capture 2026-11-13, atv5).
struct TVSettingsPane<Content: View>: View {
    var title: String? = nil
    let spacing: CGFloat
    let content: Content
    @State private var scrolled = false

    init(title: String? = nil, spacing: CGFloat = 32, @ViewBuilder content: () -> Content) {
        self.title = title
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: spacing) {
                if let title {
                    Text(title)
                        .scaledFont(.system(size: 38, weight: .semibold))
                        .foregroundColor(.textPrimary)
                        // Apple TV page titles are centered (owner 2026-11-12).
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.horizontal, 20)
                }
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, TVSettingsPaneMetrics.horizontal)
            .padding(.top, TVSettingsPaneMetrics.firstElementTop - TVSettingsPaneMetrics.topLine)
            .padding(.bottom, TVSettingsPaneMetrics.bottom)
            // The reading column: already the cap inside the split view's
            // pane; it matters when a page is pushed full width.
            .frame(maxWidth: SettingsMetrics.tvReadingColumnWidth)
            .frame(maxWidth: .infinity)
        }
        .onScrollGeometryChange(for: Bool.self) { g in
            WhatsNewRules.fadeActive(scrolledBy: Double(g.contentOffset.y + g.contentInsets.top))
        } action: { _, isScrolled in
            scrolled = isScrolled
        }
        // A tvOS ScrollView does not clip: without the mask, scrolled rows
        // drew up behind the tab bar and the profile avatar (device p12).
        .mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [scrolled ? .clear : .black, .black],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: TVSettingsPaneMetrics.fadeHeight)
                Color.black
            }
            // Only the top is cut: below, rows still run past the safe area
            // to the screen's edge as before, a cue that the page scrolls.
            .padding(.bottom, -TVSettingsPaneMetrics.bottomOverhang)
            .animation(.easeInOut(duration: 0.2), value: scrolled)
        }
        .padding(.top, TVSettingsPaneMetrics.topLine)
    }
}

/// Rail row chrome per plan A3 (row height now RailMetrics.rowHeight), accent
/// 0.18 wash on focus, with a persistent tint for the selected row so the rail
/// shows which pane is displayed even while focus is in the detail.
private struct TVRailRowStyle: ButtonStyle {
    /// Re-renders on a live theme change (sync apply, profile switch); the Color tokens read ThemeManager.shared directly.
    @ObservedObject private var themeLive = ThemeManager.shared
    let isSelected: Bool
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 18)
            .frame(minHeight: RailMetrics.rowHeight)
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
            // No focus scale: a focused row must share its siblings'
        // exact frame (Logan 2026-09-19 - the 1.02 bump made the
        // focused row read as wider than its neighbours). The
        // accent ring and fill carry focus.
            .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}
#endif
