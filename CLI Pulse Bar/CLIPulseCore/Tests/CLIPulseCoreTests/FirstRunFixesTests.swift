import XCTest
@testable import CLIPulseCore

/// v1.59 (59-15): the first-run fixes for a Mac whose session logs are read
/// but whose quota collectors are not ready, the case where the App Store
/// build's October installs stalled.
///
/// - F1: a provider with log rows in the rolling week and no row of its own
///   gets one from the scan, so its usage and its collector's not-ready reason
///   have a card to appear on (`DataRefreshManager.localDisplayProviders`).
/// - F3: the Providers tab's folder banner is the Overview's one-tap grant.
/// - F4: no "No AI tools detected" beside log rows or under the folder banner
///   (`OverviewOptionalCardsTests` holds the producer's truth table).
/// - F5: no "collecting locally" card after "Not now".
///
/// Runs in Simplified Chinese: the one string these paths produce is resolved
/// when it is made, and under English a broken lookup still passes. No
/// `AppState`: constructing one walks into a real keychain read.
final class FirstRunFixesTests: XCTestCase {

    private var savedOverride: String?

    override func setUp() {
        super.setUp()
        savedOverride = LocaleOverrideStore.shared.override
        LocaleOverrideStore.shared.set("zh-Hans")
    }

    override func tearDown() {
        LocaleOverrideStore.shared.set(savedOverride)
        super.tearDown()
    }

    // MARK: - Fixtures

    /// A fixed noon, so "today" and "six days ago" are the days they say.
    private static let now: Date = {
        var parts = DateComponents()
        parts.year = 2026; parts.month = 10; parts.day = 21; parts.hour = 12
        return Calendar.current.date(from: parts)!
    }()

    private static func day(_ offset: Int) -> String {
        DateRange.ymd(Calendar.current.date(byAdding: .day, value: offset, to: now)!)
    }

    private static func entry(_ day: String, _ provider: String,
                              input: Int, cached: Int = 0, output: Int,
                              cost: Double?) -> CostUsageScanResult.DailyEntry {
        .init(date: day, provider: provider, model: "model-\(provider.lowercased())",
              inputTokens: input, cachedTokens: cached, outputTokens: output, costUSD: cost)
    }

    private static let allKinds = Set(ProviderKind.allCases)

    /// What a quota collector returns: a utilization row with tiers.
    private static func collectorRow(_ kind: ProviderKind) -> ProviderUsage {
        ProviderUsage(
            provider: kind.rawValue, today_usage: 40, week_usage: 12,
            estimated_cost_today: 0, estimated_cost_week: 0,
            cost_status_today: "Unavailable", cost_status_week: "Unavailable",
            quota: 100, remaining: 60,
            tiers: [TierDTO(name: "5h", quota: 100, remaining: 60, windowMinutes: 300)],
            status_text: "40% used", trend: [], recent_sessions: [], recent_errors: [],
            metadata: ProviderMetadata(display_name: kind.rawValue, category: "cloud"))
    }

    /// What `LocalScanner` makes of a running CLI (Developer ID only).
    private static func processRow(_ kind: ProviderKind) -> ProviderUsage {
        ProviderUsage(
            provider: kind.rawValue, today_usage: 900, week_usage: 900,
            estimated_cost_today: 0.02, estimated_cost_week: 0.02,
            cost_status_today: "normal", cost_status_week: "normal",
            quota: nil, remaining: nil,
            status_text: CollectorStatusText.activeSessions(1),
            trend: [], recent_sessions: [], recent_errors: [], metadata: nil)
    }

    // MARK: - F1: scan-backed provider rows

    /// The stall itself: logs read, no collector ready, no process running
    /// (the App Store sandbox denies the process list). The provider gets a
    /// row with this Mac's tokens and cost, and no quota it does not have.
    func testAProviderWithLogRowsAndNoRowOfItsOwnGetsOneFromTheScan() throws {
        let scan = CostUsageScanResult(entries: [
            Self.entry(Self.day(0), "Claude", input: 1_000, cached: 50_000, output: 200, cost: 1.50),
            Self.entry(Self.day(-3), "Claude", input: 4_000, output: 800, cost: 6.00),
        ])
        let providers = DataRefreshManager.localDisplayProviders(
            processRows: [], collectorRows: [], scan: scan,
            enabledKinds: Self.allKinds, now: Self.now)

        XCTAssertEqual(providers.map(\.provider), ["Claude"], "the scan's rows found no card to appear on")
        let claude = try XCTUnwrap(providers.first)
        XCTAssertEqual(claude.today_usage, 1_200, "today is the scan's input + output, cache excluded")
        XCTAssertEqual(claude.week_usage, 6_000)
        XCTAssertEqual(claude.estimated_cost_today, 1.50, accuracy: 1e-9)
        XCTAssertEqual(claude.estimated_cost_week, 7.50, accuracy: 1e-9)
        XCTAssertEqual(claude.cost_status_today, "Estimated")
        XCTAssertNil(claude.quota, "a row read from logs claims a quota")
        XCTAssertNil(claude.remaining)
        XCTAssertTrue(claude.tiers.isEmpty)
        XCTAssertEqual(claude.metadata?.supports_quota, true,
                       "the card no longer says the quota is unavailable for a quota provider")
    }

    /// A collector's row always wins: its quota and tiers stay, the scan only
    /// prices it (as before 1.59), and the provider is not listed twice.
    func testACollectorRowWinsOverTheScan() throws {
        let scan = CostUsageScanResult(entries: [
            Self.entry(Self.day(0), "Codex", input: 3_000, output: 300, cost: 2.25),
            Self.entry(Self.day(0), "Claude", input: 1_000, output: 100, cost: 1.00),
        ])
        let providers = DataRefreshManager.localDisplayProviders(
            processRows: [], collectorRows: [Self.collectorRow(.codex)], scan: scan,
            enabledKinds: Self.allKinds, now: Self.now)

        XCTAssertEqual(providers.map(\.provider).sorted(), ["Claude", "Codex"])
        let codex = try XCTUnwrap(providers.first { $0.provider == "Codex" })
        XCTAssertEqual(codex.quota, 100, "the scan replaced the collector's row")
        XCTAssertEqual(codex.remaining, 60)
        XCTAssertEqual(codex.tiers.count, 1)
        XCTAssertEqual(codex.today_usage, 40, "a quota row's utilization was overwritten with tokens")
        XCTAssertEqual(codex.estimated_cost_today, 2.25, accuracy: 1e-9, "the scan no longer prices the row")
    }

    /// Developer ID: a running CLI's process row wins too.
    func testAProcessRowWinsOverTheScan() throws {
        let scan = CostUsageScanResult(entries: [
            Self.entry(Self.day(0), "Claude", input: 1_000, output: 100, cost: 1.00),
        ])
        let providers = DataRefreshManager.localDisplayProviders(
            processRows: [Self.processRow(.claude)], collectorRows: [], scan: scan,
            enabledKinds: Self.allKinds, now: Self.now)

        XCTAssertEqual(providers.map(\.provider), ["Claude"])
        let claude = try XCTUnwrap(providers.first)
        XCTAssertEqual(claude.today_usage, 900, "the process row was replaced")
        XCTAssertEqual(claude.status_text, CollectorStatusText.activeSessions(1))
        XCTAssertEqual(claude.estimated_cost_today, 1.00, accuracy: 1e-9)
    }

    /// The rolling week: rows six days back count, rows older do not (the
    /// cost scan reads 30 days; a provider unused for a week is not shown).
    func testOnlyTheRollingWeekMakesARow() throws {
        let old = CostUsageScanResult(entries: [
            Self.entry(Self.day(-10), "Codex", input: 5_000, output: 500, cost: 3.00),
        ])
        XCTAssertTrue(DataRefreshManager.localDisplayProviders(
            processRows: [], collectorRows: [], scan: old,
            enabledKinds: Self.allKinds, now: Self.now).isEmpty,
            "a provider last used ten days ago got a row")

        let sixDaysBack = CostUsageScanResult(entries: [
            Self.entry(Self.day(-6), "Codex", input: 5_000, output: 500, cost: 3.00),
        ])
        let codex = try XCTUnwrap(DataRefreshManager.localDisplayProviders(
            processRows: [], collectorRows: [], scan: sixDaysBack,
            enabledKinds: Self.allKinds, now: Self.now).first)
        XCTAssertEqual(codex.provider, "Codex")
        XCTAssertEqual(codex.today_usage, 0)
        XCTAssertEqual(codex.week_usage, 5_500)
        XCTAssertEqual(codex.estimated_cost_today, 0)
        XCTAssertEqual(codex.estimated_cost_week, 3.00, accuracy: 1e-9)
    }

    /// A provider the user switched off, or the free plan's limit did, gets no
    /// row, so the plan-limit migration cannot count it back in; and only the
    /// scanned providers can gain one, so it counts at most two more.
    func testASwitchedOffProviderGetsNoRowAndOnlyScannedOnesCan() {
        let scan = CostUsageScanResult(entries: [
            Self.entry(Self.day(0), "Claude", input: 1_000, output: 100, cost: 1.00),
            Self.entry(Self.day(0), "Codex", input: 1_000, output: 100, cost: 1.00),
            Self.entry(Self.day(0), "NotAProvider", input: 1_000, output: 100, cost: 1.00),
        ])
        let claudeOff = DataRefreshManager.localDisplayProviders(
            processRows: [], collectorRows: [], scan: scan,
            enabledKinds: Self.allKinds.subtracting([.claude]), now: Self.now)
        XCTAssertEqual(claudeOff.map(\.provider), ["Codex"], "a switched-off provider came back from its logs")

        let configs = ProviderKind.allCases.map { ProviderConfig(kind: $0, isEnabled: $0 != .claude) }
        let active = AppState.activeKindsForMigrationBanner(providers: claudeOff, providerConfigs: configs)
        XCTAssertEqual(active, [.codex])

        let allOn = DataRefreshManager.localDisplayProviders(
            processRows: [], collectorRows: [], scan: scan,
            enabledKinds: Self.allKinds, now: Self.now)
        XCTAssertEqual(Set(allOn.map(\.provider)), ["Claude", "Codex"])
    }

    /// No scan, no rows: nothing is invented.
    func testNoScanAddsNothing() {
        XCTAssertTrue(DataRefreshManager.localDisplayProviders(
            processRows: [], collectorRows: [], scan: nil,
            enabledKinds: Self.allKinds, now: Self.now).isEmpty)
        XCTAssertTrue(DataRefreshManager.localDisplayProviders(
            processRows: [], collectorRows: [], scan: CostUsageScanResult(entries: []),
            enabledKinds: Self.allKinds, now: Self.now).isEmpty)
    }

    #if os(macOS)
    // MARK: - F1 + F4 through a local refresh

    /// The App Store first run end to end: signed out, scan consent given, no
    /// collector ready, Claude Code's logs read. The payload shows Claude with
    /// its cost, and no "No AI tools detected".
    @MainActor
    func testALocalRefreshShowsTheLogsProviderAndNoNoAIToolsSignal() async throws {
        let today = DateRange.ymd(Date())
        let payload = try await Self.localRefreshPayload(
            costEntries: [Self.entry(today, "Claude", input: 1_000, output: 200, cost: 1.50)],
            configs: [ProviderConfig(kind: .claude), ProviderConfig(kind: .codex)])

        XCTAssertEqual(payload.providers.map(\.provider), ["Claude"])
        XCTAssertEqual(payload.providers.first?.today_usage, 1_200)
        XCTAssertEqual(payload.dashboard.provider_breakdown.map(\.provider), ["Claude"],
                       "the Overview's Provider Usage card still has no row")
        XCTAssertEqual(payload.dashboard.risk_signals, [], "a provider is on screen and the hint says no AI tools")
    }

    /// Logs read for a provider switched off: no row, and still no "No AI
    /// tools detected", because the logs were read.
    @MainActor
    func testALocalRefreshWithLogsForASwitchedOffProviderRaisesNoSignal() async throws {
        let today = DateRange.ymd(Date())
        let payload = try await Self.localRefreshPayload(
            costEntries: [Self.entry(today, "Claude", input: 1_000, output: 200, cost: 1.50)],
            configs: [ProviderConfig(kind: .claude, isEnabled: false)])

        XCTAssertTrue(payload.providers.isEmpty)
        XCTAssertEqual(payload.dashboard.risk_signals, [])
    }

    /// The positive control for the two above: with nothing read at all, the
    /// refresh still raises the signal, in Chinese.
    @MainActor
    func testALocalRefreshThatFoundNothingStillRaisesTheSignalInChinese() async throws {
        let payload = try await Self.localRefreshPayload(
            costEntries: [], configs: [ProviderConfig(kind: .claude)])

        XCTAssertTrue(payload.providers.isEmpty)
        XCTAssertEqual(payload.dashboard.risk_signals, [L10n.dashboard.noAiToolsDetected])
        let signal = try XCTUnwrap(payload.dashboard.risk_signals.first)
        XCTAssertNil(signal.range(of: "[A-Za-z]{3,}", options: .regularExpression),
                     "English words in the Chinese risk signal: \(signal)")
    }

    @MainActor
    private static func localRefreshPayload(
        costEntries: [CostUsageScanResult.DailyEntry],
        configs: [ProviderConfig]
    ) async throws -> DataRefreshManager.RefreshPayload {
        let manager = DataRefreshManager(
            api: APIClient(supabaseURL: "https://stub.cli-pulse.test", supabaseAnonKey: "anon"),
            localRuntime: .recording(LocalRuntimeRecorder(), costEntries: costEntries))
        let box = PayloadBox()
        await manager.refreshAll(
            context: DataRefreshManager.Context(
                isAuthenticated: false, isDemoMode: false, isPaired: false, isLoading: false,
                notificationsEnabled: false, sessionQuotaNotificationsEnabled: true,
                authenticatedUserID: "", providerConfigs: configs, providers: [],
                maxProviders: 100, currentTierName: "Free", tierResolutionState: .resolvedConfirmed,
                isLocalMode: true, localScanConsent: .granted, localScanConsentV2: .undecided),
            callbacks: DataRefreshManager.Callbacks(
                isAuthenticated: { false },
                setLoading: { _ in }, setLastError: { _ in }, setServerOnline: { _ in },
                applyPayload: { box.payload = $0 },
                sendNotification: { _ in }, afterRefresh: {}, handleTokenExpired: { _ in },
                activeSuppressedAlertIDs: { [] }, setNeedsFolderAccess: { _ in },
                setCollectorOutcomes: { _ in }))
        return try XCTUnwrap(box.payload, "the local refresh published no payload")
    }

    private final class PayloadBox {
        var payload: DataRefreshManager.RefreshPayload?
    }
    #endif

    // MARK: - F1: display only

    /// The scan-backed rows never reach an upload: inside `refreshLocal`, the
    /// three writes take the scan, the collector results and the provider
    /// accounts, never the display list `localDisplayProviders` returns.
    func testTheLocalRefreshUploadsNothingFromTheDisplayList() throws {
        let code = Self.codeOnly(try String(
            contentsOf: Self.coreRoot.appendingPathComponent("Sources/CLIPulseCore/DataRefreshManager.swift"),
            encoding: .utf8))
        // No ` {` in the anchor: the signature may gain a return type
        // (`async -> UploadOutcome`) without moving the body this reads.
        let start = try XCTUnwrap(code.range(of: "private func refreshLocal(context: Context, callbacks: Callbacks) async"),
                                  "refreshLocal was not found")
        let end = try XCTUnwrap(code.range(of: "nonisolated static func runCollectorPass(", range: start.upperBound..<code.endIndex),
                                "the end of refreshLocal was not found")
        let body = String(code[start.upperBound..<end.lowerBound])

        XCTAssertTrue(body.contains("let providers = Self.localDisplayProviders("),
                      "refreshLocal no longer builds its display list with localDisplayProviders")
        let write = try NSRegularExpression(pattern: #"runtime\.(sync\w+)\(\s*(\w+)"#)
        var firstArguments: [String: String] = [:]
        for match in write.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
            guard let name = Range(match.range(at: 1), in: body),
                  let argument = Range(match.range(at: 2), in: body) else { continue }
            firstArguments[String(body[name])] = String(body[argument])
        }
        XCTAssertEqual(firstArguments, [
            "syncDailyUsage": "costScanResult",
            "syncLegacyQuotas": "cloudOwnedCollectorResults",
            "syncAccountQuotas": "cloudOwnedProviderAccounts",
        ], "a local refresh's upload now reads something else; the scan-backed rows must stay display-only")
    }

    // MARK: - F5: the local-mode card

    /// The card says usage is being collected; it shows only while the
    /// collection gate lets a signed-out local-mode refresh through.
    func testTheLocalModeCardShowsOnlyWhileCollecting() {
        func shows(_ consent: LocalScanConsent, authenticated: Bool = false, localMode: Bool = true) -> Bool {
            LocalCollectionPolicy.showsLocalModeGuide(
                isAuthenticated: authenticated, isLocalMode: localMode, consent: consent)
        }
        XCTAssertTrue(shows(.granted))
        XCTAssertFalse(shows(.declined), "after \"Not now\" the card still says usage is being collected")
        XCTAssertFalse(shows(.undecided), "nothing is collected before the answer")
        XCTAssertFalse(shows(.granted, localMode: false))
        XCTAssertFalse(shows(.granted, authenticated: true), "a signed-in Mac is not in local mode")
    }

    // MARK: - Wiring (F3, F5)

    /// Source-level, because the views are out of this package's reach.
    /// Both tabs that read `needsScannerFolderAccess` draw the one banner with
    /// the one-tap grant, and the Overview draws the local-mode card only
    /// under its rule.
    func testTheTabsDrawTheOneTapBannerAndTheCardUnderItsRule() throws {
        for path in ["CLI Pulse Bar/OverviewTab.swift", "CLI Pulse Bar/ProvidersTab.swift"] {
            let lines = Self.codeOnly(try String(
                contentsOf: Self.appSourceRoot.appendingPathComponent(path), encoding: .utf8))
                .components(separatedBy: "\n")
            let gates = lines.indices.filter {
                lines[$0].trimmingCharacters(in: .whitespaces) == "if state.needsScannerFolderAccess {"
            }
            XCTAssertEqual(gates.count, 1, "\(path): the folder-access banner's gate was not found once")
            for gate in gates {
                let next = lines[min(gate + 1, lines.count - 1)].trimmingCharacters(in: .whitespaces)
                XCTAssertEqual(next, "ScannerFolderAccessBanner()", """
                    \(path) draws `\(next)` for the missing folder grant, not the banner with the one-tap grant
                    """)
            }
        }

        let overview = Self.codeOnly(try String(
            contentsOf: Self.appSourceRoot.appendingPathComponent("CLI Pulse Bar/OverviewTab.swift"), encoding: .utf8))
            .components(separatedBy: "\n")
        let cards = overview.indices.filter { overview[$0].contains("LocalModeGuideCard()") }
        XCTAssertEqual(cards.count, 1, "the Overview's local-mode card was not found once")
        for line in cards {
            let above = overview[max(0, line - 6)..<line]
            XCTAssertTrue(above.contains { $0.contains("LocalCollectionPolicy.showsLocalModeGuide(") }, """
                the Overview draws the local-mode card without LocalCollectionPolicy.showsLocalModeGuide just \
                above it, so it is back after "Not now"
                """)
        }
    }

    // MARK: - Source helpers

    /// The `CLIPulseCore` package root.
    private static var coreRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CLIPulseCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // CLIPulseCore
    }

    /// `CLI Pulse Bar/`, which holds the app targets and `CLIPulseCore`.
    private static var appSourceRoot: URL {
        coreRoot.deletingLastPathComponent()
    }

    /// Whole-line comments dropped: comments name the symbols these scans
    /// look for.
    private static func codeOnly(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}
