#if os(macOS)
import XCTest
@testable import CLIPulseCore

/// Google's June 2026 shutdown of Gemini CLI for personal accounts, replayed
/// through the collector's own network path with the response shapes CodexBar
/// recorded (`GeminiAPITestHelpers`, upstream 25bba9b7).
///
/// Before this, the shutdown reached the user as a bare 403, filed under
/// "Authentication failed · Reconnect Gemini", which is advice that cannot
/// work: Google refuses the account through this client however fresh the
/// sign-in.
final class GeminiConsumerTierShutdownTests: XCTestCase {

    private var savedLocale: String?

    override func setUp() {
        super.setUp()
        savedLocale = LocaleOverrideStore.shared.override
    }

    override func tearDown() {
        LocaleOverrideStore.shared.set(savedLocale)
        super.tearDown()
    }

    // MARK: - Replay harness

    /// Which endpoints the collector called, in order.
    private final class CallLog: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        func record(_ path: String) { lock.lock(); paths.append(path); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return paths }
    }

    private func replay(
        loadCodeAssist: (status: Int, body: Data),
        quota: (status: Int, body: Data),
        log: CallLog = CallLog()
    ) -> GeminiCollector.DataLoader {
        GeminiAPITestHelpers.dataLoader { request in
            let url = request.url!
            log.record(url.path)
            switch url.path {
            case "/v1internal:loadCodeAssist":
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString, status: loadCodeAssist.status, body: loadCodeAssist.body)
            case "/v1internal:retrieveUserQuota":
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString, status: quota.status, body: quota.body)
            default:
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
            }
        }
    }

    private let workspaceIDToken = GeminiAPITestHelpers.makeIDToken(
        email: "dev@example.com", hostedDomain: "example.com")

    private func fetch(
        _ load: @escaping GeminiCollector.DataLoader,
        idToken: String? = nil
    ) async throws -> (buckets: [GeminiCollector.QuotaBucket], tierInfo: GeminiCollector.TierInfo?) {
        try await GeminiCollector.fetchQuota(token: "token", idToken: idToken, load: load)
    }

    private func assertRetired(
        _ load: @escaping GeminiCollector.DataLoader,
        idToken: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await fetch(load, idToken: idToken)
            XCTFail("expected the shutdown to be reported", file: file, line: line)
        } catch {
            guard case .retired(.geminiCLIPersonalAccounts)? = error as? CollectorError else {
                return XCTFail("expected .retired, got \(error)", file: file, line: line)
            }
        }
    }

    private func assertPlainHTTP403(
        _ load: @escaping GeminiCollector.DataLoader,
        idToken: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await fetch(load, idToken: idToken)
            XCTFail("expected an HTTP 403", file: file, line: line)
        } catch {
            guard case .httpError(403, _)? = error as? CollectorError else {
                return XCTFail("expected .httpError(403), got \(error)", file: file, line: line)
            }
        }
    }

    // MARK: - The shutdown, as Google sends it

    func test_http200WithUnsupportedClientAndNoTier_isTheShutdown() async {
        let log = CallLog()
        await assertRetired(replay(
            loadCodeAssist: (200, GeminiAPITestHelpers.loadCodeAssistUnsupportedClientResponse()),
            quota: (403, GeminiAPITestHelpers.quotaSubscriptionRequiredResponse()),
            log: log))
        // Nothing after that answer can succeed, so the quota call is not made.
        XCTAssertEqual(log.all, ["/v1internal:loadCodeAssist"])
    }

    func test_quota403AfterUnsupportedClient_onAFreeTier_isTheShutdown() async {
        await assertRetired(replay(
            loadCodeAssist: (200, GeminiAPITestHelpers.loadCodeAssistUnsupportedClientResponse(
                currentTierId: "free-tier")),
            quota: (403, GeminiAPITestHelpers.quotaSubscriptionRequiredResponse())))
    }

    func test_loadCodeAssistErrorBodyNamingTheShutdown_isTheShutdown() async {
        let log = CallLog()
        await assertRetired(replay(
            loadCodeAssist: (403, GeminiAPITestHelpers.consumerTierDeprecationResponse()),
            quota: (403, GeminiAPITestHelpers.quotaSubscriptionRequiredResponse()),
            log: log))
        XCTAssertEqual(log.all, ["/v1internal:loadCodeAssist"])
    }

    func test_quotaErrorBodyNamingTheShutdown_isTheShutdown() async {
        await assertRetired(replay(
            loadCodeAssist: (200, GeminiAPITestHelpers.loadCodeAssistStandardTierResponse()),
            quota: (403, GeminiAPITestHelpers.consumerTierDeprecationResponse())))
    }

    // MARK: - Accounts the shutdown does not cover

    func test_plain403WithoutTheSignal_staysAnHTTPError() async {
        await assertPlainHTTP403(replay(
            loadCodeAssist: (200, GeminiAPITestHelpers.loadCodeAssistStandardTierResponse()),
            quota: (403, GeminiAPITestHelpers.quotaSubscriptionRequiredResponse())))
    }

    func test_licensedTier_despiteTheIneligibleListing_keepsWorking() async throws {
        let result = try await fetch(replay(
            loadCodeAssist: (200, GeminiAPITestHelpers.loadCodeAssistUnsupportedClientResponse(
                currentTierId: "standard-tier")),
            quota: (200, GeminiAPITestHelpers.sampleQuotaResponse())),
            idToken: workspaceIDToken)
        XCTAssertFalse(result.buckets.isEmpty)
        XCTAssertEqual(result.tierInfo?.tierId, "standard-tier")
    }

    func test_licensedTier403_staysAnHTTPError() async {
        await assertPlainHTTP403(replay(
            loadCodeAssist: (200, GeminiAPITestHelpers.loadCodeAssistUnsupportedClientResponse(
                currentTierId: "standard-tier")),
            quota: (403, GeminiAPITestHelpers.quotaSubscriptionRequiredResponse())))
    }

    func test_namedPaidTierWithoutCurrentTier_keepsWorking() async throws {
        let result = try await fetch(replay(
            loadCodeAssist: (200, GeminiAPITestHelpers.loadCodeAssistUnsupportedClientResponse(
                paidTierName: "Plus")),
            quota: (200, GeminiAPITestHelpers.sampleQuotaResponse())))
        XCTAssertFalse(result.buckets.isEmpty)
    }

    func test_namedPaidTier403_staysAnHTTPError() async {
        await assertPlainHTTP403(replay(
            loadCodeAssist: (200, GeminiAPITestHelpers.loadCodeAssistUnsupportedClientResponse(
                paidTierName: "Plus")),
            quota: (403, GeminiAPITestHelpers.quotaSubscriptionRequiredResponse())))
    }

    func test_workspaceAccountWithoutCurrentTier_keepsWorking() async throws {
        let result = try await fetch(replay(
            loadCodeAssist: (200, GeminiAPITestHelpers.loadCodeAssistUnsupportedClientResponse()),
            quota: (200, GeminiAPITestHelpers.sampleQuotaResponse())),
            idToken: workspaceIDToken)
        XCTAssertFalse(result.buckets.isEmpty)
    }

    func test_workspaceFreeTier403_staysAnHTTPError() async {
        await assertPlainHTTP403(replay(
            loadCodeAssist: (200, GeminiAPITestHelpers.loadCodeAssistUnsupportedClientResponse(
                currentTierId: "free-tier")),
            quota: (403, GeminiAPITestHelpers.quotaSubscriptionRequiredResponse())),
            idToken: workspaceIDToken)
    }

    /// Tier info stays best effort: a failed `loadCodeAssist` that is not the
    /// shutdown still lets the quota call run, as before this change.
    func test_ordinaryLoadCodeAssistFailure_stillFetchesQuota() async throws {
        let result = try await fetch(replay(
            loadCodeAssist: (500, Data("{}".utf8)),
            quota: (200, GeminiAPITestHelpers.sampleQuotaResponse())))
        XCTAssertFalse(result.buckets.isEmpty)
        XCTAssertNil(result.tierInfo)
    }

    // MARK: - Signal text

    func test_shutdownSignals() {
        for signal in [
            "UNSUPPORTED_CLIENT",
            "IneligibleTierError",
            "no longer supported for Gemini Code Assist for individuals",
            "please migrate Gemini to the Antigravity suite",
        ] {
            XCTAssertTrue(GeminiConsumerTierShutdown.isShutdownSignal(signal), signal)
        }
        for unrelated in ["UNAUTHENTICATED", "HTTP 500", "quota bucket missing", "SUBSCRIPTION_REQUIRED"] {
            XCTAssertFalse(GeminiConsumerTierShutdown.isShutdownSignal(unrelated), unrelated)
        }
    }

    // MARK: - What the user is told

    func test_shutdownIsItsOwnOutcome_notAnAuthFailure() {
        let error = CollectorError.retired(.geminiCLIPersonalAccounts)
        XCTAssertEqual(CollectorFailureCategory.categorize(error), .retired)
        XCTAssertEqual(CollectorOutcome.failed(.retired).telemetryToken, "failed_retired")
        // What the same response was filed as before.
        XCTAssertEqual(
            CollectorFailureCategory.categorize(CollectorError.httpError(status: 403, provider: "Gemini")),
            .auth)
    }

    func test_rowPointsToAntigravity_inChinese() {
        LocaleOverrideStore.shared.set("zh-Hans")
        let shown = CollectorOutcomePresentation.of(.failed(.retired), providerName: "Gemini")
        XCTAssertEqual(shown.label, "已停止支持个人账户")
        XCTAssertEqual(
            shown.nextStep,
            "Google 已不再为个人账户提供 Gemini CLI，重新登录也无济于事。Google 已用 Antigravity 取代它。")
        XCTAssertEqual(shown.severity, .attention)

        // Not the advice it used to get.
        let auth = CollectorOutcomePresentation.of(.failed(.auth), providerName: "Gemini")
        XCTAssertNotEqual(shown.label, auth.label)
        XCTAssertNotEqual(shown.nextStep, auth.nextStep)
    }

    func test_testConnectionTellsTheSameStory_andLogsInEnglish() {
        LocaleOverrideStore.shared.set("zh-Hans")
        let error = CollectorError.retired(.geminiCLIPersonalAccounts)
        XCTAssertEqual(
            error.errorDescription,
            CollectorOutcomePresentation.of(.failed(.retired), providerName: "Gemini").nextStep)
        XCTAssertEqual(
            error.logText,
            "Google no longer offers Gemini CLI to personal accounts, so signing in again won't help. "
                + "Google replaced it with Antigravity.")
    }
}
#endif
