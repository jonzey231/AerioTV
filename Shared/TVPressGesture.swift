#if os(tvOS)
import SwiftUI
import UIKit

// MARK: - tvOS tap + long-press detector (UIKit-backed overlay)

/// UIKit-backed tap + long-press gesture for tvOS, with optional
/// directional capture for in-place reordering.
///
/// Why UIKit: every SwiftUI long-press API on tvOS either fires on press
/// RELEASE (not at `minimumDuration`) or is marked explicitly unavailable.
/// We verified the following signatures all fail or fire-on-release on
/// tvOS 18:
/// - `.onLongPressGesture(minimumDuration:perform:)` - fires on release
/// - `LongPressGesture.onEnded` (same underlying gesture) - fires on release
/// - `.onLongPressGesture(minimumDuration:maximumDistance:pressing:perform:)`
///   - unavailable
/// - `.onLongPressGesture(minimumDuration:maximumDistance:perform:onPressingChanged:)`
///   - unavailable
/// - `.highPriorityGesture(LongPressGesture(...))` - does not change the
///   release-fires behavior
///
/// Overlay design: the SwiftUI content renders normally and owns its own
/// layout. We add a transparent focusable UIView as an overlay on top.
/// The overlay's `canBecomeFocused` is true, so the tvOS focus engine
/// routes select-press events to it. `pressesBegan` starts a `Timer` that
/// fires `onLongPress` at exactly `minimumPressDuration` while the press
/// is still held; `pressesEnded` fires `onTap` if the timer hadn't fired
/// yet. Focus state is reported back into SwiftUI via `onFocusChange`.
///
/// Reorder support (additive, opt-in via `interceptsDirectional`): when a
/// row is "grabbed" for moving, set `interceptsDirectional = true` on its
/// overlay and `canFocus = false` on every OTHER row's overlay. The
/// grabbed overlay then (a) stays the only focusable element, so focus
/// physically cannot leave it, and (b) consumes d-pad up/down (both
/// directional clicks via `pressesBegan` and trackpad swipes via gesture
/// recognizers), forwarding them to `onMoveUp` / `onMoveDown` instead of
/// letting the focus engine navigate. Menu while grabbed calls `onMenu`
/// (drop) and is consumed so it does not also dismiss the host sheet.
///
/// Usage:
/// ```swift
/// @State private var isFocused = false  // NOT @FocusState
/// cellContent
///     .overlay(
///         TVPressOverlay(
///             minimumPressDuration: 0.35,
///             isFocused: $isFocused,
///             onTap: { /* primary action */ },
///             onLongPress: { showCtxDialog = true }
///         )
///     )
/// ```
/// Do NOT also add `.focusable()` / `.focused()` to `cellContent` - the
/// overlay UIView is the focusable element. Having both would create two
/// competing focus targets.
struct TVPressOverlay: UIViewRepresentable {
    let minimumPressDuration: TimeInterval
    let isFocused: Binding<Bool>?
    /// Whether this overlay may take focus. Set false on non-grabbed rows
    /// during a reorder so focus locks onto the grabbed row.
    let canFocus: Bool
    /// When true, d-pad up/down/left/right are captured by this overlay
    /// (up/down -> move callbacks, left/right consumed) and Menu drops.
    let interceptsDirectional: Bool
    /// Horizontal-only adjust mode for value sliders: with
    /// `interceptsDirectional` true, left/right are captured (to adjust the
    /// value) while up/down and Menu are forwarded to the focus engine so the
    /// user can still navigate away. Reorder rows leave this false (they
    /// capture up/down to move the grabbed row).
    let horizontalAdjustOnly: Bool
    let onTap: () -> Void
    let onLongPress: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onMenu: () -> Void
    /// d-pad left/right callbacks. When `interceptsDirectional` is true,
    /// left/right clicks/swipes route here instead of being consumed
    /// silently. Used by horizontal value sliders (StreamBufferSlider) to
    /// decrement/increment while keeping up/down for focus navigation.
    let onMoveLeft: () -> Void
    let onMoveRight: () -> Void

    init(minimumPressDuration: TimeInterval = 0.35,
         isFocused: Binding<Bool>? = nil,
         canFocus: Bool = true,
         interceptsDirectional: Bool = false,
         horizontalAdjustOnly: Bool = false,
         onTap: @escaping () -> Void = {},
         onLongPress: @escaping () -> Void,
         onMoveUp: @escaping () -> Void = {},
         onMoveDown: @escaping () -> Void = {},
         onMenu: @escaping () -> Void = {},
         onMoveLeft: @escaping () -> Void = {},
         onMoveRight: @escaping () -> Void = {}) {
        self.minimumPressDuration = minimumPressDuration
        self.isFocused = isFocused
        self.canFocus = canFocus
        self.interceptsDirectional = interceptsDirectional
        self.horizontalAdjustOnly = horizontalAdjustOnly
        self.onTap = onTap
        self.onLongPress = onLongPress
        self.onMoveUp = onMoveUp
        self.onMoveDown = onMoveDown
        self.onMenu = onMenu
        self.onMoveLeft = onMoveLeft
        self.onMoveRight = onMoveRight
    }

    func makeUIView(context: Context) -> UIView {
        // Outer container is a plain UIView (not focusable). The
        // focusable PressCatcherView lives inside it. Without this
        // wrapping, UIKit's focus engine inserts its `_UIReplicantView`
        // focus-animation sibling as a subview of our direct parent -
        // which is SwiftUI's `UIHostingController.view`, triggering the
        // console warning "Adding '_UIReplicantView' as a subview of
        // UIHostingController.view is not supported". Owning our own
        // container puts the replicant inside it instead, which is a
        // legitimate UIKit hierarchy.
        let container = UIView()
        container.backgroundColor = .clear

        let catcher = PressCatcherView(frame: .zero)
        catcher.backgroundColor = .clear
        apply(to: catcher)
        catcher.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(catcher)
        NSLayoutConstraint.activate([
            catcher.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            catcher.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            catcher.topAnchor.constraint(equalTo: container.topAnchor),
            catcher.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard let catcher = uiView.subviews.compactMap({ $0 as? PressCatcherView }).first else { return }
        apply(to: catcher)
    }

    private func apply(to catcher: PressCatcherView) {
        catcher.onTap = onTap
        catcher.onLongPress = onLongPress
        catcher.onMoveUp = onMoveUp
        catcher.onMoveDown = onMoveDown
        catcher.onMenu = onMenu
        catcher.onMoveLeft = onMoveLeft
        catcher.onMoveRight = onMoveRight
        catcher.minimumPressDuration = minimumPressDuration
        catcher.canFocus = canFocus
        // Set horizontalAdjustOnly BEFORE interceptsDirectional so the
        // latter's didSet enables the correct swipe recognizers.
        catcher.horizontalAdjustOnly = horizontalAdjustOnly
        catcher.interceptsDirectional = interceptsDirectional
        catcher.onFocusChange = { focused in
            DispatchQueue.main.async {
                isFocused?.wrappedValue = focused
            }
        }
    }
}

/// Focusable UIView that detects Siri-Remote select presses and dispatches
/// tap vs long-press callbacks based on how long the press was held, plus
/// optional directional capture for reordering.
final class PressCatcherView: UIView {
    var onTap: () -> Void = {}
    var onLongPress: () -> Void = {}
    var onMoveUp: () -> Void = {}
    var onMoveDown: () -> Void = {}
    var onMenu: () -> Void = {}
    var onMoveLeft: () -> Void = {}
    var onMoveRight: () -> Void = {}
    /// See TVPressOverlay.horizontalAdjustOnly. Set before
    /// interceptsDirectional (in apply) so its didSet enables the right
    /// swipe recognizers.
    var horizontalAdjustOnly: Bool = false
    var onFocusChange: ((Bool) -> Void)?
    var minimumPressDuration: TimeInterval = 0.35

    /// Whether this view may take focus. Toggled to false on non-grabbed
    /// rows during a reorder so focus locks onto the grabbed row.
    var canFocus: Bool = true

    /// When true, capture d-pad directions for in-place reordering.
    var interceptsDirectional: Bool = false {
        didSet {
            guard interceptsDirectional != oldValue else { return }
            // Horizontal-adjust mode (sliders) captures only left/right;
            // up/down stay with the focus engine for navigation.
            let vertical = interceptsDirectional && !horizontalAdjustOnly
            upSwipe?.isEnabled = vertical
            downSwipe?.isEnabled = vertical
            leftSwipe?.isEnabled = interceptsDirectional
            rightSwipe?.isEnabled = interceptsDirectional
        }
    }

    private var longPressTimer: Timer?
    private var longPressFired = false
    private weak var upSwipe: UISwipeGestureRecognizer?
    private weak var downSwipe: UISwipeGestureRecognizer?
    private weak var leftSwipe: UISwipeGestureRecognizer?
    private weak var rightSwipe: UISwipeGestureRecognizer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        let up = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipeUp))
        up.direction = .up
        up.isEnabled = false
        addGestureRecognizer(up)
        upSwipe = up

        let down = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipeDown))
        down.direction = .down
        down.isEnabled = false
        addGestureRecognizer(down)
        downSwipe = down

        let left = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipeLeft))
        left.direction = .left
        left.isEnabled = false
        addGestureRecognizer(left)
        leftSwipe = left

        let right = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipeRight))
        right.direction = .right
        right.isEnabled = false
        addGestureRecognizer(right)
        rightSwipe = right
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var canBecomeFocused: Bool { canFocus }

    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                  with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        onFocusChange?(context.nextFocusedView == self)
    }

    @objc private func handleSwipeUp() { if interceptsDirectional { onMoveUp() } }
    @objc private func handleSwipeDown() { if interceptsDirectional { onMoveDown() } }
    @objc private func handleSwipeLeft() { if interceptsDirectional { onMoveLeft() } }
    @objc private func handleSwipeRight() { if interceptsDirectional { onMoveRight() } }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // Reorder mode: capture directional clicks + Menu, consume them so
        // focus stays pinned to this (the grabbed) row and Menu does not
        // bubble up to dismiss the host sheet.
        if interceptsDirectional {
            for press in presses {
                switch press.type {
                // Left/right always route to the callbacks: reorder rows get
                // a no-op (lock to column); sliders adjust their value.
                case .leftArrow:  onMoveLeft();  return
                case .rightArrow: onMoveRight(); return
                // Up/down/Menu: reorder rows capture them (move the grabbed
                // row, drop the sheet). In horizontalAdjustOnly (slider) mode
                // they break out and fall through to super so the focus
                // engine can navigate away to adjacent rows.
                case .upArrow:
                    if horizontalAdjustOnly { break }
                    onMoveUp(); return
                case .downArrow:
                    if horizontalAdjustOnly { break }
                    onMoveDown(); return
                case .menu:
                    if horizontalAdjustOnly { break }
                    onMenu(); return
                default: break
                }
            }
        }

        guard presses.contains(where: { $0.type == .select }) else {
            super.pressesBegan(presses, with: event)
            return
        }
        longPressFired = false
        longPressTimer?.invalidate()
        // Timer.scheduledTimer's block is @Sendable, but we scheduled it
        // from the main thread so the runloop it fires on IS main. Use
        // MainActor.assumeIsolated to access the view's main-actor state
        // without a dispatch hop (which would add latency to the 0.35s
        // threshold we're trying to hit precisely).
        longPressTimer = Timer.scheduledTimer(
            withTimeInterval: minimumPressDuration,
            repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.longPressFired = true
                self.onLongPress()
            }
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // Reorder grabs consume directional/Menu in pressesBegan; slider
        // (horizontalAdjustOnly) mode instead forwards up/down/Menu to super
        // there for focus navigation. Either way the focus move, if any,
        // already happened at pressesBegan, so swallow their pressesEnded and
        // let only a Select press reach the tap path below.
        if interceptsDirectional,
           presses.contains(where: { $0.type == .upArrow || $0.type == .downArrow || $0.type == .leftArrow || $0.type == .rightArrow || $0.type == .menu }) {
            return
        }
        guard presses.contains(where: { $0.type == .select }) else {
            super.pressesEnded(presses, with: event)
            return
        }
        longPressTimer?.invalidate()
        longPressTimer = nil
        if !longPressFired {
            onTap()
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        longPressTimer?.invalidate()
        longPressTimer = nil
        super.pressesCancelled(presses, with: event)
    }
}

// MARK: - #42 Part 1: guide long-press-Left detector

/// Detects a LONG-press (>= 0.5s) of the Left d-pad while the guide is on
/// screen and invokes `onLongPressLeft`. A short Left passes straight through
/// (so the guide's `onMoveCommand` still scrolls the EPG timeline). The Left
/// long-press recognizer is installed on the host's WINDOW — the only ancestor
/// reliably in the focused program cell's `UIPress` responder chain (a sibling
/// `.overlay`/`.background` view is not) — and is removed when the guide leaves
/// the hierarchy, so it lives only while the guide (which mounts this view) is
/// shown. Modeled on PlayerView's `.leftArrow` long-press recognizer.
struct GuideLongPressLeftDetector: UIViewRepresentable {
    /// Hold threshold. 0.5s for the mapped guide action; sidebar mode passes
    /// ~0.32s so the docked group menu opens snappily (the Android twin moved
    /// off the OS ~500ms long-press for the same reason, Logan 2026-08-06).
    var minimumPressDuration: TimeInterval = 0.5
    /// Attach the recognizer only while true. The recognizer lives on the
    /// WINDOW, so the guide behind an overlay (the in-place Search screen)
    /// would otherwise keep reacting to holds aimed at the overlay.
    var isEnabled: Bool = true
    /// Fires once when the Left hold crosses the threshold (jump to "All").
    let onBegan: () -> Void
    /// Fires when the Left press is released (stop pinning focus to "All").
    let onEnded: () -> Void

    func makeUIView(context: Context) -> LeftHoldHostView {
        let v = LeftHoldHostView()
        v.minimumPressDuration = minimumPressDuration
        v.onLeftHoldBegan = onBegan
        v.onLeftHoldEnded = onEnded
        v.isEnabled = isEnabled
        v.isUserInteractionEnabled = false   // passthrough; never steals focus/taps
        return v
    }
    func updateUIView(_ uiView: LeftHoldHostView, context: Context) {
        uiView.minimumPressDuration = minimumPressDuration
        uiView.onLeftHoldBegan = onBegan
        uiView.onLeftHoldEnded = onEnded
        uiView.isEnabled = isEnabled
        uiView.syncRecognizer()
    }
    static func dismantleUIView(_ uiView: LeftHoldHostView, coordinator: ()) {
        uiView.detachRecognizer()
    }
}

/// Non-focusable host whose only job is to attach a Left-arrow long-press
/// recognizer to its window. Never takes focus or swallows touches; the
/// recognizer uses `cancelsTouchesInView = false` so short Left presses still
/// reach SwiftUI's `onMoveCommand` (timeline scroll) untouched.
final class LeftHoldHostView: UIView, UIGestureRecognizerDelegate {
    var onLeftHoldBegan: (() -> Void)?
    var onLeftHoldEnded: (() -> Void)?
    var minimumPressDuration: TimeInterval = 0.5 {
        didSet { recognizer?.minimumPressDuration = minimumPressDuration }
    }
    private weak var attachedWindow: UIWindow?
    private var recognizer: UILongPressGestureRecognizer?

    var isEnabled: Bool = true

    override var canBecomeFocused: Bool { false }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window !== attachedWindow { detachRecognizer() }
        syncRecognizer()
    }

    /// Attach while enabled + windowed, detach otherwise. Disabling mid-hold
    /// loses the release event, which the caller's safety-task backstops
    /// (leftHoldSafetyTask) already cover.
    func syncRecognizer() {
        if !isEnabled { detachRecognizer(); return }
        guard let window, recognizer == nil else { return }
        let lp = UILongPressGestureRecognizer(target: self, action: #selector(handleLeftHold(_:)))
        lp.allowedPressTypes = [NSNumber(value: UIPress.PressType.leftArrow.rawValue)]
        lp.minimumPressDuration = minimumPressDuration
        // #42 Part 1: consume the press once the long-press is recognized so the
        // still-held Left's "click" does not resolve into the guide on release
        // (which scrolled the EPG timeline). Short Left (< 0.5s) never recognizes
        // the long-press, so its timeline scroll via onMoveCommand is unaffected.
        lp.cancelsTouchesInView = true
        lp.delaysTouchesBegan = false
        lp.delegate = self
        window.addGestureRecognizer(lp)
        recognizer = lp
        attachedWindow = window
    }

    func detachRecognizer() {
        if let r = recognizer { attachedWindow?.removeGestureRecognizer(r) }
        recognizer = nil
        attachedWindow = nil
    }

    @objc private func handleLeftHold(_ gr: UILongPressGestureRecognizer) {
        switch gr.state {
        case .began:
            onLeftHoldBegan?()
        case .ended, .cancelled, .failed:
            onLeftHoldEnded?()
        default:
            break
        }
    }

    // Coexist with the focus engine + any other recognizers (e.g. the player's).
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

// MARK: - guide long-press-Right detector (close corner mini-player)

/// Detects a LONG-press (>= 0.5s) of the Right d-pad and invokes `onBegan`,
/// used to close the corner mini-player while the guide is on screen (parity
/// with the Android TV "hold Right to close the mini player" gesture). Modeled
/// on GuideLongPressLeftDetector: the recognizer is installed on the host's
/// WINDOW (the only ancestor reliably in the focused cell's `UIPress` responder
/// chain) but ONLY while `isEnabled` is true — i.e. while a mini-player is
/// active. When no mini is up the recognizer is removed, so ordinary Right
/// navigation in the guide (including hold-to-fast-scroll) is completely
/// untouched. A short Right always passes through to `onMoveCommand`.
struct GuideLongPressRightDetector: UIViewRepresentable {
    /// Attach the Right long-press recognizer only while this is true (mini active).
    let isEnabled: Bool
    /// Fires once when the Right hold crosses the 0.5s threshold (close mini + pin timeline).
    let onBegan: () -> Void
    /// Fires when the Right press is released (unpin the guide timeline).
    let onEnded: () -> Void

    func makeUIView(context: Context) -> RightHoldHostView {
        let v = RightHoldHostView()
        v.onRightHoldBegan = onBegan
        v.onRightHoldEnded = onEnded
        v.isEnabled = isEnabled
        v.isUserInteractionEnabled = false   // passthrough; never steals focus/taps
        return v
    }
    func updateUIView(_ uiView: RightHoldHostView, context: Context) {
        uiView.onRightHoldBegan = onBegan
        uiView.onRightHoldEnded = onEnded
        uiView.isEnabled = isEnabled
        uiView.syncRecognizer()
    }
    static func dismantleUIView(_ uiView: RightHoldHostView, coordinator: ()) {
        uiView.detachRecognizer()
    }
}

/// Non-focusable host that attaches a Right-arrow long-press recognizer to its
/// window ONLY while `isEnabled` (a corner mini-player is minimized), so ordinary
/// Right (including hold-to-fast-scroll) is untouched when no mini is up. It fires
/// `onRightHoldBegan` on the 0.5s threshold (close the mini) and `onRightHoldEnded`
/// on release. The recognizer is kept attached from `.began` until release even
/// though `isEnabled` flips false when the mini closes — NOT to "hold focus" (a
/// window recognizer cannot suppress the tvOS focus engine; see #42 Part 2) — but
/// so the `.ended` event reliably fires `onRightHoldEnded`. The actual "don't
/// scroll the guide right during the hold" is done in EPGGuideView, which pins its
/// timeline (gates onMoveCommand(.right)) between the Began/Ended notifications. A
/// 5s safety fires onRightHoldEnded and resets the recognizer if the release is
/// ever missed.
final class RightHoldHostView: UIView, UIGestureRecognizerDelegate {
    var onRightHoldBegan: (() -> Void)?
    var onRightHoldEnded: (() -> Void)?
    var isEnabled: Bool = false
    private weak var attachedWindow: UIWindow?
    private var recognizer: UILongPressGestureRecognizer?
    /// True from the recognized Right-hold (.began) until release. While true the
    /// recognizer is not detached even after `isEnabled` flips false (mini closed),
    /// so the `.ended` release still fires and unpins the guide timeline.
    private var holdInProgress = false
    private var holdSafety: DispatchWorkItem?

    override var canBecomeFocused: Bool { false }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window !== attachedWindow { detachRecognizer() }
        syncRecognizer()
    }

    /// Attach the recognizer when enabled + windowed; remove it otherwise, but
    /// NEVER mid-hold — so the `.ended` release still fires `onRightHoldEnded`
    /// (which unpins the guide timeline) after the mini closes. Idempotent.
    func syncRecognizer() {
        if isEnabled, let window, recognizer == nil {
            let lp = UILongPressGestureRecognizer(target: self, action: #selector(handleRightHold(_:)))
            lp.allowedPressTypes = [NSNumber(value: UIPress.PressType.rightArrow.rawValue)]
            lp.minimumPressDuration = 0.5
            // Consume the recognized long-press so its release "click" does not
            // resolve into the guide's onMoveCommand. Short Right (< 0.5s) never
            // recognizes, so its timeline scroll is unaffected.
            lp.cancelsTouchesInView = true
            lp.delaysTouchesBegan = false
            lp.delegate = self
            window.addGestureRecognizer(lp)
            recognizer = lp
            attachedWindow = window
        } else if !isEnabled && !holdInProgress {
            detachRecognizer()
        }
    }

    func detachRecognizer() {
        holdSafety?.cancel(); holdSafety = nil
        holdInProgress = false
        if let r = recognizer { attachedWindow?.removeGestureRecognizer(r) }
        recognizer = nil
        attachedWindow = nil
    }

    @objc private func handleRightHold(_ gr: UILongPressGestureRecognizer) {
        switch gr.state {
        case .began:
            holdInProgress = true
            // Backstop in case the release event is missed, so the timeline pin
            // (and this recognizer) are never left stuck. Mirrors the hold-Left pin.
            holdSafety?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.endHold() }
            holdSafety = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: work)
            onRightHoldBegan?()
        case .ended, .cancelled, .failed:
            endHold()
        default:
            break
        }
    }

    /// Hold released (or safety fired): fire `onRightHoldEnded` exactly once
    /// (unpins the guide timeline), then reset the recognizer and re-arm fresh if
    /// a mini is still minimized — so a recognizer left mid-recognition (a missed
    /// release) is always cleared rather than stuck.
    private func endHold() {
        holdSafety?.cancel(); holdSafety = nil
        guard holdInProgress else { return }
        holdInProgress = false
        onRightHoldEnded?()
        detachRecognizer()
        syncRecognizer()
    }

    // Coexist with the focus engine + any other recognizers (e.g. the player's).
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

/// Window-level LEFT + RIGHT hold detector for the player's timeline
/// scrub (task #147 follow-up). SwiftUI's `.onMoveCommand` fires once
/// per d-pad CLICK and never autorepeats on a hold (confirmed in the
/// 2026-07-10 ATV field log: consecutive scrub steps only ever arrived
/// as discrete presses), so hold-to-scrub needs UIKit: one
/// `UILongPressGestureRecognizer` per arrow, 0.4s threshold, firing
/// `onBegan(direction)` (+1 right / -1 left) then `onEnded` on
/// release. The caller runs the repeat loop between the two. Short
/// presses never recognize and keep flowing to the focus engine /
/// `.onMoveCommand` untouched. Same window-attachment + mid-hold
/// keep-alive rules as `RightHoldHostView` above, with a longer 30s
/// safety (a legitimate scrub across a 2h programme holds for ~10s).
struct ScrubHoldDetector: UIViewRepresentable {
    let isEnabled: Bool
    let onBegan: (Int) -> Void
    let onEnded: () -> Void

    func makeUIView(context: Context) -> ScrubHoldHostView {
        let v = ScrubHoldHostView()
        v.onHoldBegan = onBegan
        v.onHoldEnded = onEnded
        v.isEnabled = isEnabled
        v.isUserInteractionEnabled = false
        return v
    }
    func updateUIView(_ uiView: ScrubHoldHostView, context: Context) {
        uiView.onHoldBegan = onBegan
        uiView.onHoldEnded = onEnded
        uiView.isEnabled = isEnabled
        uiView.syncRecognizers()
    }
    static func dismantleUIView(_ uiView: ScrubHoldHostView, coordinator: ()) {
        uiView.detachRecognizers()
    }
}

final class ScrubHoldHostView: UIView, UIGestureRecognizerDelegate {
    var onHoldBegan: ((Int) -> Void)?
    var onHoldEnded: (() -> Void)?
    var isEnabled: Bool = false
    private weak var attachedWindow: UIWindow?
    private var leftRecognizer: UILongPressGestureRecognizer?
    private var rightRecognizer: UILongPressGestureRecognizer?
    private var holdInProgress = false
    private var holdSafety: DispatchWorkItem?

    override var canBecomeFocused: Bool { false }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window !== attachedWindow { detachRecognizers() }
        syncRecognizers()
    }

    func syncRecognizers() {
        if isEnabled, let window, leftRecognizer == nil {
            leftRecognizer = makeRecognizer(.leftArrow, in: window)
            rightRecognizer = makeRecognizer(.rightArrow, in: window)
            attachedWindow = window
        } else if !isEnabled && !holdInProgress {
            detachRecognizers()
        }
    }

    private func makeRecognizer(_ type: UIPress.PressType, in window: UIWindow) -> UILongPressGestureRecognizer {
        let lp = UILongPressGestureRecognizer(target: self, action: #selector(handleHold(_:)))
        lp.allowedPressTypes = [NSNumber(value: type.rawValue)]
        lp.minimumPressDuration = 0.4
        lp.cancelsTouchesInView = true
        lp.delaysTouchesBegan = false
        lp.delegate = self
        window.addGestureRecognizer(lp)
        return lp
    }

    func detachRecognizers() {
        holdSafety?.cancel(); holdSafety = nil
        holdInProgress = false
        if let l = leftRecognizer { attachedWindow?.removeGestureRecognizer(l) }
        if let r = rightRecognizer { attachedWindow?.removeGestureRecognizer(r) }
        leftRecognizer = nil
        rightRecognizer = nil
        attachedWindow = nil
    }

    @objc private func handleHold(_ gr: UILongPressGestureRecognizer) {
        switch gr.state {
        case .began:
            holdInProgress = true
            holdSafety?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.endHold() }
            holdSafety = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 30.0, execute: work)
            onHoldBegan?(gr === leftRecognizer ? -1 : +1)
        case .ended, .cancelled, .failed:
            endHold()
        default:
            break
        }
    }

    private func endHold() {
        holdSafety?.cancel(); holdSafety = nil
        guard holdInProgress else { return }
        holdInProgress = false
        onHoldEnded?()
        detachRecognizers()
        syncRecognizers()
    }

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

#endif

// MARK: - player long-press detector (Remote Control #195)

#if os(tvOS)
/// Window-level hold detector for the PLAYER's mapped long-press slots:
/// Up/Down at 0.25s - deliberately UNDER the 300ms channel-flip debounce so
/// a recognized hold can cancel the pending flip queued by the short press -
/// and Select at 0.35s, where recognition swallows the release so the tile's
/// Button action never also fires. One recognizer per press type so the
/// callback knows which began. Installed on the window only while
/// [isEnabled] (the bare fullscreen live player); short presses always pass
/// through untouched. Modeled on GuideLongPressLeftDetector.
struct PlayerLongPressDetector: UIViewRepresentable {
    let isEnabled: Bool
    let onBegan: (UIPress.PressType) -> Void

    func makeUIView(context: Context) -> PlayerHoldHostView {
        let v = PlayerHoldHostView()
        v.onBegan = onBegan
        v.isUserInteractionEnabled = false   // passthrough; never steals focus
        v.setEnabled(isEnabled)
        return v
    }
    func updateUIView(_ uiView: PlayerHoldHostView, context: Context) {
        uiView.onBegan = onBegan
        uiView.setEnabled(isEnabled)
    }
    static func dismantleUIView(_ uiView: PlayerHoldHostView, coordinator: ()) {
        uiView.detachRecognizers()
    }
}

final class PlayerHoldHostView: UIView, UIGestureRecognizerDelegate {
    var onBegan: ((UIPress.PressType) -> Void)?
    private weak var attachedWindow: UIWindow?
    private var recognizers: [UILongPressGestureRecognizer] = []
    private var enabled = false

    override var canBecomeFocused: Bool { false }

    func setEnabled(_ on: Bool) {
        enabled = on
        if on { attachIfPossible() } else { detachRecognizers() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window !== attachedWindow { detachRecognizers() }
        attachIfPossible()
    }

    private func attachIfPossible() {
        guard enabled, let window, recognizers.isEmpty else { return }
        let specs: [(UIPress.PressType, TimeInterval)] = [
            (.upArrow, 0.25),
            (.downArrow, 0.25),
            (.select, 0.35),
        ]
        for (type, duration) in specs {
            let lp = UILongPressGestureRecognizer(target: self, action: #selector(handleHold(_:)))
            lp.allowedPressTypes = [NSNumber(value: type.rawValue)]
            lp.minimumPressDuration = duration
            // Swallow the press once the hold recognizes so the release
            // doesn't ALSO resolve as the short action (Select would
            // otherwise fire the tile's Button on release).
            lp.cancelsTouchesInView = true
            lp.delaysTouchesBegan = false
            lp.delegate = self
            window.addGestureRecognizer(lp)
            recognizers.append(lp)
        }
        attachedWindow = window
    }

    func detachRecognizers() {
        for r in recognizers { attachedWindow?.removeGestureRecognizer(r) }
        recognizers.removeAll()
        attachedWindow = nil
    }

    @objc private func handleHold(_ gr: UILongPressGestureRecognizer) {
        guard gr.state == .began,
              let raw = (gr.allowedPressTypes.first as? NSNumber)?.intValue,
              let type = UIPress.PressType(rawValue: raw) else { return }
        onBegan?(type)
    }

    // Coexist with the focus engine + the scrub/guide hold recognizers.
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
#endif
