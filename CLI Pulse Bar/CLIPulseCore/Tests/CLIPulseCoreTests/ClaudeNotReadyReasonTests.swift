#if os(macOS)
import Security
import XCTest
@testable import CLIPulseCore

/// 1.59 (59-15 F2 + F6): Claude says why it is not ready, and a declined
/// keychain dialog is not asked again every refresh.
///
/// Before, every empty token was `.notReady(.unknown)` ("Not set up — Open
/// Settings to connect this provider"), and in the field every device that
/// reported Claude said `not_ready_unknown`, including those where Codex was
/// `ok`. Each row of the mapping is pinned here with its own fixture, through
/// injected sources: no test reads this Mac's environment, its
/// `~/.claude/.credentials.json`, or Claude Code's real keychain item (a test
/// binary is not in the item's access list, so macOS would show a dialog
/// nobody answers and the suite would hang).
final class ClaudeNotReadyReasonTests: XCTestCase {

    private var now = Date(timeIntervalSinceReferenceDate: 2_000_000)
    private var cooldownSuite: String!
    private var ownerSuite: String!
    private var ownerDefaults: UserDefaults!
    private var privacySuites: [String] = []
    private var originalOwnerDefaults: UserDefaults?
    private var originalSynchronize: ((UserDefaults) -> Bool)!
    private var originalMutationLock: GeminiCredentialMutationLock!
    private var mutationLockPath: String!
    private var savedLocaleOverride: String?

    /// What the injected `SecItemCopyMatching` answers, and how often it was asked.
    private var keychainAnswer: (OSStatus, CFTypeRef?) = (errSecItemNotFound, nil)
    private var keychainReads = 0

    private let accountID = UUID(uuidString: "5E5E5E5E-0000-4000-8000-000000000159")!

    override func setUp() {
        super.setUp()
        cooldownSuite = "test.claude-not-ready.cooldown.\(UUID().uuidString)"
        ClaudeCredentials.cooldownDefaults = UserDefaults(suiteName: cooldownSuite)!
        ClaudeCredentials.nowProvider = { [weak self] in self?.now ?? Date() }
        ClaudeCredentials.keychainReadCooldownInterval = 30 * 60
        ClaudeCredentials.clearKeychainReadCooldown()
        ClaudeCredentials.clearCachedKeychainCredentials()
        keychainReads = 0
        keychainAnswer = (errSecItemNotFound, nil)
        ClaudeCredentials.copyKeychainItem = { [weak self] _ in
            guard let self else { return (errSecItemNotFound, nil) }
            self.keychainReads += 1
            return self.keychainAnswer
        }

        // `resolveTokenDetails` claims the machine's login for the entry
        // before it reads anything; keep that claim out of the real app group.
        originalOwnerDefaults = ProviderSharedCredentialOwner.defaults
        originalSynchronize = ProviderSharedCredentialOwner.synchronizeDefaults
        originalMutationLock = ProviderSharedCredentialOwner.mutationLock
        ownerSuite = "test.claude-not-ready.owner.\(UUID().uuidString)"
        ownerDefaults = UserDefaults(suiteName: ownerSuite)!
        ProviderSharedCredentialOwner.defaults = ownerDefaults
        ProviderSharedCredentialOwner.synchronizeDefaults = { _ in true }
        mutationLockPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(ownerSuite!).lock").path
        ProviderSharedCredentialOwner.mutationLock = GeminiCredentialMutationLock(lockFilePath: mutationLockPath)

        savedLocaleOverride = LocaleOverrideStore.shared.override
    }

    override func tearDown() {
        LocaleOverrideStore.shared.set(savedLocaleOverride)
        // A successful read cached its token; no other test may find it.
        ClaudeCredentials.clearCachedKeychainCredentials()
        ClaudeCredentials.copyKeychainItem = { query in
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query, &item)
            return (status, item)
        }
        ClaudeCredentials.nowProvider = { Date() }
        ClaudeCredentials.cooldownDefaults = UserDefaults(suiteName: "group.yyh.CLI-Pulse") ?? .standard
        UserDefaults().removePersistentDomain(forName: cooldownSuite)
        ProviderSharedCredentialOwner.defaults = originalOwnerDefaults
        ProviderSharedCredentialOwner.synchronizeDefaults = originalSynchronize
        ProviderSharedCredentialOwner.mutationLock = originalMutationLock
        ownerDefaults.removePersistentDomain(forName: ownerSuite)
        try? FileManager.default.removeItem(atPath: mutationLockPath)
        for suite in privacySuites { UserDefaults().removePersistentDomain(forName: suite) }
        super.tearDown()
    }

    // MARK: - Helpers

    private func privacy(strict: Bool = false, skip: Bool = false) -> PrivacySettings {
        let suite = "test.claude-not-ready.privacy.\(UUID().uuidString)"
        privacySuites.append(suite)
        let settings = PrivacySettings(defaults: UserDefaults(suiteName: suite)!)
        settings.skipClaudeKeychain = skip
        settings.localOnlyMode = strict
        return settings
    }

    private func reason(
        _ absence: ClaudeTokenAbsence?,
        sandboxed: Bool = false,
        claudeFolder: Bool = false
    ) -> CollectorNotReadyReason {
        ClaudeNotReadyDiagnosis.reason(
            for: absence, isSandboxed: sandboxed, claudeConfigDirectoryExists: { claudeFolder })
    }

    private func credentialsJSON(token: String = "sk-ant-oat01-fixture") -> CFData {
        Data(#"{"claudeAiOauth":{"accessToken":"\#(token)","rateLimitTier":"default_claude_max_5x"}}"#.utf8) as CFData
    }

    /// The background read the token resolver makes, with Settings › Privacy's
    /// switches as given, and what it noted.
    private func backgroundRead(_ settings: PrivacySettings? = nil) -> ClaudeKeychainLookup {
        ClaudeCredentials.readKeychainForTokenResolver(privacy: settings ?? privacy())
    }

    private func miss(_ lookup: ClaudeKeychainLookup) -> ClaudeKeychainMiss? {
        if case .missing(let miss) = lookup { return miss }
        return nil
    }

    /// A strategy that decides availability exactly as `ClaudeOAuthStrategy`
    /// does (a token from `resolveTokenDetails`), from injected sources.
    private struct InjectedTokenStrategy: ClaudeSourceStrategy {
        let sourceLabel = "oauth-fixture"
        let sourceType: SourceType = .oauth
        let keychain: @Sendable () -> ClaudeKeychainLookup
        func isAvailable(config: ProviderConfig) -> Bool {
            !ClaudeCredentials.resolveTokenDetails(
                config: config, environment: [:], credentialsFile: { nil }, keychain: keychain
            ).token.isEmpty
        }
        func fetch(config: ProviderConfig) async throws -> ClaudeSnapshot {
            throw ClaudeStrategyError.noToken
        }
    }

    // MARK: - The mapping, one fixture per row (firstrun.md §4)

    func test_disconnectedEntry_isNotConnected_notUnknown() {
        XCTAssertEqual(reason(.fallbackDisabled), .notConnected)
    }

    func test_ownerRecordThatCannotBeRead_staysUnknown() {
        XCTAssertEqual(reason(.sharedLoginNotClaimed), .unknown)
    }

    func test_strictPrivacyMode_isItsOwnReason() {
        XCTAssertEqual(reason(.keychain(.skipped(.skippedStrictPrivacyMode))), .strictPrivacyModeKeychain)
    }

    func test_skipSwitchAlone_isNotConnected_notStrictPrivacyMode() {
        // The Strict privacy mode hint says to turn that mode off; it is off.
        XCTAssertEqual(reason(.keychain(.skipped(.skippedBySetting))), .notConnected)
    }

    func test_helperWithoutTheAppsCopyOfTheSwitches_staysUnknown() {
        XCTAssertEqual(reason(.keychain(.skipped(.skippedAwaitingApp))), .unknown)
    }

    func test_cooldownAfterARejectedToken_isMissingCredentials() {
        XCTAssertEqual(reason(.keychain(.onCooldown(.rejectedToken))), .missingCredentials)
    }

    func test_cooldownAfterADeclinedDialog_isKeychainDenied() {
        XCTAssertEqual(reason(.keychain(.onCooldown(.declined))), .keychainDenied)
    }

    func test_noItem_withClaudeFolderVisible_isMissingCredentials() {
        XCTAssertEqual(reason(.keychain(.status(errSecItemNotFound)), claudeFolder: true), .missingCredentials)
    }

    func test_noItem_noClaudeFolder_unsandboxed_isNotInstalled() {
        XCTAssertEqual(reason(.keychain(.status(errSecItemNotFound)), claudeFolder: false), .notInstalled)
    }

    func test_noItem_sandboxed_isMissingCredentials_andNeverNotInstalled() {
        var asked = false
        let shown = ClaudeNotReadyDiagnosis.reason(
            for: .keychain(.status(errSecItemNotFound)),
            isSandboxed: true,
            claudeConfigDirectoryExists: { asked = true; return false })
        XCTAssertEqual(shown, .missingCredentials,
                       "the keychain's answer does not depend on the sandbox")
        XCTAssertFalse(asked, "a sandboxed build cannot see ~/.claude, so it must not ask")
    }

    func test_deniedOrCancelledDialog_isKeychainDenied() {
        XCTAssertEqual(reason(.keychain(.status(errSecAuthFailed))), .keychainDenied)
        XCTAssertEqual(reason(.keychain(.status(errSecUserCanceled))), .keychainDenied)
    }

    func test_noDialogPossibleOrAnyOtherStatus_staysUnknown() {
        XCTAssertEqual(reason(.keychain(.status(errSecInteractionNotAllowed))), .unknown)
        XCTAssertEqual(reason(.keychain(.status(errSecMissingEntitlement))), .unknown)
        XCTAssertEqual(reason(.keychain(.unreadable)), .unknown)
        XCTAssertEqual(reason(nil), .unknown)
    }

    // MARK: - The keychain read keeps its OSStatus, and F6

    func test_declinedRead_armsTheCooldown_andTheNextBackgroundReadDoesNotAsk() {
        keychainAnswer = (errSecAuthFailed, nil)
        XCTAssertEqual(miss(backgroundRead()), .status(errSecAuthFailed))
        XCTAssertEqual(keychainReads, 1)
        XCTAssertEqual(ClaudeCredentials.activeKeychainReadCooldown(), .declined)

        // The next refresh, minutes later: no second dialog, and still the reason.
        now = now.addingTimeInterval(4 * 60)
        XCTAssertEqual(miss(backgroundRead()), .onCooldown(.declined))
        XCTAssertEqual(keychainReads, 1, "a declined dialog came back on the next refresh")
    }

    func test_cancelledDialog_armsTheCooldownToo() {
        keychainAnswer = (errSecUserCanceled, nil)
        XCTAssertEqual(miss(backgroundRead()), .status(errSecUserCanceled))
        XCTAssertEqual(ClaudeCredentials.activeKeychainReadCooldown(), .declined)
    }

    func test_declinedCooldownEnds_andMacOSAsksAgain() {
        keychainAnswer = (errSecAuthFailed, nil)
        _ = backgroundRead()
        now = now.addingTimeInterval(30 * 60 + 1)
        XCTAssertNil(ClaudeCredentials.activeKeychainReadCooldown())
        XCTAssertNil(ClaudeCredentials.cooldownDefaults.string(forKey: ClaudeCredentials.keychainReadCooldownCauseKey),
                     "an expired cooldown left its cause behind")
        keychainAnswer = (errSecSuccess, credentialsJSON())
        guard case .found(let creds) = backgroundRead() else {
            return XCTFail("after the cooldown the item is read again")
        }
        XCTAssertEqual(creds.accessToken, "sk-ant-oat01-fixture")
        XCTAssertEqual(keychainReads, 2)
    }

    func test_noItemOrNoDialogPossible_doesNotArmTheCooldown() {
        for status in [errSecItemNotFound, errSecInteractionNotAllowed] {
            ClaudeCredentials.clearKeychainReadCooldown()
            keychainAnswer = (status, nil)
            XCTAssertEqual(miss(backgroundRead()), .status(status))
            XCTAssertNil(ClaudeCredentials.activeKeychainReadCooldown(),
                         "\(status) is not the user saying no; the next refresh may read again")
        }
    }

    func test_successfulRead_clearsADeclinedCooldown() {
        ClaudeCredentials.installKeychainReadCooldown(cause: .declined)
        keychainAnswer = (errSecSuccess, credentialsJSON())
        // The Connect button's read: the user asked, so the cooldown does not stop it.
        XCTAssertNotNil(ClaudeCredentials.readKeychainCredentials(bypassCooldown: true, cacheResult: false))
        XCTAssertEqual(keychainReads, 1)
        XCTAssertNil(ClaudeCredentials.activeKeychainReadCooldown())
    }

    func test_itemWithoutAToken_isUnreadable_notArmed() {
        keychainAnswer = (errSecSuccess, Data("not json".utf8) as CFData)
        XCTAssertEqual(miss(backgroundRead()), .unreadable)
        XCTAssertNil(ClaudeCredentials.activeKeychainReadCooldown())
    }

    func test_rejectedTokenCooldown_keepsItsCause_andAnOldOneWithoutACauseReadsAsRejected() {
        ClaudeCredentials.installKeychainReadCooldown(cause: .rejectedToken)
        XCTAssertEqual(miss(backgroundRead()), .onCooldown(.rejectedToken))
        // Armed by a build from before 1.59: an end time and no cause.
        ClaudeCredentials.cooldownDefaults.removeObject(forKey: ClaudeCredentials.keychainReadCooldownCauseKey)
        XCTAssertEqual(ClaudeCredentials.activeKeychainReadCooldown(), .rejectedToken)
        XCTAssertEqual(keychainReads, 0)
    }

    func test_privacySwitches_skipTheRead_andSayWhichOne() {
        XCTAssertEqual(miss(backgroundRead(privacy(strict: true))), .skipped(.skippedStrictPrivacyMode))
        XCTAssertEqual(miss(backgroundRead(privacy(skip: true))), .skipped(.skippedBySetting))
        XCTAssertEqual(keychainReads, 0, "a switch that says skip must not read")
    }

    // MARK: - The resolver says where it stopped

    func test_resolver_disconnectedEntry_readsNothing() {
        var asked = 0
        let resolved = ClaudeCredentials.resolveTokenDetails(
            config: ProviderConfig(kind: .claude, accountID: accountID, sharedCredentialFallbackDisabled: true),
            environment: [:], credentialsFile: { nil },
            keychain: { asked += 1; return .missing(.status(errSecItemNotFound)) })
        XCTAssertEqual(resolved.token, "")
        XCTAssertEqual(resolved.absence, .fallbackDisabled)
        XCTAssertEqual(asked, 0)
    }

    func test_resolver_tokenFromTheFileOrTheEnvironment_hasNoAbsence() {
        let fromFile = ClaudeCredentials.resolveTokenDetails(
            config: ProviderConfig(kind: .claude, accountID: accountID),
            environment: [:],
            credentialsFile: { ClaudeCredentials.Creds(accessToken: "sk-ant-oat01-file", rateLimitTier: nil) },
            keychain: { XCTFail("the file answered first"); return .missing(.unreadable) })
        XCTAssertEqual(fromFile.source, .sharedCredentialsFile)
        XCTAssertNil(fromFile.absence)

        let fromEnvironment = ClaudeCredentials.resolveTokenDetails(
            config: ProviderConfig(kind: .claude, accountID: accountID),
            environment: ["CLAUDE_CODE_OAUTH_TOKEN": "sk-ant-oat01-env"],
            credentialsFile: { nil },
            keychain: { XCTFail("the environment answered first"); return .missing(.unreadable) })
        XCTAssertEqual(fromEnvironment.source, .sharedEnvironment)
        XCTAssertNil(fromEnvironment.absence)
    }

    func test_resolver_keychainMiss_isTheAbsence_andIsNotedForReadiness() {
        let log = ClaudeTokenResolutionLog()
        let resolved = ClaudeTokenResolutionLog.$current.withValue(log) {
            ClaudeCredentials.resolveTokenDetails(
                config: ProviderConfig(kind: .claude, accountID: accountID),
                environment: [:], credentialsFile: { nil },
                keychain: { .missing(.status(errSecAuthFailed)) })
        }
        XCTAssertEqual(resolved.absence, .keychain(.status(errSecAuthFailed)))
        XCTAssertEqual(log.absence, .keychain(.status(errSecAuthFailed)))
    }

    // MARK: - readiness, through the collector

    func test_readiness_namesTheReason_fromItsOwnSingleRead() {
        let cases: [(ClaudeKeychainLookup, CollectorNotReadyReason)] = [
            (.missing(.status(errSecAuthFailed)), .keychainDenied),
            (.missing(.onCooldown(.declined)), .keychainDenied),
            (.missing(.skipped(.skippedStrictPrivacyMode)), .strictPrivacyModeKeychain),
            (.missing(.skipped(.skippedBySetting)), .notConnected),
            (.missing(.onCooldown(.rejectedToken)), .missingCredentials),
            (.missing(.status(errSecInteractionNotAllowed)), .unknown),
        ]
        for (lookup, expected) in cases {
            let reads = Counter()
            let collector = ClaudeCollector(resolver: ClaudeSourceResolver(strategies: [
                InjectedTokenStrategy(keychain: { reads.add(); return lookup }),
            ]))
            let readiness = collector.readiness(config: ProviderConfig(kind: .claude, accountID: accountID))
            XCTAssertEqual(readiness, .notReady(expected), "\(lookup)")
            XCTAssertEqual(reads.value, 1,
                           "readiness asked the keychain \(reads.value) times; a second read shows a second dialog")
        }
    }

    func test_readiness_disconnectedEntry_isNotConnected() {
        let collector = ClaudeCollector(resolver: ClaudeSourceResolver(strategies: [
            InjectedTokenStrategy(keychain: { .missing(.unreadable) }),
        ]))
        let config = ProviderConfig(kind: .claude, accountID: accountID, sharedCredentialFallbackDisabled: true)
        XCTAssertEqual(collector.readiness(config: config), .notReady(.notConnected))
    }

    func test_readiness_withAToken_isReady() {
        let collector = ClaudeCollector(resolver: ClaudeSourceResolver(strategies: [
            InjectedTokenStrategy(keychain: {
                .found(ClaudeCredentials.Creds(accessToken: "sk-ant-oat01-kc", rateLimitTier: nil))
            }),
        ]))
        XCTAssertEqual(collector.readiness(config: ProviderConfig(kind: .claude, accountID: accountID)), .ready)
    }

    func test_theOAuthStrategyStillDecidesThroughTheResolver() throws {
        // `readiness` learns the reason from the resolution its own
        // `isAvailable` makes. That only holds while the OAuth strategy asks
        // `resolveTokenDetails`; a strategy that found its token some other
        // way would leave every row at "Not set up" again.
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/CLIPulseCore/Collectors/Claude/ClaudeOAuthStrategy.swift"),
            encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "public func isAvailable(config: ProviderConfig) -> Bool {"))
        XCTAssertTrue(source[start.upperBound...].prefix(160).contains("ClaudeCredentials.resolveTokenDetails("))
    }

    // MARK: - What the user reads (asserted in Chinese: an English fallback would pass in English)

    /// The phrase each language's macOS dialog uses for its button, as the
    /// Connect button's hint (`provider_config.claude_keychain_hint`) writes it.
    private static let alwaysAllow: [String: String] = [
        "en": "Always Allow",
        "zh-Hans": "「始终允许」",
        "zh-Hant": "「永遠允許」",
        "ja": "「常に許可」",
        "ko": "'항상 허용'",
        "es": "«Permitir siempre»",
    ]

    func test_declinedRow_inChinese() {
        LocaleOverrideStore.shared.set("zh-Hans")
        let shown = CollectorOutcomePresentation.of(.notReady(.keychainDenied), providerName: "Claude")
        XCTAssertEqual(shown.label, "已拒绝钥匙串访问")
        // L10n keeps "CLI Pulse" on one line (U+00A0) at lookup.
        XCTAssertEqual(shown.nextStep,
                       "macOS 稍后会再次询问。请点按「始终允许」，让 CLI\u{00A0}Pulse 读取你的 Claude Code 登录信息。")
        XCTAssertEqual(shown.severity, .attention)
        XCTAssertNotEqual(shown.label, L10n.collectorStatus.notSetUp)
    }

    func test_declinedRow_inEveryLanguage_namesTheDialogsButtonAndClaudeCode() {
        XCTAssertEqual(Set(Self.alwaysAllow.keys), Set(LocaleOverrideStore.shippedLocalizations))
        for localization in LocaleOverrideStore.shippedLocalizations {
            LocaleOverrideStore.shared.set(localization)
            let shown = CollectorOutcomePresentation.of(.notReady(.keychainDenied), providerName: "Claude")
            let hint = shown.nextStep ?? ""
            let button = Self.alwaysAllow[localization] ?? "?"
            XCTAssertFalse(shown.label.hasPrefix("collector_status."), "\(localization) renders the raw key")
            XCTAssertTrue(hint.contains(button), "\(localization): \(hint)")
            XCTAssertTrue(L10n.providerConfig.claudeKeychainHint.contains(button),
                          "\(localization): the Connect button's hint names the button differently")
            XCTAssertTrue(hint.contains("Claude Code"), "\(localization): \(hint)")
            XCTAssertTrue(hint.contains("CLI\u{00A0}Pulse"), "\(localization): \(hint)")
            if localization != "en" {
                LocaleOverrideStore.shared.set("en")
                let english = CollectorOutcomePresentation.of(.notReady(.keychainDenied), providerName: "Claude")
                XCTAssertNotEqual(shown.label, english.label, "\(localization) shows English")
                XCTAssertNotEqual(hint, english.nextStep, "\(localization) shows English")
            }
        }
    }

    func test_notConnected_readsLikeNotSetUp_inChinese() {
        LocaleOverrideStore.shared.set("zh-Hans")
        let shown = CollectorOutcomePresentation.of(.notReady(.notConnected), providerName: "Claude")
        XCTAssertEqual(shown, CollectorOutcomePresentation.of(.notReady(.unknown), providerName: "Claude"))
        XCTAssertEqual(shown.label, "未配置")
    }

    func test_newReasons_haveTheirOwnTelemetryTokens() {
        XCTAssertEqual(CollectorOutcome.notReady(.keychainDenied).telemetryToken, "not_ready_kc_denied")
        XCTAssertEqual(CollectorOutcome.notReady(.notConnected).telemetryToken, "not_ready_not_connected")
    }
}

/// A count a `@Sendable` closure can bump.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
#endif
