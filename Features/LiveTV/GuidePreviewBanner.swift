import SwiftUI

#if os(tvOS)
// MARK: - Channel Preview banner

/// Live TV layout "Channel Preview" (Logan 2026-09-05): a banner above the
/// guide grid for the FOCUSED programme. Every line of text comes from the
/// `GuideProgram` the cell already holds, handed over synchronously on the
/// focus change, so the banner never waits on anything. Only the artwork
/// arrives later, fading in over the text; a miss leaves the slot empty.
/// Focused-programme state for the Channel Preview banner, lifted OUT of both
/// EPGGuideView's and ChannelListView's `@State` (Logan 2026-09-12 lag hunt).
///
/// Before: every focus move wrote `previewProgram` on EPGGuideView, which
/// re-evaluated the whole grid, and then forwarded the same value to
/// ChannelListView's `@State`, which re-evaluated ChannelListView AND the grid
/// inside it a second time. session11 measured that as 7 rows and 24 cells
/// re-evaluated 11 times per second while holding Down, with CADisplayLink
/// frames of 852 to 2035 ms. The banner is the only view that needs the
/// programme, so only the banner observes it now.
@MainActor
final class GuidePreviewState: ObservableObject {
    static let shared = GuidePreviewState()
    @Published private(set) var program: GuideProgram?
    @Published private(set) var channel: ChannelDisplayItem?
    /// Flips at most once per guide session (nothing focused -> something
    /// focused). The host's layout gate observes ONLY this, so a focus move
    /// between two programmes no longer re-renders the host.
    @Published private(set) var hasProgram = false

    /// Equal-value writes still notify every observer (memory:
    /// feedback_published_write_on_equal_value), so each field is guarded.
    func set(_ p: GuideProgram?, _ c: ChannelDisplayItem?) {
        if program?.id != p?.id { program = p }
        if channel?.id != c?.id { channel = c }
        if hasProgram != (p != nil) { hasProgram = (p != nil) }
    }
}

/// Thin observer so the banner re-renders on a focus move and its host does
/// not.
struct GuidePreviewBannerHost: View {
    @ObservedObject private var state = GuidePreviewState.shared
    let shortTimeFormatter: DateFormatter
    var onSelectDescription: (() -> Void)? = nil
    var onDescriptionFocusChange: ((Bool) -> Void)? = nil
    var focusRequest: Binding<Bool> = .constant(false)

    var body: some View {
        GuidePreviewBanner(program: state.program, channel: state.channel,
                           shortTimeFormatter: shortTimeFormatter,
                           onSelectDescription: onSelectDescription,
                           onDescriptionFocusChange: onDescriptionFocusChange,
                           focusRequest: focusRequest)
    }
}

/// Absolute (global-space) bottom edge of the banner's art slot.
///
/// The corner mini player's bottom edge is locked to it (Streamer parity).
/// It used to be a constant top padding that happened to line up with the
/// old fixed 360x203 art frame; since the slot takes its width from the
/// loaded image (b2fc738) and the banner itself shifts with the remote hint
/// strip and the tab bar, that constant no longer tracked anything. The slot
/// publishes its real bottom here and HomeView's tvOS mini positions itself
/// off it, so the two stay locked for landscape and portrait art and across
/// a resize after the image lands.
@MainActor
final class GuidePreviewArtAnchor: ObservableObject {
    static let shared = GuidePreviewArtAnchor()
    /// 0 means "not measured" (banner not on screen): the mini falls back to
    /// its old constant inset.
    @Published var bottomAbs: CGFloat = 0
    /// Banner instance that last reported. A clear from any other instance
    /// is ignored: a remounted banner reports before the old one's
    /// onDisappear lands, and that late clear used to zero the anchor for
    /// good (onGeometryChange only fires again when the value changes).
    private var owner: UUID?

    func report(_ value: CGFloat, owner id: UUID) {
        owner = id
        guard value > 0 else { return }
        // Equal-value writes still notify every observer (memory:
        // feedback_published_write_on_equal_value).
        let v = value.rounded()
        if bottomAbs != v { bottomAbs = v; debugLog("[ART-ANCHOR] report bottom=\(v)") }
    }

    func clear(owner id: UUID) {
        guard owner == id else { return }
        owner = nil
        if bottomAbs != 0 { bottomAbs = 0; debugLog("[ART-ANCHOR] cleared") }
    }

    /// The banner layout itself is gone (Live TV layout switched off
    /// "preview", or Live TV shown without a banner), so the mini must drop
    /// to its non-banner placement. The banner's own onDisappear no longer
    /// clears: a tab switch or rebuild only takes it off screen, and the mini
    /// keeps its vertical position while stashed on Settings.
    func clearLayoutGone() {
        owner = nil
        if bottomAbs != 0 { bottomAbs = 0; debugLog("[ART-ANCHOR] cleared (banner layout off)") }
    }
}

struct GuidePreviewBanner: View {
    let program: GuideProgram?
    let channel: ChannelDisplayItem?
    let shortTimeFormatter: DateFormatter
    /// Click on the description opens Program Info (Logan 2026-09-05).
    var onSelectDescription: (() -> Void)? = nil
    /// Focus on the description, for the host's Down-to-first-pill redirect.
    var onDescriptionFocusChange: ((Bool) -> Void)? = nil
    /// Host sets true to put focus on the description; reset here.
    var focusRequest: Binding<Bool> = .constant(false)

    @FocusState private var descriptionFocused: Bool
    @ObservedObject private var artCache = GuidePreviewArtCache.shared
    @EnvironmentObject private var nowPlaying: NowPlayingManager
    @AppStorage(epgBadgesVisibleKey) private var showEpgBadges = true
    /// Identity for GuidePreviewArtAnchor ownership.
    @State private var anchorOwner = UUID()
    /// Last measured art bottom, re-published on appear: the anchor may have
    /// been cleared (layout toggled off and back on) while the geometry is
    /// unchanged, so onGeometryChange never fires again.
    @State private var lastArtBottom: CGFloat = 0
    /// The corner mini player (410 wide, 40 from the trailing edge) sits
    /// over the banner's right end; the copy stops short of it.
    private var trailingReserve: CGFloat {
        nowPlaying.isActive && nowPlaying.isMinimized ? 422 : 0
    }

    static let height: CGFloat = 212
    @Environment(\.aerioTextScale) private var textScale
    @Environment(\.aerioSubtextScale) private var subtextScale

    /// Art slot at the current Text Size (same scale ProgramArtSlot applies
    /// to itself); the banner's own height has to clear it.
    private var artSlot: ProgramArtSlotMetrics {
        ProgramArtSlotMetrics.slot.scaled(textScale)
    }

    /// Banner height: the copy's mixed text growth, but never less than the
    /// art plus the 8pt bottom padding (plus 1pt for the rounding the
    /// designed 203 + 8 vs 212 already carried), so large Text Size cannot
    /// clip the art or push it under the guide.
    private var bannerHeight: CGFloat {
        max(TextScale.growMixed(Self.height, textScale, subtext: subtextScale),
            artSlot.height + 9)
    }

    var body: some View {
        // Bottom-aligned: logo, copy and the corner mini share one baseline
        // (Logan 2026-09-05).
        // 44 between logo and copy: the copy's focus frame must not overlap
        // the nav circles above (a 1pt overlap made Up from the description
        // pick Search over the Live TV pill, trace 2026-09-05 13:09).
        HStack(alignment: .bottom, spacing: 44) {
            // Programme art where the channel logo used to be (Logan
            // 2026-09-05); the channel name stays underneath, the logo is
            // the fallback until art lands or when there is none.
            // No fixed width: portrait art narrows its own slot (see
            // GuidePreviewArtSlot) and the copy takes the freed width.
            leadingBlock
                // The mini player's bottom edge rides this (see
                // GuidePreviewArtAnchor); the reading is live, so a slot
                // that resizes when the image lands moves the mini too.
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { maxY in
                    lastArtBottom = maxY
                    GuidePreviewArtAnchor.shared.report(maxY, owner: anchorOwner)
                }
                .onAppear {
                    GuidePreviewArtAnchor.shared.report(lastArtBottom, owner: anchorOwner)
                }
            if let program {
                copy(for: program)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, trailingReserve)
            } else {
                Text("Select a program")
                    .scaledFont(.system(size: 26, weight: .medium).subtext())
                    .foregroundColor(Color.contrastText(.textTertiary))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // 40pt each side: the logo sits as far from the left edge as the
        // mini does from the right (Logan 2026-09-05).
        .padding(.horizontal, 40)
        .padding(.bottom, 8)
        // Grows with Settings > Appearance > Text Size so the copy is not clipped.
        .frame(height: bannerHeight)
        .frame(maxWidth: .infinity)
        .background(Color.appBackground)
        .clipped()
        // Consumed here, not on the description button: a programme with no
        // description would otherwise leave the host's flag latched true.
        .onChange(of: focusRequest.wrappedValue) { _, wanted in
            guard wanted else { return }
            focusRequest.wrappedValue = false
            guard let program, !program.description.isEmpty else { return }
            // A beat: written in the same pass as the requesting catcher
            // taking focus, the write was dropped.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                descriptionFocused = true
            }
        }
    }

    private var leadingBlock: some View {
        VStack(spacing: 8) {
            switch program.map(artCache.state(for:)) ?? .pending {
            case .art(let url):
                // Shared slot: height-locked, width from the art's own
                // aspect, same as the Program Info sheet (Logan 2026-09-15).
                // The banner is a flat full-width strip on the app
                // background, not a rounded card, so per the container rule
                // (Logan 2026-09-16) its art stays square.
                ProgramArtSlot(url: url, containerRadius: 0)
                    .id(url)
            case .none:
                // Every source came back empty (static team channels and the
                // like): the channel logo stands in (Logan 2026-09-05).
                if let channel, channel.logoURL != nil {
                    CachedLogoImage(url: channel.logoURL,
                                    width: TextScale.grow(270, textScale),
                                    height: TextScale.grow(152, textScale))
                        .frame(width: artSlot.maxWidth, height: artSlot.height)
                } else {
                    ProgramArtSlot(url: nil, containerRadius: 0)
                }
            case .pending:
                // No placeholder while a lookup is open: the channel logo
                // flashed before every programme logo while stepping through
                // channels. Empty space keeps the copy from shifting.
                ProgramArtSlot(url: nil, containerRadius: 0)
            }
        }
    }

    private func copy(for program: GuideProgram) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(program.title)
                    .scaledFont(.system(size: 36, weight: .bold))
                    .foregroundColor(.textPrimary)
                    .lineLimit(1)
                if let channel {
                    Text(channel.name)
                        .scaledFont(.system(size: 22, weight: .semibold))
                        .foregroundColor(Color.contrastText(.accentPrimary))
                        .lineLimit(1)
                }
            }
            if let sub = program.subTitle,
               !EPGText.subtitleIsRedundant(sub, title: program.title, description: program.description) {
                Text(sub)
                    .scaledFont(.system(size: 22, weight: .medium).subtext())
                    .italic()
                    .foregroundColor(Color.contrastText(.textSecondary))
                    .lineLimit(1)
            }
            HStack(spacing: 10) {
                Text("\(shortTimeFormatter.string(from: program.start)) - \(shortTimeFormatter.string(from: program.end))")
                // Date-coded seasons ("S2026 E905") are not episode identity.
                if let se = seasonEpisodeLabel(season: program.season, episode: program.episode),
                   (program.season ?? 0) < 1900 {
                    Text("·").foregroundColor(Color.contrastText(.textTertiary))
                    Text(se)
                }
                if let left = remainingLabel(program) {
                    Text("·").foregroundColor(Color.contrastText(.textTertiary))
                    Text(left)
                }
                if showEpgBadges {
                    EPGFlagsRow(isLiveBroadcast: program.isLiveBroadcast, isNew: program.isNew,
                                isPremiere: program.isPremiere, isFinale: program.isFinale,
                                isRepeat: program.isRepeat, compact: false)
                }
            }
            .scaledFont(.system(size: 20, weight: .medium).subtext())
            .foregroundColor(Color.contrastText(.textSecondary))
            if !program.description.isEmpty {
                Button {
                    onSelectDescription?()
                } label: {
                    Text(program.description)
                        .scaledFont(.system(size: 23).subtext())
                        .foregroundColor(Color.contrastText(.textPrimary.opacity(0.85)))
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(BannerTextButtonStyle())
                .focused($descriptionFocused)
                .onChange(of: descriptionFocused) { _, f in onDescriptionFocusChange?(f) }
            }
        }
    }

    private func remainingLabel(_ p: GuideProgram) -> String? {
        let now = Date()
        guard p.start <= now, now < p.end else { return nil }
        let left = max(1, Int(p.end.timeIntervalSince(now) / 60))
        return left >= 60 ? "\(left / 60) h \(left % 60) min left" : "\(left) min left"
    }
}

/// Focusable description: a faint platter on focus, no system halo, no
/// scale (the banner must not move while stepping channels).
private struct BannerTextButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused
    func makeBody(configuration: Configuration) -> some View {
        // Tight vertical inset: a 12pt platter spilled over the time row
        // above and the pills below (Logan 2026-09-05).
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isFocused ? Color.white.opacity(0.08) : Color.clear)
            )
            .padding(.horizontal, -12)
            .padding(.vertical, -4)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

// MARK: - Art cache

/// TMDB landscape art per programme title, in memory for the session. A
/// title is looked up once; until it lands (or misses) the banner shows no
/// art. Nothing here ever blocks the banner's text.
@MainActor
final class GuidePreviewArtCache: ObservableObject {
    static let shared = GuidePreviewArtCache()
    @Published private(set) var version = 0
    private var entries: [String: URL?] = [:]
    private var inFlight: Set<String> = []

    enum ArtState: Equatable {
        case art(URL)
        /// A lookup is still open: draw nothing.
        case pending
        /// Every source answered and none had art: draw the channel logo.
        case none
    }

    /// Feed art first (instant), then the Dispatcharr programme detail
    /// (the icon Program Info shows; the bulk grid strips it), then TMDB.
    func state(for program: GuideProgram) -> ArtState {
        state(title: program.title, category: program.category,
              programID: program.programID, posterURL: program.posterURL)
    }

    /// Same order for callers without a GuideProgram (the Record sheet).
    func state(title: String, category: String, programID: Int?, posterURL: String? = nil) -> ArtState {
        if let raw = posterURL, let u = URL(string: raw), u.scheme != nil { return .art(u) }
        if let pid = programID {
            switch detailEntries[pid] {
            case .some(.some(let u)): return .art(u)
            case .some(.none): break          // detail had no icon: fall through to TMDB
            case .none:
                // Only a lookup that actually started is worth waiting for;
                // no Dispatcharr server means the miss is known right now.
                if fetchDetail(pid: pid, title: title) { return .pending }
            }
        }
        let key = LibraryMatcher.cleanTitle(title)
        guard TMDBPosters.isEnabled, !key.isEmpty else { return .none }
        if let cached = entries[key] { return cached.map(ArtState.art) ?? .none }
        if let failedAt = failedAt[key], Date().timeIntervalSince(failedAt) < Self.retryAfter { return .none }
        _ = url(title: title, category: category)
        return .pending
    }

    private var detailEntries: [Int: URL?] = [:]
    private var detailInFlight: Set<Int> = []

    /// Returns true when a lookup is open for `pid` (started now or earlier).
    @discardableResult
    private func fetchDetail(pid: Int, title: String) -> Bool {
        if detailInFlight.contains(pid) { return true }
        guard let server = ChannelStore.shared.activeServer, server.type == .dispatcharrAPI else {
            detailEntries[pid] = .some(nil)
            return false
        }
        detailInFlight.insert(pid)
        let baseURL = server.effectiveBaseURL
        let api = DispatcharrAPI(baseURL: baseURL,
                                 auth: .apiKey(server.effectiveApiKey),
                                 userAgent: server.effectiveUserAgent,
                                 authMode: server.dispatcharrHeaderMode,
                                 serverID: server.id,
                                 savedUsername: server.dispatcharrCredentialType == .usernamePassword
                                     ? server.username : nil)
        Task { @MainActor in
            var found: URL? = nil
            if let detail = try? await api.getProgramDetail(id: pid), let raw = detail.bestPosterString {
                found = VODService.resolveImageURL(raw, base: baseURL, size: "w780")
            }
            detailEntries[pid] = .some(found)
            detailInFlight.remove(pid)
            debugLog("[PREVIEW-ART] \(title): Dispatcharr detail \(found == nil ? "no icon" : "icon")")
            version += 1
        }
        return true
    }

    /// Failed TMDB lookups (transport, 429) by title: retried after a pause
    /// rather than on the very next render, which the failure's own
    /// `version` bump would otherwise trigger in a loop.
    private var failedAt: [String: Date] = [:]
    private static let retryAfter: TimeInterval = 60

    func url(title: String, category: String) -> URL? {
        let key = LibraryMatcher.cleanTitle(title)
        guard !key.isEmpty else { return nil }
        if let cached = entries[key] { return cached }
        guard TMDBPosters.isEnabled, let apiKey = TMDBPosters.apiKey, !inFlight.contains(key) else { return nil }
        inFlight.insert(key)
        let isMovie = category.lowercased().contains("movie") || category.lowercased().contains("film")
        Task { @MainActor in
            let entry = await TMDBService.lookupArt(title: title, isMovie: isMovie, apiKey: apiKey)
            var found: URL? = nil
            if let b = entry?.backdrop, !b.isEmpty { found = TMDBService.imageURL(path: b, size: "w780") }
            else if let p = entry?.poster, !p.isEmpty { found = TMDBService.imageURL(path: p, size: "w500") }
            if entry == nil {
                // Transport failure or 429: not pinned as a miss for the
                // session, but not retried for a minute either.
                failedAt[key] = Date()
                debugLog("[PREVIEW-ART] \(title): lookup failed (retry in \(Int(Self.retryAfter)) s)")
            } else {
                failedAt[key] = nil
                entries[key] = found
                debugLog("[PREVIEW-ART] \(title): \(found == nil ? "no art on TMDB" : "art") id=\(entry?.tmdbID ?? "")")
            }
            inFlight.remove(key)
            version += 1
        }
        return nil
    }
}
#endif

/// Portrait cutoff for the Movies hero art. The Live TV banner no longer
/// uses it: its art goes through the fit-to-box ProgramArtSlot below.
enum GuidePreviewPortraitArt {
    /// Width/height below which art counts as a portrait poster. Near-square
    /// art (sports matchup logos ~0.96) keeps the full cropped 16:9 slot.
    static let maxAspect: CGFloat = 0.8
}

/// ONE definition of the program-art slot, shared by the Live TV guide
/// preview banner (tvOS hero) and the Program Info sheet (long press, all
/// platforms).
///
/// Logan 2026-09-15 (rev 2): art KEEPS ITS OWN SHAPE. The earlier fixed box
/// was rejected: a 2:3 poster shrank to fit a landscape box (and a square one
/// on iOS), so posters read tiny next to landscape title cards. The slot is
/// now HEIGHT-LOCKED and the width follows the image aspect, so landscape art
/// renders landscape, portrait renders portrait, at the same height on both
/// surfaces. Nothing is cropped, nothing is letterboxed: the drawn box IS the
/// image shape, so the surrounding surface simply shows through.
///
/// Width is clamped to a 16:9 maximum so an ultra-wide banner cannot push the
/// copy out, and to a minimum so a freak sliver of art still reads. The 16:9
/// maximum is also what the slot RESERVES before the aspect is known, so the
/// slot never collapses and the copy column does not jump; AuthPosterImage
/// reports the decoded size (synchronously on a cache hit, so revisits do not
/// pop at all), and only then does the width settle. Height never changes, so
/// GuidePreviewArtAnchor's maxY, and the corner mini player riding it, are
/// stable throughout.
///
/// This supersedes both the fill-and-crop slot with its portrait escape hatch
/// (GuidePreviewPortraitArt.maxAspect, still used by the Movies hero) and the
/// fit-inside-a-fixed-box slot.
struct ProgramArtSlotMetrics {
    /// Locked height: the two surfaces match because they share this.
    let height: CGFloat
    /// 16:9 width, also the pre-load reservation.
    let maxWidth: CGFloat
    /// Floor for very tall art.
    let minWidth: CGFloat
    let cornerRadius: CGFloat

    init(height: CGFloat, cornerRadius: CGFloat) {
        self.height = height.rounded()
        self.maxWidth = (height * 16.0 / 9.0).rounded()
        self.minWidth = (height * 0.5).rounded()
        self.cornerRadius = cornerRadius
    }

    /// The same slot at the app-wide Text Size (Settings > Appearance).
    /// Logan 2026-09-15: the shipped sizes stay the DEFAULT, and users who
    /// want larger art raise Text Size, so the slot rides the SAME scale the
    /// type does. `TextScale.grow` is the app's one metric multiplier, so
    /// art only ever grows (85% text keeps the designed layout) and there is
    /// no second setting or duplicated factor. maxWidth and minWidth follow
    /// from the height, so true aspect and the portrait floor are preserved.
    func scaled(_ scale: CGFloat) -> ProgramArtSlotMetrics {
        guard scale > 1 else { return self }
        return ProgramArtSlotMetrics(height: TextScale.grow(height, scale),
                                     cornerRadius: TextScale.grow(cornerRadius, scale))
    }

    /// Width for a given width/height aspect, clamped.
    func width(for aspect: CGFloat?) -> CGFloat {
        guard let aspect, aspect.isFinite, aspect > 0 else { return maxWidth }
        return min(maxWidth, max(minWidth, (height * aspect).rounded()))
    }

    #if os(tvOS)
    /// The banner's long-standing 203pt art height (the banner is 212 tall);
    /// 16:9 caps the width at 361, near the old 360 box.
    static let slot = ProgramArtSlotMetrics(height: 203, cornerRadius: 12)
    #else
    /// Phone/iPad sheet.
    static let slot = ProgramArtSlotMetrics(height: 130, cornerRadius: 10)
    /// The compact phone card, where the art sits beside the copy in a row.
    static let compactSlot = ProgramArtSlotMetrics(height: 104, cornerRadius: 10)
    #endif
}

/// Height-locked, aspect-shaped program artwork. Reserves the 16:9 width even
/// when there is no art, so nothing shifts.
struct ProgramArtSlot: View {
    let url: URL?
    var headers: [String: String] = [:]
    var metrics: ProgramArtSlotMetrics = ProgramArtSlotMetrics.slot
    var maxPixel: CGFloat = 800
    /// Corner radius of the CARD this art sits in. Honored when Settings >
    /// Appearance > "Rounded corners on logos and artwork" is on, zeroed
    /// when it is off. Defaults to the slot's own designed radius so a
    /// caller inside a card of the same shape needs no argument; pass 0 for
    /// a container with no rounding (the tvOS guide preview strip). See
    /// `LogoCorners`.
    var containerRadius: CGFloat? = nil
    /// Kept for callers that want the real bitmap size; the slot uses it
    /// itself to settle its width.
    var onImageLoaded: ((CGSize) -> Void)? = nil

    /// nil until the bitmap reports its size: width stays at the 16:9 reserve.
    @State private var aspect: CGFloat? = nil
    /// App-wide Text Size: the slot grows with it (see `scaled(_:)`).
    @Environment(\.aerioTextScale) private var textScale
    /// Settings > Appearance > "Rounded corners on logos and artwork".
    @Environment(\.aerioRoundedLogoCorners) private var roundedCorners

    /// The slot's metrics at the current Text Size. Every frame below uses
    /// these, so height, 16:9 reserve and portrait floor scale together.
    private var m: ProgramArtSlotMetrics { metrics.scaled(textScale) }

    private var width: CGFloat { m.width(for: url == nil ? nil : aspect) }

    /// The radius actually drawn: the container's (Text-Size-scaled like the
    /// rest of the slot when it falls back to the slot's own), or 0 when the
    /// Appearance toggle is off.
    private var cornerRadius: CGFloat {
        // The slot already sizes itself to the art's true aspect, so its own
        // box IS the art's bounds; the cap still guards very short art.
        LogoCorners.radius(container: containerRadius ?? m.cornerRadius,
                           imageShorterSide: min(width, m.height),
                           // The slot draws through AuthPosterImage and never
                           // sees the bitmap, so it reads the shared verdict
                           // cache; unknown program art counts as a tile,
                           // since it is opaque photography.
                           isTile: LogoTileTest.cachedVerdict(for: url) ?? true,
                           enabled: roundedCorners)
    }

    var body: some View {
        Color.clear
            .frame(width: width, height: m.height)
            .overlay {
                if let url {
                    AuthPosterImage(url: url,
                                    headers: headers,
                                    onImageLoaded: { size in
                                        if size.width > 0, size.height > 0 {
                                            let a = size.width / size.height
                                            if aspect != a { aspect = a }
                                        }
                                        onImageLoaded?(size)
                                    },
                                    placeholder: .clear,
                                    maxPixel: maxPixel)
                        // FIT, never fill: aspect preserved, nothing cropped.
                        // Once the aspect is known the box already matches it,
                        // so there is nothing left over to letterbox.
                        .aspectRatio(contentMode: .fit)
                        .frame(width: width, height: m.height)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius,
                                                    style: .continuous))
                        .id(url)
                }
            }
            .clipped()
            // A new image re-reserves rather than keeping the old shape.
            .onChange(of: url) { _, _ in aspect = nil }
    }
}
