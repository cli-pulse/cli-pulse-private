#if os(macOS)
import XCTest
@testable import CLIPulseCore

/// v1.58 (P1-4) acceptance on a real Mac: the Codex projects CLI Pulse finds
/// in this Mac's logs are the ones CodexBar finds, for the same 30 days. The
/// order may differ (the two price some models differently); the set of names
/// may not.
///
/// Off unless asked for. It reads this Mac's own `~/.codex` and `~/.claude`
/// logs, which no test may do for whoever happens to run the suite, and it
/// compares them with CodexBar's answer saved to a file just before:
///
///     codexbar cost --provider codex --group-by project --format json --days 30 > /tmp/cb.json
///     CLIPULSE_LOCAL_PROJECTS_CHECK=/tmp/cb.json swift test --filter ProjectsLocalCheckTests
///
/// The test starts no process: CodexBar is run by whoever runs the check. The
/// scan writes its cache to a throwaway directory, never the app's. The output
/// is yes/no and counts only: no project name, path or figure leaves the test.
final class ProjectsLocalCheckTests: XCTestCase {
    func testCodexProjectNamesMatchCodexBarOnThisMac() throws {
        guard let file = ProcessInfo.processInfo.environment["CLIPULSE_LOCAL_PROJECTS_CHECK"], !file.isEmpty else {
            throw XCTSkip("set CLIPULSE_LOCAL_PROJECTS_CHECK=<codexbar cost --group-by project JSON> to read this Mac's logs")
        }
        let theirs = try Self.codexBarProjectNames(Data(contentsOf: URL(fileURLWithPath: file)))

        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-pulse-projects-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cache) }
        var options = CostUsageScanner.Options(cacheRoot: cache, daysToScan: 30)
        options.forceRescan = true
        let scan = CostUsageScanner.scan(options: options)
        let today = DayKey.string(from: Date())

        // Every provider's projects add up to its rows, over the window.
        for provider in ["Codex", "Claude"] {
            let days = ProviderUsageDays.fromScan(scan.entries, provider: provider, todayKey: today)
            let rows = ProjectUsageRanking.rows(scan.projects, provider: provider, basis: .eachOnce, todayKey: today)
            let tokens = rows.reduce(0) { $0 + $1.tokens }
            let cost = rows.reduce(0) { $0 + $1.cost }
            print(String(
                format: "LOCAL_PROJECTS_CHECK %@: %ld projects (%ld unknown); tokens add up: %@; cost adds up: %@",
                provider, rows.count, rows.filter(\.project.isUnknown).count,
                tokens == days.totalTokens ? "yes" : "no",
                abs(cost - days.totalCost) < 1e-6 ? "yes" : "no"))
            XCTAssertEqual(tokens, days.totalTokens, provider)
            XCTAssertEqual(cost, days.totalCost, accuracy: 1e-6, provider)
        }

        let ours = Set(
            ProjectUsageRanking.rows(scan.projects, provider: "Codex", basis: .eachOnce, todayKey: today)
                .map { $0.project.name ?? Self.unknown })
        let common = ours.intersection(theirs)
        print(String(
            format: "LOCAL_PROJECTS_CHECK Codex names equal to CodexBar's: %@ (CLI Pulse %ld, CodexBar %ld, both %ld, only CLI Pulse %ld, only CodexBar %ld)",
            ours == theirs ? "yes" : "no", ours.count, theirs.count, common.count,
            ours.subtracting(theirs).count, theirs.subtracting(ours).count))
        XCTAssertEqual(ours.count, theirs.count, "project counts differ")
        XCTAssertTrue(ours == theirs, "the Codex project names differ from CodexBar's (names not printed)")
    }

    /// Stands for an unknown project on both sides: CodexBar calls it
    /// "Unknown project", CLI Pulse "Unknown" in the reader's language.
    static let unknown = "\u{0}unknown"

    /// The project names in CodexBar's `cost --group-by project --format json`
    /// answer: an array of providers, each with `projects[].name`.
    static func codexBarProjectNames(_ data: Data) throws -> Set<String> {
        let object = try JSONSerialization.jsonObject(with: data)
        let providers = (object as? [[String: Any]]) ?? [(object as? [String: Any]) ?? [:]]
        guard let codex = providers.first(where: { ($0["provider"] as? String)?.lowercased() == "codex" }) else {
            XCTFail("CodexBar's answer has no Codex section")
            return []
        }
        let projects = codex["projects"] as? [[String: Any]] ?? []
        return Set(projects.compactMap { project -> String? in
            guard let name = project["name"] as? String else { return nil }
            return name == "Unknown project" && !(project["path"] is String) ? unknown : name
        })
    }

    /// The reader of CodexBar's answer, on a made-up one.
    func testCodexBarAnswerIsReadForNames() throws {
        let json = Data("""
            [{"provider":"codex","projects":[
              {"name":"demo-app","path":"/Users/sample/Projects/demo-app","totalCost":1.5},
              {"name":"Unknown project","totalCost":0.2}]},
             {"provider":"claude","projects":[{"name":"other","path":"/Users/sample/other"}]}]
            """.utf8)
        XCTAssertEqual(try Self.codexBarProjectNames(json), ["demo-app", Self.unknown])
    }
}
#endif
