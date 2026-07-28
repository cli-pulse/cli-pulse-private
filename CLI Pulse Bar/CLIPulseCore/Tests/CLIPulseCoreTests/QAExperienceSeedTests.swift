import Foundation
import XCTest
@testable import CLIPulseCore

final class QAExperienceSeedTests: XCTestCase {
    private struct ExpectedConfig {
        let accountID: UUID
        let kind: ProviderKind
        let sortOrder: Int
        let accountLabel: String
        let planOverride: String
    }

    private let expectedConfigs = [
        ExpectedConfig(
            accountID: UUID(
                uuidString: "A1000000-0000-4000-8000-000000000001"
            )!,
            kind: .codex,
            sortOrder: 0,
            accountLabel: "Codex · Personal",
            planOverride: "Plus"
        ),
        ExpectedConfig(
            accountID: UUID(
                uuidString: "A1000000-0000-4000-8000-000000000002"
            )!,
            kind: .codex,
            sortOrder: 1,
            accountLabel: "Codex · Work",
            planOverride: "Team"
        ),
        ExpectedConfig(
            accountID: UUID(
                uuidString: "B2000000-0000-4000-8000-000000000001"
            )!,
            kind: .claude,
            sortOrder: 2,
            accountLabel: "Claude · Personal",
            planOverride: "Pro"
        ),
        ExpectedConfig(
            accountID: UUID(
                uuidString: "B2000000-0000-4000-8000-000000000002"
            )!,
            kind: .claude,
            sortOrder: 3,
            accountLabel: "Claude · Work",
            planOverride: "Max"
        ),
        ExpectedConfig(
            accountID: UUID(
                uuidString: "C3000000-0000-4000-8000-000000000001"
            )!,
            kind: .gemini,
            sortOrder: 4,
            accountLabel: "Gemini · Personal",
            planOverride: "Advanced"
        ),
    ]

    func testPrepareFailsClosedWithoutMutatingDefaultsForUnsafeRuntimes() throws {
        for runtime in [safeProductionRuntime(), invalidQARuntime()] {
            let defaults = try makeDefaults()
            defer { cleanUp(defaults) }
            defaults.set("keep", forKey: "unrelated_sentinel")
            defaults.set(
                Data("existing".utf8),
                forKey: ProviderAccountMigration.configsKey
            )

            let outcome = QAExperienceSeed.prepare(
                runtime: runtime,
                defaults: defaults,
                reset: true
            )

            XCTAssertEqual(outcome, .skippedUnsafeRuntime)
            XCTAssertEqual(
                defaults.string(forKey: "unrelated_sentinel"),
                "keep"
            )
            XCTAssertEqual(
                defaults.data(
                    forKey: ProviderAccountMigration.configsKey
                ),
                Data("existing".utf8)
            )
            XCTAssertNil(
                defaults.object(
                    forKey: AgentSetupFeatureFlags.newUsersDefaultsKey
                )
            )
            XCTAssertNil(
                defaults.object(
                    forKey: AgentSetupFeatureFlags.existingUsersDefaultsKey
                )
            )
        }
    }

    func testPrepareSeedsExactMetadataOnlyProviderConfigsAndFlags() throws {
        let defaults = try makeDefaults()
        defer { cleanUp(defaults) }

        let outcome = QAExperienceSeed.prepare(
            runtime: safeQARuntime(),
            defaults: defaults,
            reset: false
        )

        XCTAssertEqual(outcome, .seeded)
        let data = try XCTUnwrap(
            defaults.data(forKey: ProviderAccountMigration.configsKey)
        )
        let configs = try JSONDecoder().decode(
            [ProviderConfig].self,
            from: data
        )
        assertExactConfigs(configs)
        XCTAssertEqual(
            defaults.integer(
                forKey: ProviderAccountMigration.schemaVersionKey
            ),
            ProviderAccountMigration.currentSchemaVersion
        )
        XCTAssertEqual(
            defaults.integer(forKey: QAExperienceSeed.seedMarkerKey),
            QAExperienceSeed.seedVersion
        )
        XCTAssertTrue(
            defaults.bool(
                forKey: AgentSetupFeatureFlags.newUsersDefaultsKey
            )
        )
        XCTAssertTrue(
            defaults.bool(
                forKey: AgentSetupFeatureFlags.existingUsersDefaultsKey
            )
        )

        let rawJSON = try XCTUnwrap(String(data: data, encoding: .utf8))
        for forbiddenKey in [
            "apiKey",
            "manualCookieHeader",
            "cookieSource",
            "syncOwnerUserID",
            "sharedCredentialFallbackDisabled",
            "geminiCliProbeFallback",
        ] {
            XCTAssertFalse(
                rawJSON.contains("\"\(forbiddenKey)\""),
                "raw metadata JSON must omit \(forbiddenKey)"
            )
        }
    }

    func testPrepareIsIdempotent() throws {
        let defaults = try makeDefaults()
        defer { cleanUp(defaults) }

        XCTAssertEqual(
            QAExperienceSeed.prepare(
                runtime: safeQARuntime(),
                defaults: defaults,
                reset: false
            ),
            .seeded
        )
        let firstData = try XCTUnwrap(
            defaults.data(forKey: ProviderAccountMigration.configsKey)
        )

        XCTAssertEqual(
            QAExperienceSeed.prepare(
                runtime: safeQARuntime(),
                defaults: defaults,
                reset: false
            ),
            .preservedExistingConfigs
        )
        XCTAssertEqual(
            defaults.data(forKey: ProviderAccountMigration.configsKey),
            firstData
        )
    }

    func testPreparePreservesUndecodableExistingConfigsButEnablesFlags() throws {
        let defaults = try makeDefaults()
        defer { cleanUp(defaults) }
        let existing = Data([0xFF, 0x00, 0x7F])
        defaults.set(
            existing,
            forKey: ProviderAccountMigration.configsKey
        )
        defaults.set(
            777,
            forKey: ProviderAccountMigration.schemaVersionKey
        )

        let outcome = QAExperienceSeed.prepare(
            runtime: safeQARuntime(),
            defaults: defaults,
            reset: false
        )

        XCTAssertEqual(outcome, .preservedExistingConfigs)
        XCTAssertEqual(
            defaults.data(forKey: ProviderAccountMigration.configsKey),
            existing
        )
        XCTAssertEqual(
            defaults.integer(
                forKey: ProviderAccountMigration.schemaVersionKey
            ),
            777
        )
        XCTAssertTrue(
            defaults.bool(
                forKey: AgentSetupFeatureFlags.newUsersDefaultsKey
            )
        )
        XCTAssertTrue(
            defaults.bool(
                forKey: AgentSetupFeatureFlags.existingUsersDefaultsKey
            )
        )
        XCTAssertNil(
            defaults.object(forKey: QAExperienceSeed.seedMarkerKey)
        )
    }

    func testResetReseedsKnownKeysAndPreservesUnrelatedSentinel() throws {
        let defaults = try makeDefaults()
        defer { cleanUp(defaults) }
        defaults.set("keep", forKey: "unrelated_sentinel")
        defaults.set(
            Data("old-configs".utf8),
            forKey: ProviderAccountMigration.configsKey
        )
        defaults.set(
            777,
            forKey: ProviderAccountMigration.schemaVersionKey
        )
        defaults.set(
            Data("old-backup".utf8),
            forKey: ProviderAccountMigration.backupKey
        )
        defaults.set(
            true,
            forKey: AgentSetupStateStore.legacyCompletedKey
        )
        defaults.set(
            777,
            forKey: AgentSetupStateStore.onboardingVersionKey
        )
        defaults.set(
            Data("old-progress".utf8),
            forKey: AgentSetupStateStore.progressKey
        )
        defaults.set(
            true,
            forKey: AgentSetupStateStore.upgradePromptDismissedKey
        )
        defaults.set(
            false,
            forKey: AgentSetupFeatureFlags.newUsersDefaultsKey
        )
        defaults.set(
            false,
            forKey: AgentSetupFeatureFlags.existingUsersDefaultsKey
        )
        defaults.set(
            777,
            forKey: QAExperienceSeed.seedMarkerKey
        )
        defaults.set(true, forKey: QAExperienceSeed.demoModeKey)

        let outcome = QAExperienceSeed.prepare(
            runtime: safeQARuntime(),
            defaults: defaults,
            reset: true
        )

        XCTAssertEqual(outcome, .seeded)
        XCTAssertEqual(
            defaults.string(forKey: "unrelated_sentinel"),
            "keep"
        )
        let data = try XCTUnwrap(
            defaults.data(forKey: ProviderAccountMigration.configsKey)
        )
        assertExactConfigs(
            try JSONDecoder().decode([ProviderConfig].self, from: data)
        )
        XCTAssertEqual(
            defaults.integer(
                forKey: ProviderAccountMigration.schemaVersionKey
            ),
            ProviderAccountMigration.currentSchemaVersion
        )
        XCTAssertNil(
            defaults.object(forKey: ProviderAccountMigration.backupKey)
        )
        XCTAssertNil(
            defaults.object(
                forKey: AgentSetupStateStore.legacyCompletedKey
            )
        )
        XCTAssertNil(
            defaults.object(
                forKey: AgentSetupStateStore.onboardingVersionKey
            )
        )
        XCTAssertNil(
            defaults.object(forKey: AgentSetupStateStore.progressKey)
        )
        XCTAssertNil(
            defaults.object(
                forKey: AgentSetupStateStore.upgradePromptDismissedKey
            )
        )
        XCTAssertFalse(
            defaults.bool(forKey: QAExperienceSeed.demoModeKey)
        )
        XCTAssertTrue(
            defaults.bool(
                forKey: AgentSetupFeatureFlags.newUsersDefaultsKey
            )
        )
        XCTAssertTrue(
            defaults.bool(
                forKey: AgentSetupFeatureFlags.existingUsersDefaultsKey
            )
        )
        XCTAssertEqual(
            defaults.integer(forKey: QAExperienceSeed.seedMarkerKey),
            QAExperienceSeed.seedVersion
        )
    }

    func testKeychainNamespaceAccessorsFollowCurrentRuntime() {
        let runtime = CLIPulseRuntimeEnvironment.current

        XCTAssertEqual(KeychainHelper.service, runtime.keychainService)
        XCTAssertEqual(
            KeychainHelper.sharedAccessGroup,
            runtime.keychainAccessGroup
        )
    }

    private func assertExactConfigs(
        _ configs: [ProviderConfig],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            configs.count,
            expectedConfigs.count,
            file: file,
            line: line
        )
        for (config, expected) in zip(configs, expectedConfigs) {
            XCTAssertEqual(
                config.accountID,
                expected.accountID,
                file: file,
                line: line
            )
            XCTAssertEqual(
                config.kind,
                expected.kind,
                file: file,
                line: line
            )
            XCTAssertEqual(
                config.sortOrder,
                expected.sortOrder,
                file: file,
                line: line
            )
            XCTAssertEqual(
                config.accountLabel,
                expected.accountLabel,
                file: file,
                line: line
            )
            XCTAssertEqual(
                config.planOverride,
                expected.planOverride,
                file: file,
                line: line
            )
            XCTAssertFalse(config.isEnabled, file: file, line: line)
            XCTAssertEqual(
                config.sourceMode,
                .auto,
                file: file,
                line: line
            )
            XCTAssertNil(config.apiKey, file: file, line: line)
            XCTAssertNil(
                config.manualCookieHeader,
                file: file,
                line: line
            )
            XCTAssertNil(config.cookieSource, file: file, line: line)
            XCTAssertNil(config.syncOwnerUserID, file: file, line: line)
            XCTAssertNil(
                config.sharedCredentialFallbackDisabled,
                file: file,
                line: line
            )
            XCTAssertNil(
                config.geminiCliProbeFallback,
                file: file,
                line: line
            )
            XCTAssertFalse(config.hasCredentials, file: file, line: line)
        }
    }

    private func safeQARuntime() -> CLIPulseRuntimeEnvironment {
        resolveRuntime(
            channel: "qa",
            bundleIdentifier: "app.clipulse.qa.local",
            fixedUserHome: "/private/tmp/clipulse-qa-home"
        )
    }

    private func safeProductionRuntime() -> CLIPulseRuntimeEnvironment {
        resolveRuntime(
            channel: nil,
            bundleIdentifier: "yyh.CLI-Pulse",
            fixedUserHome: nil
        )
    }

    private func invalidQARuntime() -> CLIPulseRuntimeEnvironment {
        resolveRuntime(
            channel: "qa",
            bundleIdentifier: "yyh.CLI-Pulse",
            fixedUserHome: "/private/tmp/clipulse-qa-home"
        )
    }

    private func resolveRuntime(
        channel: String?,
        bundleIdentifier: String,
        fixedUserHome: String?
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
                inspectEntry: { _ in .directory },
                resolveRealPath: { $0 }
            )
        )
    }

    private func makeDefaults() throws -> UserDefaults {
        try XCTUnwrap(
            UserDefaults(
                suiteName:
                    "QAExperienceSeedTests.\(UUID().uuidString)"
            )
        )
    }

    private func cleanUp(_ defaults: UserDefaults) {
        let keys = [
            ProviderAccountMigration.configsKey,
            ProviderAccountMigration.schemaVersionKey,
            ProviderAccountMigration.backupKey,
            AgentSetupStateStore.legacyCompletedKey,
            AgentSetupStateStore.onboardingVersionKey,
            AgentSetupStateStore.progressKey,
            AgentSetupStateStore.upgradePromptDismissedKey,
            AgentSetupFeatureFlags.newUsersDefaultsKey,
            AgentSetupFeatureFlags.existingUsersDefaultsKey,
            QAExperienceSeed.seedMarkerKey,
            QAExperienceSeed.demoModeKey,
            "unrelated_sentinel",
        ]
        for key in keys {
            defaults.removeObject(forKey: key)
        }
    }
}
