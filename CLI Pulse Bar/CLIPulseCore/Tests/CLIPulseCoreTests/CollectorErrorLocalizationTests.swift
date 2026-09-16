#if os(macOS)
import XCTest
@testable import CLIPulseCore

/// `CollectorError.errorDescription` is what macOS Settings shows under a
/// provider's Test Connection result, so it is user-facing copy — but the
/// hardcoded-strings gate could not see it. A `case … let x` pattern binding
/// reset the gate's declaration tracker, so the enclosing
/// `var errorDescription: String?` was forgotten and the whole body went
/// unscanned. That is how `GeminiOAuthError` came to have nine of its eleven
/// cases localized and two left in English, with every gate green.
///
/// The gate is fixed, but it still cannot see the throw-site payloads
/// (`missingCredentials`, `notSignedIn`), which are arguments rather than
/// returns. So these assertions exist as the guard for this family, and they
/// run under a forced zh-Hans override — in English the localized value equals
/// the English one and every check below would hold with the change reverted.
final class CollectorErrorLocalizationTests: XCTestCase {

    private func withChinese(_ body: () -> Void) {
        let store = LocaleOverrideStore.shared
        let previous = store.override
        store.set("zh-Hans")
        defer { store.set(previous) }
        body()
    }

    func testTheThreeWrappersAreLocalizedAndKeepTheirPayload() {
        withChinese {
            let url = CollectorError.invalidURL("https://example.com/x").localizedDescription
            XCTAssertFalse(url.hasPrefix("Invalid URL"), "invalidURL still renders the English wrapper")
            XCTAssertTrue(url.contains("https://example.com/x"), "the URL payload was dropped: \(url)")

            let parse = CollectorError.parseFailed("keyNotFound(tiers)").localizedDescription
            XCTAssertFalse(parse.hasPrefix("Parse"), "parseFailed still renders the English wrapper")
            XCTAssertTrue(parse.contains("keyNotFound(tiers)"), "the detail payload was dropped: \(parse)")

            let http = CollectorError.httpError(status: 429, provider: "Codex").localizedDescription
            XCTAssertNotEqual(http, "Codex HTTP 429", "httpError still renders the English wrapper")
            XCTAssertTrue(http.contains("Codex"), "the provider name was dropped: \(http)")
            XCTAssertTrue(http.contains("429"), "the status code was dropped: \(http)")
            XCTAssertFalse(http.contains("%"), "an unfilled specifier leaked: \(http)")
        }
    }

    /// The two Gemini OAuth cases that were left in English while their nine
    /// siblings were localized — the concrete bug the gate blind spot hid.
    func testTheTwoGeminiStragglersAreLocalized() {
        withChinese {
            let refresh = GeminiOAuthError.tokenRefreshFailed(500).errorDescription ?? ""
            XCTAssertFalse(refresh.hasPrefix("Token refresh failed"), "still English: \(refresh)")
            XCTAssertTrue(refresh.contains("500"), "the status was dropped: \(refresh)")

            let none = GeminiOAuthError.noRefreshToken.errorDescription ?? ""
            XCTAssertNotEqual(none, "No refresh token available", "still English: \(none)")
            XCTAssertFalse(none.isEmpty)
        }
    }

    /// Documents what this change does NOT cover, so the gap is visible rather
    /// than assumed closed. `missingCredentials` / `notSignedIn` /
    /// `silentBackoff` return their payload verbatim, and ~103 throw sites pass
    /// English into them. Localizing those needs typed cases (and a matching
    /// update to `CollectorFailureCategory.categorize`), which is a separate
    /// change. When it lands, this test should start failing and be rewritten.
    func testVerbatimPayloadCasesAreStillPassedThroughUnchanged() {
        withChinese {
            for error in [CollectorError.missingCredentials("Kimi: no API key found"),
                          CollectorError.notSignedIn("Cursor session expired"),
                          CollectorError.silentBackoff("backing off")] {
                let shown = error.localizedDescription
                let payload: String
                switch error {
                case .missingCredentials(let m), .notSignedIn(let m), .silentBackoff(let m): payload = m
                default: payload = ""
                }
                XCTAssertEqual(shown, payload,
                               "a payload case started transforming its message; update this test on purpose")
            }
        }
    }
}
#endif
