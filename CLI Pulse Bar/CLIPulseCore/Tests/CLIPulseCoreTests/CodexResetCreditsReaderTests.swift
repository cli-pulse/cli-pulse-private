// The request assertions follow steipete/CodexBar
// Tests/CodexBarTests/CodexRateLimitResetCreditsTests.swift ("request scopes
// auth and account with bounded timeout") and the stale-credential rule
// Tests/CodexBarTests/CodexResetCreditOutcomeTests.swift ("supplemental
// inventory skips stale credentials without issuing a request", "failed
// supplemental GET clears inventory on a successful usage refresh"), taken at
// upstream commit 25bba9b7, 2026-09-28 (https://github.com/steipete/CodexBar).
// NOT verbatim: a failure here is an outcome, not a thrown error; the budget,
// the store, the remote switch and the collector wiring are CLI Pulse's and
// so are their tests.
//
// ─── MIT License (full notice required by upstream) ───────────────
//
// MIT License
//
// Copyright (c) 2026 Peter Steinberger
//
// Permission is hereby granted, free of charge, to any person
// obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without
// restriction, including without limitation the rights to use, copy,
// modify, merge, publish, distribute, sublicense, and/or sell copies
// of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
// OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
// HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
// WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
// OTHER DEALINGS IN THE SOFTWARE.
// ──────────────────────────────────────────────────────────────────

#if os(macOS)
import XCTest
@testable import CLIPulseCore

/// Reading Codex's limit reset credits: the request, what a failure becomes,
/// the 4 s budget, where the reading is kept, the remote switch, and which
/// process reads them. The quota read must never wait for, or fail because
/// of, any of it.
final class CodexResetCreditsReaderTests: XCTestCase {

    private static let now = Date(timeIntervalSince1970: 1_787_000_000)
    private static let body = Data("""
    {"credits":[{"id":"RateLimitResetCredit_x","reset_type":"codex_rate_limits","status":"available",
      "granted_at":"2026-08-01T00:00:00Z","expires_at":"2026-09-01T00:00:00Z"}],"available_count":1}
    """.utf8)

    private static func jwt(expiringAt date: Date) -> String {
        func segment(_ object: [String: Any]) -> String {
            let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = segment(["alg": "RS256", "typ": "JWT"])
        let payload = segment(["exp": Int(date.timeIntervalSince1970), "sub": "test"])
        return "\(header).\(payload).signature-not-verified"
    }

    private static func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: CodexResetCreditsFetcher.url, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    /// Records what reached the transport.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [URLRequest] = []
        private var _cancelled = false
        var requests: [URLRequest] { lock.withLock { _requests } }
        var cancelled: Bool { lock.withLock { _cancelled } }
        func record(_ request: URLRequest) { lock.withLock { _requests.append(request) } }
        func markCancelled() { lock.withLock { _cancelled = true } }
    }

    private func fetch(
        token: String = "opaque-token",
        accountID: String? = "account-123",
        budget: TimeInterval = CodexResetCreditsFetcher.budget,
        _ transport: @escaping CodexResetCreditsFetcher.Transport
    ) async -> CodexResetCreditsFetcher.Outcome {
        await CodexResetCreditsFetcher.fetch(
            accessToken: token,
            chatGPTAccountID: accountID,
            now: { Self.now },
            budget: budget,
            transport: transport
        )
    }

    // MARK: - The request

    func testTheRequestIsAReadOnlyGETWithTheUsageCredential() {
        let request = CodexResetCreditsFetcher.request(accessToken: "test-token", chatGPTAccountID: "account-123")
        XCTAssertEqual(request.url?.absoluteString, "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(request.timeoutInterval, 4)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-ID"), "account-123")
        XCTAssertEqual(request.value(forHTTPHeaderField: "OpenAI-Beta"), "codex-1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "originator"), "Codex Desktop")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "CLIPulseBar")
    }

    func testNoAccountHeaderWithoutAnAccountID() {
        for accountID in [nil, ""] as [String?] {
            let request = CodexResetCreditsFetcher.request(accessToken: "t", chatGPTAccountID: accountID)
            XCTAssertNil(request.value(forHTTPHeaderField: "ChatGPT-Account-ID"))
        }
    }

    // MARK: - Outcomes

    func testA200IsAReading() async {
        let recorder = Recorder()
        let outcome = await fetch { request in
            recorder.record(request)
            return (Self.body, Self.response(200))
        }
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(outcome.snapshot?.credits.count, 1)
        XCTAssertEqual(outcome.snapshot?.updatedAt, Self.now)
    }

    func testFailuresAreOutcomesNotErrors() async {
        let unauthorized = await fetch { _ in (Data(), Self.response(401)) }
        XCTAssertEqual(unauthorized, .failed(.http(401)))

        let notFound = await fetch { _ in (Data("{}".utf8), Self.response(404)) }
        XCTAssertEqual(notFound, .failed(.http(404)))

        let garbage = await fetch { _ in (Data("<html>".utf8), Self.response(200)) }
        XCTAssertEqual(garbage, .failed(.invalidResponse))

        let offline = await fetch { _ in throw URLError(.notConnectedToInternet) }
        XCTAssertEqual(offline, .failed(.transport))

        for outcome in [unauthorized, notFound, garbage, offline] {
            XCTAssertNil(outcome.snapshot)
        }
    }

    /// Upstream's rule: a credential this close to expiring is not used, and
    /// nothing is sent.
    func testACredentialAboutToExpireSendsNothing() async {
        let recorder = Recorder()
        let outcome = await fetch(token: Self.jwt(expiringAt: Self.now.addingTimeInterval(60))) { request in
            recorder.record(request)
            return (Self.body, Self.response(200))
        }
        XCTAssertEqual(outcome, .skippedStaleCredential)
        XCTAssertTrue(recorder.requests.isEmpty)

        let fresh = await fetch(token: Self.jwt(expiringAt: Self.now.addingTimeInterval(3_600))) { request in
            recorder.record(request)
            return (Self.body, Self.response(200))
        }
        XCTAssertNotNil(fresh.snapshot, "an hour of life left is enough")
        XCTAssertEqual(recorder.requests.count, 1)
    }

    /// The budget covers the whole read: a server that never answers is cut
    /// off at the budget, and the read is cancelled, not left running.
    func testTheBudgetCutsASlowReadShort() async {
        let recorder = Recorder()
        let started = Date()
        let outcome = await fetch(budget: 0.2) { request in
            recorder.record(request)
            do {
                try await Task.sleep(nanoseconds: 20_000_000_000)
            } catch {
                recorder.markCancelled()
                throw error
            }
            return (Self.body, Self.response(200))
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(outcome, .failed(.timedOut))
        XCTAssertLessThan(elapsed, 5, "the read ran \(elapsed)s past a 0.2 s budget")
        XCTAssertTrue(recorder.cancelled, "the timed-out read must be cancelled")
    }

    func testTheProductionBudgetIsFourSeconds() {
        XCTAssertEqual(CodexResetCreditsFetcher.budget, 4)
    }

    // MARK: - The store

    @MainActor
    func testAnOlderReadFinishingLateIsDropped() throws {
        let store = CodexResetCreditsStore()
        let account = UUID()
        let snapshot = try CodexRateLimitResetCreditsSnapshot.decode(Self.body, now: Self.now)

        let older = store.begin(account)
        let newer = store.begin(account)
        store.finish(account, generation: newer, snapshot: snapshot)
        store.finish(account, generation: older, snapshot: nil)
        XCTAssertEqual(store.snapshots[account], snapshot, "the older read's failure must not erase the newer reading")
    }

    @MainActor
    func testAFailedReadClearsThePreviousReading() throws {
        let store = CodexResetCreditsStore()
        let account = UUID()
        let snapshot = try CodexRateLimitResetCreditsSnapshot.decode(Self.body, now: Self.now)
        store.finish(account, generation: store.begin(account), snapshot: snapshot)
        XCTAssertNotNil(store.snapshots[account])
        store.finish(account, generation: store.begin(account), snapshot: nil)
        XCTAssertNil(store.snapshots[account], "a pass that could not confirm the credits must not keep the old ones")
    }

    @MainActor
    func testAClearDropsAReadStillInFlight() throws {
        let store = CodexResetCreditsStore()
        let account = UUID()
        let snapshot = try CodexRateLimitResetCreditsSnapshot.decode(Self.body, now: Self.now)
        let inFlight = store.begin(account)
        store.clear(account)
        store.finish(account, generation: inFlight, snapshot: snapshot)
        XCTAssertNil(store.snapshots[account], "a read begun before the quota failed must not come back")
    }

    @MainActor
    func testReadingsAreKeptPerAccount() throws {
        let store = CodexResetCreditsStore()
        let (a, b) = (UUID(), UUID())
        let snapshot = try CodexRateLimitResetCreditsSnapshot.decode(Self.body, now: Self.now)
        store.finish(b, generation: store.begin(b), snapshot: snapshot)
        XCTAssertNil(store.snapshots[a])
        XCTAssertEqual(store.snapshot(forAnyOf: [a, b]), snapshot)
        XCTAssertNil(store.snapshot(forAnyOf: [a]))
    }

    // MARK: - The reporter

    /// The collector starts the read and returns the quota at once: a read that
    /// takes its whole budget does not hold up the pass.
    func testTheQuotaPassDoesNotWaitForTheRead() async throws {
        let store = await MainActor.run { CodexResetCreditsStore() }
        let account = UUID()
        let reporter = CodexResetCreditsReporter(
            isEnabled: { true },
            fetch: { _, _ in
                try? await Task.sleep(nanoseconds: 600_000_000)
                return .fetched(try! CodexRateLimitResetCreditsSnapshot.decode(Self.body, now: Self.now))
            },
            store: { store }
        )
        let started = Date()
        let task = reporter.refresh(account: account, accessToken: "t", chatGPTAccountID: nil)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.3, "refresh must return before the read finishes")
        await task.value
        let held = await MainActor.run { store.snapshots[account] }
        XCTAssertEqual(held?.credits.count, 1)
    }

    func testAFailedReadLeavesNothingBehind() async throws {
        let store = await MainActor.run { CodexResetCreditsStore() }
        let account = UUID()
        let snapshot = try CodexRateLimitResetCreditsSnapshot.decode(Self.body, now: Self.now)
        await MainActor.run { store.finish(account, generation: store.begin(account), snapshot: snapshot) }
        let reporter = CodexResetCreditsReporter(
            isEnabled: { true },
            fetch: { _, _ in .failed(.timedOut) },
            store: { store }
        )
        await reporter.refresh(account: account, accessToken: "t", chatGPTAccountID: nil).value
        let held = await MainActor.run { store.snapshots[account] }
        XCTAssertNil(held)
    }

    func testSwitchedOffItSendsNothingAndClears() async throws {
        let store = await MainActor.run { CodexResetCreditsStore() }
        let account = UUID()
        let snapshot = try CodexRateLimitResetCreditsSnapshot.decode(Self.body, now: Self.now)
        await MainActor.run { store.finish(account, generation: store.begin(account), snapshot: snapshot) }
        let recorder = Recorder()
        let reporter = CodexResetCreditsReporter(
            isEnabled: { false },
            fetch: { _, _ in
                recorder.record(URLRequest(url: CodexResetCreditsFetcher.url))
                return .failed(.transport)
            },
            store: { store }
        )
        await reporter.refresh(account: account, accessToken: "t", chatGPTAccountID: nil).value
        XCTAssertTrue(recorder.requests.isEmpty, "switched off, nothing is sent")
        let held = await MainActor.run { store.snapshots[account] }
        XCTAssertNil(held)
    }

    func testTheReadUsesTheCredentialItWasGiven() async {
        let store = await MainActor.run { CodexResetCreditsStore() }
        let seen = Recorder()
        let reporter = CodexResetCreditsReporter(
            isEnabled: { true },
            fetch: { token, accountID in
                var request = URLRequest(url: CodexResetCreditsFetcher.url)
                request.setValue(token, forHTTPHeaderField: "token")
                request.setValue(accountID, forHTTPHeaderField: "account")
                seen.record(request)
                return .failed(.transport)
            },
            store: { store }
        )
        await reporter.refresh(account: UUID(), accessToken: "in-memory-token", chatGPTAccountID: "acct").value
        XCTAssertEqual(seen.requests.first?.value(forHTTPHeaderField: "token"), "in-memory-token")
        XCTAssertEqual(seen.requests.first?.value(forHTTPHeaderField: "account"), "acct")
    }

    // MARK: - The collector

    /// `/wham/usage`'s shape: a 5-hour and a weekly window, no credits.
    private static let usageBody = Data("""
    {"plan_type":"plus","rate_limit":{
      "primary_window":{"used_percent":12,"limit_window_seconds":18000,"reset_at":1787003600},
      "secondary_window":{"used_percent":40,"limit_window_seconds":604800,"reset_at":1787300000}}}
    """.utf8)

    /// A `CODEX_HOME` with an auth.json shaped like the Codex CLI's, holding a
    /// token with ten days to live, so the collector never renews it (renewing
    /// would reach auth.openai.com).
    private func codexHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipulse-reset-credits-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        setenv("CODEX_HOME", home.path, 1)
        addTeardownBlock {
            unsetenv("CODEX_HOME")
            try? FileManager.default.removeItem(at: home)
        }
        return home
    }

    private static func writeAuth(in home: URL, token: String, account: String) throws {
        let auth: [String: Any] = [
            "auth_mode": "chatgpt",
            "last_refresh": "2026-08-23T05:57:04.859771Z",
            "tokens": ["access_token": token, "refresh_token": "rt", "id_token": "it", "account_id": account],
        ]
        try JSONSerialization.data(withJSONObject: auth).write(to: home.appendingPathComponent("auth.json"))
    }

    private static func liveToken(_ subject: String) -> String {
        // `jwt(expiringAt:)` with a subject of its own, so two tokens differ.
        jwt(expiringAt: Date().addingTimeInterval(240 * 3_600)) + "-" + subject
    }

    private func codexConfig() throws -> ProviderConfig {
        try XCTUnwrap(ProviderConfig.defaults().first { $0.kind == .codex })
    }

    /// The collector returns the quota while the reset-credits read is still
    /// running, and that read is given the credential the quota was read
    /// with, although auth.json changed in between: a `codex login` to another
    /// account while the quota was being read must not put that account's
    /// credits beside this one's quota.
    func testTheCollectorReadsWithTheQuotasCredentialAndDoesNotWait() async throws {
        let home = try codexHome()
        let (first, second) = (Self.liveToken("first"), Self.liveToken("second"))
        try Self.writeAuth(in: home, token: first, account: "account-first")

        let store = await MainActor.run { CodexResetCreditsStore() }
        let seen = Recorder()
        let asked = expectation(description: "the reset credits are asked for")
        let reporter = CodexResetCreditsReporter(
            isEnabled: { true },
            fetch: { token, accountID in
                var request = URLRequest(url: CodexResetCreditsFetcher.url)
                request.setValue(token, forHTTPHeaderField: "token")
                request.setValue(accountID, forHTTPHeaderField: "account")
                seen.record(request)
                asked.fulfill()
                // Far slower than the quota: the pass must not wait for it.
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                return .failed(.timedOut)
            },
            store: { store }
        )
        let collector = CodexCollector(resetCredits: reporter, usageFetch: { token, accountID in
            XCTAssertEqual(token, first)
            XCTAssertEqual(accountID, "account-first")
            try Self.writeAuth(in: home, token: second, account: "account-second")
            return try CodexCollector.parseUsage(Self.usageBody)
        })

        let started = Date()
        let result = try await collector.collect(config: try codexConfig())
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 2, "the quota waited \(elapsed)s for the reset-credits read")
        XCTAssertEqual(result.usage.tiers.count, 2, "the quota is returned whole")
        await fulfillment(of: [asked], timeout: 5)
        XCTAssertEqual(seen.requests.count, 1)
        XCTAssertEqual(seen.requests.first?.value(forHTTPHeaderField: "token"), first)
        XCTAssertEqual(seen.requests.first?.value(forHTTPHeaderField: "account"), "account-first")
    }

    /// A quota read that fails asks for no reset credits and takes away what
    /// the card held for the account.
    func testAFailedQuotaReadAsksNothingAndClearsTheCard() async throws {
        let home = try codexHome()
        try Self.writeAuth(in: home, token: Self.liveToken("only"), account: "account-only")
        let config = try codexConfig()

        let store = await MainActor.run { CodexResetCreditsStore() }
        let snapshot = try CodexRateLimitResetCreditsSnapshot.decode(Self.body, now: Self.now)
        await MainActor.run {
            store.finish(config.accountID, generation: store.begin(config.accountID), snapshot: snapshot)
        }
        let seen = Recorder()
        let reporter = CodexResetCreditsReporter(
            isEnabled: { true },
            fetch: { _, _ in
                seen.record(URLRequest(url: CodexResetCreditsFetcher.url))
                return .failed(.transport)
            },
            store: { store }
        )
        let collector = CodexCollector(resetCredits: reporter, usageFetch: { _, _ in
            throw CollectorError.httpError(status: 500, provider: "Codex")
        })

        do {
            _ = try await collector.collect(config: config)
            XCTFail("a failed quota read must fail the pass")
        } catch {}

        var held: CodexRateLimitResetCreditsSnapshot? = snapshot
        for _ in 0..<100 where held != nil {
            try await Task.sleep(nanoseconds: 20_000_000)
            held = await MainActor.run { store.snapshots[config.accountID] }
        }
        XCTAssertNil(held, "the card must not keep credits after a quota read that failed")
        XCTAssertTrue(seen.requests.isEmpty, "no reset-credits read after a failed quota read")
    }

    // MARK: - Which process reads them

    /// Only the main app's Codex collector reads reset credits. The registry's
    /// instance is what the helper login item runs; it must not, or a Mac would
    /// ask twice and the helper would hold a reading nothing shows.
    func testOnlyTheMainAppsCodexCollectorReadsResetCredits() throws {
        XCTAssertNil(CodexCollector().resetCredits)
        let registryCodex = try XCTUnwrap(CollectorRegistry.collectors.first { $0.kind == .codex } as? CodexCollector)
        XCTAssertNil(registryCodex.resetCredits, "the helper resolves Codex through the registry")
        XCTAssertNotNil(CodexCollector.mainApp.resetCredits)

        let configs = ProviderConfig.defaults()
        let codex = try XCTUnwrap(configs.first { $0.kind == .codex })
        let resolved = try XCTUnwrap(
            DataRefreshManager.LocalRefreshRuntime.mainAppCollector(for: codex) as? CodexCollector
        )
        XCTAssertNotNil(resolved.resetCredits, "the main app's pass must use the collector that reads them")

        let claude = try XCTUnwrap(configs.first { $0.kind == .claude })
        let other = try XCTUnwrap(DataRefreshManager.LocalRefreshRuntime.mainAppCollector(for: claude))
        XCTAssertEqual(other.kind, .claude)
    }

    // MARK: - The remote switch

    private func isolatedDefaults() -> UserDefaults {
        let name = "CodexResetCreditsReaderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testAnAbsentSwitchMeansOn() {
        XCTAssertTrue(CodexResetCreditsFeature.isEnabled(in: isolatedDefaults()))
    }

    func testFalseSwitchesItOffUntilAManifestNoLongerSaysSo() {
        let d = isolatedDefaults()
        CodexResetCreditsFeature.recordRemoteSwitch(false, in: d)
        XCTAssertFalse(CodexResetCreditsFeature.isEnabled(in: d))
        CodexResetCreditsFeature.recordRemoteSwitch(nil, in: d)
        XCTAssertTrue(CodexResetCreditsFeature.isEnabled(in: d), "a manifest without the key turns it back on")
        CodexResetCreditsFeature.recordRemoteSwitch(false, in: d)
        CodexResetCreditsFeature.recordRemoteSwitch(true, in: d)
        XCTAssertTrue(CodexResetCreditsFeature.isEnabled(in: d))
    }

    /// Only a real boolean written by the switch counts; a stray value under
    /// the key neither switches it off nor crashes.
    func testOnlyARealBooleanSwitchesItOff() {
        let d = isolatedDefaults()
        for stray: Any in ["YES", 1, "1"] {
            d.set(stray, forKey: CodexResetCreditsFeature.remoteDisabledKey)
            XCTAssertTrue(CodexResetCreditsFeature.isEnabled(in: d), "\(stray) must not switch it off")
        }
    }

    #if DEVID_BUILD
    func testTheManifestKeyIsOptionalAndOnlyFalseSwitchesItOff() throws {
        let base = """
        {"version":"1.57.0","arch":"arm64","url":"https://example.com/a.dmg",
         "sha256":"abc","size_bytes":1,"min_os_version":"13.0"
        """
        let d = isolatedDefaults()
        for (json, expected) in [(",\"reset_credits_enabled\":false}", false),
                                 (",\"reset_credits_enabled\":true}", true),
                                 ("}", true)] {
            let manifest = try JSONDecoder().decode(AppUpdater.Manifest.self, from: Data((base + json).utf8))
            CodexResetCreditsFeature.recordRemoteSwitch(manifest.resetCreditsEnabled, in: d)
            XCTAssertEqual(CodexResetCreditsFeature.isEnabled(in: d), expected, "manifest \(json)")
        }
        let silent = try JSONDecoder().decode(AppUpdater.Manifest.self, from: Data((base + "}").utf8))
        XCTAssertNil(silent.resetCreditsEnabled, "every manifest before 1.57 lacks the key; it must decode")
    }
    #endif
}
#endif
