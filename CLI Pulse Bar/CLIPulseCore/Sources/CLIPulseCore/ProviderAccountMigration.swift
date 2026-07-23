import Foundation

public enum ProviderAccountMigration {
    public static let currentSchemaVersion = 2
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
        makeAccountID: () -> UUID = UUID.init
    ) throws -> Result? {
        guard let originalData = defaults.data(forKey: configsKey) else {
            return nil
        }

        let decoder = JSONDecoder()
        if defaults.integer(forKey: schemaVersionKey) >= currentSchemaVersion {
            guard let configs = try? decoder.decode([ProviderConfig].self, from: originalData) else {
                throw MigrationError.invalidStoredConfig
            }
            return Result(configs: configs, didMigrate: false)
        }

        if let currentConfigs = try? decoder.decode([ProviderConfig].self, from: originalData) {
            defaults.set(currentSchemaVersion, forKey: schemaVersionKey)
            return Result(configs: currentConfigs, didMigrate: false)
        }

        let legacyConfigs: [LegacyProviderConfigV1]
        do {
            legacyConfigs = try decoder.decode([LegacyProviderConfigV1].self, from: originalData)
        } catch {
            throw MigrationError.invalidStoredConfig
        }

        let migratedConfigs = legacyConfigs.map {
            $0.providerConfig(accountID: makeAccountID())
        }

        let encoded: Data
        do {
            encoded = try JSONEncoder().encode(migratedConfigs)
        } catch {
            throw MigrationError.encodingFailed
        }

        guard (try? decoder.decode([ProviderConfig].self, from: encoded)) != nil else {
            throw MigrationError.verificationFailed
        }

        if defaults.data(forKey: backupKey) == nil {
            defaults.set(originalData, forKey: backupKey)
        }
        defaults.set(encoded, forKey: configsKey)

        guard
            let persistedData = defaults.data(forKey: configsKey),
            let persistedConfigs = try? decoder.decode([ProviderConfig].self, from: persistedData),
            persistedConfigs.map(\.accountID) == migratedConfigs.map(\.accountID)
        else {
            defaults.set(originalData, forKey: configsKey)
            defaults.removeObject(forKey: schemaVersionKey)
            throw MigrationError.verificationFailed
        }

        defaults.set(currentSchemaVersion, forKey: schemaVersionKey)
        return Result(configs: persistedConfigs, didMigrate: true)
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
