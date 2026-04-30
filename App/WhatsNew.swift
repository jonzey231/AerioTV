import SwiftUI

// MARK: - Release-notes data
//
// One curated entry per release that should surface a What's New
// pop-up. Entries are kept indefinitely so a user upgrading from an
// older version directly to a newer one (e.g. 1.6.10 → 1.6.13) still
// sees the latest highlights — the matching rule is "current bundle
// version has an entry **and** the user hasn't already seen this
// version's prompt." Older versions just sit dormant in the array.
//
// Keep bullets short — under ~60 chars each — so the sheet stays
// glanceable on iPhone and readable from a couch on Apple TV.

/// Per-version release-notes record consumed by `WhatsNewStore`.
struct WhatsNewRelease {
    /// `CFBundleShortVersionString` value this entry targets, e.g. "1.6.12".
    let version: String

    /// Headline shown at the top of the sheet (e.g. "What's new in 1.6.12").
    let title: String

    /// Bullet list — keep each line short (under ~60 chars).
    let bullets: [String]

    /// Tap target on the "Read full release notes" link. `nil` hides the link.
    let releaseURL: URL?
}

// MARK: - Store
//
// Persistence + decision logic for the What's New pop-up. Two
// UserDefaults keys back the behavior:
//
// - `whatsNew.lastSeenVersion` — the version string the user last
//   acknowledged (or that we silently set on a fresh install). The
//   pop-up surfaces only when the **current** version doesn't match
//   this value.
// - `whatsNew.permanentlyDisabled` — opt-out flag. Once set, the
//   pop-up never appears again on this device, regardless of
//   subsequent updates. Stored locally; not synced to iCloud, since
//   this is a per-device UI preference and a user might want it
//   different on iPad vs Apple TV.
//
// The first-launch case (`lastSeenVersion == nil`) is treated as a
// fresh install: we set the marker silently and skip the prompt, so
// new users don't see a "what's new" sheet for a release they never
// experienced an "old" version of.

enum WhatsNewStore {
    private static let lastSeenKey = "whatsNew.lastSeenVersion"
    private static let disabledKey = "whatsNew.permanentlyDisabled"

    /// Curated list of release-notes entries. Append a new entry per
    /// release that warrants surfacing — keep older entries so that
    /// users who skipped a few versions still get the latest one's
    /// summary on their next launch.
    static let releases: [WhatsNewRelease] = [
        WhatsNewRelease(
            version: "1.6.18",
            title: "What's new in 1.6.18",
            bullets: [
                "Swipe up or down to change channels on iPhone and iPad — tap the player to show the chrome, then swipe to flip through live channels (mirrors the Apple TV Siri Remote up/down channel-flip)",
                "Stream Info now shows live server-side stats from your Dispatcharr server when available (Dispatcharr API playlists only) — resolution, FPS, codec, output bitrate, and viewer count. Plain M3U / Xtream playlists still get the same five fields from the local player",
                "Apple TV: returning to the guide after watching a channel now focuses on that channel's row — no more random scrolling to the top",
                "iPhone portrait: Close / Options / Add buttons now hug the Dynamic Island instead of sitting too far below it — fixes a positioning regression introduced by the v1.6.17 multiview safe-area work",
                "Channel info banner no longer covers the Stream Info card on iPhone — banner hides itself while Stream Info is open, then comes back when you close it",
                "iPhone landscape: channel info banner now sits to the right of the Close button instead of below it (matching iPad), reclaiming the vertical room",
                "Live channel audio no longer keeps playing underneath when you start a recording or open a movie / TV episode — the live stream now stops cleanly the moment the new playback begins",
                "Live TV List view on iPhone no longer jitters up and down when you scroll to the spot where the group filter pills snap out of view"
            ],
            releaseURL: URL(string: "https://github.com/jonzey231/AerioTV/releases/tag/v1.6.18")
        ),
        WhatsNewRelease(
            version: "1.6.17",
            title: "What's new in 1.6.17",
            bullets: [
                "Multiview no longer leaves video tiles black after switching apps with 9 streams active — every tile now resumes cleanly when you return",
                "On Demand tab now reliably shows your movies and TV shows on a wider range of Dispatcharr server configurations — fixed both the per-playlist VOD-toggle relaunch bug AND a stricter-Dispatcharr-build category-filter bug that was leaving the tab empty (Dispatcharr API playlists only)",
                "New Sync Categories sub-page in Settings → iCloud Sync lets you opt out of syncing specific data types — Playlists, Watch Progress, Reminders, App Preferences, or Credentials — with a per-category Delete option that scrubs only that data from iCloud",
                "Reorder your Playlists in Settings: drag-to-reorder on iPhone/iPad (tap Edit), Move Up/Move Down via long-press on Apple TV. Order syncs across all your devices via iCloud",
                "Multiview on iPhone now respects the notch and Dynamic Island — video tiles stay inside the safe area instead of sliding behind the cutout"
            ],
            releaseURL: URL(string: "https://github.com/jonzey231/AerioTV/releases/tag/v1.6.17")
        ),
        WhatsNewRelease(
            version: "1.6.16",
            title: "What's new in 1.6.16",
            bullets: [
                "Apple TV: opening Options right after channel-flipping no longer freezes the UI",
                "Stream Info overlay redesigned: bottom-left on Apple TV, clears the Dynamic Island on iPhone, with a close button on iPad/iPhone",
                "Channel info banner now correctly clears the player's close button on iPad and iPhone, and stays hidden when the player is minimized",
                "VOD series episodes now load reliably on the first open — no more back-out-and-reopen workaround (Dispatcharr API playlists only)",
                "Episode rows now show artwork, duration, air date, and TMDB rating (Dispatcharr API playlists only)",
                "Movies and series open instantly on second visit"
            ],
            releaseURL: URL(string: "https://github.com/jonzey231/AerioTV/releases/tag/v1.6.16")
        ),
        WhatsNewRelease(
            version: "1.6.15",
            title: "What's new in 1.6.15",
            bullets: [
                "Apple TV: Up/Down on Siri Remote changes channels",
                "New channel info banner shows logo, number, name, program, and airing time on every stream start",
                "On Apple TV, press Menu/Back to lock the channel and reach Options, Record, and Add Stream"
            ],
            releaseURL: URL(string: "https://github.com/jonzey231/AerioTV/releases/tag/v1.6.15")
        ),
        WhatsNewRelease(
            version: "1.6.14",
            title: "What's new in 1.6.14",
            bullets: [
                "Record Program pop-up updated for clarity",
                "Text added to clarify comskip is only available via Dispatcharr API playlist and only when recording to Dispatcharr server",
            ],
            releaseURL: URL(string: "https://github.com/jonzey231/AerioTV/releases/tag/v1.6.14")
        ),
        WhatsNewRelease(
            version: "1.6.13",
            title: "What's new in 1.6.13",
            bullets: [
                "Added 'Skip Loading Screen' toggle in Settings > Appearance > App Behaviors",
                "Added 'Resume Last Channel' toggle in Settings > Appearance > App Behaviors",
                "Persistent search field has been changed to a button on iPad in Guide view to reduce wasted space",
                "Pinch-to-zoom-out has been added to iPad. This shrinks the currently playing channel to a miniplayer",
                "When present, the miniplayer no longer covers channel group names",
                "Significantly reduced app launch time by better utilizing existing persistent cache"
            ],
            releaseURL: URL(string: "https://github.com/jonzey231/AerioTV/releases/tag/v1.6.13")
        )
    ]

    /// Bundle's `CFBundleShortVersionString`, falling back to "0" so
    /// the comparison against `lastSeen` is well-defined even on a
    /// hypothetically broken Info.plist.
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Release-notes entry matching `currentVersion`, or `nil` when
    /// the running build doesn't ship a What's New blurb (release
    /// versions without a curated bullet list silently skip the
    /// prompt).
    static var currentRelease: WhatsNewRelease? {
        releases.first { $0.version == currentVersion }
    }

    /// Whether the user has permanently opted out.
    static var isPermanentlyDisabled: Bool {
        UserDefaults.standard.bool(forKey: disabledKey)
    }

    /// True when launch should pop the What's New sheet:
    /// 1. The user hasn't permanently disabled the prompt.
    /// 2. We have a release-notes entry for the current version.
    /// 3. The user hasn't already seen this version's prompt.
    /// 4. **Either** there's a recorded `lastSeenVersion` (so we know
    ///    this device has been running Aerio before), **or** the
    ///    caller has passed `isExistingUser: true` — meaning the
    ///    user has servers / completed onboarding from a prior
    ///    version, even though this is the first launch since we
    ///    started tracking `lastSeenVersion` (which itself only
    ///    came in with v1.6.12).
    ///
    /// The 4th gate is what distinguishes a genuine fresh install
    /// (no servers, no onboarding, no recorded version → silently
    /// initialise the marker, don't show notes for a release the
    /// user never lived through) from a v1.6.11 → v1.6.12 upgrade
    /// (no recorded marker because the marker didn't exist in
    /// v1.6.11, but the user has servers → show the notes).
    ///
    /// `isExistingUser` should be `true` when the device has any
    /// pre-existing app state that proves Aerio ran here before
    /// — the simplest signal is "any servers configured **or**
    /// onboarding flag is set."
    static func shouldShow(isExistingUser: Bool) -> Bool {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: disabledKey) else { return false }
        guard let release = currentRelease else { return false }
        if let lastSeen = defaults.string(forKey: lastSeenKey) {
            return lastSeen != release.version
        }
        // No recorded marker. Distinguish fresh install vs upgrade.
        if isExistingUser {
            // Upgraded from a pre-tracking version. Show the prompt
            // — caller will mark seen on dismiss.
            return true
        }
        // Genuine fresh install. Set the marker silently so future
        // updates surface notes against this baseline, and skip.
        defaults.set(release.version, forKey: lastSeenKey)
        return false
    }

    /// User dismissed via "Dismiss". Mark the **current** version as
    /// seen so the prompt won't reappear until a *new* version with
    /// curated notes ships. The next update's notes will still
    /// surface — `Dismiss` is per-version, not permanent.
    static func markSeen() {
        guard let v = currentRelease?.version else { return }
        UserDefaults.standard.set(v, forKey: lastSeenKey)
    }

    /// User opted out via "Never show again". This is the **permanent
    /// opt-out** for *all* future updates on this device — the
    /// `disabledKey` flag becomes the first guard in `shouldShow`,
    /// so subsequent releases skip the sheet regardless of what
    /// version we're on. The user can only re-enable by uninstalling
    /// or by clearing the `whatsNew.permanentlyDisabled` UserDefault.
    ///
    /// We also stamp `lastSeenKey` with the current version so that
    /// if a future build ever exposes a "re-enable" toggle, the user
    /// won't be presented with notes for the version they already
    /// chose to ignore.
    static func disable() {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: disabledKey)
        if let v = currentRelease?.version {
            defaults.set(v, forKey: lastSeenKey)
        }
    }
}

// MARK: - Sheet view
//
// Compact modal presented over `MainTabView` on the first launch
// after an update. Two action paths:
// - Got it          → calls `WhatsNewStore.markSeen()` and dismisses.
//                     Re-appears next time a newer version lands.
// - Don't show again → calls `WhatsNewStore.disable()` and dismisses.
//                     Permanent opt-out for this device.
//
// On iOS the GitHub release link is a real `Link` (opens Safari).
// On tvOS there's no system browser, so we hide the link entirely
// rather than rendering a dead button — users on Apple TV can't act
// on a URL anyway, and showing one as plain text invites confusion.
//
// The view is intentionally small — no scroll, no images, no
// per-bullet emojis. The "additional splash screen" framing in the
// product spec means it should feel lighter than a settings page,
// closer to a system-level "Welcome to <new version>" alert.

struct WhatsNewSheet: View {
    let release: WhatsNewRelease
    let onDismiss: () -> Void
    let onPermanentlyDisable: () -> Void

    /// Driven by the parent's `.sheet(isPresented:)` — we still need
    /// to flip it to false from inside the buttons so the action
    /// callbacks fire and the modal closes in one tap.
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, headerTopPadding)

            bulletList
                .padding(.horizontal, contentHorizontalPadding)
                .padding(.top, 24)

            #if !os(tvOS)
            if let url = release.releaseURL {
                Link(destination: url) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.forward.app")
                        Text("Read full release notes")
                    }
                    .font(.subheadline.weight(.medium))
                }
                .padding(.top, 18)
            }
            #endif

            Spacer(minLength: 16)

            actionButtons
                .padding(.horizontal, contentHorizontalPadding)
                .padding(.bottom, bottomPadding)
        }
        #if os(tvOS)
        .frame(maxWidth: 900)
        .padding(.horizontal, 60)
        .padding(.vertical, 40)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        #else
        .frame(maxWidth: .infinity)
        .background(Color(.systemBackground))
        #endif
        .preferredColorScheme(.dark)
    }

    // MARK: Subviews

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(Color.accentPrimary)
            Text(release.title)
                .font(titleFont)
                .multilineTextAlignment(.center)
            Text("Aerio \(release.version)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, contentHorizontalPadding)
    }

    private var bulletList: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(release.bullets, id: \.self) { bullet in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentPrimary)
                        .font(bulletIconFont)
                    Text(bullet)
                        .font(bulletTextFont)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 10) {
            // Primary: per-version dismiss. Marks the current version
            // as seen; the next update's notes will still surface.
            Button {
                onDismiss()
                isPresented = false
            } label: {
                Text("Dismiss")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: primaryButtonHeight)
                    #if os(tvOS)
                    // Apply the cyan fill on the LABEL (not the
                    // outer Button) so `TVNoHighlightButtonStyle`'s
                    // focus cue (scale + brightness + accent shadow)
                    // composes cleanly. The default tvOS focus halo
                    // — a heavy white ring + bright surround —
                    // washed out the cyan fill and made "Dismiss"
                    // unreadable on focus. This matches the focus
                    // treatment used across the rest of the app's
                    // tvOS chrome (settings rows, transport bar
                    // buttons, group pills).
                    .background(Color.accentPrimary)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    #endif
            }
            #if os(tvOS)
            .buttonStyle(TVNoHighlightButtonStyle())
            #else
            .buttonStyle(.borderedProminent)
            #endif

            // Secondary: permanent opt-out for all future updates.
            // Sets `whatsNew.permanentlyDisabled` so `shouldShow`'s
            // first guard short-circuits forever on this device.
            Button {
                onPermanentlyDisable()
                isPresented = false
            } label: {
                Text("Never show again for any future updates.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            #if os(tvOS)
            // Same no-halo treatment as the primary — without it,
            // the OS overlays the bright white pill that triggered
            // the unreadable-button report. Scale + brightness from
            // `TVNoHighlightButtonStyle` is enough to indicate focus
            // on a text-only button.
            .buttonStyle(TVNoHighlightButtonStyle())
            #else
            .buttonStyle(.plain)
            #endif
        }
    }

    // MARK: Platform sizing

    private var iconSize: CGFloat {
        #if os(tvOS)
        return 56
        #else
        return 36
        #endif
    }

    private var titleFont: Font {
        #if os(tvOS)
        return .system(size: 38, weight: .bold)
        #else
        return .title2.bold()
        #endif
    }

    private var bulletIconFont: Font {
        #if os(tvOS)
        return .system(size: 24)
        #else
        return .body
        #endif
    }

    private var bulletTextFont: Font {
        #if os(tvOS)
        return .system(size: 24)
        #else
        return .body
        #endif
    }

    private var contentHorizontalPadding: CGFloat {
        #if os(tvOS)
        return 24
        #else
        return 28
        #endif
    }

    private var headerTopPadding: CGFloat {
        #if os(tvOS)
        return 24
        #else
        return 32
        #endif
    }

    private var bottomPadding: CGFloat {
        #if os(tvOS)
        return 24
        #else
        return 24
        #endif
    }

    private var primaryButtonHeight: CGFloat {
        #if os(tvOS)
        return 60
        #else
        return 44
        #endif
    }
}

// MARK: - Modifier
//
// Convenience `.whatsNewSheet()` wrapper that the root view applies
// once. Encapsulates the `currentRelease` lookup + `shouldShow()`
// gating + dismiss-callback wiring so the call site is a single
// modifier and not a 25-line `.sheet { ... }` block sitting in the
// middle of `RootView`.

extension View {
    /// Attach the What's New sheet. Reads `WhatsNewStore.shouldShow()`
    /// once on the binding's initial flip from false → true; the
    /// caller is responsible for setting that binding from its own
    /// `.onAppear` (gives the splash + onboarding flow priority).
    func whatsNewSheet(isPresented: Binding<Bool>) -> some View {
        modifier(WhatsNewSheetModifier(isPresented: isPresented))
    }
}

private struct WhatsNewSheetModifier: ViewModifier {
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        // Resolve the current release once. If there isn't one
        // (e.g. dev build before we curated this version's bullets),
        // the modifier becomes a no-op even if `isPresented` flips.
        let release = WhatsNewStore.currentRelease

        #if os(tvOS)
        // tvOS sheets are full-screen anyway; using `.fullScreenCover`
        // keeps the focus engine well-behaved (regular `.sheet` on
        // tvOS sometimes traps focus in unexpected places).
        return content.fullScreenCover(isPresented: $isPresented) {
            if let release {
                ZStack {
                    Color.black.opacity(0.85).ignoresSafeArea()
                    WhatsNewSheet(
                        release: release,
                        onDismiss: { WhatsNewStore.markSeen() },
                        onPermanentlyDisable: { WhatsNewStore.disable() },
                        isPresented: $isPresented
                    )
                }
            }
        }
        #else
        return content.sheet(isPresented: $isPresented) {
            if let release {
                WhatsNewSheet(
                    release: release,
                    onDismiss: { WhatsNewStore.markSeen() },
                    onPermanentlyDisable: { WhatsNewStore.disable() },
                    isPresented: $isPresented
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
        #endif
    }
}
