#if os(macOS)
import AuthenticationServices
import CryptoKit
import Foundation

// MARK: - Errors

public enum GeminiOAuthError: LocalizedError {
    case noCallback
    case sessionStartFailed
    case noAuthCode
    case stateMismatch
    case tokenExchangeFailed(Int)
    case tokenRefreshFailed(Int)
    case invalidTokenResponse
    case noRefreshToken
    case clientNotConfigured
    case alreadyInProgress
    case randomGenerationFailed

    public var errorDescription: String? {
        switch self {
        case .noCallback:            return "OAuth callback not received"
        case .sessionStartFailed:    return "Failed to start authentication session"
        case .noAuthCode:            return "No authorization code in callback"
        case .stateMismatch:         return "OAuth state parameter mismatch"
        case .tokenExchangeFailed(let s): return "Token exchange failed (HTTP \(s))"
        case .tokenRefreshFailed(let s):  return "Token refresh failed (HTTP \(s))"
        case .invalidTokenResponse:  return "Invalid token response from Google"
        case .noRefreshToken:        return "No refresh token available"
        case .clientNotConfigured:   return "OAuth client ID not configured — see docs/GEMINI_OAUTH_SETUP.md"
        case .alreadyInProgress:     return "OAuth flow already in progress"
        case .randomGenerationFailed: return "Secure random generation failed"
        }
    }
}

// MARK: - Stored token container

public struct GeminiStoredTokens: Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiry: Date?

    public var isExpired: Bool {
        guard let exp = expiry else { return true }
        return exp < Date()
    }
}

/// OAuth result held only in the provider editor until the user presses Save.
/// Keeping this value in memory makes Cancel a true rollback boundary.
public struct GeminiAuthorizationTokens: Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expiry: Date

    public init(
        accessToken: String,
        refreshToken: String,
        expiry: Date
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiry = expiry
    }
}

public enum GeminiCredentialMutation: Equatable, Sendable {
    case unchanged
    case connect
    case disconnect
}

public enum GeminiConnectionTestDisposition:
    Equatable,
    Sendable
{
    case usePersistedCredentials
    case authorizationReadyToSave
    case stagedForRemoval
}

/// Pure editor state. Connect and Disconnect alter only this draft; `commit`
/// is invoked by the Save action and is the sole Keychain mutation boundary.
public struct GeminiCredentialDraft: Sendable {
    public private(set) var isConnected: Bool
    public private(set) var pendingMutation:
        GeminiCredentialMutation = .unchanged

    private let originallyConnected: Bool
    private var pendingAuthorization: GeminiAuthorizationTokens?

    public init(isConnected: Bool) {
        self.isConnected = isConnected
        self.originallyConnected = isConnected
    }

    public mutating func stageAuthorization(
        _ authorization: GeminiAuthorizationTokens
    ) {
        pendingAuthorization = authorization
        pendingMutation = .connect
        isConnected = true
    }

    public mutating func stageDisconnect() {
        pendingAuthorization = nil
        pendingMutation =
            originallyConnected ? .disconnect : .unchanged
        isConnected = false
    }

    /// Test Connection must respect the same Save/Cancel transaction as the
    /// editor. A staged authorization has already exchanged a valid OAuth
    /// code but is not yet in Keychain; a staged disconnect must never probe
    /// the old persisted token and report a misleading success.
    public var connectionTestDisposition:
        GeminiConnectionTestDisposition
    {
        switch pendingMutation {
        case .unchanged:
            return .usePersistedCredentials
        case .connect:
            return .authorizationReadyToSave
        case .disconnect:
            return .stagedForRemoval
        }
    }
}

// MARK: - Manager

/// Manages CLI Pulse's own Google OAuth2 flow for Gemini quota access.
///
/// Flow: ASWebAuthenticationSession + PKCE (public client, no client_secret).
/// Tokens: Keychain (primary) + `~/.config/clipulse/gemini_tokens.json` (Python helper,
///   access_token only — refresh_token stays in Keychain).
public final class GeminiOAuthManager: NSObject, @unchecked Sendable {

    // ── Configuration ────────────────────────────────────────────────
    // Replace after creating an iOS-type OAuth client in Google Cloud Console.
    // See docs/GEMINI_OAUTH_SETUP.md for instructions.
    public static let clientID = "REPLACE_WITH_YOUR_CLIENT_ID.apps.googleusercontent.com"

    public static var callbackScheme: String {
        clientID.split(separator: ".").reversed().joined(separator: ".")
    }
    public static var redirectURI: String {
        "\(callbackScheme):/oauthredirect"
    }

    private static let scope = "https://www.googleapis.com/auth/cloud-platform"
    private static let authEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    private static let tokenEndpoint = "https://oauth2.googleapis.com/token"

    // ── Keychain keys ────────────────────────────────────────────────
    private static let accessGroup = "group.yyh.CLI-Pulse"
    static let keyAccessToken  = "gemini.oauth.access_token"
    static let keyRefreshToken = "gemini.oauth.refresh_token"
    static let keyExpiry       = "gemini.oauth.expiry"
    private static let keyLegacyOwner = "gemini.oauth.legacy_owner"

    static func accountKey(
        _ base: String,
        accountID: UUID
    ) -> String {
        "\(base).account.\(accountID.uuidString)"
    }

    // ── Shared file for Python helper ────────────────────────────────
    private static var sharedDir: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".config/clipulse")
    }
    static var sharedTokenFilePath: String {
        (sharedDir as NSString).appendingPathComponent("gemini_tokens.json")
    }

    // ── Singleton ────────────────────────────────────────────────────
    public static let shared = GeminiOAuthManager()

    // authSession is only accessed on MainActor (UI-driven OAuth flow).
    // @unchecked Sendable on class is safe because all mutable state is MainActor-isolated.
    @MainActor private var authSession: ASWebAuthenticationSession?
    private override init() { super.init() }

    // MARK: - Public API

    /// Whether CLI Pulse has its own Gemini OAuth tokens in Keychain.
    public var isConnected: Bool { loadTokens() != nil }

    public func isConnected(
        accountID: UUID,
        allowLegacyFallback: Bool = true
    ) -> Bool {
        loadTokens(
            accountID: accountID,
            allowLegacyFallback: allowLegacyFallback
        ) != nil
    }

    /// Read-only connection check for transactional editors. Unlike
    /// `loadTokens`, this does not claim a legacy owner or copy credentials
    /// into an account-scoped Keychain slot merely because a window opened.
    public func isConnectedWithoutMigration(
        accountID: UUID,
        allowLegacyFallback: Bool = true
    ) -> Bool {
        if loadTokens(
            keys: Self.tokenKeys(accountID: accountID)
        ) != nil {
            return true
        }
        guard
            allowLegacyFallback,
            loadTokens(
                keys: Self.tokenKeys(accountID: nil)
            ) != nil
        else {
            return false
        }
        return ProviderSharedCredentialOwner.canUse(
            kind: .gemini,
            accountID: accountID
        )
    }

    /// Start the full OAuth2 authorization flow (opens browser sheet).
    /// Compatibility API for callers that explicitly want immediate commit.
    @MainActor
    public func authorize(
        accountID: UUID? = nil
    ) async throws -> (accessToken: String, refreshToken: String) {
        let authorization = try await authorizeForEditing(
            accountID: accountID
        )
        commitAuthorization(
            authorization,
            accountID: accountID
        )
        return (
            authorization.accessToken,
            authorization.refreshToken
        )
    }

    /// Run OAuth without touching Keychain. ProviderConfigEditor keeps the
    /// returned secret-bearing value in memory and commits it only on Save.
    @MainActor
    public func authorizeForEditing(
        accountID: UUID? = nil
    ) async throws -> GeminiAuthorizationTokens {
        guard Self.clientID != "REPLACE_WITH_YOUR_CLIENT_ID.apps.googleusercontent.com" else {
            throw GeminiOAuthError.clientNotConfigured
        }
        // Prevent concurrent auth sessions
        guard authSession == nil else {
            throw GeminiOAuthError.alreadyInProgress
        }

        let verifier  = try Self.generateCodeVerifier()
        let challenge = Self.generateCodeChallenge(from: verifier)
        let state     = UUID().uuidString

        guard var comps = URLComponents(string: Self.authEndpoint) else {
            throw GeminiOAuthError.sessionStartFailed
        }
        comps.queryItems = [
            .init(name: "client_id",             value: Self.clientID),
            .init(name: "redirect_uri",          value: Self.redirectURI),
            .init(name: "response_type",         value: "code"),
            .init(name: "scope",                 value: Self.scope),
            .init(name: "state",                 value: state),
            .init(name: "code_challenge",        value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "access_type",           value: "offline"),
            .init(name: "prompt",                value: "consent"),
        ]

        guard let authURL = comps.url else {
            throw GeminiOAuthError.sessionStartFailed
        }

        defer { self.authSession = nil }

        let callbackURL: URL = try await withCheckedThrowingContinuation { cont in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: Self.callbackScheme
            ) { url, error in
                if let error { cont.resume(throwing: error) }
                else if let url { cont.resume(returning: url) }
                else { cont.resume(throwing: GeminiOAuthError.noCallback) }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.authSession = session
            if !session.start() {
                self.authSession = nil
                cont.resume(throwing: GeminiOAuthError.sessionStartFailed)
            }
        }

        // Parse callback
        guard let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems,
              let code = items.first(where: { $0.name == "code" })?.value else {
            throw GeminiOAuthError.noAuthCode
        }
        guard items.first(where: { $0.name == "state" })?.value == state else {
            throw GeminiOAuthError.stateMismatch
        }

        // Exchange code → tokens
        let tokens = try await exchangeCode(code, codeVerifier: verifier)

        // Require a refresh token on initial connect
        let keys = Self.tokenKeys(accountID: accountID)
        let rt = tokens.refresh.isEmpty
            ? KeychainHelper.load(
                key: keys.refresh,
                accessGroup: Self.accessGroup
            ) ?? ""
            : tokens.refresh
        return GeminiAuthorizationTokens(
            accessToken: tokens.access,
            refreshToken: rt,
            expiry: Date().addingTimeInterval(tokens.expiresIn)
        )
    }

    public func commitAuthorization(
        _ authorization: GeminiAuthorizationTokens,
        accountID: UUID? = nil
    ) {
        storeTokens(
            access: authorization.accessToken,
            refresh: authorization.refreshToken,
            expiresIn: max(
                0,
                authorization.expiry.timeIntervalSinceNow
            ),
            accountID: accountID
        )
    }

    /// Refresh the stored access token using the refresh token.
    public func refreshAccessToken(
        accountID: UUID? = nil
    ) async throws -> String {
        let keys = Self.tokenKeys(accountID: accountID)
        guard let rt = KeychainHelper.load(
            key: keys.refresh,
            accessGroup: Self.accessGroup
        ),
              !rt.isEmpty else {
            throw GeminiOAuthError.noRefreshToken
        }

        let body = Self.formEncode([
            "client_id":     Self.clientID,
            "grant_type":    "refresh_token",
            "refresh_token": rt,
        ])

        var req = URLRequest(url: URL(string: Self.tokenEndpoint)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        req.httpBody = body.data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            // Clear tokens on permanent auth errors so isConnected reflects reality
            if (400...401).contains(status) {
                clearTokens(accountID: accountID)
            }
            throw GeminiOAuthError.tokenRefreshFailed(status)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let at = json["access_token"] as? String else {
            throw GeminiOAuthError.invalidTokenResponse
        }

        let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        let newRT = json["refresh_token"] as? String ?? rt

        storeTokens(
            access: at,
            refresh: newRT,
            expiresIn: expiresIn,
            accountID: accountID
        )
        return at
    }

    /// Load current tokens from Keychain. Returns nil if not present.
    public func loadTokens(
        accountID: UUID? = nil,
        allowLegacyFallback: Bool = true
    ) -> GeminiStoredTokens? {
        let keys = Self.tokenKeys(accountID: accountID)
        if let stored = loadTokens(keys: keys) {
            return stored
        }

        // One-time compatibility migration: the old release had a single
        // provider-global Gemini slot. Only the designated legacy owner may
        // copy it into an account slot; sibling accounts must stay empty.
        guard
            let accountID,
            allowLegacyFallback,
            let legacy = loadTokens(keys: Self.tokenKeys(accountID: nil)),
            ProviderSharedCredentialOwner.claim(
                kind: .gemini,
                accountID: accountID
            )
        else {
            return nil
        }
        copyTokens(legacy, to: keys)
        KeychainHelper.save(
            key: Self.accountKey(
                Self.keyLegacyOwner,
                accountID: accountID
            ),
            value: "1",
            accessGroup: Self.accessGroup
        )
        return legacy
    }

    private func loadTokens(keys: TokenKeys) -> GeminiStoredTokens? {
        guard let at = KeychainHelper.load(
            key: keys.access,
            accessGroup: Self.accessGroup
        ),
              !at.isEmpty else { return nil }
        let rt = KeychainHelper.load(
            key: keys.refresh,
            accessGroup: Self.accessGroup
        )
        var expiry: Date?
        if let s = KeychainHelper.load(
            key: keys.expiry,
            accessGroup: Self.accessGroup
        ),
           let ts = Double(s) {
            expiry = Date(timeIntervalSince1970: ts)
        }
        return GeminiStoredTokens(accessToken: at, refreshToken: rt, expiry: expiry)
    }

    /// Remove all stored tokens (Keychain + shared file).
    static func allowsTokenCleanup(
        in runtimeEnvironment: CLIPulseRuntimeEnvironment
    ) -> Bool {
        runtimeEnvironment.capabilities.allowsLiveCollection
    }

    public func clearTokens(
        accountID: UUID? = nil,
        runtimeEnvironment: CLIPulseRuntimeEnvironment = .current
    ) {
        guard Self.allowsTokenCleanup(in: runtimeEnvironment) else {
            return
        }
        let keys = Self.tokenKeys(accountID: accountID)
        deleteTokens(keys: keys)

        guard let accountID else {
            try? FileManager.default.removeItem(
                atPath: Self.sharedTokenFilePath
            )
            return
        }

        let legacyOwnerKey = Self.accountKey(
            Self.keyLegacyOwner,
            accountID: accountID
        )
        let inheritedLegacy =
            KeychainHelper.load(
                key: legacyOwnerKey,
                accessGroup: Self.accessGroup
            ) == "1"
        KeychainHelper.delete(
            key: legacyOwnerKey,
            accessGroup: Self.accessGroup
        )

        if ProviderSharedCredentialOwner.isOwner(
            kind: .gemini,
            accountID: accountID
        ) {
            if inheritedLegacy {
                // Only an account that actually inherited the pre-account
                // slot may delete it. A newly connected account must never
                // erase unrelated legacy/helper credentials merely because
                // it happens to be the current compatibility owner.
                deleteTokens(keys: Self.tokenKeys(accountID: nil))
                try? FileManager.default.removeItem(
                    atPath: Self.sharedTokenFilePath
                )
            }
            ProviderSharedCredentialOwner.release(
                kind: .gemini,
                accountID: accountID
            )
        }
    }

    // MARK: - Private helpers

    private struct TokenBundle {
        let access: String
        let refresh: String
        let expiresIn: TimeInterval
    }

    private struct TokenKeys {
        let access: String
        let refresh: String
        let expiry: String
    }

    private static func tokenKeys(accountID: UUID?) -> TokenKeys {
        guard let accountID else {
            return TokenKeys(
                access: keyAccessToken,
                refresh: keyRefreshToken,
                expiry: keyExpiry
            )
        }
        return TokenKeys(
            access: accountKey(keyAccessToken, accountID: accountID),
            refresh: accountKey(keyRefreshToken, accountID: accountID),
            expiry: accountKey(keyExpiry, accountID: accountID)
        )
    }

    private func exchangeCode(_ code: String, codeVerifier: String) async throws -> TokenBundle {
        let body = Self.formEncode([
            "client_id":     Self.clientID,
            "code":          code,
            "code_verifier": codeVerifier,
            "grant_type":    "authorization_code",
            "redirect_uri":  Self.redirectURI,
        ])

        var req = URLRequest(url: URL(string: Self.tokenEndpoint)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        req.httpBody = body.data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            throw GeminiOAuthError.tokenExchangeFailed(status)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let at = json["access_token"] as? String else {
            throw GeminiOAuthError.invalidTokenResponse
        }

        return TokenBundle(
            access:    at,
            refresh:   json["refresh_token"] as? String ?? "",
            expiresIn: (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        )
    }

    private func storeTokens(
        access: String,
        refresh: String,
        expiresIn: TimeInterval,
        accountID: UUID?
    ) {
        let group = Self.accessGroup
        let keys = Self.tokenKeys(accountID: accountID)
        KeychainHelper.save(
            key: keys.access,
            value: access,
            accessGroup: group
        )
        if !refresh.isEmpty {
            KeychainHelper.save(
                key: keys.refresh,
                value: refresh,
                accessGroup: group
            )
        }
        let exp = String(Date().addingTimeInterval(expiresIn).timeIntervalSince1970)
        KeychainHelper.save(
            key: keys.expiry,
            value: exp,
            accessGroup: group
        )

        if accountID == nil {
            persistSharedFile(
                access: access,
                expiresIn: expiresIn,
                path: Self.sharedTokenFilePath
            )
        }
    }

    /// Write access_token + client_id to a JSON file the Python helper can read.
    /// Refresh token is NOT written here — it stays in Keychain only.
    private func persistSharedFile(
        access: String,
        expiresIn: TimeInterval,
        path: String
    ) {
        try? FileManager.default.createDirectory(atPath: Self.sharedDir,
                                                  withIntermediateDirectories: true)
        let expMs = Int64((Date().timeIntervalSince1970 + expiresIn) * 1000)
        let dict: [String: Any] = [
            "access_token":  access,
            "expiry_date":   expMs,
            "client_id":     Self.clientID,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted) else { return }
        let url = URL(fileURLWithPath: path)
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func copyTokens(
        _ tokens: GeminiStoredTokens,
        to keys: TokenKeys
    ) {
        let group = Self.accessGroup
        KeychainHelper.save(
            key: keys.access,
            value: tokens.accessToken,
            accessGroup: group
        )
        if let refresh = tokens.refreshToken, !refresh.isEmpty {
            KeychainHelper.save(
                key: keys.refresh,
                value: refresh,
                accessGroup: group
            )
        }
        if let expiry = tokens.expiry {
            KeychainHelper.save(
                key: keys.expiry,
                value: String(expiry.timeIntervalSince1970),
                accessGroup: group
            )
        }
    }

    private func deleteTokens(keys: TokenKeys) {
        KeychainHelper.delete(
            key: keys.access,
            accessGroup: Self.accessGroup
        )
        KeychainHelper.delete(
            key: keys.refresh,
            accessGroup: Self.accessGroup
        )
        KeychainHelper.delete(
            key: keys.expiry,
            accessGroup: Self.accessGroup
        )
    }

    // MARK: - PKCE

    // `internal` (not private) so the PKCE generation is unit-testable against the
    // RFC 7636 vector — these are pure/deterministic apart from the RNG in the
    // verifier, and a regression here silently breaks the Gemini OAuth handshake.
    static func generateCodeVerifier() throws -> String {
        var buf = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, buf.count, &buf)
        guard status == errSecSuccess else {
            throw GeminiOAuthError.randomGenerationFailed
        }
        return Data(buf).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func generateCodeChallenge(from verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - URL encoding

    private static func formEncode(_ params: [String: String]) -> String {
        params.map { k, v in
            let ek = k.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? k
            let ev = v.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? v
            return "\(ek)=\(ev)"
        }.joined(separator: "&")
    }
}

public extension GeminiCredentialDraft {
    func commit(
        using manager: GeminiOAuthManager = .shared,
        accountID: UUID
    ) {
        switch pendingMutation {
        case .unchanged:
            return
        case .connect:
            guard let pendingAuthorization else { return }
            manager.commitAuthorization(
                pendingAuthorization,
                accountID: accountID
            )
        case .disconnect:
            manager.clearTokens(accountID: accountID)
        }
    }
}

// MARK: - Presentation context

extension GeminiOAuthManager: ASWebAuthenticationPresentationContextProviding {
    @MainActor
    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.windows.first(where: \.isKeyWindow)
            ?? NSApplication.shared.windows.first
            ?? ASPresentationAnchor()
    }
}
#endif
