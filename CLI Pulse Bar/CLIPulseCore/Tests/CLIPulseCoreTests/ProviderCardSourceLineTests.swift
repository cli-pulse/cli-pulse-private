import XCTest
@testable import CLIPulseCore

/// v1.58: two small things on the Mac provider card.
///
/// - The plan-and-source line read "Source: Local" right above the usage
///   figures' scope, "All devices", and the two read as disagreeing. They are
///   about different things: where the quota is read, and whose usage the
///   figures count. The line now says what it is the source of and calls this
///   Mac by the scope's own name for it.
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
        XCTAssertEqual(ProviderCardUsage.quotaSourceText(.local), "配额来源：这台 Mac")
        XCTAssertEqual(ProviderCardUsage.quotaSourceText(.merged), "配额来源：云端 + 本地")
        XCTAssertEqual(ProviderCardUsage.quotaSourceText(.api), "配额来源：API")
        for source in SourceType.allCases {
            let line = ProviderCardUsage.quotaSourceText(source)
            XCTAssertNotEqual(line, L10n.providers.sourceLabel(source.localizedName),
                              "\(source): the old line, which does not say it is the quota's source")
            XCTAssertFalse(line.contains(UsageDataScope.allDevices.label), "\(source): \(line)")
        }
        // This Mac is the scope's own name for it, one string.
        XCTAssertTrue(ProviderCardUsage.quotaSourceText(.local).hasSuffix(UsageDataScope.thisMac.label))
        XCTAssertFalse(ProviderCardUsage.quotaSourceText(.local).contains(L10n.providerConfig.sourceLocal))

        LocaleOverrideStore.shared.set("ja")
        XCTAssertEqual(ProviderCardUsage.quotaSourceText(.local), "クォータの取得元: この Mac")
        LocaleOverrideStore.shared.set("es")
        XCTAssertEqual(ProviderCardUsage.quotaSourceText(.local), "Fuente de la cuota: Este Mac")
        LocaleOverrideStore.shared.set("zh-Hant")
        XCTAssertEqual(ProviderCardUsage.quotaSourceText(.local), "配額來源：這台 Mac")
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
