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
        // One session's own wording, not Projects' for its combined row.
        XCTAssertEqual(list.lines[1].hoverText, "这个会话的日志没有记录它在哪个文件夹中运行。")
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
        // "最新", not "最近": the Sessions tab's "最近" chip means a log
        // written in the last 30 minutes.
        XCTAssertEqual(SessionUsageRanking.Order.latest.label(showsCost: true), "最新")
    }

    /// With costs hidden a line names the session's model with the most
    /// tokens, not its most expensive one, which would give the ranking by
    /// cost away.
    func testWithCostsHiddenALineNamesItsModelWithTheMostTokens() throws {
        let entries = [
            entry("mixed", model: "gpt-5.5", input: 100, output: 10, cost: 4),
            entry("mixed", model: "gpt-5.5-mini", input: 9_000, output: 900, cost: 0.5),
        ]
        let fixture = (entries, [detail("mixed", project: folder("demo-app"), minutesAgo: 1)])
        XCTAssertEqual(try XCTUnwrap(build(fixture).lines.first).usageText, "gpt-5.5 +1 · 10K I/O")
        XCTAssertEqual(try XCTUnwrap(build(fixture, showsCost: false).lines.first).usageText, "gpt-5.5-mini +1 · 10K I/O")
    }

    // MARK: - What a row says

    /// Codex's input includes its cached input, so its cached tokens are
    /// shown as part of its I/O ("含"), never beside it as a second amount;
    /// a session that cached nothing says nothing about the cache. "上次活动",
    /// not "最近活动", the Sessions tab's chip for a log written in the last
    /// five minutes.
    func testARowNamesItsModelTokensActivityAndSubagents() throws {
        let line = try XCTUnwrap(build(three).lines.first)
        XCTAssertEqual(line.usageText, "gpt-5.5 +1 · 1.5K I/O（含缓存 200）")
        XCTAssertEqual(line.usageHelp, L10n.providers.codexIOTokensHelp)
        XCTAssertTrue(line.usageHelp.hasPrefix("输入 + 输出 token。输入已包含缓存输入"), line.usageHelp)
        let moment = DisplayFormat.dateTime(Self.reference.addingTimeInterval(-600 * 60))
        XCTAssertEqual(line.activityText, "上次活动：\(moment) · 含 2 个子 Agent")
        // VoiceOver hears the shorthand spelled out: the models counted in
        // words, the tokens in full with what they are, no middle dots.
        XCTAssertEqual(
            line.accessibilityText,
            "demo-app, \(CostFormatter.format(6)), gpt-5.5 及另外 1 个模型, 输入和输出 1,540 个 token，其中缓存 200 个, "
                + "上次活动：\(moment), 含 2 个子 Agent")
        // A session without subagents says nothing about them, nor about a
        // cache it did not use.
        let recent = try XCTUnwrap(build(three).lines.last)
        XCTAssertFalse(recent.activityText.contains("子 Agent"), recent.activityText)
        XCTAssertEqual(recent.usageText, "gpt-5.5 · 55 I/O")
        XCTAssertTrue(recent.accessibilityText.contains("gpt-5.5, 输入和输出 55 个 token, 上次活动："), recent.accessibilityText)
    }

    /// Spoken, "+2" is "及另外 2 个模型", one model or many.
    func testVoiceOverCountsTheOtherModelsInWords() {
        XCTAssertEqual(L10n.sessionHistory.spokenModels("gpt-5.5", others: 2), "gpt-5.5 及另外 2 个模型")
        LocaleOverrideStore.shared.set("en")
        XCTAssertEqual(L10n.sessionHistory.spokenModels("gpt-5.5", others: 1), "gpt-5.5 and 1 other model")
        XCTAssertEqual(L10n.sessionHistory.spokenModels("gpt-5.5", others: 3), "gpt-5.5 and 3 other models")
    }

    func testEnglishCountsOneAndMany() {
        LocaleOverrideStore.shared.set("en")
        XCTAssertEqual(L10n.sessionHistory.count(1), "1 session")
        XCTAssertEqual(L10n.sessionHistory.count(1_408), "1,408 sessions")
        XCTAssertEqual(L10n.sessionHistory.subagents(1), "includes 1 subagent")
        XCTAssertEqual(L10n.sessionHistory.subagents(3), "includes 3 subagents")
        XCTAssertEqual(L10n.sessionHistory.ioCached("1.2M", "980K"), "1.2M I/O · 980K cached")
        XCTAssertEqual(L10n.sessionHistory.ioInclCached("1.2M", "980K"), "1.2M I/O, incl. 980K cached")
        XCTAssertEqual(L10n.sessionHistory.shownOf(5, 1_408), "5 of 1,408 sessions")
        XCTAssertEqual(L10n.sessionHistory.showMore(20), "Show 20 more")
        XCTAssertEqual(L10n.sessionHistory.sortLatest, "Latest")
    }

    // MARK: - More than a page

    /// The card shows the first five, says how many of how many, and shows
    /// twenty more at a time; "收起" goes back to five. It has no scroll view
    /// of its own, so a row past the fifth is reached by these, never by a
    /// scroll nothing signals.
    func testTheListShowsAPageAtATime() {
        let entries = (0..<56).map { entry("s\($0)", input: 1_000 + $0, cost: Double($0)) }
        let details = (0..<56).map { detail("s\($0)", project: folder("demo-app"), minutesAgo: Double($0)) }
        let list = build((entries, details))
        XCTAssertEqual(list.lines.count, 56)
        XCTAssertEqual(SessionUsageList.firstPage, 5)
        XCTAssertEqual(list.visibleLines(SessionUsageList.firstPage).count, 5)
        XCTAssertEqual(list.shownText(5), "56 个会话中的 5 个")
        XCTAssertEqual(list.moreCount(after: 5), 20)
        XCTAssertEqual(L10n.sessionHistory.showMore(list.moreCount(after: 5)), "再显示 20 个")
        XCTAssertFalse(list.canShowLess(5))
        XCTAssertEqual(list.shownText(25), "56 个会话中的 25 个")
        XCTAssertTrue(list.canShowLess(25))
        XCTAssertEqual(list.moreCount(after: 45), 11)
        XCTAssertEqual(list.moreCount(after: 56), 0)
        XCTAssertEqual(list.shownText(56), "56 个会话")
        XCTAssertEqual(list.shownText(80), list.countText)
        XCTAssertEqual(L10n.sessionHistory.showLess, "收起")
        // Three sessions: all shown, nothing more to show.
        let few = build(three)
        XCTAssertEqual(few.shownText(5), "3 个会话")
        XCTAssertEqual(few.moreCount(after: 5), 0)
        XCTAssertFalse(few.canShowLess(5))
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
        // Claude's cache is on top of its I/O, so it stands beside it.
        XCTAssertEqual(claude.lines.first?.usageText, "claude-sonnet-4-5 · 100 I/O · 缓存 900")
        XCTAssertEqual(claude.lines.first?.usageHelp, L10n.providers.claudeIOTokensHelp)
        XCTAssertTrue(
            claude.lines.first?.accessibilityText.contains("输入和输出 100 个 token，另有缓存 900 个 token") == true,
            claude.lines.first?.accessibilityText ?? "")
    }

    // MARK: - QA

    func testTheQARendererDrawsTheCardsStates() {
        XCTAssertTrue(QARenderSnapshot.catalog.contains(.panelSessionsStates))
        XCTAssertEqual(QARenderSurface.panelSessionsStates.id, "card-panel-sessions")
        XCTAssertEqual(QARenderSurface.panelSessionsStates.kind, .panel)
        XCTAssertTrue(QARenderSnapshot.catalog.contains(.panelSessionsMoreStates))
        XCTAssertEqual(QARenderSurface.panelSessionsMoreStates.id, "card-panel-sessions-more")
        XCTAssertTrue(QARenderSnapshot.catalog.contains(.providerUsagePanelLaptop))
        XCTAssertEqual(QARenderSurface.providerUsagePanelLaptop.id, "panel-provider-usage-codex-laptop")
        XCTAssertEqual(QARenderSurface.providerUsagePanelLaptop.kind, .panel)
    }

    /// The "more" strip shows what its note says: among the first 25 Codex
    /// sessions with the switch on, "项目 N" rows and an "未知" one; an edge
    /// session whose cost is a four-figure lower bound; a single Claude one.
    func testTheQAEdgeStatesShowWhatTheyClaim() throws {
        let kinds = QARenderSnapshot.providerPanelKinds
        let sample = kinds.map { QARenderSnapshot.providerPanelSessionsSample($0) }
        let masked = SessionUsageList.build(
            sample.flatMap(\.entries), details: sample.flatMap(\.details),
            projects: kinds.flatMap { QARenderSnapshot.providerPanelProjectsSample($0) }, provider: "Codex",
            todayKey: DayKey.string(from: Date()), showsCost: true, hidePersonalInfo: true)
        let shown = masked.visibleLines(SessionUsageList.firstPage + SessionUsageList.pageStep)
        XCTAssertEqual(shown.count, 25)
        XCTAssertTrue(shown.contains { $0.isUnknown && $0.title == "未知" }, "\(shown.map(\.title))")
        XCTAssertTrue(shown.contains { $0.title.hasPrefix("项目 ") })
        XCTAssertGreaterThan(masked.moreCount(after: shown.count), 0)

        let edge = QARenderSnapshot.sessionsEdgeSample()
        func list(_ provider: String) -> SessionUsageList {
            SessionUsageList.build(
                edge.entries, details: edge.details, projects: edge.projects, provider: provider,
                todayKey: DayKey.string(from: Date()), showsCost: true, hidePersonalInfo: false)
        }
        let long = try XCTUnwrap(list("Codex").lines.first)
        XCTAssertEqual(long.costText, CostFormatter.format(1_234.56, approximate: false, atLeast: true))
        XCTAssertGreaterThan(long.title.count, 50)
        XCTAssertEqual(list("Claude").countText, "1 个会话")
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
