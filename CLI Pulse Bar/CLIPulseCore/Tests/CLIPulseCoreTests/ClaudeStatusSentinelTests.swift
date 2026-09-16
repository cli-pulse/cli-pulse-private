import XCTest
@testable import CLIPulseCore

/// The Claude hint lines are written as English data and translated at render time.
/// Asserted under zh-Hans, because under English a broken mapping and a working one
/// return the same text.
final class ClaudeStatusSentinelTests: XCTestCase {
    private var saved: String?

    override func setUp() {
        super.setUp()
        saved = LocaleOverrideStore.shared.override
    }

    override func tearDown() {
        LocaleOverrideStore.shared.set(saved)
        super.tearDown()
    }

    /// The sentinel must be the English catalogue text, or the English UI would show
    /// one wording and every other language a translation of a different one.
    func testSentinelsAreTheEnglishCatalogueText() {
        LocaleOverrideStore.shared.set("en")
        XCTAssertEqual(ClaudeStatusSentinel.signedInConnect("a@b.co"), L10n.providers.claudeSignedInConnectHint("a@b.co"))
        XCTAssertEqual(ClaudeStatusSentinel.quotaUnavailable, L10n.providers.claudeQuotaUnavailableHint)
    }

    func testRenderedInTheReadersLanguage() {
        LocaleOverrideStore.shared.set("zh-Hans")
        let signedIn = L10n.providers.localizedStatusText(ClaudeStatusSentinel.signedInConnect("dev@example.com"))
        XCTAssertEqual(signedIn, L10n.providers.claudeSignedInConnectHint("dev@example.com"))
        XCTAssertNotEqual(signedIn, ClaudeStatusSentinel.signedInConnect("dev@example.com"), "still English under zh-Hans")
        XCTAssertTrue(signedIn.contains("dev@example.com"))

        let unavailable = L10n.providers.localizedStatusText(ClaudeStatusSentinel.quotaUnavailable)
        XCTAssertEqual(unavailable, L10n.providers.claudeQuotaUnavailableHint)
        XCTAssertNotEqual(unavailable, ClaudeStatusSentinel.quotaUnavailable)
    }

    func testLookalikesPassThrough() {
        LocaleOverrideStore.shared.set("zh-Hans")
        for raw in ["Signed in as  — Connect Claude Code in Settings", "Signed in as x", "5h 60% left · Weekly 40% left"] {
            XCTAssertEqual(L10n.providers.localizedStatusText(raw), raw)
        }
    }
}
