// 1.60: the Mac sign-in email fields take AutoFill out of the path.
//
// The two Email fields of the Settings sign-in panel (the password form and
// the email-code form) are `NoAutoFillTextField`s, which set no content type
// and no text completion, instead of SwiftUI `TextField`s, which AppKit may
// offer Keychain / iCloud Password AutoFill on. Shipped as insurance: it
// removes AutoFill from the sign-in path; it is not claimed to be the cause
// of any particular freeze.
//
// The view lives in the app target, which this package cannot compile, so the
// checks read the sources, as `HostNameMainThreadTests` does.
//
// macOS-gated: the files are the Mac target's.

#if os(macOS)
import Foundation
import XCTest
@testable import CLIPulseCore

final class SignInEmailFieldAutoFillTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // CLIPulseCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // CLIPulseCore
        .deletingLastPathComponent()   // CLI Pulse Bar
        .deletingLastPathComponent()   // repository root

    /// The file without its `//` comments, so a commented-out field counts for nothing.
    private func source(_ name: String) throws -> String {
        let url = Self.repoRoot.appendingPathComponent("CLI Pulse Bar/CLI Pulse Bar/\(name)")
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard let comment = line.range(of: "//") else { return String(line) }
            return String(line[..<comment.lowerBound])
        }.joined(separator: "\n")
    }

    /// The sign-in panel: from its declaration to the error line that ends it.
    private func loginSection() throws -> String {
        let settings = try source("SettingsTab.swift")
        let start = try XCTUnwrap(settings.range(of: "private var loginSection: some View {"))
        let end = try XCTUnwrap(settings.range(of: "if let error = state.lastError", range: start.upperBound..<settings.endIndex))
        return String(settings[start.lowerBound..<end.lowerBound])
    }

    private func matches(_ pattern: String, in text: String) throws -> Int {
        try NSRegularExpression(pattern: pattern).numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    func testBothSignInEmailFieldsAreNoAutoFillTextFields() throws {
        let section = try loginSection()
        XCTAssertEqual(try matches(#"\bNoAutoFillTextField\(\s*placeholder: L10n\.settings\.email,"#, in: section), 2,
                       "the password form and the email-code form each have an email field")
        // No SwiftUI field takes an email: neither by the title it used, nor
        // by any title that mentions email, nor a bound `$email` of its own.
        XCTAssertEqual(try matches(#"(?<![A-Za-z])TextField\("#, in: section), 1,
                       "the sign-in panel has exactly one other text field: the one-time code")
        XCTAssertEqual(try matches(#"(?<![A-Za-z])TextField\(\s*L10n\.settings\.email"#, in: section), 0,
                       "a SwiftUI TextField is back on a sign-in email field")
        XCTAssertEqual(try matches(#"(?<![A-Za-z])TextField\([^)]*\$email"#, in: section), 0)
    }

    func testTheFieldsKeepTheirLabelSizeBindingAndLayout() throws {
        let section = try loginSection()
        XCTAssertEqual(try matches(#"\btext: \$email\b"#, in: section), 2)
        XCTAssertEqual(try matches(#"\bvoiceOverLabel: L10n\.settings\.email\b"#, in: section), 2,
                       "VoiceOver read the title of the SwiftUI field; the AppKit one needs it set")
        XCTAssertEqual(try matches(#"\bfontSize: 11\b"#, in: section), 2, "the fields were 11 pt")
        XCTAssertEqual(try matches(#"\bsingleLine: true\b"#, in: section), 2, "a SwiftUI field scrolls, it does not wrap")
        XCTAssertEqual(try matches(#"\.frame\(maxWidth: \.infinity, minHeight: 22\)"#, in: section), 2,
                       "a SwiftUI field fills the width")
    }

    func testTheComponentSuppressesAutoFillAndFollowsALanguageChange() throws {
        let file = try source("NoAutoFillFields.swift")
        let start = try XCTUnwrap(file.range(of: "struct NoAutoFillTextField"))
        let component = String(file[start.lowerBound...])
        XCTAssertTrue(component.contains("field.contentType = nil"))
        XCTAssertTrue(component.contains("field.isAutomaticTextCompletionEnabled = false"))
        // The Settings tab redraws in place on a language change, keeping what
        // was typed: the placeholder and the label are set again on update.
        let update = try XCTUnwrap(component.range(of: "func updateNSView"))
        let end = try XCTUnwrap(component.range(of: "func makeCoordinator", range: update.upperBound..<component.endIndex))
        XCTAssertTrue(component[update.upperBound..<end.lowerBound].contains("apply(to: nsView)"),
                      "updateNSView no longer refreshes the placeholder and the label")
        XCTAssertTrue(component.contains("field.placeholderString = placeholder"))
        XCTAssertTrue(component.contains("field.setAccessibilityLabel(voiceOverLabel)"))
    }

    /// The label and the placeholder come from `L10n.settings.email`; in every
    /// non-English language it is its own word, not the English fallback.
    func testTheFieldTextIsLocalised() {
        let saved = LocaleOverrideStore.shared.override
        defer { LocaleOverrideStore.shared.set(saved) }
        LocaleOverrideStore.shared.set("en")
        let english = L10n.settings.email
        XCTAssertEqual(english, "Email")
        for language in ["zh-Hans", "zh-Hant", "ja", "ko", "es"] {
            LocaleOverrideStore.shared.set(language)
            XCTAssertFalse(L10n.settings.email.isEmpty, language)
            XCTAssertNotEqual(L10n.settings.email, english, "\(language) fell back to English")
        }
    }
}
#endif
