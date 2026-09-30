import XCTest
@testable import CLIPulseCore

/// v1.55: the source-level half of "Settings › Privacy's Claude keychain
/// switches hold in every process that reads the item".
///
/// The behaviour is tested in `HelperPrivacyInputsTests`. What those tests
/// cannot see is a read that never asks, or wiring in the two targets that have
/// no unit tests (the app and the LoginItem helper). The gap this closes is
/// exactly that shape: the collectors asked `PrivacySettings.shared`, and in the
/// helper that object was never told where the user's answer is.
final class ClaudeKeychainGateReferenceTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // CLIPulseCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // CLIPulseCore
        .deletingLastPathComponent()   // CLI Pulse Bar
        .deletingLastPathComponent()   // repo root

    private static let coreSources = repoRoot
        .appendingPathComponent("CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore")
    private static let helperSources = repoRoot
        .appendingPathComponent("CLI Pulse Bar/CLIPulseHelper")

    /// A `.swift` file, read for the checks below.
    private struct SourceFile {
        /// The file's name, e.g. `PrivacySettings.swift`.
        let name: String
        let url: URL
        /// Its lines, `//` comments removed so prose can name the calls freely.
        let lines: [String]

        func location(_ index: Int) -> String { "\(url.path):\(index + 1)" }
    }

    /// Every `.swift` file under `dir`.
    private func swiftFiles(under dir: URL) throws -> [SourceFile] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            XCTFail("cannot list \(dir.path)")
            return []
        }
        var out: [SourceFile] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let lines = text.components(separatedBy: "\n").map { line -> String in
                guard let comment = line.range(of: "//") else { return line }
                return String(line[..<comment.lowerBound])
            }
            out.append(SourceFile(name: url.lastPathComponent, url: url, lines: lines))
        }
        XCTAssertFalse(out.isEmpty, "no sources under \(dir.path)")
        return out
    }

    func testEveryBackgroundReadOfTheItemAsksTheProcessAwareSwitch() throws {
        var reads = 0
        let files = try swiftFiles(under: Self.coreSources) + swiftFiles(under: Self.helperSources)
        for file in files {
            for (index, line) in file.lines.enumerated()
            where line.contains("readKeychainCredentials(") && !line.contains("func readKeychainCredentials(") {
                reads += 1
                let window = file.lines[max(0, index - 3)...index].joined(separator: "\n")
                XCTAssertTrue(
                    window.contains("skipsClaudeKeychainOnItsOwn"),
                    "\(file.location(index)) reads Claude Code's keychain item without asking "
                        + "PrivacySettings.skipsClaudeKeychainOnItsOwn, so Strict privacy mode and "
                        + "\"Skip Claude Code keychain access\" would not hold there"
                )
            }
        }
        // The token resolver and the two rate-limit tier lookups. A lower count
        // means this scan stopped seeing them, not that they are gone.
        XCTAssertGreaterThanOrEqual(reads, 3)
    }

    func testNoCollectorAsksTheAppOnlySwitch() throws {
        // `skipClaudeKeychain` is this process's own stored switch. In the
        // LoginItem helper it is never written, so a collector asking it reads
        // "off" whatever the user chose.
        for file in try swiftFiles(under: Self.coreSources) where file.name != "PrivacySettings.swift" {
            for (index, line) in file.lines.enumerated()
            where line.range(of: #"PrivacySettings\.shared\.skipClaudeKeychain\b"#, options: .regularExpression) != nil {
                XCTFail("\(file.location(index)) asks the app-only switch; use skipsClaudeKeychainOnItsOwn")
            }
        }
    }

    func testOnlyOneFunctionOpensTheItem() throws {
        // Everything else goes through `readKeychainCredentials`, so the check
        // above covers every read.
        var openers: [(name: String, location: String)] = []
        let files = try swiftFiles(under: Self.coreSources) + swiftFiles(under: Self.helperSources)
        for file in files {
            for (index, line) in file.lines.enumerated() where line.contains("\"Claude Code-credentials\"") {
                openers.append((file.name, file.location(index)))
            }
        }
        XCTAssertEqual(openers.map { $0.name }, ["ClaudeSourceStrategy.swift"], "\(openers.map { $0.location })")
    }

    func testTheLoginItemFollowsTheAppsCopyBeforeItsDaemonStarts() throws {
        let delegate = try String(
            contentsOf: Self.helperSources.appendingPathComponent("HelperAppDelegate.swift"),
            encoding: .utf8
        )
        let follow = try XCTUnwrap(
            delegate.range(of: "PrivacySettings.shared.followAppCopy(in: UserDefaults(suiteName: HelperIPC.suiteName))"),
            "the helper no longer takes the switches from the app group"
        )
        let start = try XCTUnwrap(delegate.range(of: "daemon.start()"))
        XCTAssertLessThan(follow.lowerBound, start.lowerBound, "the first cycle would run on the helper's own defaults")
    }

    func testTheAppWritesTheCopyAtLaunch() throws {
        let app = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("CLI Pulse Bar/CLI Pulse Bar/CLIPulseBarApp.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            app.contains("PrivacySettings.shared.mirrorForHelpers(in: runtimeEnvironment)"),
            "the app no longer copies the switches for the helpers at launch"
        )
    }

    func testTheLoginItemTellsHelloItsCycleMayRead() throws {
        // `hello` reads ~/.codex/auth.json only when told the answer allows it
        // (`LocalSessionControlClient.hello(localScanAllowed:)`).
        let daemon = try String(
            contentsOf: Self.helperSources.appendingPathComponent("HelperDaemon.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(daemon.contains(".hello(localScanAllowed: true)"))
        XCTAssertFalse(daemon.contains("LocalSessionControlClient().hello()"))
    }
}
