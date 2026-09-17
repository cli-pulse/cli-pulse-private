import XCTest
@testable import CLIPulseCore

/// `L10n.pet.formName` composes its key at runtime — `tr("pet.form_\(form.rawValue)")`
/// — so no literal names the 71 keys it reads, and nothing tested them. A
/// `PetForm` case added without its key showed "pet.form_<raw>" in the Cattery
/// grid, in its VoiceOver label and as the companion's default name, in all six
/// languages: en lacks it too, so there is no English to fall back to.
///
/// `scripts/check_apple_strings_parity.py` now expands the composed key over
/// `PetForm`'s cases from the source. These tests hold the same line from the
/// compiled enum, and tie the accessor to the key it composes.
final class PetFormNameLocalizationTests: XCTestCase {

    private var savedOverride: String?

    override func setUp() {
        super.setUp()
        savedOverride = LocaleOverrideStore.shared.override
    }

    override func tearDown() {
        LocaleOverrideStore.shared.set(savedOverride)
        super.tearDown()
    }

    /// Asked of each locale's own catalogue, without the English fallback, so a
    /// name missing from ja alone is reported as missing from ja.
    func testEveryFormHasItsNameInEveryShippedLocale() {
        let keys = PetForm.allCases.map { "pet.form_\($0.rawValue)" }
        XCTAssertGreaterThan(keys.count, 60, "PetForm.allCases is not the real enum")

        var report: [String] = []
        for locale in LocaleOverrideStore.shippedLocalizations {
            let missing = LocaleCatalogueProbe.missing(keys, in: locale)
            if !missing.isEmpty {
                report.append("\(locale).lproj lacks \(missing.count): \(missing.joined(separator: ", "))")
            }
        }
        XCTAssertTrue(report.isEmpty, "A cat's name renders as its raw key:\n" + report.joined(separator: "\n"))
    }

    /// The accessor reads exactly those keys. Under ja, where every name differs
    /// from its key and from English, a composition change (a renamed prefix, a
    /// case name instead of the raw value) cannot pass.
    func testFormNameReadsItsComposedKeyInJapanese() {
        LocaleOverrideStore.shared.set("ja")
        for form in PetForm.allCases {
            let key = "pet.form_\(form.rawValue)"
            let shown = L10n.pet.formName(form)
            XCTAssertNotEqual(shown, key, "\(form) renders its raw key")
            guard let own = LocaleCatalogueProbe.ownValue(key, in: "ja") else {
                XCTFail("ja.lproj lacks \(key)")
                continue
            }
            XCTAssertEqual(shown, L10n.keepingBrandUnbroken(own), "formName(.\(form)) does not read \(key)")
        }
    }
}
