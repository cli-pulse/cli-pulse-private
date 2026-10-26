// 59-01 (1.59): every refresh on a Mac ends in exactly one logged
// `UploadOutcome`, and it is the right one.
//
// Each case drives a real `refreshAll` down one route to one of its exits and
// reads the tracker's log: one line, naming the reason. The route bodies
// return the outcome, so an exit without one does not compile; these cases
// pin that each exit returns the reason that explains it.
//
// macOS-gated: the local route and the upload are macOS-only.

#if os(macOS)
import Foundation
import XCTest
@testable import CLIPulseCore

@MainActor
final class RefreshUploadOutcomeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UploadOutcomeStubProtocol.reset()
    }

    override func tearDown() {
        UploadOutcomeStubProtocol.reset()
        super.tearDown()
    }

    // MARK: - No route

    func testSignedOutAndDemoSayWhyNothingRan() async {
        let harness = await Harness()
        await harness.manager.refreshAll(
            context: Self.context(isAuthenticated: false, isLocalMode: false),
            callbacks: harness.callbacks())
        await harness.manager.refreshAll(
            context: Self.context(isAuthenticated: true, isDemoMode: true),
            callbacks: harness.callbacks())
        XCTAssertEqual(harness.reasons, [.signedOut, .demo])
        XCTAssertEqual(harness.routes, ["none", "none"])
    }

    // MARK: - Local route

    func testLocalModeWithoutAnAnswerOrWithNotNowReadsNothing() async {
        let harness = await Harness()
        await harness.refresh(Self.context(isAuthenticated: false, consent: .undecided))
        await harness.refresh(Self.context(isAuthenticated: false, consent: .declined))
        await harness.refresh(Self.context(isAuthenticated: true, isPaired: false, consent: .declined))
        XCTAssertEqual(harness.reasons, [.consentUnanswered, .consentDeclined, .consentDeclined])
        XCTAssertEqual(harness.uploads.count, 0)
    }

    func testLocalModeSignedOutHasNoAccountToUploadTo() async {
        let harness = await Harness(costEntries: Self.rows)
        await harness.refresh(Self.context(isAuthenticated: false, consent: .granted))
        XCTAssertEqual(harness.reasons, [.signedOut])
        XCTAssertEqual(harness.uploads.count, 0)
    }

    func testSignedInLocalRouteReportsTheUploadsOwnOutcome() async {
        let harness = await Harness(costEntries: Self.rows, upload: .rejected(status: 403))
        await harness.refresh(Self.context(isAuthenticated: true, isPaired: false))
        XCTAssertEqual(harness.outcomes, [.rejected(status: 403)])
        XCTAssertEqual(harness.routes, ["local"])
        XCTAssertEqual(harness.uploads.count, 1)
    }

    func testAnEmptyScanSaysWhetherAFolderGrantIsMissing() async {
        let missing = await Harness(needsFolderAccess: true)
        await missing.refresh(Self.context(isAuthenticated: true, isPaired: false))
        XCTAssertEqual(missing.reasons, [.folderAccessMissing])

        let empty = await Harness(needsFolderAccess: false)
        await empty.refresh(Self.context(isAuthenticated: true, isPaired: false))
        XCTAssertEqual(empty.reasons, [.scanEmpty])
    }

    // MARK: - Cloud route

    func testCloudRouteReportsTheUploadsOwnOutcome() async {
        Self.answerCloudReads()
        let harness = await Harness(costEntries: Self.rows)
        await harness.refresh(Self.context(isAuthenticated: true, isPaired: true))
        XCTAssertEqual(harness.outcomes, [.uploaded(rows: 1, status: 200, afterTokenRefresh: false)])
        XCTAssertEqual(harness.routes, ["cloud"])
        XCTAssertEqual(harness.uploads.count, 1)
    }

    func testCloudRouteWithNotNowOrAnEmptyScan() async {
        Self.answerCloudReads()
        let declined = await Harness(costEntries: Self.rows)
        await declined.refresh(Self.context(isAuthenticated: true, isPaired: true, consent: .declined))
        XCTAssertEqual(declined.reasons, [.consentDeclined])
        XCTAssertEqual(declined.uploads.count, 0)

        let empty = await Harness(needsFolderAccess: true)
        await empty.refresh(Self.context(isAuthenticated: true, isPaired: true))
        XCTAssertEqual(empty.reasons, [.folderAccessMissing])
    }

    /// Mode 3 of the sync investigation: any one of the five reads failing
    /// skipped every upload, and said nothing about it.
    func testAFailedCloudReadSkipsTheUploadAndSaysWhich() async {
        Self.answerCloudReads(failing: "/rest/v1/devices", status: 500)
        let harness = await Harness(costEntries: Self.rows)
        await harness.refresh(Self.context(isAuthenticated: true, isPaired: true))
        XCTAssertEqual(harness.outcomes, [.cloudReadFailed(status: 500)])
        XCTAssertEqual(harness.uploads.count, 0)
    }

    func testAnUnreachableServerSaysSoAndNoNetworkIsOffline() async {
        UploadOutcomeStubProtocol.respond { _ in .fail(URLError(.cannotConnectToHost)) }
        let harness = await Harness(costEntries: Self.rows)
        await harness.refresh(Self.context(isAuthenticated: true, isPaired: true))

        UploadOutcomeStubProtocol.respond { _ in .fail(URLError(.notConnectedToInternet)) }
        await harness.refresh(Self.context(isAuthenticated: true, isPaired: true))

        // A health check that times out is a Mac with no network as often as
        // a server that never answered: the line claims neither.
        UploadOutcomeStubProtocol.respond { _ in .fail(URLError(.timedOut)) }
        await harness.refresh(Self.context(isAuthenticated: true, isPaired: true))
        XCTAssertEqual(harness.reasons, [.serverUnreachable, .offline, .noAnswer])
    }

    // MARK: - A refresh behind one that has not finished

    /// Mode 2: a refresh that never returns keeps `isLoading` true, and every
    /// later tick used to return without a word. Now each says how long the
    /// one in front of it has been running.
    func testARefreshSkippedBehindAnotherSaysForHowLong() async {
        let gate = RefreshOutcomeGate()
        let harness = await Harness(collectorGate: gate)
        let first = Task { @MainActor in
            await harness.refresh(Self.context(isAuthenticated: true, isPaired: false))
        }
        await gate.waitUntilEntered()

        await harness.refresh(Self.context(isAuthenticated: true, isPaired: false, isLoading: true))
        guard case .refreshInFlight(let seconds)? = harness.outcomes.first else {
            return XCTFail("expected refresh_in_flight first, got \(harness.outcomes)")
        }
        XCTAssertNotNil(seconds, "the refresh in flight started here, so its age is known")

        await gate.open()
        await first.value
        XCTAssertEqual(harness.reasons, [.refreshInFlight, .scanEmpty])

        // Not started by this manager: the age is unknown, not zero.
        let other = await Harness()
        await other.refresh(Self.context(isAuthenticated: true, isPaired: true, isLoading: true))
        XCTAssertEqual(other.outcomes, [.refreshInFlight(seconds: nil)])
    }

    /// The age is time the Mac was awake. A lid close catches a refresh in
    /// flight; on wake it is still loading and the next tick is skipped
    /// behind it. On wall time that tick would count the whole night and
    /// call it `refresh_stuck`. Here the night passes (wall time moves on, as
    /// it does while this test runs) and the awake clock moves only by what
    /// the test gives it, which is all the age may say.
    func testTheInFlightAgeLeavesOutTimeTheMacSlept() async {
        let gate = RefreshOutcomeGate()
        let clock = AwakeClock(start: 86_400)
        let harness = await Harness(collectorGate: gate, uptime: { clock.now })
        let first = Task { @MainActor in
            await harness.refresh(Self.context(isAuthenticated: true, isPaired: false))
        }
        await gate.waitUntilEntered()

        // Asleep overnight, then 42 s awake.
        clock.advance(42)
        await harness.refresh(Self.context(isAuthenticated: true, isPaired: false, isLoading: true))
        // Then ten minutes awake, still not back: that is stuck.
        clock.advance(Double(UploadOutcome.stuckRefreshSeconds))
        await harness.refresh(Self.context(isAuthenticated: true, isPaired: false, isLoading: true))
        XCTAssertEqual(Array(harness.outcomes.prefix(2)), [
            .refreshInFlight(seconds: 42),
            .refreshInFlight(seconds: 42 + UploadOutcome.stuckRefreshSeconds),
        ])
        XCTAssertEqual(Array(harness.reasons.prefix(2)), [.refreshInFlight, .refreshStuck])

        await gate.open()
        await first.value
    }

    /// The clock the manager uses unless a test gives it one.
    func testTheDefaultClockIsTheAwakeClock() {
        XCTAssertEqual(DataRefreshManager.systemUptime(), ProcessInfo.processInfo.systemUptime, accuracy: 1)
        XCTAssertLessThan(DataRefreshManager.systemUptime(), Date().timeIntervalSince1970 / 2,
                          "that is wall time, which counts sleep")
    }

    // MARK: - 59-01a: a rejected refresh token found by the upload

    func testAnExpiredSessionFoundByTheUploadSignsOutOnce() async {
        Self.answerCloudReads()
        for isPaired in [true, false] {
            let harness = await Harness(costEntries: Self.rows, upload: .sessionExpired)
            await harness.refresh(Self.context(isAuthenticated: true, isPaired: isPaired))
            XCTAssertEqual(harness.reasons, [.sessionExpired])
            XCTAssertEqual(harness.signOuts, 1, "isPaired=\(isPaired): exactly one sign-out")
        }
        // And only then.
        let rejected = await Harness(costEntries: Self.rows, upload: .unauthorized(afterRetry: true))
        await rejected.refresh(Self.context(isAuthenticated: true, isPaired: true))
        XCTAssertEqual(rejected.signOuts, 0, "a 401 after the retry is not a sign-out")
    }

    // MARK: - Fixtures

    private static let rows: [CostUsageScanResult.DailyEntry] = [
        .init(date: "2026-10-26", provider: "Codex", model: "gpt-5.5",
              inputTokens: 10, cachedTokens: 0, outputTokens: 1, costUSD: 0.01),
    ]

    static func context(
        isAuthenticated: Bool,
        isDemoMode: Bool = false,
        isPaired: Bool = false,
        isLoading: Bool = false,
        isLocalMode: Bool = true,
        consent: LocalScanConsent = .granted
    ) -> DataRefreshManager.Context {
        DataRefreshManager.Context(
            isAuthenticated: isAuthenticated,
            isDemoMode: isDemoMode,
            isPaired: isPaired,
            isLoading: isLoading,
            notificationsEnabled: false,
            sessionQuotaNotificationsEnabled: true,
            authenticatedUserID: isAuthenticated ? "user-a" : "",
            providerConfigs: [],
            providers: [],
            maxProviders: 100,
            currentTierName: "Pro",
            tierResolutionState: .resolvedConfirmed,
            isLocalMode: isLocalMode && !isAuthenticated,
            localScanConsent: consent,
            localScanConsentV2: .undecided
        )
    }

    /// The five reads and the budget evaluation of the cloud route, all
    /// answered, except `failing`.
    static func answerCloudReads(failing: String? = nil, status: Int = 500) {
        UploadOutcomeStubProtocol.respond { request in
            let path = request.url?.path ?? ""
            if path == failing { return .status(status, #"{"message":"boom"}"#) }
            switch path {
            case "/auth/v1/health", "/rest/v1/rpc/dashboard_summary": return .status(200, "{}")
            case "/rest/v1/rpc/evaluate_budget_alerts": return .status(200, #"{"alerts_created":0}"#)
            default: return .status(200, "[]")
            }
        }
    }

    /// A manager wired to a recording tracker and a runtime that touches
    /// nothing on this Mac.
    @MainActor
    final class Harness {
        let manager: DataRefreshManager
        let uploadLog: UploadCallLog
        private(set) var signOuts = 0
        private let box: LineBox

        init(
            costEntries: [CostUsageScanResult.DailyEntry] = [],
            needsFolderAccess: Bool = false,
            upload: UploadOutcome = .uploaded(rows: 1, status: 200, afterTokenRefresh: false),
            collectorGate: RefreshOutcomeGate? = nil,
            uptime: (() -> TimeInterval)? = nil
        ) async {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [UploadOutcomeStubProtocol.self]
            let api = APIClient(
                supabaseURL: "https://refresh-outcome.test",
                supabaseAnonKey: "anon",
                session: URLSession(configuration: config),
                providerAccountFlags: .init(readV2: false, writeV2: false)
            )
            _ = await api.beginExternalAuthorizationTransition(generation: 1)
            _ = await api.installExternalAuthenticatedSession(
                accessToken: "token-a", refreshToken: "refresh-a",
                userID: "user-a", transitionGeneration: 1)

            let box = LineBox()
            let uploadLog = UploadCallLog()
            self.box = box
            self.uploadLog = uploadLog
            manager = DataRefreshManager(
                api: api,
                localRuntime: .outcomeTest(
                    costEntries: costEntries,
                    needsFolderAccess: needsFolderAccess,
                    upload: upload,
                    uploadLog: uploadLog,
                    collectorGate: collectorGate
                ),
                hostIdentity: HostIdentity(provider: { "test-mac" }),
                uploadOutcomes: UploadOutcomeTracker(
                    reporter: RecordingUploadReporter(),
                    defaults: UploadOutcomeTests.freshDefaults(),
                    log: { box.lines.append($0) }
                ),
                uptime: uptime ?? { DataRefreshManager.systemUptime() }
            )
        }

        func callbacks() -> DataRefreshManager.Callbacks {
            DataRefreshManager.Callbacks(
                isAuthenticated: { true },
                setLoading: { _ in },
                setLastError: { _ in },
                setServerOnline: { _ in },
                applyPayload: { _ in },
                sendNotification: { _ in },
                afterRefresh: {},
                handleTokenExpired: { [weak self] _ in self?.signOuts += 1 },
                activeSuppressedAlertIDs: { [] },
                setNeedsFolderAccess: { _ in },
                setCollectorOutcomes: { _ in }
            )
        }

        func refresh(_ context: DataRefreshManager.Context) async {
            await manager.refreshAll(context: context, callbacks: callbacks())
        }

        var uploads: [String] { uploadLog.calls }

        /// The reasons logged, one per refresh, in order.
        var reasons: [UploadOutcome.Reason] {
            box.lines.compactMap { line in
                line.split(separator: " ").first { $0.hasPrefix("outcome=") }
                    .flatMap { UploadOutcome.Reason(rawValue: String($0.dropFirst("outcome=".count))) }
            }
        }

        var routes: [String] {
            box.lines.compactMap { line in
                line.split(separator: " ").first { $0.hasPrefix("route=") }.map { String($0.dropFirst(6)) }
            }
        }

        /// The outcomes, rebuilt from the log for the cases whose numbers
        /// matter. Every line must be one of these or a test fails.
        var outcomes: [UploadOutcome] {
            box.lines.map { line in
                let fields = Dictionary(
                    line.split(separator: " ").compactMap { pair -> (String, String)? in
                        let parts = pair.split(separator: "=", maxSplits: 1)
                        return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
                    },
                    uniquingKeysWith: { first, _ in first })
                let status = fields["status"].flatMap(Int.init)
                switch UploadOutcome.Reason(rawValue: fields["outcome"] ?? "") {
                case .uploaded?:
                    return .uploaded(rows: Int(fields["rows"] ?? "") ?? -1, status: status ?? -1,
                                     afterTokenRefresh: fields["token_refreshed"] == "1")
                case .rejected?: return .rejected(status: status ?? -1)
                case .cloudReadFailed?: return .cloudReadFailed(status: status)
                case .refreshInFlight?, .refreshStuck?:
                    return .refreshInFlight(seconds: fields["in_flight_s"].flatMap(Int.init))
                case .unauthorizedAfterRetry?: return .unauthorized(afterRetry: true)
                case .unauthorized?: return .unauthorized(afterRetry: false)
                default:
                    XCTFail("rebuild not written for: \(line)")
                    return .cancelled
                }
            }
        }
    }
}

final class LineBox: @unchecked Sendable {
    var lines: [String] = []
}

/// A stand-in for `systemUptime` that moves only when told.
final class AwakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: TimeInterval
    init(start: TimeInterval) { current = start }
    var now: TimeInterval { lock.lock(); defer { lock.unlock() }; return current }
    func advance(_ seconds: TimeInterval) { lock.lock(); current += seconds; lock.unlock() }
}

/// Which uploads the runtime was asked for.
final class UploadCallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func append(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        stored.append(name)
    }

    var calls: [String] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}

/// Holds the collector pass until opened, and says when it got there.
actor RefreshOutcomeGate {
    private var entered = false
    private var isOpen = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        guard !isOpen else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func open() {
        isOpen = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

extension DataRefreshManager.LocalRefreshRuntime {
    /// Touches nothing on this Mac: the scan returns `costEntries`, the folder
    /// check answers `needsFolderAccess`, the upload answers `upload`.
    static func outcomeTest(
        costEntries: [CostUsageScanResult.DailyEntry] = [],
        needsFolderAccess: Bool = false,
        upload: UploadOutcome = .uploaded(rows: 1, status: 200, afterTokenRefresh: false),
        uploadLog: UploadCallLog = UploadCallLog(),
        collectorGate: RefreshOutcomeGate? = nil
    ) -> Self {
        Self(
            prepareCredentials: {},
            collectAccountPass: { _ in
                if let collectorGate { await collectorGate.wait() }
                return .empty
            },
            readHelperSnapshot: { _ in .empty },
            scanLocal: {
                LocalScanResult(sessions: [], providers: [], totalUsage: 0, totalCost: 0, activeSessionCount: 0)
            },
            scanCostUsage: { CostUsageScanResult(entries: costEntries) },
            needsFolderAccessNudge: { scanIsEmpty in scanIsEmpty && needsFolderAccess },
            syncLegacyQuotas: { _, _ in },
            syncDailyUsage: { _, _ in
                uploadLog.append("syncDailyUsage")
                return upload
            },
            syncAccountQuotas: { _, _ in },
            recordLocalHistory: { _, _, _ in }
        )
    }
}
#endif
