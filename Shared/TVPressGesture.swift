#if os(tvOS)
import SwiftUI
import UIKit

// MARK: - tvOS tap + long-press detector (UIKit-backed overlay)

/// UIKit-backed tap + long-press gesture for tvOS.
///
/// Why UIKit: every SwiftUI long-press API on tvOS either fires on press
/// RELEASE (not at `minimumDuration`) or is marked explicitly unavailable.
/// We verified the following signatures all fail or fire-on-release on
/// tvOS 18:
/// - `.onLongPressGesture(minimumDuration:perform:)` — fires on release
/// - `LongPressGesture.onEnded` (same underlying gesture) — fires on release
/// - `.onLongPressGesture(minimumDuration:maximumDistance:pressing:perform:)`
///   — unavailable
/// - `.onLongPressGesture(minimumDuration:maximumDistance:perform:onPressingChanged:)`
///   — unavailable
/// - `.highPriorityGesture(LongPressGesture(...))` — does not change the
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
/// Do NOT also add `.focusable()` / `.focused()` to `cellContent` — the
/// overlay UIView is the focusable element. Having both would create two
/// competing focus targets.
struct TVPressOverlay: UIViewRepresentable {
    let minimumPressDuration: TimeInterval
    let isFocused: Binding<Bool>?
    let onTap: () -> Void
    let onLongPress: () -> Void

    init(minimumPressDuration: TimeInterval = 0.35,
         isFocused: Binding<Bool>? = nil,
         onTap: @escaping () -> Void = {},
         onLongPress: @escaping () -> Void) {
        self.minimumPressDuration = minimumPressDuration
        self.isFocused = isFocused
        self.onTap = onTap
        self.onLongPress = onLongPress
    }

    func makeUIView(context: Context) -> UIView {
        // Outer container is a plain UIView (not focusable). The
        // focusable PressCatcherView lives inside it. Without this
        // wrapping, UIKit's focus engine inserts its `_UIReplicantView`
        // focus-animation sibling as a subview of our direct parent —
        // which is SwiftUI's `UIHostingController.view`, triggering the
        // console warning "Adding '_UIReplicantView' as a subview of
        // UIHostingController.view is not supported". Owning our own
        // container puts the replicant inside it instead, which is a
        // legitimate UIKit hierarchy.
        let container = UIView()
        container.backgroundColor = .clear

        let catcher = PressCatcherView()
        catcher.backgroundColor = .clear
        catcher.onTap = onTap
        catcher.onLongPress = onLongPress
        catcher.minimumPressDuration = minimumPressDuration
        catcher.onFocusChange = { focused in
            DispatchQueue.main.async {
                isFocused?.wrappedValue = focused
            }
        }
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
        catcher.onTap = onTap
        catcher.onLongPress = onLongPress
        catcher.minimumPressDuration = minimumPressDuration
        catcher.onFocusChange = { focused in
            DispatchQueue.main.async {
                isFocused?.wrappedValue = focused
            }
        }
    }
}

/// Focusable UIView that detects Siri-Remote select presses and dispatches
/// tap vs long-press callbacks based on how long the press was held.
final class PressCatcherView: UIView {
    var onTap: () -> Void = {}
    var onLongPress: () -> Void = {}
    var onFocusChange: ((Bool) -> Void)?
    var minimumPressDuration: TimeInterval = 0.35

    private var longPressTimer: Timer?
    private var longPressFired = false

    override var canBecomeFocused: Bool { true }

    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                  with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        onFocusChange?(context.nextFocusedView == self)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
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
