// Each line of the Codex note is held to the behaviour it describes, in both
// directions:
//
// * a line in `Reason.shipped` whose change is missing fails here, so the note
//   never tells someone about a change their build does not have;
// * a change that lands without its line fails here too, so the note cannot
//   stay silent about the change people will notice most.
//
// When one of these fails in a pull request that changes how Codex is counted
// or priced, the fix is in `CodexEstimateChangeNote.Reason.shipped`: add the
// reason (its text is already written and translated), or take it out.
//
// macOS-gated: they run the real scanner and price table, which are macOS-only.

#if os(macOS)
import XCTest
@testable import CLIPulseCore

final class CodexEstimateChangeTripwireTests: XCTestCase {

    private typealias Reason = CodexEstimateChangeNote.Reason

    // MARK: - Cached input counted once

    func testTheCachedInputLineMatchesTheArchive() {
        let row = CostUsageScanResult.DailyEntry(
            date: "2026-09-20", provider: "Codex", model: "gpt-5.5",
            inputTokens: 1_000, cachedTokens: 800, outputTokens: 50, costUSD: 1)
        var archive = DailyUsageArchive()
        archive.mergeScanEntries([DailyUsageArchiveManager.scanEntry(row)])
        let tokens = archive.days["2026-09-20"]?.tokens
        XCTAssertTrue(tokens == 1_050 || tokens == 1_850, "fixture no longer understood: \(String(describing: tokens))")

        XCTAssertEqual(Reason.shipped.contains(.cachedInputCountedOnce), tokens == 1_050,
                       "the note's cached-input line must be shown exactly when the archive counts it once")
    }

    // MARK: - Subagent sessions

    /// A parent rollout and one subagent rollout, shaped like Codex's own: the
    /// child's `session_meta` names the parent's session, and its events are
    /// its own (stamped after its `session_meta`, and its first cumulative
    /// total is the request itself), so any rule that counts subagents counts
    /// all of it.
    func testTheSubagentLineMatchesTheScanner() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-note-subagent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let sessions = tmp.appendingPathComponent("sessions", isDirectory: true)

        let now = Date()
        let dayFormatter = ISO8601DateFormatter()
        dayFormatter.formatOptions = [.withFullDate]
        dayFormatter.timeZone = .current
        let dir = dayFormatter.string(from: now).split(separator: "-")
            .reduce(sessions) { $0.appendingPathComponent(String($1)) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        func stamp(_ secondsAgo: TimeInterval) -> String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.string(from: now.addingTimeInterval(-secondsAgo))
        }
        func tokenCount(_ at: String, input: Int, output: Int) -> String {
            let usage = #"{"input_tokens":\#(input),"cached_input_tokens":0,"output_tokens":\#(output)}"#
            return #"{"type":"event_msg","timestamp":"\#(at)","payload":{"type":"token_count","info":{"total_token_usage":\#(usage),"last_token_usage":\#(usage)}}}"#
        }
        let parent = [
            #"{"type":"session_meta","timestamp":"\#(stamp(600))","payload":{"id":"note-parent","timestamp":"\#(stamp(600))","cwd":"/tmp/p"}}"#,
            #"{"type":"turn_context","timestamp":"\#(stamp(590))","payload":{"model":"gpt-5"}}"#,
            tokenCount(stamp(580), input: 1_000, output: 100),
        ]
        let child = [
            #"{"type":"session_meta","timestamp":"\#(stamp(300))","payload":{"id":"note-child","session_id":"note-parent","parent_thread_id":"note-parent","source":{"subagent":{"other":"review"}},"timestamp":"\#(stamp(300))","cwd":"/tmp/p"}}"#,
            #"{"type":"turn_context","timestamp":"\#(stamp(290))","payload":{"model":"gpt-5"}}"#,
            tokenCount(stamp(280), input: 300, output: 30),
        ]
        try (parent.joined(separator: "\n") + "\n")
            .write(to: dir.appendingPathComponent("rollout-a-note-parent.jsonl"), atomically: true, encoding: .utf8)
        try (child.joined(separator: "\n") + "\n")
            .write(to: dir.appendingPathComponent("rollout-b-note-child.jsonl"), atomically: true, encoding: .utf8)

        var options = CostUsageScanner.Options(codexSessionsRoot: sessions, claudeProjectsRoots: [],
                                               cacheRoot: tmp.appendingPathComponent("cache"), daysToScan: 7)
        options.refreshMinIntervalSeconds = 0
        let input = CostUsageScanner.scan(options: options).entries
            .filter { $0.provider == "Codex" }
            .reduce(0) { $0 + $1.inputTokens }

        let counted: Bool
        switch input {
        case 1_300: counted = true
        case 1_000, 300: counted = false   // one of the two files dropped
        default:
            return XCTFail("fixture no longer understood: Codex input \(input)")
        }
        XCTAssertEqual(Reason.shipped.contains(.subagentSessionsCounted), counted,
                       counted
                       ? "the scanner now counts subagent sessions: add .subagentSessionsCounted to Reason.shipped"
                       : "the note says subagent sessions are counted, and the scanner drops them")
    }

    // MARK: - Subagents and forks counted by simplified rules

    /// A conversation forked from another whose first event repeats the
    /// parent's last snapshot (CodexBar's direct-fork shape). CLI Pulse does
    /// not read the inherited counter from the parent's file, so it counts that
    /// snapshot's own request again: the limit the "simplified rules" line
    /// states. Once the scanner stops counting it, the line must go.
    func testTheSimplifiedRulesLineMatchesTheScanner() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-note-fork-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let sessions = tmp.appendingPathComponent("sessions", isDirectory: true)

        let now = Date()
        let dayFormatter = ISO8601DateFormatter()
        dayFormatter.formatOptions = [.withFullDate]
        dayFormatter.timeZone = .current
        let dir = dayFormatter.string(from: now).split(separator: "-")
            .reduce(sessions) { $0.appendingPathComponent(String($1)) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        func stamp(_ secondsAgo: TimeInterval) -> String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.string(from: now.addingTimeInterval(-secondsAgo))
        }
        func tokenCount(_ at: String, total: Int, last: Int) -> String {
            func usage(_ n: Int) -> String { #"{"input_tokens":\#(n),"cached_input_tokens":0,"output_tokens":0}"# }
            return #"{"type":"event_msg","timestamp":"\#(at)","payload":{"type":"token_count","info":{"total_token_usage":\#(usage(total)),"last_token_usage":\#(usage(last))}}}"#
        }
        let parent = [
            #"{"type":"session_meta","timestamp":"\#(stamp(600))","payload":{"id":"note-root","timestamp":"\#(stamp(600))","source":"vscode"}}"#,
            #"{"type":"turn_context","timestamp":"\#(stamp(590))","payload":{"model":"gpt-5"}}"#,
            tokenCount(stamp(580), total: 3_000, last: 3_000),
            tokenCount(stamp(570), total: 7_000, last: 4_000),
        ]
        let fork = [
            #"{"type":"session_meta","timestamp":"\#(stamp(300))","payload":{"id":"note-fork","forked_from_id":"note-root","timestamp":"\#(stamp(300))","source":"vscode"}}"#,
            #"{"type":"turn_context","timestamp":"\#(stamp(300))","payload":{"model":"gpt-5"}}"#,
            tokenCount(stamp(290), total: 7_000, last: 4_000),
            tokenCount(stamp(280), total: 7_800, last: 800),
        ]
        try (parent.joined(separator: "\n") + "\n")
            .write(to: dir.appendingPathComponent("rollout-a-note-root.jsonl"), atomically: true, encoding: .utf8)
        try (fork.joined(separator: "\n") + "\n")
            .write(to: dir.appendingPathComponent("rollout-b-note-fork.jsonl"), atomically: true, encoding: .utf8)

        var options = CostUsageScanner.Options(codexSessionsRoot: sessions, claudeProjectsRoots: [],
                                               cacheRoot: tmp.appendingPathComponent("cache"), daysToScan: 7)
        options.refreshMinIntervalSeconds = 0
        let input = CostUsageScanner.scan(options: options).entries
            .filter { $0.provider == "Codex" }
            .reduce(0) { $0 + $1.inputTokens }

        let replayCounted: Bool
        switch input {
        case 11_800: replayCounted = true    // 7,000 + the repeated 4,000 + 800
        case 7_800: replayCounted = false    // the fork's inherited counter read from its parent
        default:
            return XCTFail("fixture no longer understood: Codex input \(input)")
        }
        XCTAssertEqual(Reason.subagentSessionsCounted.caveat != nil, replayCounted,
                       replayCounted
                       ? "forks are counted by simplified rules: the note must say so (Reason.caveat)"
                       : "the scanner no longer counts a fork's repeated snapshot: drop the simplified-rules line")
    }

    // MARK: - Published prices

    /// Before OpenAI published GPT-5.5's price, its row was a copy of GPT-5.4's
    /// ($2.50 per million input tokens), and GPT-5.6 Sol, with no row, fell
    /// back to it. Adopting the published table changes both.
    func testThePublishedPricesLineMatchesThePriceTable() throws {
        func perMillionInput(_ model: String) throws -> Double {
            try XCTUnwrap(TokenPricing.codexCost(model: model, inputTokens: 1_000_000,
                                                 cachedInputTokens: 0, outputTokens: 0), model)
        }
        let gpt55 = try perMillionInput("gpt-5.5")
        let sol = try perMillionInput("gpt-5.6-sol")
        let interimRates = abs(gpt55 - 2.5) < 1e-9 && abs(sol - 2.5) < 1e-9

        XCTAssertEqual(Reason.shipped.contains(.publishedPrices), !interimRates,
                       interimRates
                       ? "the note says Codex uses OpenAI's published prices, and the table still has the interim rows"
                       : "the Codex price table changed: add .publishedPrices to Reason.shipped")
    }
}
#endif
