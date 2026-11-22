#if os(macOS)
import XCTest
@testable import CLIPulseCore

/// Claude meters by plan: an Ultra account has no 5-hour window, an
/// all-models week and a week scoped to one model ("Fable"), and its token
/// still names the plan Max 20x. These pin how CLI Pulse reads and shows that.
/// Numbers are made up; the shape is the one `/api/oauth/usage` and
/// `/api/oauth/profile` returned on 2026-11-22.
final class ClaudePlanWindowsTests: XCTestCase {

    private let weekReset = "2026-11-26T09:30:00.123456+00:00"

    private func json(_ text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }

    /// The Ultra-shaped usage body: no `five_hour`, a `seven_day`, and both limits.
    private var ultraBody: String {
        """
        {
          "five_hour": null,
          "seven_day": {"utilization": 40.0, "resets_at": "\(weekReset)"},
          "seven_day_sonnet": null, "seven_day_opus": null,
          "limits": [
            {"kind": "weekly_all", "group": "weekly", "percent": 40, "severity": "normal",
             "resets_at": "\(weekReset)", "scope": null, "is_active": false},
            {"kind": "weekly_scoped", "group": "weekly", "percent": 55, "severity": "normal",
             "resets_at": "\(weekReset)",
             "scope": {"model": {"id": "model-x", "display_name": "Fable"}}, "is_active": true}
          ]
        }
        """
    }

    // MARK: - limits[]

    func testScopedWeeklyIsReadFromLimits() {
        let scoped = ClaudeUsageLimits.scopedWeekly(json(ultraBody))
        XCTAssertEqual(scoped, [ClaudeUsageLimits.Scoped(modelName: "Fable", used: 55, resetsAt: weekReset)])
        XCTAssertEqual(ClaudeUsageLimits.weeklyAll(json(ultraBody))?.used, 40)
    }

    func testScopedWeeklySkipsWhatIsNotAModelWeek() {
        let body = json("""
        {"limits": [
          {"kind": "weekly_scoped", "group": "weekly", "percent": 10,
           "scope": {"model": {"id": "all-models", "display_name": "All models"}}},
          {"kind": "weekly_scoped", "group": "weekly", "percent": true,
           "scope": {"model": {"id": "a", "display_name": "Alpha"}}},
          {"kind": "weekly_scoped", "group": "weekly", "percent": 20,
           "scope": {"model": {"id": "b", "display_name": "  "}}},
          {"kind": "weekly_scoped", "group": "daily", "percent": 30,
           "scope": {"model": {"id": "c", "display_name": "Gamma"}}},
          {"kind": "weekly_scoped", "group": "weekly", "percent": "40",
           "scope": {"model": {"id": "d", "display_name": "Delta"}}},
          {"kind": "weekly_scoped", "group": "weekly", "percent": 140,
           "scope": {"model": {"id": "e", "display_name": "Epsilon"}}},
          {"kind": "weekly_scoped", "group": "weekly", "percent": 50,
           "scope": {"model": {"id": "e", "display_name": "Epsilon again"}}},
          "not an object"
        ]}
        """)
        XCTAssertEqual(ClaudeUsageLimits.scopedWeekly(body),
                       [ClaudeUsageLimits.Scoped(modelName: "Epsilon", used: 100, resetsAt: nil)],
                       "all-models, a boolean, a blank name, another group, a string and a repeated id are skipped; >100 clamps")
        XCTAssertTrue(ClaudeUsageLimits.scopedWeekly(json(#"{"limits": null}"#)).isEmpty)
        XCTAssertNil(ClaudeUsageLimits.weeklyAll(json(#"{"limits": []}"#)))
    }

    func testHugePercentsClampInsteadOfTrapping() {
        let body = json(#"{"limits": [{"kind": "weekly_scoped", "group": "weekly", "percent": 1e20, "scope": {"model": {"id": "a", "display_name": "A"}}}, {"kind": "weekly_scoped", "group": "weekly", "percent": -1e20, "scope": {"model": {"id": "b", "display_name": "B"}}}, {"kind": "weekly_all", "group": "weekly", "percent": 1e300}]}"#)
        XCTAssertEqual(ClaudeUsageLimits.scopedWeekly(body).map(\.used), [100, 0])
        XCTAssertEqual(ClaudeUsageLimits.weeklyAll(body)?.used, 100)
    }

    func testScopedWeeklyIsCapped() {
        let entries = (0..<9).map { i in
            #"{"kind": "weekly_scoped", "group": "weekly", "percent": \#(i), "scope": {"model": {"id": "m\#(i)", "display_name": "M\#(i)"}}}"#
        }.joined(separator: ",")
        XCTAssertEqual(ClaudeUsageLimits.scopedWeekly(json(#"{"limits": [\#(entries)]}"#)).count,
                       ClaudeUsageLimits.maxScoped)
    }

    func testOAuthSnapshotCarriesTheScopedWeekAndTheWeekFromLimits() throws {
        let usage = try ClaudeOAuthStrategy.parseUsage(Data(ultraBody.utf8))
        let snapshot = ClaudeOAuthStrategy.snapshot(from: usage, rateLimitTier: "default_claude_max_20x",
                                                    planDisplayLabel: "Ultra plan", sourceLabel: "oauth")
        XCTAssertNil(snapshot.sessionUsed)
        XCTAssertEqual(snapshot.weeklyUsed, 40)
        XCTAssertEqual(snapshot.scopedWeekly.map(\.modelName), ["Fable"])
        XCTAssertEqual(snapshot.planDisplayLabel, "Ultra plan")

        // A body that leaves `seven_day` out still has its week.
        let noSevenDay = try ClaudeOAuthStrategy.parseUsage(Data("""
        {"limits": [{"kind": "weekly_all", "group": "weekly", "percent": 33, "resets_at": "\(weekReset)"}]}
        """.utf8))
        let fromLimits = ClaudeOAuthStrategy.snapshot(from: noSevenDay, rateLimitTier: nil, sourceLabel: "oauth")
        XCTAssertEqual(fromLimits.weeklyUsed, 33)
        XCTAssertEqual(fromLimits.weeklyReset, weekReset)
    }

    func testWebUsageReadsTheSameLimits() {
        let onlyLimits = ClaudeWebStrategy.parseUsage(json("""
        {"limits": [
          {"kind": "weekly_all", "group": "weekly", "percent": 33, "resets_at": "\(weekReset)"},
          {"kind": "weekly_scoped", "group": "weekly", "percent": 44,
           "scope": {"model": {"id": "x", "display_name": "Fable"}}}
        ]}
        """))
        XCTAssertTrue(onlyLimits.hasRecognizedQuota)
        XCTAssertEqual(onlyLimits.weeklyPercent, 33)
        XCTAssertEqual(onlyLimits.weeklyResetISO, weekReset)
        XCTAssertEqual(onlyLimits.scopedWeekly.map(\.used), [44])
    }

    // MARK: - The card

    func testUltraCardShowsTheWeekAndTheModelWeekAndNamesThePlan() throws {
        let usage = try ClaudeOAuthStrategy.parseUsage(Data(ultraBody.utf8))
        let result = ClaudeResultBuilder.build(from: ClaudeOAuthStrategy.snapshot(
            from: usage, rateLimitTier: "default_claude_max_20x", planDisplayLabel: "Ultra plan", sourceLabel: "oauth"))
        XCTAssertEqual(result.usage.plan_type, "Ultra")
        XCTAssertEqual(result.usage.tiers.map(\.name), ["Weekly", "Fable only"])
        let fable = try XCTUnwrap(result.usage.tiers.last)
        XCTAssertEqual(fable.remaining, 45)
        XCTAssertEqual(fable.reset_time, weekReset)
        XCTAssertEqual(fable.windowMinutes, 7 * 24 * 60)
        XCTAssertEqual(fable.role, .modelSpecific)
        // Headlined by the all-models week, as Claude's own usage page is.
        XCTAssertEqual(result.usage.remaining, 60)
        XCTAssertEqual(result.usage.status_text, "40% used")
        XCTAssertEqual(result.usage.reset_time, weekReset)
    }

    /// A reply with only model weeks must not read "100% left".
    func testOnlyModelWeeksHeadlineTheMostUsedOne() {
        let result = ClaudeResultBuilder.build(from: ClaudeSnapshot(sourceLabel: "oauth", scopedWeekly: [
            .init(modelName: "Fable", used: 30, resetsAt: weekReset),
            .init(modelName: "Other", used: 70, resetsAt: nil),
        ]))
        XCTAssertEqual(result.usage.quota, 100)
        XCTAssertEqual(result.usage.remaining, 30)
        XCTAssertEqual(result.usage.status_text, "70% used")
        XCTAssertEqual(result.usage.tiers.map(\.name), ["Fable only", "Other only"])
    }

    func testAModelWithItsOwnFlatRowIsNotDrawnTwice() throws {
        let sonnet = ClaudeResultBuilder.build(from: ClaudeSnapshot(
            weeklyUsed: 10, sonnetUsed: 20, weeklyReset: "2026-11-27T12:00:00Z", sourceLabel: "oauth",
            scopedWeekly: [.init(modelName: "Sonnet", used: 25, resetsAt: "2026-11-25T08:00:00Z")]))
        XCTAssertEqual(sonnet.usage.tiers.map(\.name), ["Weekly", "Sonnet only"])
        // One row, carrying the scoped entry's own reset rather than the week's.
        let row = try XCTUnwrap(sonnet.usage.tiers.last)
        XCTAssertEqual(row.remaining, 75)
        XCTAssertEqual(row.reset_time, "2026-11-25T08:00:00Z")
        XCTAssertEqual(row.windowMinutes, 7 * 24 * 60)
        XCTAssertEqual(row.role, .modelSpecific)

        // The flat Opus number is named for Opus now, so a scoped Sonnet week
        // beside it is a second, different row.
        let opus = ClaudeResultBuilder.build(from: ClaudeSnapshot(
            weeklyUsed: 10, opusUsed: 30, sourceLabel: "oauth",
            scopedWeekly: [.init(modelName: "Sonnet", used: 20, resetsAt: nil),
                           .init(modelName: "opus", used: 30, resetsAt: nil)]))
        XCTAssertEqual(opus.usage.tiers.map(\.name), ["Weekly", "Opus only", "Sonnet only"])
    }

    /// The CLI's "Current week (Sonnet only)" is Sonnet's row, not Opus's.
    func testCLISonnetWeekIsNamedForSonnet() throws {
        let sonnet = try ClaudeCLIPTYStrategy.parseCLIOutput("""
        Current session
        42% left
        Current week (all models)
        75% left
        Current week (Sonnet only)
        60% left
        """)
        XCTAssertEqual(sonnet.sonnetPercentLeft, 60)
        XCTAssertNil(sonnet.opusPercentLeft)
        let result = ClaudeResultBuilder.build(from: ClaudeSnapshot(
            sessionUsed: 58, weeklyUsed: 25, sonnetUsed: sonnet.sonnetPercentLeft.map { 100 - $0 }, sourceLabel: "cli-pty"))
        XCTAssertEqual(result.usage.tiers.map(\.name), ["5h Window", "Weekly", "Sonnet only"])

        let opus = try ClaudeCLIPTYStrategy.parseCLIOutput("Current week (all models)\n75% left\nCurrent week (Opus)\n60% left")
        XCTAssertEqual(opus.opusPercentLeft, 60)
        XCTAssertNil(opus.sonnetPercentLeft)
    }

    func testFlatRowsOtherwiseUnchanged() {
        let result = ClaudeResultBuilder.build(from: ClaudeSnapshot(
            sessionUsed: 45, weeklyUsed: 60, opusUsed: 75, sonnetUsed: 55,
            sessionReset: "2026-04-02T22:00:00Z", weeklyReset: "2026-04-09T00:00:00Z",
            rateLimitTier: "pro", sourceLabel: "oauth"))
        XCTAssertEqual(result.usage.tiers.map(\.name), ["5h Window", "Weekly", "Sonnet only"])
        XCTAssertEqual(result.usage.reset_time, "2026-04-02T22:00:00Z")
        XCTAssertEqual(result.usage.plan_type, "Pro")
    }

    // MARK: - Plan name

    func testPlanTypeComesFromTheLabelWhenThereIsOne() {
        let cases: [(tier: String?, label: String?, expected: String)] = [
            ("default_claude_max_20x", nil, "Max 20x"),
            ("default_claude_max_20x", "Ultra plan", "Ultra"),
            ("default_claude_max_20x", "Max plan", "Max 20x"),
            ("default_claude_max_5x", " max PLAN ", "Max 5x"),
            (nil, "Max plan", "Max 5x"),
            ("default_claude_max_20x", "Pro plan", "Pro"),
            (nil, "Team plan", "Team"),
            (nil, "Enterprise", "Enterprise"),
            (nil, "Studio plan", "Studio"),
            ("default_claude_max_20x", "   ", "Max 20x"),
            ("default_claude_max_20x", String(repeating: "x", count: 41), "Max 20x"),
            (nil, nil, "Unknown"),
            ("claude_pro", nil, "Pro"),
        ]
        for c in cases {
            XCTAssertEqual(ClaudePlanType.resolve(rateLimitTier: c.tier, planDisplayLabel: c.label), c.expected,
                           "tier \(c.tier ?? "nil"), label \(c.label ?? "nil")")
        }
    }

    func testProfileGivesOnlyTheLabelAndTheTier() {
        let body = Data("""
        {"account": {"uuid": "u", "email": "someone@example.com", "has_claude_max": true},
         "organization": {"uuid": "o", "name": "Org", "organization_type": "claude_max",
                          "rate_limit_tier": "default_claude_max_20x",
                          "plan_display_name": "Claude Ultra", "plan_display_label": "Ultra plan"}}
        """.utf8)
        XCTAssertEqual(ClaudeOAuthStrategy.parseProfile(body),
                       .init(planDisplayLabel: "Ultra plan", rateLimitTier: "default_claude_max_20x"))
        XCTAssertEqual(ClaudeOAuthStrategy.parseProfile(Data(#"{"organization": {"plan_display_label": " ", "plan_display_name": "Claude Ultra"}}"#.utf8)),
                       .init(planDisplayLabel: "Claude Ultra", rateLimitTier: nil))
        XCTAssertNil(ClaudeOAuthStrategy.parseProfile(Data(#"{"account": {}}"#.utf8)))
        XCTAssertNil(ClaudeOAuthStrategy.parseProfile(Data("not json".utf8)))
        // A Max plan's label has no multiplier; the profile's tier supplies it.
        XCTAssertEqual(ClaudePlanType.resolve(rateLimitTier: "default_claude_max_20x", planDisplayLabel: "Max plan"), "Max 20x")
    }

    func testProfileRequestCarriesTheTokenAndNothingElse() {
        let request = ClaudeOAuthStrategy.profileRequest(token: "t")
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/api/oauth/profile")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer t")
        XCTAssertNil(request.httpBody)
    }

    func testProfileIsReadInTheBackgroundAtMostEverySixHours() async {
        final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_000_000) }
        let clock = Clock()
        let gate = Gate()
        let cache = ClaudePlanLabelCache(now: { clock.now })
        let ultra = ClaudePlanLabelCache.Profile(planDisplayLabel: "Ultra plan", rateLimitTier: "t")
        let max = ClaudePlanLabelCache.Profile(planDisplayLabel: "Max plan", rateLimitTier: "t")
        func ask(_ outcome: ClaudePlanLabelCache.Outcome, fp: String = "a") async -> String? {
            await cache.profile(forFingerprint: fp, firstReadWait: 0) {
                await gate.count()
                return outcome
            }?.planDisplayLabel
        }

        // Nothing known yet: the answer is empty; the read runs behind it.
        let first = await ask(.profile(ultra))
        XCTAssertNil(first)
        await cache.settle()
        let calls1 = await gate.calls
        XCTAssertEqual(calls1, 1)
        let known = await ask(.profile(max))
        XCTAssertEqual(known, "Ultra plan")
        clock.now += 5 * 3600
        let cached = await ask(.profile(max))
        XCTAssertEqual(cached, "Ultra plan")
        await cache.settle()
        let calls2 = await gate.calls
        XCTAssertEqual(calls2, 1, "fresh for 6 hours")

        clock.now += 2 * 3600
        let stale = await ask(.failed)
        XCTAssertEqual(stale, "Ultra plan", "a stale answer is still given while the read runs")
        await cache.settle()
        let afterFailure = await ask(.profile(max))
        XCTAssertEqual(afterFailure, "Ultra plan", "a failed read keeps what was known")
        await cache.settle()
        let calls3 = await gate.calls
        XCTAssertEqual(calls3, 2, "retried only 30 minutes after a failure")
        clock.now += 31 * 60
        _ = await ask(.profile(max))
        await cache.settle()
        let retried = await ask(.profile(ultra))
        XCTAssertEqual(retried, "Max plan")

        let otherToken = await ask(.profile(ultra), fp: "b")
        XCTAssertNil(otherToken, "another token has its own entry")
    }

    /// A profile that has not been confirmed for a day is no longer given
    /// out, however many reads have failed since.
    func testAnUnconfirmedProfileAgesOut() async {
        final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_000_000) }
        let clock = Clock()
        let cache = ClaudePlanLabelCache(now: { clock.now })
        let ultra = ClaudePlanLabelCache.Profile(planDisplayLabel: "Ultra plan", rateLimitTier: nil)
        _ = await cache.profile(forFingerprint: "a", firstReadWait: 0) { .profile(ultra) }
        await cache.settle()
        for _ in 0..<5 {
            clock.now += 6 * 3600
            _ = await cache.profile(forFingerprint: "a", firstReadWait: 0) { .failed }
            await cache.settle()
        }
        let aged = await cache.profile(forFingerprint: "a", firstReadWait: 0) { .failed }
        XCTAssertNil(aged)
    }

    /// Two refreshes at once start one read; a read that has not answered
    /// holds up only the call that started it, and only for the first-read
    /// wait. The gate stays closed throughout, so each call returning at all
    /// is the proof; the expectations are hang watchdogs, not timings.
    func testOneReadAtATimeAndAHungReadBlocksNothing() async {
        let gate = Gate()
        let cache = ClaudePlanLabelCache()
        let fetch: @Sendable () async -> ClaudePlanLabelCache.Outcome = {
            await gate.enterAndWait()
            return .profile(.init(planDisplayLabel: "Ultra plan", rateLimitTier: nil))
        }
        // The starting call waits its (short) first-read wait, then answers.
        let a = await cache.profile(forFingerprint: "a", firstReadWait: 0.05, fetch: fetch)
        XCTAssertNil(a)
        // A later call does not wait again, however long its allowance.
        let returned = expectation(description: "a later call answers without waiting")
        Task {
            let b = await cache.profile(forFingerprint: "a", firstReadWait: 3600, fetch: fetch)
            XCTAssertNil(b)
            returned.fulfill()
        }
        await fulfillment(of: [returned], timeout: 10)
        await gate.waitUntilEntered()
        let calls = await gate.calls
        XCTAssertEqual(calls, 1)
        await gate.release()
        await cache.settle()
        let c = await cache.profile(forFingerprint: "a", firstReadWait: 0, fetch: fetch)
        XCTAssertEqual(c?.planDisplayLabel, "Ultra plan")
        let callsAfter = await gate.calls
        XCTAssertEqual(callsAfter, 1)
    }

    /// A quick first read is waited for, so a launch shows the right plan at once.
    func testAQuickFirstReadIsWaitedFor() async {
        let cache = ClaudePlanLabelCache()
        let profile = await cache.profile(forFingerprint: "a", firstReadWait: 5) {
            .profile(.init(planDisplayLabel: "Ultra plan", rateLimitTier: nil))
        }
        XCTAssertEqual(profile?.planDisplayLabel, "Ultra plan")
    }

    // MARK: - Files

    func testSnapshotFileKeepsTheModelWeeksAndTheLabel() throws {
        // This account's own week, three days out and not on a Friday-at-14:00Z.
        var reset = Date().addingTimeInterval(3 * 24 * 3600)
        reset = Date(timeIntervalSince1970: (reset.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
        if Calendar(identifier: .gregorian).component(.weekday, from: reset) == 6 { reset += 24 * 3600 }
        let ownReset = sharedISO8601Formatter.string(from: reset)
        let dict = ClaudeHelperContract.snapshotDictionary(
            ClaudeSnapshot(weeklyUsed: 40, weeklyReset: ownReset, sourceLabel: "oauth",
                           scopedWeekly: [.init(modelName: "Fable", used: 55, resetsAt: weekReset),
                                          .init(modelName: "Other", used: 5, resetsAt: nil)],
                           planDisplayLabel: "Ultra plan"),
            fetchedAt: Date())
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("claude_snapshot.json")
        try JSONSerialization.data(withJSONObject: dict).write(to: path)
        let read = try XCTUnwrap(ClaudeHelperContract.readSnapshot(
            maxAge: ClaudeHelperContract.cacheSnapshotAge, sourceLabel: "cache", candidatePaths: [path.path]))
        XCTAssertEqual(read.scopedWeekly, [.init(modelName: "Fable", used: 55, resetsAt: weekReset),
                                           .init(modelName: "Other", used: 5, resetsAt: nil)])
        XCTAssertEqual(read.planDisplayLabel, "Ultra plan")
        XCTAssertEqual(read.weeklyReset, ownReset, "the account's own week is not moved to Friday")

        XCTAssertTrue(ClaudeHelperContract.decodeScopedWeekly([:]).isEmpty, "an older file has none")
        XCTAssertEqual(ClaudeHelperContract.decodeScopedWeekly(["scoped_weekly": [
            ["model": "", "used": 1], ["model": "A", "used": 101], ["model": "B", "used": "2"],
            ["model": "C", "used": 3, "reset": NSNull()],
        ]]), [.init(modelName: "C", used: 3, resetsAt: nil)])
    }

    /// The account-file merge fills metadata and passes the new fields through.
    func testAccountInfoMergeKeepsTheWeeksAndTheLabel() {
        let merged = ClaudeSnapshot(weeklyUsed: 40, sourceLabel: "oauth",
                                    scopedWeekly: [.init(modelName: "Fable", used: 55, resetsAt: nil)],
                                    planDisplayLabel: "Ultra plan")
            .mergingAccountInfo(ClaudeAccountInfo(accountEmail: "a@example.com", rateLimitTier: "default_claude_max_20x"))
        XCTAssertEqual(merged.scopedWeekly.map(\.modelName), ["Fable"])
        XCTAssertEqual(merged.planDisplayLabel, "Ultra plan")
        XCTAssertEqual(ClaudeResultBuilder.build(from: merged).usage.plan_type, "Ultra")
    }

    // MARK: - Pace, widget

    private func claudeUsage(reset: String?, tiers: [TierDTO]) -> ProviderUsage {
        ProviderUsage(
            provider: "Claude", today_usage: 0, week_usage: 0,
            estimated_cost_today: 0, estimated_cost_week: 0,
            cost_status_today: "ok", cost_status_week: "ok",
            quota: 100, remaining: 60, reset_time: reset, tiers: tiers, status_text: "",
            trend: [], recent_sessions: [], recent_errors: [])
    }

    func testWeeklyHeadlineIsPacedAsAWeek() {
        let now = Date()
        let reset = sharedISO8601Formatter.string(from: now.addingTimeInterval(3 * 24 * 3600))
        let weekly = claudeUsage(reset: reset, tiers: [
            TierDTO(name: "Weekly", quota: 100, remaining: 60, reset_time: reset),
            TierDTO(name: "Fable only", quota: 100, remaining: 45, reset_time: reset,
                    windowMinutes: 7 * 24 * 60, role: .modelSpecific),
        ])
        XCTAssertEqual(weekly.paceRateWindow(now: now)?.windowMinutes, 7 * 24 * 60)

        let session = claudeUsage(reset: reset, tiers: [
            TierDTO(name: "5h Window", quota: 100, remaining: 60, reset_time: reset),
            TierDTO(name: "Weekly", quota: 100, remaining: 60, reset_time: nil),
        ])
        XCTAssertEqual(session.paceRateWindow(now: now)?.windowMinutes, 300)
        XCTAssertEqual(claudeUsage(reset: reset, tiers: []).paceRateWindow(now: now)?.windowMinutes, 300,
                       "rows without tiers keep the 5-hour reading")

        let unmatched = claudeUsage(reset: reset, tiers: [
            TierDTO(name: "Weekly", quota: 100, remaining: 60,
                    reset_time: sharedISO8601Formatter.string(from: now.addingTimeInterval(24 * 3600))),
        ])
        XCTAssertNil(unmatched.paceRateWindow(now: now)?.windowMinutes)
    }

    func testFiveHourRowWithAMismatchedResetIsNotThePace() {
        let now = Date()
        let week = sharedISO8601Formatter.string(from: now.addingTimeInterval(3 * 24 * 3600))
        let session = sharedISO8601Formatter.string(from: now.addingTimeInterval(2 * 3600))
        let usage = claudeUsage(reset: week, tiers: [
            TierDTO(name: "5h Window", quota: 100, remaining: 90, reset_time: session),
            TierDTO(name: "Weekly", quota: 100, remaining: 60, reset_time: week),
        ])
        XCTAssertEqual(usage.paceRateWindow(now: now)?.windowMinutes, 7 * 24 * 60)
    }

    func testAModelWeekIsTheWeeklyRingWhenThereIsNoOther() {
        let usage = claudeUsage(reset: nil, tiers: [
            TierDTO(name: "5h Window", quota: 100, remaining: 90),
            TierDTO(name: "Fable only", quota: 100, remaining: 45, windowMinutes: 7 * 24 * 60, role: .modelSpecific),
            TierDTO(name: "Other only", quota: 100, remaining: 80, windowMinutes: 7 * 24 * 60, role: .modelSpecific),
        ])
        XCTAssertEqual(WatchRingMath.weeklyTier(usage)?.name, "Fable only")
        let withWeek = claudeUsage(reset: nil, tiers: usage.tiers + [TierDTO(name: "Weekly", quota: 100, remaining: 70)])
        XCTAssertEqual(WatchRingMath.weeklyTier(withWeek)?.name, "Weekly")
    }

    func testModelWeeksAloneHideTheFiveHourRow() {
        let onlyScoped = claudeUsage(reset: nil, tiers: [
            TierDTO(name: "Fable only", quota: 100, remaining: 45, windowMinutes: 7 * 24 * 60, role: .modelSpecific),
        ])
        XCTAssertEqual(WatchRingMath.hasFiveHourWindow(onlyScoped), false)
        let unknown = claudeUsage(reset: nil, tiers: [TierDTO(name: "Something", quota: 100, remaining: 45)])
        XCTAssertNil(WatchRingMath.hasFiveHourWindow(unknown))
    }

    // MARK: - Helpers

    /// Counts fetches; `enterAndWait` holds one until `release`, and
    /// `waitUntilEntered` returns once a fetch has started.
    private actor Gate {
        private(set) var calls = 0
        private var released = false
        private var holders: [CheckedContinuation<Void, Never>] = []
        private var watchers: [CheckedContinuation<Void, Never>] = []

        func count() { calls += 1 }

        func enterAndWait() async {
            calls += 1
            watchers.forEach { $0.resume() }
            watchers = []
            if released { return }
            await withCheckedContinuation { holders.append($0) }
        }

        func waitUntilEntered() async {
            if calls > 0 { return }
            await withCheckedContinuation { watchers.append($0) }
        }

        func release() {
            released = true
            holders.forEach { $0.resume() }
            holders = []
        }
    }
}
#endif
