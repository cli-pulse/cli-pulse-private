import XCTest
@testable import CLIPulseCore

final class ProviderConfigModelTests: XCTestCase {

    // MARK: - ProviderConfig identity

    func testProviderConfigIdentityUsesStableAccountID() throws {
        let accountID = try XCTUnwrap(
            UUID(uuidString: "55555555-5555-4555-8555-555555555555")
        )
        let config = ProviderConfig(
            kind: .claude,
            accountID: accountID,
            accountLabel: "Work"
        )

        XCTAssertEqual(config.id, accountID)
    }

    // MARK: - TokenFormatter.format

    /// Every expectation passes an en_US locale: separators follow the display
    /// locale, and these pin the precision rule, not the machine's region.
    private let en = Locale(identifier: "en_US")

    func testTokenFormatterSmallNumbers() {
        XCTAssertEqual(TokenFormatter.format(0, locale: en), "0")
        XCTAssertEqual(TokenFormatter.format(1, locale: en), "1")
        XCTAssertEqual(TokenFormatter.format(999, locale: en), "999")
    }

    /// One rule for every surface: at most one decimal, none when it is zero.
    /// The app used to show "245.0K" and "1.0M" where the widget showed "245K".
    func testTokenFormatterKeepsOneDecimalAndDropsAZeroOne() {
        XCTAssertEqual(TokenFormatter.format(1_000, locale: en), "1K")
        XCTAssertEqual(TokenFormatter.format(1_500, locale: en), "1.5K")
        XCTAssertEqual(TokenFormatter.format(9_500, locale: en), "9.5K")
        XCTAssertEqual(TokenFormatter.format(12_300, locale: en), "12.3K")
        XCTAssertEqual(TokenFormatter.format(154_100, locale: en), "154.1K")
        XCTAssertEqual(TokenFormatter.format(245_000, locale: en), "245K")
        XCTAssertEqual(TokenFormatter.format(1_000_000, locale: en), "1M")
        XCTAssertEqual(TokenFormatter.format(8_600_000, locale: en), "8.6M")
        XCTAssertEqual(TokenFormatter.format(16_800_000, locale: en), "16.8M")
        XCTAssertEqual(TokenFormatter.format(81_000_000, locale: en), "81M")
    }

    /// A count that rounds to 1000 of one unit is shown in the next ("1000K" was
    /// pinned here as expected output before).
    func testTokenFormatterRollsOverToTheNextSuffix() {
        XCTAssertEqual(TokenFormatter.format(999_949, locale: en), "999.9K")
        XCTAssertEqual(TokenFormatter.format(999_999, locale: en), "1M")
        XCTAssertEqual(TokenFormatter.format(999_960_000, locale: en), "1B")
    }

    func testTokenFormatterBillions() {
        XCTAssertEqual(TokenFormatter.format(1_000_000_000, locale: en), "1B")
        XCTAssertEqual(TokenFormatter.format(8_600_000_000, locale: en), "8.6B")
        XCTAssertEqual(TokenFormatter.format(12_300_000_000, locale: en), "12.3B")
    }

    /// Japanese, Chinese and Korean keep K/M/B, the way their developer tools
    /// and the provider dashboards quote token counts, and never 万/萬/만; the
    /// decimal separator is the reader's.
    func testTokenFormatterKeepsTheSuffixInJapaneseChineseAndKorean() {
        XCTAssertEqual(TokenFormatter.format(245_000, locale: Locale(identifier: "ja_JP")), "245K")
        XCTAssertEqual(TokenFormatter.format(8_600_000, locale: Locale(identifier: "zh-Hans_CN")), "8.6M")
        XCTAssertEqual(TokenFormatter.format(154_100, locale: Locale(identifier: "zh-Hant_TW")), "154.1K")
        XCTAssertEqual(TokenFormatter.format(154_100, locale: Locale(identifier: "ko_KR")), "154.1K")
        XCTAssertEqual(TokenFormatter.format(1_200_000_000, locale: Locale(identifier: "ja_JP")), "1.2B")
    }

    /// Spanish read "154,1K" and "16,8M": an English suffix after a Spanish
    /// comma. It now writes the quantity the way Spanish does, for the reader's
    /// region, and keeps the rounding rule. ICU separates the word with a
    /// no-break space, compared here as a space.
    func testTokenFormatterWritesSpanishCountsInSpanish() {
        let spain = Locale(identifier: "es_ES")
        func inSpain(_ count: Int) -> String { spaced(TokenFormatter.format(count, locale: spain)) }
        XCTAssertEqual(inSpain(999), "999")
        XCTAssertEqual(inSpain(1_000), "1 mil")
        XCTAssertEqual(inSpain(154_100), "154,1 mil")
        XCTAssertEqual(inSpain(16_800_000), "16,8 M")
        XCTAssertEqual(inSpain(999_949), "999,9 mil")
        XCTAssertEqual(inSpain(999_999), "1 M", "rolls over like the other languages")
        XCTAssertEqual(spaced(TokenFormatter.format(154_100, locale: Locale(identifier: "es_MX"))), "154.1 k",
                       "Mexico's own separator and abbreviation")
    }

    /// Above a thousand million, CLDR's Spanish forms read "1.2k M" and
    /// "8.6k M" in Mexico, the US and most of Latin America, and switch
    /// between "8600 M" and "12,3 mil M" in Spain. Spanish counts those in
    /// millions ("mil millones" is a thousand millions, and a "billón" is
    /// 10^12), so they stay in millions with the region's grouping, up to the
    /// billón, which CLDR writes as Spanish does.
    func testTokenFormatterKeepsSpanishThousandsOfMillionsInMillions() {
        func text(_ count: Int, _ identifier: String) -> String {
            spaced(TokenFormatter.format(count, locale: Locale(identifier: identifier)))
        }
        XCTAssertEqual(text(1_234_000_000, "es_MX"), "1,234 M")
        XCTAssertEqual(text(8_600_000_000, "es_MX"), "8,600 M")
        XCTAssertEqual(text(1_234_000_000, "es_US"), "1,234 M")
        XCTAssertEqual(text(8_600_000_000, "es_US"), "8,600 M")
        XCTAssertEqual(text(12_300_000_000, "es_US"), "12,300 M")
        XCTAssertEqual(text(1_200_000_000, "es_AR"), "1.200 M")
        XCTAssertEqual(text(8_600_000_000, "es_ES"), "8600 M", "Spain groups from five digits")
        XCTAssertEqual(text(12_300_000_000, "es_ES"), "12.300 M")
        XCTAssertEqual(text(999_949_999, "es_MX"), "999.9 M", "below a thousand million: unchanged")
        XCTAssertEqual(text(999_950_000, "es_MX"), "1,000 M", "rolls into a thousand millions, not \"1k M\"")
        XCTAssertEqual(text(1_000_000_000_000, "es_MX"), "1 B", "a billón is 10^12 in Spanish")

        for identifier in ["es_ES", "es_MX", "es_US", "es_419", "es_AR", "es_CO"] {
            var count = 1_000_000_000.0
            while count < 999_000_000_000 {
                let shown = text(Int(count), identifier)
                XCTAssertTrue(shown.hasSuffix(" M") && !shown.contains("k") && !shown.contains("mil"),
                              "\(identifier) \(Int(count)): \(shown)")
                count *= 1.37
            }
        }
    }

    private func spaced(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
    }

    // MARK: - SubscriptionUtilization

    func testSubscriptionUtilizationZeroSubscriptionCost() {
        let u = SubscriptionUtilization(provider: "Claude", plan: "Free", apiEquivCost: 5.0, subscriptionCost: 0.0)
        XCTAssertEqual(u.utilizationPercent, 0)
        XCTAssertEqual(u.valueMultiplier, "")
    }

    func testSubscriptionUtilizationBelowOneMultiplier() {
        // apiEquivCost < subscriptionCost → multiplier < 1 → empty string
        let u = SubscriptionUtilization(provider: "Codex", plan: "Plus", apiEquivCost: 5.0, subscriptionCost: 20.0)
        XCTAssertEqual(u.utilizationPercent, 25.0, accuracy: 0.001)
        XCTAssertEqual(u.valueMultiplier, "")
    }

    func testSubscriptionUtilizationAtExactlyOne() {
        // multiplier = 1.0 → "1x"
        let u = SubscriptionUtilization(provider: "Claude", plan: "Pro", apiEquivCost: 20.0, subscriptionCost: 20.0)
        XCTAssertEqual(u.utilizationPercent, 100.0, accuracy: 0.001)
        XCTAssertEqual(u.valueMultiplier, "1x")
    }

    func testSubscriptionUtilizationHighMultiplier() {
        // apiEquivCost = 230, subscriptionCost = 10 → multiplier = 23x
        let u = SubscriptionUtilization(provider: "Gemini", plan: "Pro", apiEquivCost: 230.0, subscriptionCost: 10.0)
        XCTAssertEqual(u.utilizationPercent, 2300.0, accuracy: 0.001)
        XCTAssertEqual(u.valueMultiplier, "23x")
        XCTAssertEqual(u.provider, "Gemini")
        XCTAssertEqual(u.plan, "Pro")
        XCTAssertEqual(u.apiEquivCost, 230.0, accuracy: 0.001)
        XCTAssertEqual(u.subscriptionCost, 10.0, accuracy: 0.001)
    }

    // MARK: - UsageTier.usagePercent

    func testUsageTierNilQuotaReturnsZero() {
        let tier = UsageTier(name: "Flash", usage: 100, quota: nil, remaining: nil, resetTime: nil)
        XCTAssertEqual(tier.usagePercent, 0.0, accuracy: 0.001)
    }

    func testUsageTierZeroQuotaReturnsZero() {
        let tier = UsageTier(name: "Pro", usage: 50, quota: 0, remaining: 0, resetTime: nil)
        XCTAssertEqual(tier.usagePercent, 0.0, accuracy: 0.001)
    }

    func testUsageTierNormalCase() {
        // quota=200, remaining=150 → used=50 → 50/200 = 0.25
        let tier = UsageTier(name: "Pro", usage: 50, quota: 200, remaining: 150, resetTime: nil)
        XCTAssertEqual(tier.usagePercent, 0.25, accuracy: 0.001)
    }

    func testUsageTierCapsAtOne() {
        // remaining=-50 means overage → used=250 > quota=200 → capped at 1.0
        let tier = UsageTier(name: "Session", usage: 250, quota: 200, remaining: -50, resetTime: nil)
        XCTAssertEqual(tier.usagePercent, 1.0, accuracy: 0.001)
    }

    // MARK: - ProviderRegistry

    func testRegistryDescriptorKnownKinds() {
        let codex = ProviderRegistry.descriptor(for: .codex)
        XCTAssertEqual(codex.kind, .codex)
        XCTAssertEqual(codex.displayName, "Codex (OpenAI)")
        XCTAssertTrue(codex.supportsExactCost)
        XCTAssertTrue(codex.supportsCredits)
        XCTAssertTrue(codex.requiresHelperBackend)
        XCTAssertEqual(codex.webDomain, "chatgpt.com")

        let ollama = ProviderRegistry.descriptor(for: .ollama)
        XCTAssertEqual(ollama.kind, .ollama)
        XCTAssertFalse(ollama.supportsQuota)
        XCTAssertFalse(ollama.supportsExactCost)
        XCTAssertEqual(ollama.category, .local)
    }

    func testRegistryAllKindsHaveDescriptors() {
        for kind in ProviderKind.allCases {
            let d = ProviderRegistry.descriptor(for: kind)
            XCTAssertEqual(d.kind, kind, "\(kind.rawValue) should have a registered descriptor")
            XCTAssertFalse(d.displayName.isEmpty, "\(kind.rawValue) should have a display name")
        }
    }

    func testRegistryDescriptorSupportedSourcesNonEmpty() {
        for kind in ProviderKind.allCases {
            let d = ProviderRegistry.descriptor(for: kind)
            XCTAssertFalse(d.supportedSources.isEmpty, "\(kind.rawValue) must support at least one source")
        }
    }
}
