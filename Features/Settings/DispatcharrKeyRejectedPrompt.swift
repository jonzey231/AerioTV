//
//  DispatcharrKeyRejectedPrompt.swift
//  Aerio
//
//  "Sign-in not accepted": shown once per rejection when the server refused
//  a playlist's API key and AerioTV holds every API call for it locally
//  (DispatcharrRequestGate). Android twin: feature/settings/
//  ApiKeyRejectedPrompt.kt (fd145f3d). Buttons in order Not Now, Edit
//  Playlist; Edit Playlist is the preferred action, so it is the bold one on
//  iPhone and iPad and the one that takes focus on Apple TV. Edit Playlist
//  opens Edit Playlist for THAT playlist.
//
//  A platform alert (UIAlertController) on the topmost presented controller
//  rather than a SwiftUI `.alert`: the rejection usually lands while a sheet
//  is closing (Add Playlist's Save, measured on the simulator 2026-11-10),
//  and a SwiftUI alert whose presentation is blocked at that moment is never
//  shown. This one waits for the presentation to settle and retries.
//

import SwiftUI
import UIKit

@MainActor
final class DispatcharrKeyPromptModel: ObservableObject {
    static let shared = DispatcharrKeyPromptModel()

    @Published private(set) var prompt: DispatcharrRequestGate.Prompt?
    private weak var shown: UIAlertController?
    private var shownPrompt: DispatcharrRequestGate.Prompt?
    private var retry: Task<Void, Never>?

    private init() {
        prompt = DispatcharrRequestGate.shared.prompt
        // Read the gate's CURRENT prompt on the main actor instead of the
        // value the callback carried: callbacks from different threads may
        // land out of order, the gate's state never does.
        DispatcharrRequestGate.shared.onPromptChange = { _ in
            Task { @MainActor in DispatcharrKeyPromptModel.shared.sync() }
        }
    }

    /// Touch once at launch so the gate's callback is wired before any 401.
    func install() { sync() }

    private func sync() {
        let now = DispatcharrRequestGate.shared.prompt
        if prompt != now { prompt = now }
        guard let now else {
            // Cleared elsewhere (an edit, a passing key check, a re-check).
            retry?.cancel()
            if let a = shown, a.presentingViewController != nil { a.dismiss(animated: true) }
            shown = nil
            shownPrompt = nil
            return
        }
        if shownPrompt == now, shown?.presentingViewController != nil { return }
        present(now, attempt: 0)
    }

    private func present(_ p: DispatcharrRequestGate.Prompt, attempt: Int) {
        retry?.cancel()
        guard DispatcharrRequestGate.shared.prompt == p else { return }
        guard let top = Self.topController(), !top.isBeingDismissed, !top.isBeingPresented,
              !(top is UIAlertController) else {
            // Another presentation is settling (a sheet closing, another
            // alert up): try again shortly, for up to a minute.
            guard attempt < 120 else { return }
            retry = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                if !Task.isCancelled { self.present(p, attempt: attempt + 1) }
            }
            return
        }
        let alert = UIAlertController(
            title: DispatcharrRateLimitCopy.keyRejectedTitle,
            message: DispatcharrRateLimitCopy.keyRejectedBody(playlistName: p.playlistName,
                                                              passwordToo: p.passwordToo),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Not Now", style: .cancel) { _ in
            Task { @MainActor in DispatcharrKeyPromptModel.shared.notNow() }
        })
        let edit = UIAlertAction(title: "Edit Playlist", style: .default) { _ in
            Task { @MainActor in DispatcharrKeyPromptModel.shared.editPlaylist(p) }
        }
        alert.addAction(edit)
        alert.preferredAction = edit
        shown = alert
        shownPrompt = p
        debugLog("[AUTH] Sign-in not accepted prompt shown for \(p.playlistID.prefix(8))")
        top.present(alert, animated: true)
        watch(p, alert)
    }

    /// The controller it went up on can be torn down under it (the launch
    /// splash handing over to the main UI, measured 2026-11-10): while the
    /// prompt is still pending, check once a second that the alert is
    /// actually on screen and put it back up when it is not.
    private func watch(_ p: DispatcharrRequestGate.Prompt, _ alert: UIAlertController) {
        retry = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, DispatcharrRequestGate.shared.prompt == p, self.shown === alert else { return }
                if alert.viewIfLoaded?.window == nil, !alert.isBeingPresented {
                    debugLog("[AUTH] Sign-in not accepted prompt was not on screen; showing it again")
                    self.shown = nil
                    self.present(p, attempt: 0)
                    return
                }
            }
        }
    }

    private static func topController() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        var top = window?.rootViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }

    func notNow() {
        debugLog("[AUTH] Sign-in not accepted prompt: Not Now")
        shown = nil
        shownPrompt = nil
        DispatcharrRequestGate.shared.consumePrompt()
        prompt = nil
    }

    func editPlaylist(_ p: DispatcharrRequestGate.Prompt) {
        debugLog("[AUTH] Sign-in not accepted prompt: Edit Playlist for \(p.playlistID.prefix(8))")
        shown = nil
        shownPrompt = nil
        DispatcharrRequestGate.shared.consumePrompt()
        prompt = nil
        if let id = UUID(uuidString: p.playlistID) { SettingsDeepLink.openEditPlaylist(id) }
    }
}

/// Installs the prompt at the app root (RootView).
struct DispatcharrKeyRejectedPromptHost: ViewModifier {
    func body(content: Content) -> some View {
        content.onAppear { DispatcharrKeyPromptModel.shared.install() }
    }
}
