import Foundation

/// The account name built from Sign in with Apple's name components.
///
/// Joining "given family" with a space turned 山田 太郎 into "太郎 山田" and
/// 김 민준 into "민준 김". Chinese, Japanese and Korean names are written family
/// name first with no space between the parts.
///
/// The order follows the script of the name, not the device language: the
/// result is sent to the server as the account name and shown on every device,
/// so the same Apple ID must produce the same string whichever language the
/// phone that signed in happened to use. A fixed rule on the name's own
/// characters guarantees that; a display formatter's output is not promised to.
public enum AppleSignInName {

    public static func fullName(from components: PersonNameComponents?) -> String? {
        let given = components?.givenName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let family = components?.familyName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let parts = [given, family].filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        if !given.isEmpty, !family.isEmpty, isEastAsianName(given + family) {
            return family + given
        }
        return parts.joined(separator: " ")
    }

    /// Every letter is Han, kana or Hangul. A mixed name ("Taro 山田") keeps the
    /// Western order, because there is no single convention to follow.
    static func isEastAsianName(_ name: String) -> Bool {
        let scalars = name.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
        return !scalars.isEmpty && scalars.allSatisfy(isEastAsianNameScalar)
    }

    private static func isEastAsianNameScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x11FF,   // Hangul Jamo
             0x3005,            // 々 iteration mark (佐々木)
             0x3040...0x30FF,   // Hiragana, Katakana (incl. ー)
             0x3130...0x318F,   // Hangul Compatibility Jamo
             0x3400...0x4DBF,   // CJK Extension A
             0x4E00...0x9FFF,   // CJK Unified Ideographs
             0xAC00...0xD7AF,   // Hangul Syllables
             0xF900...0xFAFF,   // CJK Compatibility Ideographs
             0xFF66...0xFF9F,   // half-width Katakana
             0x20000...0x3134F: // CJK Extensions B–G
            return true
        default:
            return false
        }
    }
}
