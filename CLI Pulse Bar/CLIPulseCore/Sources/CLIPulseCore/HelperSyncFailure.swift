import Foundation

/// The Login Item helper's last sync failure: written as data by the helper,
/// turned into text by the app.
///
/// The helper used to store `error.localizedDescription`, and Settings › Advanced
/// showed it verbatim. That text was formatted in the helper's process, which
/// never sees the in-app language choice (it lives in the app's own defaults)
/// and declares no localizations of its own — and for an HTTP failure it
/// carried the raw PostgREST body. A user who picked 日本語 read
/// `HTTP 400 from helper_sync: {"code":"P0001",…}` until the next good sync.
///
/// So the helper stores a stable English token, and the app renders it in its
/// own language when it draws.
public enum HelperSyncFailure {
    /// Stable, PII-free token for `HelperIPC.Status.errorCode`:
    /// `http_<status>_<ServerErrorReason>`, `network`, one of
    /// `HelperAPIError.diagnosticCode`'s values, or `unknown`.
    public static func code(for error: Error) -> String {
        if let helperError = error as? HelperAPIError {
            if case let .httpError(status, _, body) = helperError {
                let kind = ServerErrorReason.classify(status: status, body: body)
                return "http_\(status)_\(kind.rawValue)"
            }
            return helperError.diagnosticCode
        }
        if (error as NSError).domain == NSURLErrorDomain {
            return networkCode
        }
        return unknownCode
    }

    /// What Settings shows for a stored status, or `nil` when there is nothing to show.
    ///
    /// - `code == nil`: a helper from before the field. Its stored text is the
    ///   only thing there is, so it is shown as before.
    /// - a code this build does not know (a newer helper): a generic localized
    ///   line, not the English detail stored beside it.
    public static func displayText(code: String?, storedText: String?) -> String? {
        guard let code else { return storedText }
        if code == networkCode {
            return L10n.serverError.network
        }
        if code == "not_configured" {
            return L10n.a11y.configurationErrorBody
        }
        if let (status, reason) = httpParts(of: code) {
            return reason.localizedText(status: status)
        }
        if code.hasPrefix(rejectedPrefix) {
            // `pairingRejected` localizes the codes it knows and otherwise returns
            // the message it was given; an empty one means "not known".
            let rejected = HelperAPIError.pairingRejected(
                code: String(code.dropFirst(rejectedPrefix.count)), message: ""
            ).errorDescription ?? ""
            if !rejected.isEmpty { return rejected }
        }
        return L10n.advanced.helperSyncFailed
    }

    static let networkCode = "network"
    static let unknownCode = "unknown"
    private static let rejectedPrefix = "rejected_"

    /// `http_503_unavailable` → (503, .unavailable). The reason's raw value has
    /// underscores of its own, so only the first one after the status splits.
    static func httpParts(of code: String) -> (Int, ServerErrorReason)? {
        guard code.hasPrefix("http_") else { return nil }
        let rest = code.dropFirst("http_".count)
        guard
            let separator = rest.firstIndex(of: "_"),
            let status = Int(rest[..<separator]),
            let reason = ServerErrorReason(rawValue: String(rest[rest.index(after: separator)...]))
        else {
            return nil
        }
        return (status, reason)
    }
}
