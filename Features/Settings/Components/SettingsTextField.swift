//
//  SettingsTextField.swift
//  Aerio
//
//  Settings redesign Phase 3, item 2: ONE text field for the whole
//  Settings surface.
//
//  Before Phase 3 a Settings field could be any of four things: a bare
//  `TextField` in a Form (EditServerSheet), a `SecureField` with no way
//  to check what was typed, `TVSettingsTextField` (tvOS box, no reveal),
//  or `AppTextField` (the good one, used only by Movies & TV and
//  Onboarding). The three shapes disagreed about where the label sat,
//  whether there was a helper line, and how focus looked.
//
//  `SettingsTextField` is the single answer, on iOS, iPadOS and tvOS:
//
//    * label ABOVE the box,
//    * value INSIDE the box,
//    * optional helper text BELOW it,
//    * a subtle accent focus outline at the standard Settings width,
//      never white and never oversized (Logan's standing rule),
//    * secure fields get the reveal eye, and NOTHING else reveals them:
//      the value stays masked whether or not the field has focus, on
//      every platform (security fix 2026-09-19).
//
//  The box itself is `AppTextField`, which already owns the UIKit
//  dark-focus field that keeps tvOS from painting its white platter.
//  This wrapper adds the helper line and the Settings defaults so no
//  call site has to remember them.
//

import SwiftUI

struct SettingsTextField: View {
    let title: String
    var placeholder: String? = nil
    @Binding var text: String
    /// Helper text below the box. Explains the field; not an error.
    var helper: String? = nil
    var isSecure: Bool = false
    /// `UIKeyboardType` exists on tvOS as well, so one signature covers
    /// both platforms; tvOS simply ignores the hint.
    var keyboardType: UIKeyboardType = .default
    var autocapitalization: TextInputAutocapitalization = .never
    var autocorrection: Bool = false

    init(_ title: String,
         placeholder: String? = nil,
         text: Binding<String>,
         helper: String? = nil,
         isSecure: Bool = false,
         keyboardType: UIKeyboardType = .default,
         autocapitalization: TextInputAutocapitalization = .never,
         autocorrection: Bool = false) {
        self.title = title
        self.placeholder = placeholder
        self._text = text
        self.helper = helper
        self.isSecure = isSecure
        self.keyboardType = keyboardType
        self.autocapitalization = autocapitalization
        self.autocorrection = autocorrection
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AppTextField(
                title,
                placeholder: placeholder ?? title,
                text: $text,
                keyboardType: keyboardType,
                isSecure: isSecure,
                autocapitalization: autocapitalization,
                autocorrection: autocorrection
                // SECURITY 2026-09-19: no reveal-on-focus. A secure field
                // stays masked on every platform until the user toggles
                // the eye, which the Siri Remote can reach.
            )

            if let helper, !helper.isEmpty {
                Text(helper)
                    .scaledFont(SettingsTextField.helperFont)
                    .foregroundColor(Color.contrastText(.textTertiary))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        #if os(iOS)
        // Settings fields sit in Form/List rows. Own the row so the
        // label/box/helper stack reads as one field instead of three
        // stacked rows.
        .padding(.vertical, 4)
        #endif
    }

    private static var helperFont: AerioFont {
        #if os(tvOS)
        .system(size: SettingsMetrics.tvFootnoteSize).subtext()
        #else
        .labelSmall.subtext()
        #endif
    }
}
