import SwiftUI
import SwiftData

@main
struct DispatcharrApp: App {
    var body: some Scene {
        WindowGroup {
            AppEntryView()
                .environmentObject(ThemeManager.shared)
        }
        .modelContainer(for: [
            ServerConnection.self,
            ChannelGroup.self,
            Channel.self,
            EPGProgram.self,
            M3UPlaylist.self,
            EPGSource.self
        ])
    }
}

// MARK: - App Entry View (Splash → Root)
struct AppEntryView: View {
    @State private var splashFinished = false

    var body: some View {
        ZStack {
            if splashFinished {
                RootView()
                    .transition(.opacity)
            } else {
                SplashView(isFinished: $splashFinished)
                    .transition(.opacity)
            }
        }
        .animation(.easeIn(duration: 0.3), value: splashFinished)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Root View (Handles Onboarding)
struct RootView: View {
    @Query private var servers: [ServerConnection]
    @Query private var playlists: [M3UPlaylist]
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    private var hasAnySource: Bool {
        !servers.isEmpty || !playlists.isEmpty
    }

    var body: some View {
        Group {
            if !hasCompletedOnboarding && !hasAnySource {
                NavigationStack {
                    WelcomeView(hasCompletedOnboarding: $hasCompletedOnboarding)
                }
            } else {
                MainTabView()
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: servers.count) { _, count in
            if count > 0 { hasCompletedOnboarding = true }
        }
        .onChange(of: playlists.count) { _, count in
            if count > 0 { hasCompletedOnboarding = true }
        }
    }
}
