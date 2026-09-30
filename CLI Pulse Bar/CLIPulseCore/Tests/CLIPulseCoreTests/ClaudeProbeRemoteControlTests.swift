#if os(macOS)
import XCTest
@testable import CLIPulseCore

/// The Claude `/usage` probe must not open a Claude Code Remote Control
/// session. A probe that did would leave an empty session in the user's
/// claude.ai and Claude app for every background refresh (CodexBar #3651).
final class ClaudeProbeRemoteControlTests: XCTestCase {

    private var args: [String] { ClaudeCLIPTYStrategy.probeLaunchArguments }

    /// The value that follows `--settings`, parsed the way Claude Code parses it.
    private func settingsPassed() throws -> [String: Any] {
        let index = try XCTUnwrap(
            args.firstIndex(of: "--settings"),
            "the probe must pass its own --settings"
        )
        let value = try XCTUnwrap(
            args.indices.contains(index + 1) ? args[index + 1] : nil,
            "--settings needs a value"
        )
        let json = try XCTUnwrap(value.data(using: .utf8))
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: json) as? [String: Any],
            "--settings must be a JSON object, or Claude Code rejects the launch"
        )
    }

    func test_probeTurnsRemoteControlOffForItself() throws {
        let settings = try settingsPassed()
        // `false`, not absent and not `true`: an absent key falls back to the
        // user's own setting, or the account default, which is what this guards against.
        XCTAssertEqual(settings["remoteControlAtStartup"] as? Bool, false)
    }

    func test_probeSettingsChangeNothingElse() throws {
        // A flag-scope setting overrides the user's for this process. Anything
        // beyond the one key would quietly change how their Claude Code behaves
        // inside the probe.
        XCTAssertEqual(Array(try settingsPassed().keys), ["remoteControlAtStartup"])
    }

    func test_existingProbeFlagsSurvive() {
        XCTAssertTrue(args.contains("--bare"))
        XCTAssertTrue(args.contains("--strict-mcp-config"))
        // `--allowed-tools` takes the empty string as its value; losing the
        // pair would hand the next flag to it as a tool list.
        let tools = args.firstIndex(of: "--allowed-tools")
        XCTAssertNotNil(tools)
        if let tools {
            XCTAssertEqual(args.indices.contains(tools + 1) ? args[tools + 1] : nil, "")
        }
    }

    /// The constant is only worth testing if it is what gets launched. A second
    /// hand-written argument list in `capturePTY` would pass every test above
    /// and still launch the old command line.
    func test_ptyCaptureLaunchesTheseArguments() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // CLIPulseCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // CLIPulseCore
            .appendingPathComponent("Sources/CLIPulseCore/Collectors/Claude/ClaudeCLIPTYStrategy.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let launches = text.components(separatedBy: "proc.arguments =").count - 1
        XCTAssertEqual(launches, 1, "one launch line, so one argument list")
        XCTAssertTrue(text.contains("proc.arguments = Self.probeLaunchArguments"))
    }
}
#endif
