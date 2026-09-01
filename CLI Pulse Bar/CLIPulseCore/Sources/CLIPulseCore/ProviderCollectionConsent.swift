import Foundation

/// Privacy rollout is deliberately independent from onboarding presentation.
/// Turning a UI experiment off must never grant credential collection, and
/// turning it on must never revoke an existing user's collection by surprise.
public enum ProviderCollectionReviewFeatureFlags {
    public static let existingUsersDefaultsKey =
        "cli_pulse_provider_collection_review_existing_users_v1"

    public static func requiresExistingUserReview(
        defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.bool(forKey: existingUsersDefaultsKey)
    }
}

/// Separates the provider catalog from the set the user authorized CLIPulse to
/// collect. A legacy all-enabled payload without this marker remains visible,
/// but collectors and helpers fail closed until the user reviews a selection.
public enum ProviderCollectionConsent {
    public static let markerDefaultsKey =
        "cli_pulse_provider_consent_version"
    static let selectionSnapshotDefaultsKey =
        "cli_pulse_provider_consent_selection_v2"
    static let installationCohortDefaultsKey =
        "cli_pulse_provider_consent_installation_cohort"
    public static let currentVersion = 2

    private struct SelectionEntry: Codable, Equatable {
        let accountID: String
        let provider: String
        let isEnabled: Bool
    }

    private enum InstallationCohort: String {
        case fresh
        case existing
    }

    public static func isRecorded(
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard
            defaults.integer(forKey: markerDefaultsKey) >= currentVersion,
            defaults.integer(
                forKey: ProviderAccountMigration.schemaVersionKey
            ) >= ProviderAccountMigration.currentSchemaVersion,
            let persistedData = defaults.data(
                forKey: ProviderAccountMigration.configsKey
            ),
            let persistedConfigs = try? JSONDecoder().decode(
                [ProviderConfig].self,
                from: persistedData
            ),
            let expectedSnapshot = selectionSnapshotData(
                for: persistedConfigs
            ),
            defaults.data(forKey: selectionSnapshotDefaultsKey)
                == expectedSnapshot
        else {
            return false
        }
        return true
    }

    /// Staged rollout policy. New installs use account-first onboarding and
    /// must explicitly confirm a selection. Existing installs are
    /// grandfathered until the existing-user review flag is enabled, avoiding
    /// a silent dashboard outage during upgrade.
    public static func isCollectionAuthorized(
        defaults: UserDefaults = .standard
    ) -> Bool {
        if isRecorded(defaults: defaults) { return true }
        // A marker without its matching durable selection is a partial or
        // corrupt commit. Never fall through to legacy grandfathering.
        if defaults.integer(forKey: markerDefaultsKey) > 0 {
            return false
        }
        guard let cohort = installationCohort(defaults: defaults) else {
            // A corrupt future/unknown classification must not silently grant
            // background credential access.
            return false
        }
        switch cohort {
        case .fresh:
            // Fresh installs are always consent-gated, independent of whether
            // the onboarding UI experiment is currently shown.
            return false
        case .existing:
            return !ProviderCollectionReviewFeatureFlags
                .requiresExistingUserReview(defaults: defaults)
        }
    }

    /// Commit consent only after the exact provider selection has already been
    /// persisted and verified. The snapshot contains no credential material;
    /// it binds the consent marker to account identity, provider, and enabled
    /// state so marker-only or stale-selection crashes fail closed.
    @discardableResult
    public static func record(
        configs: [ProviderConfig],
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard
            defaults.integer(
                forKey: ProviderAccountMigration.schemaVersionKey
            ) >= ProviderAccountMigration.currentSchemaVersion,
            let persistedData = defaults.data(
                forKey: ProviderAccountMigration.configsKey
            ),
            let persistedConfigs = try? JSONDecoder().decode(
                [ProviderConfig].self,
                from: persistedData
            ),
            let expectedSnapshot = selectionSnapshotData(for: configs),
            selectionSnapshotData(for: persistedConfigs)
                == expectedSnapshot
        else {
            return false
        }

        defaults.set(currentVersion, forKey: markerDefaultsKey)
        defaults.set(
            expectedSnapshot,
            forKey: selectionSnapshotDefaultsKey
        )
        return defaults.integer(forKey: markerDefaultsKey)
                >= currentVersion
            && defaults.data(forKey: selectionSnapshotDefaultsKey)
                == expectedSnapshot
            && isRecorded(defaults: defaults)
    }

    public static func collectibleConfigs(
        _ configs: [ProviderConfig],
        consentRecorded: Bool
    ) -> [ProviderConfig] {
        guard consentRecorded else { return [] }
        return configs.filter(\.isEnabled)
    }

    /// Keep account identity in the helper mirror while disabling collection
    /// for an unreviewed legacy selection.
    public static func helperMirrorConfigs(
        _ configs: [ProviderConfig],
        consentRecorded: Bool
    ) -> [ProviderConfig] {
        guard consentRecorded else { return [] }
        return configs.filter(\.isEnabled)
    }

    /// Capture the install cohort exactly once, before this release's own
    /// metadata writes can make a fresh install look like a returning user.
    /// Feature flags remain live; only the fresh/existing classification is
    /// durable.
    static func captureInstallationCohort(
        defaults: UserDefaults
    ) {
        _ = installationCohort(defaults: defaults)
    }

    private static func installationCohort(
        defaults: UserDefaults
    ) -> InstallationCohort? {
        if let stored = defaults.object(
            forKey: installationCohortDefaultsKey
        ) {
            guard let rawValue = stored as? String else { return nil }
            return InstallationCohort(rawValue: rawValue)
        }

        let cohort: InstallationCohort = AgentSetupStateStore
            .hasUsedThisAppBefore(defaults)
            ? .existing
            : .fresh
        defaults.set(
            cohort.rawValue,
            forKey: installationCohortDefaultsKey
        )
        return cohort
    }

    private static func selectionSnapshotData(
        for configs: [ProviderConfig]
    ) -> Data? {
        let entries = configs
            .map {
                SelectionEntry(
                    accountID: $0.accountID.uuidString.lowercased(),
                    provider: $0.kind.rawValue,
                    isEnabled: $0.isEnabled
                )
            }
            .sorted {
                if $0.accountID != $1.accountID {
                    return $0.accountID < $1.accountID
                }
                return $0.provider < $1.provider
            }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(entries)
    }
}
