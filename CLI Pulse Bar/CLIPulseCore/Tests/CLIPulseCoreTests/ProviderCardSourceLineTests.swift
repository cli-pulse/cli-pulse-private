import XCTest
@testable import CLIPulseCore

/// v1.58: two small things on the Mac provider card.
///
/// - The plan-and-source line read "Source: Local" right above the usage
///   figures' scope, "All devices", and the two read as disagreeing. They are
///   about different things: where the quota is read, and whose usage the
///   figures count. On a card with a quota the line now says what it is the
///   source of; on every card it calls this Mac by the scope's own name for it.
/// - The layout that keeps the chart beside figures with long units draws each
///   unit under its number; the unit is the headline's words around the number,
///   in each language's own order.
///
/// Asserted in zh-Hans, ja and es: an English assertion passes with the lookup
/// broken, because the fallback is English.
final class ProviderCardSourceLineTests: XCTestCase {
    private var savedOverride: String?

    override func setUp() {
        super.setUp()
        savedOverride = LocaleOverrideStore.shared.override
    }

    override func tearDown() {
        LocaleOverrideStore.shared.set(savedOverride)
        super.tearDown()
    }

    func testTheSourceLineNamesTheQuotaAndCallsThisMacByTheScopesName() {
        LocaleOverrideStore.shared.set("zh-Hans")
        XCTAssertEqual(ProviderCardUsage.sourceLineText(.local, cardShowsQuota: true), "配额来源：这台 Mac")
        XCTAssertEqual(ProviderCardUsage.sourceLineText(.merged, cardShowsQuota: true), "配额来源：云端 + 这台 Mac")
        XCTAssertEqual(ProviderCardUsage.sourceLineText(.api, cardShowsQuota: true), "配额来源：API")
        for source in SourceType.allCases {
            let line = ProviderCardUsage.sourceLineText(source, cardShowsQuota: true)
            XCTAssertNotEqual(line, L10n.providers.sourceLabel(source.localizedName),
                              "\(source): the old line, which does not say it is the quota's source")
            XCTAssertFalse(line.contains(UsageDataScope.allDevices.label), "\(source): \(line)")
            // Never "local" (本地) for this Mac, alone or merged: the scope's name.
            XCTAssertFalse(line.contains("本地"), "\(source): \(line)")
        }
        // This Mac is the scope's own name for it, one string.
        XCTAssertTrue(ProviderCardUsage.sourceLineText(.local, cardShowsQuota: true)
            .hasSuffix(UsageDataScope.thisMac.label))

        LocaleOverrideStore.shared.set("ja")
        XCTAssertEqual(ProviderCardUsage.sourceLineText(.local, cardShowsQuota: true), "クォータの取得元: この Mac")
        LocaleOverrideStore.shared.set("es")
        XCTAssertEqual(ProviderCardUsage.sourceLineText(.local, cardShowsQuota: true), "Fuente de la cuota: Este Mac")
        XCTAssertEqual(ProviderCardUsage.sourceLineText(.merged, cardShowsQuota: true),
                       "Fuente de la cuota: Nube + este Mac")
        LocaleOverrideStore.shared.set("zh-Hant")
        XCTAssertEqual(ProviderCardUsage.sourceLineText(.local, cardShowsQuota: true), "配額來源：這台 Mac")
    }

    /// 1.60 (C26): the provider editor's Data source picker names a source
    /// as the card does: this Mac is "This Mac" there too (Cursor's local
    /// source), not "Local".
    func testThePickerCallsThisMacWhatTheCardCallsIt() {
        let expected: [String: (String, String)] = [
            "en": ("This Mac", "Cloud + this Mac"),
            "zh-Hans": ("这台 Mac", "云端 + 这台 Mac"),
            "zh-Hant": ("這台 Mac", "雲端 + 這台 Mac"),
            "ja": ("この Mac", "クラウド + この Mac"),
            "ko": ("이 Mac", "클라우드 + 이 Mac"),
            "es": ("Este Mac", "Nube + este Mac"),
        ]
        for (language, names) in expected {
            LocaleOverrideStore.shared.set(language)
            XCTAssertEqual(SourceType.local.localizedName, names.0, language)
            XCTAssertEqual(SourceType.merged.localizedName, names.1, language)
            XCTAssertEqual(SourceType.local.localizedName, UsageDataScope.thisMac.label, language)
            for source in SourceType.allCases {
                XCTAssertEqual(ProviderCardUsage.sourceName(source), source.localizedName,
                               "\(language) \(source): the card and the picker name it differently")
            }
        }
        // The picker that offers it: Cursor's.
        XCTAssertTrue(ProviderRegistry.descriptor(for: .cursor).supportedSources.contains(.local))
    }

    /// A card with no quota does not say "Quota source": beside "No quota
    /// source" (a tool with no quota API we can read) or "Quota data
    /// unavailable" it would claim a quota the card does not have. The line
    /// stays neutral there, and still calls this Mac "This Mac".
    func testACardWithNoQuotaKeepsTheNeutralSourceLine() {
        LocaleOverrideStore.shared.set("zh-Hans")
        XCTAssertEqual(ProviderCardUsage.sourceLineText(.local, cardShowsQuota: false), "来源：这台 Mac")
        XCTAssertEqual(ProviderCardUsage.sourceLineText(.api, cardShowsQuota: false), "来源：API")
        XCTAssertEqual(ProviderCardUsage.sourceLineText(.merged, cardShowsQuota: false), "来源：云端 + 这台 Mac")

        func shows(visible: Bool = true, tiers: Int = 0, quota: Int? = nil, provider: String = "Codex",
                   outcome: CollectorOutcome? = .producedData) -> Bool {
            ProviderCardUsage.cardShowsQuota(
                quotaVisible: visible, tierCount: tiers, overallQuota: quota, provider: provider,
                collectorOutcome: outcome)
        }
        XCTAssertTrue(shows(tiers: 3), "quota tiers")
        XCTAssertTrue(shows(quota: 100), "the one quota bar of a provider without tiers")
        XCTAssertTrue(shows(tiers: 2, outcome: nil), "no outcome recorded (signed in, read from the account)")
        XCTAssertFalse(shows(outcome: .unsupported), "no collector: the card says No quota source")
        XCTAssertFalse(shows(tiers: 2, quota: 100, outcome: .unsupported), "no collector, whatever came with the row")
        XCTAssertFalse(shows(outcome: .ranButEmpty), "a quota that did not load")
        XCTAssertFalse(shows(outcome: .failed(.network)), "a quota that did not load")
        XCTAssertFalse(shows(quota: 100, provider: "Claude"),
                       "Claude without tiers draws Quota data unavailable, not an overall bar")
        XCTAssertFalse(shows(visible: false, tiers: 3), "the Quota section hidden from this card")
    }

    /// The unit under the number, in the languages whose month of Claude
    /// messages pushed the chart under the figures (ja, es), and in zh-Hans.
    func testTheUnitIsTheHeadlinesWordsAroundItsNumber() {
        let count = 12_400
        for (locale, unit) in [("zh-Hans", "条消息"), ("ja", "メッセージ"), ("es", "mensajes")] {
            LocaleOverrideStore.shared.set(locale)
            let value = CostFormatter.formatUsage(count)
            XCTAssertEqual(ProviderCardUsage.headlineUnit(L10n.providers.messagesShort(count), value: value), unit, locale)
        }
        LocaleOverrideStore.shared.set("es")
        XCTAssertEqual(ProviderCardUsage.headlineUnit(ProviderCardUsage.tokenBasis.tokensText(85_900),
                                                      value: CostFormatter.formatUsage(85_900)), "E/S")
        LocaleOverrideStore.shared.set("ja")
        XCTAssertEqual(ProviderCardUsage.headlineUnit(ProviderCardUsage.tokenBasis.tokensText(85_900),
                                                      value: CostFormatter.formatUsage(85_900)), "I/O")
        // Nothing to put under the number.
        XCTAssertNil(ProviderCardUsage.headlineUnit("—", value: "—"))
        XCTAssertNil(ProviderCardUsage.headlineUnit("289", value: "289"))
        XCTAssertNil(ProviderCardUsage.headlineUnit("289 msgs", value: ""))
        XCTAssertNil(ProviderCardUsage.headlineUnit("289 msgs", value: "12"), "a number the headline does not hold")
        // Either order.
        XCTAssertEqual(ProviderCardUsage.headlineUnit("msgs\u{00A0}289", value: "289"), "msgs")
    }
}
