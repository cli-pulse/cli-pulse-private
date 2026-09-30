import Foundation
import XCTest
@testable import CLIPulseCore

/// Codex windows named by their length, and the binding weekly cap.
///
/// Four groups:
///   1. `RateWindow.bindingQuotaProjection` and `CodexRateWindowNormalizer`,
///      the two pure functions ported from CodexBar (their upstream cases,
///      as XCTest);
///   2. the collector: windows filed by length, with `windowMinutes`/`role`;
///   3. the display projection (`QuotaBindingCap`) on the model every surface
///      reads, including rows older writers uploaded without the fields;
///   4. the fields survive the Mac upload and come back on download.
final class CodexQuotaWindowsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let iso = ISO8601DateFormatter()

    private func window(
        used: Double,
        minutes: Int?,
        resetIn seconds: TimeInterval?,
        description: String? = nil
    ) -> RateWindow {
        RateWindow(
            usedPercent: used,
            windowMinutes: minutes,
            resetsAt: seconds.map { now.addingTimeInterval($0) },
            resetDescription: description
        )
    }

    private let hour: TimeInterval = 3600
    private let day: TimeInterval = 86_400

    // MARK: - 1a. Binding projection (upstream MenuCardBindingQuotaTests, pure part)

    func testWeeklyExhaustionCapsTheSessionWithTheWeeklyReset() {
        let projection = RateWindow.bindingQuotaProjection(
            primary: window(used: 40, minutes: 300, resetIn: 2 * hour),
            bindingLanes: [window(used: 100, minutes: 10080, resetIn: 3 * day + 5 * hour)],
            now: now
        )
        XCTAssertEqual(projection?.usedPercent, 100)
        XCTAssertEqual(projection?.resetsAt, now.addingTimeInterval(3 * day + 5 * hour))
    }

    /// The negative control the plan asks for: a weekly window with room left
    /// does not touch the session reading.
    func testWeeklyWithRoomDoesNotCap() {
        XCTAssertNil(RateWindow.bindingQuotaProjection(
            primary: window(used: 40, minutes: 300, resetIn: 2 * hour),
            bindingLanes: [window(used: 30, minutes: 10080, resetIn: 4 * day)],
            now: now
        ))
    }

    func testExpiredWeeklyResetStopsCappingAStaleReading() {
        XCTAssertNil(RateWindow.bindingQuotaProjection(
            primary: window(used: 40, minutes: 300, resetIn: 2 * hour),
            bindingLanes: [window(used: 100, minutes: 10080, resetIn: -hour)],
            now: now
        ))
    }

    func testResetExactlyNowStopsCapping() {
        XCTAssertNil(RateWindow.bindingQuotaProjection(
            primary: window(used: 40, minutes: 300, resetIn: 2 * hour),
            bindingLanes: [window(used: 120, minutes: 10080, resetIn: 0)],
            now: now
        ))
    }

    func testMonthlyExhaustionCapsWhenMonthlyIsBinding() {
        let projection = RateWindow.bindingQuotaProjection(
            primary: window(used: 40, minutes: 300, resetIn: 2 * hour),
            bindingLanes: [
                window(used: 30, minutes: 10080, resetIn: 4 * day),
                window(used: 100, minutes: 43200, resetIn: 10 * day),
            ],
            now: now
        )
        XCTAssertEqual(projection?.resetsAt, now.addingTimeInterval(10 * day))
    }

    func testMultipleExhaustedLanesUseTheFinalUnblockReset() {
        let projection = RateWindow.bindingQuotaProjection(
            primary: window(used: 40, minutes: 300, resetIn: 2 * hour),
            bindingLanes: [
                window(used: 100, minutes: 10080, resetIn: 5 * day),
                window(used: 100, minutes: 43200, resetIn: 2 * day),
            ],
            now: now
        )
        XCTAssertEqual(projection?.resetsAt, now.addingTimeInterval(5 * day))
    }

    func testUnknownExhaustedResetSuppressesAnEarlierKnownPromise() {
        let projection = RateWindow.bindingQuotaProjection(
            primary: window(used: 40, minutes: 300, resetIn: 2 * hour),
            bindingLanes: [
                window(used: 100, minutes: 10080, resetIn: 5 * day),
                window(used: 100, minutes: 43200, resetIn: nil, description: "monthly reset pending"),
            ],
            now: now
        )
        XCTAssertEqual(projection?.usedPercent, 100)
        XCTAssertNil(projection?.resetsAt)
        XCTAssertNil(projection?.resetDescription)
    }

    func testALoneTextualBlockerKeepsItsDescription() {
        let projection = RateWindow.bindingQuotaProjection(
            primary: window(used: 40, minutes: 300, resetIn: 2 * hour),
            bindingLanes: [window(used: 100, minutes: 10080, resetIn: nil, description: " resets in 6 hours ")],
            now: now
        )
        XCTAssertNil(projection?.resetsAt)
        XCTAssertEqual(projection?.resetDescription, "resets in 6 hours")
    }

    func testBothLanesExhaustedShowTheLaterSessionReset() {
        let projection = RateWindow.bindingQuotaProjection(
            primary: window(used: 100, minutes: 300, resetIn: 5 * day),
            bindingLanes: [window(used: 100, minutes: 10080, resetIn: 3 * day)],
            now: now
        )
        XCTAssertEqual(projection?.resetsAt, now.addingTimeInterval(5 * day))
    }

    func testAShorterLaneNeverCapsALongerPrimary() {
        XCTAssertNil(RateWindow.bindingQuotaProjection(
            primary: window(used: 40, minutes: 10080, resetIn: 3 * day),
            bindingLanes: [window(used: 100, minutes: 300, resetIn: 2 * hour)],
            now: now
        ))
    }

    func testALaneOfUnknownLengthNeverCaps() {
        XCTAssertNil(RateWindow.bindingQuotaProjection(
            primary: window(used: 40, minutes: 300, resetIn: 2 * hour),
            bindingLanes: [window(used: 100, minutes: nil, resetIn: 3 * day)],
            now: now
        ))
    }

    // MARK: - 1b. Normalizer (upstream CodexCLIWindowNormalizationTests)

    func testNormalizerMapsALoneWeeklyWindowIntoSecondary() {
        let lanes = CodexRateWindowNormalizer.normalize(
            primary: window(used: 5, minutes: 10080, resetIn: nil), secondary: nil
        )
        XCTAssertNil(lanes.primary)
        XCTAssertEqual(lanes.secondary?.usedPercent, 5)
        XCTAssertEqual(lanes.secondary?.windowMinutes, 10080)
    }

    func testNormalizerKeepsALoneSessionWindowInPrimary() {
        let lanes = CodexRateWindowNormalizer.normalize(
            primary: window(used: 31, minutes: 300, resetIn: nil), secondary: nil
        )
        XCTAssertEqual(lanes.primary?.windowMinutes, 300)
        XCTAssertNil(lanes.secondary)
    }

    func testNormalizerKeepsSessionAndWeeklyOrdering() {
        let lanes = CodexRateWindowNormalizer.normalize(
            primary: window(used: 31, minutes: 300, resetIn: nil),
            secondary: window(used: 26, minutes: 10080, resetIn: nil)
        )
        XCTAssertEqual(lanes.primary?.usedPercent, 31)
        XCTAssertEqual(lanes.secondary?.usedPercent, 26)
    }

    func testNormalizerSwapsReversedWeeklyAndUnknownWindows() {
        let lanes = CodexRateWindowNormalizer.normalize(
            primary: window(used: 43, minutes: 10080, resetIn: nil),
            secondary: window(used: 17, minutes: 540, resetIn: nil)
        )
        XCTAssertEqual(lanes.primary?.windowMinutes, 540)
        XCTAssertEqual(lanes.secondary?.windowMinutes, 10080)
    }

    // MARK: - 3. Display projection

    private func codexUsage(
        tiers: [TierDTO],
        provider: String = ProviderKind.codex.rawValue,
        remaining: Int = 60,
        resetTime: String? = nil
    ) -> ProviderUsage {
        ProviderUsage(
            provider: provider,
            today_usage: 40,
            week_usage: 100,
            estimated_cost_today: 0,
            estimated_cost_week: 0,
            cost_status_today: "Unavailable",
            cost_status_week: "Unavailable",
            quota: 100,
            remaining: remaining,
            plan_type: "Plus",
            reset_time: resetTime ?? tiers.first?.reset_time,
            tiers: tiers,
            status_text: "\(100 - remaining)% used",
            trend: [],
            recent_sessions: [],
            recent_errors: []
        )
    }

    private func stamp(_ seconds: TimeInterval) -> String {
        iso.string(from: now.addingTimeInterval(seconds))
    }

    private var sessionReset: String { stamp(2 * hour) }
    private var weeklyReset: String { stamp(4 * day + 36 * 60) }

    private func sessionTier(remaining: Int = 60, minutes: Int? = 300,
                             role: TierRole? = .primary, name: String = "5h Window") -> TierDTO {
        TierDTO(name: name, quota: 100, remaining: remaining, reset_time: sessionReset,
                windowMinutes: minutes, role: role)
    }

    private func weeklyTier(remaining: Int, minutes: Int? = 10080,
                            role: TierRole? = .secondary) -> TierDTO {
        TierDTO(name: "Weekly", quota: 100, remaining: remaining, reset_time: weeklyReset,
                windowMinutes: minutes, role: role)
    }

    /// The plan's case: weekly 0% left + 5h 60% left ⇒ the 5h window, and the
    /// provider's headline, read 0% with the weekly reset.
    func testExhaustedWeeklyCapsTheSessionTierAndTheHeadline() {
        let shown = QuotaBindingCap.projectedForDisplay(
            codexUsage(tiers: [sessionTier(), weeklyTier(remaining: 0)]),
            now: now
        )
        XCTAssertEqual(shown.tiers[0].remaining, 0)
        XCTAssertEqual(shown.tiers[0].reset_time, weeklyReset)
        XCTAssertEqual(shown.tiers[1].remaining, 0)
        XCTAssertEqual(shown.tiers[1].reset_time, weeklyReset)
        XCTAssertEqual(shown.remaining, 0)
        XCTAssertEqual(shown.reset_time, weeklyReset)
        XCTAssertEqual(shown.usagePercent, 1.0)
        XCTAssertEqual(shown.status_text, "100% used")
    }

    /// Negative control: weekly not used up ⇒ nothing projected.
    func testWeeklyWithRoomLeavesEveryReadingAlone() {
        let raw = codexUsage(tiers: [sessionTier(), weeklyTier(remaining: 30)])
        let shown = QuotaBindingCap.projectedForDisplay(raw, now: now)
        XCTAssertEqual(shown.tiers.map(\.remaining), [60, 30])
        XCTAssertEqual(shown.tiers[0].reset_time, sessionReset)
        XCTAssertEqual(shown.remaining, 60)
        XCTAssertEqual(shown.reset_time, sessionReset)
        XCTAssertEqual(shown.status_text, "40% used")
    }

    func testAPassedWeeklyResetStopsTheCap() {
        let stale = TierDTO(name: "Weekly", quota: 100, remaining: 0, reset_time: stamp(-hour),
                            windowMinutes: 10080, role: .secondary)
        let shown = QuotaBindingCap.projectedForDisplay(
            codexUsage(tiers: [sessionTier(), stale]), now: now
        )
        XCTAssertEqual(shown.tiers[0].remaining, 60)
        XCTAssertEqual(shown.remaining, 60)
    }

    /// Rows uploaded before 1.55 have neither field; the helper's rows call
    /// the 5-hour window "Session". Both still cap, from their names.
    func testRowsWithoutRoleOrLengthAreReadFromTheirNames() {
        for sessionName in ["5h Window", "Session"] {
            let shown = QuotaBindingCap.projectedForDisplay(
                codexUsage(tiers: [
                    sessionTier(minutes: nil, role: nil, name: sessionName),
                    weeklyTier(remaining: 0, minutes: nil, role: nil),
                ]),
                now: now
            )
            XCTAssertEqual(shown.tiers[0].remaining, 0, sessionName)
            XCTAssertEqual(shown.tiers[0].reset_time, weeklyReset, sessionName)
            XCTAssertEqual(shown.tiers[0].name, sessionName, "the stored name is not rewritten")
            XCTAssertEqual(shown.tiers.map(\.role), [.primary, .secondary], sessionName)
            XCTAssertEqual(shown.tiers.map(\.windowMinutes), [300, 10080], sessionName)
        }
    }

    /// Before 1.55 every writer gave the primary SLOT's name ("5h Window",
    /// or the helpers' "Session") to whatever it held, and a weekly-only
    /// account's one window comes in that slot. A reset days away says it is
    /// the weekly window: it keeps its weekly-scale pace marker and the
    /// Watch's weekly ring finds it. Read as 5 hours, the marker vanished.
    func testALegacyPrimarySlotResettingInDaysIsReadAsWeekly() {
        for name in ["5h Window", "Session"] {
            let weeklyOnly = TierDTO(name: name, quota: 100, remaining: 30,
                                     reset_time: stamp(4 * day), windowMinutes: nil, role: nil)
            let shown = QuotaBindingCap.projectedForDisplay(
                codexUsage(tiers: [weeklyOnly], remaining: 30), now: now
            )
            let tier = shown.tiers[0]
            XCTAssertEqual(tier.windowMinutes, 10080, name)
            XCTAssertEqual(tier.role, .secondary, name)
            XCTAssertEqual(tier.name, name, "the stored name is not rewritten")
            XCTAssertEqual(
                QuotaBarMarkers.expectedPaceFraction(tier: tier, now: now) ?? 0,
                3.0 / 7.0, accuracy: 0.01, name
            )
            XCTAssertEqual(WatchRingMath.weeklyTier(shown), tier, name)
            XCTAssertEqual(shown.remaining, 30, "one window: nothing to cap")
        }
        // Within 5 hours of its reset, or with none, the name is taken at its
        // word; further out than a week it fits neither window.
        XCTAssertEqual(CodexQuotaWindows.primarySlot(resetTime: stamp(4 * hour), now: now)?.minutes, 300)
        XCTAssertEqual(CodexQuotaWindows.primarySlot(resetTime: stamp(-day), now: now)?.minutes, 300)
        XCTAssertEqual(CodexQuotaWindows.primarySlot(resetTime: nil, now: now)?.role, .primary)
        XCTAssertNil(CodexQuotaWindows.primarySlot(resetTime: stamp(20 * day), now: now))
    }

    func testOtherProvidersAreNotProjected() {
        let claude = codexUsage(
            tiers: [sessionTier(), weeklyTier(remaining: 0)],
            provider: ProviderKind.claude.rawValue
        )
        let shown = QuotaBindingCap.projectedForDisplay(claude, now: now)
        XCTAssertEqual(shown.tiers.map(\.remaining), [60, 0])
        XCTAssertEqual(shown.remaining, 60)
    }

    func testProjectionIsIdempotent() {
        let once = QuotaBindingCap.projectedForDisplay(
            codexUsage(tiers: [sessionTier(), weeklyTier(remaining: 0)]), now: now
        )
        let twice = QuotaBindingCap.projectedForDisplay(once, now: now)
        XCTAssertEqual(twice.tiers, once.tiers)
        XCTAssertEqual(twice.remaining, once.remaining)
        XCTAssertEqual(twice.reset_time, once.reset_time)
        XCTAssertEqual(twice.status_text, once.status_text)
    }

    func testAccountsOfAMultiAccountProviderAreProjectedToo() {
        let account = ProviderAccountUsage(
            id: UUID(uuidString: "55555555-5555-4555-8555-555555555555")!,
            provider: .codex,
            accountLabel: "Work",
            planEvidence: ProviderPlanEvidence(
                rawValue: "plus", displayValue: "Plus", source: .providerAPI,
                confidence: .high, observedAt: now
            ),
            quota: 100,
            remaining: 60,
            tiers: [sessionTier(), weeklyTier(remaining: 0)],
            resetTime: sessionReset,
            observedAt: iso.string(from: now),
            sourceDeviceID: nil,
            statusText: "40% used"
        )
        let shown = QuotaBindingCap.projectedForDisplay([account], now: now)[0]
        XCTAssertEqual(shown.tiers[0].remaining, 0)
        XCTAssertEqual(shown.remaining, 0)
        XCTAssertEqual(shown.resetTime, weeklyReset)
        XCTAssertEqual(shown.statusText, "100% used")
        XCTAssertEqual(shown.id, account.id)
    }

    /// The menu bar's "% left" is the provider's headline. Asserted in
    /// zh-Hans, where the spoken label has to carry the projected number.
    func testMenuBarReadsTheCappedHeadline() {
        let shown = QuotaBindingCap.projectedForDisplay(
            codexUsage(tiers: [sessionTier(), weeklyTier(remaining: 0)]), now: now
        )
        let readout = MenuBarReadout.resolve(
            isSignedIn: true, unresolvedAlertCount: 0, mode: .percent,
            mostUsedProvider: shown, now: now
        )
        XCTAssertEqual(readout, .percentLeft(provider: "Codex", percent: 0))
        XCTAssertEqual(readout.visibleText, "0%")

        var english = ""
        withLocale("en") { english = L10n.a11y.percentRemaining("Codex", 0) }
        withLocale("zh-Hans") {
            let clause = L10n.a11y.percentRemaining("Codex", 0)
            XCTAssertNotEqual(clause, english, "zh-Hans override is not in effect")
            XCTAssertTrue(clause.contains("0"), clause)
            XCTAssertEqual(
                readout.accessibilityLabel(serverOnline: true),
                L10n.a11y.clauses([L10n.widget.appName, clause])
            )
        }

        // Negative control: the raw value reads 60% left.
        let raw = MenuBarReadout.resolve(
            isSignedIn: true, unresolvedAlertCount: 0, mode: .percent,
            mostUsedProvider: codexUsage(tiers: [sessionTier(), weeklyTier(remaining: 0)]),
            now: now
        )
        XCTAssertEqual(raw, .percentLeft(provider: "Codex", percent: 60))
    }

    /// While the cap holds, the 5-hour window has no pace to report: a
    /// "runs out in 3h" line beside a bar reading 0% would contradict it.
    func testPaceLinesDisappearWhileCapped() {
        let shown = QuotaBindingCap.projectedForDisplay(
            codexUsage(tiers: [sessionTier(remaining: 20), weeklyTier(remaining: 0)],
                       remaining: 20),
            now: now
        )
        XCTAssertNil(shown.paceSummary(now: now))
        XCTAssertNil(QuotaBarMarkers.expectedPaceFraction(tier: shown.tiers[0], now: now))
    }

    // MARK: - Pace marker length

    /// `windowMinutes = 300` puts the pace marker on the 5-hour bar for 5
    /// hours. Without it the engine assumed a week and put the marker at
    /// ~98.5% for a window half gone.
    func testLegacyRowsGetTheSessionLengthForThePaceMarker() {
        let halfGone = TierDTO(name: "5h Window", quota: 100, remaining: 80,
                               reset_time: stamp(150 * 60), windowMinutes: nil, role: nil)
        let raw = QuotaBarMarkers.expectedPaceFraction(tier: halfGone, now: now)
        XCTAssertEqual(raw ?? 0, 0.985, accuracy: 0.01, "the bug this fixes")

        let shown = QuotaBindingCap.projectedForDisplay(
            codexUsage(tiers: [halfGone], remaining: 80), now: now
        )
        XCTAssertEqual(
            QuotaBarMarkers.expectedPaceFraction(tier: shown.tiers[0], now: now) ?? 0,
            0.5, accuracy: 0.01
        )
    }

    // MARK: - Localized tier names

    private func withLocale(_ code: String, _ body: () -> Void) {
        let store = LocaleOverrideStore.shared
        let previous = store.override
        store.set(code)
        defer { store.set(previous) }
        body()
    }

    func testCodexTierNamesFollowTheLength() {
        XCTAssertEqual(CodexQuotaWindows.tierName(windowMinutes: 300, lane: .session), "5h Window")
        XCTAssertEqual(CodexQuotaWindows.tierName(windowMinutes: 10080, lane: .weekly), "Weekly")
        // A known length decides even in the other lane.
        XCTAssertEqual(CodexQuotaWindows.tierName(windowMinutes: 10080, lane: .session), "Weekly")
        XCTAssertEqual(CodexQuotaWindows.tierName(windowMinutes: 43200, lane: .weekly), "Monthly")
        XCTAssertEqual(CodexQuotaWindows.tierName(windowMinutes: 1440, lane: .session), "Daily")
        XCTAssertEqual(CodexQuotaWindows.tierName(windowMinutes: 540, lane: .session), "Window")
        // Unknown length keeps the name the slot always had.
        XCTAssertEqual(CodexQuotaWindows.tierName(windowMinutes: nil, lane: .session), "5h Window")
        XCTAssertEqual(CodexQuotaWindows.tierName(windowMinutes: nil, lane: .weekly), "Weekly")

        // Every name it can produce is one the display translates, and the
        // weekly-only account's bar now says "weekly" where it said "5h".
        withLocale("zh-Hans") {
            for name in ["5h Window", "Daily", "Weekly", "Monthly", "Window"] {
                XCTAssertNotEqual(L10n.quotaTier.localized(name), name, "\(name) renders in English")
            }
            XCTAssertEqual(L10n.quotaTier.localized(
                CodexQuotaWindows.tierName(windowMinutes: 10080, lane: .session)
            ), L10n.quotaTier.weekly)
            XCTAssertNotEqual(L10n.quotaTier.weekly, L10n.quotaTier.window5h)
        }
    }

    /// Two bars under one name cannot be told apart, and the card keys its
    /// bars by name (`UsageTier.id`): the second of two same-named windows
    /// gets another name.
    func testTwoCodexWindowsNeverShareAName() {
        let pairs: [(Int?, Int?)] = [
            (10080, 10080), (300, 300), (1440, 1440), (43200, 43200),
            (540, 720), (nil, nil), (300, 10080), (nil, 300),
        ]
        for (first, second) in pairs {
            let a = CodexQuotaWindows.tierName(windowMinutes: first, lane: .session)
            let b = CodexQuotaWindows.tierName(windowMinutes: second, lane: .weekly, besides: a)
            XCTAssertNotEqual(a, b, "\(String(describing: first)) + \(String(describing: second))")
        }
        XCTAssertEqual(
            CodexQuotaWindows.tierName(windowMinutes: 10080, lane: .weekly, besides: "Weekly"),
            "Window"
        )
        XCTAssertEqual(
            CodexQuotaWindows.tierName(windowMinutes: 720, lane: .weekly, besides: "Window"),
            "Weekly"
        )
        // Without a clash the name is the length's.
        XCTAssertEqual(
            CodexQuotaWindows.tierName(windowMinutes: 10080, lane: .weekly, besides: "5h Window"),
            "Weekly"
        )
    }
}

// MARK: - 3b. Wiring: the projection reaches the UI state

@MainActor
final class CodexQuotaWindowStateTests: XCTestCase {
    /// `applyRefreshPayload` is where refreshed data becomes what every Mac
    /// and iPhone surface reads (cards, menu bar, widgets, the Watch relay).
    /// A projection that exists but is not called there changes nothing.
    func testRefreshedCodexDataReachesTheStateProjected() {
        let iso = ISO8601DateFormatter()
        let now = Date()
        let sessionReset = iso.string(from: now.addingTimeInterval(2 * 3600))
        let weeklyReset = iso.string(from: now.addingTimeInterval(4 * 86_400))
        let raw = ProviderUsage(
            provider: "Codex", today_usage: 40, week_usage: 100,
            estimated_cost_today: 0, estimated_cost_week: 0,
            cost_status_today: "Unavailable", cost_status_week: "Unavailable",
            quota: 100, remaining: 60, plan_type: "Plus", reset_time: sessionReset,
            tiers: [
                TierDTO(name: "5h Window", quota: 100, remaining: 60, reset_time: sessionReset,
                        windowMinutes: 300, role: .primary),
                TierDTO(name: "Weekly", quota: 100, remaining: 0, reset_time: weeklyReset,
                        windowMinutes: 10080, role: .secondary),
            ],
            status_text: "40% used", trend: [], recent_sessions: [], recent_errors: []
        )
        let state = AppState()
        state.providerConfigs = [ProviderConfig(kind: .codex, isEnabled: true)]
        state.applyRefreshPayload(DataRefreshManager.RefreshPayload(
            dashboard: DashboardSummary(
                total_usage_today: 0, total_estimated_cost_today: 0, cost_status: "Estimated",
                total_requests_today: 0, active_sessions: 0, online_devices: 0,
                unresolved_alerts: 0, provider_breakdown: [], top_projects: [], trend: [],
                recent_activity: [], risk_signals: [],
                alert_summary: AlertSummaryDTO(critical: 0, warning: 0, info: 0)
            ),
            providers: [raw],
            providerAccounts: [],
            sessions: [],
            devices: [],
            alerts: [],
            locallySupplementedProviders: [],
            tierLimitWarning: nil,
            lastRefresh: now,
            isLocalMode: true,
            costUsageScanResult: nil
        ))
        state.buildProviderDetails()

        let codex = state.providers.first { $0.provider == "Codex" }
        XCTAssertEqual(codex?.remaining, 0, "the headline the menu bar and widgets read")
        XCTAssertEqual(codex?.reset_time, weeklyReset)
        let card = state.providerDetails.first { $0.provider.provider == "Codex" }
        XCTAssertEqual(card?.tiers.first?.remaining, 0, "the card's 5-hour bar")
        XCTAssertEqual(card?.tiers.first?.resetTime, weeklyReset)
    }
}

#if os(macOS)
// MARK: - 2. Collector

final class CodexCollectorWindowTests: XCTestCase {
    private func build(_ rateLimit: String) throws -> ProviderUsage {
        let json = #"{"plan_type": "plus", "rate_limit": "# + rateLimit + "}"
        let usage = try CodexCollector.parseUsage(Data(json.utf8))
        return CodexCollector().buildResult(usage: usage, accountHadCredits: false).usage
    }

    func testWindowsCarryTheirLengthAndRole() throws {
        let usage = try build("""
        {"primary_window": {"used_percent": 40, "reset_at": 1790007200, "limit_window_seconds": 18000},
         "secondary_window": {"used_percent": 100, "reset_at": 1790400000, "limit_window_seconds": 604800}}
        """)
        XCTAssertEqual(usage.tiers.map(\.name), ["5h Window", "Weekly"])
        XCTAssertEqual(usage.tiers.map(\.windowMinutes), [300, 10080])
        XCTAssertEqual(usage.tiers.map(\.role), [.primary, .secondary])
        // The collector's own result stays raw: the cap is display-only.
        XCTAssertEqual(usage.tiers.map(\.remaining), [60, 0])
        XCTAssertEqual(usage.remaining, 60)
    }

    /// A weekly-only account gets its window in `primary_window`. It used to
    /// be named "5h Window" and headline the provider as a 5-hour reading.
    func testALoneWeeklyWindowInThePrimarySlotIsWeekly() throws {
        let usage = try build("""
        {"primary_window": {"used_percent": 70, "reset_at": 1790400000, "limit_window_seconds": 604800}}
        """)
        XCTAssertEqual(usage.tiers.map(\.name), ["Weekly"])
        XCTAssertEqual(usage.tiers.first?.role, .secondary)
        XCTAssertEqual(usage.remaining, 30)
        XCTAssertEqual(usage.status_text, "70% used")
        XCTAssertEqual(usage.week_usage, 70)
    }

    func testReversedSlotsArePutBackByLength() throws {
        let usage = try build("""
        {"primary_window": {"used_percent": 43, "limit_window_seconds": 604800},
         "secondary_window": {"used_percent": 17, "limit_window_seconds": 18000}}
        """)
        XCTAssertEqual(usage.tiers.map(\.name), ["5h Window", "Weekly"])
        XCTAssertEqual(usage.tiers.map(\.remaining), [83, 57])
        XCTAssertEqual(usage.remaining, 83, "the headline is the session window")
    }

    func testTwoWindowsOfOneLengthGetTwoNames() throws {
        let usage = try build("""
        {"primary_window": {"used_percent": 10, "limit_window_seconds": 604800},
         "secondary_window": {"used_percent": 20, "limit_window_seconds": 604800}}
        """)
        XCTAssertEqual(usage.tiers.map(\.name), ["Weekly", "Window"])
        XCTAssertEqual(usage.tiers.map(\.windowMinutes), [10080, 10080])
    }

    func testADailyWindowIsNamedDaily() throws {
        let usage = try build("""
        {"primary_window": {"used_percent": 10, "limit_window_seconds": 86400}}
        """)
        XCTAssertEqual(usage.tiers.map(\.name), ["Daily"])
        XCTAssertEqual(usage.tiers.map(\.windowMinutes), [1440])
    }

    func testUnknownLengthKeepsTheSlotName() throws {
        let usage = try build("""
        {"primary_window": {"used_percent": 10}, "secondary_window": {"used_percent": 20}}
        """)
        XCTAssertEqual(usage.tiers.map(\.name), ["5h Window", "Weekly"])
        XCTAssertEqual(usage.tiers.map(\.windowMinutes), [nil, nil])
        XCTAssertEqual(usage.tiers.map(\.role), [.primary, .secondary])
    }

    /// The in-app helper (CLIPulseHelper) runs this same collector and sends
    /// its tiers through `helper_sync`. It must put the same two fields in
    /// the row as the app's direct upload, or whichever writes last decides
    /// whether iPhone and Watch see them.
    func testTheHelperSyncRowCarriesTheSameFields() throws {
        let usage = try build("""
        {"primary_window": {"used_percent": 40, "reset_at": 1790007200, "limit_window_seconds": 18000},
         "secondary_window": {"used_percent": 100, "reset_at": 1790400000, "limit_window_seconds": 604800}}
        """)
        let payload = HelperIPC.CollectorUsagePayload(
            quota: usage.quota, remaining: usage.remaining,
            todayUsage: usage.today_usage, weekUsage: usage.week_usage,
            statusText: usage.status_text, planType: usage.plan_type,
            resetTime: usage.reset_time, tiers: usage.tiers
        )
        let rows = HelperAPIClient.legacyProviderTiers(from: ["Codex": payload])
        let row = try XCTUnwrap(rows["Codex"] as? [String: Any])
        let tiersJSON = try JSONSerialization.data(withJSONObject: row["tiers"] ?? [])
        let stored = try JSONDecoder().decode([TierDTO].self, from: tiersJSON)
        XCTAssertEqual(stored, usage.tiers)
        XCTAssertEqual(stored.map(\.windowMinutes), [300, 10080])
        XCTAssertEqual(stored.map(\.role), [.primary, .secondary])
    }

    /// End to end on the Mac card's data path: collector → provider details →
    /// the UI tier → the pace marker, for a 5-hour window half gone.
    func testTheCardsPaceMarkerIsPlacedForFiveHours() throws {
        let now = Date()
        let reset = Int(now.addingTimeInterval(150 * 60).timeIntervalSince1970)
        let usage = try build("""
        {"primary_window": {"used_percent": 10, "reset_at": \(reset), "limit_window_seconds": 18000}}
        """)
        let details = AppState.computedProviderDetails(
            providers: [usage],
            configs: ProviderConfig.defaults(),
            isLocalMode: true,
            locallySupplementedProviders: []
        )
        let tier = try XCTUnwrap(details.first { $0.provider.provider == "Codex" }?.tiers.first)
        XCTAssertEqual(tier.windowMinutes, 300)
        XCTAssertEqual(
            QuotaBarMarkers.expectedPaceFraction(tier: tier, now: now) ?? 0,
            0.5, accuracy: 0.01
        )
    }
}
#endif

// MARK: - 4. Upload, then download

final class CodexQuotaWindowRoundTripTests: XCTestCase {
    override func setUp() {
        super.setUp()
        RoundTripStub.reset()
    }

    override func tearDown() {
        RoundTripStub.reset()
        super.tearDown()
    }

    /// What the Mac uploads to `provider_quotas` is what iPhone and Watch read
    /// back through `provider_summary` (which returns `tiers` as stored). Both
    /// fields used to be dropped on the way up.
    func testWindowLengthAndRoleSurviveUploadAndDownload() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RoundTripStub.self]
        let api = APIClient(
            token: "access-token",
            supabaseURL: "https://round-trip.test",
            supabaseAnonKey: "anon",
            session: URLSession(configuration: config),
            providerAccountFlags: .init(readV2: false, writeV2: false)
        )
        _ = await api.beginExternalAuthorizationTransition(generation: 1)
        _ = await api.installExternalAuthenticatedSession(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            userID: "99999999-9999-4999-8999-999999999999",
            transitionGeneration: 1
        )
        let maybeLease = await api.authorizationLease()
        let lease = try XCTUnwrap(maybeLease)

        let uploaded = ProviderUsage(
            provider: "Codex", today_usage: 40, week_usage: 100,
            estimated_cost_today: 0, estimated_cost_week: 0,
            cost_status_today: "Unavailable", cost_status_week: "Unavailable",
            quota: 100, remaining: 60, plan_type: "Plus",
            reset_time: "2026-10-01T05:00:00Z",
            tiers: [
                TierDTO(name: "5h Window", quota: 100, remaining: 60,
                        reset_time: "2026-10-01T05:00:00Z", windowMinutes: 300, role: .primary),
                TierDTO(name: "Weekly", quota: 100, remaining: 0,
                        reset_time: "2026-10-05T00:00:00Z", windowMinutes: 10080, role: .secondary),
                TierDTO(name: "Credits", quota: 5, remaining: 5),
            ],
            status_text: "40% used", trend: [], recent_sessions: [], recent_errors: []
        )
        await api.syncProviderQuotas(
            [CollectorResult(usage: uploaded, dataKind: .quota)],
            authorizationLease: lease
        )

        let posted = try XCTUnwrap(RoundTripStub.storedRows().first)
        let downloaded = try await api.providers()
        let codex = try XCTUnwrap(downloaded.first { $0.provider == "Codex" })

        XCTAssertEqual(codex.tiers.map(\.windowMinutes), [300, 10080, nil])
        XCTAssertEqual(codex.tiers.map(\.role), [.primary, .secondary, nil])
        XCTAssertEqual(codex.tiers, uploaded.tiers)
        // Uniform keys: an unset field is sent as null, not left out.
        let credits = try XCTUnwrap((posted["tiers"] as? [[String: Any]])?.last)
        XCTAssertTrue(credits["windowMinutes"] is NSNull)
        XCTAssertTrue(credits["role"] is NSNull)
    }
}

/// Plays `provider_quotas` (stores the POSTed rows) and `provider_summary`
/// (returns them with `tiers` exactly as stored, as the RPC does).
private final class RoundTripStub: URLProtocol {
    nonisolated(unsafe) private static var rows: [[String: Any]] = []
    private static let lock = NSLock()

    static func reset() {
        lock.lock()
        rows = []
        lock.unlock()
    }

    static func storedRows() -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return rows
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let path = request.url?.path ?? ""
        var body = Data("[]".utf8)
        var status = 200
        if path.hasSuffix("/rest/v1/provider_quotas") {
            let posted = (Self.bodyData(of: request))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
            Self.lock.lock()
            Self.rows = posted
            Self.lock.unlock()
            status = 201
        } else if path.hasSuffix("/rest/v1/rpc/provider_summary") {
            let summary: [[String: Any]] = Self.storedRows().map { row in
                [
                    "provider": row["provider"] ?? NSNull(),
                    "quota": row["quota"] ?? NSNull(),
                    "remaining": row["remaining"] ?? NSNull(),
                    "plan_type": row["plan_type"] ?? NSNull(),
                    "reset_time": row["reset_time"] ?? NSNull(),
                    "tiers": row["tiers"] ?? [],
                    "today_usage": 0,
                    "total_usage": 0,
                    "estimated_cost": 0,
                    "estimated_cost_today": 0,
                    "estimated_cost_30_day": 0,
                ]
            }
            body = (try? JSONSerialization.data(withJSONObject: summary)) ?? body
        } else {
            status = 404
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func bodyData(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
