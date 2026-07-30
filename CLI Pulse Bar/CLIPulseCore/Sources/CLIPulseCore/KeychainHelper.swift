import Foundation
import Security

public enum KeychainHelper {
    private static let service = "com.clipulse.app"

    /// The app-group keychain access group shared by the main app, the
    /// LoginItem helper, and the .pkg daemon. Bare group string (no
    /// `$(AppIdentifierPrefix)`) — Apple's keychain APIs auto-prepend the
    /// team prefix at query time. Mirrors `HelperConfig.keychainAccessGroup`
    /// and the `keychain-access-groups` entry in the app/LoginItem/.pkg
    /// entitlements. Items written into this group are readable by every
    /// process that declares the group, with NO per-item consent prompt.
    public static let sharedAccessGroup = "group.yyh.CLI-Pulse"

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
    /// Gated on XCTest actually being loaded, so the shipped app cannot take
    /// this path even if something set the property: in production, auth tokens
    /// come from the Keychain, full stop.
    nonisolated(unsafe) public static var inMemoryStoreForTesting: [String: String]?

    private static let isRunningUnderXCTest = NSClassFromString("XCTestCase") != nil

    private static func testStoreKey(_ key: String, _ accessGroup: String?) -> String {
        "\(accessGroup ?? "-")|\(key)"
    }

    /// One-time migration: re-home a keychain item that was written WITHOUT
    /// an access group (so its ACL trusts only the writing app) into
    /// `sharedAccessGroup`, so the LoginItem helper can read it without the
    /// recurring "wants to use information stored by ... in your keychain"
    /// consent prompt. Safe to call on every launch — idempotent and
    /// prompt-free, because it runs in the MAIN APP reading its OWN item.
    ///
    /// We intentionally do NOT delete the legacy no-group copy afterward: a
    /// `SecItemDelete` that omits `kSecAttrAccessGroup` is not reliably
    /// scoped once the app declares `keychain-access-groups`, so deleting it
    /// could wipe the group value we just wrote. A lingering no-group
    /// duplicate is harmless — every reader now queries the group explicitly.
    public static func migrateToSharedGroup(key: String) {
        // Already present in the shared group (migrated earlier, or written
        // there by a newer build) ⇒ nothing to do. Guard also prevents
        // clobbering a fresher in-group value with a stale legacy copy.
        if load(key: key, accessGroup: sharedAccessGroup) != nil { return }
        // Read the legacy (no access group) item. The main app reading its
        // own item never triggers a consent prompt.
        guard let legacy = load(key: key), !legacy.isEmpty else { return }
        save(key: key, value: legacy, accessGroup: sharedAccessGroup)
    }

    public static func save(key: String, value: String, accessGroup: String? = nil) {
        guard let data = value.data(using: .utf8) else { return }
        if isRunningUnderXCTest, inMemoryStoreForTesting != nil {
            inMemoryStoreForTesting?[testStoreKey(key, accessGroup)] = value
            return
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
        let status = SecItemUpdate(query as CFDictionary, updateAttrs as CFDictionary)
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
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    public static func load(key: String, accessGroup: String? = nil) -> String? {
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
        if isRunningUnderXCTest, let store = inMemoryStoreForTesting {
            return store[testStoreKey(key, accessGroup)]
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func delete(key: String, accessGroup: String? = nil) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        if let group = accessGroup {
            query[kSecAttrAccessGroup as String] = group
        }
        if isRunningUnderXCTest, inMemoryStoreForTesting != nil {
            inMemoryStoreForTesting?[testStoreKey(key, accessGroup)] = nil
            return
        }
        SecItemDelete(query as CFDictionary)
    }
}
