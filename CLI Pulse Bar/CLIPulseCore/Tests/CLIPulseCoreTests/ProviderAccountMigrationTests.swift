import Foundation
import XCTest
@testable import CLIPulseCore

final class ProviderAccountMigrationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ProviderAccountMigrationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testLegacyConfigMigratesToStableAccountID() throws {
        let original = try legacyPayload()
        let firstID = try XCTUnwrap(UUID(uuidString: "11111111-1111-4111-8111-111111111111"))
        let unexpectedSecondID = try XCTUnwrap(UUID(uuidString: "22222222-2222-4222-8222-222222222222"))
        defaults.set(original, forKey: ProviderAccountMigration.configsKey)

        let first = try XCTUnwrap(ProviderAccountMigration.migrateIfNeeded(
            defaults: defaults,
            makeAccountID: { firstID }
        ))
        let second = try XCTUnwrap(ProviderAccountMigration.migrateIfNeeded(
            defaults: defaults,
            makeAccountID: { unexpectedSecondID }
        ))

        XCTAssertTrue(first.didMigrate)
        XCTAssertFalse(second.didMigrate)
        XCTAssertEqual(first.configs.map(\.accountID), [firstID])
        XCTAssertEqual(second.configs.map(\.accountID), [firstID])
        XCTAssertEqual(
            first.configs.first?.legacySecretMigrationEligible,
            true
        )
        XCTAssertEqual(
            defaults.integer(forKey: ProviderAccountMigration.schemaVersionKey),
            ProviderAccountMigration.currentSchemaVersion
        )
        XCTAssertEqual(defaults.data(forKey: ProviderAccountMigration.backupKey), original)
    }

    func testMigrationPreservesLegacyFields() throws {
        let accountID = try XCTUnwrap(UUID(uuidString: "33333333-3333-4333-8333-333333333333"))
        defaults.set(try legacyPayload(), forKey: ProviderAccountMigration.configsKey)

        let result = try XCTUnwrap(ProviderAccountMigration.migrateIfNeeded(
            defaults: defaults,
            makeAccountID: { accountID }
        ))
        let config = try XCTUnwrap(result.configs.first)

        XCTAssertEqual(config.accountID, accountID)
        XCTAssertEqual(config.kind, .gemini)
        XCTAssertFalse(config.isEnabled)
        XCTAssertEqual(config.sortOrder, 7)
        XCTAssertEqual(config.sourceMode, .oauth)
        XCTAssertEqual(config.cookieSource, .safari)
        XCTAssertEqual(config.accountLabel, "Work")
        XCTAssertEqual(config.geminiCliProbeFallback, true)
        XCTAssertNil(config.planOverride)
    }

    func testInvalidLegacyDataThrowsWithoutOverwritingOriginal() throws {
        let invalid = Data(#"{"not":"an array"}"#.utf8)
        defaults.set(invalid, forKey: ProviderAccountMigration.configsKey)

        XCTAssertThrowsError(
            try ProviderAccountMigration.migrateIfNeeded(defaults: defaults)
        )
        XCTAssertEqual(defaults.data(forKey: ProviderAccountMigration.configsKey), invalid)
        XCTAssertNil(defaults.data(forKey: ProviderAccountMigration.backupKey))
        XCTAssertEqual(defaults.integer(forKey: ProviderAccountMigration.schemaVersionKey), 0)
    }

    func testV2MetadataUpgradeSelectsOneLegacySecretTargetPerProvider()
        throws
    {
        let laterID = try XCTUnwrap(
            UUID(uuidString: "55555555-5555-4555-8555-555555555555")
        )
        let originalID = try XCTUnwrap(
            UUID(uuidString: "66666666-6666-4666-8666-666666666666")
        )
        let configs = [
            ProviderConfig(
                kind: .claude,
                accountID: laterID,
                sortOrder: 20
            ),
            ProviderConfig(
                kind: .claude,
                accountID: originalID,
                sortOrder: 10
            ),
        ]
        defaults.set(
            try JSONEncoder().encode(configs),
            forKey: ProviderAccountMigration.configsKey
        )
        defaults.set(
            2,
            forKey: ProviderAccountMigration.schemaVersionKey
        )

        let result = try XCTUnwrap(
            ProviderAccountMigration.migrateIfNeeded(
                defaults: defaults
            )
        )

        XCTAssertTrue(result.didMigrate)
        XCTAssertEqual(
            result.configs.first {
                $0.accountID == originalID
            }?.legacySecretMigrationEligible,
            true
        )
        XCTAssertNotEqual(
            result.configs.first {
                $0.accountID == laterID
            }?.legacySecretMigrationEligible,
            true
        )
        XCTAssertEqual(
            defaults.integer(
                forKey: ProviderAccountMigration.schemaVersionKey
            ),
            ProviderAccountMigration.currentSchemaVersion
        )
    }

    func testV2MetadataUpgradeBackfillsStableManualPlanRevision()
        throws
    {
        let accountID = try XCTUnwrap(
            UUID(uuidString: "77777777-7777-4777-8777-777777777777")
        )
        let migrationTime =
            Date(timeIntervalSince1970: 1_774_065_600.125)
        let unexpectedSecondTime =
            migrationTime.addingTimeInterval(3_600)
        let configs = [
            ProviderConfig(
                kind: .claude,
                accountID: accountID,
                planOverride: "Max 20x"
            ),
        ]
        defaults.set(
            try JSONEncoder().encode(configs),
            forKey: ProviderAccountMigration.configsKey
        )
        defaults.set(
            2,
            forKey: ProviderAccountMigration.schemaVersionKey
        )

        let first = try XCTUnwrap(
            ProviderAccountMigration.migrateIfNeeded(
                defaults: defaults,
                now: { migrationTime }
            )
        )
        let second = try XCTUnwrap(
            ProviderAccountMigration.migrateIfNeeded(
                defaults: defaults,
                now: { unexpectedSecondTime }
            )
        )

        XCTAssertTrue(first.didMigrate)
        XCTAssertFalse(second.didMigrate)
        XCTAssertEqual(
            first.configs.first?.planOverrideUpdatedAt,
            migrationTime
        )
        XCTAssertEqual(
            second.configs.first?.planOverrideUpdatedAt,
            migrationTime,
            "the migration revision must be written once, not move on every launch"
        )
    }

    func testClearingPlanOverrideRecordsACloudClearRevision() throws {
        let changedAt = Date(timeIntervalSince1970: 1_774_065_600.125)
        var config = ProviderConfig(
            kind: .claude,
            planOverride: "Max 20x"
        )

        config.setPlanOverride(nil, changedAt: changedAt)

        XCTAssertNil(config.planOverride)
        XCTAssertEqual(config.planOverrideUpdatedAt, changedAt)
    }

    func testNoStoredConfigDoesNotCreateMigrationState() throws {
        let result = try ProviderAccountMigration.migrateIfNeeded(defaults: defaults)

        XCTAssertNil(result)
        XCTAssertNil(defaults.data(forKey: ProviderAccountMigration.backupKey))
        XCTAssertEqual(defaults.integer(forKey: ProviderAccountMigration.schemaVersionKey), 0)
    }

    func testProviderAccountModelsRoundTripWithoutSecrets() throws {
        let accountID = try XCTUnwrap(UUID(uuidString: "44444444-4444-4444-8444-444444444444"))
        let evidence = ProviderPlanEvidence(
            rawValue: "max",
            displayValue: "Max（档位未确认）",
            source: .accountMetadata,
            confidence: .low,
            observedAt: Date(timeIntervalSince1970: 1_774_065_600)
        )
        let usage = ProviderAccountUsage(
            id: accountID,
            provider: .claude,
            accountLabel: "Work",
            planEvidence: evidence,
            quota: 100,
            remaining: 64,
            tiers: [],
            resetTime: "2026-07-25T00:00:00Z",
            observedAt: "2026-07-24T00:00:00Z",
            sourceDeviceID: nil,
            statusText: "36% used"
        )

        let data = try JSONEncoder().encode(usage)
        let decoded = try JSONDecoder().decode(ProviderAccountUsage.self, from: data)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertEqual(decoded, usage)
        XCTAssertFalse(json.localizedCaseInsensitiveContains("apiKey"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("cookie"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("token"))
    }

    private func legacyPayload() throws -> Data {
        try JSONSerialization.data(withJSONObject: [[
            "kind": ProviderKind.gemini.rawValue,
            "isEnabled": false,
            "sortOrder": 7,
            "sourceMode": SourceType.oauth.rawValue,
            "cookieSource": CookieSource.safari.rawValue,
            "accountLabel": "Work",
            "geminiCliProbeFallback": true,
        ]], options: [.sortedKeys])
    }
}
