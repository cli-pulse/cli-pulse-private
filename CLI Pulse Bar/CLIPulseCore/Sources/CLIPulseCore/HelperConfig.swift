import Foundation

/// Pairing configuration shared between the main app and the Login Item helper.
/// Non-secret fields stored in app group UserDefaults; helperSecret stored in Keychain.
public struct HelperConfig: Codable, Sendable {
    public let deviceId: String
    public let userId: String
    public let deviceName: String
    public let helperVersion: String
    public let helperSecret: String

    public init(deviceId: String, userId: String, deviceName: String,
                helperVersion: String, helperSecret: String) {
        self.deviceId = deviceId
        self.userId = userId
        self.deviceName = deviceName
        self.helperVersion = helperVersion
        self.helperSecret = helperSecret
    }

    // MARK: - App Group Persistence

    private static let suiteName = "group.yyh.CLI-Pulse"
    private static let key = "helper_config"
    private static let secretKeychainKey = "helper_secret"

    /// Injectable persistence boundary used by runtime-isolation tests.
    /// Live closures are created only after the runtime guard passes.
    internal struct PersistenceAccess {
        let loadStoredData: () -> Data?
        let saveStoredData: (Data) -> Void
        let removeStoredData: () -> Void
        let loadSecret: () -> String?
        let saveSecret: (String) -> Void
        let removeSecret: () -> Void
        let loadLegacyFileData: () -> Data?
    }

    /// Resolve on every call so each trusted process uses the namespace
    /// authorized for its runtime channel without changing the app-group
    /// UserDefaults suite above.
    static var keychainAccessGroup: String {
        KeychainHelper.sharedAccessGroup
    }

    /// Non-secret portion stored in UserDefaults.
    private struct StoredConfig: Codable {
        let deviceId: String
        let userId: String
        let deviceName: String
        let helperVersion: String
    }

    /// Read config from shared UserDefaults + Keychain.
    public static func load(
        runtimeEnvironment: CLIPulseRuntimeEnvironment = .current
    ) -> HelperConfig? {
        guard runtimeEnvironment.allowsHelperConfigurationAccess else {
            return nil
        }
        return loadAllowed(
            persistence: livePersistence(
                runtimeEnvironment: runtimeEnvironment
            )
        )
    }

    internal static func load(
        runtimeEnvironment: CLIPulseRuntimeEnvironment,
        persistence: PersistenceAccess
    ) -> HelperConfig? {
        guard runtimeEnvironment.allowsHelperConfigurationAccess else {
            return nil
        }
        return loadAllowed(persistence: persistence)
    }

    private static func loadAllowed(
        persistence: PersistenceAccess
    ) -> HelperConfig? {
        guard let data = persistence.loadStoredData(),
              let stored = try? JSONDecoder().decode(
                  StoredConfig.self,
                  from: data
              ) else {
            return nil
        }
        // Read secret from Keychain; fall back to legacy UserDefaults migration
        let secret = persistence.loadSecret()
            ?? migrateLegacySecret(using: persistence)
            ?? ""
        guard !secret.isEmpty else { return nil }
        return HelperConfig(
            deviceId: stored.deviceId,
            userId: stored.userId,
            deviceName: stored.deviceName,
            helperVersion: stored.helperVersion,
            helperSecret: secret
        )
    }

    /// 2026-05-08: bug observed in production — when a user signs into the
    /// macOS app under a NEW Supabase account while the app-group already
    /// holds a `helper_config` from a PRIOR account, the stale `deviceId`
    /// + `userId` are silently used by the upload path. The server's
    /// `upsert_daily_usage(p_device_id)` then fails the ownership check
    /// (`devices.user_id` of the stored device != `auth.uid()` of the new
    /// JWT) and raises errcode 42501 → HTTP 403. The Mac sees
    /// `[syncDailyUsage] failed: HTTP 403` every refresh forever; the
    /// iPhone reads stale cloud data.
    ///
    /// `loadIfMatches(...)` returns the config ONLY when the stored
    /// `userId` equals the currently-authenticated user_id (e.g. the
    /// `sub` claim of the access token). Callers that need to send
    /// `p_device_id` MUST use this guarded variant — passing nil for
    /// `p_device_id` is the safe fallback (the server then attributes
    /// the upsert to the sentinel UUID instead of failing the device
    /// check; see migrate_v0.37_daily_usage_device_id.sql).
    public static func loadIfMatches(
        authenticatedUserId: String?,
        runtimeEnvironment: CLIPulseRuntimeEnvironment = .current
    ) -> HelperConfig? {
        guard runtimeEnvironment.allowsHelperConfigurationAccess else {
            return nil
        }
        return loadIfMatchesAllowed(
            authenticatedUserId: authenticatedUserId,
            persistence: livePersistence(
                runtimeEnvironment: runtimeEnvironment
            )
        )
    }

    internal static func loadIfMatches(
        authenticatedUserId: String?,
        runtimeEnvironment: CLIPulseRuntimeEnvironment,
        persistence: PersistenceAccess
    ) -> HelperConfig? {
        guard runtimeEnvironment.allowsHelperConfigurationAccess else {
            return nil
        }
        return loadIfMatchesAllowed(
            authenticatedUserId: authenticatedUserId,
            persistence: persistence
        )
    }

    private static func loadIfMatchesAllowed(
        authenticatedUserId: String?,
        persistence: PersistenceAccess
    ) -> HelperConfig? {
        guard let cfg = loadAllowed(persistence: persistence) else {
            return nil
        }
        guard let auth = authenticatedUserId, !auth.isEmpty else {
            // No authenticated user yet — caller shouldn't be sending
            // p_device_id at all.
            return nil
        }
        guard cfg.userId == auth else {
            // Cross-account leak: refuse to surface the stale config.
            return nil
        }
        return cfg
    }

    /// Write config: non-secret fields to UserDefaults, secret to Keychain.
    public static func save(
        _ config: HelperConfig,
        runtimeEnvironment: CLIPulseRuntimeEnvironment = .current
    ) {
        guard runtimeEnvironment.allowsHelperConfigurationAccess else {
            return
        }
        saveAllowed(
            config,
            persistence: livePersistence(
                runtimeEnvironment: runtimeEnvironment
            )
        )
    }

    internal static func save(
        _ config: HelperConfig,
        runtimeEnvironment: CLIPulseRuntimeEnvironment,
        persistence: PersistenceAccess
    ) {
        guard runtimeEnvironment.allowsHelperConfigurationAccess else {
            return
        }
        saveAllowed(config, persistence: persistence)
    }

    private static func saveAllowed(
        _ config: HelperConfig,
        persistence: PersistenceAccess
    ) {
        let stored = StoredConfig(
            deviceId: config.deviceId,
            userId: config.userId,
            deviceName: config.deviceName,
            helperVersion: config.helperVersion
        )
        guard let data = try? JSONEncoder().encode(stored) else { return }
        persistence.saveStoredData(data)
        persistence.saveSecret(config.helperSecret)
    }

    /// Remove config from shared UserDefaults and Keychain.
    public static func remove(
        runtimeEnvironment: CLIPulseRuntimeEnvironment = .current
    ) {
        guard runtimeEnvironment.allowsHelperConfigurationAccess else {
            return
        }
        removeAllowed(
            persistence: livePersistence(
                runtimeEnvironment: runtimeEnvironment
            )
        )
    }

    internal static func remove(
        runtimeEnvironment: CLIPulseRuntimeEnvironment,
        persistence: PersistenceAccess
    ) {
        guard runtimeEnvironment.allowsHelperConfigurationAccess else {
            return
        }
        removeAllowed(persistence: persistence)
    }

    private static func removeAllowed(
        persistence: PersistenceAccess
    ) {
        persistence.removeStoredData()
        persistence.removeSecret()
    }

    /// Migrate helperSecret from old full-config UserDefaults to Keychain.
    private static func migrateLegacySecret(
        using persistence: PersistenceAccess
    ) -> String? {
        guard let data = persistence.loadStoredData(),
              let legacy = try? JSONDecoder().decode(HelperConfig.self, from: data),
              !legacy.helperSecret.isEmpty else {
            return nil
        }
        // Move secret to Keychain and re-save without it in UserDefaults
        persistence.saveSecret(legacy.helperSecret)
        return legacy.helperSecret
    }

    // MARK: - Migration from Python helper

    /// Attempt to import config from the legacy Python helper JSON file.
    /// Path: ~/.cli-pulse-helper.json
    public static func importFromLegacy(
        runtimeEnvironment: CLIPulseRuntimeEnvironment = .current
    ) -> HelperConfig? {
        guard runtimeEnvironment.allowsHelperConfigurationAccess else {
            return nil
        }
        return importFromLegacyAllowed(
            persistence: livePersistence(
                runtimeEnvironment: runtimeEnvironment
            )
        )
    }

    internal static func importFromLegacy(
        runtimeEnvironment: CLIPulseRuntimeEnvironment,
        persistence: PersistenceAccess
    ) -> HelperConfig? {
        guard runtimeEnvironment.allowsHelperConfigurationAccess else {
            return nil
        }
        return importFromLegacyAllowed(persistence: persistence)
    }

    private static func importFromLegacyAllowed(
        persistence: PersistenceAccess
    ) -> HelperConfig? {
        #if os(macOS)
        guard let data = persistence.loadLegacyFileData(),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deviceId = json["device_id"] as? String,
              let userId = json["user_id"] as? String,
              let helperSecret = json["helper_secret"] as? String else {
            return nil
        }
        return HelperConfig(
            deviceId: deviceId,
            userId: userId,
            deviceName: json["device_name"] as? String ?? Host.current().localizedName ?? "Mac",
            helperVersion: json["helper_version"] as? String ?? "1.0.0",
            helperSecret: helperSecret
        )
        #else
        return nil
        #endif
    }

    private static func livePersistence(
        runtimeEnvironment: CLIPulseRuntimeEnvironment
    ) -> PersistenceAccess {
        let accessGroup = runtimeEnvironment.keychainAccessGroup
        return PersistenceAccess(
            loadStoredData: {
                UserDefaults(suiteName: suiteName)?.data(forKey: key)
            },
            saveStoredData: { data in
                UserDefaults(suiteName: suiteName)?.set(data, forKey: key)
            },
            removeStoredData: {
                UserDefaults(suiteName: suiteName)?.removeObject(forKey: key)
            },
            loadSecret: {
                KeychainHelper.load(
                    key: secretKeychainKey,
                    accessGroup: accessGroup
                )
            },
            saveSecret: { secret in
                KeychainHelper.save(
                    key: secretKeychainKey,
                    value: secret,
                    accessGroup: accessGroup
                )
            },
            removeSecret: {
                KeychainHelper.delete(
                    key: secretKeychainKey,
                    accessGroup: accessGroup
                )
            },
            loadLegacyFileData: {
                #if os(macOS)
                let path = (NSHomeDirectory() as NSString)
                    .appendingPathComponent(".cli-pulse-helper.json")
                return FileManager.default.contents(atPath: path)
                #else
                return nil
                #endif
            }
        )
    }
}
