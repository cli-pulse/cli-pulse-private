import XCTest
@testable import CLIPulseCore

/// The Siri summary used to be one English string grown by `+=` with inline
/// plurals (`"\(n) active \(n == 1 ? "session" : "sessions")"`), which no
/// translation can follow. It is now whole clauses joined by the locale's own
/// separator. These tests pin that English output did not change, and that the
/// clauses really localize.
///
/// They used to assert on a private copy of `GetStatusIntent.perform`'s
/// composition, kept here because the intent is in the iOS app target, which
/// `swift test` does not build. A copy stays green whatever the intent does: the
/// intent could have gone back to English, joined with a hardcoded ", ", or
/// dropped a clause. So the composition moved into `L10n.intents.statusSummary`,
/// these tests call it, and `testTheIntentsSpeakOnlyWhatTheseTestsCover` reads
/// the intents' source to hold them to calling it.
final class IntentSpeechTests: XCTestCase {

    private func withLocale(_ id: String, _ body: () throws -> Void) rethrows {
        let store = LocaleOverrideStore.shared
        let previous = store.override
        store.set(id)
        defer { store.set(previous) }
        try body()
    }

    private func summary(usage: String, cost: String, sessions: Int, alerts: Int) -> String {
        L10n.intents.statusSummary(usage: usage, cost: cost, sessions: sessions, alerts: alerts)
    }

    /// Byte-for-byte what the old `+=` code produced, for every branch.
    func testEnglishSummaryIsUnchanged() {
        withLocale("en") {
            XCTAssertEqual(summary(usage: "1.2M", cost: "$3.40", sessions: 2, alerts: 3),
                           "Today: 1.2M tokens, $3.40 spent, 2 active sessions, 3 open alerts.")
            XCTAssertEqual(summary(usage: "900", cost: "$0.12", sessions: 1, alerts: 1),
                           "Today: 900 tokens, $0.12 spent, 1 active session, 1 open alert.")
            XCTAssertEqual(summary(usage: "12K", cost: "less than one cent", sessions: 0, alerts: 0),
                           "Today: 12K tokens, less than one cent spent, no open alerts.")
        }
    }

    func testEnglishProviderLinesAreUnchanged() {
        withLocale("en") {
            XCTAssertEqual(L10n.intents.providerQuotaLeft("Claude", "450K", 38), "Claude: 450K left, 38% remaining.")
            XCTAssertEqual(L10n.intents.providerUsageNoQuota("Codex", "1.1M"), "Codex: 1.1M used today, no quota set.")
            // The brand is joined with U+00A0 at lookup (L10n.keepingBrandUnbroken).
            XCTAssertEqual(L10n.intents.providerNotConfigured("Gemini"), "Gemini is not configured in CLI\u{00A0}Pulse.")
        }
    }

    /// Asserted in Chinese, where every piece of the composition is visible: the
    /// separator is "，", the sentence end "。", and a dropped clause or an
    /// English separator cannot hide behind English defaults.
    func testSummaryLocalizesClauseByClause() {
        var english = ""
        withLocale("en") { english = summary(usage: "1.2M", cost: "$3.40", sessions: 2, alerts: 1) }
        withLocale("zh-Hans") {
            let spoken = summary(usage: "1.2M", cost: "$3.40", sessions: 2, alerts: 1)
            XCTAssertNotEqual(spoken, english, "the Siri summary is still English under zh-Hans")
            XCTAssertTrue(spoken.contains("1.2M") && spoken.contains("$3.40"), "a value was dropped: \(spoken)")
            XCTAssertFalse(spoken.contains("%"), "an unfilled specifier leaked: \(spoken)")
            XCTAssertFalse(spoken.hasPrefix("Today"), "the lead clause did not localize: \(spoken)")

            let separator = L10n.intents.clauseSeparator
            let end = L10n.intents.sentenceEnd
            XCTAssertNotEqual(separator, ", ", "zh-Hans must not join clauses with the English separator")
            XCTAssertTrue(spoken.hasSuffix(end), "the sentence does not end with the locale's own ending: \(spoken)")
            // Compared whole rather than split on the separator: zh-Hans's first
            // clause contains "，" itself.
            XCTAssertEqual(spoken, L10n.intents.statusToday("1.2M", "$3.40") + separator
                           + L10n.intents.activeSessions(2) + separator
                           + L10n.intents.openAlerts(1) + end,
                           "the summary is not exactly its three clauses joined by the locale's separator")

            let quiet = summary(usage: "12K", cost: "$0.01", sessions: 0, alerts: 0)
            XCTAssertEqual(quiet, L10n.intents.statusToday("12K", "$0.01") + separator
                           + L10n.intents.noOpenAlerts + end,
                           "with no sessions the session clause must be omitted, and no alerts must say so")
        }
    }

    // MARK: - The intents speak what these tests cover

    private static let appRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // CLIPulseCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // CLIPulseCore
        .deletingLastPathComponent()   // CLI Pulse Bar

    /// What is wrong with an intent's `perform()`: a string literal in it (the
    /// answer is being written there, in English), or a required call missing.
    /// Comments are ignored.
    static func performProblems(in source: String, mustCall required: [String]) -> [String] {
        guard let start = source.range(of: "func perform()") else {
            return ["no perform() found"]
        }
        let code = source[start.lowerBound...]
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[..<comment.lowerBound]
            }
            .joined(separator: "\n")
        var depth = 0
        var body = ""
        var opened = false
        for character in code {
            if character == "{" { depth += 1; opened = true }
            if opened { body.append(character) }
            if character == "}" {
                depth -= 1
                if opened && depth == 0 { break }
            }
        }
        var problems: [String] = []
        for call in required where !body.contains(call) {
            problems.append("perform() does not call \(call)")
        }
        let literals = body.split(separator: "\n").filter { $0.contains("\"") }
        for line in literals {
            problems.append("perform() writes a string literal: \(line.trimmingCharacters(in: .whitespaces))")
        }
        return problems
    }

    func testTheIntentsSpeakOnlyWhatTheseTestsCover() throws {
        let intents = Self.appRoot.appendingPathComponent("CLI Pulse Bar iOS/Intents")
        let status = try String(contentsOf: intents.appendingPathComponent("GetStatusIntent.swift"), encoding: .utf8)
        XCTAssertEqual(Self.performProblems(in: status, mustCall: ["L10n.intents.statusSummary("]), [],
                       "GetStatusIntent must speak L10n.intents.statusSummary, which the tests above cover")

        let quota = try String(contentsOf: intents.appendingPathComponent("GetProviderQuotaIntent.swift"), encoding: .utf8)
        XCTAssertEqual(Self.performProblems(in: quota, mustCall: ["L10n.intents.providerQuotaLeft(",
                                                                    "L10n.intents.providerUsageNoQuota("]), [],
                       "GetProviderQuotaIntent must speak only L10n.intents copy")
    }

    /// Negative control for the check above: the regressions it exists for must
    /// be reported, or a green run proves nothing.
    func testThePerformCheckReportsTheRegressionsItExistsFor() {
        let englishAgain = """
        struct GetStatusIntent: AppIntent {
            func perform() async throws -> some IntentResult {
                // L10n.intents.statusSummary( is only mentioned in this comment
                let spoken = "Today: \\(usage) tokens, \\(cost) spent."
                return .result(value: spoken)
            }
        }
        """
        let problems = Self.performProblems(in: englishAgain, mustCall: ["L10n.intents.statusSummary("])
        XCTAssertTrue(problems.contains("perform() does not call L10n.intents.statusSummary("),
                      "a call mentioned only in a comment was accepted: \(problems)")
        XCTAssertTrue(problems.contains { $0.contains("Today: ") }, "an English answer was not reported: \(problems)")

        let hardcodedSeparator = """
        func perform() async throws -> some IntentResult {
            let spoken = L10n.intents.statusSummary(usage: u, cost: c, sessions: 0, alerts: 0) + ", "
            return .result(value: spoken)
        }
        """
        XCTAssertEqual(Self.performProblems(in: hardcodedSeparator, mustCall: ["L10n.intents.statusSummary("]).count, 1,
                       "a hardcoded separator after the tested call was not reported")
    }
}
