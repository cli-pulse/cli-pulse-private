import Foundation
import Security

/// One user-facing credential-access decision surface.
public struct CredentialAccessScope: Equatable, Sendable {
    public let key: String

    public static let claudeCodeImport = Self(key: "claude-code-import")

    public static func browserSafeStorage(
        provider: String,
        browser: String
    ) -> Self {
        Self(key: "browser.\(provider.lowercased()).\(browser.lowercased())")
    }

    public static func safeStorageService(_ service: String) -> Self {
        Self(key: "safe-storage.\(service.lowercased())")
    }
}

/// Remembers a cancelled credential request across refreshes and relaunches.
/// Only an explicit foreground retry clears the decision.
public enum CredentialAccessDecisionStore {
    static let defaultsKeyPrefix = "cli_pulse_credential_denied."

    private static func defaultsKey(for scope: CredentialAccessScope) -> String {
        defaultsKeyPrefix + scope.key
    }

    public static func recordDenial(
        scope: CredentialAccessScope,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(true, forKey: defaultsKey(for: scope))
    }

    public static func isDenied(
        scope: CredentialAccessScope,
        defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.bool(forKey: defaultsKey(for: scope))
    }

    public static func clearDenial(
        scope: CredentialAccessScope,
        defaults: UserDefaults = .standard
    ) {
        defaults.removeObject(forKey: defaultsKey(for: scope))
    }

    public static func clearAllSafeStorageDenials(
        defaults: UserDefaults = .standard
    ) {
        let prefix = defaultsKeyPrefix + "safe-storage."
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
    }

    public static func statusIndicatesDenial(_ status: OSStatus) -> Bool {
        status == errSecUserCanceled || status == errSecAuthFailed
    }
}
