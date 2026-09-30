#if os(macOS)
import XCTest
@testable import CLIPulseCore

/// A Claude Code transcript belongs to the project directory directly under
/// the projects root, however deep it sits. Subagents write to
/// `<project>/<session>/subagents/…` and workflow runs to
/// `…/subagents/workflows/<run>/…`; naming the project after the file's own
/// folder showed "subagents" or a run id instead of the project.
final class ClaudeProjectAttributionTests: XCTestCase {

    private var tmp: URL!
    private var projects: URL!
    private var cache: URL!

    /// `/Users/alice/code/my-app`, as Claude Code files it.
    private let appDir = "-Users-alice-code-my-app"
    private let appCwd = "/Users/alice/code/my-app"
    private let session = "0b7c2f7e-1111-4c2a-9d0e-7a1b2c3d4e5f"

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-project-attr-\(UUID().uuidString)", isDirectory: true)
        projects = tmp.appendingPathComponent("projects", isDirectory: true)
        cache = tmp.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - Fixtures

    /// One transcript at `relativePath` below the projects root. `cwd: nil`
    /// writes lines without one, which Claude Code does for summary and
    /// snapshot lines.
    @discardableResult
    private func writeTranscript(
        _ relativePath: String,
        cwd: String?,
        mtime: Date = Date()
    ) throws -> URL {
        let url = projects.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let ts = iso.string(from: mtime)
        var lines = [#"{"type":"summary","summary":"fixture","leafUuid":"x"}"#]
        let cwdField = cwd.map { #","cwd":"\#($0)""# } ?? ""
        lines.append(
            #"{"type":"user","timestamp":"\#(ts)"\#(cwdField),"message":{"role":"user","content":"hi"}}"#)
        lines.append(
            #"{"type":"assistant","timestamp":"\#(ts)","requestId":"req-\#(UUID().uuidString)","message":{"id":"msg-\#(UUID().uuidString)","model":"claude-sonnet-4-5","usage":{"input_tokens":200,"output_tokens":100}}\#(cwdField)}"#)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        return url
    }

    private func attribution(_ url: URL) throws -> ClaudeProjectAttribution {
        try XCTUnwrap(CostUsageScanner.claudeProjectAttribution(transcript: url, projectsRoot: projects))
    }

    private func scanCandidates() -> [CostUsageScanResult.ActiveSessionCandidate] {
        let options = CostUsageScanner.Options(
            codexSessionsRoot: tmp.appendingPathComponent("no-codex", isDirectory: true),
            claudeProjectsRoots: [projects],
            cacheRoot: cache,
            daysToScan: 7
        )
        return CostUsageScanner.scan(options: options).activeSessionCandidates
            .filter { $0.provider == "Claude" }
    }

    // MARK: - The two subagent layouts, end to end

    func test_subagentTranscript_isNamedAfterTheProject_notItsFolder() throws {
        try writeTranscript("\(appDir)/\(session)/subagents/agent-a1.jsonl", cwd: appCwd)
        let candidate = try XCTUnwrap(scanCandidates().first)
        XCTAssertEqual(candidate.projectName, "my-app")
        XCTAssertNotEqual(candidate.projectName, "subagents")
        XCTAssertEqual(candidate.projectRoot, appCwd)
    }

    func test_workflowSubagentTranscript_isNamedAfterTheProject_notTheRunId() throws {
        try writeTranscript(
            "\(appDir)/\(session)/subagents/workflows/wf-7f3a/agent-b2.jsonl", cwd: appCwd)
        let candidate = try XCTUnwrap(scanCandidates().first)
        XCTAssertEqual(candidate.projectName, "my-app")
        XCTAssertNotEqual(candidate.projectName, "wf-7f3a")
    }

    func test_sessionAndItsSubagents_shareOneProject() throws {
        try writeTranscript("\(appDir)/\(session).jsonl", cwd: appCwd)
        try writeTranscript("\(appDir)/\(session)/subagents/agent-a1.jsonl", cwd: appCwd)
        try writeTranscript(
            "\(appDir)/\(session)/subagents/workflows/wf-7f3a/agent-b2.jsonl", cwd: appCwd)
        let names = Set(scanCandidates().map(\.projectName))
        XCTAssertEqual(names, ["my-app"])
    }

    // MARK: - Where the label comes from

    func test_cwdBelowTheProject_namesTheProject_notTheSubfolder() throws {
        // A subagent started after the session moved into a subfolder.
        let url = try writeTranscript(
            "\(appDir)/\(session)/subagents/agent-a1.jsonl", cwd: appCwd + "/web/src")
        let found = try attribution(url)
        XCTAssertEqual(found.label, "my-app")
        XCTAssertEqual(found.root, appCwd)
    }

    func test_subagentWithoutCwd_borrowsItsSessionsCwd() throws {
        try writeTranscript("\(appDir)/\(session).jsonl", cwd: appCwd)
        let url = try writeTranscript("\(appDir)/\(session)/subagents/agent-a1.jsonl", cwd: nil)
        XCTAssertEqual(try attribution(url).label, "my-app")
    }

    func test_subagentThatRanElsewhere_isStillFiledUnderItsSession() throws {
        // e.g. a subagent working in a separate worktree.
        try writeTranscript("\(appDir)/\(session).jsonl", cwd: appCwd)
        let url = try writeTranscript(
            "\(appDir)/\(session)/subagents/agent-a1.jsonl", cwd: "/Users/alice/wt/fix-login")
        let found = try attribution(url)
        XCTAssertEqual(found.label, "my-app")
        XCTAssertNotEqual(found.label, "fix-login")
    }

    func test_noCwdAnywhere_fallsBackToTheDecodedDirectory() throws {
        let url = try writeTranscript("\(appDir)/\(session)/subagents/agent-a1.jsonl", cwd: nil)
        let found = try attribution(url)
        XCTAssertEqual(found.directory, appDir)
        XCTAssertNil(found.root)
        // Lossy, and known to be: the decoder cannot tell `/` from `-`.
        XCTAssertEqual(found.label, "code-my-app")
    }

    func test_cwdKeepsWhatTheDirectoryNameLost() throws {
        // Space and hyphen both became `-`; the recorded path still has them.
        let cwd = "/Users/alice/Documents/cli pulse"
        let dir = "-Users-alice-Documents-cli-pulse"
        let url = try writeTranscript("\(dir)/\(session).jsonl", cwd: cwd)
        XCTAssertEqual(try attribution(url).label, "cli pulse")
        XCTAssertEqual(CostUsageScanner.humanReadableClaudeProject(encodedDir: dir), "Documents-cli-pulse")
    }

    func test_topLevelTranscript_withoutCwd_keepsItsPreviousLabel() throws {
        let url = try writeTranscript("-Users-jason-cli-pulse/\(session).jsonl", cwd: nil)
        XCTAssertEqual(try attribution(url).label, "cli-pulse")
    }

    func test_fileDirectlyInTheRoot_isNotAttributed() throws {
        let url = try writeTranscript("stray.jsonl", cwd: appCwd)
        XCTAssertNil(CostUsageScanner.claudeProjectAttribution(transcript: url, projectsRoot: projects))
    }

    // MARK: - Reading cwd

    func test_cwdIsReadFromTopLevelOnly() throws {
        let url = projects.appendingPathComponent("\(appDir)/\(session).jsonl")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A `cwd` nested inside message content is data, not the session's.
        try (#"{"type":"user","message":{"cwd":"/Users/mallory/elsewhere"}}"# + "\n")
            .write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(CostUsageScanner.readClaudeTranscriptCwd(fileURL: url))
    }

    func test_cwdPastTheReadLimit_isNotRead() throws {
        let url = projects.appendingPathComponent("\(appDir)/\(session).jsonl")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let filler = String(repeating: "x", count: CostUsageScanner.claudeCwdReadLimit)
        let body = #"{"type":"summary","summary":"\#(filler)"}"# + "\n"
            + #"{"type":"user","cwd":"\#(appCwd)"}"# + "\n"
        try body.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(CostUsageScanner.readClaudeTranscriptCwd(fileURL: url))
    }

    func test_lineCutByTheReadLimit_isNotParsed() throws {
        let url = projects.appendingPathComponent("\(appDir)/\(session).jsonl")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // The cwd line starts inside the limit and ends past it.
        let head = #"{"type":"user","cwd":"\#(appCwd)","pad":""#
        let pad = String(repeating: "y", count: CostUsageScanner.claudeCwdReadLimit)
        try (head + pad + #""}"# + "\n").write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(CostUsageScanner.readClaudeTranscriptCwd(fileURL: url))
    }

    func test_cwdWithinTheReadLimit_isRead() throws {
        let url = try writeTranscript("\(appDir)/\(session).jsonl", cwd: appCwd)
        XCTAssertEqual(CostUsageScanner.readClaudeTranscriptCwd(fileURL: url), appCwd)
    }

    // MARK: - Claude Code's directory naming
    //
    // Expected values produced by running Claude Code 2.1.266's own naming
    // function (`replace(/[^a-zA-Z0-9]/g,"-")`, 200-unit cap, base-36 hash) in
    // Node on the same inputs.

    func test_directoryName_replacesEverythingButAsciiLettersAndDigits() {
        XCTAssertEqual(
            CostUsageScanner.claudeProjectDirectoryName(forPath: "/Users/jason/Documents/cli pulse"),
            "-Users-jason-Documents-cli-pulse")
        XCTAssertEqual(
            CostUsageScanner.claudeProjectDirectoryName(forPath: "/Users/alice/.config"),
            "-Users-alice--config")
    }

    func test_directoryName_countsUTF16Units_likeJavaScript() {
        // 项 and 目 are one unit each, the space one, 🚀 two.
        XCTAssertEqual(
            CostUsageScanner.claudeProjectDirectoryName(forPath: "/Users/alice/项目 🚀"),
            "-Users-alice------")
    }

    func test_directoryName_longPathIsCutAndHashed() {
        let long = "/Users/alice/" + String(repeating: "very-long-folder-name/", count: 12) + "项目 🚀"
        XCTAssertEqual(
            CostUsageScanner.claudeProjectDirectoryName(forPath: long),
            "-Users-alice-very-long-folder-name-very-long-folder-name-very-long-folder-name-"
                + "very-long-folder-name-very-long-folder-name-very-long-folder-name-very-long-folder-name-"
                + "very-long-folder-name-very-long-f-3pakff")
    }

    func test_longProjectPath_stillResolvesFromCwd() throws {
        let cwd = "/Users/alice/" + String(repeating: "very-long-folder-name/", count: 12) + "app"
        let dir = CostUsageScanner.claudeProjectDirectoryName(forPath: cwd)
        let url = try writeTranscript("\(dir)/\(session)/subagents/agent-a1.jsonl", cwd: cwd)
        XCTAssertEqual(try attribution(url).label, "app")
    }
}
#endif
