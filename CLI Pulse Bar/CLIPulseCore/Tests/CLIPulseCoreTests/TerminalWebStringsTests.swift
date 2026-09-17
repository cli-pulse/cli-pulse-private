// The in-app terminal's screen-reader strings: the native side injects them,
// index.html hands them to xterm.js before `term.open()` reads them.
//
// The page logic runs for real here, in JavaScriptCore against the vendored
// xterm.js, rather than being grepped for. The two web view hosts are pinned
// as source guards: RemoteTerminalView is iOS-only and CI runs no iOS tests.
//
// Asserted in ja: English is xterm's own default, so an English assertion
// passes even when nothing is injected.
#if canImport(JavaScriptCore)
import JavaScriptCore
import XCTest
@testable import CLIPulseCore

final class TerminalWebStringsTests: XCTestCase {
    private var savedLocaleOverride: String?

    override func setUp() {
        super.setUp()
        savedLocaleOverride = LocaleOverrideStore.shared.override
        LocaleOverrideStore.shared.set("ja")
    }

    override func tearDown() {
        LocaleOverrideStore.shared.set(savedLocaleOverride)
        super.tearDown()
    }

    private func coreSource(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)   // …/Tests/CLIPulseCoreTests/<this>
            .deletingLastPathComponent()             // …/Tests/CLIPulseCoreTests
            .deletingLastPathComponent()             // …/Tests
            .deletingLastPathComponent()             // …/CLIPulseCore
        return try String(contentsOf: root.appending(path: "Sources/CLIPulseCore/\(name)"), encoding: .utf8)
    }

    /// A browser-less global scope: xterm.js only touches `navigator` at load.
    private func makeContext() -> (JSContext, () -> String?) {
        let context = JSContext()!
        var error: String?
        context.exceptionHandler = { _, exception in
            error = exception?.toString()
        }
        context.evaluateScript("var window = this; var navigator = { userAgent: '', platform: '' };")
        return (context, { error })
    }

    func test_userScript_isValidJavaScript_carryingTheLocalizedStrings() {
        let (context, error) = makeContext()
        context.evaluateScript(TerminalWebStrings.userScriptSource())
        XCTAssertNil(error())
        XCTAssertEqual(context.evaluateScript("window.TERMINAL_STRINGS.promptLabel").toString(), "ターミナル入力")
        XCTAssertEqual(context.evaluateScript("window.TERMINAL_STRINGS.tooMuchOutput").toString(),
                       L10n.terminal.tooMuchOutput)
    }

    /// The page's own block, run against the vendored xterm.js: the injected
    /// strings must land in `Terminal.strings`, which `term.open()` reads for
    /// the input's aria-label — so the block must also come before `open()`.
    func test_page_handsTheInjectedStringsToXterm_beforeOpeningTheTerminal() throws {
        let page = try coreSource("Resources/Terminal/index.html")
        let start = try XCTUnwrap(page.range(of: "// <terminal-strings>"), "marker missing from index.html")
        let end = try XCTUnwrap(page.range(of: "// </terminal-strings>"), "marker missing from index.html")
        let open = try XCTUnwrap(page.range(of: "term.open(root)"))
        XCTAssertLessThan(end.upperBound, open.lowerBound,
                          "xterm reads promptLabel inside term.open(); strings set after it never reach the aria-label")
        let block = String(page[start.upperBound..<end.lowerBound])

        let (context, error) = makeContext()
        context.evaluateScript(TerminalWebStrings.userScriptSource())
        context.evaluateScript(try coreSource("Resources/Terminal/xterm.js"))
        XCTAssertNil(error(), "vendored xterm.js failed to load")
        XCTAssertEqual(context.evaluateScript("Terminal.strings.promptLabel").toString(), "Terminal input",
                       "precondition: xterm's default is English")

        context.evaluateScript(block)
        XCTAssertNil(error())
        XCTAssertEqual(context.evaluateScript("Terminal.strings.promptLabel").toString(), "ターミナル入力")
        XCTAssertEqual(context.evaluateScript("Terminal.strings.tooMuchOutput").toString(),
                       L10n.terminal.tooMuchOutput)
        XCTAssertNotEqual(L10n.terminal.tooMuchOutput,
                          "Too much output to announce, navigate to rows manually to read")
    }

    /// Without an injection (a preview, or a host that forgot) the page must
    /// still load and keep xterm's defaults rather than setting "undefined".
    func test_page_keepsXtermDefaults_whenNothingIsInjected() throws {
        let page = try coreSource("Resources/Terminal/index.html")
        let start = try XCTUnwrap(page.range(of: "// <terminal-strings>"))
        let end = try XCTUnwrap(page.range(of: "// </terminal-strings>"))
        let (context, error) = makeContext()
        context.evaluateScript(try coreSource("Resources/Terminal/xterm.js"))
        context.evaluateScript(String(page[start.upperBound..<end.lowerBound]))
        XCTAssertNil(error())
        XCTAssertEqual(context.evaluateScript("Terminal.strings.promptLabel").toString(), "Terminal input")
    }

    /// Both hosts must inject at document start — the page reads the strings
    /// once, while it loads. The iPhone host is iOS-only, so this is a source guard.
    func test_bothWebViewHostsInjectTheStrings_atDocumentStart() throws {
        for host in ["TerminalView.swift", "RemoteTerminalView.swift"] {
            let src = try coreSource(host)
            let call = try XCTUnwrap(src.range(of: "source: TerminalWebStrings.userScriptSource(),"),
                                     "\(host) no longer injects the terminal's localized strings")
            let rest = src[call.upperBound...].prefix(80)
            XCTAssertTrue(rest.contains("injectionTime: .atDocumentStart"),
                          "\(host) injects the strings after the page has already read them")
        }
    }
}
#endif
