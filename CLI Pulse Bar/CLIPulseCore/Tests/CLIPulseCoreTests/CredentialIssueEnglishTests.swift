#if os(macOS)
import XCTest
@testable import CLIPulseCore

/// Pins the ENGLISH rendering of every `CredentialIssue` case, generated from the
/// same spec that produced the catalogue and converted the 103 throw sites.
///
/// Before this change each throw site passed its own English literal. The
/// conversion re-rendered every template and proved it byte-identical to the
/// literal it replaced; this keeps it that way. English matters because it is
/// what the collector error log and os_log print.
///
/// Placeholder arguments are `ARG0`, `ARG1`, … so a template that drops,
/// duplicates or reorders a parameter fails here.
final class CredentialIssueEnglishTests: XCTestCase {

    func testEveryIssueRendersItsOriginalEnglish() {
        let store = LocaleOverrideStore.shared
        let previous = store.override
        store.set("zh-Hans")                   // English must not depend on the UI language
        defer { store.set(previous) }

        let cases: [(CredentialIssue, String)] = [
            (.noAPIKey, "no API key found"),
            (.noAPIToken, "no API token found"),
            (.noCredentials, "no credentials found"),
            (.noAPIKeyOrCookie, "no API key or cookie found"),
            (.noAPIKeySetEnv("ARG0"), "no API key (set ARG0)"),
            (.noAPIKeySetEnvOrConfigure("ARG0"), "no API key (set ARG0 or configure a key)"),
            (.noBaseURLSetEnv("ARG0"), "no base URL (set ARG0)"),
            (.noDeploymentSetEnv("ARG0"), "no deployment (set ARG0)"),
            (.noEndpointSetEnv("ARG0"), "no endpoint (set ARG0)"),
            (.setEnvPair("ARG0", "ARG1"), "set ARG0 + ARG1"),
            (.noFileFound("ARG0"), "no ARG0 found"),
            (.noRefreshToken, "no refresh token"),
            (.noGCPProject("ARG0"), "no GCP project — run `ARG0`"),
            (.gcloudADCNotFound("ARG0"), "gcloud ADC not found — run `ARG0`"),
            (.adcNoRefreshToken, "ADC has no refresh_token"),
            (.adcMissingClient, "ADC missing client_id/secret"),
            (.serviceAccountNeedsGcloud("ARG0"), "service-account credentials require the gcloud CLI (not available in sandbox) — run `ARG0`"),
            (.couldNotDiscoverWorkspace("ARG0", "ARG1"), "couldn't discover workspace — set ARG0 (ARG1)"),
            (.developerIDBuildOnly, "Developer-ID build only"),
            (.orgAdminKeyRequired("ARG0"), "org admin key (ARG0) required"),
            (.noSessionCookieImportable, "no session cookie (manual or auto-import)"),
            (.noSessionCookie, "no session cookie"),
            (.noNamedSessionCookie("ARG0"), "no ARG0 session cookie"),
            (.noNamedCookie("ARG0"), "no ARG0 cookie"),
            (.noAuthTokenImportable, "no auth token (manual or auto-import)"),
            (.cookieMissingField("ARG0"), "cookie has no ARG0"),
            (.cookieMissingValue("ARG0"), "cookie has no ARG0 value"),
            (.cookieMissingFieldLogIn("ARG0"), "cookie has no ARG0 (log in)"),
            (.cookieMissingFieldNotSignedIn("ARG0"), "cookie has no ARG0 (not signed in)"),
            (.cookieNeedsFieldsLogInAt("ARG0", "ARG1"), "cookie needs ARG0 (log in at ARG1)"),
            (.pasteSessionBundleOrSetEnv("ARG0", "ARG1"), "paste a Devin session bundle or set ARG0 + ARG1"),
            (.signInAtOrSetEnv("ARG0", "ARG1"), "sign in at ARG0 (cookie auto-import) or set ARG1"),
            (.notSignedInOpenOrPaste("ARG0"), "not signed in — open ARG0 in your browser, or paste a session cookie"),
            (.botProtectionBlocked("ARG0"), "access blocked by Vercel bot protection. Open ARG0 in your browser, ensure you are logged in, then refresh your session cookies."),
            (.loginRequired, "login required"),
            (.sessionExpiredOrUnauthorized, "session expired or unauthorized"),
            (.sessionExpiredSignInAgain, "session expired (sign in again)"),
            (.sessionExpiredLogInAgain, "session expired (log in again)"),
            (.sessionExpiredInvalid, "session expired/invalid"),
            (.sessionExpiredInvalidHint("ARG0", "ARG1"), "session expired/invalid (sign in at ARG0 or refresh ARG1)"),
            (.unauthenticatedHint("ARG0", "ARG1"), "unauthenticated (sign in at ARG0 or refresh ARG1)"),
            (.unauthorized, "unauthorized"),
            (.apiKeyRejected, "API key rejected (401/403)"),
            (.apiKeyRejectedStatus("ARG0"), "API key rejected (HTTP ARG0)"),
            (.sessionRejected, "session rejected"),
            (.redirectedOffOrigin, "redirected off-origin"),
            (.credentialsRejectedBy("ARG0"), "credentials rejected by ARG0"),
            (.tokenExpiredReconnectOAuth, "token expired — reconnect via CLI Pulse OAuth"),
            (.tokenExpiredNoRefreshToken, "token expired, no refresh_token available"),
            (.tokenExpiredSilenced("ARG0"), "token expired (silenced for ARG0min after first error)"),
            (.tokenRefreshFailedRun("ARG0", "ARG1"), "token refresh failed (ARG0) — run `ARG1` again"),
            (.accessTokenNilAfterRefresh("ARG0"), "ARG0 access token became nil after refresh"),
            (.authFileMissingAccessToken("ARG0"), "ARG0 auth.json not found or has no access token"),
            (.apiKeyNotConfigured("ARG0"), "ARG0 API key not configured"),
            (.serverMessage("ARG0"), "ARG0"),
            (.zedSignInFromEditor, "Zed: sign in from the Zed editor (GitHub)"),
            (.zedKeychainNeedsApproval, "Zed: Keychain access needs approval — allow access to zed.dev in the dialog, or sign in to Zed again"),
            (.zedKeychainReadFailed(42), "Zed: could not read Keychain (status 42)"),
            (.zedCredentialsExpired, "Zed: credentials invalid/expired — sign in to Zed again"),
        ]
        XCTAssertEqual(cases.count, 59, "a case was added without an English pin")
        for (issue, english) in cases {
            XCTAssertEqual(CredentialProblem(nil, issue).englishText, english, "\(issue)")
        }
    }

    func testTheProviderPrefixIsEnglishInLogs() {
        XCTAssertEqual(CredentialProblem("Kimi K2", .noAPIKey).englishText, "Kimi K2: no API key found")
    }
}
#endif
