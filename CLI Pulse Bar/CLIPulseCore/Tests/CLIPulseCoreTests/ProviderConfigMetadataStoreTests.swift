import Foundation
import XCTest
@testable import CLIPulseCore

final class ProviderConfigMetadataStoreTests: XCTestCase {
    func testSavePersistsNonSecretMetadataToBothSuites() throws {
        let appDefaults = try XCTUnwrap(
            UserDefaults(
                suiteName:
                    "ProviderConfigMetadataStoreTests.app.\(UUID())"
            )
        )
        let helperDefaults = try XCTUnwrap(
            UserDefaults(
                suiteName:
                    "ProviderConfigMetadataStoreTests.helper.\(UUID())"
            )
        )
        defer {
            clear(appDefaults)
            clear(helperDefaults)
        }
        let accountID = try XCTUnwrap(
            UUID(
                uuidString:
                    "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
            )
        )
        let config = ProviderConfig(
            kind: .claude,
            accountID: accountID,
            isEnabled: false,
            apiKey: "must-not-persist",
            manualCookieHeader: "must-not-persist",
            accountLabel: "Work",
            planOverride: "Max",
            syncOwnerUserID: "user-a"
        )
        let store = ProviderConfigMetadataStore(
            defaults: appDefaults,
            helperDefaults: helperDefaults
        )
        appDefaults.set(
            true,
            forKey: ProviderAccountFeatureFlags.writeDefaultsKey
        )

        XCTAssertTrue(store.save([config]))
        XCTAssertTrue(
            helperDefaults.bool(
                forKey: HelperIPC.providerAccountsWriteV2Key
            )
        )

        let persistedLocations = [
            (
                defaults: appDefaults,
                key: ProviderAccountMigration.configsKey
            ),
            (
                defaults: helperDefaults,
                key: HelperIPC.providerConfigsKey
            ),
        ]
        for location in persistedLocations {
            let data = try XCTUnwrap(
                location.defaults.data(forKey: location.key)
            )
            let decoded = try JSONDecoder().decode(
                [ProviderConfig].self,
                from: data
            )
            XCTAssertEqual(decoded.map(\.accountID), [accountID])
            XCTAssertEqual(decoded.first?.accountLabel, "Work")
            XCTAssertEqual(decoded.first?.planOverride, "Max")
            XCTAssertEqual(
                decoded.first?.syncOwnerUserID,
                "user-a"
            )
            XCTAssertFalse(try XCTUnwrap(decoded.first).isEnabled)
            XCTAssertNil(decoded.first?.apiKey)
            XCTAssertNil(decoded.first?.manualCookieHeader)
        }
    }

    func testHelperWriteFailureRestoresAppAndHelperMetadata()
        throws
    {
        let appSuite =
            "ProviderConfigMetadataStoreTests.rollback.app.\(UUID())"
        let helperSuite =
            "ProviderConfigMetadataStoreTests.rollback.helper.\(UUID())"
        let appDefaults = try XCTUnwrap(
            UserDefaults(suiteName: appSuite)
        )
        let helperDefaults = try XCTUnwrap(
            DroppingUserDefaults(suiteName: helperSuite)
        )
        defer {
            appDefaults.removePersistentDomain(forName: appSuite)
            helperDefaults.removePersistentDomain(forName: helperSuite)
        }
        let accountID = try XCTUnwrap(
            UUID(
                uuidString:
                    "ACACACAC-ACAC-4CAC-8CAC-ACACACACACAC"
            )
        )
        let original = ProviderConfig(
            kind: .claude,
            accountID: accountID,
            accountLabel: "Original"
        )
        let edited = ProviderConfig(
            kind: .claude,
            accountID: accountID,
            accountLabel: "Edited"
        )
        let store = ProviderConfigMetadataStore(
            defaults: appDefaults,
            helperDefaults: helperDefaults
        )
        XCTAssertTrue(store.save([original]))
        helperDefaults.droppedSetKeys.insert(
            HelperIPC.providerConfigsKey
        )

        XCTAssertFalse(store.save([edited]))
        for (defaults, key) in [
            (appDefaults, ProviderAccountMigration.configsKey),
            (helperDefaults, HelperIPC.providerConfigsKey),
        ] {
            let data = try XCTUnwrap(defaults.data(forKey: key))
            let configs = try JSONDecoder().decode(
                [ProviderConfig].self,
                from: data
            )
            XCTAssertEqual(configs.first?.accountLabel, "Original")
        }
    }

    @MainActor
    func testDraftRecoveryAnchorSurvivesRestartBeforeCredentialCommit()
        throws
    {
        let appDefaults = try XCTUnwrap(
            UserDefaults(
                suiteName:
                    "ProviderConfigMetadataStoreTests.anchor.app.\(UUID())"
            )
        )
        let helperDefaults = try XCTUnwrap(
            UserDefaults(
                suiteName:
                    "ProviderConfigMetadataStoreTests.anchor.helper.\(UUID())"
            )
        )
        defer {
            clear(appDefaults)
            clear(helperDefaults)
        }
        let accountID = try XCTUnwrap(
            UUID(
                uuidString:
                    "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
            )
        )
        let state = AppState(
            api: APIClient(),
            providerAccountDeletionOutbox:
                ProviderAccountDeletionOutbox(
                    defaults: appDefaults,
                    storageKey:
                        "ProviderConfigMetadataStoreTests.anchor.outbox"
                ),
            performLaunchSetup: false
        )
        XCTAssertEqual(
            state.addProviderAccount(
                kind: .gemini,
                accountID: accountID
            ),
            accountID
        )
        let metadataStore = ProviderConfigMetadataStore(
            defaults: appDefaults,
            helperDefaults: helperDefaults
        )

        XCTAssertTrue(
            state.persistProviderAccountCredentialRecoveryAnchor(
                accountID,
                using: metadataStore
            )
        )
        XCTAssertTrue(
            state.providerState.isProviderAccountDraft(accountID),
            "persisting the recovery anchor must not commit the editor transaction"
        )

        let restarted = try XCTUnwrap(
            ProviderAccountMigration.migrateIfNeeded(
                defaults: appDefaults
            )
        )
        let recovered = try XCTUnwrap(
            restarted.configs.first {
                $0.accountID == accountID
            }
        )
        XCTAssertEqual(recovered.kind, .gemini)
        XCTAssertFalse(
            recovered.isEnabled,
            "a crash-recovery anchor must remain disabled until Save finishes"
        )
    }

    @MainActor
    func testIncompleteSaveRecoveryIsRetainedUntilCompensationSucceeds()
        throws
    {
        let defaults = try XCTUnwrap(
            UserDefaults(
                suiteName:
                    "ProviderConfigMetadataStoreTests.pending-recovery.\(UUID())"
            )
        )
        defer {
            clear(defaults)
        }
        let state = AppState(
            api: APIClient(),
            providerAccountDeletionOutbox:
                ProviderAccountDeletionOutbox(
                    defaults: defaults,
                    storageKey:
                        "ProviderConfigMetadataStoreTests.pending-recovery.outbox"
                ),
            performLaunchSetup: false
        )
        let accountID = UUID()
        var metadataAttempts = 0
        var secretAttempts = 0
        let recovery = ProviderAccountSaveRecovery(
            restoreMetadata: {
                metadataAttempts += 1
                return metadataAttempts >= 2
            },
            restoreSecrets: {
                secretAttempts += 1
                return true
            }
        )
        state.retainProviderAccountSaveRecovery(
            recovery,
            for: accountID
        )

        XCTAssertFalse(
            state.recoverPendingProviderAccountSave(accountID)
        )
        XCTAssertTrue(
            state.recoverPendingProviderAccountSave(accountID)
        )
        XCTAssertTrue(
            state.recoverPendingProviderAccountSave(accountID),
            "a successful recovery must clear the gate"
        )
        XCTAssertEqual(metadataAttempts, 2)
        XCTAssertEqual(secretAttempts, 2)
    }

    #if os(macOS)
    @MainActor
    func testFinalDraftMetadataPersistenceReconcilesSharedOwner() throws {
        let appDefaults = try XCTUnwrap(
            UserDefaults(
                suiteName: "ProviderConfigMetadataStoreTests.final.app.\(UUID())"
            )
        )
        let helperDefaults = try XCTUnwrap(
            UserDefaults(
                suiteName: "ProviderConfigMetadataStoreTests.final.helper.\(UUID())"
            )
        )
        let originalOwnerDefaults = ProviderSharedCredentialOwner.defaults
        let originalSynchronizeDefaults = ProviderSharedCredentialOwner.synchronizeDefaults
        let originalMutationLock = ProviderSharedCredentialOwner.mutationLock
        let lockPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProviderConfigMetadataStoreTests.final.\(UUID()).lock")
            .path
        defer {
            ProviderSharedCredentialOwner.defaults = originalOwnerDefaults
            ProviderSharedCredentialOwner.synchronizeDefaults = originalSynchronizeDefaults
            ProviderSharedCredentialOwner.mutationLock = originalMutationLock
            clear(appDefaults)
            clear(helperDefaults)
            try? FileManager.default.removeItem(atPath: lockPath)
        }
        ProviderSharedCredentialOwner.defaults = helperDefaults
        ProviderSharedCredentialOwner.synchronizeDefaults = { _ in true }
        ProviderSharedCredentialOwner.mutationLock = GeminiCredentialMutationLock(
            lockFilePath: lockPath
        )

        let accountID = try XCTUnwrap(
            UUID(uuidString: "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC")
        )
        let state = AppState(
            runtimeEnvironment: TestRuntimeFixtures.productionApp,
            defaults: appDefaults,
            helperDefaults: helperDefaults,
            providerAccountDeletionOutbox: ProviderAccountDeletionOutbox(
                defaults: appDefaults,
                storageKey: "ProviderConfigMetadataStoreTests.final.outbox"
            ),
            performLaunchSetup: false
        )
        state.providerConfigs = [
            ProviderConfig(
                kind: .claude,
                accountID: accountID,
                isEnabled: true
            ),
        ]
        let metadataStore = ProviderConfigMetadataStore(
            defaults: appDefaults,
            helperDefaults: helperDefaults
        )

        XCTAssertEqual(ProviderSharedCredentialOwner.lookup(kind: .claude), .unowned)
        XCTAssertTrue(
            state.persistProviderAccountDraftMetadata(
                accountID,
                using: metadataStore
            )
        )
        XCTAssertEqual(
            ProviderSharedCredentialOwner.lookup(kind: .claude),
            .owned(accountID)
        )
    }

    @MainActor
    func testOwnerReconcileFailureStopsCredentialCommitAndDraftFinalization() throws {
        let appDefaults = try XCTUnwrap(
            UserDefaults(
                suiteName: "ProviderConfigMetadataStoreTests.failed-owner.app.\(UUID())"
            )
        )
        let helperDefaults = try XCTUnwrap(
            UserDefaults(
                suiteName: "ProviderConfigMetadataStoreTests.failed-owner.helper.\(UUID())"
            )
        )
        let originalOwnerDefaults = ProviderSharedCredentialOwner.defaults
        let originalSynchronizeDefaults = ProviderSharedCredentialOwner.synchronizeDefaults
        let originalMutationLock = ProviderSharedCredentialOwner.mutationLock
        let lockPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProviderConfigMetadataStoreTests.failed-owner.\(UUID()).lock")
            .path
        defer {
            ProviderSharedCredentialOwner.defaults = originalOwnerDefaults
            ProviderSharedCredentialOwner.synchronizeDefaults = originalSynchronizeDefaults
            ProviderSharedCredentialOwner.mutationLock = originalMutationLock
            clear(appDefaults)
            clear(helperDefaults)
            try? FileManager.default.removeItem(atPath: lockPath)
        }
        ProviderSharedCredentialOwner.defaults = helperDefaults
        ProviderSharedCredentialOwner.synchronizeDefaults = { _ in true }
        ProviderSharedCredentialOwner.mutationLock = GeminiCredentialMutationLock(
            lockFilePath: lockPath
        )
        helperDefaults.set(
            "not-a-uuid",
            forKey: "cli_pulse_provider_shared_credential_owner_Claude"
        )

        let accountID = try XCTUnwrap(
            UUID(uuidString: "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD")
        )
        let state = AppState(
            runtimeEnvironment: TestRuntimeFixtures.productionApp,
            defaults: appDefaults,
            helperDefaults: helperDefaults,
            providerAccountDeletionOutbox: ProviderAccountDeletionOutbox(
                defaults: appDefaults,
                storageKey: "ProviderConfigMetadataStoreTests.failed-owner.outbox"
            ),
            performLaunchSetup: false
        )
        _ = state.addProviderAccount(kind: .gemini, accountID: accountID)
        state.providerConfigs[0].isEnabled = true
        let metadataStore = ProviderConfigMetadataStore(
            defaults: appDefaults,
            helperDefaults: helperDefaults
        )
        var credentialCommitted = false

        let result = ProviderAccountSaveTransaction.commit(
            persistSecrets: { true },
            rollbackSecrets: { true },
            persistMetadata: {
                state.persistProviderAccountDraftMetadata(
                    accountID,
                    using: metadataStore
                )
            },
            rollbackMetadata: { true },
            commitProviderCredential: {
                credentialCommitted = true
                return true
            },
            finalize: {
                state.finalizeProviderAccountDraft(accountID)
            }
        )

        XCTAssertEqual(result, .failedRolledBack)
        XCTAssertFalse(credentialCommitted)
        XCTAssertTrue(state.providerState.isProviderAccountDraft(accountID))
    }

    @MainActor
    func testCredentialFailureRestoresMetadataAndSharedOwner()
        throws
    {
        let appDefaults = try XCTUnwrap(
            UserDefaults(
                suiteName:
                    "ProviderConfigMetadataStoreTests.credential-rollback.app.\(UUID())"
            )
        )
        let helperDefaults = try XCTUnwrap(
            UserDefaults(
                suiteName:
                    "ProviderConfigMetadataStoreTests.credential-rollback.helper.\(UUID())"
            )
        )
        let originalOwnerDefaults = ProviderSharedCredentialOwner.defaults
        let originalSynchronizeDefaults =
            ProviderSharedCredentialOwner.synchronizeDefaults
        let originalMutationLock =
            ProviderSharedCredentialOwner.mutationLock
        let lockPath = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ProviderConfigMetadataStoreTests.credential-rollback.\(UUID()).lock"
            )
            .path
        defer {
            ProviderSharedCredentialOwner.defaults = originalOwnerDefaults
            ProviderSharedCredentialOwner.synchronizeDefaults =
                originalSynchronizeDefaults
            ProviderSharedCredentialOwner.mutationLock =
                originalMutationLock
            clear(appDefaults)
            clear(helperDefaults)
            try? FileManager.default.removeItem(atPath: lockPath)
        }
        ProviderSharedCredentialOwner.defaults = helperDefaults
        ProviderSharedCredentialOwner.synchronizeDefaults = { _ in true }
        ProviderSharedCredentialOwner.mutationLock =
            GeminiCredentialMutationLock(lockFilePath: lockPath)

        let accountID = try XCTUnwrap(
            UUID(
                uuidString:
                    "EFEFEFEF-EFEF-4FEF-8FEF-EFEFEFEFEFEF"
            )
        )
        let state = AppState(
            runtimeEnvironment: TestRuntimeFixtures.productionApp,
            defaults: appDefaults,
            helperDefaults: helperDefaults,
            providerAccountDeletionOutbox:
                ProviderAccountDeletionOutbox(
                    defaults: appDefaults,
                    storageKey:
                        "ProviderConfigMetadataStoreTests.credential-rollback.outbox"
                ),
            performLaunchSetup: false
        )
        state.providerConfigs = [
            ProviderConfig(
                kind: .claude,
                accountID: accountID,
                isEnabled: true,
                accountLabel: "Original"
            ),
        ]
        let metadataStore = ProviderConfigMetadataStore(
            defaults: appDefaults,
            helperDefaults: helperDefaults
        )
        XCTAssertTrue(
            state.persistProviderAccountDraftMetadata(
                accountID,
                using: metadataStore
            )
        )
        let checkpoint = try XCTUnwrap(
            state.makeProviderAccountPersistenceCheckpoint(
                accountID,
                using: metadataStore
            )
        )
        state.providerConfigs[0].accountLabel = "Edited"
        state.providerConfigs[0]
            .sharedCredentialFallbackDisabled = true

        XCTAssertEqual(
            ProviderAccountSaveTransaction.commit(
                persistSecrets: { true },
                rollbackSecrets: { true },
                persistMetadata: {
                    state.persistProviderAccountDraftMetadata(
                        accountID,
                        using: metadataStore
                    )
                },
                rollbackMetadata: {
                    checkpoint.restore()
                },
                commitProviderCredential: { false },
                finalize: {}
            ),
            .failedRolledBack
        )
        XCTAssertEqual(
            ProviderSharedCredentialOwner.lookup(kind: .claude),
            .owned(accountID)
        )
        for (defaults, key) in [
            (appDefaults, ProviderAccountMigration.configsKey),
            (helperDefaults, HelperIPC.providerConfigsKey),
        ] {
            let data = try XCTUnwrap(defaults.data(forKey: key))
            let configs = try JSONDecoder().decode(
                [ProviderConfig].self,
                from: data
            )
            XCTAssertEqual(configs.first?.accountLabel, "Original")
            XCTAssertNil(
                configs.first?.sharedCredentialFallbackDisabled
            )
        }
    }
    #endif

    private func clear(_ defaults: UserDefaults) {
        for key in defaults.dictionaryRepresentation().keys {
            defaults.removeObject(forKey: key)
        }
    }
}

private final class DroppingUserDefaults: UserDefaults {
    var droppedSetKeys: Set<String> = []

    override func set(_ value: Any?, forKey defaultName: String) {
        guard !droppedSetKeys.contains(defaultName) else {
            return
        }
        super.set(value, forKey: defaultName)
    }
}
