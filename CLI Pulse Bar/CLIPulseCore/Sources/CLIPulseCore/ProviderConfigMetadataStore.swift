import Foundation

/// Persists ProviderConfig's Codable metadata without reading, writing, or
/// deleting any account secret. Interactive credential editors continue to use
/// `ProviderConfig.saveSecrets()` explicitly; passive onboarding completion
/// uses this store so a transient Keychain read failure cannot erase a secret.
public struct ProviderConfigMetadataStore {
    private let defaults: UserDefaults
    private let helperDefaults: UserDefaults?
    private let encoder: JSONEncoder

    public init(
        defaults: UserDefaults = .standard,
        helperDefaults: UserDefaults? = UserDefaults(
            suiteName: HelperIPC.suiteName
        ),
        encoder: JSONEncoder = JSONEncoder()
    ) {
        self.defaults = defaults
        self.helperDefaults = helperDefaults
        self.encoder = encoder
    }

    @discardableResult
    public func save(
        _ configs: [ProviderConfig],
        helperCollectionAuthorized authorizationOverride: Bool? = nil
    ) -> Bool {
        // Freeze fresh/existing classification before this write can create
        // installation evidence. Helper authorization itself is evaluated
        // only after the exact persisted selection has been read back.
        ProviderCollectionConsent.captureInstallationCohort(
            defaults: defaults
        )
        guard let data = try? encoder.encode(configs) else {
            return false
        }

        defaults.set(
            data,
            forKey: ProviderAccountMigration.configsKey
        )
        defaults.set(
            ProviderAccountMigration.currentSchemaVersion,
            forKey: ProviderAccountMigration.schemaVersionKey
        )
        guard
            defaults.data(
                forKey: ProviderAccountMigration.configsKey
            ) == data,
            defaults.integer(
                forKey: ProviderAccountMigration.schemaVersionKey
            ) == ProviderAccountMigration.currentSchemaVersion
        else {
            return false
        }
        let postSaveAuthorized =
            ProviderCollectionConsent.isCollectionAuthorized(
                defaults: defaults
            )
        // `false` is the first phase of an explicit consent transaction and
        // always empties the helper. `true` cannot grant by itself: the
        // post-write selection must still match the durable consent snapshot.
        // For ordinary saves, post-write authority is the single source of
        // truth, preventing a previously authorized selection from projecting
        // a newly changed, unconfirmed provider set into the helper.
        let collectionAuthorized = authorizationOverride == false
            ? false
            : postSaveAuthorized
        let mirrorConfigs = ProviderCollectionConsent.helperMirrorConfigs(
            configs,
            consentRecorded: collectionAuthorized
        )
        guard let mirrorData = try? encoder.encode(mirrorConfigs) else {
            return false
        }
        helperDefaults?.set(
            mirrorData,
            forKey: HelperIPC.providerConfigsKey
        )
        helperDefaults?.set(
            defaults.bool(
                forKey: ProviderAccountFeatureFlags.writeDefaultsKey
            ),
            forKey: HelperIPC.providerAccountsWriteV2Key
        )
        if let helperDefaults {
            guard
                helperDefaults.data(
                    forKey: HelperIPC.providerConfigsKey
                ) == mirrorData,
                helperDefaults.bool(
                    forKey: HelperIPC.providerAccountsWriteV2Key
                ) == defaults.bool(
                    forKey:
                        ProviderAccountFeatureFlags
                            .writeDefaultsKey
                )
            else {
                return false
            }
        }
        return true
    }
}
