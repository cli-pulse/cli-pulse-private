import SwiftUI

/// Where SwiftUI may wrap a line of Korean.
///
/// Korean puts spaces between words (어절), and a reader expects a line to wrap
/// at one of them. SwiftUI's `Text` typesets Korean with the
/// Chinese-and-Japanese rule instead, which allows a break between any two
/// syllables, so words split across lines: "전송|되지", "사용|되며", "호출|하는"
/// on the iPhone, "설치|됐다는", "업로드|되지" on the Mac.
///
/// Typesetting that text as English makes SwiftUI break at the spaces instead
/// of between Hangul syllables, and changes nothing else visible: Hangul
/// glyphs, line height and the placement of Latin words in between are the
/// same. Measured on the iOS 26.5 and 18.5 simulators with the iPhone's
/// onboarding, sign-in, account and budget-alert strings at 318, 330 and 359
/// points: without it, four words split between syllables; with it, none did.
///
/// ON THE MAC
/// The Mac splits Korean words the same way. Measured in the offscreen renders
/// of the real Mac app (QA build, macOS 27, 74 Korean views; every line read
/// back by OCR and each wrap checked against the catalogue, the views that
/// changed also by eye): with the system's rule, two words split between
/// syllables ("설치|됐다는" in the statistics notice, "업로드|되지" on the setup
/// privacy page) and "Wi-Fi" broke at its non-breaking hyphen, which that rule
/// does not honour; with this, none did.
/// No line put a particle after a Latin word, number or bracket on its own,
/// before or after. 62 of the 74 views were pixel-identical, the language
/// menu (AppKit) among them; 8 changed where a line wraps, 4 only in their
/// demo numbers and clock. `DisplayLocaleRoot`, which every Mac scene and
/// hosting root applies, applies this from macOS 14; macOS 13 has no
/// `typesettingLanguage` and keeps the system's rule. The menu bar readout is
/// not under that root and is unaffected.
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
/// NOT WITH WORD JOINERS (measured, declined 2026-09-27)
/// Joiners between the syllables of each word would live in the catalogue, in
/// every copy, search and translation review of it. The narrower idea was
/// measured: insert U+2060 WORD JOINER at display time, in the iPhone app only,
/// between a Latin letter, digit, closing bracket, % or backtick and the Hangul
/// particle after it. 18 real Korean strings at every width from 90 to 400
/// points, 5,598 layouts, on the iOS 26.5 and 18.5 simulators:
/// - typeset as English (the iPhone app): particles split from their word 344
///   times without the joiner, 0 with it; the 26 splits inside Hangul words
///   wider than the line were the same either way; 60 more lines in all; no
///   line height changed; the 421 layouts that wrapped the same way were
///   pixel-identical;
/// - under Korean's own rule on iOS (what the widgets use), SwiftUI breaks at
///   the joiner: particle splits went from 104 to 178. On macOS 27 under that
///   rule it made no difference (45 either way). The Watch was not measured.
/// Not adopted. It would put U+2060 into every Korean string the iPhone app
/// shows, accessibility labels included, and into text that crosses to the
/// Watch (`DashboardSummary.risk_signals`). What it does to braille output and
/// to Voice Control matching a spoken label could not be verified, and braille
/// translators commonly print a character they do not know as an escape code.
/// A typographic gain does not justify an accessibility regression nobody can
/// check. Where a line may wrap stays the renderer's business.
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
