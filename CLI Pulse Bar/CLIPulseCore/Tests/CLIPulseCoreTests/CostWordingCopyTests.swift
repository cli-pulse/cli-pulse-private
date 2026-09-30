import XCTest
@testable import CLIPulseCore

/// What the cost and token help texts claim, in every language.
///
/// - The Overview's token tooltip compared the figure with another app's and
///   said the two costs "matched". They did not, and the comparison was wrong
///   about Codex tokens too. The key is gone, and no displayed string names
///   that app again.
/// - The I/O token help said cache was excluded, for every provider. That is
///   true of Claude only: Codex's `input` already includes cached input. The
///   numbers are unchanged; the text now says which provider counts what.
/// - The Usage Dashboard's cost carried no estimate wording, unlike every other
///   cost in the app.
final class CostWordingCopyTests: XCTestCase {

    private var savedOverride: String?

    override func setUp() {
        super.setUp()
        savedOverride = LocaleOverrideStore.shared.override
    }

    override func tearDown() {
        LocaleOverrideStore.shared.set(savedOverride)
        super.tearDown()
    }

    private func catalogue(_ localization: String) throws -> [String: String] {
        let bundle = try XCTUnwrap(LocaleOverrideStore.bundle(forLocalization: localization))
        let url = try XCTUnwrap(bundle.url(forResource: "Localizable", withExtension: "strings"))
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
    }

    // MARK: - No comparison with another app

    /// Broader than the rule it guards (UI text must not compare our numbers
    /// with another product's): it bans the name outright. An in-app credit for
    /// code ported from that project would be allowed; allowlist its key here.
    func testNoDisplayedStringComparesUsWithCodexBar() throws {
        for localization in LocaleOverrideStore.shippedLocalizations {
            let values = try catalogue(localization)
            let named = values.filter {
                $0.key.localizedCaseInsensitiveContains("codexbar")
                    || $0.value.localizedCaseInsensitiveContains("codexbar")
            }.map(\.key)
            XCTAssertEqual(named, [], "\(localization): a displayed string or its key names another app")
        }
    }

    // MARK: - I/O tokens, per provider

    /// The Overview adds Claude and Codex tokens, so its help names both. The
    /// provider names are the same in every language.
    func testOverviewTokenHelpSpeaksForEachProviderInEveryLanguage() throws {
        for localization in LocaleOverrideStore.shippedLocalizations {
            let help = try XCTUnwrap(try catalogue(localization)["cost.io_tokens_help"], localization)
            XCTAssertTrue(help.contains("Claude"), "\(localization): \(help)")
            XCTAssertTrue(help.contains("Codex"), "\(localization): \(help)")
        }
    }

    func testTokenHelpSaysCodexInputIncludesCacheAndClaudeDoesNotInChinese() {
        LocaleOverrideStore.shared.set("zh-Hans")
        let overview = L10n.cost.ioTokensHelp
        XCTAssertTrue(overview.contains("Claude：不含缓存读取和缓存写入"), overview)
        XCTAssertTrue(overview.contains("Codex：输入已包含缓存输入"), overview)

        let codexCard = L10n.providers.codexIOTokensHelp
        XCTAssertTrue(codexCard.contains("输入已包含缓存输入"), codexCard)
        XCTAssertFalse(codexCard.contains("不含"), "the Codex card says cache is excluded: \(codexCard)")

        let claudeCard = L10n.providers.claudeMetricHelp
        XCTAssertTrue(claudeCard.contains("不含缓存读取和缓存写入"), claudeCard)
        XCTAssertFalse(claudeCard.contains("10%"), "cache reads are billed at 10% of the rate, not a 10% discount")

        // The estimate goes by the feature's own name, as in onboarding and
        // Settings, not a second word for the same thing.
        XCTAssertEqual(L10n.onboardingWizard.featureCostTitle, "费用预估")
        for help in [overview, codexCard, claudeCard] {
            XCTAssertTrue(help.contains("费用预估"), help)
            XCTAssertFalse(help.contains("费用估算"), help)
        }
    }

    /// In this catalogue "cuenta" means an account, so "como la cuenta OpenAI"
    /// read as "like the OpenAI account" rather than "the way OpenAI counts it".
    func testSpanishCodexHelpDoesNotReadAsAnAccount() {
        LocaleOverrideStore.shared.set("es")
        for help in [L10n.cost.ioTokensHelp, L10n.providers.codexIOTokensHelp] {
            XCTAssertTrue(help.contains("tal como la contabiliza OpenAI"), help)
            XCTAssertFalse(help.contains("cuenta OpenAI"), help)
        }
    }

    // MARK: - Usage Dashboard cost is an estimate

    /// The estimate word each catalogue already uses for the Overview's
    /// "30-Day Est.": the dashboard's cost label must carry the same one.
    private let estimateWord = [
        "en": "Est.", "es": "est.", "ja": "推定", "ko": "추정", "zh-Hans": "预估", "zh-Hant": "預估",
    ]

    func testUsageDashboardCostUsesTheEstimateWordInEveryLanguage() throws {
        for localization in LocaleOverrideStore.shippedLocalizations {
            let values = try catalogue(localization)
            let word = try XCTUnwrap(estimateWord[localization], localization)
            let overview = try XCTUnwrap(values["dashboard.30day_est"], localization)
            XCTAssertTrue(overview.localizedCaseInsensitiveContains(word),
                          "\(localization): the reference term moved: \(overview)")
            XCTAssertNil(values["usage_dashboard.total_cost"], "\(localization) still has the unqualified label")
            let label = try XCTUnwrap(values["usage_dashboard.total_cost_est"], localization)
            XCTAssertTrue(label.localizedCaseInsensitiveContains(word), "\(localization): \(label)")
            let disclaimer = try XCTUnwrap(values["usage_dashboard.cost_disclaimer"], localization)
            XCTAssertTrue(disclaimer.contains("API"), "\(localization): \(disclaimer)")
        }
    }

    func testUsageDashboardCostLabelInChinese() {
        LocaleOverrideStore.shared.set("zh-Hans")
        XCTAssertEqual(L10n.usageDashboard.totalCostEstimate, "预估总费用")
        XCTAssertEqual(L10n.usageDashboard.costDisclaimer, "费用是以 API 按量付费价格算出的预估值，不是真实账单。")
    }
}
