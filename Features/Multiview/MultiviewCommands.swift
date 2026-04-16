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
        PlayerSession.shared.exit()
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
}
