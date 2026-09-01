import Foundation
import XCTest
@testable import CLIPulseCore

final class ProviderConfigMetadataStoreTests: XCTestCase {
    func testFreshSaveDoesNotTurnItsOwnMetadataIntoConsent() throws {
        let appDefaults = try XCTUnwrap(
            UserDefaults(
                suiteName:
                    "ProviderConfigMetadataStoreTests.fresh.app.\(UUID())"
            )
        )
        let helperDefaults = try XCTUnwrap(
            UserDefaults(
                suiteName:
                    "ProviderConfigMetadataStoreTests.fresh.helper.\(UUID())"
            )
        )
        defer {
            clear(appDefaults)
            clear(helperDefaults)
        }
        let config = ProviderConfig(kind: .codex, isEnabled: true)
        let store = ProviderConfigMetadataStore(
            defaults: appDefaults,
            helperDefaults: helperDefaults
        )

        XCTAssertTrue(store.save([config]))
        XCTAssertTrue(
            store.save([config]),
            "a second pre-consent save must remain in the fresh-install cohort"
        )

        let appData = try XCTUnwrap(
            appDefaults.data(
                forKey: ProviderAccountMigration.configsKey
            )
        )
        let appConfigs = try JSONDecoder().decode(
            [ProviderConfig].self,
            from: appData
        )
        XCTAssertTrue(try XCTUnwrap(appConfigs.first).isEnabled)

        let helperData = try XCTUnwrap(
            helperDefaults.data(
                forKey: HelperIPC.providerConfigsKey
            )
        )
        let helperConfigs = try JSONDecoder().decode(
            [ProviderConfig].self,
            from: helperData
        )
        XCTAssertTrue(
            helperConfigs.isEmpty,
            "unreviewed account metadata must not cross into the helper projection"
        )
    }

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
            isEnabled: true,
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

        XCTAssertTrue(
            store.save(
                [config],
                helperCollectionAuthorized: false
            )
        )
        XCTAssertTrue(
            ProviderCollectionConsent.record(
                configs: [config],
                defaults: appDefaults
            )
        )
        XCTAssertTrue(
            store.save(
                [config],
                helperCollectionAuthorized: true
            )
        )
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
            XCTAssertTrue(try XCTUnwrap(decoded.first).isEnabled)
            XCTAssertNil(decoded.first?.apiKey)
            XCTAssertNil(decoded.first?.manualCookieHeader)
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

    func testChangedSelectionClearsHelperUntilNewSnapshotIsRecorded()
        throws
    {
        let appDefaults = try XCTUnwrap(
            UserDefaults(
                suiteName:
                    "ProviderConfigMetadataStoreTests.drift.app.\(UUID())"
            )
        )
        let helperDefaults = try XCTUnwrap(
            UserDefaults(
                suiteName:
                    "ProviderConfigMetadataStoreTests.drift.helper.\(UUID())"
            )
        )
        defer {
            clear(appDefaults)
            clear(helperDefaults)
        }
        let original = [
            ProviderConfig(kind: .codex, isEnabled: true),
            ProviderConfig(kind: .claude, isEnabled: true),
        ]
        let reduced = [original[1]]
        let store = ProviderConfigMetadataStore(
            defaults: appDefaults,
            helperDefaults: helperDefaults
        )

        XCTAssertTrue(
            store.save(
                original,
                helperCollectionAuthorized: false
            )
        )
        XCTAssertTrue(
            ProviderCollectionConsent.record(
                configs: original,
                defaults: appDefaults
            )
        )
        XCTAssertTrue(
            store.save(
                original,
                helperCollectionAuthorized: true
            )
        )

        XCTAssertTrue(store.save(reduced))
        XCTAssertFalse(
            ProviderCollectionConsent.isCollectionAuthorized(
                defaults: appDefaults
            )
        )
        XCTAssertTrue(
            try decodeConfigs(
                from: helperDefaults,
                key: HelperIPC.providerConfigsKey
            ).isEmpty,
            "an old snapshot must not authorize a newly reduced helper projection"
        )

        XCTAssertTrue(
            ProviderCollectionConsent.record(
                configs: reduced,
                defaults: appDefaults
            )
        )
        XCTAssertTrue(
            store.save(
                reduced,
                helperCollectionAuthorized: true
            )
        )
        XCTAssertEqual(
            try decodeConfigs(
                from: helperDefaults,
                key: HelperIPC.providerConfigsKey
            ).map(\.accountID),
            reduced.map(\.accountID)
        )
    }

    @MainActor
    func testAccountDeletionReconfirmsTheReducedSelection() throws {
        let appDefaults = try XCTUnwrap(
            UserDefaults(
                suiteName:
                    "ProviderConfigMetadataStoreTests.delete.app.\(UUID())"
            )
        )
        defer { clear(appDefaults) }
        let state = AppState(
            runtimeEnvironment: .current,
            defaults: appDefaults,
            providerSecretStore: InMemoryDeletionSecretStore(),
            performLaunchSetup: false
        )
        let original = [
            ProviderConfig(kind: .codex, isEnabled: true),
            ProviderConfig(kind: .claude, isEnabled: true),
        ]
        state.providerConfigs = original
        XCTAssertTrue(state.confirmProviderCollectionSelection())

        XCTAssertTrue(
            state.removeProviderAccount(original[0].accountID)
        )
        XCTAssertTrue(
            ProviderCollectionConsent.isCollectionAuthorized(
                defaults: appDefaults
            )
        )
        XCTAssertEqual(
            try decodeConfigs(
                from: appDefaults,
                key: ProviderAccountMigration.configsKey
            ).map(\.accountID),
            [original[1].accountID]
        )
    }

    @MainActor
    func testAccountDeletionDoesNotGrantAnUnreviewedSelection() throws {
        let appDefaults = try XCTUnwrap(
            UserDefaults(
                suiteName:
                    "ProviderConfigMetadataStoreTests.delete.unreviewed.app.\(UUID())"
            )
        )
        let helperDefaults = try XCTUnwrap(
            UserDefaults(
                suiteName:
                    "ProviderConfigMetadataStoreTests.delete.unreviewed.helper.\(UUID())"
            )
        )
        defer {
            clear(appDefaults)
            clear(helperDefaults)
        }
        let original = [
            ProviderConfig(kind: .codex, isEnabled: true),
            ProviderConfig(kind: .claude, isEnabled: true),
        ]
        appDefaults.set(
            try JSONEncoder().encode(original),
            forKey: ProviderAccountMigration.configsKey
        )
        appDefaults.set(
            true,
            forKey:
                ProviderCollectionReviewFeatureFlags
                    .existingUsersDefaultsKey
        )
        let runtime = CLIPulseRuntimeEnvironment.resolveForTesting(
            infoDictionary: [
                "CFBundleIdentifier": "yyh.CLI-Pulse",
            ],
            environment: [:]
        )
        XCTAssertTrue(runtime.capabilities.allowsHelperRegistration)
        let state = AppState(
            runtimeEnvironment: runtime,
            defaults: appDefaults,
            helperDefaults: helperDefaults,
            providerSecretStore: InMemoryDeletionSecretStore(),
            performLaunchSetup: false
        )
        state.providerConfigs = original
        XCTAssertFalse(state.providerCollectionAuthorized)

        XCTAssertTrue(
            state.removeProviderAccount(original[0].accountID)
        )
        XCTAssertFalse(
            ProviderCollectionConsent.isCollectionAuthorized(
                defaults: appDefaults
            ),
            "deleting an account must not grant consent for the accounts that remain"
        )
        XCTAssertEqual(
            try decodeConfigs(
                from: appDefaults,
                key: ProviderAccountMigration.configsKey
            ).map(\.accountID),
            [original[1].accountID]
        )
        XCTAssertTrue(
            try decodeConfigs(
                from: helperDefaults,
                key: HelperIPC.providerConfigsKey
            ).isEmpty,
            "an unreviewed reduced selection must keep the helper fail-closed"
        )
    }

    private func decodeConfigs(
        from defaults: UserDefaults,
        key: String
    ) throws -> [ProviderConfig] {
        let data = try XCTUnwrap(defaults.data(forKey: key))
        return try JSONDecoder().decode([ProviderConfig].self, from: data)
    }

    private func clear(_ defaults: UserDefaults) {
        for key in defaults.dictionaryRepresentation().keys {
            defaults.removeObject(forKey: key)
        }
    }
}

private final class InMemoryDeletionSecretStore:
    ProviderSecretStoring,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func save(
        key: String,
        value: String,
        accessGroup: String?
    ) -> Bool {
        lock.lock()
        values[key] = value
        lock.unlock()
        return true
    }

    func load(key: String, accessGroup: String?) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func delete(key: String, accessGroup: String?) -> Bool {
        lock.lock()
        values.removeValue(forKey: key)
        lock.unlock()
        return true
    }
}
