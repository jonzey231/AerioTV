//
//  TVSettingsRows.swift
//  Aerio
//
//  Extracted verbatim from SettingsView.swift (Settings redesign Phase 1,
//  SettingsUIRedesign.md A4). No behavior change intended in this move.
//

import SwiftUI
import SwiftData

#if os(tvOS)  // Phase 1 split: re-opened, block spanned the extraction cut
struct TVSettingsNavRow<Destination: View, Content: View>: View {
    let destination: Destination
    let content: Content
    @FocusState private var isFocused: Bool

    init(destination: Destination, @ViewBuilder content: () -> Content) {
        self.destination = destination
        self.content = content()
    }

    var body: some View {
        NavigationLink(destination: destination) {
            content
                .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
                .background(tvSettingsCardBG(isFocused))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(TVNoHighlightButtonStyle())
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}

/// Button-based nav row that pushes onto a NavigationPath instead of using NavigationLink.
/// This ensures the TabView's .onExitCommand can properly manage back navigation.
struct TVSettingsNavButton: View {
    let label: String
    let icon: String
    let iconColor: Color
    let subtitle: String
    let action: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            SettingsRow(icon: icon, iconColor: iconColor, title: label, subtitle: subtitle)
                .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
                .background(tvSettingsCardBG(isFocused))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(TVNoHighlightButtonStyle())
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}

/// Plain action row (Add Playlist, Copy to Clipboard, etc.)
/// with the same teal card highlight on focus.
struct TVSettingsActionRow: View {
    let icon: String
    let label: String
    var isAccent: Bool = false
    var isDestructive: Bool = false
    let action: () -> Void
    @FocusState private var isFocused: Bool

    private var tint: Color {
        if isDestructive { return .red }
        if isAccent { return .accentPrimary }
        return .textPrimary
    }

    private var iconTint: Color {
        if isDestructive { return .red }
        if isAccent { return .accentPrimary }
        return .textSecondary
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 26))
                    .foregroundColor(iconTint)
                Text(label)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundColor(tint)
                Spacer()
            }
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
            .background(tvSettingsCardBG(isFocused))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(TVNoHighlightButtonStyle())
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}

/// Selection row for "pick one of many" settings lists (Color Theme,
/// Default Tab, buffer pickers, etc.) — shows an accent checkmark on
/// the selected option and uses the same teal card highlight on focus.
/// Supports an optional icon, leading badge (e.g. theme swatch), and
/// subtitle.
struct TVSettingsSelectionRow<Leading: View>: View {
    let label: String
    var subtitle: String? = nil
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let leading: () -> Leading
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                leading()
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.system(size: 26, weight: .medium))
                        .foregroundColor(.textPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 20))
                            .foregroundColor(.textSecondary)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(.accentPrimary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
            .background(tvSettingsCardBG(isFocused))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(TVNoHighlightButtonStyle())
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}

extension TVSettingsSelectionRow where Leading == EmptyView {
    init(label: String, subtitle: String? = nil,
         isSelected: Bool, action: @escaping () -> Void) {
        self.label = label
        self.subtitle = subtitle
        self.isSelected = isSelected
        self.action = action
        self.leading = { EmptyView() }
    }
}

/// Convenience initializer that takes a leading SF Symbol string instead
/// of a custom view (covers the common case).
extension TVSettingsSelectionRow where Leading == AnyView {
    init(icon: String, iconColor: Color = .accentPrimary,
         label: String, subtitle: String? = nil,
         isSelected: Bool, action: @escaping () -> Void) {
        self.label = label
        self.subtitle = subtitle
        self.isSelected = isSelected
        self.action = action
        self.leading = {
            AnyView(
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundColor(iconColor)
                    .frame(width: 32)
            )
        }
    }
}

/// Toggle row for tvOS — renders as a Button that flips a Bool on select,
/// showing an "On / Off" indicator. Consistent with TVGroupToggleRow in ManageGroupsSheet.
struct TVSettingsToggleRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    let onChange: (Bool) -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button {
            isOn.toggle()
            onChange(isOn)
        } label: {
            HStack(spacing: 0) {
                SettingsRow(icon: icon, iconColor: iconColor, title: title, subtitle: subtitle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // On/Off indicator — mirrors TVGroupToggleRow style
                HStack(spacing: 8) {
                    Circle()
                        .fill(isOn ? iconColor : Color.textTertiary)
                        .frame(width: 10, height: 10)
                    Text(isOn ? "On" : "Off")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundColor(isOn
                            ? (isFocused ? .white : iconColor)
                            : (isFocused ? .white : .textTertiary))
                }
                .padding(.leading, 16)
            }
            .frame(minHeight: 80)
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
            .background(tvSettingsCardBG(isFocused))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(TVNoHighlightButtonStyle())
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}

/// Teal-tinted card background shared by all tvOS settings row components.
/// Internal so DVR / Developer / Appearance settings pages can reuse it.
func tvSettingsCardBG(_ focused: Bool) -> some View {
    RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(focused ? Color.accentPrimary.opacity(0.18) : Color.cardBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.accentPrimary.opacity(focused ? 0.65 : 0.10),
                        lineWidth: focused ? 2.5 : 1)
        }
}
#endif

// MARK: - Server List Row
struct ServerListRow: View {
    let server: ServerConnection
    var onSetActive: (() -> Void)? = nil

    private var hasLANConfigured: Bool {
        server.type != .m3uPlaylist && !server.localURL.isEmpty
    }

    private var isOnLAN: Bool {
        hasLANConfigured && server.effectiveBaseURL != server.normalizedBaseURL
    }

    #if os(tvOS)
    private let checkmarkSize: CGFloat = 28
    private let iconBoxSize: CGFloat = 48
    private let iconFontSize: CGFloat = 22
    private let statusDotSize: CGFloat = 12
    #else
    private let checkmarkSize: CGFloat = 22
    private let iconBoxSize: CGFloat = 36
    private let iconFontSize: CGFloat = 16
    private let statusDotSize: CGFloat = 8
    #endif

    var body: some View {
        // TestFlight 1.8.4 crash (mikec79, 2026-08-05): deleting a playlist
        // trapped in SwiftData's _KKMDBackingData.getValue reading
        // `server.type` from this row's body. The 2026-07-14 sweep guarded the
        // pushed/presented ServerConnection views but deliberately skipped list
        // rows, reasoning that @Query recreates them on delete. It does - but
        // not before SwiftUI renders the row ONE more time with the row's
        // identity still alive and the model already tombstoned, and a
        // @Persisted read on a detached model is a trap, not nil.
        //
        // Same guard as the other views: `.modelContext` is a framework
        // property, not a @Persisted attribute, so reading it after
        // `context.delete` is safe and goes nil. ViewBuilder's `if` only
        // evaluates the taken branch, so rowContent's persisted reads never run
        // once detached. No dismiss here - it is a row, and @Query drops it on
        // the next pass.
        if server.modelContext == nil {
            EmptyView()
        } else {
            rowContent
        }
    }

    private var rowContent: some View {
        HStack(spacing: 14) {
            // Active server indicator — tapping sets this server as the active one
            if let onSetActive {
                Button(action: onSetActive) {
                    Image(systemName: server.isActive ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: checkmarkSize))
                        .foregroundColor(server.isActive ? .accentPrimary : .textTertiary)
                }
                #if os(tvOS)
                .buttonStyle(TVNoHighlightButtonStyle())
                #else
                .buttonStyle(.plain)
                #endif
            }

            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(server.type.color.opacity(0.2))
                    .frame(width: iconBoxSize, height: iconBoxSize)
                Image(systemName: server.type.systemIcon)
                    .font(.system(size: iconFontSize, weight: .medium))
                    .foregroundColor(server.type.color)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(server.name)
                    .font(.bodyMedium)
                    .foregroundColor(.textPrimary)
                HStack(spacing: 6) {
                    ServerTypeBadge(type: server.type)
                    if hasLANConfigured {
                        LANWANBadge(isLAN: isOnLAN)
                    }
                    Text(server.effectiveBaseURL)
                        .font(.monoSmall)
                        .foregroundColor(.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            Circle()
                .fill(server.isVerified ? Color.statusOnline : Color.textTertiary)
                .frame(width: statusDotSize, height: statusDotSize)
        }
        #if os(tvOS)
        .padding(.vertical, 16)
        #else
        .padding(.vertical, 4)
        #endif
    }
}

// MARK: - LAN / WAN Badge
struct LANWANBadge: View {
    let isLAN: Bool

    #if os(tvOS)
    private let iconSize: CGFloat = 14
    private let textSize: CGFloat = 16
    private let hPad: CGFloat = 8
    private let vPad: CGFloat = 4
    #else
    private let iconSize: CGFloat = 8
    private let textSize: CGFloat = 9
    private let hPad: CGFloat = 5
    private let vPad: CGFloat = 2
    #endif

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isLAN ? "wifi" : "globe")
                .font(.system(size: iconSize, weight: .semibold))
            Text(isLAN ? "LAN" : "WAN")
                .font(.system(size: textSize, weight: .bold))
        }
        .foregroundColor(isLAN ? .statusOnline : .accentSecondary)
        .padding(.horizontal, hPad)
        .padding(.vertical, vPad)
        .background(
            Capsule()
                .fill(isLAN ? Color.statusOnline.opacity(0.15) : Color.accentSecondary.opacity(0.15))
        )
    }
}

// MARK: - Settings Row

#if os(tvOS)  // Phase 1 split: re-opened, block spanned the extraction cut
struct TVSettingsTextField: View {
    let placeholder: String
    @Binding var text: String
    var isSecure: Bool = false
    @State private var focused = false

    var body: some View {
        // The UIKit field (DarkFocusTextFieldRepresentable) is transparent and
        // never paints the system white/gray focus platter; this view draws
        // the resting box (elevatedBackground) and the accent focus border, so
        // the field interior stays the same at rest and on focus - only the
        // border changes.
        DarkFocusTextFieldRepresentable(
            text: $text,
            placeholder: placeholder,
            isSecure: isSecure,
            onFocusChange: { focused = $0 }
        )
        .frame(height: 60)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.elevatedBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.accentPrimary.opacity(focused ? 1.0 : 0.0),
                        lineWidth: focused ? 3 : 0)
                .animation(.easeInOut(duration: 0.15), value: focused)
        )
    }
}
#endif

// MARK: - Buffer size options
