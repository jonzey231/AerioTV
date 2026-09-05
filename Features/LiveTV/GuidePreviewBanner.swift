import SwiftUI

#if os(tvOS)
// MARK: - Channel Preview banner

/// Live TV layout "Channel Preview" (Logan 2026-09-05): a banner above the
/// guide grid for the FOCUSED programme. Every line of text comes from the
/// `GuideProgram` the cell already holds, handed over synchronously on the
/// focus change, so the banner never waits on anything. Only the artwork
/// arrives later, fading in over the text; a miss leaves the slot empty.
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
    /// The corner mini player (410 wide, 40 from the trailing edge) sits
    /// over the banner's right end; the copy stops short of it.
    private var trailingReserve: CGFloat {
        nowPlaying.isActive && nowPlaying.isMinimized ? 422 : 0
    }

    static let height: CGFloat = 212

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
            leadingBlock
                .frame(width: 360)
            if let program {
                copy(for: program)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, trailingReserve)
            } else {
                Text("Select a program")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundColor(.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // 40pt each side: the logo sits as far from the left edge as the
        // mini does from the right (Logan 2026-09-05).
        .padding(.horizontal, 40)
        .padding(.bottom, 8)
        .frame(height: Self.height)
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
                AuthPosterImage(url: url, placeholder: .clear, maxPixel: 800)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 360, height: 203)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            case .none:
                // Every source came back empty (static team channels and the
                // like): the channel logo stands in (Logan 2026-09-05).
                if let channel, channel.logoURL != nil {
                    CachedLogoImage(url: channel.logoURL, width: 270, height: 152)
                        .frame(width: 360, height: 203)
                } else {
                    Color.clear.frame(width: 360, height: 203)
                }
            case .pending:
                // No placeholder while a lookup is open: the channel logo
                // flashed before every programme logo while stepping through
                // channels. Empty space keeps the copy from shifting.
                Color.clear.frame(width: 360, height: 203)
            }
        }
    }

    private func copy(for program: GuideProgram) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(program.title)
                    .font(.system(size: 36, weight: .bold))
                    .foregroundColor(.textPrimary)
                    .lineLimit(1)
                if let channel {
                    Text(channel.name)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(.accentPrimary)
                        .lineLimit(1)
                }
            }
            if let sub = program.subTitle,
               !EPGText.subtitleIsRedundant(sub, title: program.title, description: program.description) {
                Text(sub)
                    .font(.system(size: 22, weight: .medium))
                    .italic()
                    .foregroundColor(.textSecondary)
                    .lineLimit(1)
            }
            HStack(spacing: 10) {
                Text("\(shortTimeFormatter.string(from: program.start)) - \(shortTimeFormatter.string(from: program.end))")
                // Date-coded seasons ("S2026 E905") are not episode identity.
                if let se = seasonEpisodeLabel(season: program.season, episode: program.episode),
                   (program.season ?? 0) < 1900 {
                    Text("·").foregroundColor(.textTertiary)
                    Text(se)
                }
                if let left = remainingLabel(program) {
                    Text("·").foregroundColor(.textTertiary)
                    Text(left)
                }
                if showEpgBadges {
                    EPGFlagsRow(isLiveBroadcast: program.isLiveBroadcast, isNew: program.isNew,
                                isPremiere: program.isPremiere, isFinale: program.isFinale,
                                isRepeat: program.isRepeat, compact: false)
                }
            }
            .font(.system(size: 20, weight: .medium))
            .foregroundColor(.textSecondary)
            if !program.description.isEmpty {
                Button {
                    onSelectDescription?()
                } label: {
                    Text(program.description)
                        .font(.system(size: 23))
                        .foregroundColor(.textPrimary.opacity(0.85))
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
