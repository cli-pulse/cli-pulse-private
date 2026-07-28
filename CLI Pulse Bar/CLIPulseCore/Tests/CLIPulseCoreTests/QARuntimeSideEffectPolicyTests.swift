import Foundation
import XCTest
@testable import CLIPulseCore

final class QARuntimeSideEffectPolicyTests: XCTestCase {
    private static let qaRoot = "/private/tmp/clipulse-qa-home"

    @MainActor
    func testAppStateRetainsExactZeroArgumentInitializer() {
        let factory: () -> AppState = AppState.init
        _ = factory
    }

    func testLocalModeStrategyIsDemoForQALiveForProductionAndDisabledForQuarantine() {
        XCTAssertEqual(
            RuntimeExperiencePolicy.localModeStrategy(
                for: makeRuntime(
                    channel: "qa",
                    bundleIdentifier: "app.clipulse.qa.local",
                    fixedUserHome: Self.qaRoot
                )
            ),
            .inMemoryDemo
        )
        XCTAssertEqual(
            RuntimeExperiencePolicy.localModeStrategy(
                for: makeRuntime(
                    channel: nil,
                    bundleIdentifier: "yyh.CLI-Pulse"
                )
            ),
            .liveCollection
        )
        XCTAssertEqual(
            RuntimeExperiencePolicy.localModeStrategy(
                for: makeRuntime(
                    channel: nil,
                    bundleIdentifier: "com.example.clipulse"
                )
            ),
            .disabled
        )
    }

    func testDemoResumeRequiresSafeQAAndPersistedDemoFlag() {
        let qa = makeRuntime(
            channel: "qa",
            bundleIdentifier: "app.clipulse.qa.local",
            fixedUserHome: Self.qaRoot
        )
        let production = makeRuntime(
            channel: nil,
            bundleIdentifier: "yyh.CLI-Pulse"
        )
        let quarantine = makeRuntime(
            channel: nil,
            bundleIdentifier: "com.example.clipulse"
        )

        XCTAssertTrue(
            RuntimeExperiencePolicy.shouldSynchronouslyResumeDemo(
                runtimeEnvironment: qa,
                persistedIsDemoMode: true
            )
        )
        XCTAssertFalse(
            RuntimeExperiencePolicy.shouldSynchronouslyResumeDemo(
                runtimeEnvironment: qa,
                persistedIsDemoMode: false
            )
        )
        XCTAssertFalse(
            RuntimeExperiencePolicy.shouldSynchronouslyResumeDemo(
                runtimeEnvironment: production,
                persistedIsDemoMode: true
            )
        )
        XCTAssertFalse(
            RuntimeExperiencePolicy.shouldSynchronouslyResumeDemo(
                runtimeEnvironment: quarantine,
                persistedIsDemoMode: true
            )
        )
    }

    @MainActor
    func testSafeQAContinueWithoutAccountEntersInMemoryDemo() throws {
        let fixture = try makeDefaults()
        defer {
            fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
        }
        let state = AppState(
            runtimeEnvironment: makeRuntime(
                channel: "qa",
                bundleIdentifier: "app.clipulse.qa.local",
                fixedUserHome: Self.qaRoot
            ),
            defaults: fixture.defaults
        )

        XCTAssertFalse(state.isDemoMode)
        state.continueWithoutAccount()

        XCTAssertTrue(state.isDemoMode)
        XCTAssertTrue(state.isLocalMode)
        XCTAssertTrue(state.isAuthenticated)
        XCTAssertTrue(state.isPaired)
        XCTAssertTrue(state.serverOnline)
        XCTAssertEqual(state.selectedTab, .overview)
        XCTAssertFalse(state.providers.isEmpty)
        XCTAssertEqual(state.subscriptionManager.currentTier, .team)
        XCTAssertNil(state.lastPublishedWidgetData)
    }

    @MainActor
    func testSafeQAMetadataSaveWritesOnlyIsolatedAppDefaults() throws {
        let appFixture = try makeDefaults()
        let helperFixture = try makeDefaults()
        let helperDefaults = helperFixture.defaults
        let originalOwnerDefaults = ProviderSharedCredentialOwner.defaults
        defer {
            ProviderSharedCredentialOwner.defaults = originalOwnerDefaults
            appFixture.defaults.removePersistentDomain(
                forName: appFixture.suiteName
            )
            helperDefaults.removePersistentDomain(
                forName: helperFixture.suiteName
            )
        }

        let helperDataSentinel = Data([0x51, 0x41])
        let claudeOwnerKey =
            "cli_pulse_provider_shared_credential_owner_\(ProviderKind.claude.rawValue)"
        let geminiOwnerKey =
            "cli_pulse_provider_shared_credential_owner_\(ProviderKind.gemini.rawValue)"
        helperDefaults.set(
            helperDataSentinel,
            forKey: HelperIPC.providerConfigsKey
        )
        helperDefaults.set(
            true,
            forKey: HelperIPC.providerAccountsWriteV2Key
        )
        helperDefaults.set("claude-sentinel", forKey: claudeOwnerKey)
        helperDefaults.set("gemini-sentinel", forKey: geminiOwnerKey)
        helperDefaults.set("keep", forKey: "unrelated-sentinel")
        let helperKeysBefore = Set(
            helperDefaults.dictionaryRepresentation().keys
        )
        ProviderSharedCredentialOwner.defaults = helperDefaults

        let state = AppState(
            runtimeEnvironment: makeRuntime(
                channel: "qa",
                bundleIdentifier: "app.clipulse.qa.local",
                fixedUserHome: Self.qaRoot
            ),
            defaults: appFixture.defaults,
            helperDefaults: helperDefaults
        )
        var configs = state.providerConfigs
        let savedAccountID = try XCTUnwrap(configs.first?.accountID)
        configs[0].accountLabel = "QA metadata saved"
        state.providerConfigs = configs

        state.saveProviderConfigMetadata()

        let savedData = try XCTUnwrap(
            appFixture.defaults.data(
                forKey: ProviderAccountMigration.configsKey
            )
        )
        let savedConfigs = try JSONDecoder().decode(
            [ProviderConfig].self,
            from: savedData
        )
        XCTAssertEqual(
            savedConfigs.first(where: { $0.accountID == savedAccountID })?
                .accountLabel,
            "QA metadata saved"
        )
        XCTAssertEqual(
            appFixture.defaults.integer(
                forKey: ProviderAccountMigration.schemaVersionKey
            ),
            ProviderAccountMigration.currentSchemaVersion
        )

        XCTAssertEqual(
            Set(helperDefaults.dictionaryRepresentation().keys),
            helperKeysBefore
        )
        XCTAssertEqual(
            helperDefaults.data(forKey: HelperIPC.providerConfigsKey),
            helperDataSentinel
        )
        XCTAssertTrue(
            helperDefaults.bool(
                forKey: HelperIPC.providerAccountsWriteV2Key
            )
        )
        XCTAssertEqual(
            helperDefaults.string(forKey: claudeOwnerKey),
            "claude-sentinel"
        )
        XCTAssertEqual(
            helperDefaults.string(forKey: geminiOwnerKey),
            "gemini-sentinel"
        )
        XCTAssertEqual(
            helperDefaults.string(forKey: "unrelated-sentinel"),
            "keep"
        )
    }

    #if os(macOS)
    @MainActor
    func testSafeQALocalSessionRefreshLeavesHelperStateAndDiagnosticsUntouched()
        async throws
    {
        let fixture = try makeDefaults()
        defer {
            fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
        }
        let state = AppState(
            runtimeEnvironment: makeRuntime(
                channel: "qa",
                bundleIdentifier: "app.clipulse.qa.local",
                fixedUserHome: Self.qaRoot
            ),
            defaults: fixture.defaults
        )
        let diagnostics = LocalSessionControlClient.Diagnostics(
            resolvedSocketPath: "/sentinel/helper.sock",
            socketExists: true,
            resolvedTokenPath: "/sentinel/auth-token",
            tokenExists: true,
            tokenReadable: true,
            appGroupContainerPath: "/sentinel/app-group",
            nsHomeDirectory: "/sentinel/home"
        )
        state.localHelperReachable = true
        state.localControlEnabled = true
        state.localCapabilities = .iter2bLocal
        state.localSupportedMethods = ["sentinel-method"]
        state.localProtocolVersion = 99
        state.localProviderAvailability = ["sentinel-provider"]
        state.localProviderPlanStatus = ["sentinel-provider": "on_plan"]
        state.localHelperVersion = "sentinel-version"
        state.localHelperError = "sentinel-error"
        state.localDiagnostics = diagnostics
        let installerState = state.helperInstaller.state
        let installerLastChecked = state.helperInstaller.lastChecked

        await state.refreshLocalSessionControlState()

        XCTAssertTrue(state.localHelperReachable)
        XCTAssertTrue(state.localControlEnabled)
        XCTAssertEqual(state.localCapabilities, .iter2bLocal)
        XCTAssertEqual(state.localSupportedMethods, ["sentinel-method"])
        XCTAssertEqual(state.localProtocolVersion, 99)
        XCTAssertEqual(
            state.localProviderAvailability,
            ["sentinel-provider"]
        )
        XCTAssertEqual(
            state.localProviderPlanStatus,
            ["sentinel-provider": "on_plan"]
        )
        XCTAssertEqual(state.localHelperVersion, "sentinel-version")
        XCTAssertEqual(state.localHelperError, "sentinel-error")
        XCTAssertEqual(state.localDiagnostics, diagnostics)
        XCTAssertEqual(state.helperInstaller.state, installerState)
        XCTAssertEqual(
            state.helperInstaller.lastChecked,
            installerLastChecked
        )
    }
    #endif

    @MainActor
    func testSafeQACancelProviderDraftDoesNotTouchSharedOwnerDefaults()
        throws
    {
        let appFixture = try makeDefaults()
        let ownerFixture = try makeDefaults()
        let originalOwnerDefaults = ProviderSharedCredentialOwner.defaults
        defer {
            ProviderSharedCredentialOwner.defaults = originalOwnerDefaults
            appFixture.defaults.removePersistentDomain(
                forName: appFixture.suiteName
            )
            ownerFixture.defaults.removePersistentDomain(
                forName: ownerFixture.suiteName
            )
        }
        let secretStore = RecordingProviderSecretStore()
        let state = AppState(
            runtimeEnvironment: makeRuntime(
                channel: "qa",
                bundleIdentifier: "app.clipulse.qa.local",
                fixedUserHome: Self.qaRoot
            ),
            defaults: appFixture.defaults,
            helperDefaults: ownerFixture.defaults,
            providerSecretStore: secretStore
        )
        let draftID = state.addProviderAccount(kind: .claude)
        let ownerKey =
            "cli_pulse_provider_shared_credential_owner_\(ProviderKind.claude.rawValue)"
        ownerFixture.defaults.set(draftID.uuidString, forKey: ownerKey)
        ProviderSharedCredentialOwner.defaults = ownerFixture.defaults

        state.cancelProviderAccountDraft(draftID)

        XCTAssertFalse(
            state.providerConfigs.contains { $0.accountID == draftID }
        )
        XCTAssertEqual(
            ownerFixture.defaults.string(forKey: ownerKey),
            draftID.uuidString
        )
        XCTAssertEqual(secretStore.deletedKeys.count, 2)
    }

    @MainActor
    func testSafeQARemoveProviderAccountDoesNotTouchSharedOwnerDefaults()
        throws
    {
        let appFixture = try makeDefaults()
        let ownerFixture = try makeDefaults()
        let originalOwnerDefaults = ProviderSharedCredentialOwner.defaults
        defer {
            ProviderSharedCredentialOwner.defaults = originalOwnerDefaults
            appFixture.defaults.removePersistentDomain(
                forName: appFixture.suiteName
            )
            ownerFixture.defaults.removePersistentDomain(
                forName: ownerFixture.suiteName
            )
        }
        let secretStore = RecordingProviderSecretStore()
        let state = AppState(
            runtimeEnvironment: makeRuntime(
                channel: "qa",
                bundleIdentifier: "app.clipulse.qa.local",
                fixedUserHome: Self.qaRoot
            ),
            defaults: appFixture.defaults,
            helperDefaults: ownerFixture.defaults,
            providerSecretStore: secretStore
        )
        let accountID = state.addProviderAccount(kind: .claude)
        state.commitProviderAccountDraft(accountID)
        let ownerKey =
            "cli_pulse_provider_shared_credential_owner_\(ProviderKind.claude.rawValue)"
        ownerFixture.defaults.set(accountID.uuidString, forKey: ownerKey)
        ProviderSharedCredentialOwner.defaults = ownerFixture.defaults

        XCTAssertTrue(state.removeProviderAccount(accountID))

        XCTAssertFalse(
            state.providerConfigs.contains { $0.accountID == accountID }
        )
        XCTAssertEqual(
            ownerFixture.defaults.string(forKey: ownerKey),
            accountID.uuidString
        )
        XCTAssertEqual(secretStore.deletedKeys.count, 2)
    }

    @MainActor
    func testSafeQARelaunchSynchronouslyRestoresLocalConnectedDemo() throws {
        let fixture = try makeDefaults()
        defer {
            fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
        }
        fixture.defaults.set(true, forKey: QAExperienceSeed.demoModeKey)

        let state = AppState(
            runtimeEnvironment: makeRuntime(
                channel: "qa",
                bundleIdentifier: "app.clipulse.qa.local",
                fixedUserHome: Self.qaRoot
            ),
            defaults: fixture.defaults
        )

        XCTAssertTrue(state.isDemoMode)
        XCTAssertTrue(state.isLocalMode)
        XCTAssertTrue(state.isAuthenticated)
        XCTAssertTrue(state.isPaired)
        XCTAssertTrue(state.serverOnline)
        XCTAssertFalse(state.providers.isEmpty)
        XCTAssertEqual(state.subscriptionManager.currentTier, .team)
        XCTAssertNil(
            state.lastPublishedWidgetData,
            "QA demo rendering must not advance widget dedupe state"
        )
    }

    private func makeRuntime(
        channel: String?,
        bundleIdentifier: String,
        fixedUserHome: String? = nil
    ) -> CLIPulseRuntimeEnvironment {
        var infoDictionary: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
        ]
        if let channel {
            infoDictionary["CLIPULSE_CHANNEL"] = channel
        }
        var environment: [String: String] = [:]
        if let fixedUserHome {
            environment["CFFIXED_USER_HOME"] = fixedUserHome
        }

        return CLIPulseRuntimeEnvironment.resolveForTesting(
            infoDictionary: infoDictionary,
            environment: environment,
            fileSystem: .init(
                inspectEntry: { path in
                    path == Self.qaRoot ? .directory : .missing
                },
                resolveRealPath: { $0 }
            )
        )
    }

    private func makeDefaults() throws -> (
        defaults: UserDefaults,
        suiteName: String
    ) {
        let suiteName = "QARuntimeSideEffectPolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}

private final class RecordingProviderSecretStore: ProviderSecretStoring {
    private(set) var deletedKeys: [String] = []

    func save(key: String, value: String, accessGroup: String?) {}

    func load(key: String, accessGroup: String?) -> String? {
        nil
    }

    func delete(key: String, accessGroup: String?) {
        deletedKeys.append(key)
    }
}
