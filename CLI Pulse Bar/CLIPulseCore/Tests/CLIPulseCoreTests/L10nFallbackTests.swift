import XCTest
@testable import CLIPulseCore

/// A1 (2026-08-30): `L10n.tr` called `NSLocalizedString` with no `value:`,
/// so a key missing from the active `.lproj` rendered **the raw dotted
/// identifier**. CFBundle resolves one `.lproj` and does not fall back
/// per-key, so es (774 keys) and ko (774) showed `onboarding_wizard.*`
/// debug output on the first-run screen — 3 of 80 wizard keys present —
/// while ja and zh-Hant were missing the whole 52-key v2 wizard.
///
/// `L10n.resolve(_:)` now re-looks-up misses in `en.lproj`. These tests
/// sweep **every** key of the base catalogue through **every** shipped
/// locale over the real production path, so the invariant they pin is the
/// user-visible one: no screen, in any language, ever renders a dotted key.
///
/// Negative control (run by hand when changing `resolve`): delete the
/// English-fallback `guard` in `L10n.resolve` **in place** and re-run —
/// `test_noShippedLocaleEverRendersARawKey` must fail and name the locale
/// and the missing keys. Verified red on 2026-08-30 (670 misses across
/// es/ja/ko/zh-Hant) before the fix, green after.
final class L10nFallbackTests: XCTestCase {

    /// Every `.lproj` the two Info.plists declare as shipped.
    private static let shippedLocales = ["en", "es", "ja", "ko", "zh-Hans", "zh-Hant"]

    private var savedOverride: String?

    override func setUp() {
        super.setUp()
        savedOverride = LocaleOverrideStore.shared.override
    }

    override func tearDown() {
        LocaleOverrideStore.shared.set(savedOverride)
        super.tearDown()
    }

    // MARK: - Helpers

    /// Keys declared in a locale's own `Localizable.strings`, read straight
    /// from the resource bundle rather than from a source path, so the test
    /// asserts against the artifact that actually ships.
    private func declaredKeys(in localization: String) throws -> Set<String> {
        let bundle = try XCTUnwrap(
            LocaleOverrideStore.bundle(forLocalization: localization),
            "\(localization).lproj is not in the resource bundle"
        )
        let url = try XCTUnwrap(
            bundle.url(forResource: "Localizable", withExtension: "strings"),
            "\(localization).lproj carries no Localizable.strings"
        )
        let dict = try XCTUnwrap(
            NSDictionary(contentsOf: url) as? [String: String],
            "\(localization).lproj/Localizable.strings did not parse as a strings file"
        )
        return Set(dict.keys)
    }

    // MARK: - The invariant

    /// The whole point of A1: for every shipped locale, every key in the
    /// base catalogue resolves to copy — never to its own identifier.
    func test_noShippedLocaleEverRendersARawKey() throws {
        let baseKeys = try declaredKeys(in: "en")
        XCTAssertGreaterThan(
            baseKeys.count, 1000,
            "en.lproj parsed to \(baseKeys.count) keys — the harness is not reading the real catalogue"
        )

        var report: [String] = []
        for locale in Self.shippedLocales {
            LocaleOverrideStore.shared.set(locale)
            let echoed = baseKeys.filter { L10n.resolve($0) == $0 }.sorted()
            if !echoed.isEmpty {
                let sample = echoed.prefix(5).joined(separator: ", ")
                report.append("\(locale): \(echoed.count) key(s) render as the raw identifier — \(sample)")
            }
        }

        XCTAssertTrue(
            report.isEmpty,
            "Missing keys are rendering as debug identifiers:\n" + report.joined(separator: "\n")
        )
    }

    /// Guards the sweep against passing vacuously. If the base catalogue
    /// stopped loading, or the override never took effect, `resolve` would
    /// return English for everything and the sweep above would be green for
    /// the wrong reason.
    func test_localeOverrideActuallySwitchesCatalogue() throws {
        LocaleOverrideStore.shared.set("en")
        let english = L10n.resolve("tab.overview")
        LocaleOverrideStore.shared.set("zh-Hans")
        let chinese = L10n.resolve("tab.overview")

        XCTAssertEqual(english, "Overview")
        XCTAssertNotEqual(chinese, english, "the locale override did not swap the catalogue")
        XCTAssertNotEqual(chinese, "tab.overview")
    }

    /// Exercises the fallback branch directly on keys the incomplete
    /// locales genuinely lack, and pins that the value handed back is the
    /// **English string**, not merely "something other than the key".
    ///
    /// Goes quiet if a locale is ever brought to full parity — that is the
    /// intended end state, and `test_noShippedLocaleEverRendersARawKey`
    /// keeps covering the behaviour either way.
    func test_untranslatedKeysFallBackToTheEnglishString() throws {
        let baseKeys = try declaredKeys(in: "en")
        var localesExercised = 0

        for locale in Self.shippedLocales where locale != "en" {
            let own = try declaredKeys(in: locale)
            let untranslated = baseKeys.subtracting(own).sorted()
            guard !untranslated.isEmpty else { continue }
            localesExercised += 1

            LocaleOverrideStore.shared.set("en")
            let englishValues = untranslated.reduce(into: [String: String]()) { $0[$1] = L10n.resolve($1) }

            LocaleOverrideStore.shared.set(locale)
            for key in untranslated {
                XCTAssertEqual(
                    L10n.resolve(key), englishValues[key],
                    "\(locale) is missing \(key) and did not fall back to the English copy"
                )
            }
        }

        XCTAssertGreaterThan(
            localesExercised, 0,
            "no locale has untranslated keys — if that is genuinely true, delete this test"
        )
    }

    /// `String(format:)` still has to work through the fallback: a
    /// parameterised key missing from the active locale must come back as
    /// interpolated English, not a format string with live `%@`.
    func test_parameterisedKeyInterpolatesThroughTheFallback() throws {
        LocaleOverrideStore.shared.set("es")
        let rendered = L10n.onboardingWizard.stepProgress(current: 3, total: 6, name: "Your Coding Agents")

        XCTAssertFalse(rendered.contains("%"), "format specifier survived into the rendered string: \(rendered)")
        XCTAssertFalse(rendered.hasPrefix("onboarding_wizard."), "raw key rendered: \(rendered)")
        XCTAssertTrue(rendered.contains("3"))
        XCTAssertTrue(rendered.contains("6"))
        XCTAssertTrue(rendered.contains("Your Coding Agents"))
    }
}
