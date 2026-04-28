import SwiftUI

struct WelcomeView: View {
    @Binding var hasCompletedOnboarding: Bool
    @AppStorage("iCloudSyncEnabled") private var iCloudSyncEnabled = false
    @ObservedObject private var syncManager = SyncManager.shared
    #if os(iOS)
    /// Observe the live Location authorization status so the Home
    /// WiFi opt-in card updates the moment the user responds to the
    /// iOS permission prompt (button → "Allow" in the system dialog
    /// → card switches to "✓ Enabled"). Also handles the case where
    /// the user returns to onboarding after having previously
    /// granted or denied: the card renders the current state on
    /// first paint instead of forcing them to tap again.
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    #endif

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
                        FeaturePill(icon: "key.fill", title: "Dispatcharr Admin API Key")
                        FeaturePill(icon: "tv.and.hifispeaker.fill", title: "Xtream Codes")
                        FeaturePill(icon: "doc.text.fill", title: "M3U + EPG")
                    }
                    .padding(.bottom, 32)

                    // iCloud Sync / Import
                    TVOnboardingImportButton(
                        isEnabled: iCloudSyncEnabled,
                        isImporting: syncManager.isImporting,
                        onTap: {
                            iCloudSyncEnabled.toggle()
                            SyncManager.shared.syncSettingChanged(enabled: iCloudSyncEnabled)
                        }
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
                        FeaturePill(icon: "key.fill", title: "Dispatcharr Admin API Key")
                        FeaturePill(icon: "tv.and.hifispeaker.fill", title: "Xtream Codes")
                        FeaturePill(icon: "doc.text.fill", title: "M3U + EPG")
                    }
                    .padding(.bottom, 20)

                    // iCloud Sync opt-in
                    iCloudSyncToggle
                        .padding(.horizontal, 32)
                        .padding(.bottom, 12)

                    // Home WiFi (Location permission) opt-in — see
                    // `homeWiFiPermissionCard` for the full explainer.
                    // Placed here so users see it right next to the
                    // iCloud Sync toggle (both are optional privacy
                    // opt-ins) rather than having to discover it via
                    // a warning in Settings later. Hidden if the user
                    // has already responded (granted or denied) so we
                    // don't nag on repeat onboarding launches.
                    if networkMonitor.locationAuthStatus == .notDetermined {
                        homeWiFiPermissionCard
                            .padding(.horizontal, 32)
                            .padding(.bottom, 20)
                    } else {
                        // Keep the vertical rhythm consistent when the
                        // card is hidden — without this, the iCloud
                        // row butts right up against the CTA.
                        Spacer().frame(height: 8)
                    }

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
    }

    // MARK: - Default Live TV View Picker

    // MARK: - iCloud Import Button

    private var iCloudSyncToggle: some View {
        Button {
            guard !syncManager.isImporting else { return }
            iCloudSyncEnabled.toggle()
            SyncManager.shared.syncSettingChanged(enabled: iCloudSyncEnabled)
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

    #if os(iOS)
    // MARK: - Home WiFi Permission Card
    //
    // Shown during onboarding (on iOS only) while the user has not yet
    // made a decision on Location permission. The iOS WiFi APIs
    // (`NEHotspotNetwork.fetchCurrent` and `CNCopyCurrentNetworkInfo`)
    // are gated by Apple behind Location auth — there is no "just let
    // me read the SSID" permission. Surfacing the request here, with
    // an explainer, is far better UX than letting the user stumble
    // into the yellow Settings warning and then hunt through iOS
    // Settings to fix it. Hidden when auth is already determined
    // (granted or denied) so the card doesn't become a nag.
    @ViewBuilder
    private var homeWiFiPermissionCard: some View {
        Button {
            networkMonitor.requestLocationAuthorization()
            // The button intentionally doesn't flip any local state —
            // the card re-renders when `networkMonitor.locationAuthStatus`
            // changes, which happens automatically via the
            // `@Published` property once the user responds to the
            // iOS system prompt.
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentPrimary.opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: "wifi")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.accentPrimary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Detect Home WiFi")
                        .font(.headlineSmall)
                        .foregroundColor(.textPrimary)
                    Text("Let Aerio recognise your home network and automatically use the server's local URL when you're on it. iOS requires Location permission to read the WiFi name.")
                        .font(.bodySmall)
                        .foregroundColor(.textSecondary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.textTertiary)
            }
            .padding(12)
            .background(Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.borderSubtle, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
    #endif
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
        .scaleEffect(isFocused ? 1.02 : 1.0)
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
        .scaleEffect(isFocused ? 1.05 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}

/// Primary or secondary navigation button with teal focus card.
private struct TVOnboardingNavButton<Destination: View>: View {
    let destination: Destination
    let icon: String
    let label: String
    let isPrimary: Bool
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                Text(label)
                    .font(.system(size: 26, weight: .semibold))
            }
            .foregroundColor(isPrimary ? .white : .textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 66)
            .background(
                isPrimary
                    ? AnyView(LinearGradient.accentGradient)
                    : AnyView(Color.elevatedBackground)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        isFocused ? Color.accentPrimary : (isPrimary ? Color.clear : Color.borderMedium),
                        lineWidth: isFocused ? 2.5 : 1
                    )
            )
        }
        .buttonStyle(TVNoHighlightButtonStyle())
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.02 : 1.0)
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
