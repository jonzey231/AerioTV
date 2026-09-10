import SwiftUI

#if os(iOS)

// MARK: - Inputs

/// One card in a phone deck: a stable id and the card view.
struct PhoneDeckCard: Identifiable {
    let id: String
    let view: () -> AnyView
}

/// A titled card deck (Continue Watching, Watchlist, Recently Recorded).
struct PhoneDeck {
    let title: String
    let cards: [PhoneDeckCard]
}

/// A full-width row placed between the decks and the library header, or
/// under the search field while searching.
struct PhoneRow: Identifiable {
    let id: String
    let view: () -> AnyView
}

/// One library grid cell: the cell view carries its own navigation and
/// context menu.
struct PhoneGridItem: Identifiable {
    let id: String
    let cell: () -> AnyView
}

/// The search field's bindings. `onClose` clears the query and collapses
/// the field.
struct PhoneSearch {
    let isActive: Binding<Bool>
    let text: Binding<String>
    let placeholder: String
    let onClose: () -> Void
}

// MARK: - Page

/// The phone media page (Logan 2026-09-09: one template for Movies, TV Shows
/// and DVR). Top to bottom: room under the status bar, one card deck per
/// section, extra rows, the library header (title, count, search / sort /
/// filter circles), the search field and its extras while searching, the
/// pill row, the three-column poster grid, and the alphabet rail once the
/// grid owns the display. The tabs own their data and cards; this owns the
/// layout, spacing and every scroll rule: the collapse of the tab bar, the
/// rail fade, the scroll to the header when search opens, and the letter
/// jumps. Scroll-time numbers live in a plain box, never in view state, so
/// nothing here re-renders per frame (see the scroll-churn rule).
struct PhoneMediaPage: View {
    var decks: [PhoneDeck] = []
    var rows: [PhoneRow] = []
    let headerTitle: String
    let headerCount: Int
    var search: PhoneSearch? = nil
    var searchExtras: [PhoneRow] = []
    let sortMenu: () -> AnyView
    var onFilter: (() -> Void)? = nil
    var pills: [String] = []
    var selectedPill: Binding<String?> = .constant(nil)
    let items: [PhoneGridItem]
    var emptyView: (() -> AnyView)? = nil
    var railLetters: Set<String> = []
    /// Id of the first grid item for a rail letter.
    var railTarget: (String) -> String? = { _ in nil }

    private final class ScrollBox {
        let phoneRail = DVRPhoneRailState()
        var position = ScrollPosition()
        var contentOffsetY: CGFloat = 0
        var gridTopVisible: CGFloat = 0
        var rowPitch: CGFloat = 0
        var gridWidth: CGFloat = 0
        let tabBarTracker = TabBarScrollTracker()
    }
    @State private var box = ScrollBox()
    @State private var scrollTick = 0
    @State private var railMounted = false
    @State private var tabBarHidden = false
    @State private var scrollToHeaderTick = 0
    @FocusState private var searchFocused: Bool

    private let columnSpacing: CGFloat = 8
    private let rowSpacing: CGFloat = 16
    private let sectionSpacing: CGFloat = 18
    private let railWidth: CGFloat = 14
    private let deckHeight: CGFloat = 220
    private var isSearching: Bool { !(search?.text.wrappedValue.isEmpty ?? true) }

    private struct GridTopKey: PreferenceKey {
        nonisolated(unsafe) static var defaultValue: CGFloat? = nil
        static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
            if let v = nextValue() { value = v }
        }
    }

    var body: some View {
        GeometryReader { outer in
            ScrollViewReader { proxy in
                ZStack(alignment: .topLeading) {
                    ScrollView {
                        VStack(spacing: 0) {
                            Color.clear.frame(height: 0).id("page-top")
                            VStack(alignment: .leading, spacing: sectionSpacing) {
                                // Header height measured against DVR 2026-09-09.
                                Color.clear.frame(height: 3)
                                ForEach(decks.filter { !$0.cards.isEmpty }, id: \.title) { deck in
                                    deckSection(deck)
                                }
                                ForEach(rows) { row in row.view() }
                                libraryHeader(proxy: proxy)
                                    .id("page-library")
                                if let search, search.isActive.wrappedValue {
                                    searchField(search)
                                        .padding(.horizontal, 16)
                                }
                                if isSearching {
                                    ForEach(searchExtras) { row in row.view() }
                                }
                                if !isSearching, !pills.isEmpty {
                                    pillRow
                                }
                                if items.isEmpty, let emptyView {
                                    emptyView()
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 48)
                                }
                                grid
                                    .background(GeometryReader { g in
                                        Color.clear.preference(
                                            key: GridTopKey.self,
                                            value: g.frame(in: .named("pageScroll")).minY.rounded())
                                    })
                            }
                            Color.clear.frame(height: 96)
                        }
                    }
                    .coordinateSpace(name: "pageScroll")
                    .scrollPosition(Binding(get: { box.position }, set: { box.position = $0 }))
                    .onChange(of: scrollTick) { _, _ in }
                    .onChange(of: scrollToHeaderTick) { _, _ in
                        withAnimation(.easeInOut(duration: 0.45)) {
                            proxy.scrollTo("page-library", anchor: .top)
                        }
                    }
                    .onPreferenceChange(GridTopKey.self) { gridTopY in
                        guard let gridTopY else { return }
                        box.gridTopVisible = gridTopY
                        // Rail once the header and pills have scrolled off; the
                        // park offset is set once as it appears. Writes go to
                        // the rail's own observable so only the fade wrapper
                        // re-renders.
                        let want = gridTopY <= 110 && !isSearching && items.count >= 9
                        let rail = box.phoneRail
                        if want != rail.visible {
                            if want { rail.top = (max(0, gridTopY) / 8).rounded() * 4 }
                            rail.visible = want
                        }
                        if !railMounted { railMounted = true }
                    }
                    .onScrollGeometryChange(for: [CGFloat].self) { g in
                        [g.contentOffset.y,
                         g.contentSize.height - g.containerSize.height + g.contentInsets.bottom - g.contentInsets.top]
                    } action: { old, new in
                        let oldY = old[0], y = new[0], maxY = new[1]
                        box.contentOffsetY = y
                        // No bar changes while rubber-banding past the end.
                        if y > maxY - 1 || oldY > maxY - 1 { return }
                        if let hidden = box.tabBarTracker.update(oldY: oldY, newY: y, hidden: tabBarHidden) {
                            tabBarHidden = hidden
                        }
                    }
                    .scrollAwayTabBar(collapsed: tabBarHidden)
                    .ignoresSafeArea(.container, edges: .bottom)
                    .aerioContentUnderTabBar()
                    .aerioNoTopScrollEdge()

                    if railMounted, !isSearching {
                        AlphabetRail(available: railLetters) { letter in
                            jump(to: letter, proxy: proxy)
                        }
                        .frame(width: railWidth)
                        .modifier(PhoneRailFade(state: box.phoneRail,
                                                restingTop: max(0, (outer.size.height + outer.safeAreaInsets.top - AlphabetRail.totalHeight) / 2),
                                                boxWidth: outer.size.width,
                                                boxHeight: outer.size.height + outer.safeAreaInsets.top))
                        .ignoresSafeArea(.container, edges: .top)
                    }
                }
            }
        }
    }

    // MARK: Sections

    private func deckSection(_ deck: PhoneDeck) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(deck.title)
                .font(.headlineSmall)
                .foregroundColor(.textPrimary)
                .padding(.horizontal, 16)
            PhoneCardDeck(items: deck.cards, cardHeight: deckHeight) { card in
                card.view()
            }
        }
    }

    private func libraryHeader(proxy: ScrollViewProxy) -> some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(headerTitle)
                    .font(.headlineSmall)
                    .foregroundColor(.textPrimary)
                Text("\(headerCount)")
                    .font(.labelMedium)
                    .foregroundColor(.textTertiary)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.55)) {
                    proxy.scrollTo("page-library", anchor: .top)
                }
            }
            Spacer()
            HStack(spacing: 8) {
                if let search {
                    Button {
                        if search.isActive.wrappedValue {
                            searchFocused = false
                            withAnimation(.spring(response: 0.3)) { search.onClose() }
                        } else {
                            // Insert the field with no animation, run ONE scroll,
                            // and raise the keyboard after the scroll settles.
                            var t = Transaction(); t.disablesAnimations = true
                            withTransaction(t) { search.isActive.wrappedValue = true }
                            DispatchQueue.main.async { scrollToHeaderTick += 1 }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { searchFocused = true }
                        }
                    } label: { circle("magnifyingglass") }
                    .accessibilityLabel(search.isActive.wrappedValue ? "Close search" : "Search")
                }
                Menu { sortMenu() } label: { circle("arrow.up.arrow.down") }
                    .accessibilityLabel("Sort")
                if let onFilter {
                    Button(action: onFilter) { circle("line.3.horizontal.decrease") }
                        .accessibilityLabel("Filter")
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private func circle(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 17, weight: .semibold))
            .foregroundColor(.textPrimary)
            .frame(width: 38, height: 38)
            .background(Circle().fill(Color.textPrimary.opacity(0.08)))
    }

    /// Pill search field under the header: search glyph leading, filled X
    /// trailing that clears and closes.
    private func searchField(_ search: PhoneSearch) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.textSecondary)
            TextField(search.placeholder, text: search.text)
                .font(.system(size: 16))
                .foregroundColor(.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($searchFocused)
            Button {
                searchFocused = false
                withAnimation(.spring(response: 0.25)) { search.onClose() }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.textSecondary)
            }
            .accessibilityLabel("Clear and close search")
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(Capsule().fill(Color.elevatedBackground))
    }

    private var pillRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                DVRSegmentPill(label: "All", isSelected: selectedPill.wrappedValue == nil) {
                    selectedPill.wrappedValue = nil
                }
                ForEach(pills, id: \.self) { p in
                    DVRSegmentPill(label: p, isSelected: selectedPill.wrappedValue == p) {
                        selectedPill.wrappedValue = (selectedPill.wrappedValue == p) ? nil : p
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var grid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: columnSpacing), count: 3)
        let firstID = items.first?.id
        return LazyVGrid(columns: columns, spacing: rowSpacing) {
            ForEach(items) { item in
                item.cell()
                    .id("grid-\(item.id)")
                    .background(GeometryReader { g in
                        Color.clear.onAppear {
                            if item.id == firstID { box.rowPitch = g.size.height + rowSpacing }
                        }
                    })
            }
        }
        // Symmetric 18 pt margins so the posters sit centered; the rail
        // overlays the right edge.
        .padding(.vertical, 16)
        .padding(.horizontal, 18)
        .background(GeometryReader { g in
            Color.clear.onAppear { box.gridWidth = g.size.width - 36 }
                .onChange(of: g.size.width) { _, w in box.gridWidth = w - 36 }
        })
    }

    // MARK: Rail jump

    private func jump(to letter: String, proxy: ScrollViewProxy) {
        guard let id = railTarget(letter) else { return }
        if let index = items.firstIndex(where: { $0.id == id }), box.rowPitch > 0 {
            // Absolute offset: scrollTo(id) silently no-ops for lazy grid
            // rows not yet built.
            let row = index / 3
            let gridTopContent = box.gridTopVisible + box.contentOffsetY
            let y = gridTopContent + 16 + CGFloat(row) * box.rowPitch - 24
            withAnimation(.easeInOut(duration: 0.25)) {
                box.position.scrollTo(y: max(0, y))
                scrollTick += 1
            }
        } else {
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo("grid-\(id)", anchor: .top)
            }
        }
    }
}

/// The rail overlay wrapper: fixed-height box plus padding (an offset
/// rail's taps fell through to the posters), fading with a local animation
/// driven by the rail's own observable.
struct PhoneRailFade: ViewModifier {
    @ObservedObject var state: DVRPhoneRailState
    let restingTop: CGFloat
    let boxWidth: CGFloat
    let boxHeight: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(.top, restingTop + state.top)
            .frame(width: boxWidth, height: boxHeight, alignment: .topTrailing)
            .clipped()
            .padding(.trailing, 2)
            .opacity(state.visible ? 1 : 0)
            .allowsHitTesting(state.visible)
            .animation(.easeInOut(duration: 0.25), value: state.visible)
    }
}
#endif
