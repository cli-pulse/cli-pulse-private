import Foundation

/// Text a person typed, folded to the form a server or a comparison expects.
///
/// A Japanese or Chinese input source set to full-width alphanumerics (or with
/// its full-width numerals option on) types "１２３４５６" and "ＤＥＬＥＴＥ". They
/// look like the ASCII the user meant, and nothing on screen says why they are
/// rejected. The values sent and compared stay ASCII; only the input is folded.
public enum UserInputNormalization {

    /// The emailed sign-in code, as sent to the auth server.
    ///
    /// NFKC maps full-width digits and the ideographic space to ASCII. Whitespace
    /// anywhere is dropped: a code never contains any, and "123 456" is how people
    /// copy one out of an email.
    public static func otpCode(_ raw: String) -> String {
        String(
            raw.precomposedStringWithCompatibilityMapping
                .unicodeScalars
                .filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
        )
    }

    /// The word typed to confirm account deletion.
    ///
    /// Still exactly "DELETE", case included, because the typing is the safety
    /// catch. Width is not part of that word, so "ＤＥＬＥＴＥ" counts.
    public static func isDeleteConfirmation(_ typed: String) -> Bool {
        typed.precomposedStringWithCompatibilityMapping == deleteConfirmationWord
    }

    public static let deleteConfirmationWord = "DELETE"
}
