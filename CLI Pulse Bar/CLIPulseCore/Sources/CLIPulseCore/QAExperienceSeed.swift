import Foundation

protocol QAExperienceSeedStore: AnyObject {
    func object(forKey defaultName: String) -> Any?
    func set(_ value: Any?, forKey defaultName: String)
    func removeObject(forKey defaultName: String)
}

extension UserDefaults: QAExperienceSeedStore {}

enum QAExperienceSeed {
    enum Outcome: Equatable, Sendable {
        case skippedUnsafeRuntime
        case invalidExistingConfigs
        case preservedExistingConfigs
        case seeded
        case seedFailed

        var isReady: Bool {
            switch self {
            case .preservedExistingConfigs, .seeded:
                return true
            case .skippedUnsafeRuntime, .invalidExistingConfigs, .seedFailed:
                return false
            }
        }
    }

    static let seedMarkerKey = "cli_pulse_qa_experience_seed_v1"
    static let seedVersion = 1
    static let demoModeKey = "cli_pulse_demo_mode"

    private static let resetKeys = [
        ProviderAccountMigration.configsKey,
        ProviderAccountMigration.schemaVersionKey,
        ProviderAccountMigration.backupKey,
        AgentSetupStateStore.legacyCompletedKey,
        AgentSetupStateStore.onboardingVersionKey,
        AgentSetupStateStore.progressKey,
        AgentSetupStateStore.upgradePromptDismissedKey,
        AgentSetupFeatureFlags.newUsersDefaultsKey,
        AgentSetupFeatureFlags.existingUsersDefaultsKey,
        seedMarkerKey,
        demoModeKey,
    ]

    @discardableResult
    static func prepare(
        runtime: CLIPulseRuntimeEnvironment
    ) -> Outcome {
        prepare(runtime: runtime, store: UserDefaults.standard)
    }

    @discardableResult
    static func prepareForTesting(
        runtime: CLIPulseRuntimeEnvironment,
        defaults: UserDefaults
    ) -> Outcome {
        prepare(runtime: runtime, store: defaults)
    }

    @discardableResult
    static func prepareForTesting(
        runtime: CLIPulseRuntimeEnvironment,
        store: any QAExperienceSeedStore
    ) -> Outcome {
        prepare(runtime: runtime, store: store)
    }

    private static func prepare(
        runtime: CLIPulseRuntimeEnvironment,
        store: any QAExperienceSeedStore
    ) -> Outcome {
        guard runtime.isQA, runtime.isLaunchSafe else {
            return .skippedUnsafeRuntime
        }

        if runtime.shouldResetQAExperience {
            for key in resetKeys {
                store.removeObject(forKey: key)
            }
            guard resetKeys.allSatisfy({
                store.object(forKey: $0) == nil
            }) else {
                return .seedFailed
            }
        }

        store.set(
            true,
            forKey: AgentSetupFeatureFlags.newUsersDefaultsKey
        )
        store.set(
            true,
            forKey: AgentSetupFeatureFlags.existingUsersDefaultsKey
        )

        if !runtime.shouldResetQAExperience,
           let existing = store.object(
            forKey: ProviderAccountMigration.configsKey
           )
        {
            guard let data = existing as? Data,
                  (try? JSONDecoder().decode(
                      [ProviderConfig].self,
                      from: data
                  )) != nil
            else {
                return .invalidExistingConfigs
            }
            guard featureFlagsAreEnabled(in: store) else {
                return .seedFailed
            }
            return .preservedExistingConfigs
        }

        guard let data = try? JSONEncoder().encode(seedConfigs) else {
            return .seedFailed
        }

        store.set(
            data,
            forKey: ProviderAccountMigration.configsKey
        )
        store.set(
            ProviderAccountMigration.currentSchemaVersion,
            forKey: ProviderAccountMigration.schemaVersionKey
        )
        store.set(seedVersion, forKey: seedMarkerKey)

        guard readBackMatchesSeed(in: store) else {
            return .seedFailed
        }
        return .seeded
    }

    private static func featureFlagsAreEnabled(
        in store: any QAExperienceSeedStore
    ) -> Bool {
        boolValue(
            store.object(
                forKey: AgentSetupFeatureFlags.newUsersDefaultsKey
            )
        ) == true
            && boolValue(
                store.object(
                    forKey: AgentSetupFeatureFlags.existingUsersDefaultsKey
                )
            ) == true
    }

    private static func readBackMatchesSeed(
        in store: any QAExperienceSeedStore
    ) -> Bool {
        guard let data = store.object(
            forKey: ProviderAccountMigration.configsKey
        ) as? Data,
              let configs = try? JSONDecoder().decode(
                  [ProviderConfig].self,
                  from: data
              ),
              configsMatchSeed(configs),
              integerValue(
                  store.object(
                      forKey: ProviderAccountMigration.schemaVersionKey
                  )
              ) == ProviderAccountMigration.currentSchemaVersion,
              featureFlagsAreEnabled(in: store),
              integerValue(store.object(forKey: seedMarkerKey))
                == seedVersion
        else {
            return false
        }
        return true
    }

    private static func configsMatchSeed(
        _ configs: [ProviderConfig]
    ) -> Bool {
        let expectedConfigs = seedConfigs
        guard configs.count == expectedConfigs.count else {
            return false
        }
        for (config, expected) in zip(configs, expectedConfigs) {
            guard config.accountID == expected.accountID,
                  config.kind == expected.kind,
                  config.isEnabled == expected.isEnabled,
                  config.sortOrder == expected.sortOrder,
                  config.sourceMode == expected.sourceMode,
                  config.apiKey == expected.apiKey,
                  config.cookieSource == expected.cookieSource,
                  config.manualCookieHeader
                    == expected.manualCookieHeader,
                  config.accountLabel == expected.accountLabel,
                  config.planOverride == expected.planOverride,
                  config.syncOwnerUserID == expected.syncOwnerUserID,
                  config.sharedCredentialFallbackDisabled
                    == expected.sharedCredentialFallbackDisabled,
                  config.geminiCliProbeFallback
                    == expected.geminiCliProbeFallback
            else {
                return false
            }
        }
        return true
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool {
            return value
        }
        return (value as? NSNumber)?.boolValue
    }

    private static func integerValue(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        return (value as? NSNumber)?.intValue
    }

    private static var seedConfigs: [ProviderConfig] {
        [
            makeConfig(
                accountID: "A1000000-0000-4000-8000-000000000001",
                kind: .codex,
                sortOrder: 0,
                accountLabel: "Codex · Personal",
                planOverride: "Plus"
            ),
            makeConfig(
                accountID: "A1000000-0000-4000-8000-000000000002",
                kind: .codex,
                sortOrder: 1,
                accountLabel: "Codex · Work",
                planOverride: "Team"
            ),
            makeConfig(
                accountID: "B2000000-0000-4000-8000-000000000001",
                kind: .claude,
                sortOrder: 2,
                accountLabel: "Claude · Personal",
                planOverride: "Pro"
            ),
            makeConfig(
                accountID: "B2000000-0000-4000-8000-000000000002",
                kind: .claude,
                sortOrder: 3,
                accountLabel: "Claude · Work",
                planOverride: "Max"
            ),
            makeConfig(
                accountID: "C3000000-0000-4000-8000-000000000001",
                kind: .gemini,
                sortOrder: 4,
                accountLabel: "Gemini · Personal",
                planOverride: "Advanced"
            ),
        ]
    }

    private static func makeConfig(
        accountID: String,
        kind: ProviderKind,
        sortOrder: Int,
        accountLabel: String,
        planOverride: String
    ) -> ProviderConfig {
        guard let accountID = UUID(uuidString: accountID) else {
            preconditionFailure("Invalid QA provider account UUID")
        }

        return ProviderConfig(
            kind: kind,
            accountID: accountID,
            isEnabled: false,
            sortOrder: sortOrder,
            sourceMode: .auto,
            apiKey: nil,
            cookieSource: nil,
            manualCookieHeader: nil,
            accountLabel: accountLabel,
            planOverride: planOverride,
            syncOwnerUserID: nil,
            sharedCredentialFallbackDisabled: nil,
            geminiCliProbeFallback: nil
        )
    }
}
