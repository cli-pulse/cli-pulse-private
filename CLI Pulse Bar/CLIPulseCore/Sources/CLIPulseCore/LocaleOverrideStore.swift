import Foundation
import Combine
#if canImport(SwiftUI)
import SwiftUI
#endif

/// Runtime UI-language override. When set, `L10n.tr` looks up strings in
/// the matching `.lproj` bundle instead of the system-default locale.
///
/// iter22 (2026-05-01): added the in-app language switcher requested by
/// manual smoke. Persisted to standard UserDefaults so the choice
/// survives restarts. Publishes `objectWillChange` on every change so
/// observing views re-render localized strings without a relaunch. Observing
/// it directly: `MenuBarView`, `SettingsTab`, `OnboardingWizardView` and
/// `LegacyOnboardingWizardView` in the app target, and `MachineHealthView`,
/// `UsageDashboardView` and `LanguagePickerMenu` here. Every macOS scene root
/// observes it through `displayLocaleRoot()`.
///
/// Three things follow the choice, at different speeds:
/// * CLIPulseCore's own strings (`bundle`) switch live.
/// * Dates and other formatted values follow `displayLocale`, live, wherever a
///   root applies `displayLocaleRoot()` or a formatter reads it.
/// * Text AppKit, Foundation and StoreKit supply themselves (alert and panel
///   buttons, system error descriptions) is resolved from `AppleLanguages` once
///   per process. The macOS app calls `mirrorToAppleLanguages()` so the choice
///   reaches that text from the next launch; nothing can switch it live.
public final class LocaleOverrideStore: ObservableObject {
    public static let shared = LocaleOverrideStore()

    /// Posted whenever the active override changes, for non-SwiftUI code.
    /// Nothing in the app subscribes today: views observe the store itself.
    public static let didChangeNotification = Notification.Name("CLIPulseLocaleOverrideDidChange")

    private static let defaultsKey = "cli_pulse_locale_override"

    /// The key macOS reads a process's UI languages from, in the app's own
    /// defaults domain first. It is the same key System Settings' per-app
    /// language writes.
    static let appleLanguagesKey = "AppleLanguages"

    /// What this store last wrote to `AppleLanguages`, in a key only the app
    /// writes. `AppleLanguages` alone cannot say who set it: System Settings'
    /// per-app language writes the same key, and that one is the user's.
    static let mirroredLanguagesKey = "cli_pulse_mirrored_apple_languages"

    /// `nil` means "follow system default". Non-nil values are the
    /// matching `.lproj` directory name, e.g. `"en"`, `"ja"`,
    /// `"zh-Hans"`.
    @Published public private(set) var override: String?

    private let defaults: UserDefaults

    /// The override in effect when this process started. With mirroring on, it
    /// is also what `AppleLanguages` pinned the resource bundle to at launch —
    /// see `liveSystemLocalization`.
    private let launchOverride: String?

    /// Off by default so tests and the iPhone/Watch apps, which have no
    /// language menu, never write `AppleLanguages`.
    private var mirrorsAppleLanguages = false

    /// The user's language list with the app-domain pin removed. Injected in
    /// tests; in the app, removing our key lets the lookup fall through to the
    /// system-wide list.
    private let systemPreferredLanguages: () -> [String]

    init(
        defaults: UserDefaults = .standard,
        systemPreferredLanguages: (() -> [String])? = nil
    ) {
        self.defaults = defaults
        let stored = defaults.string(forKey: Self.defaultsKey)
        self.override = stored
        self.launchOverride = stored
        self.systemPreferredLanguages = systemPreferredLanguages ?? {
            defaults.stringArray(forKey: Self.appleLanguagesKey) ?? Locale.preferredLanguages
        }
    }

    public func set(_ newValue: String?) {
        guard newValue != override else { return }
        override = newValue
        if let newValue {
            defaults.set(newValue, forKey: Self.defaultsKey)
        } else {
            defaults.removeObject(forKey: Self.defaultsKey)
        }
        if mirrorsAppleLanguages {
            if let newValue {
                writeMirror([newValue])
            } else {
                // System Default: drop our pin so the system-wide list applies
                // again from the next launch.
                removeMirror()
            }
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    /// Mirrors the override into `AppleLanguages` from now on, so the text
    /// macOS frameworks supply (alert buttons, open/save panels, system error
    /// descriptions) follows the chosen language after the next launch.
    ///
    /// That key sets the language of the whole app process, not just of those
    /// frameworks. From the next launch after a choice:
    /// * `Locale.current` and `Locale.autoupdatingCurrent` take the chosen
    ///   language (on the user's region), and so does `.formatted()`;
    /// * Sentry reports that language in its culture context;
    /// * `URLSession` sends it as `Accept-Language` on every request that does
    ///   not set its own (the CLI Pulse backend does not read the header);
    /// * system error text, including `error.localizedDescription` interpolated
    ///   into log lines, is in that language.
    ///
    /// Stored and sent values do not change, but only because of how today's
    /// formatters are written: every `NumberFormatter` pins `en_US` or
    /// `en_US_POSIX`, and the date formatters without a pinned locale use a
    /// fixed `yyyy-MM-dd` pattern, which reads the same in every shipped
    /// language (the calendar follows the region, not the language). A new
    /// formatter whose output is stored, synced, compared or sent must pin
    /// `en_US_POSIX`, or it will write the user's language after a restart.
    ///
    /// Called once at app launch, after any defaults migration. An override
    /// chosen before this existed is brought into step here.
    ///
    /// With no override, `AppleLanguages` is removed only if it still holds
    /// what this store wrote (see `mirroredLanguagesKey`). That clears a pin
    /// the override outlived, after a downgrade to a build without the mirror
    /// or a `defaults delete` of the override, which would otherwise keep the
    /// app in the old language with System Default checked. A per-app language
    /// set in System Settings is a different value and is left alone.
    public func mirrorToAppleLanguages() {
        mirrorsAppleLanguages = true
        if let override {
            writeMirror([override])
        } else {
            removeMirror()
        }
    }

    private func writeMirror(_ languages: [String]) {
        defaults.set(languages, forKey: Self.appleLanguagesKey)
        defaults.set(languages, forKey: Self.mirroredLanguagesKey)
    }

    /// Removes `AppleLanguages` while it is still the value this store wrote,
    /// and forgets that value either way: once the key holds something else,
    /// it is not ours to remove.
    private func removeMirror() {
        guard let mirrored = defaults.stringArray(forKey: Self.mirroredLanguagesKey) else { return }
        if defaults.stringArray(forKey: Self.appleLanguagesKey) == mirrored {
            defaults.removeObject(forKey: Self.appleLanguagesKey)
        }
        defaults.removeObject(forKey: Self.mirroredLanguagesKey)
    }

    /// The `.lproj` that "System Default" means right now, when the resource
    /// bundle cannot answer that itself.
    ///
    /// A process launched with an override was pinned to it through
    /// `AppleLanguages`, and a bundle resolves its localization once. Without
    /// this, choosing System Default would leave the whole app in the old
    /// language until relaunch. `nil` whenever the bundle's own launch-time
    /// choice is still right.
    private var liveSystemLocalization: String? {
        guard override == nil, mirrorsAppleLanguages, launchOverride != nil else { return nil }
        return Self.systemLocalization(preferences: systemPreferredLanguages())
    }

    /// The shipped catalogue a preference list selects, the way the bundle
    /// itself would choose. English, the development language, when nothing
    /// in the list is shipped.
    static func systemLocalization(preferences: [String]) -> String {
        Bundle.preferredLocalizations(from: shippedLocalizations, forPreferences: preferences)
            .lazy.compactMap(canonicalLocalization).first ?? "en"
    }

    /// The locale every displayed date, time and number should use.
    ///
    /// The one accessor for display formatting on macOS: SwiftUI gets it
    /// through `displayLocaleRoot()`, and a `DateFormatter` (or any formatter
    /// that feeds visible text) sets `.locale` from it, because the SwiftUI
    /// environment never reaches formatter objects.
    ///
    /// With no override it is `Locale.autoupdatingCurrent`. With one, it is the
    /// chosen language on the user's own region and calendar, so a Spanish
    /// choice keeps Mexico's separators rather than Spain's. Never use it for
    /// stored values or day keys: those stay POSIX.
    public var displayLocale: Locale {
        let language: String?
        if let override {
            // An override that resolves to no catalogue shows the system's
            // strings (see `bundle`), so it formats like the system too.
            language = Self.bundle(forLocalization: override) != nil
                ? Self.canonicalLocalization(override) : nil
        } else {
            language = liveSystemLocalization
        }
        guard let language else { return Self.systemLocale() }
        return Self.displayLocale(language: language, base: Self.systemLocale())
    }

    /// The system locale `displayLocale` starts from. The app never changes it.
    /// Tests do, because separators come from the region: on an en_US machine,
    /// which CI is, a Spanish choice formats "2.5" either way, so a formatter
    /// that ignored the display locale could not fail there.
    nonisolated(unsafe) static var systemLocale: () -> Locale = { .autoupdatingCurrent }

    /// `base` with its language replaced by `language`.
    static func displayLocale(language: String, base: Locale) -> Locale {
        var components = Locale.Components(locale: base)
        var chosen = Locale.Language.Components(identifier: language)
        // The region of a plain identifier such as en_MX lives in the language
        // components, so replacing them wholesale would drop it.
        chosen.region = components.languageComponents.region
        components.languageComponents = chosen
        return Locale(components: components)
    }

    /// Bundle to read localized strings from. Falls back to the package
    /// resource bundle when the override doesn't resolve to a known
    /// `.lproj` directory.
    public var bundle: Bundle {
        let base = Self.resourceBundle()
        guard let override else {
            return liveSystemLocalization.flatMap(Self.bundle(forLocalization:)) ?? base
        }
        return Self.bundle(forLocalization: override) ?? base
    }

    /// Resolves a single `.lproj` directory inside the resource bundle.
    ///
    /// Tries the canonical name first (e.g. `"zh-Hans"`), then a
    /// lowercased variant, because SwiftPM rewrites resource-bundle
    /// directory names to all-lowercase (`zh-hans.lproj`). Returns `nil`
    /// for unknown values so callers can decide their own fallback
    /// instead of crashing on a typo.
    public static func bundle(forLocalization localization: String) -> Bundle? {
        let base = resourceBundle()
        for candidate in resolutionCandidates(for: localization) {
            if let path = base.path(forResource: candidate, ofType: "lproj"),
               let bundle = Bundle(path: path) {
                return bundle
            }
        }
        return nil
    }

    /// The `.lproj` catalogue the app is actually reading, by name.
    ///
    /// Not `Locale.current.identifier` and not `Bundle.preferredLocalizations`
    /// of the main bundle: both answer "what does the user prefer", and the
    /// question the activation funnel asks is "what did they SEE". A French
    /// user prefers `fr` and reads `en`, and it is the English they read that
    /// the funnel needs to know about.
    ///
    /// Returns the canonical `.lproj` name (`zh-Hans`, not `zh-hans`) —
    /// SwiftPM lowercases resource-bundle directory names, so the value coming
    /// back from `preferredLocalizations` cannot be used as-is. Anything
    /// unrecognised becomes `nil` rather than being reported verbatim; the
    /// telemetry column is a closed set and the server rejects the rest.
    ///
    /// After System Default is picked in a session that launched with a
    /// choice, this is the system list's catalogue, the one `bundle` now
    /// shows, not the launch-pinned bundle's. Telemetry reports that value.
    public static var resolvedLocalization: String? {
        resolvedLocalization(for: shared)
    }

    /// `resolvedLocalization` for a given store, so tests can reach the
    /// System Default branch without touching `shared`.
    static func resolvedLocalization(for store: LocaleOverrideStore) -> String? {
        if let override = store.override,
           let canonical = canonicalLocalization(override),
           bundle(forLocalization: override) != nil {
            return canonical
        }
        if let live = store.liveSystemLocalization {
            return live
        }
        for candidate in resourceBundle().preferredLocalizations {
            if let canonical = canonicalLocalization(candidate) {
                return canonical
            }
        }
        return nil
    }

    /// The catalogues this app ships. Kept here rather than in the telemetry
    /// layer because it is a fact about the resource bundle.
    ///
    /// The language menu, `resolvedLocalization` and `L10nFallbackTests` all
    /// read this list, so it must match the `.lproj` directories on disk:
    /// `LanguageChoiceTests` compares the two, and a catalogue added without
    /// an entry here fails CI instead of silently missing from the menu.
    public static let shippedLocalizations = ["en", "es", "ja", "ko", "zh-Hans", "zh-Hant"]

    /// One row of the language menu.
    public struct LanguageOption: Identifiable, Hashable, Sendable {
        /// The `.lproj` name, which is also the stored override value.
        public let id: String
        /// The language's name in that language, so a reader finds their own
        /// language whatever the app is currently showing.
        public let nativeName: String
    }

    /// Endonyms, written out rather than taken from
    /// `Locale.localizedString(forIdentifier:)`, which gives lowercase
    /// "español" and "中文（简体）".
    private static let nativeNames: [String: String] = [
        "en": "English",
        "es": "Español",
        "ja": "日本語",
        "ko": "한국어",
        "zh-Hans": "简体中文",
        "zh-Hant": "繁體中文",
    ]

    /// The language menu, built from `shippedLocalizations`. A catalogue added
    /// there without a native name drops out of this list, and
    /// `LanguageChoiceTests` fails: a hand-written menu once offered four
    /// of six shipped languages, with no 한국어 and no Español.
    public static let languageOptions: [LanguageOption] = shippedLocalizations.compactMap { id in
        nativeNames[id].map { LanguageOption(id: id, nativeName: $0) }
    }

    private static func canonicalLocalization(_ raw: String) -> String? {
        shippedLocalizations.first { $0.caseInsensitiveCompare(raw) == .orderedSame }
    }

    /// The `en.lproj` bundle, resolved once.
    ///
    /// `L10n.tr` uses this as a last-resort fallback so a key that is
    /// missing from the active locale renders **English copy** rather
    /// than the raw dotted identifier. See `L10n.resolve(_:)`.
    ///
    /// Resolved eagerly into a `static let` because the miss path runs
    /// inside SwiftUI `body` evaluation; a `nil` here (bundle failed to
    /// load entirely) simply restores the pre-fallback behaviour.
    public static let englishBundle: Bundle? = bundle(forLocalization: "en")

    private static func resolutionCandidates(for override: String) -> [String] {
        var candidates = [override]
        let lower = override.lowercased()
        if lower != override { candidates.append(lower) }
        return candidates
    }

    /// Internal, not private, so tests can list the `.lproj` directories the
    /// bundle really ships.
    static func resourceBundle() -> Bundle {
        #if SWIFT_PACKAGE
        return .module
        #else
        return Bundle(for: BundleToken.self)
        #endif
    }
}

#if !SWIFT_PACKAGE
private final class BundleToken {}
#endif
