import XCTest
@testable import CLIPulseCore

/// v1.55: the source-level half of "Strict privacy mode reads no other app's
/// secret on its own", for the wiring the behaviour tests cannot see.
///
/// `CookieResolverTests`, `ZedCollectorTests` and
/// `ClaudeHelperSessionKeyStrictModeTests` test each guard through its
/// injectable seam. What they cannot see is production code going around the
/// seam: the 17 cookie collectors calling an overload that brings its own
/// importer, the production entry point dropping `privacy:`, or another read
/// of the Companion's `claude_session.json`. Reverting any of those compiled
/// and broke no test before these checks.
final class StrictPrivacyModeReferenceTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // CLIPulseCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // CLIPulseCore
        .deletingLastPathComponent()   // CLI Pulse Bar
        .deletingLastPathComponent()   // repo root

    private static let appProjectSources = repoRoot.appendingPathComponent("CLI Pulse Bar")
    private static let helperSwiftSources = repoRoot.appendingPathComponent("HelperSwift/Sources")

    /// A `.swift` file with its `//` comments removed, so prose can name the
    /// calls freely.
    private struct SourceFile {
        let name: String
        let url: URL
        let text: String
    }

    private func productionFiles() throws -> [SourceFile] {
        var out: [SourceFile] = []
        for root in [Self.appProjectSources, Self.helperSwiftSources] {
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
                XCTFail("cannot list \(root.path)")
                continue
            }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let components = Set(url.pathComponents)
                if !components.isDisjoint(with: ["Tests", ".build", "DerivedData"]) { continue }
                let raw = try String(contentsOf: url, encoding: .utf8)
                let text = raw.components(separatedBy: "\n").map { line -> String in
                    guard let comment = line.range(of: "//") else { return line }
                    return String(line[..<comment.lowerBound])
                }.joined(separator: "\n")
                out.append(SourceFile(name: url.lastPathComponent, url: url, text: text))
            }
        }
        XCTAssertFalse(out.isEmpty)
        return out
    }

    /// The argument list of each call that starts with `prefix`, up to its
    /// matching parenthesis.
    private func calls(of prefix: String, in text: String) -> [Substring] {
        var out: [Substring] = []
        var searchFrom = text.startIndex
        while let start = text.range(of: prefix, range: searchFrom..<text.endIndex) {
            var depth = 1
            var index = start.upperBound
            while index < text.endIndex, depth > 0 {
                if text[index] == "(" { depth += 1 }
                if text[index] == ")" { depth -= 1 }
                index = text.index(after: index)
            }
            out.append(text[start.upperBound..<index])
            searchFrom = index
        }
        return out
    }

    // MARK: - CookieResolver

    func testEveryCookieCollectorCallsTheProductionEntryPoint() throws {
        // The production overload asks this process's Strict privacy mode.
        // An overload that brings its own importer decides it only from what
        // the caller passes, so no collector may call one.
        var productionCalls = 0
        for file in try productionFiles() where file.name != "CookieResolver.swift" {
            for arguments in calls(of: "CookieResolver.resolve(", in: file.text) {
                productionCalls += 1
                XCTAssertFalse(arguments.contains("importer:"),
                               "\(file.url.path): calls CookieResolver with its own importer")
                XCTAssertFalse(arguments.contains("browserImportAllowed:"),
                               "\(file.url.path): decides Strict privacy mode for CookieResolver")
                XCTAssertFalse(arguments.contains("privacy:"),
                               "\(file.url.path): passes its own PrivacySettings to CookieResolver")
            }
        }
        // A lower count means this scan stopped seeing them, not that they are gone.
        XCTAssertGreaterThanOrEqual(productionCalls, 17)
    }

    func testTheProductionEntryPointAsksThisProcesssSwitch() throws {
        let resolver = try XCTUnwrap(try productionFiles().first { $0.name == "CookieResolver.swift" })
        let text = resolver.text
        // The production overload is the one that names the platform importer.
        let entry = try XCTUnwrap(text.range(of: "importer: platformDefaultImporter,"))
        let tail = text[entry.upperBound...].prefix(200)
        XCTAssertTrue(tail.contains("privacy: .shared"),
                      "the production CookieResolver.resolve no longer passes privacy: .shared")
        XCTAssertEqual(text.components(separatedBy: "importer: platformDefaultImporter").count - 1, 1)
        // The privacy overload turns the switch into the import decision.
        XCTAssertTrue(text.contains("browserImportAllowed: !privacy.skipsOtherAppsSecretsOnItsOwn"))
        // No default: a caller that brings an importer must decide.
        XCTAssertFalse(text.contains("browserImportAllowed: Bool ="),
                       "browserImportAllowed has a default again, so dropping privacy: compiles silently")
        // The skip is noted, so the row can say it (`StrictPrivacyModeStatusTests`).
        XCTAssertTrue(text.contains("StrictPrivacySkipLog.note(.browserCookies)"))
    }

    // MARK: - the Companion's claude.ai cookie

    func testOnlyTheGuardedReadOpensTheCompanionsCookieFile() throws {
        var readers: [String] = []
        for file in try productionFiles() {
            let uses = file.text.components(separatedBy: "sessionKeyCandidatePaths").count - 1
            guard uses > 0 else { continue }
            if file.name == "ClaudeHelperContract.swift" {
                XCTAssertEqual(uses, 1, "ClaudeHelperContract should only define sessionKeyCandidatePaths")
                XCTAssertTrue(file.text.contains("public static var sessionKeyCandidatePaths"))
                continue
            }
            readers.append("\(file.name)×\(uses)")
        }
        XCTAssertEqual(readers, ["ClaudeWebStrategy.swift×1"],
                       "the Companion's claude_session.json is read outside findSessionKeyFromFile")

        let strategy = try XCTUnwrap(try productionFiles().first { $0.name == "ClaudeWebStrategy.swift" })
        let text = strategy.text
        let start = try XCTUnwrap(text.range(of: "static func findSessionKeyFromFile()"))
        let body = text[start.upperBound...].prefix(300)
        XCTAssertTrue(body.contains("strictPrivacyMode: strictPrivacyModeSkipsHelperSessionKey()"), String(body))
        XCTAssertTrue(body.contains("paths: ClaudeHelperContract.sessionKeyCandidatePaths"), String(body))
        XCTAssertTrue(text.contains("guard !strictPrivacyMode else { return nil }"))
    }

    // MARK: - the LAN agent's hello

    func testTheAppGivesTheLANAgentTheLocalScanAnswer() throws {
        // Without it the agent says no, which fails safe (no phone is offered
        // Remote Control); this pins the yes path.
        let app = try XCTUnwrap(try productionFiles().first { $0.name == "AppState.swift" })
        let start = try XCTUnwrap(app.text.range(of: "lanAgent.localScanAllowed = {"))
        let body = app.text[start.upperBound...].prefix(300)
        XCTAssertTrue(body.contains("LocalCollectionPolicy.allowsCollection("), String(body))
    }
}
