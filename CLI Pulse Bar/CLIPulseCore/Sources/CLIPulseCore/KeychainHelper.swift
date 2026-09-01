import Foundation
import Security

#if os(macOS)
enum BackgroundKeychainAccess {
    static func apply(to query: inout [String: Any]) {
        query[kSecUseAuthenticationUI as String] =
            kSecUseAuthenticationUIFail
    }
}
#endif

protocol ProviderSecretStoring {
    @discardableResult
    func save(
        key: String,
        value: String,
        accessGroup: String?
    ) -> Bool
    func load(key: String, accessGroup: String?) -> String?
    @discardableResult
    func delete(key: String, accessGroup: String?) -> Bool
}

struct KeychainProviderSecretStore: ProviderSecretStoring {
    @discardableResult
    func save(
        key: String,
        value: String,
        accessGroup: String?
    ) -> Bool {
        KeychainHelper.save(
            key: key,
            value: value,
            accessGroup: accessGroup
        )
    }

    func load(key: String, accessGroup: String?) -> String? {
        KeychainHelper.load(key: key, accessGroup: accessGroup)
    }

    @discardableResult
    func delete(key: String, accessGroup: String?) -> Bool {
        KeychainHelper.delete(key: key, accessGroup: accessGroup)
    }
}

public enum KeychainHelper {
    public enum SharedGroupMigrationOutcome: Equatable, Sendable {
        case complete
        case retryNeeded
    }

    static var service: String {
        CLIPulseRuntimeEnvironment.current.keychainService
    }

    /// The app-group keychain access group shared by the main app, the
    /// LoginItem helper, and the .pkg daemon. Bare group string (no
    /// `$(AppIdentifierPrefix)`) — Apple's keychain APIs auto-prepend the
    /// team prefix at query time. Mirrors `HelperConfig.keychainAccessGroup`
    /// and the `keychain-access-groups` entry in the app/LoginItem/.pkg
    /// entitlements. Items written into this group are readable by every
    /// process that declares the group, with NO per-item consent prompt.
    public static var sharedAccessGroup: String {
        CLIPulseRuntimeEnvironment.current.keychainAccessGroup
    }

    // MARK: - Test seam

    /// In-memory stand-in for the login Keychain, honoured ONLY under XCTest.
    ///
    /// `load` searches the legacy file-based keychain — the query carries no
    /// `kSecUseDataProtectionKeychain` — so a test binary, whose signature does
    /// not match the ACL on items the shipped app wrote, makes macOS raise the
    /// "wants to use information stored by ... in your keychain" dialog this
    /// file already describes above. Headless there is nobody to click it, and
    /// `SecItemCopyMatching` blocks in `mach_msg` indefinitely.
    ///
    /// Not hypothetical. `applyAuthenticatedState` reads `storedToken` to build
    /// its notification userInfo, so every test that signs in inherited that
    /// stall: it wedged the 2200-test suite past a 9-minute timeout, and had
    /// surfaced earlier as one 27s test that a re-run at 0.037s made look like
    /// a one-off blip. CI cannot catch it — a fresh runner keychain answers
    /// `errSecItemNotFound` immediately — so it only ever bites on a developer
    /// machine, where it reads as "the test suite hangs" with no other clue.
    ///
    /// Active for the WHOLE test bundle, not opt-in per class, because the
    /// blocking read is not something a test asks for: `AppState.init` starts a
    /// MainActor task that calls `restoreSession()` (AppState.swift:830), so
    /// merely constructing an `AppState` — which dozens of tests do — arms it.
    /// When it blocks it holds the main actor, and the next test that needs the
    /// main actor deadlocks. That is why `CookieResolverTests` passed alone in
    /// 0.005s and hung in the full run: it was the victim, not the cause. An
    /// opt-in seam would have to be remembered by every future test that ever
    /// touches `AppState`, which is exactly the kind of thing nobody remembers.
    ///
    /// Gated on XCTest actually being loaded, so the shipped app cannot take
    /// this path: in production, auth tokens come from the Keychain, full stop.
    nonisolated(unsafe) public static var inMemoryStoreForTesting: [String: String] = [:]

    private static let isRunningUnderXCTest = NSClassFromString("XCTestCase") != nil

    private static func testStoreKey(_ key: String, _ accessGroup: String?) -> String {
        "\(accessGroup ?? "-")|\(key)"
    }

    /// One-time migration: re-home a keychain item that was written WITHOUT
    /// an access group (so its ACL trusts only the writing app) into
    /// `sharedAccessGroup`, so the LoginItem helper can read it without the
    /// recurring "wants to use information stored by ... in your keychain"
    /// consent prompt. Safe to call on every launch — idempotent and
    /// non-interactive. A stale ACL or locked item returns `retryNeeded`
    /// instead of displaying SecurityAgent UI or being marked complete.
    ///
    /// We intentionally do NOT delete the legacy no-group copy afterward: a
    /// `SecItemDelete` that omits `kSecAttrAccessGroup` is not reliably
    /// scoped once the app declares `keychain-access-groups`, so deleting it
    /// could wipe the group value we just wrote. A lingering no-group
    /// duplicate is harmless — every reader now queries the group explicitly.
    @discardableResult
    public static func migrateToSharedGroup(
        key: String
    ) -> SharedGroupMigrationOutcome {
        // Already present in the shared group (migrated earlier, or written
        // there by a newer build) ⇒ nothing to do. Guard also prevents
        // clobbering a fresher in-group value with a stale legacy copy.
        let shared = loadResult(
            key: key,
            accessGroup: sharedAccessGroup
        )
        if shared.status == errSecSuccess, shared.value != nil {
            return .complete
        }
        guard shared.status == errSecItemNotFound else {
            return .retryNeeded
        }
        // Read the legacy (no access group) item without UI. A locked or stale
        // ACL remains retryable instead of being mistaken for absence.
        let legacy = loadResult(key: key, accessGroup: nil)
        if legacy.status == errSecItemNotFound {
            return .complete
        }
        guard legacy.status == errSecSuccess,
              let value = legacy.value,
              !value.isEmpty
        else {
            return .retryNeeded
        }
        return save(
            key: key,
            value: value,
            accessGroup: sharedAccessGroup
        ) ? .complete : .retryNeeded
    }

    /// Builds the non-interactive query shared by every app-owned read.
    static func loadQuery(
        key: String,
        accessGroup: String? = nil
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let group = accessGroup {
            query[kSecAttrAccessGroup as String] = group
        }
        #if os(macOS)
        BackgroundKeychainAccess.apply(to: &query)
        #endif
        return query
    }

    @discardableResult
    public static func save(
        key: String,
        value: String,
        accessGroup: String? = nil
    ) -> Bool {
        guard let data = value.data(using: .utf8) else {
            return false
        }
        if isRunningUnderXCTest {
            inMemoryStoreForTesting[testStoreKey(key, accessGroup)] = value
            return true
        }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        if let group = accessGroup {
            query[kSecAttrAccessGroup as String] = group
        }
        // Atomic: try update first, fall back to add if item doesn't exist
        // NOTE: kSecAttrAccessible must NOT be in update attrs — Apple rejects it with errSecParam
        let updateAttrs: [String: Any] = [
            kSecValueData as String: data,
        ]
        var updateQuery = query
        #if os(macOS)
        BackgroundKeychainAccess.apply(to: &updateQuery)
        let status = LegacyKeychainUIGate.withInteractionDisabled {
            SecItemUpdate(updateQuery as CFDictionary, updateAttrs as CFDictionary)
        }
        #else
        let status = SecItemUpdate(updateQuery as CFDictionary, updateAttrs as CFDictionary)
        #endif
        if status == errSecSuccess {
            return true
        }
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            // v1.21 D3: WhenUnlockedThisDeviceOnly is tighter than the previous
            // AfterFirstUnlock — token is unreadable while device is locked AND
            // never syncs via iCloud Keychain (which AfterFirstUnlock could,
            // if kSecAttrSynchronizable were ever set). Main-app reads tokens
            // only while user is interacting (= device unlocked), so the
            // tighter access class is compatible. Existing items keep their
            // old accessibility until natural rotation rewrites them — no
            // explicit migration needed (Apple rejects accessibility changes
            // in SecItemUpdate with errSecParam, so the safe path is just
            // new writes = tighter, old items continue to work as-is).
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            #if os(macOS)
            let addStatus = LegacyKeychainUIGate.withInteractionDisabled {
                SecItemAdd(addQuery as CFDictionary, nil)
            }
            #else
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            #endif
            if addStatus == errSecSuccess {
                return true
            }
            if addStatus == errSecDuplicateItem {
                #if os(macOS)
                return LegacyKeychainUIGate.withInteractionDisabled {
                    SecItemUpdate(
                        updateQuery as CFDictionary,
                        updateAttrs as CFDictionary
                    ) == errSecSuccess
                }
                #else
                return SecItemUpdate(
                    updateQuery as CFDictionary,
                    updateAttrs as CFDictionary
                ) == errSecSuccess
                #endif
            }
        }
        return false
    }

    public static func load(key: String, accessGroup: String? = nil) -> String? {
        let result = loadResult(key: key, accessGroup: accessGroup)
        guard result.status == errSecSuccess else { return nil }
        return result.value
    }

    private static func loadResult(
        key: String,
        accessGroup: String?
    ) -> (status: OSStatus, value: String?) {
        if isRunningUnderXCTest {
            guard let value = inMemoryStoreForTesting[
                testStoreKey(key, accessGroup)
            ] else {
                return (errSecItemNotFound, nil)
            }
            return (errSecSuccess, value)
        }
        let query = loadQuery(key: key, accessGroup: accessGroup)
        var item: CFTypeRef?
        #if os(macOS)
        let status = LegacyKeychainUIGate.withInteractionDisabled {
            SecItemCopyMatching(query as CFDictionary, &item)
        }
        #else
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        #endif
        guard status == errSecSuccess, let data = item as? Data else {
            return (status, nil)
        }
        return (status, String(data: data, encoding: .utf8))
    }

    @discardableResult
    public static func delete(
        key: String,
        accessGroup: String? = nil
    ) -> Bool {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        if let group = accessGroup {
            query[kSecAttrAccessGroup as String] = group
        }
        if isRunningUnderXCTest {
            inMemoryStoreForTesting[testStoreKey(key, accessGroup)] = nil
            return true
        }
        #if os(macOS)
        BackgroundKeychainAccess.apply(to: &query)
        let status = LegacyKeychainUIGate.withInteractionDisabled {
            SecItemDelete(query as CFDictionary)
        }
        #else
        let status = SecItemDelete(query as CFDictionary)
        #endif
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
