import SwiftUI
import Combine
#if os(tvOS)
import GameController
#endif

// MARK: - Channel number entry (GH #71)
//
// Direct channel-number entry from a keyboard or a remote that delivers
// digit key presses: an attached keyboard on iPadOS, or on Apple TV a
// Bluetooth keyboard / a CEC or universal remote with a number pad (the
// Siri Remote has no digits). Digits typed while the live player or the
// EPG guide is on screen collect in a small overlay under the nav bar;
// Return resolves them against the channel numbers and either tunes
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
    @Published private(set) var digits = ""
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
                if let digit = Self.digit(for: keyCode) {
                    self.handle(character: digit, source: "gckeyboard")
                } else if keyCode == .returnOrEnter || keyCode == .keypadEnter {
                    self.commit()
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
                        .font(.headline)
                } else {
                    Text(entry.digits)
                        .font(.system(size: digitSize, weight: .semibold, design: .rounded))
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

    init(scope: ChannelNumberEntry.Scope, isActive: Bool = true,
         channels: @escaping () -> [ChannelDisplayItem],
         onResolve: @escaping (ChannelDisplayItem) -> Void) {
        self.scope = scope
        self.isActive = isActive
        self.channels = channels
        self.onResolve = onResolve
    }

    func body(content: Content) -> some View {
        content
            .onKeyPress(characters: .decimalDigits, phases: .down) { press in
                guard let c = press.characters.first else { return .ignored }
                return entry.handle(character: c) ? .handled : .ignored
            }
            .onKeyPress(.return, phases: .down) { _ in
                entry.commit() ? .handled : .ignored
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
                    entry.register(scope, channels: channels, onResolve: onResolve)
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
