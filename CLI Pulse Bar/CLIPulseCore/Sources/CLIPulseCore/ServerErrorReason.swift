import Foundation

/// What a failed Supabase response means to the person reading the error.
///
/// `APIError.httpError` and `HelperAPIError.httpError` carry the response body,
/// and their descriptions used to print it: a Japanese user whose email code had
/// expired read `HTTP 403：{"code":403,"error_code":"otp_expired","msg":"Token has
/// expired or is invalid"}` on the sign-in screen. The body is the server's own
/// English JSON in every language, so only the `HTTP %d:` wrapper was translated.
///
/// This reduces a response to a small closed set, keyed first by the machine
/// code the body carries (GoTrue `error_code`, PostgREST `code`) and then by the
/// status, so the screen can say what happened in the user's language. Anything
/// unrecognised becomes a generic message that keeps the status for support but
/// never the body. The body itself stays on the error value — code such as
/// `APIClient.isProviderAccountRPCUnavailable` parses it — and is logged where
/// the error is thrown.
///
/// The raw values are stable English tokens: the helper stores them in the
/// app group (`HelperSyncFailure`), so renaming one strands every stored status.
public enum ServerErrorReason: String, CaseIterable, Sendable {
    case codeInvalidOrExpired = "code_invalid_or_expired"
    case rateLimited = "rate_limited"
    case invalidCredentials = "invalid_credentials"
    case invalidEmail = "invalid_email"
    case invalidInput = "invalid_input"
    case identityAlreadyLinked = "identity_already_linked"
    case lastIdentity = "last_identity"
    case linkingDisabled = "linking_disabled"
    case sessionExpired = "session_expired"
    case timeout = "timeout"
    /// The helper's device row is gone or its secret no longer matches — this
    /// Mac has to be paired again. Retrying never succeeds.
    case deviceNotPaired = "device_not_paired"
    /// Any other 5xx: the server's problem, worth retrying later.
    case unavailable = "unavailable"
    /// Anything else. Shown with the status and nothing from the body.
    case failed = "failed"

    public static func classify(status: Int, body: String) -> ServerErrorReason {
        let object = jsonObject(body)
        if let code = serverCode(in: object) {
            if code == raisedException, object?["message"] as? String == deviceNotFoundMessage {
                return .deviceNotPaired
            }
            if let reason = byServerCode[code] {
                return reason
            }
        }
        if status == 429 { return .rateLimited }
        if (500...599).contains(status) { return .unavailable }
        return .failed
    }

    /// GoTrue puts its machine code in `error_code` (its own `code` is the numeric
    /// status); PostgREST puts a SQLSTATE or `PGRST…` string in `code`. A body that
    /// is not JSON — a gateway's HTML error page, say — has no code.
    ///
    /// The code is what failure logs record in public: it names the case without
    /// carrying the server's text, which can echo a whole row back.
    static func serverCode(in body: String) -> String? {
        serverCode(in: jsonObject(body))
    }

    private static func serverCode(in object: [String: Any]?) -> String? {
        guard let object else { return nil }
        for key in ["error_code", "code"] {
            if let code = object[key] as? String, !code.isEmpty {
                return code
            }
        }
        return nil
    }

    private static func jsonObject(_ body: String) -> [String: Any]? {
        guard let data = body.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// A plain `raise exception` in PL/pgSQL is SQLSTATE P0001 (HTTP 400 from
    /// PostgREST), shared by every message our RPCs raise, so the code alone says
    /// nothing. The helper-credential RPCs (`helper_heartbeat`, `helper_sync`,
    /// `helper_sync_provider_account_quotas`, `helper_report_app_version`) raise
    /// this exact text when the device row is gone or the secret does not match
    /// (backend/supabase/helper_rpc.sql and its later migrations). It was the only
    /// clue the helper's most common sync failure gave, so it is matched by text,
    /// as `APIClient.isProviderAccountRPCUnavailable` matches PGRST202's.
    private static let raisedException = "P0001"
    private static let deviceNotFoundMessage = "Device not found or unauthorized"

    /// Only the codes the app's own flows actually hit: email-code and password
    /// sign-in, identity linking, session refresh, and a statement timeout on a
    /// slow RPC. PostgREST's JWT codes are left out on purpose — the helper calls
    /// with the anon key, where they would mean a broken configuration, not an
    /// expired sign-in, and "sign in again" would send the user the wrong way.
    private static let byServerCode: [String: ServerErrorReason] = [
        "otp_expired": .codeInvalidOrExpired,
        "over_email_send_rate_limit": .rateLimited,
        "over_request_rate_limit": .rateLimited,
        "over_sms_send_rate_limit": .rateLimited,
        "invalid_credentials": .invalidCredentials,
        "email_address_invalid": .invalidEmail,
        "validation_failed": .invalidInput,
        "identity_already_exists": .identityAlreadyLinked,
        "single_identity_not_deletable": .lastIdentity,
        "manual_linking_disabled": .linkingDisabled,
        "session_not_found": .sessionExpired,
        "session_expired": .sessionExpired,
        "refresh_token_not_found": .sessionExpired,
        "refresh_token_already_used": .sessionExpired,
        "bad_jwt": .sessionExpired,
        "57014": .timeout,
    ]

    /// Positional status for the two generic reasons; the others ignore it.
    public func localizedText(status: Int) -> String {
        switch self {
        case .codeInvalidOrExpired: return L10n.serverError.codeInvalidOrExpired
        case .rateLimited: return L10n.serverError.rateLimited
        case .invalidCredentials: return L10n.serverError.invalidCredentials
        case .invalidEmail: return L10n.serverError.invalidEmail
        case .invalidInput: return L10n.serverError.invalidInput
        case .identityAlreadyLinked: return L10n.serverError.identityAlreadyLinked
        case .lastIdentity: return L10n.serverError.lastIdentity
        case .linkingDisabled: return L10n.serverError.linkingDisabled
        case .sessionExpired: return L10n.auth.errorSessionExpired
        case .timeout: return L10n.serverError.timeout
        case .deviceNotPaired: return L10n.serverError.deviceNotPaired
        case .unavailable: return L10n.serverError.unavailable(status)
        case .failed: return L10n.serverError.failed(status)
        }
    }
}
