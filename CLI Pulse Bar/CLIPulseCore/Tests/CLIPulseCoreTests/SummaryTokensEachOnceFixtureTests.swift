import XCTest
@testable import CLIPulseCore

/// v1.58 (migrate_v0.86): the server's summary RPCs, `dashboard_summary`,
/// `provider_summary` and `provider_account_summary`, count a row's tokens as
/// the Mac does, each once (`ArchiveTokenBasis`): Codex input + output, since
/// its input already includes its cached input; every other provider input +
/// cached + output. Until v0.86 they added Codex's cached input a second time.
///
/// Both sides are held to one file,
/// `backend/supabase/tests/fixtures/summary_tokens_each_once.json`: here its
/// rows go through the Mac's code, and the CI database suite
/// (`run_v086_summary_tokens_each_once_tests.sh`) calls the three RPCs on the
/// same rows and expects the same figures. A change to either rule that does
/// not change the other fails one of the two.
final class SummaryTokensEachOnceFixtureTests: XCTestCase {

    private struct Fixture: Decodable {
        struct Row: Decodable {
            let user: String
            let metric_date: String
            let provider: String
            let model: String
            let input_tokens: Int
            let cached_tokens: Int
            let output_tokens: Int
            let cost: Double
        }
        struct Figures: Decodable, Equatable {
            let today_usage: Int
            let total_usage: Int
        }
        struct Expected: Decodable {
            let today_usage: Int
            let total_usage: Int
            let before_v086: Figures
        }
        let today: String
        let rows: [Row]
        let expected: [String: Expected]
        let expected_dashboard_today_usage: Int
        let expected_dashboard_today_usage_before_v086: Int
    }

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // CLIPulseCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // CLIPulseCore
        .deletingLastPathComponent()   // CLI Pulse Bar
        .deletingLastPathComponent()   // repo root

    private static let fixtureURL = repoRoot
        .appendingPathComponent("backend/supabase/tests/fixtures/summary_tokens_each_once.json")
    private static let migrationURL = repoRoot
        .appendingPathComponent("backend/supabase/migrate_v0.86_summary_tokens_each_once.sql")

    private func fixture() throws -> Fixture {
        try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: Self.fixtureURL))
    }

    /// The user's rows as the app holds them after `get_daily_usage`.
    private func dailyUsage(_ f: Fixture) -> [DailyUsage] {
        f.rows.filter { $0.user == "user" }.map {
            DailyUsage(date: $0.metric_date, provider: $0.provider, model: $0.model,
                       inputTokens: $0.input_tokens, cachedTokens: $0.cached_tokens,
                       outputTokens: $0.output_tokens, cost: $0.cost)
        }
    }

    /// The card's windows ending on the fixture's today: the server's windows
    /// for that `p_user_today` (today; today and the 6 days before).
    private func windows(_ f: Fixture) throws -> ProviderUsageWindows {
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let parts = f.today.split(separator: "-").compactMap { Int($0) }
        let noon = try XCTUnwrap(calendar.date(from: DateComponents(
            year: parts[0], month: parts[1], day: parts[2], hour: 12)))
        let w = ProviderUsageWindows(now: noon, timeZone: utc)
        XCTAssertEqual(w.todayKey, f.today)
        return w
    }

    /// Each provider's today and week, row by row through
    /// `ArchiveTokenBasis.tokens`, equal what the RPCs answer after v0.86.
    func testTheMacsRuleGivesTheServersFigures() throws {
        let f = try fixture()
        let rows = dailyUsage(f)
        let w = try windows(f)
        XCTAssertFalse(f.expected.isEmpty)
        for (provider, want) in f.expected {
            let mine = rows.filter { $0.provider == provider }
            func sum(_ window: ProviderUsageWindow) -> Int {
                mine.filter { w.contains($0.date, in: window) }.reduce(0) {
                    $0 + ArchiveTokenBasis.tokens(provider: $1.provider, inputTokens: $1.inputTokens,
                                                  cachedTokens: $1.cachedTokens, outputTokens: $1.outputTokens)
                }
            }
            XCTAssertEqual(sum(.today), want.today_usage, "\(provider): today")
            XCTAssertEqual(sum(.week), want.total_usage, "\(provider): the week")
        }
        let dashboard = rows.filter { w.contains($0.date, in: .today) }.reduce(0) {
            $0 + ArchiveTokenBasis.tokens(provider: $1.provider, inputTokens: $1.inputTokens,
                                          cachedTokens: $1.cachedTokens, outputTokens: $1.outputTokens)
        }
        XCTAssertEqual(dashboard, f.expected_dashboard_today_usage, "dashboard_summary's today_usage")
    }

    /// The usage panel's "each once" days (`ProviderUsageDays`, the basis the
    /// panel labels "Tokens: input, cached input and output, each counted
    /// once") add up to the same figures: what the Mac shows is what the
    /// server now says.
    func testThePanelsEachOnceDaysAddUpToTheServersFigures() throws {
        let f = try fixture()
        let rows = dailyUsage(f)
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        for (provider, want) in f.expected {
            let days = ProviderUsageDays.fromCloud(rows, provider: provider, basis: .eachOnce,
                                                   days: 7, todayKey: f.today, timeZone: utc)
            XCTAssertEqual(days.days.count, 7)
            XCTAssertEqual(days.day(f.today)?.tokens ?? 0, want.today_usage, "\(provider): today")
            XCTAssertEqual(days.days.reduce(0) { $0 + $1.tokens }, want.total_usage, "\(provider): the week")
        }
    }

    /// Control: the fixture tells the two rules apart. Summed the old way
    /// (input + cached + output, unclamped) its rows give `before_v086`, and
    /// Codex's figures are not the new ones, so a server or a Mac still
    /// counting the cache twice cannot pass the tests above.
    func testTheFixtureShowsTheDoubleCount() throws {
        let f = try fixture()
        let rows = dailyUsage(f)
        let w = try windows(f)
        for (provider, want) in f.expected {
            let mine = rows.filter { $0.provider == provider }
            func old(_ window: ProviderUsageWindow) -> Int {
                mine.filter { w.contains($0.date, in: window) }
                    .reduce(0) { $0 + $1.inputTokens + $1.cachedTokens + $1.outputTokens }
            }
            XCTAssertEqual(Fixture.Figures(today_usage: old(.today), total_usage: old(.week)), want.before_v086,
                           "\(provider): the old sum")
        }
        let codex = try XCTUnwrap(f.expected[ProviderKind.codex.rawValue])
        XCTAssertNotEqual(codex.today_usage, codex.before_v086.today_usage)
        XCTAssertNotEqual(codex.total_usage, codex.before_v086.total_usage)
        XCTAssertNotEqual(f.expected_dashboard_today_usage, f.expected_dashboard_today_usage_before_v086)
        // Claude is counted the same way by both rules.
        let claude = try XCTUnwrap(f.expected[ProviderKind.claude.rawValue])
        XCTAssertEqual(Fixture.Figures(today_usage: claude.today_usage, total_usage: claude.total_usage),
                       claude.before_v086)
    }

    /// The SQL names the one provider whose input includes its cached input.
    /// If `ArchiveTokenBasis` ever treats another provider that way, v0.86's
    /// rule (and the app_rpc.sql copy CI holds it to) must name it too.
    func testTheMigrationNamesEveryProviderWhoseInputIncludesCache() throws {
        let sql = try String(contentsOf: Self.migrationURL, encoding: .utf8)
        let cachedInside = ProviderKind.allCases.filter { ArchiveTokenBasis.inputIncludesCached($0.rawValue) }
        XCTAssertEqual(cachedInside, [.codex])
        for kind in cachedInside {
            // Three functions, one rule each.
            XCTAssertEqual(sql.components(separatedBy: "case when provider = '\(kind.rawValue)'").count - 1, 3,
                           "v0.86 does not apply \(kind.rawValue)'s rule in all three functions")
        }
    }
}
