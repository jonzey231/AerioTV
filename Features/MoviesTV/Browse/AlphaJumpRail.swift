#if os(tvOS)
import SwiftUI

/// Vertical A-Z (plus "#") strip pinned to the left edge of a browse grid.
///
/// This is the defining 10-foot affordance for a large library: paging a
/// 17,000-title grid a row at a time with a D-pad is not navigation, and every
/// mature TV media app solves it with a letter rail. Focusing a letter scrolls
/// the grid to the first title in that bucket.
///
/// Focus behaviour and styling are adapted from `GroupSidebarPanel`, the rail
/// this app already ships in the Live TV guide, because its hard-won details
/// apply verbatim here:
///
///   - The rail is its own `focusSection()`, so D-pad Left from grid column 0
///     enters it and D-pad Right returns to the grid instead of the focus
///     engine resolving geometrically into whatever happens to sit alongside.
///   - The focus visual is owned entirely through `@Environment(\.isFocused)`
///     with `TVNoRingButtonStyle`-style suppression, so tvOS never paints its
///     squared platter over a round letter chip
///     (see `feedback_tvos_focus_squared_platter`).
///   - `ScrollView` + `LazyVStack`, never `List`: `List` paints its own white
///     highlight over the focused row and takes visual control away.
///
/// Jumping happens on FOCUS, not on click. Requiring a click to jump would mean
/// the user cannot skim the library by holding a direction, which is the whole
/// point of the rail.
struct AlphaJumpRail: View {
    /// Buckets in rail order, with the grid index each one jumps to.
    let buckets: [(bucket: String, index: Int)]
    /// Called with the target grid index when a letter takes focus.
    let onJump: (Int) -> Void

    @FocusState private var focusedBucket: String?

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 4) {
                ForEach(buckets, id: \.bucket) { entry in
                    // A Button, not a bare focusable Text: tvOS only routes
                    // D-pad focus to genuinely focusable elements, and Button
                    // gives the pressed state for free if a user does click.
                    Button {
                        onJump(entry.index)
                    } label: {
                        Text(entry.bucket)
                    }
                    .buttonStyle(AlphaJumpLetterStyle())
                    .focused($focusedBucket, equals: entry.bucket)
                }
            }
            .padding(.vertical, 12)
        }
        .frame(width: 64)
        .focusSection()
        .onChange(of: focusedBucket) { _, bucket in
            // Focus IS the gesture. Guard on a real bucket so the jump does not
            // re-fire when focus leaves the rail entirely (bucket becomes nil).
            guard let bucket,
                  let entry = buckets.first(where: { $0.bucket == bucket })
            else { return }
            onJump(entry.index)
        }
    }
}

/// Round letter chip. Focused draws an accent fill; unfocused stays a quiet
/// secondary glyph so the rail never competes with the posters for attention.
private struct AlphaJumpLetterStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        let focused = isFocused
        return configuration.label
            .font(.system(size: 22, weight: focused ? .bold : .medium))
            .foregroundColor(focused ? .white : .textSecondary)
            .frame(width: 44, height: 44)
            .background(
                Circle().fill(focused ? Color.accentPrimary : Color.clear)
            )
            .scaleEffect(focused ? 1.15 : 1.0)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: focused)
    }
}
#endif
