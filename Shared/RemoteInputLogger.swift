//
// RemoteInputLogger.swift
//
// DEBUG-only tvOS remote-input logger. Subscribes to GameController events
// for the Siri Remote and prints every button press / dpad movement to
// stdout with a `[REMOTE]` prefix so the devicectl --console capture picks
// them up alongside the rest of the app's log output.
//
// Why GameController (not UIResponder.pressesBegan):
//   tvOS's focus engine consumes many UIPress events before they reach
//   any SwiftUI handler — e.g. the dpad presses that move focus never
//   fire `.onMoveCommand` on your views (SwiftUI rewrites those as focus
//   transitions, not command events). GameController's valueChangedHandler
//   runs in parallel with the focus engine and sees the raw hardware input
//   regardless of who consumes it downstream.
//
// What's logged:
//   [REMOTE] select           pressed   focus=MultiviewTileView
//   [REMOTE] select           released  focus=MultiviewTileView
//   [REMOTE] play_pause       pressed   focus=MultiviewTileView
//   [REMOTE] menu             pressed   focus=MultiviewTileView
//   [REMOTE] dpad             x=+0.98 y=+0.00  focus=MultiviewTileView
//   [REMOTE] controller_attached name=..., vendor=...
//
// To correlate with "what the UI did in response", grep the same
// timespan in the log for side effects — watchdog hangs, tile
// state changes, store mutations, SwiftUI lifecycle prints.
//

#if os(tvOS) && DEBUG
import Foundation
import GameController
import UIKit

enum RemoteInputLogger {
    private nonisolated(unsafe) static var didInstall = false

    /// Dedupe: valueChangedHandler fires on *any* change of the whole pad,
    /// including tiny dpad jiggles. Track last logged value per element to
    /// suppress sub-threshold dpad noise.
    private nonisolated(unsafe) static var lastDpadX: Float = 0
    private nonisolated(unsafe) static var lastDpadY: Float = 0

    static func install() {
        guard !didInstall else { return }
        didInstall = true

        // Attach to anything already connected.
        for c in GCController.controllers() { attach(to: c) }

        NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect,
            object: nil,
            queue: .main
        ) { note in
            if let c = note.object as? GCController { attach(to: c) }
        }
        NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect,
            object: nil,
            queue: .main
        ) { note in
            if let c = note.object as? GCController {
                log("controller_detached name=\(c.productCategory)")
            }
        }

        log("installed — waiting for controllers")
    }

    // MARK: - Attach

    private static func attach(to controller: GCController) {
        let name = controller.vendorName ?? "?"
        let category = controller.productCategory
        log("controller_attached name=\(category) vendor=\(name)")

        // Siri Remote presents as a microGamepad. Older remotes are the same
        // physical profile. Extended gamepads (PS/Xbox) add more buttons.
        if let mic = controller.microGamepad {
            attachMicro(mic)
        }
        if let ext = controller.extendedGamepad {
            attachExtended(ext)
        }
    }

    private static func attachMicro(_ pad: GCMicroGamepad) {
        // Don't let the dpad auto-snap to cardinals — we want the raw analog
        // value so we can see glide speed and partial flicks.
        pad.reportsAbsoluteDpadValues = true

        pad.buttonA.pressedChangedHandler = { _, _, pressed in
            log("select           \(pressed ? "pressed " : "released") focus=\(focusSummary())")
        }
        pad.buttonX.pressedChangedHandler = { _, _, pressed in
            log("play_pause       \(pressed ? "pressed " : "released") focus=\(focusSummary())")
        }
        pad.buttonMenu.pressedChangedHandler = { _, _, pressed in
            log("menu             \(pressed ? "pressed " : "released") focus=\(focusSummary())")
        }
        pad.dpad.valueChangedHandler = { _, x, y in
            logDpad(x: x, y: y)
        }
    }

    private static func attachExtended(_ pad: GCExtendedGamepad) {
        // For completeness on PS/Xbox controllers. Siri Remote won't hit
        // these, but a paired game controller will.
        pad.buttonA.pressedChangedHandler = { _, _, pressed in
            log("ext_A            \(pressed ? "pressed " : "released") focus=\(focusSummary())")
        }
        pad.buttonB.pressedChangedHandler = { _, _, pressed in
            log("ext_B            \(pressed ? "pressed " : "released") focus=\(focusSummary())")
        }
        pad.buttonMenu.pressedChangedHandler = { _, _, pressed in
            log("ext_menu         \(pressed ? "pressed " : "released") focus=\(focusSummary())")
        }
        pad.buttonOptions?.pressedChangedHandler = { _, _, pressed in
            log("ext_options      \(pressed ? "pressed " : "released") focus=\(focusSummary())")
        }
    }

    // MARK: - Dpad dedupe

    /// The Siri Remote touchpad fires valueChanged at up to ~60Hz with
    /// sub-pixel drift. Log only meaningful movement — thresholded at
    /// ±0.25, and only when state crosses a cardinal boundary or flicks
    /// to center. That keeps the log readable during swipes.
    private static func logDpad(x: Float, y: Float) {
        let threshold: Float = 0.25
        let prevBucket = dpadBucket(x: lastDpadX, y: lastDpadY, threshold: threshold)
        let newBucket = dpadBucket(x: x, y: y, threshold: threshold)
        guard prevBucket != newBucket else { return }
        lastDpadX = x
        lastDpadY = y
        let xs = String(format: "%+.2f", x)
        let ys = String(format: "%+.2f", y)
        log("dpad=\(String(describing: newBucket).padding(toLength: 9, withPad: " ", startingAt: 0)) x=\(xs) y=\(ys) focus=\(focusSummary())")
    }

    private enum DpadBucket: String { case center, up, down, left, right, upLeft, upRight, downLeft, downRight }

    private static func dpadBucket(x: Float, y: Float, threshold t: Float) -> DpadBucket {
        let up = y > t, down = y < -t, right = x > t, left = x < -t
        switch (up, down, left, right) {
        case (true,  false, false, false): return .up
        case (false, true,  false, false): return .down
        case (false, false, true,  false): return .left
        case (false, false, false, true ): return .right
        case (true,  false, true,  false): return .upLeft
        case (true,  false, false, true ): return .upRight
        case (false, true,  true,  false): return .downLeft
        case (false, true,  false, true ): return .downRight
        default: return .center
        }
    }

    // MARK: - Focus summary

    /// A short label for whatever UIKit currently has focused, so each
    /// press/dpad event in the log can be correlated with the target view.
    /// Falls back to `?` if the focus system can't be queried on the
    /// current thread / environment.
    @MainActor
    private static func focusSummaryMain() -> String {
        // UIWindowScene.focusSystem is the canonical tvOS 15+ API —
        // `UIScreen.focusedItem` is deprecated, and UIScreen doesn't conform
        // to UIFocusEnvironment so it can't be passed to
        // `UIFocusSystem.focusSystem(for:)` anyway.
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            if let sys = scene.focusSystem, let item = sys.focusedItem {
                return "\(type(of: item))"
            }
        }
        return "nil"
    }

    /// Non-main-actor shim so the GameController callback (which is already
    /// main-queue on tvOS, but not main-actor-isolated in Swift 6 strict
    /// mode) can call it without await. We guard with `Thread.isMainThread`
    /// so an accidental background call degrades to "?" rather than
    /// crashing.
    private static func focusSummary() -> String {
        guard Thread.isMainThread else { return "?off-main" }
        return MainActor.assumeIsolated { focusSummaryMain() }
    }

    // MARK: - Logging

    private static func log(_ msg: String) {
        // Pad the event name to a fixed width so columns line up in
        // the log file. A narrower label widens `focus=`.
        print("[REMOTE] \(msg)")
    }
}
#else
enum RemoteInputLogger {
    static func install() {}
}
#endif
