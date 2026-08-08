import SwiftUI

/// One horizontal "Recently Added" shelf on the Movies & TV Home section.
///
/// Built from the same skeleton as `ContinueWatchingSection` (header, then a
/// horizontal ScrollView of cards) because that layout is already proven on
/// all four form factors. The tvOS specifics are the load-bearing part and are
/// carried over verbatim:
///
///   - The rail is its own `focusSection()`, so D-pad Down from the row above
///     lands on the leftmost VISIBLE card instead of making a geometric jump
///     into whatever happens to sit directly below.
///   - Cards use `TVCardButtonStyle` for focus scaling.
///
/// "See all" opens the grid pre-scoped to this library.
struct MediaShelfRow: View {
    let title: String
    let items: [VODDisplayItem]
    var headers: [String: String] = [:]
    /// Nil hides the affordance (a shelf with nothing more to show).
    var onSeeAll: (() -> Void)?

    private var headerSpacing: CGFloat {
        #if os(tvOS)
        20
        #else
        8
        #endif
    }

    private var cardSpacing: CGFloat {
        #if os(tvOS)
        24
        #else
        12
        #endif
    }

    private var posterWidth: CGFloat {
        #if os(tvOS)
        200
        #else
        120
        #endif
    }

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: headerSpacing) {
                header

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: cardSpacing) {
                        ForEach(items) { item in
                            NavigationLink(value: item) {
                                VODPosterCard(item: item, headers: headers)
                                    .frame(width: posterWidth)
                            }
                            #if os(tvOS)
                            .buttonStyle(TVCardButtonStyle())
                            #else
                            .buttonStyle(.plain)
                            #endif
                        }
                    }
                    .padding(.horizontal, 16)
                    #if os(tvOS)
                    // Focus scaling on the edge cards overflows the rail's
                    // bounds; without vertical room the grown card clips.
                    .padding(.vertical, 12)
                    #endif
                }
                #if os(tvOS)
                .focusSection()
                #endif
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.headline)
                .foregroundColor(.textPrimary)
            Spacer()
            if let onSeeAll {
                Button(action: onSeeAll) {
                    Text("See All")
                        .font(.labelMedium)
                        .foregroundColor(.accentPrimary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .zIndex(0)
    }
}
