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
        var config = ProviderConfig(kind: .gemini, accountID: accountID)

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
        var config = ProviderConfig(kind: .claude, accountID: accountID)

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
        var config = ProviderConfig(kind: .claude, accountID: accountID)
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

    func save(key: String, value: String, accessGroup: String?) {
        values[Slot(key: key, accessGroup: accessGroup)] = value
    }

    func load(key: String, accessGroup: String?) -> String? {
        values[Slot(key: key, accessGroup: accessGroup)]
    }

    func delete(key: String, accessGroup: String?) {
        values.removeValue(forKey: Slot(key: key, accessGroup: accessGroup))
    }
}
