#if os(macOS)
import Foundation
import Security
import os

/// Bridges credential files from the real filesystem to the app group,
/// so the sandboxed helper can access them without direct file access.
///
/// Flow: Main app resolves bookmarks → reads credential files → writes
/// extracted tokens to app group UserDefaults → Helper reads from app group.
public enum CredentialBridge {

    private static let logger = Logger(subsystem: "yyh.CLI-Pulse", category: "CredentialBridge")
    private static let suiteName = "group.yyh.CLI-Pulse"
    private static let credentialsKey = "bridged_credentials"
    private static let accessGroup = "group.yyh.CLI-Pulse"

    // MARK: - Sync (called by main app during refresh)

    /// Read credential files via bookmarks and write tokens to app group.
    /// Called during each refresh cycle in DataRefreshManager.
    public static func syncCredentialsToAppGroup(
        configs: [ProviderConfig]
    ) {
        let credentials = collectCredentials(
            configs: configs,
            read: { SandboxFileAccess.read(path: $0) }
        )

        // Always replace CLIPulse's cache. If the user disables a provider (or
        // every provider), retaining the previous token snapshot would violate
        // the same consent boundary even though the source credential remains
        // untouched.
        if let jsonData = try? JSONSerialization.data(withJSONObject: [
            "timestamp": sharedISO8601Formatter.string(from: Date()),
            "credentials": credentials,
        ]) {
            saveToKeychain(data: jsonData)
            logger.debug("Bridged \(credentials.count, privacy: .public) credential sets to Keychain")
        }
    }

    static func collectCredentials(
        configs: [ProviderConfig],
        read: (String) -> Data?
    ) -> [String: [String: Any]] {
        var credentials: [String: [String: Any]] = [:]
        let authorizedKinds = Set(
            configs.filter(\.isEnabled).map(\.kind)
        )

        // Codex: ~/.codex/auth.json
        if authorizedKinds.contains(.codex),
           let data = read(expandPath("~/.codex/auth.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let tokens = json["tokens"] as? [String: Any] ?? [:]
            credentials["Codex"] = [
                "access_token": tokens["access_token"] as? String ?? "",
                "refresh_token": tokens["refresh_token"] as? String ?? "",
                "id_token": tokens["id_token"] as? String ?? "",
                "account_id": tokens["account_id"] as? String ?? "",
                "last_refresh": json["last_refresh"] as? String ?? "",
            ]
        }

        // Gemini: ~/.gemini/oauth_creds.json
        if authorizedKinds.contains(.gemini),
           let data = read(expandPath("~/.gemini/oauth_creds.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            credentials["Gemini"] = [
                "access_token": json["access_token"] as? String ?? "",
                "refresh_token": json["refresh_token"] as? String ?? "",
                "id_token": json["id_token"] as? String ?? "",
                "expiry_date": (json["expiry_date"] as? NSNumber)?.doubleValue ?? 0,
            ]
        }

        // Claude: ~/.claude/.credentials.json
        if authorizedKinds.contains(.claude),
           let data = read(expandPath("~/.claude/.credentials.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            credentials["Claude"] = [
                "accessToken": json["accessToken"] as? String ?? "",
                "refreshToken": json["refreshToken"] as? String ?? "",
                "expiresAt": json["expiresAt"] as? String ?? "",
                "rateLimitTier": json["rateLimitTier"] as? String ?? "",
            ]
        }

        // Kilo: ~/.local/share/kilo/auth.json
        if authorizedKinds.contains(.kilo),
           let data = read(expandPath("~/.local/share/kilo/auth.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            credentials["Kilo"] = [
                "access": json["kilo.access"] as? String ?? json["access_token"] as? String ?? "",
            ]
        }

        return credentials
    }

    // MARK: - Read (called by helper or collectors)

    /// Read bridged credentials for a provider from Keychain.
    /// Returns nil if no credentials available or data is stale (>5 minutes).
    public static func readBridgedCredentials(provider: String) -> [String: Any]? {
        guard let data = loadFromKeychain() else { return nil }
        return decodeBridgedCredentials(data, provider: provider)
    }

    /// Pure decode + freshness gate, split out of `readBridgedCredentials` so the
    /// staleness logic is unit-testable without the Keychain. Returns nil when the
    /// blob is malformed JSON, older than `maxAge` (default 5 min), or has no entry
    /// for `provider`. A blob with no/unparseable `timestamp` is treated as fresh —
    /// this matches the prior behavior exactly. `now`/`maxAge` are injectable for
    /// deterministic tests.
    static func decodeBridgedCredentials(_ data: Data, provider: String,
                                         now: Date = Date(), maxAge: TimeInterval = 300) -> [String: Any]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // v1.50: the `if let` chain used to swallow a parse failure — an
        // unparseable timestamp skipped the whole staleness check and the
        // bridged credential was used regardless of age. Tolerant parse, and an
        // age we cannot determine is treated as too old. A stale credential
        // fails a provider call visibly; a silently-accepted one fails in ways
        // the user cannot attribute.
        if let timestampStr = json["timestamp"] as? String {
            guard let timestamp = sharedISO8601Parse(timestampStr),
                  now.timeIntervalSince(timestamp) <= maxAge else {
                return nil
            }
        }
        let allCreds = json["credentials"] as? [String: Any]
        return allCreds?[provider] as? [String: Any]
    }

    // MARK: - Keychain Storage

    private static func keychainQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.clipulse.credential-bridge",
            kSecAttrAccount as String: credentialsKey,
            kSecAttrAccessGroup as String: accessGroup,
        ]
        // Required on macOS for app-group shared Keychain items (data protection keychain)
        if #available(macOS 10.15, *) {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    private static func saveToKeychain(data: Data) {
        let query = keychainQuery()
        // Try update first (atomic), fall back to add
        // NOTE: kSecAttrAccessible must NOT be in update attrs — Apple rejects it
        let updateAttrs: [String: Any] = [
            kSecValueData as String: data,
        ]
        let status = LegacyKeychainUIGate.withInteractionDisabled {
            SecItemUpdate(
                query as CFDictionary,
                updateAttrs as CFDictionary
            )
        }
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            // v1.21 D3: tighter than AfterFirstUnlock — see KeychainHelper.swift
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = LegacyKeychainUIGate.withInteractionDisabled {
                SecItemAdd(addQuery as CFDictionary, nil)
            }
            if addStatus != errSecSuccess {
                logger.error("Keychain save failed: \(addStatus, privacy: .public)")
            }
        } else if status != errSecSuccess {
            logger.error("Keychain update failed: \(status, privacy: .public)")
        }
    }

    private static func loadFromKeychain() -> Data? {
        var query = keychainQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = LegacyKeychainUIGate.withInteractionDisabled {
            SecItemCopyMatching(query as CFDictionary, &item)
        }
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return data
    }

    // MARK: - Helpers

    private static func expandPath(_ path: String) -> String {
        if path.hasPrefix("~/") {
            return (realUserHome() as NSString).appendingPathComponent(String(path.dropFirst(2)))
        }
        return path
    }
}
#endif
