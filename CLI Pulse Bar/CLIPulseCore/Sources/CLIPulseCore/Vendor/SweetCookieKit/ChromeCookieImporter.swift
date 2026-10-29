// Vendored from steipete/SweetCookieKit 0.4.1 (MIT, © Peter Steinberger)
// https://github.com/steipete/SweetCookieKit — see ./LICENSE for the
// full MIT notice. Source-vendored (not an SPM dependency) because
// SweetCookieKit's Package.swift requires swift-tools 6.2 while CI runs
// Swift 6.1; vendoring removes the manifest from the resolution graph.
// Whole file is `#if os(macOS)`-wrapped so it never compiles on
// iOS/watchOS (same isolation the `.when(platforms:[.macOS])` SPM
// condition provided); CLIPulseCore links sqlite3 on macOS for this.

#if os(macOS)

#if os(macOS)
import CommonCrypto
import Foundation
import LocalAuthentication
import Security
import SQLite3

/// Reads cookies from a local Chromium cookie DB (macOS).
///
/// Notes:
/// - Chromium stores cookie values in an SQLite DB, and most values are encrypted (`encrypted_value` starts
///   with `v10` on macOS). Decryption uses the "Chrome Safe Storage" password from the macOS Keychain and
///   AES-CBC + PBKDF2. This is inherently brittle across Chromium changes; keep it best-effort.
enum ChromeCookieImporter {
    private static let chromeSafeStorageKeyLock = NSLock()
    private nonisolated(unsafe) static var cachedChromeSafeStorageKeys: [Browser: Data] = [:]

    enum ImportError: LocalizedError {
        case cookieDBNotFound(path: String)
        case keychainDenied
        /// CLI Pulse (1.60, N2): reading the Safe Storage key needs the user to
        /// approve a Keychain dialog, and this read is not one a person started,
        /// so no dialog was shown. Not a denial: a manual refresh may ask.
        case keychainApprovalNeeded
        case sqliteFailed(message: String)

        var errorDescription: String? {
            switch self {
            case let .cookieDBNotFound(path): "Chromium Cookies DB not found at \(path)."
            case .keychainDenied: "macOS Keychain denied access to Chrome Safe Storage."
            case .keychainApprovalNeeded:
                "Reading Chrome Safe Storage needs Keychain approval; it is asked for on a manual refresh."
            case let .sqliteFailed(message): "Failed to read Chromium cookies: \(message)"
            }
        }
    }

    struct CookieRecord {
        let hostKey: String
        let name: String
        let path: String
        let expiresUTC: Int64
        let isSecure: Bool
        let isHTTPOnly: Bool
        let value: String
    }

    static func availableStores(for browser: Browser, homeDirectories: [URL]) -> [BrowserCookieStore] {
        guard browser.engine == .chromium else { return [] }
        let labelPrefix = browser.displayName
        let roots = ChromiumProfileLocator
            .roots(for: [browser], homeDirectories: homeDirectories)
            .map(\.url)

        var candidates: [ChromeProfileCandidate] = []
        for root in roots {
            candidates.append(contentsOf: Self.chromeProfileCookieDBs(
                root: root,
                labelPrefix: labelPrefix,
                browser: browser))
        }
        return candidates
            .filter { FileManager.default.fileExists(atPath: $0.cookiesDB.path) }
            .map { candidate in
                BrowserCookieStore(
                    browser: candidate.browser,
                    profile: candidate.profile,
                    kind: candidate.kind,
                    label: candidate.label,
                    databaseURL: candidate.cookiesDB)
            }
    }

    /// CLI Pulse (1.60, N2) changes the order upstream used. Upstream derived the
    /// Safe Storage key first and read the database second, so every Chromium
    /// browser with a cookie store cost one Keychain lookup — a dialog, for an
    /// app the item does not trust — even when the browser held no cookie for
    /// the provider. Here the copied database is read first, and the key is
    /// asked for only when a host-matching row is encrypted. The lookup may
    /// show a dialog only when `allowKeychainInteraction` is true, which
    /// `BrowserCookieAutoImporter` sets for a refresh a person started.
    static func loadCookies(
        from store: BrowserCookieStore,
        matchingDomains domains: [String],
        domainMatch: BrowserCookieDomainMatch,
        allowKeychainInteraction: Bool = false) throws -> [CookieRecord]
    {
        guard let sourceDB = store.databaseURL else {
            throw ImportError.cookieDBNotFound(path: "Missing cookie DB for \(store.label)")
        }
        let rows = try Self.readRowsFromLockedChromeDB(
            sourceDB: sourceDB,
            matchingDomains: domains,
            domainMatch: domainMatch)
        guard rows.contains(where: \.needsSafeStorageKey) else {
            return rows.compactMap { $0.record(key: nil) }
        }
        let chromeKey = try Self.chromeSafeStorageKey(
            for: store.browser,
            allowInteraction: allowKeychainInteraction,
            passwordLookup: Self.passwordLookupOverrideForTesting ?? { service, account, allowInteraction in
                Self.findGenericPassword(service: service, account: account, allowInteraction: allowInteraction)
            })
        return rows.compactMap { $0.record(key: chromeKey) }
    }

    /// A host-matching row as stored: the plain value, or the encrypted one
    /// still to be decrypted.
    struct CookieRow {
        let hostKey: String
        let name: String
        let path: String
        let expiresUTC: Int64
        let isSecure: Bool
        let isHTTPOnly: Bool
        let plainValue: String?
        let encryptedValue: Data?

        /// Only a row with no plain value and a `v10` encrypted one needs the
        /// key: `v10` is the only format `decryptChromiumValue` reads, so any
        /// other would cost a dialog and still yield nothing.
        var needsSafeStorageKey: Bool {
            guard (self.plainValue ?? "").isEmpty, let enc = self.encryptedValue else { return false }
            return enc.count > 3 && enc.starts(with: Data("v10".utf8))
        }

        func record(key: Data?) -> CookieRecord? {
            let value: String
            if let plain = self.plainValue, !plain.isEmpty {
                value = plain
            } else if let enc = self.encryptedValue, !enc.isEmpty, let key,
                      let decrypted = ChromeCookieImporter.decryptChromiumValue(enc, key: key)
            {
                value = decrypted
            } else {
                return nil
            }
            return CookieRecord(
                hostKey: self.hostKey,
                name: self.name,
                path: self.path,
                expiresUTC: self.expiresUTC,
                isSecure: self.isSecure,
                isHTTPOnly: self.isHTTPOnly,
                value: value)
        }
    }

    // MARK: - DB copy helper

    private static func readRowsFromLockedChromeDB(
        sourceDB: URL,
        matchingDomains: [String],
        domainMatch: BrowserCookieDomainMatch) throws -> [CookieRow]
    {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sweet-cookie-kit-chrome-cookies-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let copiedDB = tempDir.appendingPathComponent("Cookies")
        try FileManager.default.copyItem(at: sourceDB, to: copiedDB)

        for suffix in ["-wal", "-shm"] {
            let src = URL(fileURLWithPath: sourceDB.path + suffix)
            if FileManager.default.fileExists(atPath: src.path) {
                let dst = URL(fileURLWithPath: copiedDB.path + suffix)
                try? FileManager.default.copyItem(at: src, to: dst)
            }
        }

        defer { try? FileManager.default.removeItem(at: tempDir) }

        return try Self.readRows(
            fromDB: copiedDB.path,
            matchingDomains: matchingDomains,
            domainMatch: domainMatch)
    }

    // MARK: - SQLite read

    private static func readRows(
        fromDB path: String,
        matchingDomains: [String],
        domainMatch: BrowserCookieDomainMatch) throws -> [CookieRow]
    {
        var db: OpaquePointer?
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
            throw ImportError.sqliteFailed(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_close(db) }

        let conditions = BrowserCookieDomainMatcher.sqlCondition(
            column: "host_key",
            patterns: matchingDomains,
            match: domainMatch)
        let sql = """
        SELECT host_key, name, path, expires_utc, is_secure, is_httponly, value, encrypted_value
        FROM cookies
        WHERE \(conditions)
        """

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw ImportError.sqliteFailed(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var out: [CookieRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(CookieRow(
                hostKey: String(cString: sqlite3_column_text(stmt, 0)),
                name: String(cString: sqlite3_column_text(stmt, 1)),
                path: String(cString: sqlite3_column_text(stmt, 2)),
                expiresUTC: sqlite3_column_int64(stmt, 3),
                isSecure: sqlite3_column_int(stmt, 4) != 0,
                isHTTPOnly: sqlite3_column_int(stmt, 5) != 0,
                plainValue: Self.readTextColumn(stmt, index: 6),
                encryptedValue: Self.readBlobColumn(stmt, index: 7)))
        }
        return out
    }

    private static func readTextColumn(_ stmt: OpaquePointer?, index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        guard let c = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: c)
    }

    private static func readBlobColumn(_ stmt: OpaquePointer?, index: Int32) -> Data? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        guard let bytes = sqlite3_column_blob(stmt, index) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, index))
        return Data(bytes: bytes, count: count)
    }

    // MARK: - Keychain + crypto

    typealias SafeStoragePasswordLookup =
        @Sendable (_ service: String, _ account: String, _ allowInteraction: Bool) -> (
            status: OSStatus,
            password: String?)

    /// Replaces the Keychain read in tests, for the task it is bound in.
    @TaskLocal static var passwordLookupOverrideForTesting: SafeStoragePasswordLookup?

    /// CLI Pulse (1.60, N2): the no-UI read always goes first, and a dialog is
    /// allowed only when `allowInteraction` is true. Upstream read every label
    /// with interaction allowed, whoever started the refresh.
    ///
    /// - An item this app may already read comes back from the no-UI read.
    /// - None exists under any label: `.keychainDenied`, as before.
    /// - One exists but needs approval, and no dialog is allowed:
    ///   `.keychainApprovalNeeded`, which is not remembered as a denial.
    /// - Dialog allowed: asked for each existing label in order, stopping at
    ///   the first that answers or the first the person cancels.
    static func chromeSafeStorageKey(
        for browser: Browser,
        allowInteraction: Bool,
        passwordLookup: @escaping SafeStoragePasswordLookup) throws -> Data
    {
        if BrowserCookieKeychainAccessGate.isDisabled {
            throw ImportError.keychainDenied
        }

        self.chromeSafeStorageKeyLock.lock()
        if let cached = self.cachedChromeSafeStorageKeys[browser] {
            self.chromeSafeStorageKeyLock.unlock()
            return cached
        }
        self.chromeSafeStorageKeyLock.unlock()

        let labels = Self.safeStorageLabels(for: browser)

        var password: String?
        var existing: [(service: String, account: String)] = []
        for label in labels {
            let result = passwordLookup(label.service, label.account, false)
            if let p = result.password {
                password = p
                break
            }
            if result.status != errSecItemNotFound { existing.append(label) }
        }

        if password == nil {
            guard !existing.isEmpty else { throw ImportError.keychainDenied }
            guard allowInteraction else { throw ImportError.keychainApprovalNeeded }
            var refused = false
            for label in existing {
                BrowserCookieKeychainPromptHandler.handler?(BrowserCookieKeychainPromptContext(
                    service: label.service,
                    account: label.account,
                    label: label.service))
                let result = passwordLookup(label.service, label.account, true)
                if let p = result.password {
                    password = p
                    break
                }
                if result.status == errSecUserCanceled || result.status == errSecAuthFailed {
                    refused = true
                    break
                }
            }
            // No answer and no refusal (a locked Keychain or screen comes back
            // as errSecInteractionNotAllowed even here): not a denial either,
            // so the run does not remember it as one.
            if password == nil, !refused { throw ImportError.keychainApprovalNeeded }
        }
        guard let password else { throw ImportError.keychainDenied }

        let salt = Data("saltysalt".utf8)
        var key = Data(count: kCCKeySizeAES128)
        let keyLength = key.count
        let result = key.withUnsafeMutableBytes { keyBytes in
            password.utf8CString.withUnsafeBytes { passBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passBytes.bindMemory(to: Int8.self).baseAddress,
                        passBytes.count - 1,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1003,
                        keyBytes.bindMemory(to: UInt8.self).baseAddress,
                        keyLength)
                }
            }
        }
        guard result == kCCSuccess else {
            throw ImportError.keychainDenied
        }

        self.chromeSafeStorageKeyLock.lock()
        self.cachedChromeSafeStorageKeys[browser] = key
        self.chromeSafeStorageKeyLock.unlock()
        return key
    }

    static func resetSafeStorageKeyCacheForTesting() {
        self.chromeSafeStorageKeyLock.lock()
        self.cachedChromeSafeStorageKeys = [:]
        self.chromeSafeStorageKeyLock.unlock()
    }

    /// Exposed for tests.
    static func decryptChromiumValue(_ encryptedValue: Data, key: Data) -> String? {
        guard encryptedValue.count > 3 else { return nil }
        let prefix = encryptedValue.prefix(3)
        let prefixString = String(data: prefix, encoding: .utf8)
        let payload = encryptedValue.dropFirst(3)

        if prefixString != "v10" {
            return nil
        }

        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var out = Data(count: payload.count + kCCBlockSizeAES128)
        var outLength: size_t = 0
        let outCapacity = out.count

        let status = out.withUnsafeMutableBytes { outBytes in
            payload.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            inBytes.baseAddress,
                            payload.count,
                            outBytes.baseAddress,
                            outCapacity,
                            &outLength)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        out.count = outLength

        let candidate = out.count > 32 ? out.dropFirst(32) : out[...]
        if let decoded = String(data: Data(candidate), encoding: .utf8) {
            return Self.cleanValue(decoded)
        }
        if let decoded = String(data: out, encoding: .utf8) {
            return Self.cleanValue(decoded)
        }
        return nil
    }

    private static func cleanValue(_ value: String) -> String {
        var i = value.startIndex
        while i < value.endIndex, value[i].unicodeScalars.allSatisfy({ $0.value < 0x20 }) {
            i = value.index(after: i)
        }
        return String(value[i...])
    }

    private static func safeStorageLabels(for browser: Browser) -> [(service: String, account: String)] {
        let labels = browser.safeStorageLabels
        if !labels.isEmpty { return labels }
        return BrowserCatalog.safeStorageLabels
    }

    private static func findGenericPassword(
        service: String,
        account: String,
        allowInteraction: Bool) -> (status: OSStatus, password: String?)
    {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: true,
        ]
        if !allowInteraction {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext] = context
            // CLI Pulse (1.60, N2): `interactionNotAllowed` alone can still
            // show the legacy Allow/Deny dialog for a file-based Keychain item,
            // which is what a browser's Safe Storage item is. The UI-fail flag
            // makes that read fail with errSecInteractionNotAllowed instead.
            // Both flags together is what upstream CodexBar's no-UI query
            // (`KeychainNoUIQuery`) sets; `ZedCollector` sets the UI-fail one.
            query[kSecUseAuthenticationUI] = kSecUseAuthenticationUIFail
        }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return (status, nil) }
        guard let data = result as? Data else { return (status, nil) }
        let password = String(data: data, encoding: .utf8)
        return (status, password)
    }

    // MARK: - Profile discovery

    private struct ChromeProfileCandidate {
        let browser: Browser
        let profile: BrowserProfile
        let kind: BrowserCookieStoreKind
        let label: String
        let cookiesDB: URL
    }

    private static func chromeProfileCookieDBs(
        root: URL,
        labelPrefix: String,
        browser: Browser) -> [ChromeProfileCandidate]
    {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
        else { return [] }

        let profileDirs = entries.filter { url in
            guard let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory), isDir else {
                return false
            }
            let name = url.lastPathComponent
            return name == "Default" || name.hasPrefix("Profile ") || name.hasPrefix("user-")
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        return profileDirs.flatMap { dir in
            let profileName = dir.lastPathComponent
            let profile = BrowserProfile(id: dir.path, name: profileName)
            let labelBase = "\(labelPrefix) \(profileName)"
            let cookiesDB = dir.appendingPathComponent("Cookies")
            let networkCookiesDB = dir.appendingPathComponent("Network").appendingPathComponent("Cookies")
            return [
                ChromeProfileCandidate(
                    browser: browser,
                    profile: profile,
                    kind: .network,
                    label: "\(labelBase) (Network)",
                    cookiesDB: networkCookiesDB),
                ChromeProfileCandidate(
                    browser: browser,
                    profile: profile,
                    kind: .primary,
                    label: labelBase,
                    cookiesDB: cookiesDB),
            ]
        }
    }
}
#endif

#endif
