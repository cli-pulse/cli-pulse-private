import XCTest
@testable import CLIPulseCore

/// SwiftUI on iPhone wrapped Korean between any two syllables ("전송|되지",
/// "사용|되며"). The app root now typesets Korean as Latin text, which wraps at
/// the spaces between words. The wrapping itself was measured on the iOS
/// simulator (see `KoreanLineBreaking`); `swift test` runs on the Mac, where
/// Korean already wraps at spaces, so this pins who gets it and that the
/// iPhone root applies it.
final class KoreanLineBreakingTests: XCTestCase {

    private var savedLocaleOverride: String?

    override func setUp() {
        super.setUp()
        savedLocaleOverride = LocaleOverrideStore.shared.override
    }

    override func tearDown() {
        LocaleOverrideStore.shared.set(savedLocaleOverride)
        super.tearDown()
    }

    func test_onlyKoreanIsTypesetToWrapAtSpaces() {
        XCTAssertTrue(KoreanLineBreaking.wrapsAtSpaces(localization: "ko"))
        for other in ["en", "es", "ja", "zh-Hans", "zh-Hant", nil] as [String?] {
            XCTAssertFalse(KoreanLineBreaking.wrapsAtSpaces(localization: other), String(describing: other))
        }
        XCTAssertEqual(Set(LocaleOverrideStore.shippedLocalizations.filter {
            KoreanLineBreaking.wrapsAtSpaces(localization: $0)
        }), ["ko"])
    }

    func test_theIPhoneRoot_keepsKoreanWordsWhole() throws {
        let app = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // …/Tests/CLIPulseCoreTests
            .deletingLastPathComponent()    // …/Tests
            .deletingLastPathComponent()    // …/CLIPulseCore
            .deletingLastPathComponent()    // …/CLI Pulse Bar
            .appending(path: "CLI Pulse Bar iOS/CLIPulseApp_iOS.swift")
        let source = try String(contentsOf: app, encoding: .utf8)
        let scene = try XCTUnwrap(source.range(of: "WindowGroup {"), "no WindowGroup in the iPhone app")
        let commands = try XCTUnwrap(source.range(of: ".commands {", range: scene.upperBound..<source.endIndex))
        let content = source[scene.upperBound..<commands.lowerBound]
        XCTAssertTrue(content.contains(".keepsKoreanWordsWhole()"), String(content))
    }

    /// Typeset as English, a line can still break where a run that is not
    /// Hangul meets the Hangul particle after it. On the iPhone the privacy
    /// footer wrapped as "…Google 등)" / "는 macOS 키체인에만…", the particle
    /// starting a line on its own. The iPhone's strings whose parenthetical
    /// ended right before a particle are reworded, so none of them puts Hangul
    /// straight after a closing bracket, quote or backtick. Read in Korean,
    /// with arguments filled in as the screen shows them.
    func test_iPhoneKoreanText_hasNoHangulRightAfterAClosingBracket() {
        LocaleOverrideStore.shared.set("ko")
        let shown = [
            L10n.onboardingWizard.privacyKeysDetail,
            L10n.onboarding.cloudSyncDesc,
            L10n.auth.codeSentTo("dev@example.com"),
            L10n.account.unlinkMessage("GitHub"),
            L10n.alertKind.budgetDailyMessage("12.50", "10.00"),
            L10n.alertKind.budgetWeeklyMessage("80.00", "50.00"),
            L10n.providers.claudeSignedInConnectHint("dev@example.com"),
        ]
        let closing: Set<Character> = [")", "]", "」", "』", "’", "`"]
        func isHangulSyllable(_ c: Character) -> Bool {
            c.unicodeScalars.first.map { (0xAC00...0xD7A3).contains($0.value) } ?? false
        }
        for text in shown {
            XCTAssertTrue(text.contains(where: isHangulSyllable), "control: not the Korean text: \(text)")
            let characters = Array(text)
            for (before, after) in zip(characters, characters.dropFirst())
            where closing.contains(before) && isHangulSyllable(after) {
                XCTFail("\"\(before)\(after)\" can start a line with the particle: \(text)")
            }
        }
    }
}
