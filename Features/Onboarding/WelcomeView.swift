import SwiftUI

struct WelcomeView: View {
    @Binding var hasCompletedOnboarding: Bool

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

            VStack(spacing: 0) {
                Spacer()

                // Logo / Icon
                ZStack {
                    Circle()
                        .fill(LinearGradient.accentGradient)
                        .frame(width: 90, height: 90)
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundColor(.white)
                }
                .shadow(color: Color.accentPrimary.opacity(0.4), radius: 20, y: 8)
                .padding(.bottom, 32)

                // Title
                VStack(spacing: 6) {
                    Text("Dispatcharr")
                        .font(.displayLarge)
                        .foregroundColor(.textPrimary)
                    Text("Your IPTV & Media Hub")
                        .font(.bodyLarge)
                        .foregroundColor(.textSecondary)
                    Text("iPhone, iPad, Apple TV, & Mac")
                        .font(.bodySmall)
                        .foregroundColor(.textTertiary)
                }
                .padding(.bottom, 48)

                // Feature Pills
                VStack(spacing: 12) {
                    FeaturePill(icon: "key.fill",
                                title: "Dispatcharr API",
                                detail: "Dispatcharr native API — connect with a personal API key")
                    FeaturePill(icon: "tv.and.hifispeaker.fill",
                                title: "Xtream Codes",
                                detail: "Live TV + VOD with any Xtream provider")
                    FeaturePill(icon: "doc.text.fill",
                                title: "M3U + EPG",
                                detail: "Any M3U playlist URL or file")
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 56)

                Spacer()

                // CTA
                VStack(spacing: 12) {
                    NavigationLink(destination: AddServerView()) {
                        HStack(spacing: 8) {
                            Image(systemName: "server.rack")
                                .font(.system(size: 16, weight: .semibold))
                            Text("Connect a Server")
                                .font(.headlineMedium)
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(LinearGradient.accentGradient)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    NavigationLink(destination: M3UImportView()) {
                        HStack(spacing: 8) {
                            Image(systemName: "list.bullet.rectangle.fill")
                                .font(.system(size: 16, weight: .semibold))
                            Text("Import M3U Playlist")
                                .font(.headlineMedium)
                        }
                        .foregroundColor(.textPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(Color.elevatedBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.borderMedium, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)

                    Button("Skip for now") {
                        hasCompletedOnboarding = true
                    }
                    .font(.bodyMedium)
                    .foregroundColor(.textTertiary)
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 48)
            }
        }
        .navigationBarHidden(true)
    }
}

// MARK: - Feature Pill
private struct FeaturePill: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient.accentGradient.opacity(0.2))
                    .frame(width: 42, height: 42)
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(LinearGradient.accentGradient)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headlineSmall)
                    .foregroundColor(.textPrimary)
                Text(detail)
                    .font(.bodySmall)
                    .foregroundColor(.textSecondary)
            }

            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundColor(.accentSecondary)
        }
        .padding(14)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.borderSubtle, lineWidth: 1)
        )
    }
}
