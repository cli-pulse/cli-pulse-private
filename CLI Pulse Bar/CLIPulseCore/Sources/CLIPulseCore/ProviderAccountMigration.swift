import Foundation

public enum ProviderAccountMigration {
    public static let currentSchemaVersion = 3
    public static let configsKey = "cli_pulse_provider_configs"
    public static let schemaVersionKey = "cli_pulse_provider_configs_schema_version"
    public static let backupKey = "cli_pulse_provider_configs_v1_backup"

    public struct Result: Sendable {
        public let configs: [ProviderConfig]
        public let didMigrate: Bool

        public init(configs: [ProviderConfig], didMigrate: Bool) {
            self.configs = configs
            self.didMigrate = didMigrate
        }
    }

    public enum MigrationError: LocalizedError {
        case invalidStoredConfig
        case encodingFailed
        case verificationFailed

        public var errorDescription: String? {
            switch self {
            case .invalidStoredConfig:
                return "The stored provider configuration could not be decoded."
            case .encodingFailed:
                return "The migrated provider configuration could not be encoded."
            case .verificationFailed:
                return "The migrated provider configuration could not be verified."
            }
        }
    }

    public static func migrateIfNeeded(
        defaults: UserDefaults,
        makeAccountID: () -> UUID = UUID.init,
        now: () -> Date = Date.init
    ) throws -> Result? {
        guard let originalData = defaults.data(forKey: configsKey) else {
            return nil
        }

        let decoder = JSONDecoder()
        let originalSchemaVersion =
            defaults.object(forKey: schemaVersionKey) as? Int
        if defaults.integer(forKey: schemaVersionKey)
            >= currentSchemaVersion
        {
            guard let configs = try? decoder.decode([ProviderConfig].self, from: originalData) else {
                throw MigrationError.invalidStoredConfig
            }
            return Result(configs: configs, didMigrate: false)
        }

        if let currentConfigs = try? decoder.decode([ProviderConfig].self, from: originalData) {
            let upgradedConfigs =
                upgradeMetadata(
                    in: currentConfigs,
                    migrationDate: now()
                )
            let persistedConfigs = try persist(
                upgradedConfigs,
                originalData: originalData,
                originalSchemaVersion: originalSchemaVersion,
                defaults: defaults,
                createBackup: false
            )
            defaults.set(currentSchemaVersion, forKey: schemaVersionKey)
            return Result(configs: persistedConfigs, didMigrate: true)
        }

        let legacyConfigs: [LegacyProviderConfigV1]
        do {
            legacyConfigs = try decoder.decode([LegacyProviderConfigV1].self, from: originalData)
        } catch {
            throw MigrationError.invalidStoredConfig
        }

        let migratedConfigs =
            upgradeMetadata(
                in: legacyConfigs.map {
                    $0.providerConfig(accountID: makeAccountID())
                },
                migrationDate: now()
            )
        let persistedConfigs = try persist(
            migratedConfigs,
            originalData: originalData,
            originalSchemaVersion: originalSchemaVersion,
            defaults: defaults,
            createBackup: true
        )

        defaults.set(currentSchemaVersion, forKey: schemaVersionKey)
        return Result(configs: persistedConfigs, didMigrate: true)
    }

    private static func upgradeMetadata(
        in configs: [ProviderConfig],
        migrationDate: Date
    ) -> [ProviderConfig] {
        var result = configs
        for index in result.indices {
            let override = result[index].planOverride?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if override?.isEmpty == false,
               result[index].planOverrideUpdatedAt == nil {
                result[index].planOverrideUpdatedAt = migrationDate
            }
        }
        for kind in ProviderKind.allCases {
            let indices = result.indices.filter {
                result[$0].kind == kind
            }
            guard
                !indices.isEmpty,
                !indices.contains(where: {
                    result[$0].legacySecretMigrationEligible == true
                }),
                let target = indices.min(by: {
                    let lhs = result[$0]
                    let rhs = result[$1]
                    if lhs.sortOrder != rhs.sortOrder {
                        return lhs.sortOrder < rhs.sortOrder
                    }
                    return lhs.accountID.uuidString
                        < rhs.accountID.uuidString
                })
            else {
                continue
            }
            result[target].legacySecretMigrationEligible = true
        }
        return result
    }

    private static func persist(
        _ configs: [ProviderConfig],
        originalData: Data,
        originalSchemaVersion: Int?,
        defaults: UserDefaults,
        createBackup: Bool
    ) throws -> [ProviderConfig] {
        let encoded: Data
        do {
            encoded = try JSONEncoder().encode(configs)
        } catch {
            throw MigrationError.encodingFailed
        }

        let decoder = JSONDecoder()
        guard
            (try? decoder.decode(
                [ProviderConfig].self,
                from: encoded
            )) != nil
        else {
            throw MigrationError.verificationFailed
        }

        if createBackup,
           defaults.data(forKey: backupKey) == nil {
            defaults.set(originalData, forKey: backupKey)
        }
        defaults.set(encoded, forKey: configsKey)

        guard
            let persistedData = defaults.data(forKey: configsKey),
            let persistedConfigs = try? decoder.decode(
                [ProviderConfig].self,
                from: persistedData
            ),
            persistedConfigs.map(\.accountID)
                == configs.map(\.accountID),
            persistedConfigs.map(\.legacySecretMigrationEligible)
                == configs.map(\.legacySecretMigrationEligible),
            persistedConfigs.map(\.planOverrideUpdatedAt)
                == configs.map(\.planOverrideUpdatedAt)
        else {
            defaults.set(originalData, forKey: configsKey)
            if let originalSchemaVersion {
                defaults.set(
                    originalSchemaVersion,
                    forKey: schemaVersionKey
                )
            } else {
                defaults.removeObject(forKey: schemaVersionKey)
            }
            throw MigrationError.verificationFailed
        }
        return persistedConfigs
    }
}

struct LegacyProviderConfigV1: Decodable {
    let kind: ProviderKind
    let isEnabled: Bool
    let sortOrder: Int
    let sourceMode: SourceType
    let cookieSource: CookieSource?
    let accountLabel: String?
    let geminiCliProbeFallback: Bool?

    private enum CodingKeys: String, CodingKey {
        case kind
        case isEnabled
        case sortOrder
        case sourceMode
        case cookieSource
        case accountLabel
        case geminiCliProbeFallback
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(ProviderKind.self, forKey: .kind)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        sourceMode = try container.decodeIfPresent(SourceType.self, forKey: .sourceMode) ?? .auto
        cookieSource = try container.decodeIfPresent(CookieSource.self, forKey: .cookieSource)
        accountLabel = try container.decodeIfPresent(String.self, forKey: .accountLabel)
        geminiCliProbeFallback = try container.decodeIfPresent(
            Bool.self,
            forKey: .geminiCliProbeFallback
        )
    }

    func providerConfig(accountID: UUID) -> ProviderConfig {
        ProviderConfig(
            kind: kind,
            accountID: accountID,
            isEnabled: isEnabled,
            sortOrder: sortOrder,
            sourceMode: sourceMode,
            cookieSource: cookieSource,
            accountLabel: accountLabel,
            geminiCliProbeFallback: geminiCliProbeFallback
        )
    }
}
