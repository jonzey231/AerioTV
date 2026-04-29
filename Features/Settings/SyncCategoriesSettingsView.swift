//  SyncCategoriesSettingsView.swift
//  Aerio
//
//  v1.6.17 — granular per-data-type iCloud sync controls.
//
//  Anchored from the iCloud Sync section of the main SettingsView.
//  Each row pairs a "Sync this category" toggle with a destructive
//  "Delete from iCloud" action. The master `iCloudSyncEnabled`
//  toggle still gates everything; when it's off, every row here is
//  disabled but the user can still hit Delete to scrub stale cloud
//  state per category.

import SwiftUI
import SwiftData

struct SyncCategoriesSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var servers: [ServerConnection]
    @ObservedObject private var theme = ThemeManager.shared
    @AppStorage("iCloudSyncEnabled") private var iCloudSyncEnabled = true

    // One @AppStorage per category — written through SyncCategory.defaultsKey,
    // round-trips via SyncManager.buildPreferencesDict so a flip on one
    // device propagates to the user's other devices.
    @AppStorage(SyncCategory.servers.defaultsKey)       private var syncServers = true
    @AppStorage(SyncCategory.watchProgress.defaultsKey) private var syncWatchProgress = true
    @AppStorage(SyncCategory.reminders.defaultsKey)     private var syncReminders = true
    @AppStorage(SyncCategory.preferences.defaultsKey)   private var syncPreferences = true
    @AppStorage(SyncCategory.credentials.defaultsKey)   private var syncCredentials = true

    /// The category whose Delete confirmation is currently being shown.
    @State private var pendingDeleteCategory: SyncCategory? = nil

    /// Set when a delete completes — drives the toast confirmation.
    @State private var lastDeletedCategory: SyncCategory? = nil
    @State private var showDeletedToast = false

    private func binding(for category: SyncCategory) -> Binding<Bool> {
        switch category {
        case .servers:       return $syncServers
        case .watchProgress: return $syncWatchProgress
        case .reminders:     return $syncReminders
        case .preferences:   return $syncPreferences
        case .credentials:   return $syncCredentials
        }
    }

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            #if os(tvOS)
            tvOSBody
            #else
            iOSBody
            #endif
        }
        .navigationTitle("Sync Categories")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .alert(
            pendingDeleteCategory.map { "Remove \($0.displayName) from iCloud?" } ?? "",
            isPresented: Binding(
                get: { pendingDeleteCategory != nil },
                set: { if !$0 { pendingDeleteCategory = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let category = pendingDeleteCategory {
                    SyncManager.shared.clearCloudCategory(category, localServers: servers)
                    lastDeletedCategory = category
                    pendingDeleteCategory = nil
                    withAnimation(.easeInOut(duration: 0.2)) { showDeletedToast = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        withAnimation(.easeInOut(duration: 0.2)) { showDeletedToast = false }
                    }
                }
            }
            Button("Cancel", role: .cancel) { pendingDeleteCategory = nil }
        } message: {
            if let category = pendingDeleteCategory {
                Text("This will remove your \(category.displayName) from iCloud. Other devices will keep their local copy.")
            }
        }
        .overlay(alignment: .bottom) {
            if showDeletedToast, let category = lastDeletedCategory {
                Text("\(category.displayName) removed from iCloud")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Capsule().fill(Color.statusLive))
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: - iOS Body
    #if os(iOS)
    private var iOSBody: some View {
        List {
            Section {
                ForEach(SyncCategory.allCases) { category in
                    iOSRow(for: category)
                        .listRowBackground(Color.cardBackground)
                }
            } header: {
                Text("Categories").sectionHeaderStyle()
            } footer: {
                Text(footerText)
                    .font(.labelSmall).foregroundColor(.textTertiary)
            }
            .listSectionSeparator(.hidden)
        }
        .scrollContentBackground(.hidden)
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func iOSRow(for category: SyncCategory) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: binding(for: category)) {
                SettingsRow(icon: category.icon, iconColor: theme.accent,
                            title: category.displayName,
                            subtitle: category.subtitle)
            }
            .tint(theme.accent)
            .disabled(!iCloudSyncEnabled)
            .opacity(iCloudSyncEnabled ? 1.0 : 0.5)

            HStack {
                Spacer()
                Button(role: .destructive) {
                    pendingDeleteCategory = category
                } label: {
                    Label("Delete from iCloud", systemImage: "icloud.slash")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }
    #endif

    // MARK: - tvOS Body
    #if os(tvOS)
    private var tvOSBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                tvSection("Categories") {
                    ForEach(SyncCategory.allCases) { category in
                        TVSettingsToggleRow(
                            icon: category.icon,
                            iconColor: theme.accent,
                            title: category.displayName,
                            subtitle: category.subtitle,
                            isOn: binding(for: category)
                        ) { _ in }
                        .disabled(!iCloudSyncEnabled)
                        .opacity(iCloudSyncEnabled ? 1.0 : 0.5)
                    }
                }

                tvSection("Delete from iCloud") {
                    ForEach(SyncCategory.allCases) { category in
                        TVSettingsActionRow(
                            icon: "icloud.slash",
                            label: "Delete \(category.displayName)",
                            isDestructive: true,
                            action: { pendingDeleteCategory = category }
                        )
                    }
                }

                Text(footerText)
                    .font(.footnote)
                    .foregroundColor(.textTertiary)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 32)
            }
            .padding(.horizontal, 60)
            .padding(.top, 32)
        }
    }

    @ViewBuilder
    private func tvSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundColor(.textSecondary)
                .padding(.leading, 12)
            VStack(spacing: 0) { content() }
                .background(Color.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
    #endif

    // MARK: - Copy

    private var footerText: String {
        if iCloudSyncEnabled {
            return "Each toggle controls whether this device pushes and pulls that category to iCloud. The category-toggle states themselves sync across your devices, so flipping one here will reach your other Apple-ID-signed-in devices. Use the Delete buttons to remove a category's cloud copy without affecting local data."
        } else {
            return "iCloud Sync is off. Per-category toggles take effect when you re-enable Sync at the top. The Delete buttons still work — useful for scrubbing stale iCloud state before re-enabling Sync."
        }
    }
}
