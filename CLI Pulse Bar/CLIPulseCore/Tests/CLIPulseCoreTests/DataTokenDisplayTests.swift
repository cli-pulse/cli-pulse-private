import XCTest
@testable import CLIPulseCore

/// Values that are stored identifiers but were rendered as if they were words.
/// Each is mapped at display time; the stored value is untouched, because the
/// views and the persisted config still compare against it.
final class DataTokenDisplayTests: XCTestCase {

    private func withLocale(_ id: String, _ body: () -> Void) {
        let store = LocaleOverrideStore.shared
        let previous = store.override
        store.set(id)
        defer { store.set(previous) }
        body()
    }

    // MARK: - Source type

    /// The source picker used to render `rawValue` — "oauth", "api", "merged" —
    /// which read as lowercase debug tokens even in English.
    func testSourceTypesNoLongerRenderTheirStoredIdentifier() {
        withLocale("en") {
            for source in SourceType.allCases {
                XCTAssertNotEqual(source.localizedName, source.rawValue,
                                  "\(source) still renders its stored identifier")
                XCTAssertFalse(source.localizedName.isEmpty)
            }
            XCTAssertEqual(SourceType.oauth.localizedName, "OAuth")
            XCTAssertEqual(SourceType.api.localizedName, "API")
            XCTAssertEqual(SourceType.cli.localizedName, "CLI")
        }
    }

    func testTranslatableSourceTypesAreLocalized() {
        let translatable: [SourceType] = [.auto, .local, .merged]
        var english: [SourceType: String] = [:]
        withLocale("en") { for s in translatable { english[s] = s.localizedName } }
        withLocale("zh-Hans") {
            for s in translatable {
                XCTAssertNotEqual(s.localizedName, english[s], "\(s) is still English under zh-Hans")
            }
        }
    }

    /// The stored value must not move: persisted configs and the helper decode it.
    func testSourceTypeRawValuesAreUnchanged() {
        XCTAssertEqual(SourceType.allCases.map(\.rawValue),
                       ["auto", "web", "cli", "oauth", "api", "local", "merged"])
    }

    // MARK: - Cookie source

    func testBrowserNamesRenderAsWrittenAndTheRestAreLocalized() {
        withLocale("zh-Hans") {
            XCTAssertEqual(CookieSource.safari.localizedName, "Safari")
            XCTAssertEqual(CookieSource.chrome.localizedName, "Chrome")
            XCTAssertEqual(CookieSource.firefox.localizedName, "Firefox")
            XCTAssertNotEqual(CookieSource.automatic.localizedName, "Automatic")
            XCTAssertNotEqual(CookieSource.manual.localizedName, "Manual")
        }
    }

    // MARK: - Plan

    /// "Multiple accounts" is the one plan value the app composes itself
    /// (`APIClient`); `ProviderAccountAPITests` pins that producer. This pins the
    /// other end, so rewording either side fails loudly instead of the badge
    /// silently going back to English.
    func testTheComposedPlanValueIsLocalizedAndVendorPlansPassThrough() {
        withLocale("zh-Hans") {
            XCTAssertNotEqual(L10n.providers.planDisplay("Multiple accounts"), "Multiple accounts")
            for vendorPlan in ["Pro", "Max 5x", "Paid", "Free", "Team", ""] {
                XCTAssertEqual(L10n.providers.planDisplay(vendorPlan), vendorPlan,
                               "\(vendorPlan) is a vendor plan name and must render as written")
            }
        }
    }
}
