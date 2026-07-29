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
    func testSafeQADeniesHelperConfigurationStorageBeforeAnyPersistenceAccess() {
        let runtime = makeRuntime(
            channel: "qa",
            bundleIdentifier: "app.clipulse.qa.local",
            fixedUserHome: Self.qaRoot
        )
        var persistenceInteractionCount = 0
        let persistence = HelperConfig.PersistenceAccess(
            loadStoredData: {
                persistenceInteractionCount += 1
                return nil
            },
            saveStoredData: { _ in
                persistenceInteractionCount += 1
            },
            removeStoredData: {
                persistenceInteractionCount += 1
            },
            loadSecret: {
                persistenceInteractionCount += 1
                return nil
            },
            saveSecret: { _ in
                persistenceInteractionCount += 1
            },
            removeSecret: {
                persistenceInteractionCount += 1
            },
            loadLegacyFileData: {
                persistenceInteractionCount += 1
                return nil
            }
        )
        let config = HelperConfig(
            deviceId: "qa-device",
            userId: "qa-user",
            deviceName: "QA Mac",
            helperVersion: "1.0.0",
            helperSecret: "must-not-be-written"
        )

        XCTAssertFalse(runtime.allowsHelperConfigurationAccess)
        XCTAssertNil(
            HelperConfig.load(
                runtimeEnvironment: runtime,
                persistence: persistence
            )
        )
        HelperConfig.save(
            config,
            runtimeEnvironment: runtime,
            persistence: persistence
        )
        HelperConfig.remove(
            runtimeEnvironment: runtime,
            persistence: persistence
        )
        XCTAssertNil(
            HelperConfig.importFromLegacy(
                runtimeEnvironment: runtime,
                persistence: persistence
            )
        )
        XCTAssertEqual(persistenceInteractionCount, 0)
    }

    func testOnlyExactProductionAppAndHelperMayAccessHelperConfiguration() {
        XCTAssertTrue(
            makeRuntime(
                channel: nil,
                bundleIdentifier: "yyh.CLI-Pulse"
            ).allowsHelperConfigurationAccess
        )
        XCTAssertTrue(
            makeRuntime(
                channel: nil,
                bundleIdentifier: "yyh.CLI-Pulse.helper"
            ).allowsHelperConfigurationAccess
        )
        XCTAssertFalse(
            makeRuntime(
                channel: nil,
                bundleIdentifier: "yyh.CLI-Pulse.widgets"
            ).allowsHelperConfigurationAccess
        )
        XCTAssertFalse(
            makeRuntime(
                channel: "qa",
                bundleIdentifier: "app.clipulse.qa.local",
                fixedUserHome: Self.qaRoot
            ).allowsHelperConfigurationAccess
        )
        XCTAssertFalse(
            makeRuntime(
                channel: nil,
                bundleIdentifier: "com.example.clipulse"
            ).allowsHelperConfigurationAccess
        )
    }

    func testSafeQALocalSessionClientRejectsBeforeProductionPathResolution()
        async
    {
        let runtime = makeRuntime(
            channel: "qa",
            bundleIdentifier: "app.clipulse.qa.local",
            fixedUserHome: Self.qaRoot
        )
        var productionPathResolutionCount = 0
        let client = LocalSessionControlClient(
            runtimeEnvironment: runtime,
            basePathResolver: {
                productionPathResolutionCount += 1
                return "/Users/production/.clipulse"
            }
        )

        let diagnostics = client.diagnostics()
        XCTAssertEqual(productionPathResolutionCount, 0)
        XCTAssertTrue(
            diagnostics.resolvedSocketPath.hasPrefix(Self.qaRoot)
        )
        XCTAssertTrue(
            diagnostics.resolvedTokenPath.hasPrefix(Self.qaRoot)
        )
        XCTAssertFalse(diagnostics.socketExists)
        XCTAssertFalse(diagnostics.tokenExists)
        XCTAssertFalse(diagnostics.tokenReadable)
        XCTAssertNil(diagnostics.appGroupContainerPath)

        do {
            _ = try await client.hello()
            XCTFail("safe QA must reject local helper RPC")
        } catch let error as SessionControlError {
            XCTAssertEqual(error, .runtimeRestricted)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        do {
            _ = try await client.getLocalControlStatus()
            XCTFail("safe QA must reject authenticated local helper RPC")
        } catch let error as SessionControlError {
            XCTAssertEqual(error, .runtimeRestricted)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        var streamIterator = client.subscribeEvents(
            sessionId: "qa-session"
        ).makeAsyncIterator()
        do {
            _ = try await streamIterator.next()
            XCTFail("safe QA must reject local helper event streams")
        } catch let error as SessionControlError {
            XCTAssertEqual(error, .runtimeRestricted)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(productionPathResolutionCount, 0)
    }

    func testProductionHelperLocalSessionClientUsesLiveBasePath() {
        let runtime = makeRuntime(
            channel: nil,
            bundleIdentifier: "yyh.CLI-Pulse.helper"
        )
        var liveBasePathResolutionCount = 0
        let client = LocalSessionControlClient(
            runtimeEnvironment: runtime,
            basePathResolver: {
                liveBasePathResolutionCount += 1
                return "/private/tmp/clipulse-production-helper-test"
            }
        )

        let diagnostics = client.diagnostics()

        XCTAssertEqual(liveBasePathResolutionCount, 1)
        XCTAssertEqual(
            diagnostics.resolvedSocketPath,
            "/private/tmp/clipulse-production-helper-test/"
                + LocalSessionControlClient.socketFilename
        )
        XCTAssertEqual(
            diagnostics.resolvedTokenPath,
            "/private/tmp/clipulse-production-helper-test/"
                + LocalSessionControlClient.authTokenFilename
        )
    }

    @MainActor
    func testSafeQALocalSessionEntryPointsStayDisabledEvenWithStaleReadyFlags()
        throws
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
        state.localHelperReachable = true
        state.localControlEnabled = true
        let session = RemoteSession(
            id: "qa-stale-session",
            device_id: "qa-stale-device",
            provider: "claude",
            cwd_basename: "qa",
            status: "running",
            created_at: "2026-07-29T00:00:00Z"
        )
        state.localManagedSessions = [
            .init(
                id: session.id,
                provider: session.provider,
                clientLabel: "stale",
                status: session.status,
                controllable: true,
                source: .managed
            ),
        ]

        XCTAssertNil(state.selfDeviceId)
        XCTAssertFalse(state.canStartLocalManagedSession)
        XCTAssertFalse(state.shouldUseLocalSessionControl(forDeviceId: "stale"))
        XCTAssertFalse(state.shouldRouteSessionLocally(session))
    }

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

    @MainActor
    func testSafeQAHelperInstallerRejectsExternalWorkBeforeResolvingProductionPaths() async {
        let runtime = makeRuntime(
            channel: "qa",
            bundleIdentifier: "app.clipulse.qa.local",
            fixedUserHome: Self.qaRoot
        )
        var productionPathResolutionCount = 0
        var helperClientCreationCount = 0
        let installer = HelperInstaller(
            runtimeEnvironment: runtime,
            manifestURL: URL(string: "https://example.invalid/manifest.json")!,
            urlSession: .shared,
            helloClient: {
                helperClientCreationCount += 1
                return LocalSessionControlClient(
                    socketPath: "/private/tmp/clipulse-qa-missing.sock",
                    tokenPath: "/private/tmp/clipulse-qa-missing-token",
                    connectTimeout: 0.01,
                    requestTimeout: 0.01
                )
            },
            productionPathResolver: {
                productionPathResolutionCount += 1
                return HelperInstaller.ProductionPaths(
                    udsPath: "/Users/production/Library/Group Containers/group.yyh.CLI-Pulse/clipulse-helper.sock",
                    helperDir: "/Users/production/Library/CLI-Pulse-Helper"
                )
            }
        )

        await installer.refresh()
        await installer.refreshIfStale()
        await installer.install()
        await installer.uninstall()
        let isLive = await installer.probeHelperLiveness(timeout: 0.01)

        XCTAssertEqual(productionPathResolutionCount, 0)
        XCTAssertEqual(helperClientCreationCount, 0)
        XCTAssertNil(installer.lastChecked)
        XCTAssertFalse(isLive)
    }

    func testSafeQASystemServiceGateDoesNotReadOrMutateLoginItems() throws {
        let runtime = makeRuntime(
            channel: "qa",
            bundleIdentifier: "app.clipulse.qa.local",
            fixedUserHome: Self.qaRoot
        )
        var statusReadCount = 0
        var registrationCount = 0
        var unregistrationCount = 0
        let service = RuntimeProtectedSystemService(
            runtimeEnvironment: runtime,
            isEnabled: {
                statusReadCount += 1
                return true
            },
            register: {
                registrationCount += 1
            },
            unregister: {
                unregistrationCount += 1
            }
        )

        XCTAssertFalse(service.isEnabled)
        XCTAssertFalse(try service.setEnabled(true))
        XCTAssertFalse(try service.setEnabled(false))
        XCTAssertEqual(statusReadCount, 0)
        XCTAssertEqual(registrationCount, 0)
        XCTAssertEqual(unregistrationCount, 0)
    }

    func testSafeQAProviderActionGateDoesNotInvokeLiveAction() async throws {
        let runtime = makeRuntime(
            channel: "qa",
            bundleIdentifier: "app.clipulse.qa.local",
            fixedUserHome: Self.qaRoot
        )
        var invocationCount = 0

        let result: String? = try await RuntimeProtectedProviderAction.perform(
            runtimeEnvironment: runtime
        ) {
            invocationCount += 1
            return "live-result"
        }

        XCTAssertNil(result)
        XCTAssertEqual(invocationCount, 0)
    }

    func testGeminiTokenCleanupPolicyRequiresLiveCollection() {
        XCTAssertFalse(
            GeminiOAuthManager.allowsTokenCleanup(
                in: makeRuntime(
                    channel: "qa",
                    bundleIdentifier: "app.clipulse.qa.local",
                    fixedUserHome: Self.qaRoot
                )
            )
        )
        XCTAssertTrue(
            GeminiOAuthManager.allowsTokenCleanup(
                in: makeRuntime(
                    channel: nil,
                    bundleIdentifier: "yyh.CLI-Pulse"
                )
            )
        )
        XCTAssertFalse(
            GeminiOAuthManager.allowsTokenCleanup(
                in: makeRuntime(
                    channel: nil,
                    bundleIdentifier: "com.example.clipulse"
                )
            )
        )
    }

    func testExplicitSafeQARuntimeSkipsGeminiCleanupBeforeOwnerStore()
        throws
    {
        let ownerFixture = try makeDefaults()
        let originalOwnerDefaults = ProviderSharedCredentialOwner.defaults
        defer {
            ProviderSharedCredentialOwner.defaults = originalOwnerDefaults
            ownerFixture.defaults.removePersistentDomain(
                forName: ownerFixture.suiteName
            )
        }
        let accountID = UUID()
        let ownerKey =
            "cli_pulse_provider_shared_credential_owner_\(ProviderKind.gemini.rawValue)"
        ownerFixture.defaults.set(accountID.uuidString, forKey: ownerKey)
        ProviderSharedCredentialOwner.defaults = ownerFixture.defaults

        GeminiOAuthManager.shared.clearTokens(
            accountID: accountID,
            runtimeEnvironment: makeRuntime(
                channel: "qa",
                bundleIdentifier: "app.clipulse.qa.local",
                fixedUserHome: Self.qaRoot
            )
        )

        XCTAssertEqual(
            ownerFixture.defaults.string(forKey: ownerKey),
            accountID.uuidString
        )
    }
    #endif

    @MainActor
    func testSafeQACancelProviderDraftDoesNotTouchSharedOwnerDefaults()
        throws
    {
        try assertSafeQACancelDoesNotTouchSharedOwnerDefaults(
            kind: .claude
        )
    }

    @MainActor
    func testSafeQACancelGeminiDraftDoesNotTouchSharedOwnerDefaults()
        throws
    {
        try assertSafeQACancelDoesNotTouchSharedOwnerDefaults(
            kind: .gemini
        )
    }

    @MainActor
    func testSafeQARemoveProviderAccountDoesNotTouchSharedOwnerDefaults()
        throws
    {
        try assertSafeQARemoveDoesNotTouchSharedOwnerDefaults(
            kind: .claude
        )
    }

    @MainActor
    func testSafeQARemoveGeminiAccountDoesNotTouchSharedOwnerDefaults()
        throws
    {
        try assertSafeQARemoveDoesNotTouchSharedOwnerDefaults(
            kind: .gemini
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

    @MainActor
    private func assertSafeQACancelDoesNotTouchSharedOwnerDefaults(
        kind: ProviderKind
    ) throws {
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
        let draftID = state.addProviderAccount(kind: kind)
        let ownerKey =
            "cli_pulse_provider_shared_credential_owner_\(kind.rawValue)"
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
    private func assertSafeQARemoveDoesNotTouchSharedOwnerDefaults(
        kind: ProviderKind
    ) throws {
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
        let accountID = state.addProviderAccount(kind: kind)
        state.commitProviderAccountDraft(accountID)
        let ownerKey =
            "cli_pulse_provider_shared_credential_owner_\(kind.rawValue)"
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
