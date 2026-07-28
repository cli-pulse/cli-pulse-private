import Foundation

public enum QAExperienceSeed {
    public enum Outcome: Equatable, Sendable {
        case skippedUnsafeRuntime
        case preservedExistingConfigs
        case seeded
        case seedFailed
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
    public static func prepare(
        runtime: CLIPulseRuntimeEnvironment,
        defaults: UserDefaults = .standard,
        reset: Bool
    ) -> Outcome {
        guard runtime.isQA, runtime.isLaunchSafe else {
            return .skippedUnsafeRuntime
        }

        if reset {
            for key in resetKeys {
                defaults.removeObject(forKey: key)
            }
        }

        defaults.set(
            true,
            forKey: AgentSetupFeatureFlags.newUsersDefaultsKey
        )
        defaults.set(
            true,
            forKey: AgentSetupFeatureFlags.existingUsersDefaultsKey
        )

        guard defaults.object(
            forKey: ProviderAccountMigration.configsKey
        ) == nil else {
            return .preservedExistingConfigs
        }

        let didSave = ProviderConfigMetadataStore(
            defaults: defaults,
            helperDefaults: nil
        ).save(seedConfigs)
        guard didSave else {
            return .seedFailed
        }

        defaults.set(seedVersion, forKey: seedMarkerKey)
        return .seeded
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
