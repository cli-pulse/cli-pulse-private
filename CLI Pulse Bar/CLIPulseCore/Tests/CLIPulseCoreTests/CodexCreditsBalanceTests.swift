import XCTest
@testable import CLIPulseCore

/// Codex's credits balance is a count of credits. It used to be read as a window
/// whose quota was its own remaining value, which can only say "100% left", with
/// a comment calling it a dollar balance; a balance of 0 dropped the row; and the
/// balance `/wham/usage` actually sends, a JSON string, never parsed at all.
///
/// Text is asserted in zh-Hans and es: the English fallback reads the same as the
/// English plural, so an English-only assertion passes with the lookup broken.
final class CodexCreditsBalanceTests: XCTestCase {

    private var savedOverride: String?
    private var savedSystemLocale: (() -> Locale)!

    override func setUp() {
        super.setUp()
        savedOverride = LocaleOverrideStore.shared.override
        savedSystemLocale = LocaleOverrideStore.systemLocale
        // Separators come from the region; pin it so the expected text does not
        // depend on the Mac running the tests.
        LocaleOverrideStore.systemLocale = { Locale(identifier: "en_US") }
    }

    override func tearDown() {
        LocaleOverrideStore.systemLocale = savedSystemLocale
        LocaleOverrideStore.shared.set(savedOverride)
        super.tearDown()
    }

    private func use(_ localization: String) {
        LocaleOverrideStore.shared.set(localization)
    }

    private func units(_ credits: Double) -> Int {
        CodexCreditsBalance.units(forBalance: credits)
    }

    // MARK: - Text

    /// A count of credits: no currency sign, no percentage, and the singular for
    /// exactly one.
    func testBalanceReadsAsCreditsLeftInChinese() {
        use("zh-Hans")
        XCTAssertEqual(CodexCreditsBalance.leftText(units: 0), "剩余 0 积分")
        XCTAssertEqual(CodexCreditsBalance.leftText(units: units(1_250.5)), "剩余 1,250.5 积分")
        XCTAssertEqual(CodexCreditsBalance.leftText(units: units(40)), "剩余 40 积分")
        for text in [CodexCreditsBalance.leftText(units: 0), CodexCreditsBalance.leftText(units: units(1_250.5))] {
            XCTAssertFalse(text.contains("$"), text)
            XCTAssertFalse(text.contains("%"), text)
        }
    }

    func testOneCreditIsSingularInSpanish() {
        LocaleOverrideStore.systemLocale = { Locale(identifier: "es_ES") }
        use("es")
        XCTAssertEqual(CodexCreditsBalance.leftText(units: units(1)), "1 crédito restante")
        XCTAssertEqual(CodexCreditsBalance.leftText(units: 0), "0 créditos restantes")
        XCTAssertEqual(CodexCreditsBalance.leftText(units: units(2.5)), "2,5 créditos restantes")
        XCTAssertEqual(CodexCreditsBalance.leftText(units: units(1_000.25)), "1000,25 créditos restantes")
    }

    // MARK: - What counts as the balance

    /// The Mac writes the role; the desktop and Android apps write the name only,
    /// and the provider-level cloud upload drops the role. All are the balance.
    /// Another provider's "Credits" is its own allocation, drawn as a bar.
    func testOnlyCodexCreditsIsTheBalance() {
        let codex = ProviderKind.codex.rawValue
        XCTAssertTrue(CodexCreditsBalance.isBalance(
            TierDTO(name: "Credits", quota: 0, remaining: 0, role: .credits), provider: codex))
        XCTAssertTrue(CodexCreditsBalance.isBalance(
            TierDTO(name: "Credits", quota: 500_000, remaining: 500_000), provider: codex))
        XCTAssertFalse(CodexCreditsBalance.isBalance(
            TierDTO(name: "Weekly", quota: 100, remaining: 40, role: .secondary), provider: codex))
        XCTAssertFalse(CodexCreditsBalance.isBalance(
            TierDTO(name: "Credits", quota: 1_000, remaining: 250), provider: ProviderKind.augment.rawValue))
        XCTAssertFalse(CodexCreditsBalance.isBalance(
            TierDTO(name: "Extra usage", quota: 1_000, remaining: 250, role: .credits),
            provider: ProviderKind.claude.rawValue))
    }

    /// A row list keeps the balance at 0 and still drops a window with no quota.
    func testDisplayedTiersKeepAZeroBalance() {
        let tiers = [
            TierDTO(name: "5h Window", quota: 100, remaining: 60),
            TierDTO(name: "Disabled", quota: 0, remaining: 0),
            CodexCreditsBalance.tier(balance: 0),
        ]
        XCTAssertEqual(
            CodexCreditsBalance.displayedTiers(tiers, provider: ProviderKind.codex.rawValue).map(\.name),
            ["5h Window", "Credits"])
        XCTAssertEqual(
            CodexCreditsBalance.displayedTiers(tiers, provider: ProviderKind.augment.rawValue).map(\.name),
            ["5h Window"])
    }

    /// The desktop and Android apps write quota = remaining = balance × 100,000;
    /// the Mac writes quota 0. Both shapes read back as the same balance, from
    /// `remaining`.
    func testBothProducersReadAsTheSameBalance() {
        use("zh-Hans")
        let codex = ProviderKind.codex.rawValue
        let mac = CodexCreditsBalance.tier(balance: 12.5)
        let desktop = TierDTO(name: "Credits", quota: 1_250_000, remaining: 1_250_000)
        XCTAssertEqual(CodexCreditsBalance.leftText(for: mac, provider: codex), "剩余 12.5 积分")
        XCTAssertEqual(CodexCreditsBalance.leftText(for: desktop, provider: codex), "剩余 12.5 积分")
        XCTAssertNil(CodexCreditsBalance.leftText(
            for: TierDTO(name: "Weekly", quota: 100, remaining: 40), provider: codex))
    }

    /// Quota 0 keeps every percentage reader away from the balance: the quota
    /// alert, the most-constrained account and older app versions all skip a
    /// tier whose quota is 0.
    func testTheMacTierHasNoAllocationForAPercentageToUse() {
        let tier = CodexCreditsBalance.tier(balance: 40)
        XCTAssertEqual(tier.quota, 0)
        XCTAssertEqual(tier.remaining, 4_000_000)
        XCTAssertEqual(tier.role, .credits)
        XCTAssertNil(tier.reset_time)
        XCTAssertNil(QuotaPercent.usedAndLeft(quota: tier.quota, remaining: tier.remaining))
        XCTAssertEqual(CodexCreditsBalance.units(forBalance: -3), 0)
        XCTAssertEqual(CodexCreditsBalance.units(forBalance: .nan), 0)
    }

    // MARK: - Provider card

    private func codexUsage(tiers: [TierDTO]) -> ProviderUsage {
        ProviderUsage(
            provider: ProviderKind.codex.rawValue,
            today_usage: 40, week_usage: 10,
            estimated_cost_today: 0, estimated_cost_week: 0,
            cost_status_today: "Unavailable", cost_status_week: "Unavailable",
            quota: 100, remaining: 60, plan_type: "plus",
            tiers: tiers, status_text: "",
            trend: [], recent_sessions: [], recent_errors: []
        )
    }

    private func codexDetail(tiers: [TierDTO]) throws -> ProviderDetail {
        let details = AppState.computedProviderDetails(
            providers: [codexUsage(tiers: tiers)],
            configs: [ProviderConfig(kind: .codex, sortOrder: 0)],
            isLocalMode: true,
            locallySupplementedProviders: []
        )
        return try XCTUnwrap(details.first)
    }

    /// A spent balance stays on the card as "0 credits left"; it used to vanish,
    /// because the tier list dropped every tier whose quota was 0.
    func testCardKeepsASpentBalanceAndDrawsItAsCredits() throws {
        use("zh-Hans")
        let detail = try codexDetail(tiers: [
            TierDTO(name: "5h Window", quota: 100, remaining: 60),
            TierDTO(name: "Weekly", quota: 100, remaining: 90),
            CodexCreditsBalance.tier(balance: 0),
        ])
        XCTAssertEqual(detail.tiers.map(\.name), ["5h Window", "Weekly", "Credits"])
        let credits = try XCTUnwrap(detail.tiers.last)
        XCTAssertEqual(credits.creditsLeftText, "剩余 0 积分")
        XCTAssertNil(credits.quota, "a balance has no allocation to draw a bar against")
        XCTAssertEqual(credits.usagePercent, 0)
        XCTAssertNil(detail.tiers[0].creditsLeftText)
        XCTAssertNil(detail.tiers[1].creditsLeftText)
    }

    /// The desktop app's row (quota = remaining) used to read "100% left".
    func testCardReadsTheDesktopRowAsABalanceNotAFullWindow() throws {
        use("zh-Hans")
        let detail = try codexDetail(tiers: [
            TierDTO(name: "5h Window", quota: 100, remaining: 60),
            TierDTO(name: "Credits", quota: 4_000_000, remaining: 4_000_000),
        ])
        XCTAssertEqual(detail.tiers.last?.creditsLeftText, "剩余 40 积分")
        XCTAssertNil(detail.tiers.last?.quota)
    }

    // MARK: - Collector

    #if os(macOS)
    private func usage(_ creditsJSON: String) throws -> CodexCollector.UsageResponse {
        let json = """
        {
            "plan_type": "plus",
            "rate_limit": {
                "primary_window": {"used_percent": 40, "reset_at": 1735401600, "limit_window_seconds": 18000},
                "secondary_window": {"used_percent": 10, "reset_at": 1735920000, "limit_window_seconds": 604800}
            },
            "credits": \(creditsJSON)
        }
        """.data(using: .utf8)!
        return try CodexCollector.parseUsage(json)
    }

    private func buildTiers(_ creditsJSON: String, accountHadCredits: Bool = false) throws -> [TierDTO] {
        try CodexCollector()
            .buildResult(usage: usage(creditsJSON), accountHadCredits: accountHadCredits)
            .usage.tiers
    }

    /// A throwaway suite, so no test reads or writes the app group's memory.
    private func isolatedMemory() -> (CodexCreditsMemory, () -> Void) {
        let suite = "com.clipulse.tests.codex-credits.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (CodexCreditsMemory(defaults: defaults), { defaults.removePersistentDomain(forName: suite) })
    }

    /// One collector pass as `collect` runs it, against `memory`.
    private func pass(
        _ creditsJSON: String,
        account: String?,
        memory: CodexCreditsMemory
    ) throws -> TierDTO? {
        try CodexCollector()
            .buildResult(usage: usage(creditsJSON), accountId: account, memory: memory)
            .usage.tiers
            .first { $0.name == CodexCreditsBalance.tierName }
    }

    /// The balance arrives as a string. Reading only numbers left it nil, so the
    /// row was never built from a live response.
    func testStringBalanceFromTheEndpointBuildsTheTier() throws {
        let tiers = try buildTiers(#"{"has_credits": true, "unlimited": false, "balance": "1250.5"}"#)
        let credits = try XCTUnwrap(tiers.first { $0.name == "Credits" })
        XCTAssertEqual(credits.role, .credits)
        XCTAssertEqual(credits.quota, 0)
        XCTAssertEqual(credits.remaining, 125_050_000)
    }

    /// `/wham/usage` reports "0" for an account that never bought credits.
    /// Building the row from that put "0 credits left" on every Codex card.
    func testAnAccountThatNeverHadCreditsGetsNoRow() throws {
        let tiers = try buildTiers(#"{"has_credits": false, "unlimited": false, "balance": "0"}"#)
        XCTAssertEqual(tiers.map(\.name), ["5h Window", "Weekly"])
    }

    /// `has_credits` goes false once nothing is left. For an account that had
    /// credits the row stays, as "0 credits left", instead of disappearing.
    func testASpentBalanceStaysForAnAccountThatHadCredits() throws {
        let tiers = try buildTiers(
            #"{"has_credits": false, "unlimited": false, "balance": "0"}"#,
            accountHadCredits: true
        )
        let credits = try XCTUnwrap(tiers.first { $0.name == "Credits" })
        XCTAssertEqual(credits.remaining, 0)
        XCTAssertEqual(credits.role, .credits)
        XCTAssertEqual(tiers.map(\.name), ["5h Window", "Weekly", "Credits"])
    }

    /// Either signal of credits now is enough on its own.
    func testHasCreditsOrABalanceAboveZeroBuildsTheRow() throws {
        let flagged = try buildTiers(#"{"has_credits": true, "unlimited": false, "balance": "0"}"#)
        XCTAssertEqual(flagged.first { $0.name == "Credits" }?.remaining, 0,
                       "has_credits with a 0 balance lost its row")
        let funded = try buildTiers(#"{"has_credits": false, "unlimited": false, "balance": "12"}"#)
        XCTAssertEqual(funded.first { $0.name == "Credits" }?.remaining, units(12),
                       "a balance above 0 lost its row because has_credits said false")
    }

    /// The rule end to end, across passes: credits bought, then spent.
    /// The last pass is the same response as the never-had-credits account's,
    /// and only the memory of the earlier passes tells them apart.
    func testTheRowOutlivesTheLastCreditAcrossPasses() throws {
        let (memory, cleanUp) = isolatedMemory()
        defer { cleanUp() }
        let spent = #"{"has_credits": false, "unlimited": false, "balance": "0"}"#

        XCTAssertNil(try pass(spent, account: "acct-never", memory: memory),
                     "an account that never had credits reads 0 credits left")

        let bought = try pass(#"{"has_credits": true, "unlimited": false, "balance": "25"}"#,
                              account: "acct-bought", memory: memory)
        XCTAssertEqual(bought?.remaining, units(25))
        let afterSpending = try pass(spent, account: "acct-bought", memory: memory)
        XCTAssertEqual(afterSpending?.remaining, 0, "the spent balance vanished")

        // Remembered per account: the other one is still never-had.
        XCTAssertNil(try pass(spent, account: "acct-never", memory: memory))
    }

    /// Nothing is remembered from a response that says no credits, and an
    /// account with credits is remembered once, however many passes see it.
    func testMemoryRecordsOnlyAccountsWithCreditsAndOnlyOnce() throws {
        let (memory, cleanUp) = isolatedMemory()
        defer { cleanUp() }

        _ = try pass(#"{"has_credits": false, "unlimited": false, "balance": "0"}"#,
                     account: "acct-a", memory: memory)
        XCTAssertFalse(memory.hasHadCredits(account: "acct-a"))

        _ = try pass(#"{"has_credits": false, "unlimited": false, "balance": "3"}"#,
                     account: "acct-a", memory: memory)
        _ = try pass(#"{"has_credits": true, "unlimited": false, "balance": "3"}"#,
                     account: "acct-a", memory: memory)
        XCTAssertTrue(memory.hasHadCredits(account: "acct-a"))
        XCTAssertEqual(memory.defaults.stringArray(forKey: CodexCreditsMemory.key)?.count, 1)
    }

    /// The account ID is not written down, only a digest of it; the list is
    /// capped; and the key survives the move from the App Store build to the
    /// Developer ID one.
    func testMemoryStoresDigestsUnderAMigratableCappedKey() {
        let (memory, cleanUp) = isolatedMemory()
        defer { cleanUp() }
        memory.remember(account: "user-AbCdEf123")
        let stored = memory.defaults.stringArray(forKey: CodexCreditsMemory.key) ?? []
        XCTAssertEqual(stored.count, 1)
        XCTAssertFalse(stored[0].contains("AbCdEf123"), "the raw account ID was stored")
        XCTAssertNotEqual(CodexCreditsMemory.accountDigest("a"), CodexCreditsMemory.accountDigest("b"))
        XCTAssertEqual(CodexCreditsMemory.accountDigest(" a\n"), CodexCreditsMemory.accountDigest("a"))

        for i in 0..<(CodexCreditsMemory.maxAccounts + 5) {
            memory.remember(account: "acct-\(i)")
        }
        XCTAssertEqual(memory.defaults.stringArray(forKey: CodexCreditsMemory.key)?.count,
                       CodexCreditsMemory.maxAccounts)
        XCTAssertTrue(memory.hasHadCredits(account: "acct-\(CodexCreditsMemory.maxAccounts + 4)"),
                      "the newest account was dropped instead of the oldest")

        XCTAssertTrue(
            UnsandboxedDataMigration.appOwnedKeyPrefixes.contains { CodexCreditsMemory.key.hasPrefix($0) },
            "\(CodexCreditsMemory.key) would be dropped on MAS → DEVID"
        )
    }

    func testUnlimitedOrMissingBalanceBuildsNoTier() throws {
        XCTAssertFalse(try buildTiers(#"{"has_credits": true, "unlimited": true, "balance": "999"}"#)
            .contains { $0.name == "Credits" })
        XCTAssertFalse(try buildTiers(#"{"has_credits": true, "unlimited": false, "balance": null}"#)
            .contains { $0.name == "Credits" })
        XCTAssertFalse(try buildTiers(#"{"has_credits": true, "unlimited": false}"#)
            .contains { $0.name == "Credits" })
    }

    func testBalanceParsingAcceptsNumbersAndNumericStringsOnly() {
        XCTAssertEqual(CodexCollector.parseBalance("0"), 0)
        XCTAssertEqual(CodexCollector.parseBalance(" 12.5 "), 12.5)
        XCTAssertEqual(CodexCollector.parseBalance(NSNumber(value: 150.0)), 150)
        XCTAssertNil(CodexCollector.parseBalance(""))
        XCTAssertNil(CodexCollector.parseBalance("n/a"))
        XCTAssertNil(CodexCollector.parseBalance(NSNull()))
        XCTAssertNil(CodexCollector.parseBalance(nil))
        XCTAssertNil(CodexCollector.parseBalance(NSNumber(value: true)), "a JSON boolean is not a balance")
        XCTAssertNil(CodexCollector.parseBalance("inf"))
    }
    #endif
}
