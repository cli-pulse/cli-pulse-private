import Foundation
import AuthenticationServices
import os

private let webAuthLogger = Logger(subsystem: "com.clipulse", category: "WebAuthSession")

/// What to show when an `ASWebAuthenticationSession` ends in an error: Google and
/// GitHub sign-in and linking on the iPhone, and Connect Gemini on the Mac.
///
/// The same decision as `AppleSignInFailure`, for the browser sheet. Closing the
/// sheet is not an error. The session's other errors (in practice
/// `presentationContextNotProvided` / `presentationContextInvalid`, which are
/// programming errors) arrive as a system sentence carrying the English domain
/// and code, which the three call sites used to show as it was. They become the
/// caller's own localized line, and the domain and code go to the log.
public enum WebAuthSessionFailure {
    /// `nil` when the person closed the browser sheet; otherwise `generic`.
    public static func message(for error: Error, generic: String) -> String? {
        if isCancellation(error) { return nil }
        let nsError = error as NSError
        webAuthLogger.error(
            "Web authentication session failed: \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public)"
        )
        return generic
    }

    /// Google / GitHub sign-in on the login screen.
    public static func signInMessage(for error: Error) -> String? {
        message(for: error, generic: L10n.auth.signInFailedGeneric)
    }

    /// Linking Google / GitHub from Linked Accounts.
    public static func linkMessage(for error: Error) -> String? {
        message(for: error, generic: L10n.auth.linkFailedGeneric)
    }

    /// Domain and code both: code 1 alone is `canceledLogin` here but means
    /// something else in almost every other domain.
    static func isCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == ASWebAuthenticationSessionError.errorDomain
            && nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue
    }
}
