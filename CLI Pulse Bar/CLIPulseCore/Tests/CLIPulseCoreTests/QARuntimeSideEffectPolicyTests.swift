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
            "cli_pulse_provider_shared_credential_owner_claude"
        let geminiOwnerKey =
            "cli_pulse_provider_shared_credential_owner_gemini"
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
