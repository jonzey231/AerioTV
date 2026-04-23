import SwiftUI

// MARK: - Program Info Target
//
// Minimal value type that carries everything `ProgramInfoView` needs
// to render a program detail modal. Callers build one of these from
// whichever richer program object they have on hand — `GuideProgram`
// in the guide grid, `EPGEntry` + channel context in the list-view
// expanded panel, or `ChannelDisplayItem.currentProgram*` fields for
// the always-visible "now airing" card.
//
// `Identifiable` so call sites can use the `.sheet(item:)` /
// `.fullScreenCover(item:)` form, which presents / dismisses based on
// whether the state is non-nil. Cleaner than tracking a separate Bool
// + a payload that has to survive the dismiss animation.
//
// The `id` is built from the same title+start+end triple `EPGEntry`
// uses so switching programs in rapid succession doesn't fight
// SwiftUI's identity diffing.
struct ProgramInfoTarget: Identifiable, Equatable {
    let channelName: String
    let title: String
    let start: Date
    let end: Date
    let description: String
    /// Raw XMLTV `<category>` string. May contain multiple categories
    /// separated by `,`, `/`, or `;` (e.g. `"Drama, Sci-Fi"`). The
    /// pill renderer splits on those separators and colours each
    /// token independently so users can see both how the feed tagged
    /// the program AND how each tag resolves into Aerio's category
    /// palette.
    let category: String

    var id: String {
        "\(title)-\(start.timeIntervalSinceReferenceDate)-\(end.timeIntervalSinceReferenceDate)"
    }
}

// MARK: - Program Info View
//
// Read-only modal that surfaces everything Aerio knows about a
// single program. Opened from the long-press / context-menu on any
// program cell (guide grid) or row (list view). Purpose is twofold:
//
//   1. Let users read the description + category metadata without
//      needing to start playback.
//   2. Expose the category tagging behind the v1.6.4 guide-cell tint
//      so users can audit their EPG feed quality from inside the app.
//      Matching colour between the info pill and the guide tint is
//      intentional — the pill IS the legend for the grid.
//
// Missing fields are surfaced, not hidden. A program whose XMLTV
// entry has no `<desc>` shows a "No description…" placeholder
// instead of a gap; a missing category renders a neutral-grey pill
// labeled with the raw token. This matches Archie's "audit from
// inside the app" requirement — a silent empty field teaches the
// user nothing about why a program isn't tinted.
struct ProgramInfoView: View {
    let target: ProgramInfoTarget
    @Environment(\.dismiss) private var dismiss

    // Shared between platforms: a formatter for the start/end time
    // row. 12-hour on iOS (user locale), short style on tvOS.
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .none
        f.dateStyle = .medium
        return f
    }()

    /// Duration label — "45 min", "1 h 30 min", "2 h". Duration of 0
    /// or negative (malformed EPG) falls back to "—".
    private var durationLabel: String {
        let seconds = end.timeIntervalSince(start)
        guard seconds > 0 else { return "—" }
        let totalMinutes = Int((seconds / 60).rounded())
        if totalMinutes < 60 {
            return "\(totalMinutes) min"
        }
        let hours = totalMinutes / 60
        let mins = totalMinutes % 60
        if mins == 0 {
            return "\(hours) h"
        }
        return "\(hours) h \(mins) min"
    }

    private var start: Date { target.start }
    private var end: Date { target.end }
    private var isLive: Bool { start <= Date() && end > Date() }

    /// Time range + date header. Collapses "same day" to just the
    /// time range; adds the date only when the program spans or
    /// starts on a different calendar day than today (late-night
    /// programs that start at 23:45 and end at 00:30 still read
    /// as "today" here — that's fine, the date row is an
    /// affordance for overnight / future recording scheduling
    /// more than strict precision).
    private var timeRangeLabel: String {
        let start = Self.timeFormatter.string(from: target.start)
        let end = Self.timeFormatter.string(from: target.end)
        return "\(start) – \(end)"
    }

    private var dateLabel: String {
        Self.dateFormatter.string(from: target.start)
    }

    /// Split raw category string on XMLTV's common separators. Empty
    /// tokens (double-commas, trailing separators) are filtered out.
    private var categoryTokens: [String] {
        let separators = CharacterSet(charactersIn: ",/;")
        return target.category
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// XMLTV program-type/format words that describe HOW a program is
    /// packaged rather than WHAT it contains. Shown in a separate
    /// "Metadata" pill row so users can see the content categories
    /// on their own without the format-indicator noise drowning
    /// them out. These are the words Archie specifically called out
    /// as not being genres — "Episode", "Series", etc. The match
    /// is case-insensitive and exact (not substring) so "Comedy"
    /// never accidentally lands in Metadata.
    private static let metadataTokens: Set<String> = [
        "episode",
        "series",
        "movie",
        "film",
        "feature",
        "feature film",
        "short",
        "short film",
        "special",
        "premiere",
        "season premiere",
        "series premiere",
        "finale",
        "season finale",
        "series finale",
        "rerun",
        "repeat",
        "live",
        "pilot",
        "made-for-tv movie",
        "made for tv movie",
        "miniseries",
        "limited series"
    ]

    /// Category tokens classified as XMLTV metadata (format/type).
    private var metadataPills: [String] {
        categoryTokens.filter { Self.metadataTokens.contains($0.lowercased()) }
    }

    /// Category tokens that are actual genres — everything not
    /// claimed by `metadataPills`. These are the tokens the category
    /// colour palette tries to resolve into buckets (Sports, News,
    /// Drama, etc.) for the pill tint.
    private var genrePills: [String] {
        categoryTokens.filter { !Self.metadataTokens.contains($0.lowercased()) }
    }

    var body: some View {
        #if os(tvOS)
        tvBody
        #else
        NavigationStack {
            iOSForm
                // Suppress the system grouped-list background so the
                // sheet stays on the app's black theme at both
                // `.medium` and `.large` detents. Without this the
                // Form renders its default "grouped list" grey,
                // which looks off against the rest of Aerio's dark
                // chrome (user-reported: expanded sheet turns gray).
                .scrollContentBackground(.hidden)
                .background(Color.appBackground)
                .navigationTitle("Program Info")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
                .toolbarBackground(Color.appBackground, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.appBackground)
        #endif
    }

    // MARK: - iOS Layout

    #if os(iOS)
    @ViewBuilder
    private var iOSForm: some View {
        Form {
            Section {
                LabeledContent("Channel", value: target.channelName)
                LabeledContent("Program", value: target.title)
                LabeledContent("Airs", value: timeRangeLabel)
                LabeledContent("Date", value: dateLabel)
                LabeledContent("Duration", value: durationLabel)
                if isLive {
                    HStack {
                        Text("LIVE")
                            .font(.caption.weight(.bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.statusLive, in: Capsule())
                        Spacer()
                    }
                }
            }

            Section("Description") {
                descriptionText
                    .textSelection(.enabled)
            }

            // Metadata pills — XMLTV format indicators. Rendered as
            // neutral grey pills regardless of palette state because
            // they're not genres (no tint mapping applies).
            if !metadataPills.isEmpty {
                Section("Metadata") {
                    CategoryPillsLayout(spacing: 6) {
                        ForEach(metadataPills, id: \.self) { token in
                            CategoryPill(rawToken: token, forceNeutral: true)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            // Genre pills — tokens that may resolve to a palette
            // bucket (Sports, Drama, etc.). Unresolved tokens still
            // render as neutral grey pills so the user can audit
            // what their feed tagged.
            if !genrePills.isEmpty {
                Section("Categories") {
                    CategoryPillsLayout(spacing: 6) {
                        ForEach(genrePills, id: \.self) { token in
                            CategoryPill(rawToken: token)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
    #endif

    // MARK: - tvOS Layout

    #if os(tvOS)
    @ViewBuilder
    private var tvBody: some View {
        ZStack(alignment: .topTrailing) {
            Color.appBackground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 36) {
                    // Header — channel + title + live badge
                    VStack(alignment: .leading, spacing: 12) {
                        Text(target.channelName.uppercased())
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundColor(.textSecondary)
                            .tracking(1.5)
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            Text(target.title)
                                .font(.system(size: 44, weight: .bold))
                                .foregroundColor(.textPrimary)
                            if isLive {
                                Text("LIVE")
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(Color.statusLive, in: Capsule())
                            }
                        }
                    }

                    // Time row — date + range + duration
                    HStack(spacing: 40) {
                        infoColumn(title: "Airs", value: timeRangeLabel)
                        infoColumn(title: "Date", value: dateLabel)
                        infoColumn(title: "Duration", value: durationLabel)
                    }

                    // Description
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Description")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(.textSecondary)
                        descriptionText
                    }

                    // Metadata pills (XMLTV format indicators — neutral
                    // grey, not palette-tinted).
                    if !metadataPills.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Metadata")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundColor(.textSecondary)
                            CategoryPillsLayout(spacing: 10) {
                                ForEach(metadataPills, id: \.self) { token in
                                    CategoryPill(rawToken: token, forceNeutral: true)
                                }
                            }
                        }
                    }

                    // Genre pills (palette-tinted where the token
                    // matches a bucket / custom entry).
                    if !genrePills.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Categories")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundColor(.textSecondary)
                            CategoryPillsLayout(spacing: 10) {
                                ForEach(genrePills, id: \.self) { token in
                                    CategoryPill(rawToken: token)
                                }
                            }
                        }
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 80)
                .padding(.vertical, 72)
                .frame(maxWidth: 1200, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button("Close") { dismiss() }
                .padding(.top, 48)
                .padding(.trailing, 64)
        }
        // tvOS Menu button defaults to dismissing the fullScreenCover,
        // but being explicit keeps the behaviour intentional. The
        // .onExitCommand handler runs even when the Close button
        // doesn't have focus, which matches users' Menu-to-back
        // expectation throughout the app.
        .onExitCommand { dismiss() }
    }

    private func infoColumn(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.textTertiary)
                .tracking(1.2)
            Text(value)
                .font(.system(size: 22, weight: .medium))
                .foregroundColor(.textPrimary)
        }
    }
    #endif

    // MARK: - Shared Chrome

    @ViewBuilder
    private var descriptionText: some View {
        if target.description.isEmpty {
            #if os(tvOS)
            Text("No program description provided in XMLTV.")
                .font(.system(size: 22))
                .foregroundColor(.textTertiary)
                .italic()
            #else
            Text("No program description provided in XMLTV.")
                .foregroundStyle(.secondary)
                .italic()
            #endif
        } else {
            #if os(tvOS)
            Text(target.description)
                .font(.system(size: 24))
                .foregroundColor(.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            #else
            Text(target.description)
                .fixedSize(horizontal: false, vertical: true)
            #endif
        }
    }
}

// MARK: - Category Pill
//
// Colour comes from the same `CategoryColor` palette the guide grid
// uses for cell tint, so a pill in this modal matches the tint on
// the cell the user long-pressed to open the modal. Resolution
// order matches `CategoryColor.backgroundColor`:
//
//   1. User-defined custom category (from Settings) — hex wins.
//   2. Built-in bucket whose aliases contain the token — bucket's
//      current (possibly user-overridden) colour wins.
//   3. Neither — neutral grey pill so the token is still visible,
//      teaching the user that this tag doesn't resolve to any
//      colour in their palette. Part of the "audit EPG quality"
//      goal.
//
// The label is always the RAW token from the XMLTV feed, not the
// resolved bucket's display name. Users asked for "how did my feed
// tag this program" — showing the bucket name would hide the raw
// data behind Aerio's canonicalisation.
private struct CategoryPill: View {
    let rawToken: String
    /// When true, skip palette resolution entirely and render as a
    /// neutral grey pill. Used for the "Metadata" section in
    /// `ProgramInfoView`, whose tokens (Episode / Series / Movie
    /// etc.) aren't genres and shouldn't falsely pick up a bucket
    /// colour via substring match (e.g., "Special" wouldn't hit a
    /// bucket today but a future palette change shouldn't surprise
    /// us).
    var forceNeutral: Bool = false

    /// Resolved (color, opacity) pair. `nil` background → use the
    /// neutral-grey fallback handled below.
    private var fill: Color {
        if forceNeutral { return Color.textTertiary }
        if let hex = CategoryColor.customHex(for: rawToken) {
            return Color(hex: hex)
        }
        if let bucket = CategoryColor.bucket(for: rawToken) {
            return bucket.baseColor
        }
        return Color.textTertiary
    }

    /// Whether the palette actually matched this token. Used to dim
    /// the "unmatched" pills slightly so matched ones read as the
    /// visually-active state.
    private var isResolved: Bool {
        guard !forceNeutral else { return false }
        return CategoryColor.customHex(for: rawToken) != nil ||
               CategoryColor.bucket(for: rawToken) != nil
    }

    var body: some View {
        Text(rawToken)
            #if os(tvOS)
            .font(.system(size: 20, weight: .medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            #else
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            #endif
            .foregroundColor(isResolved ? .white : .textSecondary)
            .background(
                Capsule().fill(fill.opacity(isResolved ? 0.85 : 0.25))
            )
    }
}

// MARK: - CategoryPillsLayout
//
// A simple flow layout: children are laid out left-to-right, wrapping
// to a new line when the available width runs out. Used for the
// category pills since a typical program has 1–4 categories and a
// horizontal ScrollView would look out of place inside a Form row
// or a tvOS vertical stack.
//
// Uses the Swift 5.7+ `Layout` protocol. iOS 16+ / tvOS 16+ / macOS
// 13+ — well under Aerio's deployment floor.
private struct CategoryPillsLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var cursorX: CGFloat = 0
        var cursorY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var contentWidth: CGFloat = 0

        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if cursorX + size.width > maxWidth, cursorX > 0 {
                cursorY += lineHeight + spacing
                cursorX = 0
                lineHeight = 0
            }
            cursorX += size.width + spacing
            contentWidth = max(contentWidth, cursorX - spacing)
            lineHeight = max(lineHeight, size.height)
        }

        return CGSize(width: contentWidth, height: cursorY + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var cursorX = bounds.minX
        var cursorY = bounds.minY
        var lineHeight: CGFloat = 0

        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if cursorX + size.width > bounds.maxX, cursorX > bounds.minX {
                cursorY += lineHeight + spacing
                cursorX = bounds.minX
                lineHeight = 0
            }
            sub.place(
                at: CGPoint(x: cursorX, y: cursorY),
                proposal: ProposedViewSize(size)
            )
            cursorX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
