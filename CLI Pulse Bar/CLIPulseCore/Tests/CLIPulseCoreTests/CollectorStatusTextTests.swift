import XCTest
@testable import CLIPulseCore

/// Collector status lines are English data, translated where they are shown.
///
/// Two properties, checked for every builder:
///   * under English the rendered line is byte-identical to the stored one, which
///     only holds if each key's English value is exactly what its builder writes;
///   * under zh-Hans it is not, which only holds if the recognizer matches the
///     builder's output. Under English alone a broken recognizer passes, because
///     the fallback is the English line itself.
final class CollectorStatusTextTests: XCTestCase {
    private typealias S = CollectorStatusText
    private var saved: String?

    override func setUp() {
        super.setUp()
        saved = LocaleOverrideStore.shared.override
    }

    override func tearDown() {
        LocaleOverrideStore.shared.set(saved)
        super.tearDown()
    }

    private func render(_ raw: String, in locale: String) -> String {
        LocaleOverrideStore.shared.set(locale)
        return L10n.providers.localizedStatusText(raw)
    }

    /// One output of every builder, including both plural forms.
    private let everyBuilder: [String] = [
        S.percentLeft(40),
        S.windowPercentLeft(.fiveHour, 60),
        S.windowPercentLeft(.fourHour, 80),
        S.windowPercentLeft(.daily, 80),
        S.windowPercentLeft(.weekly, 40),
        S.windowPercentLeft(.monthly, 50),
        S.windowPercentLeft(.rolling, 75),
        S.usedOf("12", "100"),
        S.creditsUsedOf("250,000", "1,000,000"),
        S.tokensOf("300", "1,000"),
        S.keysOf("3", "5"),
        S.charactersOf("1.2K", "10K"),
        S.charactersOf("1.2K", "10K", overage: "1.23", currency: "USD"),
        S.creditsLeftOf("70", "100"),
        S.unitsLeftOf("70", "100", unit: "points"),
        S.poolCount("Refresh", "40", "100"),
        S.requestsLeft(1),
        S.requestsLeft(37),
        S.creditsRemaining("750"),
        S.creditsLeft("500"),
        S.credits("$12.50"),
        S.credit("$12.50"),
        S.balance("CNY 12.50"),
        S.balanceOf("$12.50"),
        S.balanceOfCredits("640"),
        S.thisMonth("$4.25"),
        S.remaining("$11.00"),
        S.amountOf("$18.00", "$30.00"),
        S.inDeficit("$3.00"),
        S.uncollected("$1.00"),
        S.today("$1.00"),
        S.month("$3.00"),
        S.deepSeekEmptyBalance("¥0.00"),
        S.deepSeekBalance(total: "¥12.30", paid: "¥10.00", granted: "¥2.30"),
        S.requests(1),
        S.requests(1234),
        S.audioHours("1.5"),
        S.billableHours("2"),
        S.tokens("1,500"),
        S.ttsCharacters("900"),
        S.requestsShort("150"),
        S.tokensShort("70"),
        S.requestsPerMinute("120"),
        S.tokensPerMinute("9000"),
        S.cachePerMinute("30.0"),
        S.modelsAvailable(1),
        S.modelsAvailable(3),
        S.modelsInstalled(1),
        S.modelsInstalled(2),
        S.runningInstalled(running: 1, installed: 2),
        S.activeSessions(1),
        S.activeSessions(3),
        S.unlimited,
        S.balanceUnavailable,
        S.balanceUnavailableForAPICalls,
        S.creditsDataUnavailable,
        S.noVeniceBalance,
        S.autoTopUp,
        S.planExpired,
        S.overdueInvoices,
        S.deployment("gpt-4o"),
        S.model("gpt-4o-2024-08-06"),
    ]

    func testEnglishReadersSeeTheStoredLineUnchanged() {
        for raw in everyBuilder {
            XCTAssertEqual(render(raw, in: "en"), raw, "the English catalogue disagrees with the builder")
        }
    }

    func testEveryBuilderIsTranslated() {
        for raw in everyBuilder {
            XCTAssertNotEqual(render(raw, in: "zh-Hans"), raw, "\(raw) still renders in English under zh-Hans")
        }
    }

    func testSegmentsAreTranslatedOneByOne() {
        let line = S.join([S.windowPercentLeft(.fiveHour, 60), S.windowPercentLeft(.weekly, 40)])
        XCTAssertEqual(line, "5h 60% left · Weekly 40% left")
        XCTAssertEqual(render(line, in: "zh-Hans"), "5h：剩余 60% · 每周：剩余 40%")
        XCTAssertEqual(render(S.usedOf("12", "100"), in: "zh-Hans"), "已使用 12/100")
        XCTAssertEqual(render(S.thisMonth("$3.00"), in: "ja"), "今月 $3.00")
        XCTAssertEqual(render(S.join(["CNY 12.50", S.planExpired]), in: "ja"), "CNY 12.50 · プラン期限切れ")
    }

    /// "300/1,000 tokens" has no rule of its own. A separate `tokens_of` key read
    /// byte-for-byte like "(.+) tokens" in every language, so it was removed;
    /// this pins that the general rule still renders it.
    func testUsedOfLimitTokensRenderThroughTheGeneralTokensRule() {
        XCTAssertEqual(render(S.tokensOf("300", "1,000"), in: "zh-Hans"), "300/1,000 token")
        XCTAssertEqual(render(S.tokensOf("300", "1,000"), in: "ja"), "300/1,000 トークン")
        XCTAssertEqual(render(S.tokensOf("300", "1,000"), in: "ko"), "300/1,000 토큰")
    }

    /// Sakana writes "$0.50 credit" and Crof "$1.00 credits": the same dollar
    /// credit, so Chinese gives both one shape and calls it 额度, not 积分 (points).
    func testDollarCreditHasOneShapeInChinese() {
        XCTAssertEqual(render(S.join([S.windowPercentLeft(.fiveHour, 60), S.credit("$0.50")]), in: "zh-Hans"),
                       "5h：剩余 60% · 额度：$0.50")
        XCTAssertEqual(render(S.credits("$1.00"), in: "zh-Hans"), "额度：$1.00")
        XCTAssertEqual(render(S.credit("$0.50"), in: "zh-Hant"), "額度：$0.50")
        XCTAssertEqual(render(S.credits("$1.00"), in: "zh-Hant"), "額度：$1.00")
    }

    /// A vendor's words keep their place and their spelling next to ours.
    func testVendorSegmentsAreKeptVerbatim() {
        XCTAssertEqual(render(S.join(["Pro", S.amountOf("$18.00", "$30.00")]), in: "zh-Hans"),
                       "Pro · 已使用 $18.00（共 $30.00）")
        // Both producers mean an amount used against a cap (Command Code above,
        // Bedrock's budget here), so the Chinese says "used … (of …)" rather than
        // "the $18 inside $30".
        XCTAssertEqual(render(S.join([S.thisMonth("$25.00"), S.amountOf("25%", "$100")]), in: "zh-Hant"),
                       "本月 $25.00 · 已使用 25%（共 $100）")
        XCTAssertEqual(render(S.join(["Pro · 400 / 1000 edit predictions", S.overdueInvoices]), in: "zh-Hans"),
                       "Pro · 400 / 1000 edit predictions · ⚠︎ 有逾期账单")
        XCTAssertEqual(render(S.join([S.windowPercentLeft(.fourHour, 80), "normal"]), in: "ja"),
                       "4h: 残り 80% · normal")
        for vendorOnly in ["Pro · Unlimited edit predictions", "$12.50 Zen",
                           "DIEM 3.00 / 10.00 epoch allocation", "12,500/50,000 compute points"] {
            XCTAssertEqual(render(vendorOnly, in: "zh-Hans"), vendorOnly)
        }
    }

    /// Spanish distinguishes one from many; the builder and the key both do.
    func testCountsUseTheSingularForOne() {
        XCTAssertEqual(S.modelsAvailable(1), "1 model available")
        XCTAssertEqual(render(S.modelsAvailable(1), in: "es"), "1 modelo disponible")
        XCTAssertEqual(render(S.modelsAvailable(3), in: "es"), "3 modelos disponibles")
        XCTAssertEqual(render(S.requestsLeft(1), in: "es"), "1 solicitud restante")

        // Only the count of 1 changed its English bytes; larger counts keep the
        // grouping Deepgram always wrote.
        XCTAssertEqual(S.requests(1), "1 request")
        XCTAssertEqual(S.requests(0), "0 requests")
        XCTAssertEqual(S.requests(1234), "1,234 requests")
        XCTAssertEqual(render(S.requests(1), in: "es"), "1 solicitud")
        XCTAssertEqual(render(S.requests(1234), in: "es"), "1,234 solicitudes")
        // A line stored before the singular existed still translates.
        XCTAssertEqual(render("1 requests", in: "es"), "1 solicitudes")

        // English says "1 active" and "3 active" alike; Spanish does not.
        XCTAssertEqual(S.activeSessions(1), "1 active")
        XCTAssertEqual(S.activeSessions(3), "3 active")
        XCTAssertEqual(render(S.activeSessions(1), in: "es"), "1 sesión activa")
        XCTAssertEqual(render(S.activeSessions(3), in: "es"), "3 sesiones activas")
        XCTAssertEqual(render(S.activeSessions(3), in: "zh-Hans"), "3 个活跃会话")
    }

    /// Anchored: a line that merely contains a template is not that template.
    func testNearMissesPassThrough() {
        for raw in ["about 40% left", "Weekly 40%", "Hourly 40% left", "the balance of $3 of it", "Unlimited plan",
                    "2 request", "one active", "3 active keys"] {
            XCTAssertEqual(render(raw, in: "zh-Hans"), raw)
        }
    }

    // MARK: - Real collector output

    #if os(macOS)
    /// The builders are only half the story: these run the collectors' own result
    /// building, so a collector that stops using a builder fails here too.
    func testRealCollectorLinesAreRecognized() {
        let lines = [
            BedrockCollector.buildResult(spend: 25, region: "us-east-1", budget: 100).usage.status_text,
            OpenAIAdminCollector.buildResult(total: 4.25, currency: "USD").usage.status_text,
            LLMProxyCollector.buildResult(.init(
                providerCount: 2, totalKeys: 5, activeKeys: 3, totalRequests: 150,
                totalTokens: 70, approxCostUSD: 2.0, minRemainingPercent: 40, nextResetAt: nil)).usage.status_text,
            MiMoCollector.buildResult(
                balance: nil, currency: "CNY", planCode: nil,
                periodEnd: nil, expired: false, used: 0, limit: 0).usage.status_text,
            AzureOpenAICollector.formatStatusText(deploymentName: "gpt-4o", model: "gpt-4o-2024-08-06"),
            DeepgramCollector.formatStatusText(.init(requests: 1, hours: 1.5)),
        ]
        // The template words these lines are made of; amounts, currency codes and
        // model ids are allowed to stay.
        let templateWords = #"\b(left|keys|req|tok|this month|of|Balance|unavailable|Deployment|Model|requests?|audio hrs)\b"#
        for line in lines {
            XCTAssertEqual(render(line, in: "en"), line)
            let shown = render(line, in: "zh-Hans")
            XCTAssertNil(shown.range(of: templateWords, options: .regularExpression),
                         "\(line) -> \(shown) kept English template words")
        }
    }

    func testDeepgramWritesOneRequestInTheSingular() {
        let line = DeepgramCollector.formatStatusText(.init(requests: 1, hours: 1.5))
        XCTAssertEqual(line, "1 request · 1.5 audio hrs")
        XCTAssertEqual(render(line, in: "es"), "1 solicitud · 1.5 h de audio")
    }
    #endif
}
