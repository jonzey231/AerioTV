import SwiftUI

/// iPadOS keyboard shortcuts for the multiview grid. Installed once
/// by `AerioApp`'s scene-level `.commands { }` block (iOS-only).
///
/// Design:
/// - Each command guards on `PlayerSession.shared.mode == .multiview`
///   so pressing a hotkey outside multiview is a no-op. We don't
///   hide or disable the commands based on mode because SwiftUI's
///   command system doesn't give us a reactive way to do that
///   without capturing the session in every command builder;
///   no-op-at-dispatch is simpler and has identical UX.
/// - The sheet-opening / exit shortcuts route through the same
///   `MultiviewStore` / `PlayerSession` APIs as on-screen buttons so
///   behavior stays consistent.
///
/// `@MainActor` because the mutations are on `@MainActor`-isolated
/// singletons. `Commands` bodies run on the main actor already, but
/// being explicit silences Swift 6 strict-concurrency warnings.
#if os(iOS)
struct MultiviewCommands: Commands {
    var body: some Commands {
        CommandMenu("Multiview") {
            Button("Add Tile…") {
                openAddSheet()
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("Exit Multiview") {
                exitMultiview()
            }
            .keyboardShortcut("w", modifiers: .command)

            Divider()

            Button("Full-Screen Audio Tile") {
                toggleFullscreenAudioTile()
            }
            .keyboardShortcut("f", modifiers: .command)

            Divider()

            // ⌘1..⌘9 — take audio of tile N (1-indexed, so ⌘1 is
            // tile[0]). Each button is only active when that tile
            // index exists. `Button.disabled` is driven off a
            // fresh-computed bound value; this re-computes when any
            // command key is pressed because SwiftUI re-evaluates
            // `body` on change.
            ForEach(1...9, id: \.self) { slot in
                Button("Take Audio of Tile \(slot)") {
                    takeAudio(slot: slot)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(slot)")), modifiers: .command)
            }
        }
    }

    // MARK: - Actions

    @MainActor
    private func openAddSheet() {
        guard PlayerSession.shared.mode == .multiview else { return }
        DebugLogger.shared.log("[MV-Cmd] ⌘N openAddSheet", category: "Playback", level: .info)
        // There's no global "present add sheet" API — the sheet is
        // owned by `MultiviewContainerView`'s `@State`. We post a
        // Notification that the container listens for; the container
        // flips its local state on receipt. This is the least-
        // invasive wiring (no env-object plumbing, no new singleton).
        NotificationCenter.default.post(name: .multiviewRequestOpenAddSheet, object: nil)
    }

    @MainActor
    private func exitMultiview() {
        guard PlayerSession.shared.mode == .multiview else { return }
        DebugLogger.shared.log("[MV-Cmd] ⌘W exitMultiview", category: "Playback", level: .info)
        // ⌘W behaves like the on-screen Exit button: fall back to
        // single-stream playback of the audio tile's channel.
        PlayerSession.shared.exitMultiviewKeepingAudioTile()
    }

    @MainActor
    private func toggleFullscreenAudioTile() {
        guard PlayerSession.shared.mode == .multiview else { return }
        let store = MultiviewStore.shared
        guard let audioID = store.audioTileID else { return }
        let willBeFullscreen = (store.fullscreenTileID != audioID)
        store.fullscreenTileID = willBeFullscreen ? audioID : nil
        DebugLogger.shared.log(
            "[MV-Cmd] ⌘F fullscreen audioTile=\(audioID) now=\(willBeFullscreen ? "on" : "off")",
            category: "Playback", level: .info
        )
    }

    @MainActor
    private func takeAudio(slot: Int) {
        guard PlayerSession.shared.mode == .multiview else { return }
        let store = MultiviewStore.shared
        let idx = slot - 1
        guard store.tiles.indices.contains(idx) else { return }
        DebugLogger.shared.log(
            "[MV-Cmd] ⌘\(slot) takeAudio tile=\(store.tiles[idx].id)",
            category: "Playback", level: .info
        )
        store.setAudio(to: store.tiles[idx].id)
    }
}
#endif

/// Notification posted by `MultiviewCommands` to ask the container
/// view to open its add-channel sheet. Container registers a
/// `.onReceive(...)` observer on this and flips its `@State
/// showAddSheet` to `true`.
extension Notification.Name {
    static let multiviewRequestOpenAddSheet = Notification.Name("MultiviewRequestOpenAddSheet")

    /// Posted by MultiviewTileView when a live stream's connection issue
    /// starts (object = true, fired from scheduleAutoReconnect) or clears
    /// (object = false, from clearPlaybackError). The container listens to
    /// auto-summon + pin the chrome with the Retry cell focused on tvOS,
    /// so a re-tune is one Select away during an outage (Android parity,
    /// 2026-07-12).
    static let connectionIssueChanged = Notification.Name("ConnectionIssueChanged")

    /// Posted by the chrome's Retry cell (object = the audio tile id). The
    /// matching tile runs its own `retryNow()` so a chrome-driven retry is
    /// byte-for-byte the card's Retry: cancel the pending countdown, zero it,
    /// flip to "Reconnecting…", then fire retryAction. Calling retryAction
    /// straight from the chrome reconnected silently with no visible feedback
    /// (ATV field test 2026-07-12).
    static let connectionIssueRetryRequested = Notification.Name("ConnectionIssueRetryRequested")

    /// Posted by `SwitchStreamView` after a confirmed Dispatcharr Switch
    /// Stream. The live player coordinator whose proxy URL matches
    /// `userInfo["uuid"]` reloads libmpv onto the same proxy URL so it
    /// re-locks onto the channel's fresh buffer. libmpv usually follows the
    /// in-place TS swap on its own, but when the picked upstream is dead and
    /// Dispatcharr cascades through server-side failover, the buffer resets
    /// repeatedly and libmpv falls far behind the head (frozen until
    /// re-tune). The reload is the deterministic recovery; a brief keepalive
    /// connection is held across it so the channel isn't torn down to zero
    /// clients (Dispatcharr's short shutdown delay would cold-revert it to the
    /// default stream). Does NOT affect the Stats page (that's owner-worker
    /// gated server-side); purely a playback-robustness step.
    static let switchStreamReprime = Notification.Name("SwitchStreamReprime")
}
