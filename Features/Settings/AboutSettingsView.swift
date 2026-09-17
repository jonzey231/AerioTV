//
//  AboutSettingsView.swift
//  Aerio
//
//  Settings redesign Phase 1 (regroup, 2026-09-17). About became a page:
//  the device / system / version rows, Copy to Clipboard, Open Source
//  Licenses, the developer links and the memorial line moved off the
//  Settings root, which now keeps a single About row showing the version.
//
//  Rows and copy are unchanged; the bodies were lifted from SettingsView's
//  root About section and its iPad / tvOS About panes.
//

import SwiftUI

struct AboutSettingsView: View {
    @ObservedObject private var theme = ThemeManager.shared

    @State private var copiedAbout = false
    /// Presents the What's New sheet on demand from the App Version row.
    /// Independent of the launch-time presentation in RootView.
    @State private var showWhatsNewFromAbout = false
    #if os(tvOS)
    /// Presents the Open Source Licenses takeover (GPL/LGPL notice
    /// obligations; mirrors Android's Settings > About entry).
    @State private var showOSSLicenses = false
    /// Non-nil presents the About-row QR sheet.
    @State private var tvQRLink: TVQRLink?
    #endif

    // MARK: - About computed properties

    private var aboutDevice: String { DeviceInfo.modelName }

    private var aboutSystem: String {
#if canImport(UIKit)
        return "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
#else
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
#endif
    }

    private var aboutVersion: String { AboutInfo.version }

    private var aboutInstallDate: String { DeviceInfo.firstInstalledText }

    private var aboutUpdateDate: String { DeviceInfo.lastUpdatedText }

    private var aboutCopyText: String {
        [
            "AerioTV \(aboutVersion)",
            "Device: \(aboutDevice)",
            "System: \(aboutSystem)",
            "First Installed: \(aboutInstallDate)",
            "Last Updated: \(aboutUpdateDate)"
        ].joined(separator: "\n")
    }

    /// Whether a curated What's New entry exists for the running build.
    private var hasWhatsNew: Bool { WhatsNewStore.currentRelease != nil }

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            #if os(tvOS)
            tvOSBody
            #else
            iOSBody
            #endif
        }
        .navigationTitle("About")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #else
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .toolbarBackground(Color.appBackground, for: .navigationBar)
    }

    // MARK: - iOS Body

    #if os(iOS)
    private var iOSBody: some View {
        List {
            Section {
                infoRow("Device",          value: aboutDevice)
                    .listRowBackground(Color.cardBackground)
                infoRow("System",          value: aboutSystem)
                    .listRowBackground(Color.cardBackground)
                appVersionRow
                    .listRowBackground(Color.cardBackground)
                infoRow("First Installed", value: aboutInstallDate)
                    .listRowBackground(Color.cardBackground)
                infoRow("Last Updated",    value: aboutUpdateDate)
                    .listRowBackground(Color.cardBackground)

                Button {
                    UIPasteboard.general.string = aboutCopyText
                    copiedAbout = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        copiedAbout = false
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: copiedAbout ? "checkmark.circle.fill" : "doc.on.doc")
                            .scaledFont(.system(size: 14, weight: .medium))
                            .foregroundColor(copiedAbout ? .accentPrimary : Color.contrastText(.textSecondary))
                        Text(copiedAbout ? "Copied!" : "Copy to Clipboard")
                            .scaledFont(.bodyMedium)
                            .foregroundColor(copiedAbout ? Color.contrastText(.accentPrimary) : Color.contrastText(.textSecondary))
                        Spacer()
                    }
                }
                .buttonStyle(PressableButtonStyle())
                .listRowBackground(Color.cardBackground)

                NavigationLink {
                    OpenSourceLicensesView()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text")
                            .scaledFont(.system(size: 14, weight: .medium))
                            .foregroundColor(Color.contrastText(.textSecondary))
                        Text("Open Source Licenses")
                            .scaledFont(.bodyMedium.subtext())
                            .foregroundColor(Color.contrastText(.textSecondary))
                        Spacer()
                    }
                }
                .listRowBackground(Color.cardBackground)

                Link(destination: URL(string: "https://github.com/jonzey231/AerioTV")!) {
                    HStack(spacing: 8) {
                        Image(systemName: "link")
                            .scaledFont(.system(size: 14, weight: .medium))
                            .foregroundColor(Color.contrastText(.textSecondary))
                        Text("Developer Website")
                            .scaledFont(.bodyMedium.subtext())
                            .foregroundColor(Color.contrastText(.textSecondary))
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .scaledFont(.system(size: 12))
                            .foregroundColor(Color.contrastText(.textTertiary))
                    }
                }
                .listRowBackground(Color.cardBackground)

                Link(destination: URL(string: "https://github.com/jonzey231/AerioTV/issues")!) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.bubble")
                            .scaledFont(.system(size: 14, weight: .medium))
                            .foregroundColor(Color.contrastText(.textSecondary))
                        Text("Report an Issue")
                            .scaledFont(.bodyMedium.subtext())
                            .foregroundColor(Color.contrastText(.textSecondary))
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .scaledFont(.system(size: 12))
                            .foregroundColor(Color.contrastText(.textTertiary))
                    }
                }
                .listRowBackground(Color.cardBackground)
            } footer: {
                Text("In loving memory of Jesse Mann aka EPG Guru")
                    .scaledFont(.footnote.subtext())
                    .italic()
                    .foregroundColor(Color.contrastText(.textTertiary))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
            }
            .listSectionSeparator(.hidden)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    /// App Version row. When the running build ships release notes the row
    /// becomes a quiet button that re-opens the What's New sheet.
    @ViewBuilder
    private var appVersionRow: some View {
        if hasWhatsNew {
            Button {
                showWhatsNewFromAbout = true
            } label: {
                HStack {
                    Text("App Version")
                        .scaledFont(.bodyMedium.subtext())
                        .foregroundColor(Color.contrastText(.textSecondary))
                    Spacer()
                    Text(aboutVersion)
                        .scaledFont(.bodyMedium)
                        .foregroundColor(.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("What's New")
                        .scaledFont(.caption.subtext())
                        .foregroundColor(Color.contrastText(.textTertiary))
                    Image(systemName: "chevron.right")
                        .scaledFont(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color.contrastText(.textTertiary))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .whatsNewSheet(isPresented: $showWhatsNewFromAbout)
        } else {
            infoRow("App Version", value: aboutVersion)
        }
    }

    private func infoRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .scaledFont(.bodyMedium.subtext())
                .foregroundColor(Color.contrastText(.textSecondary))
            Spacer()
            Text(value)
                .scaledFont(.bodyMedium)
                .foregroundColor(.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
    #endif

    // MARK: - tvOS Body

    #if os(tvOS)
    private var tvOSBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(spacing: 0) {
                    tvAboutRow("Device",          value: aboutDevice)
                    Divider().background(Color.borderSubtle).padding(.horizontal, 16)
                    tvAboutRow("System",          value: aboutSystem)
                    Divider().background(Color.borderSubtle).padding(.horizontal, 16)
                    tvAppVersionRow
                    Divider().background(Color.borderSubtle).padding(.horizontal, 16)
                    tvAboutRow("First Installed", value: aboutInstallDate)
                    Divider().background(Color.borderSubtle).padding(.horizontal, 16)
                    tvAboutRow("Last Updated",    value: aboutUpdateDate)
                    Divider().background(Color.borderSubtle).padding(.horizontal, 16)
                    tvAboutLinkRow("Developer Website", urlString: "https://github.com/jonzey231/AerioTV")
                    Divider().background(Color.borderSubtle).padding(.horizontal, 16)
                    tvAboutLinkRow("Report an Issue",   urlString: "https://github.com/jonzey231/AerioTV/issues/new")
                    Divider().background(Color.borderSubtle).padding(.horizontal, 16)
                    Button {
                        showOSSLicenses = true
                    } label: {
                        HStack {
                            Text("Open Source Licenses")
                                .scaledFont(.system(size: 26, weight: .medium))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .scaledFont(.system(size: 20))
                                .opacity(0.5)
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 18)
                    }
                    // .plain let tvOS drop its big bright white platter behind
                    // the row (Logan 2026-09-15). Shared inline-card treatment.
                    .buttonStyle(TVInlineCardRowButtonStyle())
                }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.cardBackground))
                .padding(.bottom, 8)

                Text("In loving memory of Jesse Mann aka EPG Guru")
                    .scaledFont(.system(size: 22).subtext())
                    .italic()
                    .foregroundColor(Color.contrastText(.textTertiary))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 12)
            }
            // Phase 3 item 7: centered reading column, same as every other
            // tvOS Settings page.
            .frame(maxWidth: SettingsMetrics.tvReadingColumnWidth, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity)
        }
        .sheet(item: $tvQRLink) { link in
            TVQRLinkSheet(link: link)
        }
        .fullScreenCover(isPresented: $showOSSLicenses) {
            OpenSourceLicensesView(standalone: true)
        }
    }

    /// App Version row on Apple TV. Focusable when the build ships release
    /// notes so the remote can re-open the What's New cover.
    @ViewBuilder
    private var tvAppVersionRow: some View {
        if hasWhatsNew {
            Button {
                showWhatsNewFromAbout = true
            } label: {
                HStack {
                    Text("App Version")
                        .scaledFont(.system(size: 26, weight: .medium).subtext())
                        .foregroundColor(Color.contrastText(.textSecondary))
                    Spacer()
                    Text(aboutVersion)
                        .scaledFont(.system(size: 26))
                        .foregroundColor(.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("What's New")
                        .scaledFont(.system(size: 22).subtext())
                        .foregroundColor(Color.contrastText(.textTertiary))
                    Image(systemName: "chevron.right")
                        .scaledFont(.system(size: 20))
                        .opacity(0.5)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
            }
            .buttonStyle(TVInlineCardRowButtonStyle())
            .whatsNewSheet(isPresented: $showWhatsNewFromAbout)
        } else {
            tvAboutRow("App Version", value: aboutVersion)
        }
    }

    private func tvAboutRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .scaledFont(.system(size: 26, weight: .medium).subtext())
                .foregroundColor(Color.contrastText(.textSecondary))
            Spacer()
            Text(value)
                .scaledFont(.system(size: 26))
                .foregroundColor(.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    /// External-link About row: focusable, presents the URL as a QR the
    /// user scans with a phone (Android parity P2).
    private func tvAboutLinkRow(_ label: String, urlString: String) -> some View {
        Button {
            tvQRLink = TVQRLink(title: label, url: urlString)
        } label: {
            HStack {
                Text(label)
                    .scaledFont(.system(size: 26, weight: .medium).subtext())
                    .foregroundColor(Color.contrastText(.textSecondary))
                Spacer()
                Image(systemName: "qrcode")
                    .scaledFont(.system(size: 24))
                    .foregroundColor(.textPrimary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
        }
        .buttonStyle(TVInlineCardRowButtonStyle())
    }
    #endif
}

/// Shared "1.8.40 (1)" version string, so the Settings root row and the
/// About page cannot drift.
enum AboutInfo {
    static var version: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        let build   = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }
}
