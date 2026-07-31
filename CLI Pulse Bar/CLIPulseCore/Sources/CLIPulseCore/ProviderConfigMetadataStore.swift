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
    public func save(_ configs: [ProviderConfig]) -> Bool {
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
        helperDefaults?.set(
            data,
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
                ) == data,
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
