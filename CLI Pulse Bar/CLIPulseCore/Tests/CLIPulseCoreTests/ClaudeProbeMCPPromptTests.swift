#if os(macOS)
import XCTest
@testable import CLIPulseCore

/// 1.59 probe hygiene for the Claude `/usage` PTY probe and the resolver.
///
/// 1. The probe never approves an MCP server. Up to 1.58 it answered "New MCP
///    server found" with Enter, which confirms that dialog's default, "Use
///    this and all future MCP servers".
/// 2. The three diagnostic files in `$TMPDIR` are written by DEBUG builds
///    only. Release builds wrote them for every user.
final class ClaudeProbeMCPPromptTests: XCTestCase {

    // MARK: - MCP

    func testNoAutoResponseTouchesAnMCPPrompt() {
        for (needle, _) in ClaudeCLIPTYStrategy.promptResponses {
            XCTAssertFalse(needle.lowercased().contains("mcp"),
                           "the probe must not answer an MCP prompt: \(needle)")
            XCTAssertFalse(ClaudeCLIPTYStrategy.mcpApprovalPromptVisible(needle.lowercased()),
                           "an auto-answered prompt overlaps the MCP dialog: \(needle)")
        }
    }

    /// The dialog as the probe sees it: ANSI stripped, lowercased.
    func testMCPApprovalDialogIsRecognised() {
        let dialog = """
        new mcp server found in .mcp.json: example-server
        ❯ 1. use this and all future mcp servers in this project
          2. use this mcp server
          3. continue without using this mcp server
        """
        XCTAssertTrue(ClaudeCLIPTYStrategy.mcpApprovalPromptVisible(dialog))
        XCTAssertTrue(ClaudeCLIPTYStrategy.mcpApprovalPromptVisible("new mcp server found"))
    }

    func testOrdinaryProbeScreensAreNotMistakenForIt() {
        for screen in [
            "quick safety check: is this a project you created or one you trust?",
            "current session\n12% used\nresets 5pm",
            "show plan usage limits",
            "/usage",
        ] {
            XCTAssertFalse(ClaudeCLIPTYStrategy.mcpApprovalPromptVisible(screen), screen)
        }
    }

    private func source(_ file: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // CLIPulseCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // CLIPulseCore
            .appendingPathComponent("Sources/CLIPulseCore/Collectors/Claude/\(file)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Recognising the dialog only helps if the capture loop stops on it
    /// before any key goes out: the prompt answers, `/usage` and `/exit`
    /// all end in an Enter, which would confirm the dialog's default.
    func testCaptureStopsAtTheDialogBeforeSendingAnyKey() throws {
        let text = try source("ClaudeCLIPTYStrategy.swift")
        let check = try XCTUnwrap(text.range(of: "if Self.mcpApprovalPromptVisible(normalized) {"),
                                  "capturePTY must check for the MCP dialog")
        let answers = try XCTUnwrap(text.range(of: "for prompt in Self.promptResponses"))
        let command = try XCTUnwrap(text.range(of: "Self.writeToPTY(primaryFD, subcommand + \"\\r\")"))
        XCTAssertLessThan(check.lowerBound, answers.lowerBound, "checked before answering prompts")
        XCTAssertLessThan(check.lowerBound, command.lowerBound, "checked before sending /usage")
        let exitWrite = try XCTUnwrap(text.range(of: "Self.writeToPTY(primaryFD, \"/exit\\r\")"))
        let guardLine = try XCTUnwrap(text.range(of: "if !stoppedAtMCPPrompt {"))
        XCTAssertLessThan(guardLine.lowerBound, exitWrite.lowerBound, "/exit is skipped after the dialog")
        XCTAssertEqual(text.components(separatedBy: "\"/exit\\r\"").count - 1, 1, "one /exit write")
    }

    // MARK: - DEBUG-only diagnostic files

    /// Every line that names one of the three `$TMPDIR` files sits inside an
    /// `#if DEBUG` branch, outside doc comments. Read from the source because
    /// a test target is itself a DEBUG build and cannot observe the release
    /// behaviour.
    func testDiagnosticFilesAreWrittenInDebugBuildsOnly() throws {
        let names = [
            "clipulse_claude_pty_raw.txt",
            "clipulse_claude_resolver.log",
            "clipulse_claude_fallback.log",
        ]
        var seen = Set<String>()
        for file in ["ClaudeCLIPTYStrategy.swift", "ClaudeSourceResolver.swift"] {
            var stack: [Bool] = []   // per open #if: is this branch DEBUG-only?
            for (number, raw) in try source(file).components(separatedBy: "\n").enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("#if ") {
                    stack.append(line == "#if DEBUG")
                } else if line.hasPrefix("#elseif") || line == "#else" {
                    if !stack.isEmpty { stack[stack.count - 1] = false }
                } else if line == "#endif" {
                    _ = stack.popLast()
                } else if !line.hasPrefix("//") {
                    for name in names where line.contains(name) {
                        seen.insert(name)
                        XCTAssertTrue(stack.contains(true),
                                      "\(file):\(number + 1) writes \(name) outside #if DEBUG")
                    }
                }
            }
        }
        XCTAssertEqual(seen, Set(names), "each file is still written somewhere (in DEBUG)")
    }

    /// The resolver's file writer is reached only through `log`, so a
    /// DEBUG-only writer is not enough on its own: `log` must not call it
    /// outside DEBUG either. Its body is pinned here.
    func testResolverLogIsDebugOnly() throws {
        let text = try source("ClaudeSourceResolver.swift")
        let start = try XCTUnwrap(text.range(of: "private static func log(_ message: @autoclosure () -> String) {"))
        let body = text[start.upperBound...].prefix(while: { $0 != "}" })
        let lines = body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        XCTAssertEqual(lines.first, "#if DEBUG")
        XCTAssertEqual(lines.last, "#endif")
    }
}
#endif
