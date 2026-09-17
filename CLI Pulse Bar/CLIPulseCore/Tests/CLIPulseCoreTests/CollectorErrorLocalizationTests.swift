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

    /// Replaces a test that pinned the OLD behaviour on purpose — the credential
    /// payloads were English strings passed through verbatim, and that test was
    /// written to start failing when they were localized. They now are.
    func testCredentialPayloadsAreLocalizedAndKeepTheirTechnicalTokens() {
        withChinese {
            let problem = CredentialProblem("Poe", .noAPIKeySetEnv("POE_API_KEY"))
            for error in [CollectorError.missingCredentials(problem),
                          CollectorError.notSignedIn(problem),
                          CollectorError.silentBackoff(problem)] {
                let shown = error.localizedDescription
                XCTAssertNotEqual(shown, "Poe: no API key (set POE_API_KEY)", "still English under zh-Hans")
                XCTAssertTrue(shown.contains("Poe"), "the provider was dropped: \(shown)")
                XCTAssertTrue(shown.contains("POE_API_KEY"),
                              "the environment variable was translated or dropped: \(shown)")
                XCTAssertFalse(shown.contains("%"), "an unfilled specifier leaked: \(shown)")
            }
        }
    }

    /// Logs stay English whatever the UI language, so a log line from a Mac set
    /// to Chinese can be grepped against one from a Mac set to English.
    func testLogTextStaysEnglishUnderAnyLocale() {
        withChinese {
            let error = CollectorError.missingCredentials(CredentialProblem("Kimi K2", .noAPIKey))
            XCTAssertEqual(error.logText, "Kimi K2: no API key found")
            XCTAssertEqual(CollectorError.logText(for: error), "Kimi K2: no API key found")
            XCTAssertNotEqual(error.localizedDescription, error.logText, "the UI text did not localize")
        }
    }

    /// The three wrapper cases log in English too, not only the credential ones.
    func testWrapperCasesLogInEnglishUnderAnyLocale() {
        withChinese {
            let cases: [(CollectorError, String)] = [
                (.invalidURL("https://x"), "Invalid URL: https://x"),
                (.httpError(status: 503, provider: "Groq"), "Groq returned HTTP 503"),
                (.parseFailed("bad JSON"), "Parse failed: bad JSON"),
            ]
            for (error, english) in cases {
                XCTAssertEqual(error.logText, english)
                XCTAssertNotEqual(error.localizedDescription, english, "the UI text did not localize")
            }
        }
    }

    /// Server-supplied text has no template; it passes through in both renderings.
    func testServerSuppliedDetailPassesThroughVerbatim() {
        withChinese {
            let problem = CredentialProblem("Abacus AI", .serverMessage("Invalid session token"))
            XCTAssertEqual(problem.englishText, "Abacus AI: Invalid session token")
            XCTAssertTrue(problem.localizedText.contains("Invalid session token"))
        }
    }

    /// "解析失败：Deepgram: no projects for this API key" called a setup problem a
    /// parse failure, in two languages. The setup conditions have their own case.
    func testSetupProblemsAreLocalizedAndNotCalledParseFailures() {
        withChinese {
            let noProjects = CollectorError.noData(provider: "Deepgram", reason: .noProjectsForKey)
            XCTAssertEqual(noProjects.localizedDescription, "Deepgram：此 API 密钥下没有项目")
            XCTAssertEqual(noProjects.logText, "Deepgram: no projects for this API key")

            let noQuota = CollectorError.noData(provider: "Vertex AI", reason: .noQuotaForProject)
            XCTAssertEqual(noQuota.localizedDescription, "Vertex AI：此项目没有配额数据")
            XCTAssertEqual(noQuota.logText, "Vertex AI: no quota data for this project")

            let parseWrapper = L10n.collectorError.parseFailed("")
            for error in [noProjects, noQuota] {
                XCTAssertFalse(error.localizedDescription.hasPrefix(parseWrapper), "still wrapped as a parse failure")
            }
        }
        // The uploaded device diagnostic keeps the bucket these reported under before.
        XCTAssertEqual(CollectorFailureCategory.categorize(
            CollectorError.noData(provider: "Deepgram", reason: .noProjectsForKey)), .parse)
    }

    func testCredentialCasesStillCategorizeAsAuth() {
        let problem = CredentialProblem(nil, .sessionRejected)
        XCTAssertEqual(CollectorFailureCategory.categorize(CollectorError.missingCredentials(problem)), .auth)
        XCTAssertEqual(CollectorFailureCategory.categorize(CollectorError.notSignedIn(problem)), .auth)
    }
}
#endif
