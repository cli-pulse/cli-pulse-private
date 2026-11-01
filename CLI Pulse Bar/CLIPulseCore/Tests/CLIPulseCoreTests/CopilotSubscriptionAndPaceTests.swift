#if os(macOS)
// 1.61 (P2, P3): Copilot with an ended subscription says so instead of
// "Operational", and Copilot's monthly quotas get a window (the calendar month
// ending at the reset) so the pace text and marker work.

import Foundation
import XCTest
@testable import CLIPulseCore

final class CopilotSubscriptionAndPaceTests: XCTestCase {

    private func result(_ json: String) throws -> CollectorResult {
        CopilotCollector().buildResult(try CopilotCollector.parseResponse(Data(json.utf8)))
    }

    private func utc(_ text: String) -> Date {
        let f = ISO8601DateFormatter()
        return f.date(from: text)!
    }

    // MARK: - P2

    /// The shape upstream CodexBar's #4851 fixture has: no quota snapshots,
    /// `access_type_sku: subscription_ended`.
    func test_an_ended_subscription_says_so_instead_of_operational() throws {
        let r = try result("""
        {"login":"fixture-user","access_type_sku":"subscription_ended","copilot_plan":"individual",
         "chat_enabled":false,"cli_enabled":false,"can_signup_for_limited":true}
        """)
        XCTAssertEqual(r.usage.status_text, "Copilot subscription ended")
        XCTAssertTrue(r.usage.tiers.isEmpty)
        // The SKU read as GitHub might vary its case or padding.
        let padded = try result(#"{"copilot_plan":"individual","access_type_sku":" Subscription_Ended "}"#)
        XCTAssertEqual(padded.usage.status_text, CollectorStatusText.copilotSubscriptionEnded)
    }

    /// Quotas still reported win over the SKU: the bars are the truth.
    func test_an_ended_sku_with_quotas_still_shows_the_quotas() throws {
        let r = try result(#"{"copilot_plan":"individual","access_type_sku":"subscription_ended","quota_snapshots":{"premium_interactions":{"entitlement":300,"remaining":90,"percent_remaining":30.0}}}"#)
        XCTAssertEqual(r.usage.status_text, "70% used")
    }

    func test_the_ended_status_is_shown_in_the_readers_language() {
        let store = LocaleOverrideStore.shared
        let previous = store.override
        defer { store.set(previous) }
        let expected = [
            "en": "Copilot subscription ended",
            "zh-Hans": "Copilot 订阅已结束",
            "zh-Hant": "Copilot 訂閱已結束",
            "ja": "Copilot のサブスクリプション終了",
            "ko": "Copilot 구독 종료됨",
            "es": "Suscripción de Copilot finalizada",
        ]
        for (locale, text) in expected {
            store.set(locale)
            XCTAssertEqual(L10n.providers.localizedStatusText(CollectorStatusText.copilotSubscriptionEnded), text, locale)
            XCTAssertEqual(LocaleCatalogueProbe.ownValue("status_text.copilot_subscription_ended", in: locale), text, locale)
        }
    }

    /// A normal subscription is unchanged; another quota-less SKU keeps the old
    /// label (only the SKU upstream documents is read as ended).
    func test_a_normal_subscription_and_another_sku_are_unchanged() throws {
        let normal = try result("""
        {"copilot_plan":"individual","access_type_sku":"monthly_subscriber","quota_reset_date":"2026-08-01",
         "quota_snapshots":{"premium_interactions":{"entitlement":300,"remaining":90,"percent_remaining":30.0},
                            "chat":{"entitlement":0,"remaining":0,"percent_remaining":100.0}}}
        """)
        XCTAssertEqual(normal.usage.status_text, "70% used")
        XCTAssertEqual(normal.usage.tiers.map(\.name), ["Premium"])

        let other = try result(#"{"copilot_plan":"individual","access_type_sku":"future-entitlement"}"#)
        XCTAssertEqual(other.usage.status_text, "Operational")
    }

    /// The API's own spelling, `premium_interactions`, gives the Premium bar
    /// (only `premiumInteractions` was read before 1.61).
    func test_the_snake_case_premium_snapshot_is_read() throws {
        let r = try result(#"{"copilot_plan":"individual","quota_snapshots":{"premium_interactions":{"entitlement":300,"remaining":90,"percent_remaining":30.0}}}"#)
        XCTAssertEqual(r.usage.tiers.map(\.name), ["Premium"])
        XCTAssertEqual(r.usage.quota, 300)
        // Both spellings: the API's own wins over nothing, camelCase first as before.
        let both = try result(#"{"quota_snapshots":{"premiumInteractions":{"entitlement":100,"remaining":10},"premium_interactions":{"entitlement":300,"remaining":90}}}"#)
        XCTAssertEqual(both.usage.quota, 100)
    }

    // MARK: - P3

    func test_the_window_is_the_calendar_month_ending_at_the_reset() {
        let cases: [(String, Int)] = [
            ("2026-08-01T00:00:00Z", 31),   // July
            ("2026-03-01T00:00:00Z", 28),   // February 2026
            ("2028-03-01T00:00:00Z", 29),   // February 2028 (leap year)
            ("2026-05-01T00:00:00Z", 30),   // April
            ("2026-01-01T00:00:00Z", 31),   // December, across the year
            ("2026-03-31T00:00:00Z", 31),   // from 2026-02-28 (no 31 February): 31 days
        ]
        for (reset, days) in cases {
            XCTAssertEqual(CopilotQuotaWindow.minutes(endingAt: utc(reset)), days * 24 * 60, reset)
        }
        // The same in a time zone with daylight saving: the month is UTC's,
        // not the Mac's (a local calendar gives March 2026 in Los Angeles 30 d 23 h).
        let saved = NSTimeZone.default
        defer { NSTimeZone.default = saved }
        NSTimeZone.default = TimeZone(identifier: "America/Los_Angeles")!
        XCTAssertEqual(CopilotQuotaWindow.minutes(endingAt: utc("2026-04-01T00:00:00Z")), 31 * 24 * 60)
        XCTAssertEqual(CopilotQuotaWindow.minutes(endingAt: utc("2026-11-01T00:00:00Z")), 31 * 24 * 60)
    }

    /// The pace text: the provider card's line and the menu bar's label, and
    /// for a row written before 1.61 (no stored length) the month is inferred.
    func test_Copilot_gets_pace_text_mid_month() throws {
        let now = utc("2026-07-16T12:00:00Z")
        let r = try result("""
        {"copilot_plan":"individual","quota_reset_date":"2026-08-01",
         "quota_snapshots":{"premium_interactions":{"entitlement":300,"remaining":90,"percent_remaining":30.0}}}
        """)
        XCTAssertEqual(r.usage.paceWindowMinutes(resetsAt: utc("2026-08-01T00:00:00Z"), now: now), 31 * 24 * 60)
        XCTAssertNotNil(r.usage.paceSummary(now: now))
        XCTAssertEqual(r.usage.paceMenuLabel(now: now), "▲20%", "70% used at half the month")

        // The same row as a build before 1.61 stored it: no window length.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(r.usage)) as? [String: Any])
        json["tiers"] = (json["tiers"] as? [[String: Any]])?.map { $0.filter { $0.key != "windowMinutes" } }
        let oldRow = try JSONDecoder().decode(ProviderUsage.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(oldRow.tiers.first?.windowMinutes, "positive control")
        XCTAssertEqual(oldRow.paceMenuLabel(now: now), "▲20%", "a row written before 1.61 is paced too")
    }

    /// The tiers carry the window and a reset every reader parses, so the pace
    /// marker lands where an even burn would be: noon on 16 July is half of
    /// July, as upstream's #4847 fixture.
    func test_a_bare_reset_date_gives_tiers_a_window_and_a_pace() throws {
        let r = try result("""
        {"copilot_plan":"individual","quota_reset_date":"2026-08-01",
         "quota_snapshots":{"premium_interactions":{"entitlement":300,"remaining":90,"percent_remaining":30.0},
                            "chat":{"entitlement":1000,"remaining":700,"percent_remaining":70.0}}}
        """)
        XCTAssertEqual(r.usage.reset_time, "2026-08-01T00:00:00Z")
        for tier in r.usage.tiers {
            XCTAssertEqual(tier.windowMinutes, 31 * 24 * 60, tier.name)
            XCTAssertEqual(tier.reset_time, "2026-08-01T00:00:00Z")
        }
        let premium = try XCTUnwrap(r.usage.tiers.first { $0.name == "Premium" })
        let marker = try XCTUnwrap(QuotaBarMarkers.expectedPaceFraction(tier: premium, now: utc("2026-07-16T12:00:00Z")))
        XCTAssertEqual(marker, 0.5, accuracy: 0.001)
    }

    /// A reset that cannot be read gives no window, and so no pace (#708).
    func test_an_unreadable_reset_gives_no_window() throws {
        let r = try result("""
        {"copilot_plan":"individual","quota_reset_date":"soon",
         "quota_snapshots":{"premium_interactions":{"entitlement":300,"remaining":90,"percent_remaining":30.0}}}
        """)
        XCTAssertEqual(r.usage.tiers.first?.windowMinutes, nil)
        XCTAssertEqual(r.usage.tiers.first?.reset_time, "soon")
        XCTAssertNil(r.usage.paceSummary(now: utc("2026-07-16T12:00:00Z")))
        let none = try result("""
        {"copilot_plan":"individual",
         "quota_snapshots":{"premium_interactions":{"entitlement":300,"remaining":90,"percent_remaining":30.0}}}
        """)
        XCTAssertNil(none.usage.tiers.first?.windowMinutes)
    }
}
#endif
