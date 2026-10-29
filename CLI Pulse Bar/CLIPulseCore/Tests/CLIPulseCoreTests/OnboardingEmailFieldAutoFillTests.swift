// 1.60: the first-run wizards' email fields take AutoFill out of the path, as
// the Settings sign-in panel's do (`SignInEmailFieldAutoFillTests`).
//
// Both wizards in `OnboardingWizardView.swift` — `LegacyOnboardingWizardView`
// (the first-run wizard) and `OnboardingWizardView` (agent setup) — have an
// email-code form and a password form, each with an Email field. They were
// SwiftUI `TextField`s with `.onSubmit`; they are `NoAutoFillTextField`s now,
// which set no content type and no text completion, and Return still submits
// through the component's `onSubmit`. Insurance, like #714: it is not claimed
// to be the cause of any particular freeze.
//
// The views live in the app target, which this package cannot compile, so the
// checks read the sources.

#if os(macOS)
import Foundation
import XCTest
@testable import CLIPulseCore

final class OnboardingEmailFieldAutoFillTests: XCTestCase {

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

    /// The argument list of each call that starts with `prefix`, up to its
    /// matching parenthesis.
    private func calls(of prefix: String, in text: String) -> [String] {
        var out: [String] = []
        var from = text.startIndex
        while let found = text.range(of: prefix, range: from..<text.endIndex) {
            // Not part of a longer name (`NoAutoFillTextField(` for `TextField(`).
            if found.lowerBound > text.startIndex,
               let before = text[text.index(before: found.lowerBound)].unicodeScalars.first,
               CharacterSet.alphanumerics.contains(before) {
                from = found.upperBound
                continue
            }
            var depth = 1
            var index = found.upperBound
            while index < text.endIndex, depth > 0 {
                if text[index] == "(" { depth += 1 }
                if text[index] == ")" { depth -= 1 }
                index = text.index(after: index)
            }
            out.append(String(text[found.upperBound..<index]))
            from = index
        }
        return out
    }

    func testEveryWizardEmailFieldIsANoAutoFillTextField() throws {
        let wizard = try source("OnboardingWizardView.swift")
        let emailFields = calls(of: "NoAutoFillTextField(", in: wizard).filter { $0.contains("text: $email") }
        XCTAssertEqual(emailFields.count, 4, "two wizards, each with an email-code form and a password form")
        let swiftUIEmailFields = calls(of: "TextField(", in: wizard).filter {
            $0.contains("$email") || $0.contains("L10n.settings.email") || $0.contains("L10n.login.emailPlaceholder")
        }
        XCTAssertEqual(swiftUIEmailFields, [], "a SwiftUI TextField is back on a wizard email field")
    }

    /// Return still submits: each form's field calls the form's own action,
    /// as its `.onSubmit` did.
    func testReturnStillSubmitsEachForm() throws {
        let wizard = try source("OnboardingWizardView.swift")
        let emailFields = calls(of: "NoAutoFillTextField(", in: wizard).filter { $0.contains("text: $email") }
        func submitting(_ action: String) -> Int {
            emailFields.filter {
                $0.contains("onSubmit: \(action)\n") || $0.contains("onSubmit: \(action)\r")
                    || $0.contains("onSubmit: { \(action)() }")
            }.count
        }
        XCTAssertEqual(submitting("sendCode"), 2, "the email-code forms send the code on Return")
        XCTAssertEqual(submitting("signInWithPassword"), 2, "the password forms sign in on Return")
        for field in emailFields {
            XCTAssertTrue(field.contains("voiceOverLabel: L10n.settings.email"), "VoiceOver read the SwiftUI field's title")
            XCTAssertTrue(field.contains("singleLine: true"), "a SwiftUI field scrolls, it does not wrap")
            XCTAssertTrue(field.contains("fontSize: 13"), "a SwiftUI rounded-border field is 13 pt")
        }
    }

    /// The component's Return hook: Return (`insertNewline:`) runs
    /// `onSubmit` and is consumed; without one, the field behaves as before.
    func testTheComponentRunsOnSubmitOnReturn() throws {
        let file = try source("NoAutoFillFields.swift")
        let start = try XCTUnwrap(file.range(of: "struct NoAutoFillTextField"))
        let component = String(file[start.lowerBound...])
        XCTAssertTrue(component.contains("var onSubmit: (() -> Void)? = nil"))
        let hook = try XCTUnwrap(component.range(of: "doCommandBy commandSelector: Selector) -> Bool {"))
        let body = String(component[hook.upperBound...].prefix(400))
        XCTAssertTrue(body.contains("#selector(NSResponder.insertNewline(_:))"), body)
        XCTAssertTrue(body.contains("let onSubmit = parent.onSubmit"), body)
        XCTAssertTrue(body.contains("return false"), "no onSubmit: Return is left to the field")
        XCTAssertTrue(body.contains("onSubmit()"), body)
        XCTAssertTrue(body.contains("return true"), body)
        // The AutoFill suppression the fields are here for.
        XCTAssertTrue(component.contains("field.contentType = nil"))
        XCTAssertTrue(component.contains("field.isAutomaticTextCompletionEnabled = false"))
    }
}
#endif
