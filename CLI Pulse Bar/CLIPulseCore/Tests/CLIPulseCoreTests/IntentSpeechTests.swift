import XCTest
@testable import CLIPulseCore

/// The Siri summary used to be one English string grown by `+=` with inline
/// plurals (`"\(n) active \(n == 1 ? "session" : "sessions")"`), which no
/// translation can follow. It is now whole clauses joined by the locale's own
/// separator. These tests pin that English output did not change, and that the
/// clauses really localize.
final class IntentSpeechTests: XCTestCase {

    private func withLocale(_ id: String, _ body: () -> Void) {
        let store = LocaleOverrideStore.shared
        let previous = store.override
        store.set(id)
        defer { store.set(previous) }
        body()
    }

    /// Mirrors `GetStatusIntent.perform`. Kept here, in the package, because the
    /// intent itself is in the iOS app target, which `swift test` does not build.
    private func summary(usage: String, cost: String, sessions: Int, alerts: Int) -> String {
        var clauses = [L10n.intents.statusToday(usage, cost)]
        if sessions > 0 { clauses.append(L10n.intents.activeSessions(sessions)) }
        clauses.append(alerts > 0 ? L10n.intents.openAlerts(alerts) : L10n.intents.noOpenAlerts)
        return clauses.joined(separator: L10n.intents.clauseSeparator) + L10n.intents.sentenceEnd
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

    func testSummaryLocalizesAndLeavesNoSpecifiers() {
        var english = ""
        withLocale("en") { english = summary(usage: "1.2M", cost: "$3.40", sessions: 2, alerts: 1) }
        withLocale("zh-Hans") {
            let spoken = summary(usage: "1.2M", cost: "$3.40", sessions: 2, alerts: 1)
            XCTAssertNotEqual(spoken, english, "the Siri summary is still English under zh-Hans")
            XCTAssertTrue(spoken.contains("1.2M") && spoken.contains("$3.40"), "a value was dropped: \(spoken)")
            XCTAssertFalse(spoken.contains("%"), "an unfilled specifier leaked: \(spoken)")
            XCTAssertFalse(spoken.hasPrefix("Today"), "the lead clause did not localize: \(spoken)")
        }
    }
}
