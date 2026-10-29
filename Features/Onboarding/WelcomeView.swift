import SwiftUI

/// Welcome screen (onboarding redesign, approved 2026-10-29).
///
/// Why the redesign: the old screen led with a logo, a tagline, and a list
/// of source types that were not tappable, so the first real decision (where
/// does your content live) sat below the fold. The new screen asks that
/// question first, splits "start here" from "keep your devices in sync", and
/// puts Skip one step after the last row so it is never hunted for.
///
/// Layout follows size classes only. Compact width (iPhone, and the outer
/// display of a foldable) is a single column with the phone headline;
/// regular width (iPad, Mac, and a foldable's inner display) is two columns,
/// brand left and cards right, with the tablet headline. No device-specific
/// branching: the system's own bars are respected through the safe area.
struct WelcomeView: View {
    @Binding var hasCompletedOnboarding: Bool
    @AppStorage("iCloudSyncEnabled") private var iCloudSyncEnabled = iCloudSyncEnabledDefault
    @ObservedObject private var syncManager = SyncManager.shared

    /// Discord (Glitzbr): he turned iCloud sync on during setup and a
    /// customised remote map from a different-generation Apple TV landed on
    /// this one. By the time he found the Sync Categories screen the data had
    /// already arrived, so the choice has to be offered BEFORE the first pull
    /// - which is what this sheet does. Logan 2026-08-10.
    @State private var showCategoryChooser = false

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    #if os(tvOS)
    private enum Field: Hashable { case connect, cloudSync, dispatcharr, skip }
    @FocusState private var focus: Field?
    #endif

    private var isTV: Bool {
        #if os(tvOS)
        return true
        #else
        return false
        #endif
    }

    private var isRegularWidth: Bool {
        #if os(iOS)
        return horizontalSizeClass == .regular
        #else
        return true
        #endif
    }

    // MARK: Copy

    private var headline: String {
        if isTV { return "Welcome. Let's get your TV connected." }
        return isRegularWidth ? "Welcome. Let's get connected." : "Welcome. Let's connect your content."
    }

    private var bodyCopy: String {
        isTV
            ? "Live TV with a full guide, movies, series, and DVR from your own server. Nothing is bundled, so the first step is telling AerioTV where your content lives."
            : "Live TV with a guide, movies, series, and DVR from your own server. First, tell AerioTV where it lives."
    }

    private var connectDetail: String {
        isTV
            ? "Enter the details yourself. Dispatcharr, Xtream Codes, or an M3U playlist with an EPG."
            : "Dispatcharr, Xtream Codes, or an M3U playlist with an EPG."
    }

    private var cloudSyncTitle: String {
        if syncManager.isImporting { return "Importing from iCloud..." }
        return iCloudSyncEnabled ? "iCloud sync is on" : "Sync with iCloud"
    }

    private var cloudSyncDetail: String {
        if syncManager.isImporting { return "Looking for an existing configuration." }
        return isTV
            ? "Turns on sync from here on. If you already have a backup, it restores it too."
            : "Turns on sync. Restores a backup if you have one."
    }

    private var dispatcharrDetail: String {
        isTV
            ? "Connects your server and turns on sync for favorites, progress, and settings."
            : "Connects your server and turns on sync."
    }

    private var skipFootnote: String {
        isTV
            ? "Look around first. You can connect a server any time from Settings."
            : "You can connect a server any time from Settings."
    }

    // MARK: Body

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                Group {
                    if isRegularWidth {
                        HStack(alignment: .top, spacing: isTV ? 80 : 48) {
                            brandColumn
                                .frame(maxWidth: .infinity, alignment: .leading)
                            choicesColumn
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxWidth: isTV ? 1600 : 1000)
                    } else {
                        VStack(alignment: .leading, spacing: 28) {
                            brandColumn
                            choicesColumn
                        }
                        .frame(maxWidth: 560)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, isTV ? 80 : 20)
                .padding(.vertical, isTV ? 60 : 24)
            }
        }
        .navigationBarHidden(true)
        #if os(tvOS)
        .defaultFocus($focus, .connect)
        // Menu at the top of setup never closes the app.
        .onExitCommand { }
        #endif
        .sheet(isPresented: $showCategoryChooser) {
            OnboardingSyncCategoryChooser(
                onContinue: {
                    showCategoryChooser = false
                    // Only NOW does anything come down: the categories the
                    // user just chose are already written, and
                    // syncSettingChanged is what kicks off the first pull.
                    // Sync stays on from here whether or not a backup exists.
                    iCloudSyncEnabled = true
                    SyncManager.shared.syncSettingChanged(enabled: true)
                },
                onCancel: {
                    showCategoryChooser = false
                    // Backing out leaves sync off entirely - nothing was
                    // pulled, so there is nothing to undo.
                }
            )
        }
    }

    private var brandColumn: some View {
        VStack(alignment: .leading, spacing: isTV ? 20 : 12) {
            Text("AerioTV")
                .scaledFont(.system(size: isTV ? 34 : 20, weight: .bold))
                .foregroundColor(.accentPrimary)
            Text(headline)
                .scaledFont(.system(size: isTV ? 56 : (isRegularWidth ? 40 : 30), weight: .bold))
                .foregroundColor(.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(bodyCopy)
                .scaledFont(isTV ? .system(size: 26).subtext() : .bodyLarge.subtext())
                .foregroundColor(Color.contrastText(.textSecondary))
                .fixedSize(horizontal: false, vertical: true)
            if isTV {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.left")
                    Text("Back returns to the previous step at any time")
                }
                .scaledFont(.system(size: 20).subtext())
                .foregroundColor(Color.contrastText(.textTertiary))
                .padding(.top, 24)
            }
        }
        .multilineTextAlignment(.leading)
    }

    private var choicesColumn: some View {
        VStack(alignment: .leading, spacing: isTV ? 16 : 10) {
            OnboardingSectionLabel("Start here")

            OnboardingNavCard(
                destination: AddServerView(isOnboarding: true),
                icon: "server.rack",
                title: "Connect a Server",
                detail: connectDetail,
                highlighted: true
            )
            #if os(tvOS)
            .focused($focus, equals: .connect)
            #endif

            OnboardingSectionLabel("Keep your devices in sync")
                .padding(.top, isTV ? 20 : 14)

            OnboardingActionCard(
                icon: iCloudSyncEnabled ? "checkmark.icloud.fill" : "icloud.fill",
                title: cloudSyncTitle,
                detail: cloudSyncDetail,
                isOn: iCloudSyncEnabled,
                isBusy: syncManager.isImporting
            ) {
                guard !syncManager.isImporting else { return }
                toggleICloudSync()
            }
            .disabled(syncManager.isImporting)
            #if os(tvOS)
            .focused($focus, equals: .cloudSync)
            #endif

            OnboardingNavCard(
                destination: AddServerView(initialType: .dispatcharrAPI, isOnboarding: true),
                icon: "key.fill",
                title: "Sign in with Dispatcharr",
                detail: dispatcharrDetail,
                highlighted: false
            )
            #if os(tvOS)
            .focused($focus, equals: .dispatcharr)
            #endif

            // Directly under the sync rows: one press down from the last row.
            VStack(alignment: .leading, spacing: 8) {
                OnboardingPillButton(title: "Skip for now", filled: false) {
                    hasCompletedOnboarding = true
                }
                #if os(tvOS)
                .focused($focus, equals: .skip)
                #endif
                Text(skipFootnote)
                    .scaledFont(isTV ? .system(size: 20).subtext() : .bodySmall.subtext())
                    .foregroundColor(Color.contrastText(.textTertiary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, isTV ? 16 : 10)
        }
    }

    /// Turning sync ON opens the chooser first and defers the pull until the
    /// user confirms; turning it OFF is immediate.
    private func toggleICloudSync() {
        if iCloudSyncEnabled {
            iCloudSyncEnabled = false
            SyncManager.shared.syncSettingChanged(enabled: false)
        } else {
            showCategoryChooser = true
        }
    }
}

// MARK: - Shared onboarding components

private var onboardingIsTV: Bool {
    #if os(tvOS)
    return true
    #else
    return false
    #endif
}

/// Small uppercase section label ("START HERE").
struct OnboardingSectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .scaledFont(.system(size: onboardingIsTV ? 20 : 12, weight: .semibold))
            .tracking(1.2)
            .foregroundColor(Color.contrastText(.textTertiary))
    }
}

/// The inside of every onboarding card: icon tile, title, detail, trailing.
struct OnboardingCardContent: View {
    let icon: String
    let title: String
    let detail: String
    var trailing: Trailing = .chevron
    var isFocused: Bool = false

    enum Trailing { case chevron, toggle(Bool), busy, none }

    var body: some View {
        let tv = onboardingIsTV
        HStack(spacing: tv ? 20 : 14) {
            ZStack {
                RoundedRectangle(cornerRadius: tv ? 12 : 10, style: .continuous)
                    .fill(Color.accentPrimary.opacity(0.15))
                    .frame(width: tv ? 56 : 40, height: tv ? 56 : 40)
                Image(systemName: icon)
                    .scaledFont(.system(size: tv ? 24 : 17, weight: .medium))
                    .foregroundColor(.accentPrimary)
            }
            .fixedSize()
            VStack(alignment: .leading, spacing: tv ? 6 : 3) {
                Text(title)
                    .scaledFont(tv ? .system(size: 26, weight: .semibold) : .headlineSmall)
                    .foregroundColor(.textPrimary)
                Text(detail)
                    .scaledFont(tv ? .system(size: 20).subtext() : .bodySmall.subtext())
                    .foregroundColor(Color.contrastText(.textSecondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            switch trailing {
            case .chevron:
                Image(systemName: "chevron.right")
                    .scaledFont(.system(size: tv ? 20 : 14, weight: .semibold))
                    .foregroundColor(isFocused ? .accentPrimary : Color.contrastText(.textTertiary))
            case .toggle(let on):
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .scaledFont(.system(size: tv ? 28 : 20))
                    .foregroundColor(on ? .accentPrimary : Color.contrastText(.textTertiary))
            case .busy:
                ProgressView().tint(.accentPrimary)
            case .none:
                EmptyView()
            }
        }
        .padding(.horizontal, tv ? 24 : 14)
        .padding(.vertical, tv ? 20 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Card surface: quiet border, accent border when highlighted or on.
struct OnboardingCardBackground: View {
    var highlighted: Bool = false
    var radius: CGFloat = onboardingIsTV ? 18 : 14

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.cardBackground)
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(highlighted ? Color.accentPrimary : Color.borderSubtle,
                                  lineWidth: highlighted ? 1.5 : 1)
            }
    }
}

/// Card that pushes a destination.
struct OnboardingNavCard<Destination: View>: View {
    let destination: Destination
    let icon: String
    let title: String
    let detail: String
    var highlighted: Bool = false
    #if os(tvOS)
    @FocusState private var isFocused: Bool
    #endif

    var body: some View {
        NavigationLink(destination: destination) {
            #if os(tvOS)
            OnboardingCardContent(icon: icon, title: title, detail: detail, isFocused: isFocused)
                .background(OnboardingCardBackground(highlighted: highlighted))
            #else
            OnboardingCardContent(icon: icon, title: title, detail: detail)
                .background(OnboardingCardBackground(highlighted: highlighted))
            #endif
        }
        #if os(tvOS)
        .buttonStyle(TVNoHighlightButtonStyle())
        .focused($isFocused)
        .tvFocusRingShape(.rounded(18))
        #else
        .buttonStyle(.plain)
        #endif
    }
}

/// Card that runs an action (on/off rows).
struct OnboardingActionCard: View {
    let icon: String
    let title: String
    let detail: String
    var highlighted: Bool = false
    var isOn: Bool? = nil
    var isBusy: Bool = false
    let action: () -> Void
    #if os(tvOS)
    @FocusState private var isFocused: Bool
    #endif

    init(icon: String, title: String, detail: String, highlighted: Bool = false,
         isOn: Bool? = nil, isBusy: Bool = false, action: @escaping () -> Void) {
        self.icon = icon; self.title = title; self.detail = detail
        self.highlighted = highlighted; self.isOn = isOn; self.isBusy = isBusy
        self.action = action
    }

    private var trailing: OnboardingCardContent.Trailing {
        if isBusy { return .busy }
        if let isOn { return .toggle(isOn) }
        return .chevron
    }

    var body: some View {
        Button(action: action) {
            #if os(tvOS)
            OnboardingCardContent(icon: icon, title: title, detail: detail,
                                  trailing: trailing, isFocused: isFocused)
                .background(OnboardingCardBackground(highlighted: highlighted || isOn == true))
            #else
            OnboardingCardContent(icon: icon, title: title, detail: detail, trailing: trailing)
                .background(OnboardingCardBackground(highlighted: highlighted || isOn == true))
            #endif
        }
        #if os(tvOS)
        .buttonStyle(TVNoHighlightButtonStyle())
        .focused($isFocused)
        .tvFocusRingShape(.rounded(18))
        #else
        .buttonStyle(.plain)
        #endif
    }
}

/// Capsule pill button: filled (primary) or outlined.
struct OnboardingPillButton: View {
    let title: String
    var filled: Bool = false
    var fullWidth: Bool = false
    let action: () -> Void

    var body: some View {
        let tv = onboardingIsTV
        Button(action: action) {
            Text(title)
                .scaledFont(.system(size: tv ? 24 : 16, weight: .semibold))
                .foregroundColor(filled ? .white : .textPrimary)
                .padding(.horizontal, tv ? 36 : 22)
                .frame(maxWidth: fullWidth ? .infinity : nil)
                .frame(minHeight: tv ? 60 : 44)
                .background {
                    if filled {
                        Capsule(style: .continuous).fill(LinearGradient.accentGradient)
                    } else {
                        Capsule(style: .continuous)
                            .strokeBorder(Color.borderSubtle, lineWidth: 1.5)
                    }
                }
                .contentShape(Capsule())
        }
        #if os(tvOS)
        .buttonStyle(TVNoHighlightButtonStyle())
        .tvFocusRingShape(.capsule)
        #else
        .buttonStyle(.plain)
        #endif
    }
}

/// Step indicator dots ("Step 1 of 3").
struct OnboardingStepDots: View {
    let current: Int
    let total: Int

    var body: some View {
        let tv = onboardingIsTV
        HStack(spacing: tv ? 10 : 6) {
            ForEach(1...total, id: \.self) { step in
                Capsule()
                    .fill(step == current ? Color.accentPrimary : Color.borderSubtle)
                    .frame(width: step == current ? (tv ? 28 : 18) : (tv ? 10 : 6),
                           height: tv ? 10 : 6)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Step \(current) of \(total)")
    }
}

// MARK: - tvOS Onboarding Components
#if os(tvOS)

/// Shared teal-tinted card background, matches the Settings pattern.
private func tvOnboardingCardBG(_ focused: Bool) -> some View {
    RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(focused ? Color.accentPrimary.opacity(0.18) : Color.cardBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.accentPrimary.opacity(focused ? 0.65 : 0.10),
                        lineWidth: focused ? 2.5 : 1)
        }
}

/// One category row in the onboarding "what should come in" sheet.
///
/// Deliberately NOT a raw SwiftUI `Toggle`. On tvOS a Toggle draws the
/// system focus platter - a pale slab that washed out both the white title
/// and the accent-tinted subtitle, so the focused row was the HARDEST one
/// to read (Logan 2026-08-10, from Apple TV screenshots). It also centers
/// its label's text, which is why the subtitles were centre-aligned under
/// left-aligned titles.
///
/// Same shape as `TVOnboardingImportButton` above: own the focus visual via
/// `tvOnboardingCardBG`, keep the text block left-aligned, and light the
/// On/Off indicator white while focused so it reads against the fill.
private struct TVOnboardingCategoryRow: View {
    let category: SyncCategory
    @Binding var isOn: Bool
    @FocusState private var isFocused: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentPrimary.opacity(0.15))
                        .frame(width: 44, height: 44)
                    Image(systemName: category.icon)
                        .scaledFont(.system(size: 20, weight: .medium))
                        .foregroundColor(.accentPrimary)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(category.displayName)
                        .scaledFont(.system(size: 24, weight: .semibold))
                        .foregroundColor(.textPrimary)
                    Text(category.briefSubtitle)
                        .scaledFont(.system(size: 18).subtext())
                        .foregroundColor(Color.contrastText(.textSecondary))
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    Circle()
                        .fill(isOn ? Color.accentPrimary : Color.textTertiary)
                        .frame(width: 10, height: 10)
                    Text(isOn ? "On" : "Off")
                        .scaledFont(.system(size: 24, weight: .semibold))
                        .foregroundColor(isOn
                            ? (isFocused ? .white : .accentPrimary)
                            : (isFocused ? .white : .textTertiary))
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .buttonStyle(TVNoHighlightButtonStyle())
        .focused($isFocused)
        .background(tvOnboardingCardBG(isFocused))
        .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}

/// Filled primary CTA for onboarding sheets. `.buttonStyle(.plain)` leaves
/// tvOS free to stack its own pale platter behind the gradient; this owns
/// the focus visual instead - the fill stays put and focus reads as a white
/// border plus a small grow, so the white label never loses contrast.
private struct TVOnboardingPrimaryButton: View {
    let title: String
    let action: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Text(title)
                .scaledFont(.system(size: 26, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 64)
                .background(LinearGradient.accentGradient)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(isFocused ? 0.9 : 0),
                                      lineWidth: 3)
                }
        }
        .buttonStyle(TVNoHighlightButtonStyle(drawsFocusRing: false))
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}

/// Secondary text button ("Not now"). Same treatment as
/// `TVOnboardingSkipButton` - tint on focus rather than letting tvOS drop a
/// light pill behind dim grey text, which is what made it unreadable
/// exactly when it was selected.
private struct TVOnboardingTextButton: View {
    let title: String
    let action: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(title, action: action)
            .scaledFont(.system(size: 22))
            .foregroundColor(isFocused ? .accentPrimary : .textTertiary)
            .buttonStyle(TVNoHighlightButtonStyle())
            .focused($isFocused)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}

/// "Skip for now" text button with subtle focus highlight.
private struct TVOnboardingSkipButton: View {
    let action: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button("Skip for now", action: action)
            .scaledFont(.system(size: 22))
            .foregroundColor(isFocused ? .accentPrimary : .textTertiary)
            .buttonStyle(TVNoHighlightButtonStyle())
            .focused($isFocused)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}

#endif

// MARK: - Onboarding Sync Category Chooser

/// Shown the moment the user opts into iCloud sync during setup, BEFORE the
/// first pull runs.
///
/// Discord (Glitzbr, 2026-08-10): he enabled sync on a second Apple TV and a
/// remote button map customised for a different-generation remote came down
/// with everything else. The per-category controls already existed, but they
/// live in Settings, and by the time you go looking for them the data has
/// already landed. Logan's call: ask during onboarding, when the answer still
/// changes the outcome.
///
/// Everything defaults ON, so the common case is one press. The toggles write
/// the same `syncEnabled.<rawValue>` defaults keys the Settings screen binds
/// to - one source of truth, and a choice made here shows up there.
struct OnboardingSyncCategoryChooser: View {
    let onContinue: () -> Void
    let onCancel: () -> Void

    /// Local until Continue, so backing out cannot leave a half-applied set.
    @State private var selection: [SyncCategory: Bool] = Dictionary(
        uniqueKeysWithValues: SyncCategory.allCases.map { ($0, $0.defaultEnabled) }
    )

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("What should come in from iCloud?")
                            .scaledFont(.headlineLarge)
                            .foregroundColor(.textPrimary)
                        Text("You can change any of this later in Settings, and each device chooses for itself.")
                            .scaledFont(.bodySmall.subtext())
                            .foregroundColor(Color.contrastText(.textSecondary))
                    }

                    // Rows sit directly on the sheet, each carrying its own
                    // card. They used to be dividers inside ANOTHER rounded
                    // card, which read as pills nested in a pill.
                    VStack(spacing: 8) {
                        ForEach(SyncCategory.allCases) { category in
                            let binding = Binding(
                                get: { selection[category] ?? category.defaultEnabled },
                                set: { selection[category] = $0 }
                            )
                            #if os(tvOS)
                            TVOnboardingCategoryRow(category: category, isOn: binding)
                            #else
                            Toggle(isOn: binding) {
                                SettingsRow(icon: category.icon,
                                            iconColor: .accentPrimary,
                                            title: category.displayName,
                                            subtitle: category.briefSubtitle)
                            }
                            .tint(.accentPrimary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.elevatedBackground)
                            )
                            #endif
                        }
                    }

                    VStack(spacing: 10) {
                        let commit = {
                            // Commit BEFORE the caller starts the pull.
                            for (category, isOn) in selection {
                                UserDefaults.standard.set(isOn, forKey: category.defaultsKey)
                            }
                            onContinue()
                        }
                        #if os(tvOS)
                        TVOnboardingPrimaryButton(title: "Turn On iCloud Sync", action: commit)
                        TVOnboardingTextButton(title: "Not now", action: onCancel)
                        #else
                        Button(action: commit) {
                            Text("Turn On iCloud Sync")
                                .scaledFont(.headlineMedium)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: 48)
                                .background(LinearGradient.accentGradient)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)

                        Button("Not now", action: onCancel)
                            .scaledFont(.bodyMedium)
                            .foregroundColor(.textTertiary)
                        #endif
                    }
                }
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
                .padding(24)
            }
        }
    }
}
