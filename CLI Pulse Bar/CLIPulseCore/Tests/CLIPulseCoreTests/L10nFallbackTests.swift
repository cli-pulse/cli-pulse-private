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
/// Negative control (run by hand when changing `resolve`): replace the English
/// lookup at the end of `L10n.resolve` with `return format` and re-run —
/// `test_untranslatedKeysFallBackToTheEnglishString` and
/// `test_parameterisedKeyInterpolatesThroughTheFallback` must fail. Verified red
/// on 2026-08-30 against the real catalogues (670 misses across es/ja/ko/zh-Hant),
/// and on 2026-09-17 against the synthetic catalogue, once the real ones reached
/// parity and the sweep could no longer reach the fallback.
final class L10nFallbackTests: XCTestCase {

    /// Every shipped `.lproj`. The store's list, not a copy of it:
    /// `LanguageChoiceTests` pins that list to the directories on disk, so a
    /// new catalogue cannot be left out of this sweep.
    private static let shippedLocales = LocaleOverrideStore.shippedLocalizations

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

    /// Exercises the fallback branch directly and pins that the value handed back
    /// is the **English string**, not merely "something other than the key".
    ///
    /// The shipped catalogues reached full parity on 2026-09-17, so no real key
    /// reaches this branch any more and the sweep above would stay green with the
    /// fallback deleted. It still matters: it is what a user sees if a key ever
    /// ships untranslated. So the test builds its own two-locale catalogue with a
    /// key only English carries, and runs the production lookup over it.
    func test_untranslatedKeysFallBackToTheEnglishString() throws {
        let (english, spanish) = try makeCatalogues(
            english: ["shared.title": "Shared", "only.english": "Only in English"],
            spanish: ["shared.title": "Compartido"]
        )

        XCTAssertEqual(L10n.resolve("shared.title", active: spanish, english: english), "Compartido",
                       "a key the locale carries must come from the locale, not from English")
        XCTAssertEqual(L10n.resolve("only.english", active: spanish, english: english), "Only in English",
                       "a key the locale lacks did not fall back to the English copy")
        XCTAssertEqual(L10n.resolve("in.neither", active: spanish, english: english), "in.neither",
                       "a key in no catalogue has nothing to fall back to")
    }

    /// `String(format:)` still has to work through the fallback: a
    /// parameterised key missing from the active locale must come back as
    /// interpolated English, not a format string with live `%@`.
    func test_parameterisedKeyInterpolatesThroughTheFallback() throws {
        let (english, spanish) = try makeCatalogues(
            english: ["wizard.step": "Step %d of %d: %@"],
            spanish: [:]
        )
        let format = L10n.resolve("wizard.step", active: spanish, english: english)
        let rendered = String(format: format, 3, 6, "Your Coding Agents")

        XCTAssertEqual(rendered, "Step 3 of 6: Your Coding Agents")
    }

    /// Writes an `en.lproj` and an `es.lproj` into a temporary directory and opens
    /// each as a bundle — the same shape `LocaleOverrideStore.bundle(forLocalization:)`
    /// hands to the production lookup.
    private func makeCatalogues(
        english: [String: String],
        spanish: [String: String]
    ) throws -> (english: Bundle, spanish: Bundle) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("L10nFallbackTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        func write(_ table: [String: String], locale: String) throws -> Bundle {
            let dir = root.appendingPathComponent("\(locale).lproj", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try (table as NSDictionary).write(to: dir.appendingPathComponent("Localizable.strings"))
            return try XCTUnwrap(Bundle(path: dir.path), "could not open \(locale).lproj as a bundle")
        }
        return (try write(english, locale: "en"), try write(spanish, locale: "es"))
    }
}
