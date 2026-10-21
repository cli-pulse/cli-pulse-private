import XCTest
@testable import CLIPulseCore

/// v1.58 (P1-5): what the Sessions list shows, from the scan's rows by
/// session: a row per session over the panel's 30 days, most expensive first
/// (or latest first), each naming its project, its model, I/O and cached
/// tokens, its estimated cost, when it was last active and how many subagents
/// it includes; with "Hide personal information" on, "Project N" (the number
/// Projects gives the folder) and no path.
///
/// Asserted in Simplified Chinese: in English "Unknown" and "Project 2" are
/// also what a missing translation falls back to, so an English check could
/// not tell the catalogue lookup worked.
final class SessionUsageListTests: XCTestCase {

    private var previousLocale: String?
    private let today = "2026-10-21"
    private let utc = TimeZone(identifier: "UTC")!

    override func setUp() {
        super.setUp()
        previousLocale = LocaleOverrideStore.shared.override
        LocaleOverrideStore.shared.set("zh-Hans")
    }

    override func tearDown() {
        LocaleOverrideStore.shared.set(previousLocale)
        super.tearDown()
    }

    // MARK: - Fixtures

    private func folder(_ name: String) -> ProjectIdentity {
        .folder("/Users/sample/Projects/" + name)
    }

    private func entry(
        _ session: String, provider: String = "Codex", date: String? = nil, model: String = "gpt-5.5",
        input: Int, cached: Int = 0, output: Int = 0, cost: Double?, approximate: Bool = false
    ) -> CostUsageScanResult.SessionEntry {
        .init(provider: provider, session: session, date: date ?? today, model: model,
              inputTokens: input, cachedTokens: cached, outputTokens: output, costUSD: cost,
              priceIsApproximate: approximate)
    }

    private func detail(
        _ session: String, provider: String = "Codex", project: ProjectIdentity, minutesAgo: Double,
        subagentDays: [String] = []
    ) -> CostUsageScanResult.SessionDetail {
        .init(provider: provider, key: session, project: project,
              lastActivity: Self.reference.addingTimeInterval(-minutesAgo * 60), subagentLastDays: subagentDays)
    }

    /// The moment the fixtures' last activity is counted back from.
    private static let reference = Date(timeIntervalSince1970: 1_792_000_000)

    /// The same sessions' projects, as Projects lists them, for the numbers
    /// "Hide personal information" gives.
    private func projects(
        _ entries: [CostUsageScanResult.SessionEntry], _ details: [CostUsageScanResult.SessionDetail]
    ) -> [CostUsageScanResult.ProjectEntry] {
        let projectOf = Dictionary(uniqueKeysWithValues: details.map { ($0.key, $0.project) })
        return entries.map {
            .init(provider: $0.provider, project: projectOf[$0.session] ?? .unknown, date: $0.date, model: $0.model,
                  inputTokens: $0.inputTokens, cachedTokens: $0.cachedTokens, outputTokens: $0.outputTokens,
                  costUSD: $0.costUSD)
        }
    }

    /// Three Codex sessions: an expensive one with two models and two
    /// subagents, a cheap recent one, and one in an unknown folder.
    private var three: (entries: [CostUsageScanResult.SessionEntry], details: [CostUsageScanResult.SessionDetail]) {
        let entries = [
            entry("big", input: 1_000, cached: 200, output: 100, cost: 5),
            entry("big", date: "2026-10-20", model: "gpt-5.5-mini", input: 400, output: 40, cost: 1),
            entry("recent", input: 50, output: 5, cost: 0.25),
            entry("lost", input: 3_000, output: 300, cost: 2),
        ]
        let details = [
            detail("big", project: folder("demo-app"), minutesAgo: 600, subagentDays: [today, "2026-10-20"]),
            detail("recent", project: folder("api-gateway"), minutesAgo: 5),
            detail("lost", project: .unknown, minutesAgo: 90),
        ]
        return (entries, details)
    }

    private func build(
        _ fixture: (entries: [CostUsageScanResult.SessionEntry], details: [CostUsageScanResult.SessionDetail]),
        provider: String = "Codex", showsCost: Bool = true, hidePersonalInfo: Bool = false,
        order: SessionUsageRanking.Order = .cost) -> SessionUsageList
    {
        SessionUsageList.build(
            fixture.entries, details: fixture.details, projects: projects(fixture.entries, fixture.details),
            provider: provider, todayKey: today, timeZone: utc, showsCost: showsCost,
            hidePersonalInfo: hidePersonalInfo, order: order)
    }

    // MARK: - Order

    func testSessionsAreListedMostExpensiveFirstWithTheirProjects() {
        let list = build(three)
        XCTAssertEqual(list.lines.map(\.title), ["demo-app", "未知", "api-gateway"])
        XCTAssertEqual(list.countText, "3 个会话")
        XCTAssertEqual(list.lines.first?.costText, CostFormatter.format(6))
        XCTAssertEqual(list.lines.first?.hoverText, "/Users/sample/Projects/demo-app")
        XCTAssertEqual(list.lines[1].hoverText, L10n.projects.unknownHelp)
        XCTAssertTrue(list.lines[1].isUnknown)
    }

    func testLatestFirstOnRequest() {
        XCTAssertEqual(build(three, order: .latest).lines.map(\.title), ["api-gateway", "未知", "demo-app"])
    }

    /// With costs hidden a list shows no cost and does not follow, or give
    /// away, a ranking by cost: most I/O tokens first, and the picker reads
    /// "Tokens" for that order.
    func testWithCostsHiddenTheListIsRankedByTokensAndShowsNoCost() {
        let list = build(three, showsCost: false)
        XCTAssertEqual(list.lines.map(\.title), ["未知", "demo-app", "api-gateway"])
        XCTAssertTrue(list.lines.allSatisfy { $0.costText == nil && $0.costHelp.isEmpty })
        XCTAssertEqual(SessionUsageRanking.Order.cost.label(showsCost: false), "token")
        XCTAssertEqual(SessionUsageRanking.Order.cost.label(showsCost: true), "费用")
        XCTAssertEqual(SessionUsageRanking.Order.latest.label(showsCost: true), "最近")
    }

    // MARK: - What a row says

    func testARowNamesItsModelTokensActivityAndSubagents() throws {
        let line = try XCTUnwrap(build(three).lines.first)
        XCTAssertEqual(line.usageText, "gpt-5.5 +1 · 1.5K I/O · 缓存 200")
        let moment = DisplayFormat.dateTime(Self.reference.addingTimeInterval(-600 * 60))
        XCTAssertEqual(line.activityText, "最近活动：\(moment) · 含 2 个子 Agent")
        XCTAssertEqual(
            line.accessibilityText,
            "demo-app, \(CostFormatter.format(6)), gpt-5.5 +1 · 1.5K I/O · 缓存 200, 最近活动：\(moment) · 含 2 个子 Agent")
        // A session without subagents says nothing about them.
        let recent = try XCTUnwrap(build(three).lines.last)
        XCTAssertFalse(recent.activityText.contains("子 Agent"), recent.activityText)
        XCTAssertEqual(recent.usageText, "gpt-5.5 · 55 I/O · 缓存 0")
    }

    func testEnglishCountsOneAndMany() {
        LocaleOverrideStore.shared.set("en")
        XCTAssertEqual(L10n.sessionHistory.count(1), "1 session")
        XCTAssertEqual(L10n.sessionHistory.count(1_408), "1,408 sessions")
        XCTAssertEqual(L10n.sessionHistory.subagents(1), "includes 1 subagent")
        XCTAssertEqual(L10n.sessionHistory.subagents(3), "includes 3 subagents")
        XCTAssertEqual(L10n.sessionHistory.ioCached("1.2M", "980K"), "1.2M I/O · 980K cached")
    }

    /// A cost is marked as a model's is: "No rate" when none of its tokens
    /// had one, "≥" when some had none, "≈" when one was borrowed.
    func testCostsAreMarkedAsTheModelRowsMarkThem() throws {
        let entries = [
            entry("unrated", model: "local-preview", input: 100, cost: nil),
            entry("partly", input: 100, cost: 1),
            entry("partly", model: "local-preview", input: 100, cost: nil),
            entry("borrowed", model: "gpt-9", input: 100, cost: 0.5, approximate: true),
        ]
        let details = ["unrated", "partly", "borrowed"].map { detail($0, project: folder($0), minutesAgo: 1) }
        let list = build((entries, details))
        let byTitle = Dictionary(uniqueKeysWithValues: list.lines.map { ($0.title, $0) })
        let unrated = try XCTUnwrap(byTitle["unrated"])
        XCTAssertEqual(unrated.costText, "无单价")
        XCTAssertTrue(unrated.hasNoRate)
        XCTAssertEqual(byTitle["partly"]?.costText, CostFormatter.format(1, approximate: false, atLeast: true))
        XCTAssertEqual(byTitle["partly"]?.costHelp, L10n.providerPanel.atLeastHelp)
        XCTAssertEqual(byTitle["borrowed"]?.costText, CostFormatter.format(0.5, approximate: true, atLeast: false))
    }

    // MARK: - Hide personal information

    /// Each project goes by the number Projects gives it, so "项目 2" is the
    /// same folder in both lists, and no path is shown; an unknown folder
    /// names nothing personal and keeps its name.
    func testHiddenNamesAreTheProjectsNumbersWithoutAPath() throws {
        let fixture = three
        let list = build(fixture, hidePersonalInfo: true)
        let numbers = ProjectUsageRanking.anonymousNumbers(
            projects(fixture.entries, fixture.details), todayKey: today, timeZone: utc)
        let demo = try XCTUnwrap(numbers[folder("demo-app").key])
        let api = try XCTUnwrap(numbers[folder("api-gateway").key])
        XCTAssertEqual(list.lines.map(\.title), ["项目 \(demo)", "未知", "项目 \(api)"])
        XCTAssertNil(list.lines[0].hoverText)
        XCTAssertNil(list.lines[2].hoverText)
        XCTAssertTrue(list.namesHidden)
        XCTAssertFalse(list.lines.contains { ($0.hoverText ?? "").contains("/Users/") })
        XCTAssertEqual(list.footnote, [L10n.sessionHistory.help, L10n.usageDashboard.costDisclaimer, L10n.projects.numberedHelp])
        XCTAssertTrue(list.footnote[0].hasPrefix("根据这台 Mac 的会话日志"), list.footnote[0])
    }

    /// The footnote says the costs are estimates only while it shows some.
    func testTheFootnoteLabelsCostsAsEstimatesOnlyWhenItShowsThem() {
        XCTAssertEqual(build(three).footnote, [L10n.sessionHistory.help, L10n.usageDashboard.costDisclaimer])
        XCTAssertEqual(build(three, showsCost: false).footnote, [L10n.sessionHistory.help])
        XCTAssertEqual(L10n.usageDashboard.costDisclaimer, "费用是以 API 按量付费价格算出的预估值，不是真实账单。")
    }

    // MARK: - The window

    /// Only the 30 days ending today count, for a session's figures and for
    /// its subagents.
    func testOnlyTheWindowsDaysCount() throws {
        let entries = [
            entry("long", date: "2026-09-21", input: 9_000, cost: 9),   // the 31st day back
            entry("long", date: "2026-09-22", input: 100, cost: 1),     // the 30th
            entry("gone", date: "2026-09-20", input: 500, cost: 5),
        ]
        let details = [
            detail("long", project: folder("demo-app"), minutesAgo: 1, subagentDays: ["2026-09-21", "2026-09-22"]),
            detail("gone", project: folder("old"), minutesAgo: 2),
        ]
        let rows = SessionUsageRanking.rows(entries, details: details, provider: "Codex", todayKey: today, timeZone: utc)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(row.inputTokens, 100)
        XCTAssertEqual(row.cost, 1)
        XCTAssertEqual(row.subagents, 1)
    }

    /// One provider's list holds that provider's sessions.
    func testAProviderListShowsOnlyItsOwn() {
        var fixture = three
        fixture.entries.append(entry("claude-one", provider: "Claude", model: "claude-sonnet-4-5", input: 10, cached: 900, output: 90, cost: 0.1))
        fixture.details.append(detail("claude-one", provider: "Claude", project: folder("demo-app"), minutesAgo: 3))
        XCTAssertEqual(build(fixture).lines.count, 3)
        let claude = build(fixture, provider: "Claude")
        XCTAssertEqual(claude.lines.map(\.title), ["demo-app"])
        XCTAssertEqual(claude.countText, "1 个会话")
        XCTAssertEqual(claude.lines.first?.usageText, "claude-sonnet-4-5 · 100 I/O · 缓存 900")
    }

    // MARK: - QA

    func testTheQARendererDrawsTheCardsStates() {
        XCTAssertTrue(QARenderSnapshot.catalog.contains(.panelSessionsStates))
        XCTAssertEqual(QARenderSurface.panelSessionsStates.id, "card-panel-sessions")
        XCTAssertEqual(QARenderSurface.panelSessionsStates.kind, .panel)
    }

    /// The renders' sample sessions are the sample projects' rows exactly,
    /// so the panel's Sessions and Projects tell one story, and some of them
    /// show subagents and more than one model.
    func testTheQASampleSessionsAddUpToTheProjectsSample() throws {
        for kind in QARenderSnapshot.providerPanelKinds {
            let sample = QARenderSnapshot.providerPanelSessionsSample(kind)
            let projects = QARenderSnapshot.providerPanelProjectsSample(kind)
            func sum(_ values: [(Int, Int, Int, Double)]) -> (Int, Int, Int, Int) {
                values.reduce((0, 0, 0, 0)) { ($0.0 + $1.0, $0.1 + $1.1, $0.2 + $1.2, $0.3 + Int(($1.3 * 100).rounded())) }
            }
            let sessions = sum(sample.entries.map { ($0.inputTokens, $0.cachedTokens, $0.outputTokens, $0.costUSD ?? 0) })
            let split = sum(projects.map { ($0.inputTokens, $0.cachedTokens, $0.outputTokens, $0.costUSD ?? 0) })
            XCTAssertTrue(sessions == split, "\(kind): sessions \(sessions) vs projects \(split)")
            let rows = SessionUsageRanking.rows(
                sample.entries, details: sample.details, provider: kind.rawValue, todayKey: DayKey.string(from: Date()))
            XCTAssertTrue(rows.contains { $0.subagents > 0 }, "\(kind)")
            XCTAssertTrue(rows.contains { $0.models.count > 1 }, "\(kind)")
            XCTAssertTrue(rows.allSatisfy { $0.lastActivity <= Date() }, "\(kind)")
        }
    }
}
