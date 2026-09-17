import XCTest
import SwiftUI
@testable import CLIPulseCore

/// The macOS language menu and what the choice reaches beyond CLIPulseCore's
/// own strings: the menu's rows, the display locale formatters use, and the
/// `AppleLanguages` mirror that system-supplied text reads at launch.
///
/// Every localized assertion runs under a non-English choice. CI runs in en,
/// and English is also the fallback copy, so an English assertion would pass
/// with the lookup broken.
final class LanguageChoiceTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "test.language-choice.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        LocaleOverrideStore.shared.set(nil)
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// What the suite itself holds. `object(forKey:)` falls through to
    /// NSGlobalDomain, where `AppleLanguages` always exists.
    private var writtenAppleLanguages: [String]? {
        defaults.persistentDomain(forName: suiteName)?["AppleLanguages"] as? [String]
    }

    // MARK: - The menu

    /// The menu was once four hand-written buttons with no 한국어 and no
    /// Español, although both catalogues were complete.
    func test_languageMenuOffersEveryShippedLocalization() {
        XCTAssertEqual(
            LocaleOverrideStore.languageOptions.map(\.id),
            LocaleOverrideStore.shippedLocalizations,
            "a shipped catalogue is missing from the language menu (no native name for it?)"
        )
        XCTAssertEqual(
            LocaleOverrideStore.languageOptions.map(\.nativeName),
            ["English", "Español", "日本語", "한국어", "简体中文", "繁體中文"]
        )
    }

    /// The menu reads `shippedLocalizations`, so the list itself has to match
    /// the catalogues on disk. Pinning the menu to the list alone would stay
    /// green if a seventh `.lproj` shipped and only the other copies of the
    /// list (the parity gate's) were updated: the menu would silently leave
    /// that language out, the defect this menu was rebuilt to fix.
    func test_shippedLocalizations_areTheCataloguesInTheResourceBundle() throws {
        let resources = try XCTUnwrap(LocaleOverrideStore.resourceBundle().resourceURL)
        let onDisk = try FileManager.default
            .contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "lproj" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .filter { $0.caseInsensitiveCompare("Base") != .orderedSame }
            // SwiftPM lowercases the directory names (zh-hans.lproj). Anything
            // not in the list keeps its own name so the failure names it.
            .map { name in
                LocaleOverrideStore.shippedLocalizations
                    .first { $0.caseInsensitiveCompare(name) == .orderedSame } ?? name
            }

        XCTAssertEqual(
            Set(onDisk), Set(LocaleOverrideStore.shippedLocalizations),
            "LocaleOverrideStore.shippedLocalizations does not match the .lproj directories in \(resources.path)"
        )
    }

    // MARK: - Display locale

    func test_displayLocale_isTheOverrideLanguage() {
        LocaleOverrideStore.shared.set("ja")
        XCTAssertEqual(LocaleOverrideStore.shared.displayLocale.language.languageCode, .japanese)

        LocaleOverrideStore.shared.set("zh-Hant")
        let traditional = LocaleOverrideStore.shared.displayLocale.language
        XCTAssertEqual(traditional.languageCode, .chinese)
        XCTAssertEqual(traditional.script, .hanTraditional)
    }

    func test_displayLocale_withoutOverride_isTheSystemLocale() {
        LocaleOverrideStore.shared.set(nil)
        XCTAssertEqual(LocaleOverrideStore.shared.displayLocale, Locale.autoupdatingCurrent)
    }

    /// The language changes; the user's region stays, so separators and date
    /// order are still theirs.
    func test_displayLocale_keepsTheUsersRegion() {
        let locale = LocaleOverrideStore.displayLocale(language: "es", base: Locale(identifier: "en_MX"))
        XCTAssertEqual(locale.language.languageCode, .spanish)
        XCTAssertEqual(locale.region, .mexico)
    }

    /// The accessor is what formatters read: a date through it under 日本語 is
    /// Japanese on an English machine.
    func test_dateFormattedThroughDisplayLocale_isJapanese() throws {
        LocaleOverrideStore.shared.set("ja")
        let formatter = DateFormatter()
        formatter.locale = LocaleOverrideStore.shared.displayLocale
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateStyle = .long
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-17T12:00:00Z"))

        XCTAssertEqual(formatter.string(from: date), "2026年9月17日")
    }

    /// The usage heatmap's month row read "Jan Feb Mar" under Chinese headings.
    /// This pins the symbol lookup only; that the view feeds it the locale its
    /// root put in the environment is `DisplayLocaleRootTests`.
    func test_heatmapMonthSymbols_areInTheLocaleTheyAreGiven() {
        LocaleOverrideStore.shared.set("ja")
        let symbols = UsageHeatmapGrid.shortMonthSymbols(locale: LocaleOverrideStore.shared.displayLocale)
        XCTAssertEqual(UsageHeatmapGrid.shortMonth(9, symbols: symbols), "9月")

        LocaleOverrideStore.shared.set("zh-Hans")
        let chinese = UsageHeatmapGrid.shortMonthSymbols(locale: LocaleOverrideStore.shared.displayLocale)
        XCTAssertEqual(UsageHeatmapGrid.shortMonth(1, symbols: chinese), "1月")
    }

    // MARK: - AppleLanguages

    func test_choice_isNotMirroredUntilTheAppAsks() {
        let store = LocaleOverrideStore(defaults: defaults)
        store.set("ja")
        XCTAssertNil(writtenAppleLanguages, "only the macOS app, at launch, may write AppleLanguages")
    }

    func test_choice_writesAppleLanguages_andSystemDefaultRemovesIt() {
        let store = LocaleOverrideStore(defaults: defaults)
        store.mirrorToAppleLanguages()

        store.set("ko")
        XCTAssertEqual(writtenAppleLanguages, ["ko"])
        store.set("zh-Hant")
        XCTAssertEqual(writtenAppleLanguages, ["zh-Hant"])

        store.set(nil)
        XCTAssertNil(writtenAppleLanguages)
    }

    /// Someone who picked a language before the mirror existed gets system text
    /// in it from the next launch without picking again.
    func test_mirroringAtLaunch_catchesUpAnEarlierChoice() {
        defaults.set("es", forKey: "cli_pulse_locale_override")
        let store = LocaleOverrideStore(defaults: defaults)
        store.mirrorToAppleLanguages()
        XCTAssertEqual(writtenAppleLanguages, ["es"])
    }

    /// With no in-app choice, a per-app language set in System Settings (the
    /// same key) is the user's and must survive launch.
    func test_mirroringAtLaunch_withoutAChoice_leavesSystemSettingsAlone() {
        defaults.set(["ko"], forKey: "AppleLanguages")
        let store = LocaleOverrideStore(defaults: defaults)
        store.mirrorToAppleLanguages()
        XCTAssertEqual(writtenAppleLanguages, ["ko"])
    }

    /// A launch with 日本語 chosen pins the resource bundle to Japanese through
    /// AppleLanguages, and a bundle resolves its language once. Picking System
    /// Default must still switch live, to what the system list says.
    func test_systemDefault_afterLaunchingWithAChoice_switchesLive() {
        defaults.set("ja", forKey: "cli_pulse_locale_override")
        let store = LocaleOverrideStore(defaults: defaults, systemPreferredLanguages: { ["ko-KR", "en-US"] })
        store.mirrorToAppleLanguages()

        store.set(nil)

        XCTAssertEqual(NSLocalizedString("tab.overview", bundle: store.bundle, comment: ""), "개요")
        XCTAssertEqual(store.displayLocale.language.languageCode, .korean)
    }

    func test_systemLocalization_picksTheShippedCatalogueForAPreferenceList() {
        XCTAssertEqual(LocaleOverrideStore.systemLocalization(preferences: ["zh-Hant-TW", "en"]), "zh-Hant")
        XCTAssertEqual(LocaleOverrideStore.systemLocalization(preferences: ["es-MX"]), "es")
        XCTAssertEqual(LocaleOverrideStore.systemLocalization(preferences: ["fr-FR"]), "en")
    }
}
