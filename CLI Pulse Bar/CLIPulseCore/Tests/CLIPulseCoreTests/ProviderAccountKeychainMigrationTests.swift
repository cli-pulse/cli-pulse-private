import Foundation
import XCTest
@testable import CLIPulseCore

final class ProviderAccountKeychainMigrationTests: XCTestCase {
    func testSameProviderAccountsSaveAndDeleteWithoutCollision() throws {
        let store = InMemoryProviderSecretStore()
        let accountA = try XCTUnwrap(
            UUID(uuidString: "11111111-1111-4111-8111-111111111111")
        )
        let accountB = try XCTUnwrap(
            UUID(uuidString: "22222222-2222-4222-8222-222222222222")
        )
        let configA = ProviderConfig(
            kind: .claude,
            accountID: accountA,
            apiKey: "account-a-api-key",
            manualCookieHeader: "account-a-cookie"
        )
        let configB = ProviderConfig(
            kind: .claude,
            accountID: accountB,
            apiKey: "account-b-api-key",
            manualCookieHeader: "account-b-cookie"
        )

        configA.saveSecrets(using: store)
        configB.saveSecrets(using: store)

        var loadedA = ProviderConfig(kind: .claude, accountID: accountA)
        var loadedB = ProviderConfig(kind: .claude, accountID: accountB)
        loadedA.loadSecrets(using: store)
        loadedB.loadSecrets(using: store)

        XCTAssertEqual(loadedA.apiKey, "account-a-api-key")
        XCTAssertEqual(loadedA.manualCookieHeader, "account-a-cookie")
        XCTAssertEqual(loadedB.apiKey, "account-b-api-key")
        XCTAssertEqual(loadedB.manualCookieHeader, "account-b-cookie")

        configA.deleteSecrets(using: store)

        loadedA.loadSecrets(using: store)
        loadedB.loadSecrets(using: store)

        XCTAssertNil(loadedA.apiKey)
        XCTAssertNil(loadedA.manualCookieHeader)
        XCTAssertEqual(loadedB.apiKey, "account-b-api-key")
        XCTAssertEqual(loadedB.manualCookieHeader, "account-b-cookie")
    }

    func testLegacySecretsCopyToAccountSlotsAndRemainReadableWithoutLegacy() throws {
        let store = InMemoryProviderSecretStore()
        let accountID = try XCTUnwrap(
            UUID(uuidString: "33333333-3333-4333-8333-333333333333")
        )
        let group = ProviderConfig.secretsAccessGroup
        store.save(
            key: legacyKey(.gemini, "apiKey"),
            value: "legacy-api-key",
            accessGroup: group
        )
        store.save(
            key: legacyKey(.gemini, "cookie"),
            value: "legacy-cookie",
            accessGroup: group
        )
        var config = ProviderConfig(
            kind: .gemini,
            accountID: accountID,
            legacySecretMigrationEligible: true
        )

        config.loadSecrets(using: store)

        XCTAssertEqual(config.apiKey, "legacy-api-key")
        XCTAssertEqual(config.manualCookieHeader, "legacy-cookie")
        XCTAssertEqual(
            store.load(key: legacyKey(.gemini, "apiKey"), accessGroup: group),
            "legacy-api-key",
            "The first migration version must retain the legacy slot for rollback."
        )

        store.delete(key: legacyKey(.gemini, "apiKey"), accessGroup: group)
        store.delete(key: legacyKey(.gemini, "cookie"), accessGroup: group)
        config.apiKey = nil
        config.manualCookieHeader = nil

        config.loadSecrets(using: store)

        XCTAssertEqual(config.apiKey, "legacy-api-key")
        XCTAssertEqual(config.manualCookieHeader, "legacy-cookie")
    }

    func testRepeatedMigrationDoesNotOverwriteAccountScopedValues() throws {
        let store = InMemoryProviderSecretStore()
        let accountID = try XCTUnwrap(
            UUID(uuidString: "44444444-4444-4444-8444-444444444444")
        )
        let group = ProviderConfig.secretsAccessGroup
        store.save(
            key: legacyKey(.claude, "apiKey"),
            value: "stale-legacy-key",
            accessGroup: group
        )
        store.save(
            key: accountKey(accountID, "apiKey"),
            value: "current-account-key",
            accessGroup: group
        )
        var config = ProviderConfig(
            kind: .claude,
            accountID: accountID,
            legacySecretMigrationEligible: true
        )

        config.loadSecrets(using: store)
        config.loadSecrets(using: store)

        XCTAssertEqual(config.apiKey, "current-account-key")
        XCTAssertEqual(
            store.load(key: accountKey(accountID, "apiKey"), accessGroup: group),
            "current-account-key"
        )
        XCTAssertEqual(
            store.load(key: legacyKey(.claude, "apiKey"), accessGroup: group),
            "stale-legacy-key"
        )
    }

    func testDeletingMigratedAccountSecretDoesNotRestoreRetainedLegacyValue() throws {
        let store = InMemoryProviderSecretStore()
        let accountID = try XCTUnwrap(
            UUID(uuidString: "55555555-5555-4555-8555-555555555555")
        )
        let group = ProviderConfig.secretsAccessGroup
        store.save(
            key: legacyKey(.claude, "apiKey"),
            value: "legacy-api-key",
            accessGroup: group
        )
        var config = ProviderConfig(
            kind: .claude,
            accountID: accountID,
            legacySecretMigrationEligible: true
        )
        config.loadSecrets(using: store)
        XCTAssertEqual(config.apiKey, "legacy-api-key")

        config.deleteSecrets(using: store)
        config.apiKey = nil
        config.loadSecrets(using: store)

        XCTAssertNil(config.apiKey)
        XCTAssertEqual(
            store.load(key: legacyKey(.claude, "apiKey"), accessGroup: group),
            "legacy-api-key",
            "The retained rollback slot must not reactivate a deleted account secret."
        )
    }

    func testOnlyDesignatedMigratedAccountCanConsumeLegacySecret() throws {
        let store = InMemoryProviderSecretStore()
        let migratedID = try XCTUnwrap(
            UUID(uuidString: "66666666-6666-4666-8666-666666666666")
        )
        let addedLaterID = try XCTUnwrap(
            UUID(uuidString: "77777777-7777-4777-8777-777777777777")
        )
        let group = ProviderConfig.secretsAccessGroup
        store.save(
            key: legacyKey(.claude, "apiKey"),
            value: "legacy-owner-key",
            accessGroup: group
        )
        var addedLater = ProviderConfig(
            kind: .claude,
            accountID: addedLaterID
        )
        var migrated = ProviderConfig(
            kind: .claude,
            accountID: migratedID,
            legacySecretMigrationEligible: true
        )

        // Model an interruption after the second account metadata was saved but
        // before the original account copied or marked the legacy Keychain slot.
        addedLater.loadSecrets(using: store)
        migrated.loadSecrets(using: store)

        XCTAssertNil(
            addedLater.apiKey,
            "a later same-provider account must never claim the provider-scoped rollback slot"
        )
        XCTAssertEqual(migrated.apiKey, "legacy-owner-key")
    }

    func testDeleteSecretsReportsFailureAndRetainsSecret() throws {
        let store = InMemoryProviderSecretStore()
        let accountID = try XCTUnwrap(
            UUID(uuidString: "88888888-8888-4888-8888-888888888888")
        )
        let config = ProviderConfig(
            kind: .claude,
            accountID: accountID,
            apiKey: "must-remain-retryable"
        )
        config.saveSecrets(using: store)
        store.failingDeleteKeys.insert(
            accountKey(accountID, "apiKey")
        )

        let deleted = config.deleteSecrets(using: store)

        XCTAssertFalse(deleted)
        XCTAssertEqual(
            store.load(
                key: accountKey(accountID, "apiKey"),
                accessGroup: ProviderConfig.secretsAccessGroup
            ),
            "must-remain-retryable"
        )
    }

    func testSaveSecretsReportsKeychainWriteFailure() throws {
        let store = InMemoryProviderSecretStore()
        let accountID = try XCTUnwrap(
            UUID(
                uuidString:
                    "99999999-9999-4999-8999-999999999999"
            )
        )
        let config = ProviderConfig(
            kind: .claude,
            accountID: accountID,
            apiKey: "must-not-be-reported-as-saved"
        )
        store.failingSaveKeys.insert(
            accountKey(accountID, "apiKey")
        )

        XCTAssertFalse(config.saveSecrets(using: store))
        XCTAssertNil(
            store.load(
                key: accountKey(accountID, "apiKey"),
                accessGroup: ProviderConfig.secretsAccessGroup
            )
        )
    }

    func testSaveSecretsRestoresBothEntriesWhenSecondWriteFails()
        throws
    {
        let store = InMemoryProviderSecretStore()
        let accountID = try XCTUnwrap(
            UUID(
                uuidString:
                    "ABABABAB-ABAB-4BAB-8BAB-ABABABABABAB"
            )
        )
        let original = ProviderConfig(
            kind: .claude,
            accountID: accountID,
            apiKey: "old-api-key",
            manualCookieHeader: "old-cookie"
        )
        XCTAssertTrue(original.saveSecrets(using: store))
        store.failingSaveAttemptsByKey[
            accountKey(accountID, "cookie")
        ] = 1
        let edited = ProviderConfig(
            kind: .claude,
            accountID: accountID,
            apiKey: "new-api-key",
            manualCookieHeader: "new-cookie"
        )

        XCTAssertFalse(edited.saveSecrets(using: store))
        XCTAssertEqual(
            store.load(
                key: accountKey(accountID, "apiKey"),
                accessGroup: ProviderConfig.secretsAccessGroup
            ),
            "old-api-key"
        )
        XCTAssertEqual(
            store.load(
                key: accountKey(accountID, "cookie"),
                accessGroup: ProviderConfig.secretsAccessGroup
            ),
            "old-cookie"
        )
    }

    func testSaveSecretsFailsWithoutMutationWhenCheckpointReadFails()
        throws
    {
        let store = InMemoryProviderSecretStore()
        let accountID = try XCTUnwrap(
            UUID(
                uuidString:
                    "ACACACAC-ACAC-4CAC-8CAC-ACACACACACAC"
            )
        )
        let original = ProviderConfig(
            kind: .claude,
            accountID: accountID,
            apiKey: "old-api-key",
            manualCookieHeader: "old-cookie"
        )
        XCTAssertTrue(original.saveSecrets(using: store))
        let apiKey = accountKey(accountID, "apiKey")
        store.failingLoadKeys.insert(apiKey)
        let edited = ProviderConfig(
            kind: .claude,
            accountID: accountID,
            apiKey: "new-api-key",
            manualCookieHeader: "new-cookie"
        )

        XCTAssertFalse(edited.saveSecrets(using: store))

        store.failingLoadKeys.remove(apiKey)
        XCTAssertEqual(
            store.load(
                key: apiKey,
                accessGroup: ProviderConfig.secretsAccessGroup
            ),
            "old-api-key"
        )
        XCTAssertEqual(
            store.load(
                key: accountKey(accountID, "cookie"),
                accessGroup: ProviderConfig.secretsAccessGroup
            ),
            "old-cookie"
        )
    }

    func testRestoreMissingSecretReportsReadFailureAfterDelete()
        throws
    {
        let store = InMemoryProviderSecretStore()
        let accountID = try XCTUnwrap(
            UUID(
                uuidString:
                    "ADADADAD-ADAD-4DAD-8DAD-ADADADADADAD"
            )
        )
        let config = ProviderConfig(
            kind: .claude,
            accountID: accountID
        )
        let checkpoint = try XCTUnwrap(
            config.makeSecretPersistenceCheckpoint(using: store)
        )
        let apiKey = accountKey(accountID, "apiKey")
        XCTAssertTrue(
            store.save(
                key: apiKey,
                value: "must-be-removed",
                accessGroup: ProviderConfig.secretsAccessGroup
            )
        )
        store.failingLoadKeys.insert(apiKey)

        XCTAssertFalse(
            config.restoreSecrets(
                from: checkpoint,
                using: store
            ),
            "a read failure must not verify deletion as successful"
        )

        store.failingLoadKeys.remove(apiKey)
        XCTAssertNil(
            store.load(
                key: apiKey,
                accessGroup: ProviderConfig.secretsAccessGroup
            )
        )
    }

    @MainActor
    func testRemovingMigrationOwnerDeletesLegacySlotsAndOnlyItsAccountSecrets()
        throws
    {
        let store = InMemoryProviderSecretStore()
        let ownerID = try XCTUnwrap(
            UUID(
                uuidString:
                    "AEAEAEAE-AEAE-4EAE-8EAE-AEAEAEAEAEAE"
            )
        )
        let siblingID = try XCTUnwrap(
            UUID(
                uuidString:
                    "AFAFAFAF-AFAF-4FAF-8FAF-AFAFAFAFAFAF"
            )
        )
        let group = ProviderConfig.secretsAccessGroup
        let owner = ProviderConfig(
            kind: .claude,
            accountID: ownerID,
            apiKey: "owner-api-key",
            manualCookieHeader: "owner-cookie",
            legacySecretMigrationEligible: true
        )
        let sibling = ProviderConfig(
            kind: .claude,
            accountID: siblingID,
            apiKey: "sibling-api-key",
            manualCookieHeader: "sibling-cookie"
        )
        XCTAssertTrue(owner.saveSecrets(using: store))
        XCTAssertTrue(sibling.saveSecrets(using: store))
        XCTAssertTrue(
            store.save(
                key: legacyKey(.claude, "apiKey"),
                value: "legacy-api-key",
                accessGroup: group
            )
        )
        XCTAssertTrue(
            store.save(
                key: legacyKey(.claude, "cookie"),
                value: "legacy-cookie",
                accessGroup: group
            )
        )
        let state = try makeIsolatedState(store: store)
        state.providerConfigs = [owner, sibling]

        XCTAssertTrue(state.removeProviderAccount(ownerID))

        XCTAssertEqual(state.providerConfigs.map(\.accountID), [siblingID])
        XCTAssertNil(
            store.load(
                key: legacyKey(.claude, "apiKey"),
                accessGroup: group
            )
        )
        XCTAssertNil(
            store.load(
                key: legacyKey(.claude, "cookie"),
                accessGroup: group
            )
        )
        XCTAssertNil(
            store.load(
                key: markerKey(ownerID, "apiKey"),
                accessGroup: group
            )
        )
        XCTAssertNil(
            store.load(
                key: markerKey(ownerID, "cookie"),
                accessGroup: group
            )
        )
        XCTAssertEqual(
            store.load(
                key: accountKey(siblingID, "apiKey"),
                accessGroup: group
            ),
            "sibling-api-key"
        )
        XCTAssertEqual(
            store.load(
                key: accountKey(siblingID, "cookie"),
                accessGroup: group
            ),
            "sibling-cookie"
        )
    }

    @MainActor
    func testLegacyDeleteFailureKeepsAccountRetryableUntilCleanupCompletes()
        throws
    {
        let store = InMemoryProviderSecretStore()
        let accountID = try XCTUnwrap(
            UUID(
                uuidString:
                    "B0B0B0B0-B0B0-40B0-80B0-B0B0B0B0B0B0"
            )
        )
        let group = ProviderConfig.secretsAccessGroup
        let config = ProviderConfig(
            kind: .claude,
            accountID: accountID,
            apiKey: "account-api-key",
            manualCookieHeader: "account-cookie",
            legacySecretMigrationEligible: true
        )
        XCTAssertTrue(config.saveSecrets(using: store))
        XCTAssertTrue(
            store.save(
                key: legacyKey(.claude, "apiKey"),
                value: "legacy-api-key",
                accessGroup: group
            )
        )
        let legacyCookie = legacyKey(.claude, "cookie")
        XCTAssertTrue(
            store.save(
                key: legacyCookie,
                value: "legacy-cookie",
                accessGroup: group
            )
        )
        store.failingDeleteKeys.insert(legacyCookie)
        let state = try makeIsolatedState(store: store)
        state.providerConfigs = [config]

        XCTAssertFalse(state.removeProviderAccount(accountID))
        XCTAssertEqual(state.providerConfigs.map(\.accountID), [accountID])
        XCTAssertNil(
            store.load(
                key: legacyKey(.claude, "apiKey"),
                accessGroup: group
            ),
            "completed deletion steps may remain monotonic while metadata stays retryable"
        )
        XCTAssertEqual(
            store.load(key: legacyCookie, accessGroup: group),
            "legacy-cookie"
        )
        XCTAssertEqual(
            store.load(
                key: markerKey(accountID, "apiKey"),
                accessGroup: group
            ),
            "1",
            "the marker must prevent retained legacy data from reappearing before retry"
        )

        store.failingDeleteKeys.remove(legacyCookie)

        XCTAssertTrue(state.removeProviderAccount(accountID))
        XCTAssertTrue(state.providerConfigs.isEmpty)
        XCTAssertNil(store.load(key: legacyCookie, accessGroup: group))
        XCTAssertNil(
            store.load(
                key: markerKey(accountID, "apiKey"),
                accessGroup: group
            )
        )
        XCTAssertNil(
            store.load(
                key: markerKey(accountID, "cookie"),
                accessGroup: group
            )
        )
    }

    @MainActor
    func testLegacyReadFailureCannotVerifyAccountRemoval() throws {
        let store = InMemoryProviderSecretStore()
        let accountID = try XCTUnwrap(
            UUID(
                uuidString:
                    "B1B1B1B1-B1B1-41B1-81B1-B1B1B1B1B1B1"
            )
        )
        let group = ProviderConfig.secretsAccessGroup
        let config = ProviderConfig(
            kind: .claude,
            accountID: accountID,
            apiKey: "account-api-key",
            legacySecretMigrationEligible: true
        )
        XCTAssertTrue(config.saveSecrets(using: store))
        let legacyAPIKey = legacyKey(.claude, "apiKey")
        XCTAssertTrue(
            store.save(
                key: legacyAPIKey,
                value: "legacy-api-key",
                accessGroup: group
            )
        )
        store.failingLoadKeys.insert(legacyAPIKey)
        let state = try makeIsolatedState(store: store)
        state.providerConfigs = [config]

        XCTAssertFalse(state.removeProviderAccount(accountID))
        XCTAssertEqual(state.providerConfigs.map(\.accountID), [accountID])

        store.failingLoadKeys.remove(legacyAPIKey)

        XCTAssertTrue(state.removeProviderAccount(accountID))
        XCTAssertTrue(state.providerConfigs.isEmpty)
    }

    @MainActor
    func testMarkerDeleteFailureKeepsAccountRetryableUntilCleanupCompletes()
        throws
    {
        let store = InMemoryProviderSecretStore()
        let accountID = try XCTUnwrap(
            UUID(
                uuidString:
                    "B2B2B2B2-B2B2-42B2-82B2-B2B2B2B2B2B2"
            )
        )
        let group = ProviderConfig.secretsAccessGroup
        let config = ProviderConfig(
            kind: .claude,
            accountID: accountID,
            apiKey: "account-api-key",
            manualCookieHeader: "account-cookie"
        )
        XCTAssertTrue(config.saveSecrets(using: store))
        let cookieMarker = markerKey(accountID, "cookie")
        store.failingDeleteKeys.insert(cookieMarker)
        let state = try makeIsolatedState(store: store)
        state.providerConfigs = [config]

        XCTAssertFalse(state.removeProviderAccount(accountID))
        XCTAssertEqual(state.providerConfigs.map(\.accountID), [accountID])
        XCTAssertNil(
            store.load(
                key: accountKey(accountID, "apiKey"),
                accessGroup: group
            )
        )
        XCTAssertNil(
            store.load(
                key: accountKey(accountID, "cookie"),
                accessGroup: group
            )
        )
        XCTAssertNil(
            store.load(
                key: markerKey(accountID, "apiKey"),
                accessGroup: group
            )
        )
        XCTAssertEqual(
            store.load(key: cookieMarker, accessGroup: group),
            "1"
        )

        store.failingDeleteKeys.remove(cookieMarker)

        XCTAssertTrue(state.removeProviderAccount(accountID))
        XCTAssertTrue(state.providerConfigs.isEmpty)
        XCTAssertNil(store.load(key: cookieMarker, accessGroup: group))
    }

    @MainActor
    func testRemovingNonMigrationSiblingPreservesLegacySlotsAndRemovesMarkers()
        throws
    {
        let store = InMemoryProviderSecretStore()
        let accountID = try XCTUnwrap(
            UUID(
                uuidString:
                    "B3B3B3B3-B3B3-43B3-83B3-B3B3B3B3B3B3"
            )
        )
        let group = ProviderConfig.secretsAccessGroup
        let config = ProviderConfig(
            kind: .claude,
            accountID: accountID,
            apiKey: "sibling-api-key"
        )
        XCTAssertTrue(config.saveSecrets(using: store))
        XCTAssertTrue(
            store.save(
                key: legacyKey(.claude, "apiKey"),
                value: "migration-owner-legacy-key",
                accessGroup: group
            )
        )
        let state = try makeIsolatedState(store: store)
        state.providerConfigs = [config]

        XCTAssertTrue(state.removeProviderAccount(accountID))

        XCTAssertEqual(
            store.load(
                key: legacyKey(.claude, "apiKey"),
                accessGroup: group
            ),
            "migration-owner-legacy-key"
        )
        XCTAssertNil(
            store.load(
                key: markerKey(accountID, "apiKey"),
                accessGroup: group
            )
        )
        XCTAssertNil(
            store.load(
                key: markerKey(accountID, "cookie"),
                accessGroup: group
            )
        )
    }

    #if os(macOS)
    @MainActor
    func testSharedOwnerReleaseFailureKeepsAccountRetryable() throws {
        let store = InMemoryProviderSecretStore()
        let accountID = try XCTUnwrap(
            UUID(
                uuidString:
                    "B4B4B4B4-B4B4-44B4-84B4-B4B4B4B4B4B4"
            )
        )
        let config = ProviderConfig(
            kind: .claude,
            accountID: accountID,
            apiKey: "account-api-key"
        )
        XCTAssertTrue(config.saveSecrets(using: store))
        let state = try makeIsolatedState(
            store: store,
            bundleIdentifier: "yyh.CLI-Pulse"
        )
        state.providerConfigs = [config]

        let ownerSuiteName =
            "ProviderAccountKeychainMigrationTests.Owner.\(UUID().uuidString)"
        let ownerDefaults = try XCTUnwrap(
            UserDefaults(suiteName: ownerSuiteName)
        )
        ownerDefaults.removePersistentDomain(forName: ownerSuiteName)
        let ownerKey =
            "cli_pulse_provider_shared_credential_owner_\(ProviderKind.claude.rawValue)"
        ownerDefaults.set(accountID.uuidString, forKey: ownerKey)

        let originalOwnerDefaults = ProviderSharedCredentialOwner.defaults
        let originalSynchronizeDefaults =
            ProviderSharedCredentialOwner.synchronizeDefaults
        let originalMutationLock =
            ProviderSharedCredentialOwner.mutationLock
        let mutationLockPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(ownerSuiteName).lock")
            .path
        defer {
            ProviderSharedCredentialOwner.defaults = originalOwnerDefaults
            ProviderSharedCredentialOwner.synchronizeDefaults =
                originalSynchronizeDefaults
            ProviderSharedCredentialOwner.mutationLock =
                originalMutationLock
            ownerDefaults.removePersistentDomain(forName: ownerSuiteName)
            try? FileManager.default.removeItem(
                atPath: mutationLockPath
            )
        }
        ProviderSharedCredentialOwner.defaults = ownerDefaults
        ProviderSharedCredentialOwner.synchronizeDefaults = { _ in false }
        ProviderSharedCredentialOwner.mutationLock =
            GeminiCredentialMutationLock(
                lockFilePath: mutationLockPath
            )

        XCTAssertFalse(state.removeProviderAccount(accountID))
        XCTAssertEqual(state.providerConfigs.map(\.accountID), [accountID])
        XCTAssertEqual(
            ownerDefaults.string(forKey: ownerKey),
            accountID.uuidString
        )

        ProviderSharedCredentialOwner.synchronizeDefaults = { _ in true }

        XCTAssertTrue(state.removeProviderAccount(accountID))
        XCTAssertTrue(state.providerConfigs.isEmpty)
        XCTAssertNil(ownerDefaults.string(forKey: ownerKey))
    }
    #endif

    private func legacyKey(_ kind: ProviderKind, _ suffix: String) -> String {
        "cli_pulse_provider_\(kind.rawValue)_\(suffix)"
    }

    private func accountKey(_ accountID: UUID, _ suffix: String) -> String {
        "cli_pulse_provider_account_\(accountID.uuidString)_\(suffix)"
    }

    private func markerKey(_ accountID: UUID, _ suffix: String) -> String {
        "\(accountKey(accountID, suffix))_legacy_migrated"
    }

    @MainActor
    private func makeIsolatedState(
        store: InMemoryProviderSecretStore,
        bundleIdentifier: String =
            "tests.clipulse.provider-account-removal"
    ) throws -> AppState {
        let suiteName =
            "ProviderAccountKeychainMigrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let runtime =
            CLIPulseRuntimeEnvironment.resolveForTesting(
                infoDictionary: [
                    "CFBundleIdentifier":
                        bundleIdentifier,
                ],
                environment: [:]
            )
        return AppState(
            runtimeEnvironment: runtime,
            defaults: defaults,
            providerSecretStore: store,
            performLaunchSetup: false
        )
    }
}

private final class InMemoryProviderSecretStore: ProviderSecretStoring {
    private struct Slot: Hashable {
        let key: String
        let accessGroup: String?
    }

    private var values: [Slot: String] = [:]
    var failingSaveKeys: Set<String> = []
    var failingSaveAttemptsByKey: [String: Int] = [:]
    var failingDeleteKeys: Set<String> = []
    var failingLoadKeys: Set<String> = []

    @discardableResult
    func save(
        key: String,
        value: String,
        accessGroup: String?
    ) -> Bool {
        guard !failingSaveKeys.contains(key) else {
            return false
        }
        if let remaining = failingSaveAttemptsByKey[key],
           remaining > 0
        {
            failingSaveAttemptsByKey[key] = remaining - 1
            return false
        }
        values[Slot(key: key, accessGroup: accessGroup)] = value
        return true
    }

    func load(key: String, accessGroup: String?) -> String? {
        guard !failingLoadKeys.contains(key) else {
            return nil
        }
        return values[Slot(key: key, accessGroup: accessGroup)]
    }

    func read(
        key: String,
        accessGroup: String?
    ) -> ProviderSecretReadResult {
        guard !failingLoadKeys.contains(key) else {
            return .failure
        }
        guard
            let value = values[
                Slot(key: key, accessGroup: accessGroup)
            ]
        else {
            return .missing
        }
        return .value(value)
    }

    @discardableResult
    func delete(key: String, accessGroup: String?) -> Bool {
        guard !failingDeleteKeys.contains(key) else {
            return false
        }
        values.removeValue(forKey: Slot(key: key, accessGroup: accessGroup))
        return true
    }
}
