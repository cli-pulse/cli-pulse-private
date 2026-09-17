import SwiftUI

/// Where SwiftUI may wrap a line of Korean.
///
/// Korean puts spaces between words (어절), and a reader expects a line to wrap
/// at one of them. SwiftUI's `Text` on iPhone typesets Korean with the
/// Chinese-and-Japanese rule instead, which allows a break between any two
/// syllables, so words split across lines: "전송|되지", "사용|되며", "호출|하는".
///
/// Typesetting that text as English makes SwiftUI break at the spaces, and
/// changes nothing else visible: Hangul glyphs, line height and the placement
/// of Latin words in between are the same. Measured on the iOS 26.5 simulator
/// with the onboarding and privacy strings at 318 to 359 points: without it,
/// three words split at those widths; with it, none did.
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
