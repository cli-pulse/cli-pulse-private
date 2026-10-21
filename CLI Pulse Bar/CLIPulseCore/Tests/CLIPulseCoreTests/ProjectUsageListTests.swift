import XCTest
@testable import CLIPulseCore

/// v1.58 (P1-4): what a project list shows, from the scan's rows by project:
/// the top five by cost, "name · cost · tokens", the full path only on hover,
/// and with "Hide personal information" on "Project N" and no path.
///
/// Asserted in Simplified Chinese: in English "Unknown" and "Project 2" are
/// also what a missing translation falls back to, so an English check could
/// not tell the catalogue lookup worked.
final class ProjectUsageListTests: XCTestCase {

    private var previousLocale: String?
    private let today = "2026-10-21"

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

    private func projectEntry(
        _ project: ProjectIdentity, provider: String = "Codex", date: String? = nil,
        model: String = "gpt-5.5", input: Int, cached: Int = 0, output: Int = 0, cost: Double?
    ) -> CostUsageScanResult.ProjectEntry {
        .init(provider: provider, project: project, date: date ?? today, model: model,
              inputTokens: input, cachedTokens: cached, outputTokens: output, costUSD: cost)
    }

    /// Seven projects of one provider, costs 7 down to 1, tokens rising the
    /// other way; one of them unknown.
    private var seven: [CostUsageScanResult.ProjectEntry] {
        let names = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot"]
        var entries = names.enumerated().map { index, name in
            projectEntry(folder(name), input: 1_000 * (index + 1), cost: Double(7 - index))
        }
        entries.append(projectEntry(.unknown, input: 50_000, cost: 0.5))
        return entries
    }

    private func build(
        _ entries: [CostUsageScanResult.ProjectEntry], provider: String? = "Codex",
        basis: ProviderUsageDays.TokenBasis = .eachOnce,
        showsCost: Bool = true, hidePersonalInfo: Bool = false) -> ProjectUsageList
    {
        ProjectUsageList.build(
            entries, provider: provider, basis: basis, todayKey: today,
            timeZone: TimeZone(identifier: "UTC")!,
            showsCost: showsCost, hidePersonalInfo: hidePersonalInfo)
    }

    // MARK: - Ranking

    func testTheTopFiveByCostAreListedWithTheirFolderNames() {
        let list = build(seven)
        XCTAssertEqual(list.lines.map(\.title), ["alpha", "bravo", "charlie", "delta", "echo"])
        XCTAssertEqual(list.projectCount, 7)
        XCTAssertEqual(list.shownOfText, "7 个项目中的前 5 个")
        XCTAssertEqual(list.lines.first?.costText, CostFormatter.format(7))
        XCTAssertEqual(list.lines.first?.tokensText, "1K token")
        // The full path is what hovering shows.
        XCTAssertEqual(list.lines.first?.hoverText, "/Users/sample/Projects/alpha")
    }

    /// With costs hidden a list shows no cost and does not follow, or give
    /// away, a ranking by cost: most tokens first.
    func testWithCostsHiddenTheListIsRankedByTokensAndShowsNoCost() {
        let list = build(seven, showsCost: false)
        XCTAssertEqual(list.lines.map(\.title), ["未知", "foxtrot", "echo", "delta", "charlie"])
        XCTAssertTrue(list.lines.allSatisfy { $0.costText == nil })
        XCTAssertTrue(list.lines.allSatisfy { $0.costHelp.isEmpty })
    }

    func testAListOfFewerThanFiveSaysNothingAboutMore() {
        let list = build(Array(seven.prefix(3)))
        XCTAssertEqual(list.lines.count, 3)
        XCTAssertNil(list.shownOfText)
    }

    /// Only the window's days count: the 30 days ending today.
    func testDaysOutsideTheWindowAreLeftOut() {
        let entries = [
            projectEntry(folder("recent"), date: "2026-09-22", input: 100, cost: 1),   // the 30th day back
            projectEntry(folder("stale"), date: "2026-09-21", input: 100, cost: 9),    // the 31st
            projectEntry(folder("future"), date: "2026-10-22", input: 100, cost: 9),
        ]
        XCTAssertEqual(build(entries).lines.map(\.title), ["recent"])
    }

    /// One provider's list shows that provider's projects; the Overview's,
    /// both, a folder both name counted once.
    func testAProviderListShowsOnlyItsOwnAndTheOverviewMergesAFolderBothName() {
        let shared = folder("shared")
        let entries = [
            projectEntry(shared, provider: "Codex", input: 1_000, cost: 1),
            projectEntry(shared, provider: "Claude", model: "claude-sonnet-4-5", input: 2_000, cost: 2),
            projectEntry(folder("claude-only"), provider: "Claude", model: "claude-sonnet-4-5", input: 500, cost: 0.5),
        ]
        XCTAssertEqual(build(entries, provider: "Codex").lines.map(\.title), ["shared"])
        let both = build(entries, provider: nil)
        XCTAssertEqual(both.lines.map(\.title), ["shared", "claude-only"])
        XCTAssertEqual(both.lines.first?.costText, CostFormatter.format(3))
        XCTAssertEqual(both.lines.first?.tokensText, "3K token")
    }

    /// A project's tokens are counted as the view beside it counts them:
    /// each once (Codex's cached input inside its input, Claude's cache
    /// beside it), or the cards' input + output.
    func testTokensFollowTheListsBasis() {
        let entries = [
            projectEntry(folder("codex"), provider: "Codex", input: 1_000, cached: 800, output: 100, cost: 1),
            projectEntry(folder("claude"), provider: "Claude", model: "claude-sonnet-4-5", input: 10, cached: 5_000, output: 90, cost: 1),
        ]
        func tokens(_ provider: String, _ basis: ProviderUsageDays.TokenBasis) -> Int? {
            ProjectUsageRanking.rows(entries, provider: provider, basis: basis, todayKey: today,
                                     timeZone: TimeZone(identifier: "UTC")!).first?.tokens
        }
        XCTAssertEqual(tokens("Codex", .eachOnce), 1_100)
        XCTAssertEqual(tokens("Codex", .inputOutput), 1_100)
        XCTAssertEqual(tokens("Claude", .eachOnce), 5_100)
        XCTAssertEqual(tokens("Claude", .inputOutput), 100)
        XCTAssertEqual(build(entries, provider: "Claude", basis: .inputOutput).lines.first?.tokensText, "100 I/O")
    }

    /// A cost is marked as a model's is: "≥" when some tokens had no rate,
    /// "No rate" when none had one.
    func testAPartlyOrWhollyUnpricedProjectSaysSo() {
        let entries = [
            projectEntry(folder("partly"), input: 1_000, cost: 2),
            projectEntry(folder("partly"), model: "mystery", input: 1_000, cost: nil),
            projectEntry(folder("unpriced"), model: "mystery", input: 5_000, cost: nil),
        ]
        let lines = build(entries).lines
        XCTAssertEqual(lines.map(\.title), ["partly", "unpriced"])
        XCTAssertEqual(lines[0].costText, "≥" + CostFormatter.format(2))
        XCTAssertEqual(lines[0].costHelp, L10n.providerPanel.atLeastHelp)
        XCTAssertEqual(lines[1].costText, L10n.providerPanel.noRate)
        XCTAssertEqual(lines[1].costHelp, L10n.providerPanel.noRateHelp)
    }

    // MARK: - Unknown

    func testAProjectWhoseLogsNameNoFolderIsUnknownInTheReadersLanguage() throws {
        let line = try XCTUnwrap(build([projectEntry(.unknown, input: 100, cost: 1)]).lines.first)
        XCTAssertEqual(line.title, "未知")
        XCTAssertTrue(line.isUnknown)
        XCTAssertEqual(line.hoverText, L10n.projects.unknownHelp)
        XCTAssertNotNil(line.hoverText?.range(of: "文件夹"), "the hover text is not Chinese: \(line.hoverText ?? "")")
    }

    // MARK: - Hide personal information

    /// With the switch on a named project is "Project N" and shows no path;
    /// "Unknown" names nothing personal and keeps its name.
    func testWithTheSwitchOnProjectsAreNumberedAndShowNoPath() {
        let list = build(seven + [projectEntry(.unknown, input: 1, cost: 100)], hidePersonalInfo: true)
        XCTAssertEqual(list.lines.map(\.title), ["未知", "项目 1", "项目 2", "项目 3", "项目 4"])
        for line in list.lines where !line.isUnknown {
            XCTAssertNil(line.hoverText, "\(line.title) shows a path on hover")
        }
        let shown = list.lines.map { [$0.title, $0.hoverText ?? "", $0.tokensText, $0.costText ?? ""] }
            .flatMap { $0 }.joined(separator: " ")
        for name in ["alpha", "bravo", "/Users/sample"] {
            XCTAssertNil(shown.range(of: name), "\(name) is on screen with the switch on: \(shown)")
        }
    }

    /// Negative control: the switch off shows the names, and the paths on hover.
    func testWithTheSwitchOffTheNamesAndPathsShow() {
        let list = build(seven)
        XCTAssertTrue(list.lines.contains { $0.title == "alpha" })
        XCTAssertTrue(list.lines.contains { $0.hoverText == "/Users/sample/Projects/alpha" })
    }

    /// "Project 2" is the same project in a provider's list and in the
    /// Overview's: numbered by its place among every provider's projects.
    func testAProjectKeepsItsNumberInEveryList() {
        let entries = [
            projectEntry(folder("claude-big"), provider: "Claude", model: "claude-sonnet-4-5", input: 100, cost: 10),
            projectEntry(folder("codex-a"), provider: "Codex", input: 100, cost: 5),
            projectEntry(folder("codex-b"), provider: "Codex", input: 100, cost: 1),
        ]
        let overview = build(entries, provider: nil, hidePersonalInfo: true)
        let codex = build(entries, provider: "Codex", hidePersonalInfo: true)
        XCTAssertEqual(overview.lines.map(\.title), ["项目 1", "项目 2", "项目 3"])
        XCTAssertEqual(codex.lines.map(\.title), ["项目 2", "项目 3"])
        XCTAssertEqual(overview.lines.map(\.id).dropFirst().map { $0 }, codex.lines.map(\.id))
    }

    func testTheMaskItself() {
        let project = folder("demo-app")
        XCTAssertEqual(PersonalInfoMask.projectTitle(project, number: 3, hidePersonalInfo: true), "项目 3")
        XCTAssertEqual(PersonalInfoMask.projectTitle(project, number: 3, hidePersonalInfo: false), "demo-app")
        XCTAssertEqual(PersonalInfoMask.projectTitle(.unknown, number: nil, hidePersonalInfo: true), "未知")
        XCTAssertNil(PersonalInfoMask.projectPath(project, hidePersonalInfo: true))
        XCTAssertEqual(PersonalInfoMask.projectPath(project, hidePersonalInfo: false), "/Users/sample/Projects/demo-app")
    }

    func testTheScopeSaysThisMacAndTheWindow() {
        XCTAssertEqual(ProjectUsageList.scopeText(), "这台 Mac · 最近 30 天")
    }

    // MARK: - The QA renders

    /// The review set draws the Top Projects card in its states, and the
    /// panel's Projects from sample rows split by project that add up to the
    /// panel's sample rows, so the renders show figures the panel can.
    func testTheRendersDrawTheProjectStatesFromSamplesThatAddUp() {
        XCTAssertTrue(QARenderSnapshot.catalog.contains(.topProjectsStates))
        XCTAssertEqual(QARenderSurface.topProjectsStates.id, "card-top-projects")
        XCTAssertEqual(QARenderSurface.topProjectsStates.kind, .window)
        let now = Date()
        for kind in QARenderSnapshot.providerPanelKinds {
            let rows = QARenderSnapshot.providerPanelSample(kind, today: now)
            let projects = QARenderSnapshot.providerPanelProjectsSample(kind, today: now)
            XCTAssertEqual(projects.reduce(0) { $0 + $1.inputTokens + $1.cachedTokens + $1.outputTokens },
                           rows.reduce(0) { $0 + $1.inputTokens + $1.cachedTokens + $1.outputTokens }, "\(kind)")
            XCTAssertEqual(projects.reduce(0) { $0 + ($1.costUSD ?? 0) },
                           rows.reduce(0) { $0 + ($1.costUSD ?? 0) }, accuracy: 0.001, "\(kind)")
            XCTAssertTrue(projects.allSatisfy {
                $0.project.isUnknown || $0.project.path?.hasPrefix(QARenderSnapshot.sampleProjectsFolder + "/") == true
            })
            let list = ProjectUsageList.build(
                projects, provider: kind.rawValue, basis: .eachOnce, todayKey: DayKey.string(from: now),
                showsCost: true, hidePersonalInfo: false)
            XCTAssertEqual(list.lines.count, ProjectUsageRanking.shownCount, "\(kind)")
            XCTAssertNotNil(list.shownOfText, "\(kind): the render shows a list cut short")
        }
    }

    // MARK: - Folders

    func testWorkingDirectoriesBecomeProjectFolders() {
        let home = "/Users/sample"
        func root(_ cwd: String?) -> String? { ProjectPathNormalizer.root(cwd, home: home) }
        XCTAssertEqual(root("/Users/sample/Projects/demo-app/"), "/Users/sample/Projects/demo-app")
        XCTAssertEqual(root("~/Projects/demo-app"), "/Users/sample/Projects/demo-app")
        XCTAssertEqual(root("~"), "/Users/sample")
        XCTAssertEqual(root("/Users/sample/Projects/demo-app/./ios/.."), "/Users/sample/Projects/demo-app")
        XCTAssertEqual(root("/tmp/clone-1"), "/private/tmp/clone-1")
        XCTAssertEqual(root("/private/tmp/clone-1"), "/private/tmp/clone-1")
        // A Codex worktree is its checkout folder, whatever subfolder ran.
        XCTAssertEqual(root("/Users/sample/.codex/worktrees/a1b2/demo-app/ios/App"),
                       "/Users/sample/.codex/worktrees/a1b2/demo-app")
        XCTAssertNil(root(nil))
        XCTAssertNil(root("  "))
        XCTAssertNil(root("relative/path"), "a relative path names no folder")

        XCTAssertTrue(ProjectPathNormalizer.isTemporary("/private/tmp/clone-1", home: home))
        XCTAssertTrue(ProjectPathNormalizer.isTemporary("/Users/sample/.codex/worktrees/a1b2/demo-app", home: home))
        XCTAssertFalse(ProjectPathNormalizer.isTemporary("/Users/sample/Projects/demo-app", home: home))
        XCTAssertFalse(ProjectPathNormalizer.isTemporary("/private/tmpfolder", home: home))
        XCTAssertEqual(ProjectPathNormalizer.codexWorktreeRepository(
            "/Users/sample/.codex/worktrees/a1b2/demo-app", home: home), "demo-app")
        XCTAssertNil(ProjectPathNormalizer.codexWorktreeRepository("/Users/sample/Projects/demo-app", home: home))
        XCTAssertEqual(ProjectPathNormalizer.name(of: "/Users/sample/Projects/demo-app"), "demo-app")
        XCTAssertEqual(ProjectPathNormalizer.name(of: "/"), "/")
    }

    /// A repository URL can carry a token or `user@host`: only its hash is
    /// ever kept.
    func testARepositoryURLIsKeptOnlyAsAHash() throws {
        let url = "https://x-access-token:secret-123@github.example/sample/demo-app.git"
        let hash = try XCTUnwrap(ProjectPathNormalizer.repositoryHash(url))
        XCTAssertEqual(hash.count, 64)
        XCTAssertNil(hash.range(of: "secret"))
        XCTAssertEqual(hash, ProjectPathNormalizer.repositoryHash(url), "the same URL hashes the same")
        XCTAssertNotEqual(hash, ProjectPathNormalizer.repositoryHash("https://github.example/sample/other.git"))
        XCTAssertNil(ProjectPathNormalizer.repositoryHash(nil))
        XCTAssertNil(ProjectPathNormalizer.repositoryHash(" "))
    }
}
