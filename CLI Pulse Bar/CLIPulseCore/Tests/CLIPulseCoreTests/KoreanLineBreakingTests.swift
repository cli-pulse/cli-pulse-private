import XCTest
@testable import CLIPulseCore

/// SwiftUI on iPhone wrapped Korean between any two syllables ("전송|되지",
/// "사용|되며"). The app root now typesets Korean as Latin text, which wraps at
/// the spaces between words. The wrapping itself was measured on the iOS
/// simulator (see `KoreanLineBreaking`); `swift test` runs on the Mac, where
/// Korean already wraps at spaces, so this pins who gets it and that the
/// iPhone root applies it.
final class KoreanLineBreakingTests: XCTestCase {

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
}
