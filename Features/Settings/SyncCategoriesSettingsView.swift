//  SyncCategoriesSettingsView.swift
//  Aerio
//
//  v1.6.17, granular per-data-type iCloud sync controls.
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
    @AppStorage("iCloudSyncEnabled") private var iCloudSyncEnabled = iCloudSyncEnabledDefault

    // One @AppStorage per category, written through SyncCategory.defaultsKey,
    // round-trips via SyncManager.buildPreferencesDict so a flip on one
    // device propagates to the user's other devices.
    @AppStorage(SyncCategory.servers.defaultsKey)       private var syncServers = true
    @AppStorage(SyncCategory.watchProgress.defaultsKey) private var syncWatchProgress = true
    @AppStorage(SyncCategory.reminders.defaultsKey)     private var syncReminders = true
    @AppStorage(SyncCategory.preferences.defaultsKey)   private var syncPreferences = true
    @AppStorage(SyncCategory.remoteControl.defaultsKey) private var syncRemoteControl = true
    @AppStorage(SyncCategory.credentials.defaultsKey)   private var syncCredentials = true
    // Default OFF: a per-device choice unless the user opts in.
    @AppStorage(SyncCategory.radioModeDefault.defaultsKey) private var syncRadioModeDefault = false

    /// The category whose Delete confirmation is currently being shown.
    @State private var pendingDeleteCategory: SyncCategory? = nil

    /// Set when a delete completes, drives the toast confirmation.
    @State private var lastDeletedCategory: SyncCategory? = nil
    @State private var showDeletedToast = false

    private func binding(for category: SyncCategory) -> Binding<Bool> {
        switch category {
        case .servers:       return $syncServers
        case .watchProgress: return $syncWatchProgress
        case .reminders:     return $syncReminders
        case .preferences:   return $syncPreferences
        case .remoteControl: return $syncRemoteControl
        case .radioModeDefault: return $syncRadioModeDefault
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
        #else
        // tvOS draws `.navigationTitle` as an oversized system title that
        // sits OVER the scrolling rows (Logan's Apple TV pass 2026-09-19
        // caught "Sync Categories" printed across the middle of the list).
        // Every other tvOS Settings page hides the bar and draws its own
        // heading; this pushed page was the one that did not.
        .toolbar(.hidden, for: .navigationBar)
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
                    .scaledFont(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Capsule().fill(Color.statusLive))
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: - Per-item rows

    /// Bumped after every scope or toggle write so rows re-read
    /// UserDefaults (the items have no @AppStorage of their own).
    @State private var revision = 0

    private static let scopeOptions: [SettingsChoice<String>] = SyncScope.offeredCases.map {
        SettingsChoice($0.rawValue, $0.title)
    }

    private func groupScopeBinding(_ group: SyncItemGroup) -> Binding<String> {
        Binding(
            get: {
                _ = revision
                let scopes = Set(group.items.filter { !$0.isData }.map(\.storedScope))
                return scopes.count == 1 ? scopes.first!.rawValue : "mixed"
            },
            set: { raw in
                guard let scope = SyncScope(rawValue: raw) else { return }
                for item in group.items where !item.isData { item.setScope(scope) }
                didChangeItems()
            }
        )
    }

    private func itemScopeBinding(_ item: SyncItem) -> Binding<String> {
        Binding(
            get: { _ = revision; return item.storedScope.rawValue },
            set: { raw in
                guard let scope = SyncScope(rawValue: raw) else { return }
                item.setScope(scope)
                didChangeItems()
            }
        )
    }

    private func itemToggleBinding(_ item: SyncItem) -> Binding<Bool> {
        Binding(
            get: { _ = revision; return item.storedScope != .off },
            set: { on in
                item.setScope(on ? .all : .off)
                didChangeItems()
            }
        )
    }

    private func didChangeItems() {
        SyncItemCatalog.syncPreferencesCategoryFlag()
        revision += 1
        SyncManager.shared.pushPreferences()
    }

    private var settingsGroups: [SyncItemGroup] {
        SyncItemCatalog.groups.filter { $0.items.contains { !$0.isData } }
    }

    /// Data rows: the data group plus data items living in settings groups
    /// (Remote Button Map sits with Remote Control).
    private var dataItems: [SyncItem] {
        SyncItemCatalog.groups.flatMap { $0.items.filter(\.isData) }
    }

    private var scopeFooter: String {
        #if os(tvOS)
        "All devices syncs the setting everywhere. TVs only syncs it between your Apple TVs and starts from this TV's current value. Off keeps it on this device. These choices apply to this device only."
        #else
        "All devices syncs the setting everywhere. Phones and tablets only syncs it between your iPhones and iPads and starts from this device's current value. Off keeps it on this device. These choices apply to this device only."
        #endif
    }

    // MARK: - iOS Body
    #if os(iOS)
    private var iOSBody: some View {
        List {
            ForEach(settingsGroups) { group in
                Section {
                    SettingsChoicePicker("All \(group.title) Settings",
                                         options: Self.scopeOptions,
                                         selection: groupScopeBinding(group),
                                         footer: scopeFooter,
                                         unmatchedTitle: "Mixed")
                        .listRowBackground(Color.cardBackground)
                    ForEach(group.items.filter { !$0.isData }) { item in
                        SettingsChoicePicker(item.label,
                                             options: Self.scopeOptions,
                                             selection: itemScopeBinding(item),
                                             footer: scopeFooter)
                            .listRowBackground(Color.cardBackground)
                    }
                } header: {
                    Text(group.title).sectionHeaderStyle()
                }
                .disabled(!iCloudSyncEnabled)
                .opacity(iCloudSyncEnabled ? 1.0 : 0.5)
            }
            Section {
                ForEach(dataItems) { item in
                    Toggle(isOn: itemToggleBinding(item)) {
                        Text(item.label).scaledFont(.bodyMedium).foregroundColor(.textPrimary)
                    }
                    .tint(theme.accent)
                    .listRowBackground(Color.cardBackground)
                }
            } header: {
                Text("Your Data").sectionHeaderStyle()
            }
            .disabled(!iCloudSyncEnabled)
            .opacity(iCloudSyncEnabled ? 1.0 : 0.5)

            Section {
                ForEach(SyncCategory.allCases) { category in
                    Button(role: .destructive) {
                        pendingDeleteCategory = category
                    } label: {
                        Label("Delete \(category.displayName)", systemImage: "icloud.slash")
                            .scaledFont(.bodyMedium)
                    }
                    .tint(.red)
                    .listRowBackground(Color.cardBackground)
                }
            } header: {
                Text("Delete from iCloud").sectionHeaderStyle()
            } footer: {
                Text(footerText)
                    .scaledFont(.labelSmall.subtext()).foregroundColor(Color.contrastText(.textTertiary))
            }
            .listSectionSeparator(.hidden)
        }
        .scrollContentBackground(.hidden)
        // Phase 3 (Logan 2026-09-18): floating tab bar parity -
        // content runs under the bar, the bar tucks away on scroll,
        // and the last row clears it.
        .settingsPhoneTabBarChrome()
        .listStyle(.insetGrouped)
    }
    #endif

    // MARK: - tvOS Body
    #if os(tvOS)
    private var tvOSBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                // Own heading, now that the system bar is hidden above.
                Text("Sync Categories")
                    .scaledFont(.system(size: 38, weight: .semibold))
                    .foregroundColor(.textPrimary)
                    .padding(.horizontal, 24)

                ForEach(settingsGroups) { group in
                    SettingsSection(group.title, style: .compactCard) {
                        SettingsChoicePicker("All \(group.title) Settings",
                                             options: Self.scopeOptions,
                                             selection: groupScopeBinding(group),
                                             footer: scopeFooter,
                                             unmatchedTitle: "Mixed")
                        ForEach(group.items.filter { !$0.isData }) { item in
                            SettingsChoicePicker(item.label,
                                                 options: Self.scopeOptions,
                                                 selection: itemScopeBinding(item),
                                                 footer: scopeFooter)
                        }
                    }
                    .disabled(!iCloudSyncEnabled)
                    .opacity(iCloudSyncEnabled ? 1.0 : 0.5)
                }

                SettingsSection("Your Data", style: .compactCard) {
                    ForEach(dataItems) { item in
                        TVSettingsToggleRow(
                            icon: "icloud",
                            iconColor: theme.accent,
                            title: item.label,
                            subtitle: "",
                            isOn: itemToggleBinding(item)
                        ) { _ in }
                    }
                }
                .disabled(!iCloudSyncEnabled)
                .opacity(iCloudSyncEnabled ? 1.0 : 0.5)

                SettingsSection("Delete from iCloud", style: .compactCard) {
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
                    .scaledFont(.footnote.subtext())
                    .foregroundColor(Color.contrastText(.textTertiary))
                    .padding(.horizontal, 24)
                    .padding(.bottom, 32)
            }
            // Same reading column every other tvOS Settings pane uses, so
            // a pushed page does not stretch edge to edge on a 4K set.
            .frame(maxWidth: SettingsMetrics.tvReadingColumnWidth)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 32)
        }
    }
    #endif

    // MARK: - Copy

    private var footerText: String {
        if iCloudSyncEnabled {
            // Discord (Glitzbr) had to ask what actually triggers a sync,
            // which means the answer was invisible. It is: a local change
            // pushes itself a couple of seconds later, and an incoming change
            // from another device is applied as soon as iCloud delivers it.
            // Sync Now only forces the round trip early.
            return "Syncing is automatic: a change you make here is sent a few seconds later, and a change from another device is applied as soon as iCloud delivers it. Sync Now on the previous screen just forces that round trip immediately.\n\nEach row controls whether and where this device pushes and pulls that item. Use the Delete buttons to remove a category's cloud copy without affecting local data."
        } else {
            return "iCloud Sync is off. These choices take effect when you re-enable Sync at the top. The Delete buttons still work: useful for scrubbing stale iCloud state before re-enabling Sync."
        }
    }
}
