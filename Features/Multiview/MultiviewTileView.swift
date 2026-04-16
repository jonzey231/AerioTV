import SwiftUI
#if canImport(UIKit)
import UIKit
import UniformTypeIdentifiers
#endif

/// One tile in the multiview grid.
///
/// Responsibilities:
/// - Host an `MPVPlayerViewRepresentable` parameterised with the
///   tile's identity, audio-focus state, and pause state.
/// - Draw the focus ring + audio-active badge + channel label.
/// - Handle tap-to-take-audio.
/// - Handle long-press → `.confirmationDialog` with per-tile actions
///   (Remove / Make Audio / Full-Screen / Audio Track / Subtitle
///   Track / Move Tile — tvOS only).
/// - Surface decode errors via a red overlay with a Remove button.
/// - Act as a drag source + drop target on iPadOS for rearrange.
/// - Announce state to VoiceOver via `.accessibilityLabel`.
///
/// Non-responsibilities (container's job):
/// - Layout / positioning (handled by `MultiviewLayoutView`).
/// - tvOS relocate-mode D-pad remap (handled by
///   `MultiviewContainerView.onMoveCommand`).
/// - Add-sheet + exit wiring (handled by `MultiviewTransportBar`).
struct MultiviewTileView: View {
    let tile: MultiviewTile
    @ObservedObject var store: MultiviewStore

    /// A per-tile progress store. `@StateObject` so SwiftUI keeps it
    /// alive across tile re-renders and a new one is built for each
    /// new tile identity. Holds the tile's audio/subtitle track
    /// list, current mpv progress, and the `togglePauseAction`
    /// callback. Non-audio tiles still decode, so this store keeps
    /// tracking even while muted.
    @StateObject private var progressStore = PlayerProgressStore()

    /// Per-tile attempt log — mpv events, failover attempts. Purely
    /// diagnostic; nothing user-visible.
    @StateObject private var logStore = AttemptLogStore()

    /// tvOS focus state — MUST be `@State Bool` not `@FocusState`
    /// because we use `TVPressOverlay` (UIKit-backed) for long-press
    /// detection. See `Shared/TVPressGesture.swift:43-45`. The
    /// overlay binds this via the `isFocused` parameter.
    @State private var isFocused: Bool = false

    /// Whether the confirmation dialog (per-tile action menu) is
    /// currently showing. Set by the long-press callback.
    @State private var showMenu: Bool = false

    /// Non-nil when the underlying mpv coordinator reported a fatal
    /// decode error. Drives the red error overlay. Tapping "Remove"
    /// on the overlay calls `store.remove(id:)`, which takes the
    /// tile out of the grid entirely.
    @State private var decodeErrorMessage: String? = nil

    /// Stacked confirmation-dialog flags for the per-tile track
    /// sub-menus. SwiftUI doesn't support nested `.confirmationDialog`
    /// directly; the pattern is to tap a button in the main menu that
    /// dismisses it + sets one of these, which triggers a fresh
    /// dialog on the next render.
    @State private var showAudioTrackMenu: Bool = false
    @State private var showSubtitleTrackMenu: Bool = false

    var isAudioActive: Bool { store.audioTileID == tile.id }

    /// Computed: a non-audio tile should freeze itself if PiP is
    /// currently active (the audio tile is the PiP window's source
    /// and keeps decoding; everyone else pauses to save CPU + GPU +
    /// network).
    private var shouldPause: Bool {
        store.isPiPActive && !isAudioActive
    }

    var body: some View {
        tileContent
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(a11yLabel)
            .accessibilityAddTraits(.isButton)
            // `verbatim:` parity with the error overlay — channel
            // names are server-controlled and could contain Markdown
            // syntax. `confirmationDialog(_:isPresented:…)` with a
            // String parameter interprets LocalizedStringKey, which
            // includes Markdown on iOS 15+. Using the `Text`
            // overload with `verbatim:` bypasses interpretation.
            .confirmationDialog(
                Text(verbatim: tile.item.name),
                isPresented: $showMenu,
                titleVisibility: .visible
            ) {
                menuButtons
            }
            .confirmationDialog(
                "Audio Track",
                isPresented: $showAudioTrackMenu,
                titleVisibility: .visible
            ) {
                audioTrackButtons
            }
            .confirmationDialog(
                "Subtitle Track",
                isPresented: $showSubtitleTrackMenu,
                titleVisibility: .visible
            ) {
                subtitleTrackButtons
            }
            #if os(tvOS)
            // tvOS relocate-mode input handling. Only active when
            // this tile is the relocating target — see plan's "Move
            // Tile" menu action.
            //
            // Swap is PHYSICAL: arrow keys move the tile toward the
            // rect actually adjacent in that direction, computed by
            // `MultiviewGridMath.physicalNeighbor`. This handles
            // asymmetric layouts (3/5/7/8) correctly — D-pad Down
            // from a top-row tile moves it into the row below, not
            // to the next entry in the list (which for N=7 would be
            // the middle tile on the right, not below).
            .onMoveCommand { direction in
                guard store.relocatingTileID == tile.id,
                      let idx = store.tiles.firstIndex(where: { $0.id == tile.id })
                else { return }
                let neighborDir: MultiviewGridMath.NeighborDirection
                switch direction {
                case .left:  neighborDir = .left
                case .right: neighborDir = .right
                case .up:    neighborDir = .up
                case .down:  neighborDir = .down
                @unknown default: return
                }
                guard let neighborIdx = MultiviewGridMath.physicalNeighbor(
                    of: idx,
                    count: store.tiles.count,
                    direction: neighborDir
                ) else { return }
                let neighborID = store.tiles[neighborIdx].id
                DebugLogger.shared.log(
                    "[MV-Cmd] tvOS relocate swap dir=\(neighborDir) tile=\(tile.id) neighbor=\(neighborID)",
                    category: "Playback", level: .info
                )
                store.swap(tile.id, neighborID)
            }
            .onExitCommand {
                // Menu while relocating = cancel. Otherwise let the
                // command propagate (container handles exit-
                // multiview at the root).
                if store.relocatingTileID == tile.id {
                    store.relocatingTileID = nil
                    DebugLogger.shared.log(
                        "[MV-Cmd] tvOS relocate cancel (Menu) tile=\(tile.id)",
                        category: "Playback", level: .info
                    )
                }
            }
            #endif
    }

    // MARK: - Content

    private var tileContent: some View {
        ZStack {
            // The actual mpv-backed video view. It's at the bottom of
            // the ZStack so overlays paint on top.
            MPVPlayerViewRepresentable(
                urls: [tile.streamURL],
                headers: tile.headers,
                isLive: true,
                nowPlayingTitle: tile.item.name,
                nowPlayingSubtitle: tile.item.currentProgram,
                nowPlayingArtworkURL: tile.item.logoURL,
                progressStore: progressStore,
                logStore: logStore,
                onFatalError: { message in
                    // Surface on the tile instead of killing the
                    // whole app. The overlay exposes a Remove button.
                    decodeErrorMessage = message
                    // Log the sanitized message — the raw message can
                    // echo server-controlled bytes (HLS errors, HTTP
                    // response bodies). `sanitizedErrorMessage` strips
                    // control/bidi chars and caps length.
                    DebugLogger.shared.log(
                        "[MV-Tile] decode error: channel=\(tile.item.name) msg=\(Self.sanitizedErrorMessage(message))",
                        category: "Playback", level: .warning
                    )
                },
                tileID: tile.id,
                isAudioActive: isAudioActive,
                shouldPause: shouldPause
            )
            // SwiftUI identity is the TILE id, not the item.id, so
            // rearrange (which shuffles `tiles` but keeps ids) doesn't
            // recreate the coordinator. Seed-from-single has
            // `tile.id == item.id` so that case also preserves
            // identity with the single-mode view.
            .id(tile.id)
            .onAppear {
                DebugLogger.shared.log(
                    "[MV-Tile] mount id=\(tile.id) name=\(tile.item.name)",
                    category: "Playback", level: .info
                )
            }
            .onDisappear {
                DebugLogger.shared.log(
                    "[MV-Tile] unmount id=\(tile.id)",
                    category: "Playback", level: .info
                )
            }

            // Audio-active badge (top-left). Visual language matches
            // the rest of the app: accent color + speaker icon. Only
            // drawn on the audio tile.
            if isAudioActive {
                audioBadge
            }

            // Close button (top-right, iPadOS only). tvOS surfaces
            // Remove via the per-tile confirmation dialog because a
            // persistent tap target next to a focus-driven tile grid
            // hurts focus-engine arithmetic (extra siblings in the
            // focus chain). iPad users expect a Maps / Widget
            // "x close" affordance on each card.
            #if !os(tvOS)
            closeButton
            #endif

            // Tile chrome — channel name strip along the bottom,
            // shown on hover / focus for tvOS and always on iPad.
            labelStrip

            // Red decode-error overlay. Only shown when mpv's failover
            // has exhausted its retries. Remove button calls the
            // store — tearing down the MPVPlayerView via the tile
            // removal is cleaner than trying to re-init the mpv
            // handle in place.
            if let decodeErrorMessage {
                decodeErrorOverlay(decodeErrorMessage)
            }
        }
        .overlay(
            // Focus ring (tvOS) / relocate-amber. Audio-active is
            // signalled by the audioBadge (speaker icon top-left),
            // not a ring — see `ring` docstring.
            //
            // Animation: 150ms ease so state transitions (focus in/
            // out on tvOS, relocate enter/exit) feel like a native
            // focus-engine effect instead of a snap.
            Self.tileShape
                .stroke(ring.color, lineWidth: ring.width)
                .animation(.easeInOut(duration: 0.15), value: isFocused)
                .animation(.easeInOut(duration: 0.15), value: store.relocatingTileID)
        )
        .clipShape(Self.tileShape)
        // Black underlay so letterbox bars aren't transparent.
        .background(Self.tileShape.fill(Color.black))
        #if !os(tvOS)
        // iPadOS: trackpad / Magic-Keyboard hover cue. `.highlight`
        // gives the standard iPad "I'm pointing at a control"
        // feedback, consistent with Settings and LiveTV cards.
        .hoverEffect(.highlight)
        #endif
        #if os(tvOS)
        .overlay(tvPressOverlay)
        #else
        .onTapGesture {
            // iPadOS: tap to take audio. The long-press gesture
            // handles the menu.
            store.setAudio(to: tile.id)
        }
        .onLongPressGesture(minimumDuration: 0.35) {
            showMenu = true
            DebugLogger.shared.log(
                "[MV-Cmd] tile menu opened id=\(tile.id)",
                category: "Playback", level: .info
            )
        }
        #endif
        #if !os(tvOS)
        // iPadOS drag-and-drop rearrange. tvOS uses the explicit
        // "Move Tile" menu action — the Siri Remote doesn't have a
        // drag primitive.
        .onDrag {
            NSItemProvider(object: tile.id as NSString)
        }
        .onDrop(
            of: [.text],
            delegate: MultiviewTileDropDelegate(
                targetID: tile.id,
                store: store
            )
        )
        #endif
    }

    // MARK: - Ring (focus / audio)

    /// Shared rounded-rect used for clip, background, and stroke.
    /// Shape-constructed once, destructured at the call sites, so
    /// the corner radius stays in sync across all three visual
    /// layers. Radius 12 matches `tvSettingsCardBG(_:)` at
    /// `Features/Settings/SettingsView.swift:898` so a focused tile
    /// and a focused Settings card feel like the same app.
    private static let tileShape = RoundedRectangle(
        cornerRadius: 12,
        style: .continuous
    )

    /// Precedence: relocating > focused (tvOS) > none.
    ///
    /// The audio-active state is intentionally NOT a ring here. v1
    /// used an `accentPrimary` ring around the audio tile, but on
    /// iPad device test that rendered as a visually-heavy "blue box"
    /// that competed with the video. The `audioBadge` (top-left
    /// speaker icon) is a clearer, less-intrusive audio indicator
    /// and reads the same across iPad and tvOS. If we ever need a
    /// stronger audio cue, prefer adjusting the badge's saturation
    /// or adding a small accent strip under the label — NOT an
    /// outer border.
    ///
    /// Color language:
    /// - Relocate ring: `.orange` at 4pt. Semantic, intentionally OFF
    ///   the accent token so it never clashes with focus even for
    ///   users who customise accent to orange. Also reads as
    ///   "edit-mode" in system UI (iOS home-screen jiggle).
    /// - Focus ring (tvOS only): solid `accentPrimary` at 2.5pt,
    ///   matching `tvSettingsCardBG` focused-state exactly so a
    ///   focused tile and a focused Settings card look identical.
    private var ring: (color: Color, width: CGFloat) {
        if store.relocatingTileID == tile.id {
            return (.orange, 4)
        }
        #if os(tvOS)
        if isFocused {
            return (Color.accentPrimary, 2.5)
        }
        #endif
        return (.clear, 0)
    }

    // MARK: - Audio badge

    // MARK: - Close button (iPad only)

    #if !os(tvOS)
    private var closeButton: some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    store.remove(id: tile.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white, Color.black.opacity(0.65))
                        .padding(6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close tile")
                .accessibilityHint("Remove this channel from multiview")
            }
            Spacer()
        }
    }
    #endif

    private var audioBadge: some View {
        VStack {
            HStack {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(Color.accentPrimary)
                    )
                    .padding(8)
                Spacer()
            }
            Spacer()
        }
        .allowsHitTesting(false)
    }

    // MARK: - Label strip

    private var labelStrip: some View {
        VStack {
            Spacer()
            HStack {
                Text(tile.item.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.black.opacity(0.55))
                    )
                Spacer()
            }
            .padding(8)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Decode-error overlay

    private func decodeErrorOverlay(_ message: String) -> some View {
        ZStack {
            Color.red.opacity(0.85)
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.white)
                Text("Decoder unavailable")
                    .font(.headline)
                    .foregroundStyle(.white)
                // SECURITY: mpv error strings can echo server-controlled
                // bytes (HTTP error bodies, HLS parse errors, remote URL
                // fragments). Use `verbatim:` so SwiftUI doesn't apply
                // Markdown interpretation — otherwise a hostile origin
                // could send `[Click here](evil://)` and render a
                // tappable link inside our error UI. Also strip control
                // chars + bidi-override characters and cap length.
                Text(verbatim: Self.sanitizedErrorMessage(message))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 10)
                Button("Remove", role: .destructive) {
                    store.remove(id: tile.id)
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }
            .padding(12)
        }
    }

    /// Strip control chars, bidi overrides, and truncate to a display-
    /// safe length. The remaining text is still technically attacker-
    /// influenced (mpv faithfully relays server errors), but it can't
    /// spoof structure or hide bytes.
    private static func sanitizedErrorMessage(_ raw: String) -> String {
        // Unicode categories we never want to see in the overlay:
        // C0/C1 controls, bidi overrides/embeddings, zero-width
        // space/joiner, LTR/RTL marks.
        let blockedScalars: Set<Unicode.Scalar> = [
            "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
            "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",
            "\u{200B}", "\u{200C}", "\u{200D}", "\u{200E}", "\u{200F}",
            "\u{FEFF}"
        ]
        var cleaned = ""
        cleaned.reserveCapacity(raw.count)
        for scalar in raw.unicodeScalars {
            if blockedScalars.contains(scalar) { continue }
            if scalar.value < 0x20 && scalar != "\n" && scalar != "\t" { continue }
            if (0x7F...0x9F).contains(scalar.value) { continue }
            cleaned.unicodeScalars.append(scalar)
            if cleaned.count >= 200 { break }
        }
        return cleaned
    }

    // MARK: - Menu

    @ViewBuilder
    private var menuButtons: some View {
        // "Make Audio" hidden on the already-audio tile — it would be
        // a silent no-op and takes a menu slot from a useful action.
        if !isAudioActive {
            Button("Make Audio") {
                store.setAudio(to: tile.id)
            }
        }

        let isFullscreen = store.fullscreenTileID == tile.id
        Button(isFullscreen ? "Exit Full-Screen" : "Full-Screen in Grid") {
            store.fullscreenTileID = isFullscreen ? nil : tile.id
        }

        // Audio / subtitle sub-menus — only shown when there's a
        // non-trivial choice. `audioTracks.count > 1` because the
        // default "Track 1" with no alternative is just noise.
        //
        // Sub-menu flags are flipped on the NEXT runloop via a
        // Task @MainActor hop. Flipping synchronously races the main
        // dialog's dismiss animation — SwiftUI sometimes renders
        // both stacked dialogs at once, which looks broken. The
        // one-tick defer lets the first dialog's `.isPresented`
        // reach `false` before the second's flips to `true`.
        if progressStore.audioTracks.count > 1 {
            Button("Audio Track…") {
                Task { @MainActor in showAudioTrackMenu = true }
            }
        }
        if !progressStore.subtitleTracks.isEmpty {
            Button("Subtitle Track…") {
                Task { @MainActor in showSubtitleTrackMenu = true }
            }
        }

        #if os(tvOS)
        Button("Move Tile") {
            // Entering relocate-mode. The container's
            // `.onMoveCommand` picks this up and remaps D-pad into
            // swap-neighbor. The caller (container) draws an amber
            // ring while this is non-nil.
            store.relocatingTileID = tile.id
            DebugLogger.shared.log(
                "[MV-Cmd] tvOS relocate enter tile=\(tile.id)",
                category: "Playback", level: .info
            )
        }
        #endif

        Button("Remove", role: .destructive) {
            store.remove(id: tile.id)
        }

        Button("Cancel", role: .cancel) {}
    }

    @ViewBuilder
    private var audioTrackButtons: some View {
        // SECURITY: `track.displayName` is mpv-sourced and therefore
        // attacker-influenced via stream metadata (title tag, track
        // lang). SwiftUI's `Button(_: String)` and `Button(_: LocalizedStringKey)`
        // both apply Markdown to the label — so a title like
        // `[Click](evil://)` would render a tappable link inside the
        // action sheet. Use the closure-based `Button { } label:`
        // form with `Text(verbatim:)` to disable interpretation.
        ForEach(progressStore.audioTracks) { track in
            let active = track.id == progressStore.currentAudioTrackID
            Button {
                progressStore.setAudioTrackAction?(track.id)
            } label: {
                Text(verbatim: active ? "✓ \(track.displayName)" : track.displayName)
            }
        }
        Button("Cancel", role: .cancel) {}
    }

    @ViewBuilder
    private var subtitleTrackButtons: some View {
        Button(progressStore.currentSubtitleTrackID == 0 ? "✓ Off" : "Off") {
            progressStore.setSubtitleTrackAction?(0)
        }
        ForEach(progressStore.subtitleTracks) { track in
            let active = track.id == progressStore.currentSubtitleTrackID
            Button {
                progressStore.setSubtitleTrackAction?(track.id)
            } label: {
                Text(verbatim: active ? "✓ \(track.displayName)" : track.displayName)
            }
        }
        Button("Cancel", role: .cancel) {}
    }

    // MARK: - tvOS press overlay

    #if os(tvOS)
    private var tvPressOverlay: some View {
        TVPressOverlay(
            minimumPressDuration: 0.35,
            isFocused: $isFocused,
            onTap: {
                // During relocate mode, Select commits the move
                // (clears `relocatingTileID`). Otherwise it acts as
                // tap-to-take-audio, matching the iPad gesture.
                // Without this guard, Select mid-relocate silently
                // shifts audio instead of committing, confusing the
                // user who expected a click-to-place flow.
                if store.relocatingTileID == tile.id {
                    store.relocatingTileID = nil
                    DebugLogger.shared.log(
                        "[MV-Cmd] tvOS relocate commit (Select) tile=\(tile.id)",
                        category: "Playback", level: .info
                    )
                    return
                }
                store.setAudio(to: tile.id)
            },
            onLongPress: {
                // Long-press mid-relocate is treated as cancel so the
                // user isn't stuck in the mode if they forgot how to
                // escape it.
                if store.relocatingTileID == tile.id {
                    store.relocatingTileID = nil
                    DebugLogger.shared.log(
                        "[MV-Cmd] tvOS relocate cancel (long-press) tile=\(tile.id)",
                        category: "Playback", level: .info
                    )
                    return
                }
                showMenu = true
                DebugLogger.shared.log(
                    "[MV-Cmd] tile menu opened id=\(tile.id)",
                    category: "Playback", level: .info
                )
            }
        )
    }
    #endif

    // MARK: - A11y

    private var a11yLabel: String {
        let audioState = isAudioActive ? "audio on" : "muted"
        let name = tile.item.name
        let err = decodeErrorMessage != nil ? ", decode error" : ""
        return "\(name), \(audioState)\(err)"
    }
}

// MARK: - iPadOS drop delegate

#if !os(tvOS)
/// Handles `.onDrop` on a tile: when a drag from another tile lands
/// on `targetID`, swap the two in `MultiviewStore.tiles`. Audio
/// follows content, not position, so `audioTileID` is untouched.
struct MultiviewTileDropDelegate: DropDelegate {
    let targetID: String
    let store: MultiviewStore

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.text]).first else {
            return false
        }
        // Loading the string is async — capture target + store up
        // front and hop back to MainActor to mutate.
        let target = targetID
        let s = store
        provider.loadObject(ofClass: NSString.self) { value, _ in
            guard let sourceID = (value as? NSString) as String? else { return }
            guard sourceID != target else { return }
            Task { @MainActor in
                DebugLogger.shared.log(
                    "[MV-Tile] drop swap source=\(sourceID) target=\(target)",
                    category: "Playback", level: .info
                )
                s.swap(sourceID, target)
            }
        }
        return true
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.text])
    }
}
#endif
