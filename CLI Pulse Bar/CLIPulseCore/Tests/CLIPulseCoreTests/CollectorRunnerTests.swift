#if os(macOS)
import XCTest
@testable import CLIPulseCore

/// v1.44 W3 — pin `CollectorRunner`.
///
/// The bug being fixed is an absence, which makes it easy to "fix" without
/// fixing: `runCollectors` filtered providers down to the runnable ones before
/// executing, and returned `nil` for anything that threw, so four different
/// situations reached the UI as the same nothing. The headline test here is
/// therefore not about any single classification — it is that a pass over N
/// configs yields N entries.
private func stubUsage(
    quota: Int?, remaining: Int?, today: Int = 0, week: Int = 0, tiers: [TierDTO] = []
) -> ProviderUsage {
    ProviderUsage(
        provider: "Stub", today_usage: today, week_usage: week,
        estimated_cost_today: 0, estimated_cost_week: 0,
        cost_status_today: "Estimated", cost_status_week: "Estimated",
        quota: quota, remaining: remaining, tiers: tiers,
        // Deliberately non-empty: `status_text` is ALWAYS populated, even on
        // no-data paths, which is exactly why the classifier must not consult
        // it. See the note on `classifyCollectorOutcome`.
        status_text: "Quota unavailable — connect in Settings",
        trend: [], recent_sessions: [], recent_errors: []
    )
}

private func dataBearingResult() -> CollectorResult {
    CollectorResult(usage: stubUsage(quota: 1000, remaining: 200), dataKind: .quota)
}

private func emptyResult() -> CollectorResult {
    CollectorResult(usage: stubUsage(quota: nil, remaining: nil), dataKind: .quota)
}

/// A collector that reports whatever readiness the test asks for and then
/// returns/throws whatever the test asks for.
private struct StubCollector: ProviderCollector {
    let kind: ProviderKind
    var available: Bool = true
    var readinessOverride: CollectorReadiness?
    var outcome: Result<CollectorResult, Error>?

    func isAvailable(config: ProviderConfig) -> Bool { available }

    func readiness(config: ProviderConfig) -> CollectorReadiness {
        readinessOverride ?? (available ? .ready : .notReady(.unknown))
    }

    func collect(config: ProviderConfig) async throws -> CollectorResult {
        try (outcome ?? .success(dataBearingResult())).get()
    }
}

final class CollectorRunnerTests: XCTestCase {

    // MARK: - The headline property

    /// Every configured provider gets an entry, whatever happened to it.
    ///
    /// This is the whole feature. Before W3 the pre-execution filter dropped
    /// the disabled / unsupported / not-ready providers, so the UI had nothing
    /// to render for them and the user could not tell "I turned this off" from
    /// "this is broken". A `run` that returned only the two data-bearing
    /// entries would satisfy every other test in this file.
    func testEveryConfiguredProviderIsAccountedFor() async {
        let configs = [
            ProviderConfig(kind: .codex, isEnabled: true),
            ProviderConfig(kind: .claude, isEnabled: false),        // disabled
            ProviderConfig(kind: .gemini, isEnabled: true),         // no collector
            ProviderConfig(kind: .cursor, isEnabled: true)           // not ready
        ]

        let runs = await CollectorRunner.run(
            configs: configs,
            maxConcurrent: 4,
            execute: { _, collector in
                do {
                    return .success(try await collector.collect(config: configs[0]))
                } catch {
                    return .failure(error)
                }
            }
        )

        XCTAssertEqual(
            Set(runs.map(\.kind)), Set(configs.map(\.kind)),
            "a pass over N configs must yield N entries — dropping the non-runnable ones is the bug"
        )
    }

    // MARK: - preflight

    func testDisabledProviderIsReportedAsDisabledNotAsMissing() {
        let outcome = CollectorRunner.preflight(
            config: ProviderConfig(kind: .codex, isEnabled: false),
            collector: StubCollector(kind: .codex)
        )
        XCTAssertEqual(outcome, .disabled)
    }

    func testProviderWithNoCollectorIsUnsupported() {
        let outcome = CollectorRunner.preflight(
            config: ProviderConfig(kind: .codex, isEnabled: true),
            collector: nil
        )
        XCTAssertEqual(outcome, .unsupported,
                       "no collector implemented is not the same as one that failed")
    }

    func testNotReadyCarriesTheCollectorsOwnReason() {
        let outcome = CollectorRunner.preflight(
            config: ProviderConfig(kind: .codex, isEnabled: true),
            collector: StubCollector(
                kind: .codex, available: false,
                readinessOverride: .notReady(.missingCredentials)
            )
        )
        XCTAssertEqual(outcome, .notReady(.missingCredentials))
    }

    /// A collector that hasn't been taught to explain itself must say so rather
    /// than have a reason invented for it. Several collectors return false from
    /// `isAvailable` because the TOOL is absent, not because a key is missing —
    /// defaulting to `.missingCredentials` would send those users hunting for
    /// an API key that was never the problem.
    func testUnexplainedUnavailabilityStaysUnknown() {
        let outcome = CollectorRunner.preflight(
            config: ProviderConfig(kind: .codex, isEnabled: true),
            collector: StubCollector(kind: .codex, available: false)
        )
        XCTAssertEqual(outcome, .notReady(.unknown))
    }

    func testReadyCollectorIsNotPreflightedAway() {
        XCTAssertNil(
            CollectorRunner.preflight(
                config: ProviderConfig(kind: .codex, isEnabled: true),
                collector: StubCollector(kind: .codex, available: true)
            ),
            "nil means execute — a ready collector must not be short-circuited"
        )
    }

    // MARK: - classify

    /// The case that used to be invisible. A collector can return successfully
    /// and carry nothing usable; rendered through `quota ?? 100, remaining ?? 100`
    /// that becomes a healthy-looking "100% remaining" tile.
    func testSuccessfulRunWithNoNumbersIsEmptyNotSuccess() {
        XCTAssertEqual(CollectorRunner.classify(emptyResult()), .ranButEmpty)
    }

    func testResultWithNumbersIsProducedData() {
        XCTAssertEqual(CollectorRunner.classify(dataBearingResult()), .producedData)
    }

    /// Any one signal is enough — a provider with no quota model still counts
    /// as producing data if it reported usage.
    func testUsageAloneCountsAsData() {
        let result = CollectorResult(
            usage: stubUsage(quota: nil, remaining: nil, today: 42), dataKind: .statusOnly
        )
        XCTAssertEqual(CollectorRunner.classify(result), .producedData)
    }

    /// THE AUDIT FINDING. A `.statusOnly` or `.credits` collector reports its
    /// payload in `status_text` and hardcodes the counters to zero/nil on its
    /// SUCCESS path — Groq returns "12.5 req/min · 4300 tok/min" with
    /// `today_usage: 0, quota: nil, tiers: []`, OpenRouter returns
    /// "$12.34 / $50.00" the same way.
    ///
    /// Running those five numeric fields through the counter predicate called
    /// 26 healthy collectors empty, which put a permanent orange
    /// "No data returned" warning directly beneath the live numbers they had
    /// just fetched — and, because `producedValue` needs a `.producedData`,
    /// meant a user whose providers are all credits/status-only never got W5,
    /// while every telemetry report logged them "empty".
    func testStatusOnlyAndCreditsCollectorsAreNotCalledEmpty() {
        let statusOnly = CollectorResult(
            usage: stubUsage(quota: nil, remaining: nil), dataKind: .statusOnly
        )
        XCTAssertEqual(
            CollectorRunner.classify(statusOnly), .producedData,
            "a status-only collector that returned successfully HAS produced its kind of value"
        )

        let credits = CollectorResult(
            usage: stubUsage(quota: nil, remaining: nil), dataKind: .credits
        )
        XCTAssertEqual(
            CollectorRunner.classify(credits), .producedData,
            "a balance is data — it just isn't a counter"
        )
    }

    /// …and the counter predicate must still apply to `.quota`, or the fix
    /// above would simply declare every collector healthy and re-hide the
    /// silent-zero case this release exists to expose.
    func testQuotaCollectorsAreStillHeldToTheCounterPredicate() {
        XCTAssertEqual(
            CollectorRunner.classify(
                CollectorResult(usage: stubUsage(quota: nil, remaining: nil), dataKind: .quota)
            ),
            .ranButEmpty,
            "a quota collector with no numbers is exactly the silent-zero case"
        )
    }

    // MARK: - failure categories

    func testAuthFailuresAreDistinguishedFromGenericHTTP() {
        XCTAssertEqual(CollectorFailureCategory.categorize(CollectorError.notSignedIn("x")), .auth)
        XCTAssertEqual(
            CollectorFailureCategory.categorize(CollectorError.httpError(status: 401, provider: "x")), .auth,
            "401 is 'sign in again', not a generic upstream error"
        )
        XCTAssertEqual(
            CollectorFailureCategory.categorize(CollectorError.httpError(status: 403, provider: "x")), .auth
        )
        XCTAssertEqual(
            CollectorFailureCategory.categorize(CollectorError.httpError(status: 500, provider: "x")), .http,
            "a 500 is not the user's credential problem"
        )
    }

    /// A parse failure is ours to fix, not the user's — it must never land in a
    /// bucket that produces a "check your credentials" instruction.
    func testParseFailureIsItsOwnCategory() {
        XCTAssertEqual(CollectorFailureCategory.categorize(CollectorError.parseFailed("x")), .parse)
    }

    func testNetworkAndPermissionAreRecognisedFromNSError() {
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        XCTAssertEqual(CollectorFailureCategory.categorize(offline), .network)

        let denied = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        XCTAssertEqual(CollectorFailureCategory.categorize(denied), .permission,
                       "sandbox denial has a one-tap fix and must not be buried in .other")
    }

    /// An unrecognised error must not be dressed up as something specific.
    func testUnknownErrorIsOtherRatherThanAGuess() {
        struct Mystery: Error {}
        XCTAssertEqual(CollectorFailureCategory.categorize(Mystery()), .other)
    }

    // MARK: - readiness probe

    func testConfigDirectoryPresentMeansSignedOutNotMissing() {
        XCTAssertEqual(
            CollectorReadinessProbe.fromConfigDirectory(
                path: "/x/.codex", isSandboxed: false, directoryExists: { _ in true }
            ),
            .notReady(.missingCredentials),
            "the tool is here — the fix is `codex login`, not a reinstall"
        )
    }

    func testUnsandboxedBuildMayReportTheToolMissing() {
        XCTAssertEqual(
            CollectorReadinessProbe.fromConfigDirectory(
                path: "/x/.codex", isSandboxed: false, directoryExists: { _ in false }
            ),
            .notReady(.notInstalled)
        )
    }

    /// The trap this probe exists to avoid. Under MAS with no folder access, a
    /// negative existence check is ambiguous — absent and unreadable are the
    /// same answer — so claiming `notInstalled` would tell every App Store user
    /// who hasn't granted access yet to go reinstall a CLI they already have.
    /// Sandboxed builds are not allowed to make that claim.
    func testSandboxedBuildNeverClaimsTheToolIsMissing() {
        let readiness = CollectorReadinessProbe.fromConfigDirectory(
            path: "/x/.codex", isSandboxed: true, directoryExists: { _ in false }
        )
        XCTAssertEqual(readiness, .notReady(.unknown))
        XCTAssertNotEqual(
            readiness, .notReady(.notInstalled),
            "a blind sandboxed probe must not be dressed up as a definite answer"
        )
    }

    // MARK: - actionability & telemetry

    /// Drives whether a row shows a call to action. `unsupported` is quiet on
    /// purpose: there is nothing a user can do about a provider we never wrote
    /// a collector for, so prompting them would be noise they cannot clear.
    func testOnlyFixableOutcomesAreActionable() {
        XCTAssertFalse(CollectorOutcome.disabled.isActionable)
        XCTAssertFalse(CollectorOutcome.unsupported.isActionable)
        XCTAssertFalse(CollectorOutcome.producedData.isActionable)
        XCTAssertTrue(CollectorOutcome.ranButEmpty.isActionable)
        XCTAssertTrue(CollectorOutcome.notReady(.missingCredentials).isActionable)
        XCTAssertTrue(CollectorOutcome.failed(.auth).isActionable)
    }

    /// Telemetry tokens are aggregated across devices and compared over time,
    /// so renaming one silently splits history. Pinned literally.
    func testTelemetryTokensAreStable() {
        XCTAssertEqual(CollectorOutcome.disabled.telemetryToken, "disabled")
        XCTAssertEqual(CollectorOutcome.unsupported.telemetryToken, "unsupported")
        XCTAssertEqual(CollectorOutcome.producedData.telemetryToken, "ok")
        XCTAssertEqual(CollectorOutcome.ranButEmpty.telemetryToken, "empty")
        XCTAssertEqual(
            CollectorOutcome.notReady(.missingCredentials).telemetryToken, "not_ready_missing_credentials"
        )
        XCTAssertEqual(CollectorOutcome.failed(.parse).telemetryToken, "failed_parse")
    }

    // MARK: - telemetry throttle

    /// A refresh tick is 60–120s. Reporting unconditionally would be well over
    /// a thousand writes per device per day to answer a question that changes
    /// maybe twice a week.
    func testUnchangedStatusIsNotReReportedEveryTick() {
        let map = ["Codex": "ok"]
        XCTAssertFalse(
            CollectorRunner.shouldReportTelemetry(
                current: map, lastReported: map,
                lastReportedAt: Date(timeIntervalSince1970: 1000),
                now: Date(timeIntervalSince1970: 1060)      // one tick later
            ),
            "nothing changed a minute ago — this is the 1400-writes-a-day path"
        )
    }

    /// …but a change must go out immediately. A provider that just broke is
    /// the entire reason this column exists.
    func testAChangedStatusIsReportedImmediately() {
        XCTAssertTrue(
            CollectorRunner.shouldReportTelemetry(
                current: ["Codex": "failed_auth"], lastReported: ["Codex": "ok"],
                lastReportedAt: Date(timeIntervalSince1970: 1000),
                now: Date(timeIntervalSince1970: 1001)
            )
        )
    }

    /// A steadily-healthy device must still check in, or "no rows" becomes
    /// ambiguous between "fine" and "stopped reporting" — the exact ambiguity
    /// that made the v0.71 column useless in the first place.
    func testHealthyDeviceStillReportsOnceAnHour() {
        let map = ["Codex": "ok"]
        XCTAssertTrue(
            CollectorRunner.shouldReportTelemetry(
                current: map, lastReported: map,
                lastReportedAt: Date(timeIntervalSince1970: 1000),
                now: Date(timeIntervalSince1970: 1000 + 3600)
            )
        )
    }

    func testFirstEverReportAlwaysGoesOut() {
        XCTAssertTrue(
            CollectorRunner.shouldReportTelemetry(
                current: ["Codex": "ok"], lastReported: nil, lastReportedAt: nil, now: Date()
            )
        )
    }

    /// Never upload an empty map — it would overwrite a real prior reading
    /// with nothing and look like a device that lost all its providers.
    func testEmptyMapIsNeverUploaded() {
        XCTAssertFalse(
            CollectorRunner.shouldReportTelemetry(
                current: [:], lastReported: nil, lastReportedAt: nil, now: Date()
            )
        )
    }

    /// The throttle cache must be per-device, mirroring `appVersionReportKey`.
    ///
    /// With a global key, account A's cached map suppresses the FIRST report
    /// from a newly-paired device B whenever their maps happen to match —
    /// leaving B's backend row null for up to an hour, which is
    /// indistinguishable from the silence this feature exists to explain.
    func testThrottleCacheIsScopedPerDevice() {
        XCTAssertNotEqual(
            AppState.collectorStatusKey(deviceId: "device-a"),
            AppState.collectorStatusKey(deviceId: "device-b"),
            "a global cache key lets one device's history silence another's first report"
        )
        XCTAssertNotEqual(
            AppState.collectorStatusAtKey(deviceId: "device-a"),
            AppState.collectorStatusAtKey(deviceId: "device-b")
        )
        // Map and timestamp must not collide with each other either.
        XCTAssertNotEqual(
            AppState.collectorStatusKey(deviceId: "d"),
            AppState.collectorStatusAtKey(deviceId: "d")
        )
    }

    /// `ok` and `empty` must match what the daemon already reports under
    /// migrate_v0.71, or the two reporters would split the same column.
    func testTokensMatchTheDaemonsExistingVocabulary() {
        XCTAssertEqual(
            CollectorOutcome.producedData.telemetryToken,
            HelperAPIClient.classifyCollectorOutcome(
                tiersCount: 1, quota: 10, remaining: 5, todayUsage: 0, weekUsage: 0
            )
        )
        XCTAssertEqual(
            CollectorOutcome.ranButEmpty.telemetryToken,
            HelperAPIClient.classifyCollectorOutcome(
                tiersCount: 0, quota: nil, remaining: nil, todayUsage: 0, weekUsage: 0
            )
        )
    }
}
#endif
