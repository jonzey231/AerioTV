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
#endif
