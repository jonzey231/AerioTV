//
//  SettingsChoicePicker.swift
//  Aerio
//
//  Settings redesign Phase 3, item 3: ONE "pick one of these" control.
//
//  Before Phase 3 the same question was asked five different ways:
//  a ForEach of check-marked Buttons inlined into the page (nine of
//  them), a `.segmented` Picker (Appearance Mode, Tile Corners), a
//  `Menu` picker (the DVR buffers), a native menu Picker (DVR
//  destination), and on tvOS a wall of `TVSettingsSelectionRow`s. A
//  page with three of those inline lists on it was mostly other
//  people's options.
//
//  The Phase 3 shape, matching Android:
//
//    iPhone / iPad - the picker is ONE row: title on the left, the
//      current value trailing, chevron. It pushes a single-choice page
//      (a radio list with a check on the selected row) carrying the
//      same title and the caller's footer.
//    tvOS - revised 2026-09-19 (Logan: "a lot of submenus seem very
//      long and could be condensed"). MORE than three options collapse
//      to the same single row and push a tvOS choice page; two or three
//      options still read as a compact group and stay INLINE with a
//      check, where a push would only cost an extra Back press.
//
//  Selection rows never ring or fill in white: the check is the
//  selection, the accent ring is the focus (Logan's standing rule).
//

import SwiftUI

// MARK: - Option model

/// One choice offered by `SettingsChoicePicker`.
struct SettingsChoice<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    /// Second line, on the choice page and on tvOS. Usually an example
    /// ("7:30 PM") or a one-line consequence.
    var subtitle: String? = nil
    /// Leading SF Symbol. Optional; a list where only some rows have an
    /// icon looks broken, so pass it for all or for none.
    var icon: String? = nil
    /// Leading color dot instead of an icon: the Color Theme list shows
    /// each theme's accent this way.
    var swatch: Color? = nil

    var id: Value { value }

    init(_ value: Value, _ title: String, subtitle: String? = nil,
         icon: String? = nil, swatch: Color? = nil) {
        self.value = value
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.swatch = swatch
    }
}

// MARK: - Picker

struct SettingsChoicePicker<Value: Hashable>: View {
    let title: String
    let options: [SettingsChoice<Value>]
    @Binding var selection: Value
    /// Explanatory copy. On iOS it becomes the pushed page's footer; on
    /// tvOS it renders under the inline rows.
    var footer: String? = nil
    /// Leading SF Symbol for the ROW (iOS) - not for the options.
    var icon: String? = nil
    var iconColor: Color = .accentPrimary
    /// Runs after `selection` is written. Pages that have to push
    /// preferences or save a model pass it here rather than using
    /// `.onChange`, so the write and its side effect stay together.
    var onChange: ((Value) -> Void)? = nil

    @ObservedObject private var theme = ThemeManager.shared

    init(_ title: String,
         options: [SettingsChoice<Value>],
         selection: Binding<Value>,
         footer: String? = nil,
         icon: String? = nil,
         iconColor: Color = .accentPrimary,
         onChange: ((Value) -> Void)? = nil) {
        self.title = title
        self.options = options
        self._selection = selection
        self.footer = footer
        self.icon = icon
        self.iconColor = iconColor
        self.onChange = onChange
    }

    /// The label shown trailing on the collapsed row. Falls back to an
    /// em-dash-free placeholder when the stored value is not one of the
    /// offered options (a stale preference, or a group that went away).
    private var currentTitle: String {
        options.first(where: { $0.value == selection })?.title ?? "Not set"
    }

    private func select(_ value: Value) {
        selection = value
        onChange?(value)
    }

    var body: some View {
        #if os(tvOS)
        tvBody
        #else
        iosRow
        #endif
    }

    // MARK: iOS / iPadOS - collapsed row that pushes a choice page

    #if !os(tvOS)
    private var iosRow: some View {
        NavigationLink {
            SettingsChoicePage(title: title,
                               options: options,
                               selection: $selection,
                               footer: footer,
                               onChange: onChange)
        } label: {
            HStack(spacing: 12) {
                if let icon {
                    Image(systemName: icon)
                        .scaledFont(.system(size: 15, weight: .semibold))
                        .foregroundColor(iconColor)
                        .frame(width: 22)
                }
                Text(title)
                    .scaledFont(.bodyMedium)
                    .foregroundColor(.textPrimary)
                Spacer(minLength: 12)
                Text(currentTitle)
                    .scaledFont(.bodyMedium)
                    .foregroundColor(Color.contrastText(.textSecondary))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
    #endif

    // MARK: tvOS - collapsed row that opens a pop-up option sheet

    #if os(tvOS)
    /// Logan 2026-09-19, after walking the redesign on the Apple TV:
    /// option lists should be a POP-UP, not a pushed page and not inline
    /// rows. Every picker is now ONE row (title / current value /
    /// chevron) that opens a centered modal card over the dimmed page.
    /// Two- and three-option lists included: they read the same way, and
    /// a two-option choice that would rather be a toggle is written as a
    /// toggle at the call site.
    @State private var isSheetPresented = false

    private var tvBody: some View {
        TVSettingsCardButtonRow(action: { isSheetPresented = true }) {
            HStack(spacing: 16) {
                if let icon {
                    // Phase 3 item 5: the tiled icon, never a bare glyph,
                    // so a picker row sits among toggle rows without
                    // reading as a different kind of row.
                    SettingsIconTile(icon: icon, color: iconColor)
                }
                Text(title)
                    .scaledFont(.system(size: SettingsMetrics.tvRowTitleSize, weight: .medium))
                    .foregroundColor(.textPrimary)
                Spacer(minLength: 16)
                Text(currentTitle)
                    .scaledFont(.system(size: SettingsMetrics.tvEyebrowSize))
                    .foregroundColor(Color.contrastText(.textSecondary))
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .scaledFont(.system(size: 22, weight: .semibold))
                    .foregroundColor(Color.contrastText(.textTertiary))
            }
        }
        .fullScreenCover(isPresented: $isSheetPresented) {
            // The focus state must live INSIDE the cover. A @FocusState owned
            // by this presenting row never reaches the cover's rows: the cover
            // is a separate presentation with its own focus environment, so
            // requests made from out here were silently dropped and the
            // system kept its own pick, row one (Logan 2026-09-19, twice).
            TVSettingsSingleChoiceSheet(title: title, footer: footer,
                                        options: options,
                                        selection: selection) { value in
                select(value)
                isSheetPresented = false
            }
        }
    }
    #endif
}

#if os(tvOS)
// MARK: - Shared option row

/// One option inside a `TVSettingsSheetCard`: leading swatch or icon,
/// title, optional subtitle, accent checkmark on the current value.
/// Focus is the standard accent 2pt ring from `TVSettingsSelectionRow`;
/// the system white platter never appears.
struct TVSettingsOptionRow<Value: Hashable>: View {
    let option: SettingsChoice<Value>
    let isSelected: Bool
    let action: () -> Void
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        TVSettingsSelectionRow(
            label: option.title,
            subtitle: option.subtitle,
            isSelected: isSelected,
            action: action,
            leading: {
                if let swatch = option.swatch {
                    Circle()
                        .fill(swatch)
                        .frame(width: 28, height: 28)
                        .overlay(Circle().stroke(Color.borderMedium, lineWidth: 1))
                } else if let icon = option.icon {
                    Image(systemName: icon)
                        .scaledFont(.system(size: 22))
                        .foregroundColor(theme.accent)
                        .frame(width: 32)
                }
            }
        )
    }
}

// MARK: - Single-choice sheet content (tvOS)

/// The body of a single-choice option sheet. It owns the focus state so the
/// request to start on the CURRENT option is made from inside the cover's
/// own focus environment, which is the only place it takes effect.
struct TVSettingsSingleChoiceSheet<Value: Hashable>: View {
    let title: String
    var footer: String? = nil
    let options: [SettingsChoice<Value>]
    let selection: Value
    let onPick: (Value) -> Void

    @FocusState private var focusedOption: Value?
    @State private var didPlaceFocus = false

    var body: some View {
        TVSettingsSheetCard(title: title, footer: footer,
                            scrollTarget: selection) {
            ForEach(options) { option in
                TVSettingsOptionRow(option: option,
                                    isSelected: option.value == selection) {
                    onPick(option.value)
                }
                .focused($focusedOption, equals: option.value)
                .id(option.value)
            }
        }
        .defaultFocus($focusedOption, selection, priority: .userInitiated)
        .onAppear { placeFocus() }
        // The system makes its own first pick as the cover settles. Override
        // that pick exactly once, then leave the user in control.
        .onChange(of: focusedOption) { _, newValue in
            guard !didPlaceFocus, let newValue, newValue != selection else { return }
            placeFocus()
        }
    }

    private func placeFocus() {
        for delay in [0.05, 0.2, 0.45] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard !didPlaceFocus || focusedOption == nil else { return }
                focusedOption = selection
                if delay >= 0.45 { didPlaceFocus = true }
            }
        }
    }
}

// MARK: - Pop-up option sheet (tvOS)

/// The modal card every tvOS Settings option list opens in.
///
/// Why a `fullScreenCover` and not a hand-built overlay (Logan asked
/// which): the cover is the only presentation that reliably TRAPS focus
/// (a custom overlay inside a page's ScrollView leaves the rows behind it
/// focusable, and the D-pad walks straight out of the card), and it
/// restores focus to the originating row on dismiss for free.
/// `.presentationBackground(.clear)` removes the system material, so what
/// is behind the card is the page itself under our own dim layer, not a
/// blurred-white sheet.
///
/// Menu closes the sheet and never leaves Settings: the card registers
/// itself in the page's `SettingsDismissStack` through
/// `trackedAsClassicSettingsChild()`, which is the same mechanism the
/// pushed Settings children use, so MainTabView's Menu handler pops this
/// first (LIFO) exactly as it would pop a pushed page.
struct TVSettingsSheetCard<Content: View>: View {
    let title: String
    var footer: String? = nil
    /// The row `.id(...)` to drag into view when the card opens, so a long
    /// option list opens ON the current value instead of at row one. The
    /// caller tags its rows with the same identity.
    var scrollTarget: AnyHashable? = nil
    @ViewBuilder let content: Content

    /// Card width. Options are short lines, so this sits inside the
    /// reading column rather than matching it.
    private let cardWidth: CGFloat = 900

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Dimmed, never a blurred-white material: the page stays
                // readable behind the card.
                Color.black.opacity(0.62).ignoresSafeArea()

                ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title)
                            .scaledFont(.system(size: 34, weight: .semibold))
                            .foregroundColor(.textPrimary)
                            .padding(.horizontal, 4)
                        if let footer, !footer.isEmpty {
                            Text(footer)
                                .scaledFont(.system(size: SettingsMetrics.tvFootnoteSize).subtext())
                                .foregroundColor(Color.contrastText(.textTertiary))
                                .padding(.horizontal, 4)
                                .padding(.bottom, 8)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            content
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(32)
                }
                .frame(maxWidth: cardWidth)
                // Taller lists scroll INSIDE the card.
                .frame(maxHeight: geo.size.height * 0.7)
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.cardBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.accentPrimary.opacity(0.18),
                                      lineWidth: SettingsMetrics.tvCardBorderWidth)
                )
                // Keeps the D-pad inside the card.
                .focusSection()
                .onAppear {
                    guard let scrollTarget else { return }
                    // No animation: the card should be ALREADY parked on
                    // the current value when it fades in.
                    proxy.scrollTo(scrollTarget, anchor: .center)
                }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .presentationBackground(.clear)
        // Menu closes the sheet first, never Settings itself.
        .trackedAsClassicSettingsChild()
    }
}
#endif

// MARK: - Pushed choice page (iOS / iPadOS)

#if !os(tvOS)
/// The single-choice page a `SettingsChoicePicker` row pushes. A radio
/// list: one row per option, a check on the selected one, and the
/// caller's footer underneath. Choosing a row writes the value and pops,
/// which is the iOS convention and matches Android's single-choice
/// dialog closing on selection.
struct SettingsChoicePage<Value: Hashable>: View {
    let title: String
    let options: [SettingsChoice<Value>]
    @Binding var selection: Value
    var footer: String? = nil
    var onChange: ((Value) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        List {
            Section {
                ForEach(options) { option in
                    Button {
                        selection = option.value
                        onChange?(option.value)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            if let icon = option.icon {
                                Image(systemName: icon)
                                    .scaledFont(.system(size: 15, weight: .semibold))
                                    .foregroundColor(theme.accent)
                                    .frame(width: 22)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.title)
                                    .scaledFont(.bodyMedium)
                                    .foregroundColor(.textPrimary)
                                if let subtitle = option.subtitle {
                                    Text(subtitle)
                                        .scaledFont(.labelSmall.subtext())
                                        .foregroundColor(Color.contrastText(.textTertiary))
                                }
                            }
                            Spacer(minLength: 12)
                            if option.value == selection {
                                Image(systemName: "checkmark")
                                    .scaledFont(.system(size: 14, weight: .semibold))
                                    .foregroundColor(theme.accent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .listRowBackground(Color.cardBackground)
                }
            } footer: {
                if let footer, !footer.isEmpty {
                    Text(footer)
                        .scaledFont(.labelSmall.subtext())
                        .foregroundColor(Color.contrastText(.textTertiary))
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        #if os(iOS)
        // Phase 3 (Logan 2026-09-18): floating tab bar parity -
        // content runs under the bar, the bar tucks away on scroll,
        // and the last row clears it.
        .settingsPhoneTabBarChrome()
        #endif
        .background(Color.appBackground)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
