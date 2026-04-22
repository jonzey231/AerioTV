import SwiftUI

/// In-app banner that slides down from the top when a program reminder fires
/// while the app is in the foreground. Auto-dismisses after 8 seconds.
struct ReminderBannerView: View {
    @ObservedObject private var reminderManager = ReminderManager.shared
    @State private var dismissTask: Task<Void, Never>?

    var body: some View {
        if let banner = reminderManager.pendingBanner {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    // Bell icon
                    ZStack {
                        Circle()
                            .fill(Color.accentPrimary.opacity(0.2))
                            .frame(width: 40, height: 40)
                        Image(systemName: "bell.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.accentPrimary)
                    }

                    // Title + subtitle
                    VStack(alignment: .leading, spacing: 2) {
                        Text(banner.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.textPrimary)
                            .lineLimit(1)

                        HStack(spacing: 4) {
                            Text("Starting in 5 min")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.textSecondary)
                            if !banner.channel.isEmpty {
                                Text("on")
                                    .font(.system(size: 12))
                                    .foregroundColor(.textTertiary)
                                Text(banner.channel)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.accentPrimary)
                            }
                        }
                        .lineLimit(1)
                    }

                    Spacer()

                    // Dismiss button
                    Button {
                        dismissBanner()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.textTertiary)
                            .frame(width: 28, height: 28)
                            .background(Color.elevatedBackground, in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.white.opacity(0.1), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
                )
                .padding(.horizontal, 16)
                #if os(iOS)
                .padding(.top, topSafeAreaInset + 4)
                #else
                .padding(.top, 40)
                #endif

                Spacer()
            }
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: reminderManager.pendingBanner)
            .onTapGesture { dismissBanner() }
            .onAppear { scheduleAutoDismiss() }
            .onDisappear {
                // Don't let an orphaned sleep task fire dismissBanner() after
                // the view has already been removed from the hierarchy.
                dismissTask?.cancel()
                dismissTask = nil
            }
            .onChange(of: reminderManager.pendingBanner) { _, newValue in
                if newValue != nil { scheduleAutoDismiss() }
            }
            .allowsHitTesting(true)
            .zIndex(100)
        }
    }

    private func dismissBanner() {
        dismissTask?.cancel()
        withAnimation(.easeOut(duration: 0.25)) {
            reminderManager.pendingBanner = nil
        }
    }

    private func scheduleAutoDismiss() {
        dismissTask?.cancel()
        dismissTask = Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000) // 8 seconds
            guard !Task.isCancelled else { return }
            await MainActor.run { dismissBanner() }
        }
    }

    #if os(iOS)
    private var topSafeAreaInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?
            .safeAreaInsets.top ?? 44
    }
    #endif
}
