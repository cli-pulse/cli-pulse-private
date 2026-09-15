import Foundation

/// Persists ProviderConfig's Codable metadata without reading, writing, or
/// deleting any account secret. Interactive credential editors continue to use
/// `ProviderConfig.saveSecrets()` explicitly; passive onboarding completion
/// uses this store so a transient Keychain read failure cannot erase a secret.
public struct ProviderConfigMetadataStore {
    struct PersistenceCheckpoint {
        let appConfigs: Data?
        let appSchemaVersion: Int?
        let helperConfigs: Data?
        let helperWriteV2: Bool?
    }

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
        let checkpoint = makePersistenceCheckpoint()

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
            _ = restore(checkpoint)
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
                _ = restore(checkpoint)
                return false
            }
        }
        return true
    }

    func makePersistenceCheckpoint() -> PersistenceCheckpoint {
        PersistenceCheckpoint(
            appConfigs: defaults.data(
                forKey: ProviderAccountMigration.configsKey
            ),
            appSchemaVersion:
                defaults.object(
                    forKey:
                        ProviderAccountMigration.schemaVersionKey
                ) == nil
                ? nil
                : defaults.integer(
                    forKey:
                        ProviderAccountMigration.schemaVersionKey
                ),
            helperConfigs: helperDefaults?.data(
                forKey: HelperIPC.providerConfigsKey
            ),
            helperWriteV2:
                helperDefaults?.object(
                    forKey:
                        HelperIPC.providerAccountsWriteV2Key
                ) == nil
                ? nil
                : helperDefaults?.bool(
                    forKey:
                        HelperIPC.providerAccountsWriteV2Key
                )
        )
    }

    @discardableResult
    func restore(
        _ checkpoint: PersistenceCheckpoint
    ) -> Bool {
        restore(
            checkpoint.appConfigs,
            in: defaults,
            forKey: ProviderAccountMigration.configsKey
        )
        restore(
            checkpoint.appSchemaVersion,
            in: defaults,
            forKey: ProviderAccountMigration.schemaVersionKey
        )
        if let helperDefaults {
            restore(
                checkpoint.helperConfigs,
                in: helperDefaults,
                forKey: HelperIPC.providerConfigsKey
            )
            restore(
                checkpoint.helperWriteV2,
                in: helperDefaults,
                forKey: HelperIPC.providerAccountsWriteV2Key
            )
        }

        let appRestored =
            defaults.data(
                forKey: ProviderAccountMigration.configsKey
            ) == checkpoint.appConfigs
            && optionalInteger(
                defaults,
                key: ProviderAccountMigration.schemaVersionKey
            ) == checkpoint.appSchemaVersion
        let helperRestored: Bool
        if let helperDefaults {
            helperRestored =
                helperDefaults.data(
                    forKey: HelperIPC.providerConfigsKey
                ) == checkpoint.helperConfigs
                && optionalBool(
                    helperDefaults,
                    key: HelperIPC.providerAccountsWriteV2Key
                ) == checkpoint.helperWriteV2
        } else {
            helperRestored = true
        }
        return appRestored && helperRestored
    }

    private func restore(
        _ value: Any?,
        in defaults: UserDefaults,
        forKey key: String
    ) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func optionalInteger(
        _ defaults: UserDefaults,
        key: String
    ) -> Int? {
        defaults.object(forKey: key) == nil
            ? nil
            : defaults.integer(forKey: key)
    }

    private func optionalBool(
        _ defaults: UserDefaults,
        key: String
    ) -> Bool? {
        defaults.object(forKey: key) == nil
            ? nil
            : defaults.bool(forKey: key)
    }
}

/// Opaque rollback point spanning both provider metadata copies and the
/// provider-global compatibility owner records.
public final class ProviderAccountPersistenceCheckpoint {
    private let metadataStore: ProviderConfigMetadataStore
    private let metadataCheckpoint:
        ProviderConfigMetadataStore.PersistenceCheckpoint
    private let ownerCheckpoint:
        ProviderSharedCredentialOwner.PersistenceCheckpoint?
    private let restoresOwner: Bool

    init(
        metadataStore: ProviderConfigMetadataStore,
        metadataCheckpoint:
            ProviderConfigMetadataStore.PersistenceCheckpoint,
        ownerCheckpoint:
            ProviderSharedCredentialOwner.PersistenceCheckpoint?,
        restoresOwner: Bool
    ) {
        self.metadataStore = metadataStore
        self.metadataCheckpoint = metadataCheckpoint
        self.ownerCheckpoint = ownerCheckpoint
        self.restoresOwner = restoresOwner
    }

    @discardableResult
    public func restore() -> Bool {
        let metadataRestored = metadataStore.restore(
            metadataCheckpoint
        )
        let ownerRestored: Bool
        if restoresOwner {
            guard let ownerCheckpoint else {
                return false
            }
            ownerRestored = ProviderSharedCredentialOwner.restore(
                ownerCheckpoint
            )
        } else {
            ownerRestored = true
        }
        return metadataRestored && ownerRestored
    }
}
