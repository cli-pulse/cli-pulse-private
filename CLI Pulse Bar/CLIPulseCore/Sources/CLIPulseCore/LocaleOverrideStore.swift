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
/// survives restarts. Posts `objectWillChange` and a notification on
/// every change so observing views (and `AppState`, which republishes
/// to its own observers) re-render localized strings without a relaunch.
public final class LocaleOverrideStore: ObservableObject {
    public static let shared = LocaleOverrideStore()

    /// Posted whenever the active override changes. Useful for
    /// `AppState` to forward to its own subscribers so SwiftUI views
    /// that don't directly observe `LocaleOverrideStore` still
    /// re-render localized text after a language switch.
    public static let didChangeNotification = Notification.Name("CLIPulseLocaleOverrideDidChange")

    private static let defaultsKey = "cli_pulse_locale_override"

    /// `nil` means "follow system default". Non-nil values are the
    /// matching `.lproj` directory name, e.g. `"en"`, `"ja"`,
    /// `"zh-Hans"`.
    @Published public private(set) var override: String?

    private init() {
        self.override = UserDefaults.standard.string(forKey: Self.defaultsKey)
    }

    public func set(_ newValue: String?) {
        guard newValue != override else { return }
        override = newValue
        if let newValue {
            UserDefaults.standard.set(newValue, forKey: Self.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    /// Bundle to read localized strings from. Falls back to the package
    /// resource bundle when the override doesn't resolve to a known
    /// `.lproj` directory.
    public var bundle: Bundle {
        let base = Self.resourceBundle()
        guard let override else { return base }
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
    public static var resolvedLocalization: String? {
        if let override = shared.override,
           let canonical = canonicalLocalization(override),
           bundle(forLocalization: override) != nil {
            return canonical
        }
        for candidate in resourceBundle().preferredLocalizations {
            if let canonical = canonicalLocalization(candidate) {
                return canonical
            }
        }
        return nil
    }

    /// The catalogues this app ships. Kept here rather than in the telemetry
    /// layer because it is a fact about the resource bundle, and
    /// `L10nFallbackTests` already pins the same list against what is on disk.
    public static let shippedLocalizations = ["en", "es", "ja", "ko", "zh-Hans", "zh-Hant"]

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

    private static func resourceBundle() -> Bundle {
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
