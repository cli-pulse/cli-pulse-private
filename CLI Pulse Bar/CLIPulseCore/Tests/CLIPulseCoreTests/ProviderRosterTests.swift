import XCTest
@testable import CLIPulseCore

/// 1.57: Crof (shut down), Kimi K2 and CrossModel (relays whose operator CLI
/// Pulse could not confirm) are retired. Their raw values must keep decoding,
/// and nothing may offer, collect or show them (`ProviderRoster`).
final class ProviderRosterTests: XCTestCase {

    private let retired: Set<ProviderKind> = [.crof, .kimiK2, .crossModel]

    private var savedLocale: String?

    override func setUp() {
        super.setUp()
        savedLocale = LocaleOverrideStore.shared.override
    }

    override func tearDown() {
        LocaleOverrideStore.shared.set(savedLocale)
        super.tearDown()
    }

    // MARK: - Old data still decodes

    /// The configs array as 1.56 saved it to UserDefaults
    /// (`cli_pulse_provider_configs`), with all three retired providers in it.
    private let configsSavedBy156 = """
    [
      {"accountID":"11111111-1111-4111-8111-111111111111","kind":"Codex","isEnabled":true,"sortOrder":0,"sourceMode":"auto"},
      {"accountID":"22222222-2222-4222-8222-222222222222","kind":"Kimi K2","isEnabled":true,"sortOrder":12,"sourceMode":"auto","accountLabel":"Relay"},
      {"accountID":"33333333-3333-4333-8333-333333333333","kind":"Crof","isEnabled":true,"sortOrder":26,"sourceMode":"auto"},
      {"accountID":"44444444-4444-4444-8444-444444444444","kind":"CrossModel","isEnabled":false,"sortOrder":44,"sourceMode":"api"},
      {"accountID":"55555555-5555-4555-8555-555555555555","kind":"Moonshot","isEnabled":true,"sortOrder":39,"sourceMode":"auto"}
    ]
    """

    func testConfigsAnOlderBuildSavedWithRetiredProvidersStillDecode() throws {
        let configs = try JSONDecoder().decode(
            [ProviderConfig].self,
            from: Data(configsSavedBy156.utf8)
        )
        XCTAssertEqual(configs.map(\.kind), [.codex, .kimiK2, .crof, .crossModel, .moonshot],
                       "one undecodable kind would throw away the whole array, every account with it")
        XCTAssertEqual(configs[1].accountLabel, "Relay")
    }

    func testRetiredAccountsAreLeftOutAndTheNextSaveDropsThem() throws {
        let configs = try JSONDecoder().decode(
            [ProviderConfig].self,
            from: Data(configsSavedBy156.utf8)
        )
        let active = ProviderRoster.activeConfigs(configs)
        XCTAssertEqual(active.map(\.kind), [.codex, .moonshot], "order kept, retired left out")
        XCTAssertEqual(active.map(\.accountID), [configs[0].accountID, configs[4].accountID])

        // What `ProviderConfigMetadataStore.save` writes is what it is given.
        let saved = try JSONEncoder().encode(active)
        let reread = try JSONDecoder().decode([ProviderConfig].self, from: saved)
        XCTAssertEqual(reread.map(\.kind), [.codex, .moonshot])
    }

    func testRetiredNamesInSyncedRowsStillDecode() throws {
        let kinds = try JSONDecoder().decode(
            [ProviderKind].self,
            from: Data(#"["Crof","Kimi K2","CrossModel"]"#.utf8)
        )
        XCTAssertEqual(kinds, [.crof, .kimiK2, .crossModel])

        let account = accountUsage(.crossModel)
        let decoded = try JSONDecoder().decode(
            ProviderAccountUsage.self,
            from: JSONEncoder().encode(account)
        )
        XCTAssertEqual(decoded.provider, .crossModel)
    }

    // MARK: - The roster

    func testExactlyTheThreeAreRetiredForTheirReasons() {
        XCTAssertEqual(Set(ProviderKind.allCases.filter(\.isRetired)), retired)
        XCTAssertEqual(ProviderKind.crof.retirement, .serviceShutDown)
        XCTAssertEqual(ProviderKind.kimiK2.retirement, .unconfirmedOperator)
        XCTAssertEqual(ProviderKind.crossModel.retirement, .unconfirmedOperator)
        // The official ones stay: the notice tells Kimi K2 users so.
        XCTAssertNil(ProviderKind.kimi.retirement)
        XCTAssertNil(ProviderKind.moonshot.retirement)
    }

    func testOfferedIsEveryOtherProviderInCaseOrder() {
        XCTAssertEqual(
            ProviderKind.offered,
            ProviderKind.allCases.filter { !retired.contains($0) }
        )
        XCTAssertEqual(ProviderKind.offered.count, ProviderKind.allCases.count - 3)
    }

    func testANewInstallGetsNoAccountForARetiredProvider() {
        let kinds = ProviderConfig.defaults().map(\.kind)
        XCTAssertEqual(kinds, ProviderKind.offered)
        XCTAssertTrue(retired.isDisjoint(with: kinds))
    }

    #if os(macOS)
    func testNoCollectorIsRegisteredForARetiredProvider() {
        let registered = Set(CollectorRegistry.collectors.map(\.kind))
        XCTAssertTrue(retired.isDisjoint(with: registered),
                      "a registered collector would send the key: \(registered.intersection(retired))")
        // A saved key no longer reaches anything, in the app or the helper.
        for kind in retired {
            XCTAssertNil(CollectorRegistry.collector(
                for: kind,
                config: ProviderConfig(kind: kind, apiKey: "saved-key")
            ))
        }
        // Positive control: an offered API-key provider still collects.
        XCTAssertNotNil(CollectorRegistry.collector(
            for: .moonshot,
            config: ProviderConfig(kind: .moonshot, apiKey: "saved-key")
        ))
    }

    func testTheEnvironmentKeysAreTheOnesTheCollectorsRead() {
        let keys = ProviderRoster.unconfirmedOperatorEnvironmentKeys
        XCTAssertEqual(Set(keys.keys), [.kimiK2, .crossModel])
        XCTAssertEqual(keys[.kimiK2], KimiK2Collector.environmentKeys)
        XCTAssertEqual(keys[.crossModel], [CrossModelCollector.apiKeyEnv])
    }
    #endif

    // MARK: - Rows for display

    func testRetiredRowsAreNotShown() {
        let rows = ["Codex", "Kimi K2", "Crof", "CrossModel", "Moonshot", "Some Future Provider"]
            .map { usage(provider: $0) }
        XCTAssertEqual(
            ProviderRoster.shown(rows).map(\.provider),
            ["Codex", "Moonshot", "Some Future Provider"],
            "a name this build does not know is not retired"
        )
        let accounts = [accountUsage(.codex), accountUsage(.kimiK2), accountUsage(.crof)]
        XCTAssertEqual(ProviderRoster.shown(accounts).map(\.provider), [.codex])
    }

    func testARetiredRowTakesNoPlanSlot() {
        let count = DataRefreshManager.activeProviderCount(
            providers: [usage(provider: "Kimi K2"), usage(provider: "CrossModel"),
                        usage(provider: "Crof"), usage(provider: "Codex")],
            providerConfigs: []
        )
        XCTAssertEqual(count, 1, "only Codex is a provider this build offers")
    }

    // MARK: - Who is owed the notice

    private func config(
        _ kind: ProviderKind,
        key: String? = nil,
        label: String? = nil,
        enabled: Bool = true
    ) -> ProviderConfig {
        ProviderConfig(kind: kind, isEnabled: enabled, apiKey: key, accountLabel: label)
    }

    private func owed(_ configs: [ProviderConfig], environment: [String: String] = [:]) -> Bool {
        ProviderRoster.hadUnconfirmedOperatorSetUp(configs: configs, environment: environment)
    }

    func testTheNoticeIsOwedForASavedKeyToKimiK2OrCrossModel() {
        XCTAssertTrue(owed([config(.kimiK2, key: "k")]))
        XCTAssertTrue(owed([config(.crossModel, key: "k")]))
        // Switched off now, but the person saved a key to it.
        XCTAssertTrue(owed([config(.crossModel, key: "k", enabled: false)]))
    }

    func testTheNoticeIsNotOwedWithoutAKeyToThem() {
        // Every install had a Kimi K2 and a CrossModel account by default.
        XCTAssertFalse(owed(ProviderKind.allCases.map { config($0) }))
        // A name alone sent nothing; the notice is about a key.
        XCTAssertFalse(owed([config(.kimiK2, label: "Work")]))
        XCTAssertFalse(owed([config(.kimiK2, key: "  \n")]))
        // Neither collector read a cookie.
        var cookie = config(.kimiK2)
        cookie.manualCookieHeader = "session=1"
        cookie.cookieSource = .manual
        XCTAssertFalse(owed([cookie]))
        // Crof shut down: removed without a notice.
        XCTAssertFalse(owed([config(.crof, key: "k")]))
        // The official providers are not retired.
        XCTAssertFalse(owed([config(.moonshot, key: "k"), config(.kimi, key: "k")]))
    }

    func testAKeyInTheEnvironmentCountsWhereItsCollectorRan() {
        let readBy: [(ProviderKind, String)] = [
            (.kimiK2, "KIMI_K2_API_KEY"), (.kimiK2, "KIMI_API_KEY"),
            (.kimiK2, "KIMI_KEY"), (.crossModel, "CROSSMODEL_API_KEY"),
        ]
        for (kind, key) in readBy {
            XCTAssertTrue(owed([config(kind)], environment: [key: "sk-1"]), key)
            // A fresh 1.57 install has no such account: nothing ever ran.
            XCTAssertFalse(owed(ProviderConfig.defaults(), environment: [key: "sk-1"]), key)
            // Collectors ran for enabled accounts only.
            XCTAssertFalse(owed([config(kind, enabled: false)], environment: [key: "sk-1"]), key)
        }
        // Each collector read its own variables, not the other's.
        XCTAssertFalse(owed([config(.crossModel)], environment: ["KIMI_API_KEY": "sk-1"]))
        XCTAssertFalse(owed([config(.kimiK2)], environment: ["CROSSMODEL_API_KEY": "sk-1"]))
        XCTAssertFalse(owed([config(.kimiK2)], environment: ["KIMI_K2_API_KEY": "  "]))
        XCTAssertFalse(owed([config(.kimiK2)], environment: ["MOONSHOT_API_KEY": "sk-1"]))
    }

    // MARK: - The notice is shown once

    func testTheNoticeIsRecordedOnceAndStaysDismissed() throws {
        let suite = "ProviderRosterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let notice = RetiredProviderNotice(defaults: defaults)

        XCTAssertFalse(notice.record(owed: false))
        XCTAssertFalse(notice.isPending)

        XCTAssertTrue(notice.record(owed: true))
        XCTAssertTrue(notice.isPending)
        // The next launch no longer has the account (the save dropped it), and
        // the notice is still owed until it is dismissed.
        XCTAssertTrue(notice.record(owed: false))
        XCTAssertTrue(RetiredProviderNotice(defaults: defaults).isPending)

        notice.dismiss()
        XCTAssertFalse(notice.isPending)
        // An account that comes back (a downgrade, a restore) does not bring
        // the notice back.
        XCTAssertFalse(notice.record(owed: true))
        XCTAssertFalse(notice.isPending)
    }

    // MARK: - What a launch keeps, and when it records the notice

    private func noticeDefaults() throws -> UserDefaults {
        let suite = "ProviderRosterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testTheLaunchRecordsTheNoticeFromTheAccountsItThenLeavesOut() throws {
        let defaults = try noticeDefaults()
        let notice = RetiredProviderNotice(defaults: defaults)
        // As read at launch: retired accounts still in, keys loaded.
        let read = [config(.codex), config(.kimiK2, key: "k"),
                    config(.crof), config(.moonshot, key: "m")]

        let kept = ProviderRoster.configsKeptAtLaunch(read, environment: [:], notice: notice)
        XCTAssertEqual(kept.map(\.kind), [.codex, .moonshot], "order kept, retired left out")
        XCTAssertEqual(kept.map(\.accountID), [read[0].accountID, read[3].accountID])
        XCTAssertTrue(notice.isPending,
                      "the Kimi K2 key must be asked about before its account is left out, or the notice is never owed")

        // The next launch reads the list the launch wrote back, without the
        // Kimi K2 account: the notice is still owed until it is dismissed.
        let next = ProviderRoster.configsKeptAtLaunch(kept, environment: [:], notice: notice)
        XCTAssertEqual(next.map(\.kind), [.codex, .moonshot])
        XCTAssertTrue(RetiredProviderNotice(defaults: defaults).isPending)
    }

    func testTheLaunchRecordsNothingWhereNoKeyWasSent() throws {
        let defaults = try noticeDefaults()
        // Every install's untouched default accounts, retired ones included.
        let read = ProviderKind.allCases.map { config($0) }

        let kept = ProviderRoster.configsKeptAtLaunch(
            read, environment: [:], notice: RetiredProviderNotice(defaults: defaults)
        )
        XCTAssertEqual(kept.map(\.kind), ProviderKind.offered)
        XCTAssertNil(defaults.string(forKey: RetiredProviderNotice.stateKey))
    }

    func testWithoutANoticeTheLaunchOnlyLeavesRetiredAccountsOut() {
        // The iPhone: collectors never ran there, so nothing is recorded.
        let kept = ProviderRoster.configsKeptAtLaunch(
            [config(.kimiK2, key: "k"), config(.codex), config(.crossModel, key: "k")],
            environment: ["KIMI_API_KEY": "sk-1"],
            notice: nil
        )
        XCTAssertEqual(kept.map(\.kind), [.codex])
    }

    func testOnceRecordedWhoIsOwedIsNotAskedAgain() throws {
        let notice = RetiredProviderNotice(defaults: try noticeDefaults())
        var asked = 0
        func owed() -> Bool {
            asked += 1
            return true
        }
        XCTAssertTrue(notice.record(owed: owed()))
        XCTAssertEqual(asked, 1, "nothing recorded yet: asked")
        XCTAssertTrue(notice.record(owed: owed()))
        notice.dismiss()
        XCTAssertFalse(notice.record(owed: owed()))
        XCTAssertEqual(asked, 1,
                       "pending or dismissed, no answer changes the notice, so a launch does not ask")
    }

    // MARK: - The notice's words

    func testTheNoticeIsTranslatedAndKeepsTheNamesInEnglish() {
        LocaleOverrideStore.shared.set("en")
        let english = L10n.menuBar.retiredProvidersNotice
        XCTAssertTrue(english.contains("Kimi K2"))
        for language in ["zh-Hans", "zh-Hant", "ja", "ko", "es"] {
            LocaleOverrideStore.shared.set(language)
            let text = L10n.menuBar.retiredProvidersNotice
            XCTAssertNotEqual(text, english, "\(language) shows English")
            XCTAssertNotEqual(text, "menu_bar.retired_providers_notice", "\(language) shows the key")
            for name in ["Kimi K2", "CrossModel", "Kimi", "Moonshot"] {
                XCTAssertTrue(text.contains(name), "\(language) must name \(name) as written")
            }
            let dismiss = L10n.a11y.dismissRetiredProvidersNotice
            XCTAssertTrue(dismiss.contains("Kimi K2") && dismiss.contains("CrossModel"), language)
        }
        LocaleOverrideStore.shared.set("zh-Hans")
        XCTAssertTrue(L10n.menuBar.retiredProvidersNotice.contains("密钥"),
                      "zh-Hans says the key is no longer sent")
    }
}

/// The behaviour behind `ProviderRosterReferenceTests`' display check:
/// rows a refresh brings back for a retired provider never reach the state
/// every Mac and iPhone surface reads (cards, menu bar, widgets, the Watch
/// relay).
@MainActor
final class ProviderRosterStateTests: XCTestCase {
    func testRefreshedRowsForRetiredProvidersNeverReachTheState() {
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
            providers: ["Kimi K2", "Codex", "Crof", "CrossModel"].map(usage(provider:)),
            providerAccounts: [accountUsage(.crossModel), accountUsage(.codex), accountUsage(.kimiK2)],
            sessions: [],
            devices: [],
            alerts: [],
            locallySupplementedProviders: [],
            tierLimitWarning: nil,
            lastRefresh: Date(),
            isLocalMode: false,
            costUsageScanResult: nil
        ))
        XCTAssertEqual(state.providers.map(\.provider), ["Codex"],
                       "provider rows: a device on an older build may upload retired ones")
        XCTAssertEqual(state.providerAccounts.map(\.provider), [.codex],
                       "account rows: a device on an older build may upload retired ones")
    }
}

// MARK: - Fixtures

private func usage(provider: String) -> ProviderUsage {
    ProviderUsage(
        provider: provider,
        today_usage: 5, week_usage: 5,
        estimated_cost_today: 0, estimated_cost_week: 0,
        estimated_cost_30_day: 0,
        cost_status_today: "Estimated", cost_status_week: "Estimated",
        quota: nil, remaining: nil,
        tiers: [], status_text: "",
        trend: [], recent_sessions: [], recent_errors: []
    )
}

private func accountUsage(_ provider: ProviderKind) -> ProviderAccountUsage {
    ProviderAccountUsage(
        id: UUID(),
        provider: provider,
        accountLabel: nil,
        planEvidence: ProviderPlanEvidence(
            rawValue: nil, displayValue: nil, source: .providerAPI,
            confidence: .high, observedAt: Date(timeIntervalSince1970: 1_800_000_000)
        ),
        quota: nil,
        remaining: nil,
        tiers: [],
        resetTime: nil,
        observedAt: nil,
        sourceDeviceID: nil,
        statusText: ""
    )
}
