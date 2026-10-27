// Unit tests for the v1.23.0 G4 ProviderUsage→UsagePace UI bridge
// (`ProviderUsage+Pace.swift`). Covers the Gemini 3.1 Pro R1-adopted
// reset-anchor guard, the 0…1 → 0…100 scale conversion, provider
// gating, and seam equivalence (the bridge must delegate faithfully
// to the vendored engine). en-locale pinned (mirrors
// UsagePaceTextTests) so any literal text stays deterministic.

import XCTest
@testable import CLIPulseCore

final class ProviderUsagePaceTests: XCTestCase {
    private var savedLocaleOverride: String?

    override func setUp() {
        super.setUp()
        savedLocaleOverride = LocaleOverrideStore.shared.override
        LocaleOverrideStore.shared.set("en")
    }

    override func tearDown() {
        LocaleOverrideStore.shared.set(savedLocaleOverride)
        super.tearDown()
    }

    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    private func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func usage(
        provider: String,
        quota: Int?,
        remaining: Int?,
        reset_time: String?,
        tiers: [TierDTO] = []) -> ProviderUsage
    {
        ProviderUsage(
            provider: provider,
            today_usage: 0, week_usage: 0,
            estimated_cost_today: 0, estimated_cost_week: 0,
            cost_status_today: "ok", cost_status_week: "ok",
            quota: quota, remaining: remaining,
            reset_time: reset_time,
            tiers: tiers,
            status_text: "",
            trend: [], recent_sessions: [], recent_errors: [])
    }

    /// A Codex reading whose headline is one window, as the collector writes
    /// it: the headline's remaining and reset are that window's.
    private func codexHeadline(
        remaining: Int, resetIn seconds: TimeInterval,
        windowMinutes: Int?, role: TierRole? = .primary,
        name: String = "Weekly") -> ProviderUsage
    {
        let reset = iso(now.addingTimeInterval(seconds))
        return usage(
            provider: "Codex", quota: 100, remaining: remaining, reset_time: reset,
            tiers: [TierDTO(name: name, quota: 100, remaining: remaining, reset_time: reset,
                            windowMinutes: windowMinutes, role: role)])
    }

    // MARK: - Scale + reset anchor

    func test_paceRateWindow_scales_0to1_into_0to100() throws {
        let u = usage(provider: "Codex", quota: 100, remaining: 40,
                      reset_time: iso(now.addingTimeInterval(3 * 24 * 3600)))
        let w = try XCTUnwrap(u.paceRateWindow(now: now))
        XCTAssertEqual(w.usedPercent, 60, accuracy: 0.0001)  // (100-40)/100 → 0.6 → ×100
        XCTAssertNil(w.windowMinutes)
        let resetsAt = try XCTUnwrap(w.resetsAt)
        XCTAssertEqual(resetsAt.timeIntervalSince(now), 3 * 24 * 3600, accuracy: 1)
    }

    func test_missing_reset_time_suppresses_pace() {            // Gemini R1 MEDIUM
        let u = usage(provider: "Codex", quota: 100, remaining: 40, reset_time: nil)
        XCTAssertNil(u.paceRateWindow(now: now))
        XCTAssertNil(u.paceSummary(now: now))
        XCTAssertNil(u.paceDetail(now: now))
        XCTAssertNil(u.paceMenuLabel(now: now))
    }

    func test_non_iso8601_reset_time_suppresses_pace() {        // Gemini R1 MEDIUM
        let u = usage(provider: "Codex", quota: 100, remaining: 40,
                      reset_time: "in 3 hours")
        XCTAssertNil(u.paceRateWindow(now: now))
        XCTAssertNil(u.paceSummary(now: now))
    }

    func test_past_reset_time_suppresses_pace() {               // Gemini R1 MEDIUM
        let u = usage(provider: "Codex", quota: 100, remaining: 40,
                      reset_time: iso(now.addingTimeInterval(-3600)))
        XCTAssertNil(u.paceRateWindow(now: now))
        XCTAssertNil(u.paceSummary(now: now))
        XCTAssertNil(u.paceMenuLabel(now: now))
    }

    // MARK: - Provider gating

    func test_non_codex_claude_provider_yields_nil_pace() {
        let u = usage(provider: "Cursor", quota: 100, remaining: 40,
                      reset_time: iso(now.addingTimeInterval(3 * 24 * 3600)))
        XCTAssertNotNil(u.paceRateWindow(now: now))   // window itself is provider-agnostic
        XCTAssertNil(u.paceSummary(now: now))         // engine gates to Codex/Claude
        XCTAssertNil(u.paceDetail(now: now))
        XCTAssertNil(u.paceMenuLabel(now: now))
    }

    func test_unknown_provider_string_yields_nil_pace() {
        let u = usage(provider: "Nonsense", quota: 100, remaining: 40,
                      reset_time: iso(now.addingTimeInterval(3 * 24 * 3600)))
        XCTAssertNil(u.paceSummary(now: now))         // providerKind == nil
        XCTAssertNil(u.paceMenuLabel(now: now))
    }

    // MARK: - Seam equivalence: bridge delegates faithfully to the engine

    func test_summary_detail_match_direct_engine_call() throws {
        let u = codexHeadline(remaining: 50, resetIn: 3 * 24 * 3600,
                              windowMinutes: 10080, role: .secondary)
        let w = try XCTUnwrap(u.paceRateWindow(now: now))
        XCTAssertNotNil(u.paceSummary(now: now))
        XCTAssertEqual(
            u.paceSummary(now: now),
            UsagePaceText.sessionSummary(provider: .codex, window: w, now: now))
        XCTAssertEqual(
            u.paceDetail(now: now)?.leftLabel,
            UsagePaceText.sessionDetail(provider: .codex, window: w, now: now)?.leftLabel)
    }

    func test_menu_label_is_compact_and_stage_consistent() throws {
        let u = codexHeadline(remaining: 50, resetIn: 3 * 24 * 3600,
                              windowMinutes: 10080, role: .secondary)
        let w = try XCTUnwrap(u.paceRateWindow(now: now))
        let pace = try XCTUnwrap(UsagePaceText.sessionPace(provider: .codex, window: w, now: now))
        let label = u.paceMenuLabel(now: now)

        do {
            let expectedPrefix: String
            switch pace.stage {
            case .onTrack: expectedPrefix = "≈"
            case .slightlyAhead, .ahead, .farAhead: expectedPrefix = "▲"
            case .slightlyBehind, .behind, .farBehind: expectedPrefix = "▼"
            }
            XCTAssertEqual(label?.hasPrefix(expectedPrefix), true)
            XCTAssertLessThanOrEqual(label?.count ?? 0, 6)  // ultra-compact menu form
        }
    }

    // MARK: - Window length of the headline (1.60 N4)
    //
    // The pace line used to build its window with no length, and the engine
    // took 5 hours. For a Codex account whose headline is a weekly or 30-day
    // window, the last 5 hours before that reset were paced as a 5-hour
    // window. The texts are asserted in zh-Hans, where a lookup that fell
    // back to English could not pass.

    /// Weekly-only Codex, 2 hours before the weekly reset, 90% used. Paced on
    /// the week, 98.8% of it has gone, so the account is 9% in reserve and
    /// lasts. Paced as 5 hours (the bug) it read "30% in deficit, projected
    /// empty in 20 minutes".
    func test_weekly_only_codex_near_its_reset_is_paced_on_the_week() throws {
        LocaleOverrideStore.shared.set("zh-Hans")
        let u = codexHeadline(remaining: 10, resetIn: 2 * 3600,
                              windowMinutes: 10080, role: .secondary)

        XCTAssertEqual(try XCTUnwrap(u.paceRateWindow(now: now)).windowMinutes, 10080)
        let detail = try XCTUnwrap(u.paceDetail(now: now))
        XCTAssertEqual(detail.expectedUsedPercent, (10080.0 - 120) / 10080 * 100, accuracy: 0.01)
        XCTAssertEqual(u.paceSummary(now: now), "节奏：结余 9% · 可用至重置")
        XCTAssertNotEqual(u.paceSummary(now: now), "节奏：透支 30% · 预计 20 分钟后用尽",
                          "the 5-hour pace this replaces")
        XCTAssertEqual(u.paceMenuLabel(now: now), "▼9%")
    }

    /// A row from a writer that stored no length: "Weekly" is read as a
    /// week, as the bars read it (`CodexQuotaWindows.resolved`).
    func test_codex_weekly_row_without_a_length_is_read_as_a_week() throws {
        let u = codexHeadline(remaining: 10, resetIn: 2 * 3600,
                              windowMinutes: nil, role: nil)
        XCTAssertEqual(try XCTUnwrap(u.paceRateWindow(now: now)).windowMinutes, 10080)
        XCTAssertEqual(u.paceMenuLabel(now: now), "▼9%")
    }

    /// A fixed 30-day window (`limit_window_seconds: 2592000`), 20 days
    /// before its reset, half used: a third of the window has gone, so 17%
    /// in deficit, projected empty in 10 days. A 5-hour window cannot reset
    /// 20 days away, so the old code showed nothing here.
    func test_thirty_day_codex_window_is_paced_on_43200_minutes() throws {
        LocaleOverrideStore.shared.set("zh-Hans")
        let u = codexHeadline(remaining: 50, resetIn: 20 * 86_400,
                              windowMinutes: 43_200, role: .primary, name: "Monthly")

        XCTAssertEqual(try XCTUnwrap(u.paceRateWindow(now: now)).windowMinutes, 43_200)
        let detail = try XCTUnwrap(u.paceDetail(now: now))
        XCTAssertEqual(detail.expectedUsedPercent, 100.0 / 3, accuracy: 0.01)
        XCTAssertEqual(u.paceSummary(now: now), "节奏：透支 17% · 预计 10 天后用尽")
        XCTAssertEqual(u.paceMenuLabel(now: now), "▲17%")
    }

    /// The same 30-day window in its last 5 hours: paced on 43,200 minutes
    /// (nearly all gone), not as a 5-hour window.
    func test_thirty_day_codex_window_near_its_reset_is_not_paced_as_five_hours() throws {
        let u = codexHeadline(remaining: 50, resetIn: 2 * 3600,
                              windowMinutes: 43_200, role: .primary, name: "Monthly")
        let detail = try XCTUnwrap(u.paceDetail(now: now))
        XCTAssertEqual(detail.expectedUsedPercent, (43_200.0 - 120) / 43_200 * 100, accuracy: 0.01)
        XCTAssertEqual(u.paceMenuLabel(now: now), "▼50%")
    }

    /// A Codex headline whose window length is unknown gets no pace, rather
    /// than a 5-hour one: no tier at all, or a tier with no length and a
    /// name that says nothing about one.
    func test_codex_headline_of_unknown_length_has_no_pace() {
        let noTiers = usage(provider: "Codex", quota: 100, remaining: 10,
                            reset_time: iso(now.addingTimeInterval(2 * 3600)))
        let unnamed = codexHeadline(remaining: 10, resetIn: 2 * 3600,
                                    windowMinutes: nil, role: .primary, name: "Window")
        for u in [noTiers, unnamed] {
            XCTAssertNotNil(u.paceRateWindow(now: now))
            XCTAssertNil(u.paceRateWindow(now: now)?.windowMinutes)
            XCTAssertNil(u.paceSummary(now: now))
            XCTAssertNil(u.paceDetail(now: now))
            XCTAssertNil(u.paceMenuLabel(now: now))
        }
    }

    /// The tier is the one whose reset is the headline's, not simply the
    /// first: a headline on the session window is paced for 5 hours even
    /// when a weekly tier comes first, and a weekly tier with another reset
    /// is never borrowed.
    func test_codex_length_comes_from_the_tier_with_the_headlines_reset() throws {
        let sessionReset = iso(now.addingTimeInterval(2 * 3600))
        let u = usage(
            provider: "Codex", quota: 100, remaining: 20, reset_time: sessionReset,
            tiers: [
                TierDTO(name: "Weekly", quota: 100, remaining: 50,
                        reset_time: iso(now.addingTimeInterval(4 * 86_400)),
                        windowMinutes: 10080, role: .secondary),
                TierDTO(name: "5h Window", quota: 100, remaining: 20, reset_time: sessionReset,
                        windowMinutes: 300, role: .primary),
            ])
        XCTAssertEqual(try XCTUnwrap(u.paceRateWindow(now: now)).windowMinutes, 300)
        XCTAssertEqual(u.paceMenuLabel(now: now), "▲20%")
    }

    /// Claude is unchanged: its headline is the session window, paced on
    /// 5 hours, though its tiers carry no length (`ClaudeResultBuilder`).
    func test_claude_session_pace_is_unchanged() throws {
        LocaleOverrideStore.shared.set("zh-Hans")
        let reset = iso(now.addingTimeInterval(2 * 3600))
        let u = usage(
            provider: "Claude", quota: 100, remaining: 20, reset_time: reset,
            tiers: [
                TierDTO(name: "5h Window", quota: 100, remaining: 20, reset_time: reset),
                TierDTO(name: "Weekly", quota: 100, remaining: 70,
                        reset_time: iso(now.addingTimeInterval(4 * 86_400))),
            ])

        XCTAssertEqual(try XCTUnwrap(u.paceRateWindow(now: now)).windowMinutes, 300)
        XCTAssertEqual(u.paceSummary(now: now), "节奏：透支 20% · 预计 45 分钟后用尽")
        XCTAssertEqual(u.paceMenuLabel(now: now), "▲20%")
        // A Claude reading without tiers is paced the same way.
        let bare = usage(provider: "Claude", quota: 100, remaining: 20, reset_time: reset)
        XCTAssertEqual(bare.paceSummary(now: now), u.paceSummary(now: now))
    }

    /// The menu bar's pace readout for a weekly-only Codex account near its
    /// reset, end to end through `MenuBarReadout`.
    func test_menu_bar_pace_readout_for_weekly_only_codex() {
        LocaleOverrideStore.shared.set("zh-Hans")
        let u = codexHeadline(remaining: 10, resetIn: 2 * 3600,
                              windowMinutes: 10080, role: .secondary)
        let readout = MenuBarReadout.resolve(
            isSignedIn: true, unresolvedAlertCount: 0, mode: .pace,
            mostUsedProvider: u, now: now)
        XCTAssertEqual(readout, .pace(provider: "Codex", glyph: "▼9%", summary: "节奏：结余 9%"))
        XCTAssertEqual(readout.visibleText, "▼9%")
    }

    #if os(macOS)
    /// From the API's JSON: a weekly-only and a 30-day-only account, through
    /// the collector and the display projection the UI applies.
    func test_collector_windows_pace_on_their_own_length() throws {
        func build(_ rateLimit: String) throws -> ProviderUsage {
            let json = #"{"plan_type": "plus", "rate_limit": "# + rateLimit + "}"
            let parsed = try CodexCollector.parseUsage(Data(json.utf8))
            let raw = CodexCollector().buildResult(usage: parsed, accountHadCredits: false).usage
            return QuotaBindingCap.projectedForDisplay(raw, now: now)
        }
        let soon = Int(now.addingTimeInterval(2 * 3600).timeIntervalSince1970)
        let weekly = try build("""
        {"primary_window": {"used_percent": 90, "reset_at": \(soon), "limit_window_seconds": 604800}}
        """)
        XCTAssertEqual(try XCTUnwrap(weekly.paceRateWindow(now: now)).windowMinutes, 10080)
        XCTAssertEqual(weekly.paceMenuLabel(now: now), "▼9%")

        let later = Int(now.addingTimeInterval(20 * 86_400).timeIntervalSince1970)
        let monthly = try build("""
        {"primary_window": {"used_percent": 50, "reset_at": \(later), "limit_window_seconds": 2592000}}
        """)
        XCTAssertEqual(try XCTUnwrap(monthly.paceRateWindow(now: now)).windowMinutes, 43_200)
        XCTAssertEqual(monthly.paceMenuLabel(now: now), "▲17%")
    }
    #endif
}
