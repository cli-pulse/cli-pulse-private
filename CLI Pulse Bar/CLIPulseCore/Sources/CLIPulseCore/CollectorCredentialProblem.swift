import Foundation

/// Why a collector could not authenticate — carried by `CollectorError.missingCredentials`,
/// `.notSignedIn` and `.silentBackoff` instead of a pre-rendered English `String`.
///
/// These messages are what a user reads under a provider's Test Connection result
/// in macOS Settings, and they are the most common real failure: "no API key
/// found", "session expired". They used to be English literals at 103 throw sites
/// across 47 collectors. Being ARGUMENTS rather than returns, no localization gate
/// could see them.
///
/// Now the payload is typed, so the compiler rejects a new unlocalized message:
/// there is no `String` to pass. Technical tokens — an environment variable, a
/// cookie field, a host, a shell command — are parameters, so they survive
/// translation verbatim.
///
/// Rendered twice from one switch (`L10n.collectorCredential`): in the active
/// locale for the UI, and in English for logs, which stay greppable.
public struct CredentialProblem: Sendable, Equatable {
    /// Display name prefixed as "Provider: …", or nil when the sentence names the
    /// product itself.
    public let provider: String?
    public let issue: CredentialIssue

    public init(_ provider: String?, _ issue: CredentialIssue) {
        self.provider = provider
        self.issue = issue
    }

    /// For the UI, in the active locale.
    public var localizedText: String { render(english: false) }

    /// For logs: English whatever the active locale, byte-identical to the literal
    /// each throw site used to pass.
    public var englishText: String { render(english: true) }

    private func render(english: Bool) -> String {
        let body = L10n.collectorCredential.text(issue, english: english)
        guard let provider else { return body }
        return L10n.collectorCredential.withProvider(provider, body, english: english)
    }
}

public enum CredentialIssue: Sendable, Equatable {
    /// en: no API key found
    case noAPIKey
    /// en: no API token found
    case noAPIToken
    /// en: no credentials found
    case noCredentials
    /// en: no API key or cookie found
    case noAPIKeyOrCookie
    /// en: no API key (set {env})
    case noAPIKeySetEnv(String)
    /// en: no API key (set {env} or configure a key)
    case noAPIKeySetEnvOrConfigure(String)
    /// en: no base URL (set {env})
    case noBaseURLSetEnv(String)
    /// en: no deployment (set {env})
    case noDeploymentSetEnv(String)
    /// en: no endpoint (set {env})
    case noEndpointSetEnv(String)
    /// en: set {first} + {second}
    case setEnvPair(String, String)
    /// en: no {file} found
    case noFileFound(String)
    /// en: no refresh token
    case noRefreshToken
    /// en: no GCP project — run `{command}`
    case noGCPProject(String)
    /// en: gcloud ADC not found — run `{command}`
    case gcloudADCNotFound(String)
    /// en: ADC has no refresh_token
    case adcNoRefreshToken
    /// en: ADC missing client_id/secret
    case adcMissingClient
    /// en: service-account credentials require the gcloud CLI (not available in sandbox) — run `{command}`
    case serviceAccountNeedsGcloud(String)
    /// en: couldn't discover workspace — set {env} ({example})
    case couldNotDiscoverWorkspace(String, String)
    /// en: Developer-ID build only
    case developerIDBuildOnly
    /// en: org admin key ({prefix}) required
    case orgAdminKeyRequired(String)
    /// en: no session cookie (manual or auto-import)
    case noSessionCookieImportable
    /// en: no session cookie
    case noSessionCookie
    /// en: no {name} session cookie
    case noNamedSessionCookie(String)
    /// en: no {name} cookie
    case noNamedCookie(String)
    /// en: no auth token (manual or auto-import)
    case noAuthTokenImportable
    /// en: cookie has no {field}
    case cookieMissingField(String)
    /// en: cookie has no {field} value
    case cookieMissingValue(String)
    /// en: cookie has no {field} (log in)
    case cookieMissingFieldLogIn(String)
    /// en: cookie has no {field} (not signed in)
    case cookieMissingFieldNotSignedIn(String)
    /// en: cookie needs {fields} (log in at {host})
    case cookieNeedsFieldsLogInAt(String, String)
    /// en: paste a Devin session bundle or set {env} + {extra}
    case pasteSessionBundleOrSetEnv(String, String)
    /// en: sign in at {host} (cookie auto-import) or set {env}
    case signInAtOrSetEnv(String, String)
    /// en: not signed in — open {host} in your browser, or paste a session cookie
    case notSignedInOpenOrPaste(String)
    /// en: access blocked by Vercel bot protection. Open {host} in your browser, ensure you are logged in, then refresh your session cookies.
    case botProtectionBlocked(String)
    /// en: login required
    case loginRequired
    /// en: session expired or unauthorized
    case sessionExpiredOrUnauthorized
    /// en: session expired (sign in again)
    case sessionExpiredSignInAgain
    /// en: session expired (log in again)
    case sessionExpiredLogInAgain
    /// en: session expired/invalid
    case sessionExpiredInvalid
    /// en: session expired/invalid (sign in at {host} or refresh {env})
    case sessionExpiredInvalidHint(String, String)
    /// en: unauthenticated (sign in at {host} or refresh {env})
    case unauthenticatedHint(String, String)
    /// en: unauthorized
    case unauthorized
    /// en: API key rejected (401/403)
    case apiKeyRejected
    /// en: API key rejected (HTTP {status})
    case apiKeyRejectedStatus(String)
    /// en: session rejected
    case sessionRejected
    /// en: redirected off-origin
    case redirectedOffOrigin
    /// en: credentials rejected by {service}
    case credentialsRejectedBy(String)
    /// en: token expired — reconnect via CLI Pulse OAuth
    case tokenExpiredReconnectOAuth
    /// en: token expired, no refresh_token available
    case tokenExpiredNoRefreshToken
    /// en: token expired (silenced for {minutes}min after first error)
    case tokenExpiredSilenced(String)
    /// en: token refresh failed ({code}) — run `{command}` again
    case tokenRefreshFailedRun(String, String)
    /// en: {product} access token became nil after refresh
    case accessTokenNilAfterRefresh(String)
    /// en: {product} auth.json not found or has no access token
    case authFileMissingAccessToken(String)
    /// en: {product} API key not configured
    case apiKeyNotConfigured(String)
    /// en: {text}
    /// Text the provider's SERVER returned, passed through verbatim. Never give it a
    /// string literal — that is an unlocalized message wearing a typed costume, and
    /// `check_hardcoded_ui_strings.py` fails on it.
    case serverMessage(String)
    /// Reuses `collector_status.zed_sign_in_from_editor`, which Zed already localized at the throw site.
    case zedSignInFromEditor
    /// Reuses `collector_status.zed_keychain_needs_approval`, which Zed already localized at the throw site.
    case zedKeychainNeedsApproval
    /// Reuses `collector_status.zed_keychain_read_failed`, which Zed already localized at the throw site.
    case zedKeychainReadFailed(Int)
    /// Reuses `collector_status.zed_credentials_expired`, which Zed already localized at the throw site.
    case zedCredentialsExpired
}
