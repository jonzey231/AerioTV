import SwiftUI
import Combine
#if os(tvOS)
import GameController
import UIKit.UIGestureRecognizerSubclass
#endif

// MARK: - Channel number entry (GH #71)
//
// Direct channel-number entry from a keyboard or a remote that delivers
// digit key presses: an attached keyboard on iPadOS, or on Apple TV a
// Bluetooth keyboard / a CEC or universal remote with a number pad (the
// Siri Remote has no digits). Digits typed while the live player or the
// EPG guide is on screen collect in a small overlay under the nav bar;
// Return (or OK / Select on Apple TV) resolves them against the
// channel numbers and either tunes
// (player) or jumps the guide's focus/scroll to that row. An entry left
// alone for 6s clears itself.
//
// One shared state holder feeds every screen. Each screen registers a
// `Scope` with the channel list it shows and what "resolve" means for
// it; the player scope wins over the guide scope whenever both are on
// screen (full-screen player above the Live TV tab).

@MainActor
final class ChannelNumberEntry: ObservableObject {
    static let shared = ChannelNumberEntry()

    enum Scope: Int, Comparable {
        case guide = 0
        case player = 1
        static func < (a: Scope, b: Scope) -> Bool { a.rawValue < b.rawValue }
    }

    struct Handler {
        /// The list a typed number resolves against (index fallback uses
        /// its 1-based position).
        let channels: () -> [ChannelDisplayItem]
        /// What to do with the match.
        let onResolve: (ChannelDisplayItem) -> Void
    }

    static let maxDigits = 4
    /// Digits wait for Return; an entry left alone this long clears itself
    /// (Logan 2026-09-02: no auto-commit, matches Android).
    static let idleClear: TimeInterval = 6.0
    static let messageDuration: TimeInterval = 1.5

    /// Digits typed so far (empty when idle).
    @Published private(set) var digits = "" {
        didSet {
            #if os(tvOS)
            selectPressCommit.setArmed(!digits.isEmpty)
            #endif
        }
    }
    /// Transient "No channel 123" notice.
    @Published private(set) var message: String?
    /// Scope that currently owns key presses and the overlay.
    @Published private(set) var activeScope: Scope?

    var isVisible: Bool { !digits.isEmpty || message != nil }
    var isPending: Bool { !digits.isEmpty }

    private var handlers: [Scope: Handler] = [:]
    private var commitTask: Task<Void, Never>?
    private var messageTask: Task<Void, Never>?
    /// Same-character debounce so a press that reaches us twice (SwiftUI
    /// `.onKeyPress` and the GameController fallback both firing) counts
    /// once.
    private var lastEvent: (character: Character, at: Date)?

    #if os(tvOS)
    private lazy var selectPressCommit = SelectPressCommitInterceptor { [weak self] in
        self?.commit()
    }
    #endif

    private init() {}

    // MARK: Registration

    func register(_ scope: Scope, channels: @escaping () -> [ChannelDisplayItem],
                  onResolve: @escaping (ChannelDisplayItem) -> Void) {
        handlers[scope] = Handler(channels: channels, onResolve: onResolve)
        recomputeActiveScope()
        #if os(tvOS)
        startKeyboardFallback()
        #endif
    }

    func unregister(_ scope: Scope) {
        handlers[scope] = nil
        let wasActive = activeScope == scope
        recomputeActiveScope()
        // The owning screen went away mid-entry: drop the digits rather
        // than letting the timer act on a screen that no longer shows.
        if wasActive { cancel() }
    }

    private func recomputeActiveScope() {
        activeScope = handlers.keys.max()
    }

    // MARK: Input

    /// Feed one digit. Returns false (unhandled) when the character is
    /// not a digit, nothing is registered, or the press is a duplicate.
    @discardableResult
    func handle(character c: Character, source: String = "keypress") -> Bool {
        guard c.isASCII, c.isNumber, activeScope != nil else { return false }
        let now = Date()
        if let last = lastEvent, last.character == c, now.timeIntervalSince(last.at) < 0.15 {
            return true
        }
        lastEvent = (c, now)
        messageTask?.cancel()
        message = nil
        if digits.count >= Self.maxDigits {
            digits = String(digits.dropFirst())
        }
        digits.append(c)
        debugLog("[ChannelNumber] \(source) digit=\(c) buffer=\(digits) scope=\(String(describing: activeScope))")
        scheduleCommit()
        return true
    }

    private func scheduleCommit() {
        commitTask?.cancel()
        commitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.idleClear * 1_000_000_000))
            guard !Task.isCancelled else { return }
            _ = self?.cancel()
        }
    }

    /// Resolve the buffered digits now (Return / Select). Returns false
    /// when nothing was buffered so the caller can leave the press to
    /// its normal owner.
    @discardableResult
    func commit() -> Bool {
        commitTask?.cancel()
        commitTask = nil
        guard !digits.isEmpty else { return false }
        let typed = digits
        digits = ""
        guard let scope = activeScope, let handler = handlers[scope] else { return true }
        if let match = Self.resolve(typed, in: handler.channels()) {
            debugLog("[ChannelNumber] resolved \(typed) -> \(match.name) (#\(match.number)) scope=\(scope)")
            handler.onResolve(match)
        } else {
            debugLog("[ChannelNumber] no channel \(typed) scope=\(scope)")
            showMessage("No channel \(typed)")
        }
        return true
    }

    /// Drop the buffer (Menu / Escape). Returns false when nothing was
    /// pending so the caller can treat the press normally.
    @discardableResult
    func cancel() -> Bool {
        commitTask?.cancel()
        commitTask = nil
        messageTask?.cancel()
        let hadSomething = isVisible
        digits = ""
        message = nil
        return hadSomething
    }

    private func showMessage(_ text: String) {
        messageTask?.cancel()
        message = text
        messageTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.messageDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }

    // MARK: Resolution

    /// Leading zeros are not significant ("007" == "7"); an all-zero
    /// entry stays "0" so a channel numbered 0 remains reachable.
    static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let stripped = trimmed.drop(while: { $0 == "0" })
        return stripped.isEmpty ? "0" : String(stripped)
    }

    /// Channel-number match first; when no channel carries that number,
    /// fall back to the 1-based row position in the list shown.
    static func resolve(_ raw: String, in channels: [ChannelDisplayItem]) -> ChannelDisplayItem? {
        let wanted = normalize(raw)
        guard !wanted.isEmpty else { return nil }
        if let byNumber = channels.first(where: { normalize($0.number) == wanted }) {
            return byNumber
        }
        if let index = Int(wanted), index >= 1, index <= channels.count {
            return channels[index - 1]
        }
        return nil
    }

    // MARK: tvOS keyboard fallback

    #if os(tvOS)
    /// SwiftUI `.onKeyPress` needs the press to travel up the focus
    /// chain to the modifier; on tvOS that is not guaranteed for every
    /// input path (a remote that maps its number pad through the
    /// keyboard HID page, focus parked on a UIKit-hosted view). The
    /// GameController keyboard profile sees every connected keyboard
    /// regardless of focus, so it rides alongside as a fallback; the
    /// same-character debounce above folds the two deliveries into one.
    private var keyboardConnectObserver: NSObjectProtocol?

    private func startKeyboardFallback() {
        guard keyboardConnectObserver == nil else { return }
        keyboardConnectObserver = NotificationCenter.default.addObserver(
            forName: .GCKeyboardDidConnect, object: nil, queue: .main
        ) { [weak self] _ in
            // Queue is main; re-read the coalesced keyboard rather than
            // carrying the notification object across the isolation edge.
            MainActor.assumeIsolated {
                self?.attachKeyboard(GCKeyboard.coalesced)
            }
        }
        attachKeyboard(GCKeyboard.coalesced)
    }

    private func attachKeyboard(_ keyboard: GCKeyboard?) {
        guard let input = keyboard?.keyboardInput else { return }
        input.keyChangedHandler = { [weak self] _, _, keyCode, pressed in
            guard pressed else { return }
            Task { @MainActor [weak self] in
                guard let self, self.activeScope != nil else { return }
                // Return / Enter is deliberately not handled here: tvOS
                // also delivers it as a Select press, which
                // `SelectPressCommitInterceptor` commits. Committing here
                // first disarmed that recognizer, so the Select reached the
                // focused guide cell and played it instead.
                if let digit = Self.digit(for: keyCode) {
                    self.handle(character: digit, source: "gckeyboard")
                } else if keyCode == .escape {
                    self.cancel()
                }
            }
        }
    }

    private static func digit(for code: GCKeyCode) -> Character? {
        switch code {
        case .zero, .keypad0: return "0"
        case .one, .keypad1: return "1"
        case .two, .keypad2: return "2"
        case .three, .keypad3: return "3"
        case .four, .keypad4: return "4"
        case .five, .keypad5: return "5"
        case .six, .keypad6: return "6"
        case .seven, .keypad7: return "7"
        case .eight, .keypad8: return "8"
        case .nine, .keypad9: return "9"
        default: return nil
        }
    }
    #endif
}

// MARK: - tvOS remote Select commits

#if os(tvOS)
/// A remote's OK button arrives as a `.select` press, and on Apple TV a
/// keyboard's Return / Enter arrives as one too. The focused view (a player
/// tile, a guide cell) would act on it. While digits are buffered, a
/// window-level recognizer takes the press first, swallows it so the focused
/// view does not also act on it, and commits the entry instead. This is the
/// only commit path on tvOS. Same window-recognizer approach as
/// `PlayerLongPressDetector`.
@MainActor
final class SelectPressCommitInterceptor: NSObject {
    private let onSelect: () -> Void
    private weak var attachedWindow: UIWindow?
    private var recognizer: SelectPressDownRecognizer?
    /// Whether digits are buffered. Disarming while Select is still held
    /// does not remove the recognizer yet: removing it mid-press left the
    /// guide's own tap and hold gestures stuck (the next OK opened the
    /// program menu or did nothing), so removal waits for the press to end.
    private var isArmed = false

    init(onSelect: @escaping () -> Void) {
        self.onSelect = onSelect
    }

    /// Attach to the key window while armed, detach otherwise.
    func setArmed(_ armed: Bool) {
        isArmed = armed
        if armed {
            attach()
        } else if let recognizer, recognizer.state == .began || recognizer.state == .changed {
            return
        } else {
            detach()
        }
    }

    private func attach() {
        guard recognizer == nil, let window = Self.keyWindow() else { return }
        let press = SelectPressDownRecognizer(target: self, action: #selector(handleSelect(_:)))
        press.cancelsTouchesInView = true
        window.addGestureRecognizer(press)
        recognizer = press
        attachedWindow = window
    }

    private func detach() {
        if let recognizer { attachedWindow?.removeGestureRecognizer(recognizer) }
        recognizer = nil
        attachedWindow = nil
    }

    @objc private func handleSelect(_ gesture: SelectPressDownRecognizer) {
        switch gesture.state {
        case .began:
            onSelect()
        case .ended, .cancelled, .failed:
            // Off this action callback, so the recognizer is not removed
            // from inside its own state change; re-check in case new digits
            // re-armed it in between.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isArmed else { return }
                self.detach()
            }
        default:
            break
        }
    }

    private static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }
}

/// Begins the moment Select goes down, ahead of the focused view's own
/// Select handling. (A zero-duration `UILongPressGestureRecognizer` did not
/// fire for a quick press in testing, which then played the focused cell.)
final class SelectPressDownRecognizer: UIGestureRecognizer {
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        guard state == .possible else { return }
        // Any other button fails at once: the other recognizers are told to
        // wait for this one, so it must never sit undecided on an arrow or
        // Back press.
        state = presses.contains(where: { $0.type == .select }) ? .began : .failed
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        if state == .began || state == .changed { state = .ended } else { state = .failed }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        state = .cancelled
    }

    // Win against the focused view's own Select recognizers (guide cells,
    // player tiles): never wait on them, and make them wait on this one.
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func shouldRequireFailure(of otherGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func shouldBeRequiredToFail(by otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
}
#endif

// MARK: - Overlay

/// Small top-right pill showing the digits typed so far, or the
/// "No channel N" notice. Purely presentational; reads the shared
/// state holder.
struct ChannelNumberEntryOverlay: View {
    @ObservedObject private var entry = ChannelNumberEntry.shared
    let scope: ChannelNumberEntry.Scope

    var body: some View {
        if entry.activeScope == scope, entry.isVisible {
            Group {
                if let message = entry.message {
                    Text(message)
                        .scaledFont(.headline)
                } else {
                    Text(entry.digits)
                        .scaledFont(.system(size: digitSize, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
            }
            .foregroundColor(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .background(Color.black.opacity(0.72))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(.top, 24)
            .transition(.opacity)
            .allowsHitTesting(false)
            .accessibilityLabel(entry.message ?? "Channel number \(entry.digits)")
        }
    }

    private var digitSize: CGFloat {
        #if os(tvOS)
        return 44
        #else
        return 30
        #endif
    }
}

// MARK: - View modifier

/// Attach to a screen that supports number entry. Registers the scope
/// while `isActive`, intercepts digit / Return / Escape key presses, and
/// hosts the overlay. Key presses only reach `.onKeyPress` when focus
/// sits inside the modified view; the tvOS GameController fallback in
/// the state holder covers presses that do not.
struct ChannelNumberEntryModifier: ViewModifier {
    let scope: ChannelNumberEntry.Scope
    let isActive: Bool
    let channels: () -> [ChannelDisplayItem]
    let onResolve: (ChannelDisplayItem) -> Void

    @ObservedObject private var entry = ChannelNumberEntry.shared

    /// The newest closures from the screen. The modifier is rebuilt on every
    /// render with closures that capture that render's values, but the scope
    /// registers once, so the handler reads through this box. Without it a
    /// guide that registered while its list was still loading resolved every
    /// number against that first, partial list ("No channel 13" with 13 on
    /// screen).
    private final class LatestHandler {
        var channels: () -> [ChannelDisplayItem] = { [] }
        var onResolve: (ChannelDisplayItem) -> Void = { _ in }
    }
    @State private var latest = LatestHandler()

    init(scope: ChannelNumberEntry.Scope, isActive: Bool = true,
         channels: @escaping () -> [ChannelDisplayItem],
         onResolve: @escaping (ChannelDisplayItem) -> Void) {
        self.scope = scope
        self.isActive = isActive
        self.channels = channels
        self.onResolve = onResolve
    }

    func body(content: Content) -> some View {
        latest.channels = channels
        latest.onResolve = onResolve
        return content
            .onKeyPress(characters: .decimalDigits, phases: .down) { press in
                guard let c = press.characters.first else { return .ignored }
                return entry.handle(character: c) ? .handled : .ignored
            }
            .onKeyPress(.return, phases: .down) { _ in
                #if os(tvOS)
                // Left to the Select press tvOS sends for the same key (see
                // the GameController fallback).
                return .ignored
                #else
                return entry.commit() ? .handled : .ignored
                #endif
            }
            .onKeyPress(.escape, phases: .down) { _ in
                entry.cancel() ? .handled : .ignored
            }
            .overlay(alignment: .top) {
                ChannelNumberEntryOverlay(scope: scope)
                    .animation(.easeInOut(duration: 0.15), value: entry.isVisible)
            }
            .onChange(of: isActive, initial: true) { _, active in
                if active {
                    entry.register(scope,
                                   channels: { [latest] in latest.channels() },
                                   onResolve: { [latest] item in latest.onResolve(item) })
                } else {
                    entry.unregister(scope)
                }
            }
            .onDisappear { entry.unregister(scope) }
    }
}

extension View {
    /// GH #71: digit-key channel entry for this screen.
    func channelNumberEntry(scope: ChannelNumberEntry.Scope, isActive: Bool = true,
                            channels: @escaping () -> [ChannelDisplayItem],
                            onResolve: @escaping (ChannelDisplayItem) -> Void) -> some View {
        modifier(ChannelNumberEntryModifier(scope: scope, isActive: isActive,
                                            channels: channels, onResolve: onResolve))
    }
}
