import SwiftUI

/// Where SwiftUI may wrap a line of Korean.
///
/// Korean puts spaces between words (어절), and a reader expects a line to wrap
/// at one of them. SwiftUI's `Text` on iPhone typesets Korean with the
/// Chinese-and-Japanese rule instead, which allows a break between any two
/// syllables, so words split across lines: "전송|되지", "사용|되며", "호출|하는".
///
/// Typesetting that text as English makes SwiftUI break at the spaces instead
/// of between Hangul syllables, and changes nothing else visible: Hangul
/// glyphs, line height and the placement of Latin words in between are the
/// same. Measured on the iOS 26.5 and 18.5 simulators with the iPhone's
/// onboarding, sign-in, account and budget-alert strings at 318, 330 and 359
/// points: without it, four words split between syllables; with it, none did.
///
/// WHAT STILL BREAKS
/// Typeset as English, a line may break where a run that is not Hangul ends
/// and the Hangul attached to it begins, which the Korean rule kept together:
/// after a closing bracket or quote ("…Google 등)" / "는 macOS…"), a Latin word
/// ("Mac" / "은", "API" / "를"), a number ("30" / "초"), a percent sign or a
/// backtick. The particle then starts the next line. Measured the same way.
///
/// That is the trade taken. The Korean rule may split any Hangul word of two
/// syllables or more; this one only where a name, number or bracket meets the
/// Hangul after it.
/// The iPhone strings whose parenthetical ended right before its particle are
/// reworded without the parenthesis, and a test keeps them that way. A Latin
/// word or number followed by its particle is how most of the app's Korean
/// names things, so it is left as it is. No other typesetting language tried
/// keeps both kinds whole: French, Russian, Arabic, Hindi, Thai, Vietnamese
/// and "und" behave as English, and Korean with the `lw=keepall` extension
/// renders exactly as plain Korean.
///
/// NOT FOR OTHER LANGUAGES
/// Chinese and Japanese have no spaces to break at, so the per-character rule
/// is the right one there. Spanish and English already typeset as Latin.
///
/// NOT ON THE MAC
/// macOS SwiftUI already keeps Korean words whole: the same strings rendered
/// with `AppleLanguages` set to Korean wrap at spaces with or without this
/// (measured on macOS 27). The Mac app also supports macOS 13, which this
/// modifier does not.
///
/// NOT WITH INVISIBLE JOINERS
/// Word joiners between the syllables of each word would hold it together too,
/// but they would live in the catalogue, in every copy, search and translation
/// review of it. Where a line may wrap is the renderer's business.
public enum KoreanLineBreaking {

    /// Whether text in `localization` needs Latin typesetting to wrap at its
    /// spaces. Only Korean does.
    public static func wrapsAtSpaces(localization: String?) -> Bool {
        localization == "ko"
    }

    /// The language the text is typeset as when it does. English, for its
    /// space-based line breaking; nothing about the text is translated.
    static let typesettingLanguage = Locale.Language(identifier: "en")
}

@available(iOS 17.0, macOS 14.0, watchOS 10.0, *)
public extension View {
    /// Keeps Korean words whole when SwiftUI wraps text below this view. Apply
    /// it once, at the root of a scene. See `KoreanLineBreaking`.
    func keepsKoreanWordsWhole(
        localization: String? = LocaleOverrideStore.resolvedLocalization
    ) -> some View {
        typesettingLanguage(
            KoreanLineBreaking.typesettingLanguage,
            isEnabled: KoreanLineBreaking.wrapsAtSpaces(localization: localization)
        )
    }
}
