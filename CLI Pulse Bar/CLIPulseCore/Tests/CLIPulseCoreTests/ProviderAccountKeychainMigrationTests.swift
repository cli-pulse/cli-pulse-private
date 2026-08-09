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

    private func legacyKey(_ kind: ProviderKind, _ suffix: String) -> String {
        "cli_pulse_provider_\(kind.rawValue)_\(suffix)"
    }

    private func accountKey(_ accountID: UUID, _ suffix: String) -> String {
        "cli_pulse_provider_account_\(accountID.uuidString)_\(suffix)"
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
