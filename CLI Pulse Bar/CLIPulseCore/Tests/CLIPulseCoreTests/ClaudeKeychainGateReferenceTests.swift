import XCTest
@testable import CLIPulseCore

/// v1.55: the source-level half of "Settings › Privacy's Claude keychain
/// switches hold in every process that reads the item".
///
/// The behaviour is tested in `HelperPrivacyInputsTests`, including that
/// `ClaudeCredentials.readKeychainCredentialsIfAllowed` never calls its reader
/// under a switch. What those tests cannot see is a read that goes around that
/// guard, or wiring in the targets that have no unit tests (the app and the
/// LoginItem helper). The gap this closes is exactly that shape: the
/// collectors asked `PrivacySettings.shared`, and in the helper that object was
/// never told where the user's answer is.
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
    /// Every target the Xcode project builds: the app, the LoginItem helper,
    /// iOS, Watch, Widgets, and CLIPulseCore (tests left out).
    private static let appProjectSources = repoRoot
        .appendingPathComponent("CLI Pulse Bar")
    /// The bundled Swift helper (Developer ID only).
    private static let helperSwiftSources = repoRoot
        .appendingPathComponent("HelperSwift/Sources")

    /// A `.swift` file, read for the checks below.
    private struct SourceFile {
        /// The file's name, e.g. `PrivacySettings.swift`.
        let name: String
        let url: URL
        /// Its lines, `//` comments removed so prose can name the calls freely.
        let lines: [String]

        func location(_ index: Int) -> String { "\(url.path):\(index + 1)" }
    }

    /// Every `.swift` file under `dir`, leaving out tests and build output.
    private func swiftFiles(under dir: URL) throws -> [SourceFile] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            XCTFail("cannot list \(dir.path)")
            return []
        }
        var out: [SourceFile] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let components = Set(url.pathComponents)
            if !components.isDisjoint(with: ["Tests", ".build", "DerivedData"]) { continue }
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

    /// All production Swift in the repo that could read the item.
    private func productionFiles() throws -> [SourceFile] {
        try swiftFiles(under: Self.appProjectSources) + swiftFiles(under: Self.helperSwiftSources)
    }

    func testOnlyTheGuardAndTheConnectButtonCallTheRawRead() throws {
        // `readKeychainCredentials(` opens the item with no question asked.
        // Everything that reads it on its own must go through
        // `readKeychainCredentialsIfAllowed`, which asks the switches; only the
        // Settings "Connect Claude Code" button, a read the user just asked
        // for, calls it directly.
        var rawCallers: [String: Int] = [:]
        var rawLocations: [String] = []
        var guardedCalls = 0
        for file in try productionFiles() {
            for (index, line) in file.lines.enumerated() {
                if line.contains("readKeychainCredentialsIfAllowed("),
                   !line.contains("func readKeychainCredentialsIfAllowed(") {
                    guardedCalls += 1
                }
                guard line.contains("readKeychainCredentials("),
                      !line.contains("func readKeychainCredentials(")
                else { continue }
                rawCallers[file.name, default: 0] += 1
                rawLocations.append(file.location(index))
                if file.name == "ProviderConfigEditor.swift" {
                    let window = file.lines[index...min(file.lines.count - 1, index + 3)].joined(separator: "\n")
                    XCTAssertTrue(
                        window.contains("bypassCooldown: true"),
                        "\(file.location(index)): the Connect button's read is the user-initiated one"
                    )
                }
            }
        }
        XCTAssertEqual(
            rawCallers,
            ["ClaudeSourceStrategy.swift": 1, "ProviderConfigEditor.swift": 1],
            "only the guard's own reader and the Connect button may open Claude Code's keychain "
                + "item without asking Settings › Privacy's switches: \(rawLocations)"
        )
        // The token resolver and the two rate-limit tier lookups. A lower count
        // means this scan stopped seeing them, not that they are gone.
        XCTAssertGreaterThanOrEqual(guardedCalls, 3)
    }

    func testTheGuardAsksTheProcessAwareSwitchBeforeItReads() throws {
        let strategy = try XCTUnwrap(
            try swiftFiles(under: Self.coreSources).first { $0.name == "ClaudeSourceStrategy.swift" }
        )
        let text = strategy.lines.joined(separator: "\n")
        let start = try XCTUnwrap(text.range(of: "func readKeychainCredentialsIfAllowed("))
        let body = text[start.lowerBound...].prefix(600)
        let ask = try XCTUnwrap(body.range(of: "guard !privacy.skipsClaudeKeychainOnItsOwn else { return nil }"))
        let read = try XCTUnwrap(body.range(of: "return reader()"))
        XCTAssertLessThan(ask.lowerBound, read.lowerBound)
        // Its default reader is the raw read, the one caller counted above.
        XCTAssertTrue(body.contains("reader: () -> Creds? = { ClaudeCredentials.readKeychainCredentials() }"))
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
        // above covers every read. The bundled Swift helper spells the name too,
        // for a quota fetcher nothing in production runs (next test).
        var openers: [String] = []
        var locations: [String] = []
        for file in try productionFiles() {
            for (index, line) in file.lines.enumerated() where line.contains("\"Claude Code-credentials\"") {
                openers.append(file.name)
                locations.append(file.location(index))
            }
        }
        XCTAssertEqual(openers.sorted(), ["ClaudeQuotaFetcher.swift", "ClaudeSourceStrategy.swift"], "\(locations)")
    }

    func testTheBundledSwiftHelperNeverRunsItsKeychainQuotaFetcher() throws {
        // `ClaudeQuotaFetcher` reads the item through `KeychainReader`
        // (`security find-generic-password`) and asks no switch: the bundled
        // helper must not open the app group, so it cannot read the app's copy.
        // It is safe only while nothing in production constructs it, or the
        // `SystemCollector` that does. A caller added later fails here, and has
        // to bring the switches with it.
        let patterns: [(pattern: String, allowedIn: Set<String>)] = [
            (#"\bSystemCollector\("#, []),
            (#"\bClaudeQuotaFetcher\("#, ["SystemCollector.swift"]),
            (#"\bkeychainServiceName\b"#, ["ClaudeQuotaFetcher.swift"]),
        ]
        for file in try swiftFiles(under: Self.helperSwiftSources) {
            for (index, line) in file.lines.enumerated() {
                for (pattern, allowedIn) in patterns
                where !allowedIn.contains(file.name)
                    && line.range(of: pattern, options: .regularExpression) != nil {
                    XCTFail("\(file.location(index)) reaches Claude Code's keychain item through the bundled helper's quota fetcher, which asks no switch")
                }
            }
        }
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

    func testTheLoginItemReportsWhenTheAppChangesASwitchOrAsks() throws {
        // Without this the report waited for the helper's next collecting
        // cycle (a sync interval), and the app's launch-time request, which
        // replaces a report an earlier helper left, went unanswered.
        let delegate = try String(
            contentsOf: Self.helperSources.appendingPathComponent("HelperAppDelegate.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(delegate.contains("daemon.reportClaudeKeychainAccess(announce: true)"), "no report at launch")
        XCTAssertTrue(delegate.contains("daemon?.reportClaudeKeychainAccess(announce: true)"), "no report on request")
        XCTAssertTrue(delegate.contains("HelperInputs.didChangeNotificationName"), "a switch change is not observed")
        XCTAssertTrue(delegate.contains("HelperPrivacyInputs.reportRequestNotificationName"), "the app's request is not observed")

        let daemon = try String(
            contentsOf: Self.helperSources.appendingPathComponent("HelperDaemon.swift"),
            encoding: .utf8
        )
        let collect = try XCTUnwrap(daemon.range(of: "private func collectProviderQuotas() async -> ProviderQuotaCollection {"))
        XCTAssertTrue(
            daemon[collect.upperBound...].prefix(200).contains("reportClaudeKeychainAccess()"),
            "a collecting cycle no longer reports"
        )
        XCTAssertTrue(daemon.contains("HelperInputs.postDidReport()"))

        let settings = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("CLI Pulse Bar/CLI Pulse Bar/PrivacySettingsSection.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(settings.contains(".publisher(for: HelperPrivacyInputs.didReportNotificationName)"),
                      "Settings does not re-read the report when the helper answers")
    }

    func testTheAppWritesTheCopyAtLaunch() throws {
        let app = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("CLI Pulse Bar/CLI Pulse Bar/CLIPulseBarApp.swift"),
            encoding: .utf8
        )
        let mirror = try XCTUnwrap(
            app.range(of: "PrivacySettings.shared.mirrorForHelpers(in: runtimeEnvironment)"),
            "the app no longer copies the switches for the helpers at launch"
        )
        // After the Developer ID migration, which carries the `privacy.` keys
        // over: before it, both switches would be copied as off.
        let migration = try XCTUnwrap(app.range(of: "UnsandboxedDataMigration.runIfNeeded()"))
        XCTAssertLessThan(migration.lowerBound, mirror.lowerBound)
        // Before AppState, whose consent copy wakes the helper.
        let appState = try XCTUnwrap(app.range(of: "AppState(runtimeEnvironment: runtimeEnvironment)"))
        XCTAssertLessThan(mirror.lowerBound, appState.lowerBound)
    }

    func testTheLoginItemTellsHelloItsCycleMayRead() throws {
        // `hello` reads ~/.codex/auth.json only when told the answer allows it
        // (`LocalSessionControlClient.hello(localScanAllowed:)`). The helper
        // says what `HelperCycleRunner` asked just before the heartbeat step
        // (`HelperCycleRunnerTests.testEachUploadStepIsHandedTheQuestionThatAllowedIt`),
        // not a constant, and calls `hello` nowhere else.
        let daemon = try String(
            contentsOf: Self.helperSources.appendingPathComponent("HelperDaemon.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(daemon.contains(".hello(localScanAllowed: cycle.reads)"))
        XCTAssertFalse(daemon.contains("localScanAllowed: true"), "a literal yes that no question gave")
        XCTAssertFalse(daemon.contains("LocalSessionControlClient().hello()"))
        XCTAssertEqual(daemon.components(separatedBy: ".hello(").count - 1, 1, "hello is called outside the heartbeat step")
        // The heartbeat is reached only as an upload step, with its question.
        XCTAssertEqual(daemon.components(separatedBy: "self.sendHeartbeat(").count - 1, 1)
        XCTAssertTrue(daemon.contains("try await self.sendHeartbeat(collection, config: config, cycle: cycle)"))
    }
}
