// LanguagePicker — the in-app language choice and the locale it implies for
// every macOS SwiftUI root.

import SwiftUI

/// Puts `LocaleOverrideStore.displayLocale` into the SwiftUI environment, so
/// `Text(date, style:)`, `.formatted()` and views reading `\.locale` format in
/// the language the user picked rather than the system's.
///
/// Apply it to the content of every macOS scene and `NSHostingView` root. It
/// observes the store, so the environment updates on a switch without a
/// relaunch. It does not rebuild the content: a view that only builds
/// `L10n` strings in `body` and has nothing else that changed is not
/// re-evaluated by an environment change, which is why `MenuBarView` and
/// `UsageDashboardView` also key their content on the override.
public struct DisplayLocaleRoot: ViewModifier {
    @ObservedObject private var store = LocaleOverrideStore.shared

    public init() {}

    public func body(content: Content) -> some View {
        content.environment(\.locale, store.displayLocale)
    }
}

public extension View {
    /// See `DisplayLocaleRoot`.
    func displayLocaleRoot() -> some View {
        modifier(DisplayLocaleRoot())
    }

    /// Rebuilds this view when the language changes.
    ///
    /// Observing `LocaleOverrideStore` re-evaluates the observing view's body,
    /// but SwiftUI skips a child whose inputs compare equal, so a child that
    /// builds `L10n` text from unchanged values (a tab that takes only
    /// environment objects, a read-only card) keeps its old language. A new
    /// identity forces a fresh body, at the price of the child's own @State:
    /// apply it below any state a switch must keep, such as typed sign-in
    /// details.
    ///
    /// Pass `language` from a store the caller observes, so the caller is
    /// re-evaluated on a switch. Inside a `ForEach`, pass the row's own id as
    /// `row` too: a lazy stack reads an explicit `.id` as the row identity, and
    /// the language alone would give every row the same one.
    func languageKeyed(_ language: String?, row: AnyHashable? = nil) -> some View {
        id(LanguageKey(row: row, language: language))
    }
}

/// The identity `languageKeyed` gives a view.
private struct LanguageKey: Hashable {
    let row: AnyHashable?
    let language: String?
}

#if os(macOS)
/// The globe menu that switches the app's language.
///
/// One view for every popover state (dashboard footer, signed-out footer,
/// onboarding, scan consent), so a first-run user can switch before they
/// ever reach the dashboard.
///
/// An inline `Picker` rather than buttons with a checkmark image: macOS then
/// draws real menu-item checkmarks and VoiceOver announces which language is
/// selected. Every tag is `String?`, the type of the selection, or the row
/// would never match and nothing would be checked.
public struct LanguagePickerMenu: View {
    @ObservedObject private var store = LocaleOverrideStore.shared

    public init() {}

    public var body: some View {
        Menu {
            Picker(L10n.language.title, selection: Binding(
                get: { store.override },
                set: { store.set($0) }
            )) {
                Text(L10n.language.systemDefault).tag(String?.none)
                Divider()
                ForEach(LocaleOverrideStore.languageOptions) { option in
                    Text(option.nativeName).tag(Optional(option.id))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            // Alert and panel buttons come from macOS, which reads the language
            // once at launch (see `LocaleOverrideStore.mirrorToAppleLanguages`).
            Text(L10n.language.systemTextAfterRestart)
        } label: {
            Image(systemName: "globe")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(L10n.language.title)
        .help(L10n.language.title)
    }
}
#endif
