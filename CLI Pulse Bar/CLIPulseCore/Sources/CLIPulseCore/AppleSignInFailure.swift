import Foundation
import AuthenticationServices
import os

private let appleSignInLogger = Logger(subsystem: "com.clipulse", category: "AppleSignIn")

/// What to show when a Sign in with Apple sheet ends in an error.
///
/// The iPhone login screen used to show `error.localizedDescription`, so simply
/// dismissing the sheet left a red "The operation couldn't be completed.
/// (com.apple.AuthenticationServices.AuthorizationError error 1001.)" under the
/// button. Cancelling is not an error. Every other `ASAuthorizationError` is a
/// system sentence with an English domain and code in it, which tells the user
/// nothing they can act on, so it becomes the app's own generic line and the
/// domain and code go to the log.
public enum AppleSignInFailure {
    /// `nil` when the person dismissed the sheet.
    public static func signInMessage(for error: Error) -> String? {
        isCancellation(error) ? nil : logged(error, generic: L10n.auth.signInFailedGeneric)
    }

    /// The same decision for linking Apple from Linked Accounts.
    public static func linkMessage(for error: Error) -> String? {
        isCancellation(error) ? nil : logged(error, generic: L10n.auth.linkFailedGeneric)
    }

    static func isCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == ASAuthorizationError.errorDomain
            && nsError.code == ASAuthorizationError.canceled.rawValue
    }

    private static func logged(_ error: Error, generic: String) -> String {
        let nsError = error as NSError
        appleSignInLogger.error(
            "Sign in with Apple failed: \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public)"
        )
        return generic
    }
}
