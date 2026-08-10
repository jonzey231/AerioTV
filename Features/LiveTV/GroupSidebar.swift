import SwiftUI
#if os(tvOS)
import UIKit

// MARK: - Docked Group Sidebar (tvOS)
//
// Ported from the Android `feature/livetv/GroupSidebar.kt` (Remote Control
// initiative, Logan spec 2026-07-20): the left-anchored group rail that slides
// in when the user presses Left from the "now" column. Shared between the two
// surfaces that need it:
//   - the GUIDE, via `GuideGroupSidebarPane` — a hard, opaque DOCKED side menu
//     that the guide content sits beside (no scrim, no overlay); Right steps
//     back out to the grid without changing the group, and Menu/Back does the
//     same;
//   - the PLAYER's channel-list overlay, which embeds `GroupSidebarPanel`
//     directly as its leading pane.
//
// Tokens are the same tokens the top group-pill row uses: the sentinel "All"
// (rendered "All Channels") or a raw group title. Picking a token drives the
// exact same filter the pills row does, via the `onSelect` callback the host
// wires to `selectedGroup`.
//
// Whole file is tvOS-only: it contributes nothing to the iOS build.

/// Sentinel that matches `ChannelListView.selectedGroup`'s default and the
/// leading "All" pill; rendered as "All Channels" in the sidebar.
private let groupSidebarAllToken = "All"

/// Row label type scale (10-foot). The panel width is measured against this
/// exact size + weight so the fitted width matches what actually renders.
private let groupSidebarRowFontSize: CGFloat = 30

/// Footprint of the header's `ManageGroupsButton` on tvOS: a 30pt symbol
/// (~34pt wide as drawn) plus `TVManageGroupsButtonStyle`'s 7pt padding on
/// each side, rounded up so the focus ring never clips at the panel edge.
private let groupSidebarManageButtonWidth: CGFloat = 52

/// Maps a group token to its sidebar display label: the "All" sentinel becomes
/// "All Channels", every other token renders as-is.
func groupSidebarLabel(_ token: String) -> String {
    token == groupSidebarAllToken ? "All Channels" : token
}

// MARK: - Row button style (owns the focus visual, no system platter)

/// tvOS focus style for a sidebar row. Owns the focus visual entirely through
/// `@Environment(\.isFocused)` so the system's squared focus platter is never
/// drawn (see `feedback_tvos_focus_squared_platter`): the focused row gets a
/// white wash + an inset accent border, the active row an accent tint +
/// semibold, and the border is drawn with `strokeBorder` (inset) so the ring
/// stays inside the row's footprint.
private struct GroupSidebarRowButtonStyle: ButtonStyle {
    let isActive: Bool
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        let focused = isFocused
        let fg: Color = focused ? .white : (isActive ? .accentPrimary : .textPrimary)
        let bg: Color = focused
            ? Color.white.opacity(0.16)
            : (isActive ? Color.accentPrimary.opacity(0.12) : .clear)
        return configuration.label
            .font(.system(size: groupSidebarRowFontSize, weight: isActive ? .semibold : .regular))
            .foregroundColor(fg)
            .lineLimit(1)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(bg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(focused ? Color.accentPrimary : Color.clear, lineWidth: 3)
            )
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: focused)
    }
}

// MARK: - GroupSidebarPanel

/// A focusable vertical list of group-selection rows.
///
/// - Content-sized: the width is measured from the widest rendered label (via
///   `UIFont.systemFont(ofSize:weight:.semibold)`) plus ~44pt of row chrome,
///   clamped to a 10-foot-legible 300…620pt so one very long group can't
///   dominate the guide and a single short group isn't cramped.
/// - Opaque background so the docked pane reads as a hard side menu.
/// - Lands with the active group scrolled into view and focused: on appear it
///   scrolls to the selected token and asserts `@FocusState` onto the active
///   row through a short retry loop (a single write is dropped while the row is
///   still laying out).
///
/// Rendered with `ScrollView` + `LazyVStack` rather than a SwiftUI `List`
/// because, on tvOS, `List` paints its own white highlight over the focused
/// row; the ScrollView path gives the row button style full visual control.
struct GroupSidebarPanel: View {
    let groups: [String]
    let selectedToken: String
    let onSelect: (String) -> Void
    let onDismiss: () -> Void
    /// Android-parity live preview: fires as D-pad focus lands on a row
    /// (the HOST debounces and applies the group behind the sidebar).
    /// Nil = no preview (the player overlay's group stage stays
    /// commit-on-OK only).
    let onRowFocused: ((String) -> Void)?
    /// GH #57 (Logan 2026-08-10): round Manage Groups button to the right of
    /// the "Groups" header. Sidebar mode hides the pill row, and with it the
    /// only entry point into hide/reorder, so the sidebar has to carry its
    /// own. Nil on the player's channel-list overlay, which is a transient
    /// tuning surface with no settings affordances.
    let onManageGroups: (() -> Void)?
    /// Warning dot on that button when groups are currently hidden.
    let hiddenGroupCount: Int

    @FocusState private var focusedToken: String?

    init(groups: [String],
         selectedToken: String,
         onSelect: @escaping (String) -> Void,
         onDismiss: @escaping () -> Void,
         onRowFocused: ((String) -> Void)? = nil,
         onManageGroups: (() -> Void)? = nil,
         hiddenGroupCount: Int = 0) {
        self.groups = groups
        self.selectedToken = selectedToken
        self.onSelect = onSelect
        self.onDismiss = onDismiss
        self.onRowFocused = onRowFocused
        self.onManageGroups = onManageGroups
        self.hiddenGroupCount = hiddenGroupCount
    }

    /// The row that should receive focus + be scrolled into view. Mirrors the
    /// Android `indexOf(selectedToken).coerceAtLeast(0)`: the selected token
    /// when present (e.g. a collection filter isn't in `groups`), else the
    /// first group.
    private var focusTarget: String? {
        if groups.contains(selectedToken) { return selectedToken }
        return groups.first
    }

    /// Fit the panel to the widest label at the row's type scale, then clamp.
    /// A LazyVStack can't be intrinsic-measured, so text-measuring the labels
    /// is the reliable way to size the rail.
    private var panelWidth: CGFloat {
        let font = UIFont.systemFont(ofSize: groupSidebarRowFontSize, weight: .semibold)
        let widest = groups.reduce(CGFloat(0)) { acc, token in
            let w = (groupSidebarLabel(token) as NSString)
                .size(withAttributes: [.font: font]).width
            return max(acc, w)
        }
        // 20pt row padding each side + a little breathing room past the text.
        // GH #57: the header now carries the Manage Groups button beside the
        // title, so a narrow group list must not squeeze it off the panel.
        // Floor the fit at what that header actually needs.
        let headerFont = UIFont.systemFont(ofSize: 22, weight: .semibold)
        let headerTitle = ("Groups" as NSString)
            .size(withAttributes: [.font: headerFont]).width
        let headerFloor = onManageGroups == nil
            ? 0
            : 20 + headerTitle + 12 + groupSidebarManageButtonWidth + 20
        return min(max(widest + 44, headerFloor, 300), 620)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("Groups")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.textSecondary)

                // GH #57: the sidebar's own entry into hide/reorder. Sits in
                // the header rather than the list so a D-pad Right out of a
                // row still commits and leaves (the focus engine searches the
                // focused row's own horizontal band, and this button is above
                // every row); Up from the top row is what reaches it.
                if let onManageGroups {
                    ManageGroupsButton(
                        action: onManageGroups,
                        hiddenCount: hiddenGroupCount
                    )
                }
            }
            .padding(.leading, 20)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(groups, id: \.self) { token in
                            groupRow(token)
                                .id(token)
                        }
                    }
                    .padding(.vertical, 4)
                }
                // Back/Menu dismisses when the panel is used standalone (the
                // player's channel-list overlay). When nested in
                // GuideGroupSidebarPane this fires first and calls the same
                // closure the pane passes down.
                .onExitCommand { onDismiss() }
                .onAppear { assertInitialFocus(using: proxy) }
                .onChange(of: focusedToken) { _, token in
                    if let token { onRowFocused?(token) }
                }
            }
        }
        .frame(width: panelWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.appBackground)
    }

    @ViewBuilder
    private func groupRow(_ token: String) -> some View {
        Button {
            onSelect(token)
        } label: {
            Text(groupSidebarLabel(token))
                .lineLimit(1)
        }
        .buttonStyle(GroupSidebarRowButtonStyle(isActive: token == selectedToken))
        .focused($focusedToken, equals: token)
    }

    /// Scroll the active row to center, then re-assert focus onto it until the
    /// focus engine accepts the claim (a lone write is dropped while the row is
    /// still realizing).
    private func assertInitialFocus(using proxy: ScrollViewProxy) {
        guard let target = focusTarget else { return }
        Task { @MainActor in
            proxy.scrollTo(target, anchor: .center)
            for _ in 0..<10 {
                focusedToken = target
                try? await Task.sleep(nanoseconds: 60_000_000)
                if focusedToken == target { break }
            }
        }
    }
}

// MARK: - GuideGroupSidebarPane

/// DOCKED pane for the GUIDE surface: a hard, opaque side menu that lives in
/// the same row as the guide content (the grid shifts beside it, no scrim/
/// overlay, so the channel rail stays fully readable). Wraps `GroupSidebarPanel`
/// in its own focus scope with a hairline trailing separator.
///
/// Right steps back out to the grid without changing the group; Menu/Back does
/// the same. Both route through `onDismiss`, which the host uses to collapse
/// the pane.
struct GuideGroupSidebarPane: View {
    let groups: [String]
    let selectedToken: String
    let onSelect: (String) -> Void
    let onDismiss: () -> Void
    /// Android-parity preview + commit split: `onPreview` fires per focused
    /// row (host debounces + applies the group live behind the pane);
    /// `onCommit` is Right-out-of-the-rail = KEEP the previewed group and
    /// close. Nil keeps the legacy Right-cancels behavior.
    let onPreview: ((String) -> Void)?
    let onCommit: (() -> Void)?
    /// GH #57: opens Manage Groups from the header button. See
    /// `GroupSidebarPanel.onManageGroups`.
    let onManageGroups: (() -> Void)?
    let hiddenGroupCount: Int

    @Namespace private var sidebarFocusNS

    init(groups: [String],
         selectedToken: String,
         onSelect: @escaping (String) -> Void,
         onDismiss: @escaping () -> Void,
         onPreview: ((String) -> Void)? = nil,
         onCommit: (() -> Void)? = nil,
         onManageGroups: (() -> Void)? = nil,
         hiddenGroupCount: Int = 0) {
        self.groups = groups
        self.selectedToken = selectedToken
        self.onSelect = onSelect
        self.onDismiss = onDismiss
        self.onPreview = onPreview
        self.onCommit = onCommit
        self.onManageGroups = onManageGroups
        self.hiddenGroupCount = hiddenGroupCount
    }

    var body: some View {
        HStack(spacing: 0) {
            GroupSidebarPanel(
                groups: groups,
                selectedToken: selectedToken,
                onSelect: onSelect,
                onDismiss: onDismiss,
                onRowFocused: onPreview,
                onManageGroups: onManageGroups,
                hiddenGroupCount: hiddenGroupCount
            )
            .padding(.vertical, 24)
            .padding(.leading, 20)
            .padding(.trailing, 12)
            .frame(maxHeight: .infinity)
            .background(Color.appBackground)
            .focusScope(sidebarFocusNS)

            // Hairline separating the menu from the shifted guide.
            Rectangle()
                .fill(Color.accentPrimary.opacity(0.25))
                .frame(width: 1)
                .frame(maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity)
        // Right has no focusable target inside the vertical rail, so the move
        // bubbles here and steps back out to the grid. With the preview flow
        // wired, Right COMMITS the previewed group (Android parity: OK or
        // Right keeps it, Back reverts); the legacy host keeps Right=cancel.
        // Up/Down are consumed by row-to-row focus movement and never reach
        // this handler.
        .onMoveCommand { direction in
            if direction == .right { (onCommit ?? onDismiss)() }
        }
        .onExitCommand { onDismiss() }
    }
}
#endif
