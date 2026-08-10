import SwiftUI

struct WelcomeView: View {
    @Binding var hasCompletedOnboarding: Bool
    @AppStorage("iCloudSyncEnabled") private var iCloudSyncEnabled = false
    @ObservedObject private var syncManager = SyncManager.shared

    /// Discord (Glitzbr): he turned iCloud sync on during setup and a
    /// customised remote map from a different-generation Apple TV landed on
    /// this one. By the time he found the Sync Categories screen the data had
    /// already arrived, so the choice has to be offered BEFORE the first pull
    /// - which is what this sheet does. Logan 2026-08-10.
    @State private var showCategoryChooser = false

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            // Background gradient orbs
            GeometryReader { geo in
                Circle()
                    .fill(Color.accentPrimary.opacity(0.12))
                    .frame(width: 400, height: 400)
                    .blur(radius: 80)
                    .offset(x: -100, y: -80)

                Circle()
                    .fill(Color.accentSecondary.opacity(0.10))
                    .frame(width: 300, height: 300)
                    .blur(radius: 60)
                    .offset(x: geo.size.width - 150, y: geo.size.height - 200)
            }
            .ignoresSafeArea()

            #if os(tvOS)
            // tvOS: single centred column, max width so it breathes on a large display
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    // Branding
                    Image("AerioLogo")
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 90, height: 90)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .shadow(color: Color(hex: "1AC4D8").opacity(0.5), radius: 28, y: 8)
                        .padding(.bottom, 24)
                        .padding(.top, 60)

                    Text("AerioTV")
                        .font(.system(size: 60, weight: .bold))
                        .foregroundColor(.textPrimary)
                    Text("Your IPTV & Media Hub")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundColor(.textSecondary)
                        .padding(.bottom, 6)
                    Text("iPhone · iPad · Apple TV · Mac")
                        .font(.system(size: 20))
                        .foregroundColor(.textTertiary)
                        .padding(.bottom, 40)

                    // Supported source types
                    VStack(spacing: 10) {
                        FeaturePill(icon: "key.fill", title: "Dispatcharr Direct Connect")
                        FeaturePill(icon: "tv.and.hifispeaker.fill", title: "Xtream Codes")
                        FeaturePill(icon: "doc.text.fill", title: "M3U + EPG")
                    }
                    .padding(.bottom, 32)

                    // iCloud Sync / Import
                    TVOnboardingImportButton(
                        isEnabled: iCloudSyncEnabled,
                        isImporting: syncManager.isImporting,
                        onTap: { toggleICloudSync() }
                    )
                    .padding(.bottom, 28)

                    // Action buttons
                    TVOnboardingNavButton(
                        destination: AddServerView(),
                        icon: "server.rack",
                        label: "Connect a Server",
                        isPrimary: true
                    )
                    .padding(.bottom, 10)

                    TVOnboardingSkipButton {
                        hasCompletedOnboarding = true
                    }
                    .padding(.bottom, 60)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
            }
            #else
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    // Logo / Icon
                    Image("AerioLogo")
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 80, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .shadow(color: Color(hex: "1AC4D8").opacity(0.45), radius: 20, y: 8)
                        .padding(.top, 16)
                        .padding(.bottom, 20)

                    // Title
                    VStack(spacing: 4) {
                        Text("AerioTV")
                            .font(.displayLarge)
                            .foregroundColor(.textPrimary)
                        Text("Your IPTV & Media Hub")
                            .font(.bodyLarge)
                            .foregroundColor(.textSecondary)
                        Text("iPhone, iPad, Apple TV, & Mac")
                            .font(.bodySmall)
                            .foregroundColor(.textTertiary)
                    }
                    .padding(.bottom, 24)

                    // Supported source types
                    VStack(spacing: 8) {
                        FeaturePill(icon: "key.fill", title: "Dispatcharr Direct Connect")
                        FeaturePill(icon: "tv.and.hifispeaker.fill", title: "Xtream Codes")
                        FeaturePill(icon: "doc.text.fill", title: "M3U + EPG")
                    }
                    .padding(.bottom, 20)

                    // iCloud Sync opt-in
                    iCloudSyncToggle
                        .padding(.horizontal, 32)
                        .padding(.bottom, 12)

                    // Keep the vertical rhythm between the iCloud row
                    // and the CTA below.
                    Spacer().frame(height: 8)

                    // CTA
                    VStack(spacing: 10) {
                        NavigationLink(destination: AddServerView()) {
                            HStack(spacing: 8) {
                                Image(systemName: "server.rack")
                                    .font(.system(size: 15, weight: .semibold))
                                Text("Connect a Server")
                                    .font(.headlineMedium)
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(LinearGradient.accentGradient)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)

                        Button("Skip for now") {
                            hasCompletedOnboarding = true
                        }
                        .font(.bodyMedium)
                        .foregroundColor(.textTertiary)
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 32)
                }
                .frame(maxWidth: .infinity)
            }
            #endif
        }
        .navigationBarHidden(true)
        .sheet(isPresented: $showCategoryChooser) {
            OnboardingSyncCategoryChooser(
                onContinue: {
                    showCategoryChooser = false
                    // Only NOW does anything come down: the categories the
                    // user just chose are already written, and
                    // syncSettingChanged is what kicks off the first pull.
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

    // MARK: - Default Live TV View Picker

    // MARK: - iCloud Import Button

    private var iCloudSyncToggle: some View {
        Button {
            guard !syncManager.isImporting else { return }
            toggleICloudSync()
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentPrimary.opacity(0.15))
                        .frame(width: 36, height: 36)
                    if syncManager.isImporting {
                        ProgressView()
                            .tint(.accentPrimary)
                    } else {
                        Image(systemName: iCloudSyncEnabled ? "checkmark.icloud.fill" : "icloud.fill")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.accentPrimary)
                    }
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(syncManager.isImporting ? "Importing from iCloud…"
                         : iCloudSyncEnabled ? "iCloud Sync Enabled"
                         : "Sync via iCloud")
                        .font(.headlineSmall)
                        .foregroundColor(.textPrimary)
                    Text(syncManager.isImporting ? "Looking for an existing configuration…"
                         : iCloudSyncEnabled
                         ? "Settings synced across all your devices"
                         : "Use if you've enabled Aerio iCloud sync on another device")
                        .font(.bodySmall)
                        .foregroundColor(.textSecondary)
                        .lineLimit(2)
                }

                Spacer()

                if syncManager.isImporting {
                    ProgressView()
                        .tint(.accentPrimary)
                } else {
                    Image(systemName: iCloudSyncEnabled ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20))
                        .foregroundColor(iCloudSyncEnabled ? .accentPrimary : .textTertiary)
                }
            }
            .padding(12)
            .background(Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(iCloudSyncEnabled ? Color.accentPrimary.opacity(0.4) : Color.borderSubtle, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(syncManager.isImporting)
    }
}

// MARK: - tvOS Onboarding Components
#if os(tvOS)

/// Shared teal-tinted card background — matches the Settings pattern.
private func tvOnboardingCardBG(_ focused: Bool) -> some View {
    RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(focused ? Color.accentPrimary.opacity(0.18) : Color.cardBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.accentPrimary.opacity(focused ? 0.65 : 0.10),
                        lineWidth: focused ? 2.5 : 1)
        }
}

/// Non-interactive feature row — no card background, border, or checkmark
/// so it reads as informational text, not a focusable button.
private struct TVFeatureRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(LinearGradient.accentGradient)
                .frame(width: 28)

            Text(title)
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(.textPrimary)

            Text("·")
                .font(.system(size: 24))
                .foregroundColor(.textTertiary)

            Text(detail)
                .font(.system(size: 20))
                .foregroundColor(.textTertiary)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
    }
}

/// iCloud import/sync button for onboarding — toggles on/off with importing state.
private struct TVOnboardingImportButton: View {
    let isEnabled: Bool
    var isImporting: Bool = false
    let onTap: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button {
            guard !isImporting else { return }
            onTap()
        } label: {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentPrimary.opacity(0.15))
                        .frame(width: 44, height: 44)
                    if isImporting {
                        ProgressView()
                            .tint(.accentPrimary)
                    } else {
                        Image(systemName: isEnabled ? "checkmark.icloud.fill" : "icloud.fill")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundColor(.accentPrimary)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(isImporting ? "Importing from iCloud…"
                         : isEnabled ? "iCloud Sync Enabled"
                         : "Sync via iCloud")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(.textPrimary)
                    Text(isImporting ? "Looking for an existing configuration…"
                         : isEnabled
                         ? "Settings will stay in sync across all your devices"
                         : "Import an existing Aerio configuration from iCloud and keep settings in sync across all devices using the same Apple ID")
                        .font(.system(size: 18))
                        .foregroundColor(.textSecondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if isImporting {
                    ProgressView()
                        .tint(.accentPrimary)
                } else {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(isEnabled ? Color.accentPrimary : Color.textTertiary)
                            .frame(width: 10, height: 10)
                        Text(isEnabled ? "On" : "Off")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundColor(isEnabled
                                ? (isFocused ? .white : .accentPrimary)
                                : (isFocused ? .white : .textTertiary))
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .buttonStyle(TVNoHighlightButtonStyle())
        .focused($isFocused)
        .disabled(isImporting)
        .background(tvOnboardingCardBG(isFocused))
        .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}

/// Segmented picker row — each option is a separate focusable button.
private struct TVOnboardingPickerRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let options: [(value: String, label: String)]
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentPrimary.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.accentPrimary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.textPrimary)
                Text(subtitle)
                    .font(.system(size: 18))
                    .foregroundColor(.textSecondary)
            }
            Spacer()
            HStack(spacing: 8) {
                ForEach(options, id: \.value) { option in
                    TVOnboardingPickerOption(
                        label: option.label,
                        isSelected: selection == option.value,
                        onSelect: { selection = option.value }
                    )
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.borderSubtle, lineWidth: 1)
        )
    }
}

private struct TVOnboardingPickerOption: View {
    let label: String
    let isSelected: Bool
    let onSelect: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: onSelect) {
            Text(label)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(isSelected ? .white : (isFocused ? .white : .textSecondary))
                .frame(width: 100, height: 44)
                .background(
                    isSelected
                        ? AnyView(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(LinearGradient.accentGradient))
                        : AnyView(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isFocused ? Color.accentPrimary.opacity(0.25) : Color.elevatedBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.accentPrimary.opacity(isFocused ? 0.65 : 0.15), lineWidth: isFocused ? 2 : 1)
                )
        }
        .buttonStyle(TVNoHighlightButtonStyle())
        .focused($isFocused)
        .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}

/// Onboarding navigation card. Same card shape as
/// `TVOnboardingImportButton` so the welcome screen reads as a column
/// of matching pill rows. v1.6.21: previously a filled-gradient
/// primary CTA; reshaped to the outlined card style after user
/// feedback that the two onboarding rows should look like siblings.
/// The icon stays in the leading 44pt tile, the title fills the
/// middle, and a chevron sits on the right matching the action-row
/// pattern used elsewhere in Settings.
private struct TVOnboardingNavButton<Destination: View>: View {
    let destination: Destination
    let icon: String
    let label: String
    /// Retained as a parameter for source compatibility with the
    /// pre-v1.6.21 callsite in this file. Both modes now render
    /// the same card style; the parameter is reserved for future
    /// use (e.g., emphasising one row over another with a slightly
    /// brighter accent) but currently has no visual effect.
    let isPrimary: Bool
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentPrimary.opacity(0.15))
                        .frame(width: 44, height: 44)
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.accentPrimary)
                }
                Text(label)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(isFocused ? .accentPrimary : .textTertiary)
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
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.accentPrimary)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(category.displayName)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(.textPrimary)
                    Text(category.briefSubtitle)
                        .font(.system(size: 18))
                        .foregroundColor(.textSecondary)
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    Circle()
                        .fill(isOn ? Color.accentPrimary : Color.textTertiary)
                        .frame(width: 10, height: 10)
                    Text(isOn ? "On" : "Off")
                        .font(.system(size: 24, weight: .semibold))
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
                .font(.system(size: 26, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 64)
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
            .font(.system(size: 22))
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
            .font(.system(size: 22))
            .foregroundColor(isFocused ? .accentPrimary : .textTertiary)
            .buttonStyle(TVNoHighlightButtonStyle())
            .focused($isFocused)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}

#endif

// MARK: - Feature Bullet
/// Non-interactive feature row — intentionally styled without card backgrounds,
/// borders, or trailing chevrons/checkmarks so it reads as informational text,
/// not a tappable button.
private struct FeaturePill: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(LinearGradient.accentGradient)
                .frame(width: 24)

            Text(title)
                .font(.headlineSmall)
                .foregroundColor(.textPrimary)
        }
        .padding(.vertical, 4)
    }
}

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
        uniqueKeysWithValues: SyncCategory.allCases.map { ($0, true) }
    )

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("What should come in from iCloud?")
                            .font(.headlineLarge)
                            .foregroundColor(.textPrimary)
                        Text("You can change any of this later in Settings, and each device chooses for itself.")
                            .font(.bodySmall)
                            .foregroundColor(.textSecondary)
                    }

                    // Rows sit directly on the sheet, each carrying its own
                    // card. They used to be dividers inside ANOTHER rounded
                    // card, which read as pills nested in a pill.
                    VStack(spacing: 8) {
                        ForEach(SyncCategory.allCases) { category in
                            let binding = Binding(
                                get: { selection[category] ?? true },
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
                                .font(.headlineMedium)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                                .background(LinearGradient.accentGradient)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)

                        Button("Not now", action: onCancel)
                            .font(.bodyMedium)
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
