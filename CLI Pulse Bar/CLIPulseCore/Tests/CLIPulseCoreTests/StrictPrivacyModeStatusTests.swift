#if os(macOS)
import XCTest
@testable import CLIPulseCore

/// v1.55: a provider row says "Not read in Strict privacy mode" when Strict
/// privacy mode stopped the one read it needed, instead of something false.
///
/// Before: a cookie provider set to read its cookie from a browser (Cursor by
/// default) threw its missing-cookie error, shown as "Authentication failed —
/// Reconnect Cursor — its saved credential was rejected", though nothing was
/// sent and nothing rejected. Zed showed "Not set up", though CLI Pulse never
/// looked. `CookieResolver` notes the skip in the run's `StrictPrivacySkipLog`,
/// and both collector drivers read it when the run fails.
final class StrictPrivacyModeStatusTests: XCTestCase {

    override func tearDown() {
        LocaleOverrideStore.shared.set(nil)
        super.tearDown()
    }

    /// A cookie provider as the real ones are written: it asks
    /// `CookieResolver`, and without a cookie throws its own
    /// missing-credential error. With a cookie it fails on the network, so a
    /// test can tell the two apart.
    private struct CookieOnlyCollector: ProviderCollector {
        let kind: ProviderKind = .cursor
        let browserImportAllowed: Bool
        /// What the importer finds when it is allowed to run.
        let importedCookie: String?

        private struct Importer: CookieImporting {
            let cookie: String?
            func importCookieHeader(
                domains: [String],
                knownSessionCookieNames: Set<String>,
                logger: (@Sendable (String) -> Void)?
            ) async -> String? { cookie }
        }

        func isAvailable(config: ProviderConfig) -> Bool { true }

        func collect(config: ProviderConfig) async throws -> CollectorResult {
            let resolution = await CookieResolver.resolve(
                config: config,
                envVarNames: [],
                domains: ["cursor.com"],
                knownSessionCookieNames: [],
                importer: Importer(cookie: importedCookie),
                browserImportAllowed: browserImportAllowed
            )
            guard resolution.headerValue != nil else {
                throw CollectorError.missingCredentials(CredentialProblem("Cursor", .noSessionCookieImportable))
            }
            throw URLError(.notConnectedToInternet)
        }
    }

    /// Skips a cookie under Strict privacy mode, then fails on something that
    /// has nothing to do with it (a provider with a second credential path).
    private struct SkipsThenNetworkFails: ProviderCollector {
        let kind: ProviderKind = .minimax
        func isAvailable(config: ProviderConfig) -> Bool { true }
        func collect(config: ProviderConfig) async throws -> CollectorResult {
            _ = await CookieResolver.resolve(
                config: config,
                envVarNames: [],
                domains: ["minimax.example"],
                knownSessionCookieNames: [],
                importer: NullCookieImporter(),
                browserImportAllowed: false
            )
            throw URLError(.notConnectedToInternet)
        }
    }

    private var automatic: ProviderConfig {
        ProviderConfig(kind: .cursor, cookieSource: .automatic)
    }

    private func runOnce(_ collector: ProviderCollector, config: ProviderConfig) async -> CollectorOutcome {
        let runs = await CollectorRunner.run(
            configs: [config],
            maxConcurrent: 1,
            collectorResolver: { _ in collector },
            execute: { config, collector in
                do { return .success(try await collector.collect(config: config)) } catch { return .failure(error) }
            }
        )
        return runs.first?.outcome ?? .disabled
    }

    // MARK: - the rule

    func test_aCredentialFailureAfterAStrictSkip_isReportedAsTheSkip() {
        let missing = CollectorError.missingCredentials(CredentialProblem("Cursor", .noSessionCookieImportable))
        XCTAssertEqual(CollectorRunner.failureOutcome(missing, strictPrivacySkips: [.browserCookies]),
                       .notReady(.strictPrivacyModeCookies))
        // Negative control: the same error with nothing skipped is what it was.
        XCTAssertEqual(CollectorRunner.failureOutcome(missing, strictPrivacySkips: []), .failed(.auth))
    }

    func test_aFailureOfAnotherKind_keepsItsOwnCategory() {
        // A network error in a run that also skipped a cookie is still a
        // network error: Strict privacy mode did not cause it.
        XCTAssertEqual(CollectorRunner.failureOutcome(URLError(.timedOut), strictPrivacySkips: [.browserCookies]),
                       .failed(.network))
    }

    func test_aCollectorThatSaysSoItself_isReportedAsTheSkip() {
        let zed = StrictPrivacyModeSkipped(.keychainItem, provider: "Zed")
        XCTAssertEqual(CollectorRunner.failureOutcome(zed, strictPrivacySkips: []),
                       .notReady(.strictPrivacyModeKeychain))
        XCTAssertEqual(CollectorRunner.strictPrivacySkip(causing: zed, strictPrivacySkips: []), .keychainItem)
        XCTAssertNil(CollectorRunner.strictPrivacySkip(causing: URLError(.timedOut), strictPrivacySkips: [.browserCookies]))
    }

    // MARK: - through the drivers

    func test_theRunner_reportsACookieProviderUnderStrictPrivacyMode() async {
        let outcome = await runOnce(CookieOnlyCollector(browserImportAllowed: false, importedCookie: "a=1"),
                                    config: automatic)
        XCTAssertEqual(outcome, .notReady(.strictPrivacyModeCookies))
    }

    func test_theRunner_withoutStrictPrivacyMode_isUnchanged() async {
        // Negative controls: allowed and nothing found is still a credential
        // failure; allowed and found runs on to the network.
        let nothing = await runOnce(CookieOnlyCollector(browserImportAllowed: true, importedCookie: nil),
                                    config: automatic)
        XCTAssertEqual(nothing, .failed(.auth))
        let found = await runOnce(CookieOnlyCollector(browserImportAllowed: true, importedCookie: "a=1"),
                                  config: automatic)
        XCTAssertEqual(found, .failed(.network))
    }

    func test_theRunner_withAPastedCookie_isUnchanged() async {
        // Strict privacy mode leaves a cookie the user pasted alone.
        var config = automatic
        config.manualCookieHeader = "a=1"
        let outcome = await runOnce(CookieOnlyCollector(browserImportAllowed: false, importedCookie: nil),
                                    config: config)
        XCTAssertEqual(outcome, .failed(.network))
    }

    func test_theRunner_keepsANetworkFailureAfterASkip() async {
        let outcome = await runOnce(SkipsThenNetworkFails(), config: ProviderConfig(kind: .minimax, cookieSource: .automatic))
        XCTAssertEqual(outcome, .failed(.network))
    }

    func test_concurrentRuns_keepTheirOwnSkips() async {
        // Each run binds its own log: a skip in one must not turn another
        // run's credential failure into a Strict privacy mode row.
        let strict = CookieOnlyCollector(browserImportAllowed: false, importedCookie: "a=1")
        let allowed = CookieOnlyCollector(browserImportAllowed: true, importedCookie: nil)
        let configs = (0..<8).map { index in
            ProviderConfig(
                kind: .cursor,
                accountID: UUID(),
                cookieSource: .automatic,
                accountLabel: index.isMultiple(of: 2) ? "strict" : "allowed"
            )
        }
        let runs = await CollectorRunner.run(
            configs: configs,
            maxConcurrent: 8,
            collectorResolver: { config in config.accountLabel == "strict" ? strict : allowed },
            execute: { config, collector in
                do { return .success(try await collector.collect(config: config)) } catch { return .failure(error) }
            }
        )
        XCTAssertEqual(runs.count, 8)
        XCTAssertEqual(runs.filter { $0.outcome == .notReady(.strictPrivacyModeCookies) }.count, 4)
        XCTAssertEqual(runs.filter { $0.outcome == .failed(.auth) }.count, 4)
    }

    func test_theAppsRefresh_reportsACookieProviderUnderStrictPrivacyMode() async {
        // The driver the app's refresh uses.
        let strict = await DataRefreshManager.runOneCollectorWithOutcome(
            config: automatic,
            collector: CookieOnlyCollector(browserImportAllowed: false, importedCookie: "a=1")
        )
        XCTAssertEqual(strict.outcome, .notReady(.strictPrivacyModeCookies))
        // Negative control.
        let allowed = await DataRefreshManager.runOneCollectorWithOutcome(
            config: automatic,
            collector: CookieOnlyCollector(browserImportAllowed: true, importedCookie: nil)
        )
        XCTAssertEqual(allowed.outcome, .failed(.auth))
    }

    func test_outsideARun_aSkipIsNotedNowhere() {
        // The resolver may be called with no log bound (a Test button before
        // this change, a future caller): nothing breaks, nothing is kept.
        XCTAssertNil(StrictPrivacySkipLog.current)
        StrictPrivacySkipLog.note(.browserCookies)
        let log = StrictPrivacySkipLog()
        StrictPrivacySkipLog.$current.withValue(log) {
            StrictPrivacySkipLog.note(.browserCookies)
            StrictPrivacySkipLog.note(.browserCookies)
            StrictPrivacySkipLog.note(.keychainItem)
        }
        XCTAssertEqual(log.skips, [.browserCookies, .keychainItem])
    }

    // MARK: - what the row says

    func test_theRow_namesTheSwitchAndTheProviderInEveryLanguage() {
        for localization in LocaleOverrideStore.shippedLocalizations {
            LocaleOverrideStore.shared.set(localization)
            let switchName = L10n.settings.localOnlyMode
            let rows: [(CollectorNotReadyReason, String)] = [
                (.strictPrivacyModeCookies, "Cursor"),
                (.strictPrivacyModeKeychain, "Zed"),
            ]
            for (reason, provider) in rows {
                let shown = CollectorOutcomePresentation.of(.notReady(reason), providerName: provider)
                XCTAssertEqual(shown.severity, .normal, "\(localization): the user chose this")
                XCTAssertTrue(shown.label.localizedCaseInsensitiveContains(switchName),
                              "\(localization): \(shown.label) does not name \(switchName)")
                let hint = shown.nextStep ?? ""
                XCTAssertTrue(hint.contains(provider), "\(localization): \(hint)")
                XCTAssertTrue(hint.localizedCaseInsensitiveContains(switchName), "\(localization): \(hint)")
                XCTAssertTrue(hint.contains(L10n.settings.privacy), "\(localization): \(hint)")
                XCTAssertFalse(hint.hasPrefix("collector_status."), "\(localization) renders the raw key")
                // Not the words it replaces.
                XCTAssertNotEqual(shown.label, L10n.collectorStatus.authFailed, localization)
                XCTAssertNotEqual(shown.label, L10n.collectorStatus.notSetUp, localization)
            }
            let cookieHint = L10n.collectorStatus.strictPrivacyModeCookieHint("Cursor")
            XCTAssertTrue(cookieHint.contains(L10n.providerConfig.cookieSource), "\(localization): \(cookieHint)")
            XCTAssertTrue(cookieHint.contains(L10n.providerConfig.cookieSourceManual), "\(localization): \(cookieHint)")
            // The Test button's error says what the row says.
            XCTAssertEqual(StrictPrivacyModeSkipped(.browserCookies, provider: "Cursor").localizedDescription,
                           cookieHint, localization)
            XCTAssertEqual(StrictPrivacyModeSkipped(.keychainItem, provider: "Zed").localizedDescription,
                           L10n.collectorStatus.strictPrivacyModeKeychainHint("Zed"), localization)
            // The editor's note under "Automatic" names the switch too.
            XCTAssertTrue(L10n.providerConfig.autoImportNoteStrict.localizedCaseInsensitiveContains(switchName),
                          "\(localization): \(L10n.providerConfig.autoImportNoteStrict)")
            XCTAssertNotEqual(L10n.providerConfig.autoImportNoteStrict, L10n.providerConfig.autoImportNote, localization)
        }
    }

    func test_eachReasonHasItsOwnTelemetryToken() {
        XCTAssertEqual(CollectorOutcome.notReady(.strictPrivacyModeCookies).telemetryToken, "not_ready_strict_cookies")
        XCTAssertEqual(CollectorOutcome.notReady(.strictPrivacyModeKeychain).telemetryToken, "not_ready_strict_keychain")
    }
}
#endif
