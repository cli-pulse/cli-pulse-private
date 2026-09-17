import XCTest
@testable import CLIPulseCore

/// Quota tier names are display strings that are ALSO identity: the alert
/// `suppression_key`, a `ForEach` id, a cloud upload, and the input to
/// `WatchRingMath.weeklyTier`'s "week" match. So the stored name stays English
/// and only the rendering is localized.
///
/// Every assertion runs under a forced zh-Hans override. In English a localized
/// value equals its input, so an English-only version of this file would pass
/// with the mapper deleted — which is exactly how a previous localization test
/// in this suite managed to test nothing.
///
/// Completeness (every produced name classified, every TRANSLATE name wired
/// into all six catalogues) is checked by `scripts/check_quota_tier_names.py`,
/// not here. This file checks BEHAVIOUR: that the mapper translates what it
/// claims to, passes through what it claims to, and does not disturb identity.
final class QuotaTierNameLocalizationTests: XCTestCase {

    private func withChinese(_ body: () throws -> Void) rethrows {
        let store = LocaleOverrideStore.shared
        let previous = store.override
        store.set("zh-Hans")
        defer { store.set(previous) }
        try body()
    }

    // MARK: - Translated names

    func testGenericTierNamesAreLocalized() throws {
        try withChinese {
            for raw in ["5h Window", "Weekly", "Daily", "Monthly", "Credits", "Default", "Requests"] {
                let shown = L10n.quotaTier.localized(raw)
                XCTAssertNotEqual(shown, raw, "\(raw) still renders in English under zh-Hans")
                XCTAssertFalse(shown.isEmpty, "\(raw) mapped to an empty string")
            }
        }
    }

    /// Different durations must not collapse into each other. An earlier draft
    /// gave "5-hour" and "5h Window" the same catalogue key, which would have
    /// rendered one provider's window as another's.
    ///
    /// Note what is NOT asserted: "5h Window" and "5-hour" may legitimately
    /// render identically. They are the same five-hour window named by two
    /// different vendors, and Japanese deliberately shows "5h" for both. What
    /// must never collapse is four hours into five.
    func testDifferentDurationsDoNotCollapse() throws {
        try withChinese {
            let four = L10n.quotaTier.localized("4-hour")
            let five = L10n.quotaTier.localized("5-hour")
            let window = L10n.quotaTier.localized("5h Window")
            // Without this, the test passes with the mapper deleted: the raw
            // English strings differ from each other too. Found by injecting
            // exactly that.
            XCTAssertNotEqual(window, "5h Window", "nothing was localized, so distinctness proves nothing")
            XCTAssertNotEqual(four, "4-hour")
            XCTAssertNotEqual(four, five, "4-hour and 5-hour render the same")
            XCTAssertNotEqual(four, window, "4-hour and the 5h window render the same")
        }
    }

    /// Producers disagree on capitalization on purpose — ElevenLabs' labels are
    /// lowercase mid-phrase — so matching is case-insensitive.
    func testMatchingIsCaseInsensitive() throws {
        try withChinese {
            XCTAssertEqual(L10n.quotaTier.localized("Voice slots"), L10n.quotaTier.localized("Voice Slots"))
            XCTAssertEqual(L10n.quotaTier.localized("WEEKLY"), L10n.quotaTier.localized("Weekly"))
            XCTAssertNotEqual(L10n.quotaTier.localized("weekly"), "weekly")
        }
    }

    /// A mixed name keeps its model noun verbatim inside the translation.
    /// "Sonnet" and "Opus" are Claude models; a translated model name stops the
    /// row identifying which limit it is.
    func testModelNamesSurviveTranslation() throws {
        try withChinese {
            for (raw, model) in [("Sonnet only", "Sonnet"), ("Opus only", "Opus"),
                                 ("Opus (Weekly)", "Opus"), ("Sonnet (Weekly)", "Sonnet")] {
                let shown = L10n.quotaTier.localized(raw)
                XCTAssertTrue(shown.contains(model),
                              "\(raw) -> \(shown) dropped the model name \(model)")
                XCTAssertNotEqual(shown, raw, "\(raw) was not localized at all")
            }
        }
    }

    // MARK: - Every manifest decision, as the mapper renders it

    struct ManifestEntry: Decodable {
        let name: String
        let display: String
        let l10n_key: String?
    }

    /// `scripts/quota_tier_names.json`, the record of every tier name's decision.
    private func manifest() throws -> [ManifestEntry] {
        struct File: Decodable { let entries: [ManifestEntry] }
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CLIPulseCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // CLIPulseCore
            .deletingLastPathComponent()   // CLI Pulse Bar
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("scripts/quota_tier_names.json")
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: url)).entries
    }

    /// What is wrong with a mapper's rendering of the manifest. A TRANSLATE name
    /// must render exactly its OWN key's value (looked up without the English
    /// fallback), in any capitalization; a PASSTHROUGH name must render as itself.
    static func renderingProblems(_ entries: [ManifestEntry],
                                  localize: (String) -> String,
                                  ownValue: (String) -> String?) -> [String] {
        var problems: [String] = []
        for entry in entries {
            switch entry.display {
            case "TRANSLATE":
                guard let key = entry.l10n_key, let expected = ownValue(key) else {
                    problems.append("\(entry.name): no value for \(entry.l10n_key ?? "its key")")
                    continue
                }
                for spelling in [entry.name, entry.name.uppercased(), entry.name.lowercased()] {
                    let shown = localize(spelling)
                    if shown != expected {
                        problems.append("\(spelling) renders \(shown), not \(key) (\(expected))")
                    }
                }
            case "PASSTHROUGH":
                let shown = localize(entry.name)
                if shown != entry.name {
                    problems.append("\(entry.name) is PASSTHROUGH but renders \(shown)")
                }
            default:
                problems.append("\(entry.name): unknown display \(entry.display)")
            }
        }
        return problems
    }

    /// All 56 decisions, not a sample of seven: a case label returning the wrong
    /// accessor (every Weekly bar showing 每月) or a capitalized label that
    /// `raw.lowercased()` never equals fails here, where "differs from English"
    /// did not notice either.
    func testEveryManifestNameRendersItsOwnKey() throws {
        let entries = try manifest()
        XCTAssertGreaterThan(entries.count, 40, "the manifest did not load")
        withChinese {
            let own = { (key: String) in
                LocaleCatalogueProbe.ownValue(key, in: "zh-Hans").map(L10n.keepingBrandUnbroken)
            }
            let problems = Self.renderingProblems(entries, localize: L10n.quotaTier.localized, ownValue: own)
            XCTAssertEqual(problems, [], "L10n.quotaTier.localized disagrees with scripts/quota_tier_names.json")
        }
    }

    /// Negative control: the two regressions the test above exists for must be
    /// reported, or its green run proves nothing.
    func testTheManifestCheckReportsAWrongArmAndACaseSensitiveLabel() throws {
        let entries = try manifest()
        withChinese {
            let own = { (key: String) in
                LocaleCatalogueProbe.ownValue(key, in: "zh-Hans").map(L10n.keepingBrandUnbroken)
            }
            let wrongArm: (String) -> String = { raw in
                raw.lowercased() == "weekly" ? L10n.quotaTier.monthly : L10n.quotaTier.localized(raw)
            }
            XCTAssertTrue(Self.renderingProblems(entries, localize: wrongArm, ownValue: own)
                            .contains { $0.hasPrefix("Weekly renders") },
                          "a Weekly arm returning monthly was not reported")

            let caseSensitive: (String) -> String = { raw in
                raw == "Bonus Credits" ? raw : L10n.quotaTier.localized(raw)
            }
            XCTAssertTrue(Self.renderingProblems(entries, localize: caseSensitive, ownValue: own)
                            .contains { $0.hasPrefix("Bonus Credits renders Bonus Credits") },
                          "a label that never matches Bonus Credits was not reported")
        }
    }

    // MARK: - Names deliberately left English

    /// Vendor products, plans, models, coined units and currency codes are what
    /// the user is comparing against the vendor's own billing page.
    func testVendorNamesAreNotTranslated() throws {
        try withChinese {
            for raw in ["Ark Plan", "Kilo Pass", "Token Plan", "Coding Plan", "Compute Points",
                        "DIEM Balance", "USD Balance", "Pro", "Flash", "Flash Lite",
                        "Designs", "Daily Routines", "Premium", "Chat", "Edit Predictions"] {
                XCTAssertEqual(L10n.quotaTier.localized(raw), raw,
                               "\(raw) was translated; it is a vendor name and must render as-is")
            }
        }
    }

    /// DeepSeek builds its name as `"\(b.currency) Balance"`, so the set of
    /// currencies is open. A currency the manifest has never seen must pass
    /// through rather than fall into some default.
    func testAnUnseenCurrencyAndAnUnknownNamePassThrough() throws {
        try withChinese {
            for raw in ["EUR Balance", "JPY Balance", "A Tier From A Collector Written Next Year", ""] {
                XCTAssertEqual(L10n.quotaTier.localized(raw), raw)
            }
        }
    }

    // MARK: - Identity is not disturbed

    /// The quota alert's id and `suppression_key` embed the tier name. If they
    /// ever picked up the localized text, a user switching language would get
    /// every quota alert re-fired, and the Mac and the phone would disagree
    /// about which alerts are already suppressed.
    func testQuotaAlertSuppressionKeyStaysEnglish() throws {
        try withChinese {
            let provider = ProviderUsage(
                provider: "Claude", today_usage: 0, week_usage: 0,
                estimated_cost_today: 0, estimated_cost_week: 0,
                cost_status_today: "normal", cost_status_week: "normal",
                quota: nil, remaining: nil,
                tiers: [TierDTO(name: "Weekly", quota: 100, remaining: 5)],
                status_text: "Operational",
                trend: [], recent_sessions: [], recent_errors: [])

            let alerts = AlertGenerator.evaluateQuotaAlerts(providers: [provider], thresholds: [80])
            XCTAssertEqual(alerts.count, 1, "the quota alert did not fire, so this proves nothing")

            let localized = L10n.quotaTier.localized("Weekly")
            XCTAssertNotEqual(localized, "Weekly", "zh-Hans override is not in effect")

            for field in ["id", "suppression_key"] {
                let value = alerts[0][field] as? String ?? ""
                XCTAssertTrue(value.contains("Weekly"),
                              "\(field) lost the English tier name: \(value)")
                XCTAssertFalse(value.contains(localized),
                               "\(field) embedded the LOCALIZED tier name: \(value)")
            }
        }
    }

    /// `WatchRingMath.weeklyTier` finds the weekly window by matching "week" in
    /// the name, and it is the only detector that works (the explicit role is
    /// never populated). A localized model value would make it match nothing.
    func testWeeklyWindowIsStillFoundWhenTheUIIsChinese() throws {
        try withChinese {
            let provider = ProviderUsage(
                provider: "Claude", today_usage: 0, week_usage: 0,
                estimated_cost_today: 0, estimated_cost_week: 0,
                cost_status_today: "normal", cost_status_week: "normal",
                quota: nil, remaining: nil,
                tiers: [TierDTO(name: "5h Window", quota: 100, remaining: 90),
                        TierDTO(name: "Weekly", quota: 100, remaining: 40)],
                status_text: "Operational",
                trend: [], recent_sessions: [], recent_errors: [])

            XCTAssertEqual(WatchRingMath.weeklyTier(provider)?.name, "Weekly",
                           "the weekly-window detector stopped matching")
            XCTAssertEqual(WatchRingMath.weeklyRemainingPercentInt(provider), 40)
        }
    }
}
