#if os(macOS)
import XCTest
@testable import CLIPulseCore

/// 1.59 (59-16): the Mac App Store build asks for a rating on the third day a
/// provider card has shown a cost, never in the first session, at most once a
/// version, and the Developer ID build never asks (`MacReviewPrompt`).
@MainActor
final class MacReviewPromptTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "MacReviewPromptTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    private func prompt(
        version: String = "1.59.0", firstSession: Bool = false, appStore: Bool = true
    ) -> MacReviewPrompt {
        let prompt = MacReviewPrompt(defaults: defaults)
        prompt.begin(appVersion: version, isFirstSession: firstSession, isAppStoreBuild: appStore)
        return prompt
    }

    // MARK: - The rule, through the store

    func testAsksOnTheThirdDayWithACost() {
        let p = prompt()
        XCTAssertFalse(p.costShown(onDay: "2026-11-02"))
        XCTAssertFalse(p.costShown(onDay: "2026-11-02"), "the same day again is still one day")
        XCTAssertFalse(p.costShown(onDay: "2026-11-05"))
        XCTAssertEqual(p.costDays, ["2026-11-02", "2026-11-05"])
        XCTAssertTrue(p.costShown(onDay: "2026-11-09"), "the third different day asks")
        XCTAssertEqual(defaults.string(forKey: MacReviewPrompt.askedVersionKey), "1.59.0")
    }

    func testAsksAtMostOnceAVersion() {
        let p = prompt()
        for day in ["2026-11-01", "2026-11-02"] { p.costShown(onDay: day) }
        XCTAssertTrue(p.costShown(onDay: "2026-11-03"))
        XCTAssertFalse(p.costShown(onDay: "2026-11-03"))
        XCTAssertFalse(p.costShown(onDay: "2026-11-04"), "a later day of the same version does not ask again")

        // A relaunch of the same version: still asked.
        XCTAssertFalse(prompt().costShown(onDay: "2026-11-05"))

        // The next version, its days already counted: it asks once more, once.
        let next = prompt(version: "1.60.0")
        XCTAssertTrue(next.costShown(onDay: "2026-12-01"))
        XCTAssertFalse(next.costShown(onDay: "2026-12-02"))
    }

    func testNeverInTheFirstSession() {
        let first = prompt(firstSession: true)
        for day in ["2026-11-01", "2026-11-02", "2026-11-03", "2026-11-04", "2026-11-05"] {
            XCTAssertFalse(first.costShown(onDay: day), "the first session never asks, however long it runs")
        }
        XCTAssertNil(defaults.string(forKey: MacReviewPrompt.askedVersionKey), "nothing recorded as asked")
        XCTAssertEqual(first.costDays.count, 5, "its days still count")

        // The next launch is not the first session: the days it already has ask.
        XCTAssertTrue(prompt().costShown(onDay: "2026-11-06"))
    }

    func testTheDeveloperIDBuildNeverAsksAndWritesNothing() {
        let p = prompt(appStore: false)
        for day in ["2026-11-01", "2026-11-02", "2026-11-03", "2026-11-04"] {
            XCTAssertFalse(p.costShown(onDay: day))
        }
        XCTAssertNil(defaults.object(forKey: MacReviewPrompt.costDaysKey))
        XCTAssertNil(defaults.object(forKey: MacReviewPrompt.askedVersionKey))
    }

    /// Before the app calls `begin` at launch, nothing asks and nothing is written.
    func testWithoutBeginItNeverAsks() {
        let p = MacReviewPrompt(defaults: defaults)
        for day in ["2026-11-01", "2026-11-02", "2026-11-03"] {
            XCTAssertFalse(p.costShown(onDay: day))
        }
        XCTAssertNil(defaults.object(forKey: MacReviewPrompt.costDaysKey))
    }

    func testOnlyTheLatestDaysAreKept() {
        let p = prompt(appStore: true)
        let days = (1...14).map { DayKey.string(year: 2026, month: 11, day: $0) }
        for day in days { p.costShown(onDay: day) }
        XCTAssertEqual(p.costDays, Array(days.suffix(MacReviewPrompt.keptDays)))
    }

    // MARK: - The rule itself

    func testThePolicyTable() {
        typealias P = MacReviewPromptPolicy
        XCTAssertEqual(P.costDaysNeeded, 3)
        for days in 0...5 {
            XCTAssertEqual(
                P.shouldAsk(costDays: days, askedVersion: nil, appVersion: "1.59.0",
                            isFirstSession: false, isAppStoreBuild: true),
                days >= 3, "\(days) days")
        }
        XCTAssertFalse(P.shouldAsk(costDays: 9, askedVersion: nil, appVersion: "1.59.0",
                                   isFirstSession: true, isAppStoreBuild: true), "first session")
        XCTAssertFalse(P.shouldAsk(costDays: 9, askedVersion: nil, appVersion: "1.59.0",
                                   isFirstSession: false, isAppStoreBuild: false), "not the App Store build")
        XCTAssertFalse(P.shouldAsk(costDays: 9, askedVersion: "1.59.0", appVersion: "1.59.0",
                                   isFirstSession: false, isAppStoreBuild: true), "this version asked")
        XCTAssertTrue(P.shouldAsk(costDays: 9, askedVersion: "1.58.0", appVersion: "1.59.0",
                                  isFirstSession: false, isAppStoreBuild: true), "an older version asked")
        XCTAssertFalse(P.shouldAsk(costDays: 9, askedVersion: nil, appVersion: "",
                                   isFirstSession: false, isAppStoreBuild: true), "no version read")
    }

    /// The App Store build in production only. Under `-DDEVID_BUILD` (CI's
    /// Developer ID pass) every answer is false, whatever the run time says.
    func testOnlyTheAppStoreBuildInProductionAsks() {
        for distribution in DistributionChannel.allCases {
            for runtime in [CLIPulseRuntimeEnvironment.Channel.production, .qa] {
                let expected: Bool
                #if DEVID_BUILD
                expected = false
                #else
                expected = runtime == .production && distribution == .mas
                #endif
                XCTAssertEqual(
                    MacReviewPromptPolicy.isAppStoreBuild(runtimeChannel: runtime, distribution: distribution),
                    expected, "\(runtime) \(distribution)")
            }
        }
    }

    // MARK: - What counts as a cost shown

    private func card(today: Double?, week: Double?, thirty: Double?) -> ProviderCardUsage {
        func cell(_ cost: Double?) -> ProviderCardUsage.Cell {
            ProviderCardUsage.Cell(cost: cost, costIsApproximate: false, ioTokens: 1_000, messages: nil)
        }
        return ProviderCardUsageBuilder.build(
            provider: "Codex", usage: nil, scanEntries: [], cloudRows: [], readsCloud: false)
            .with(today: cell(today), week: cell(week), thirty: cell(thirty))
    }

    func testACardShowsACostOnlyWhenOneAboveZeroIsDrawn() {
        typealias P = MacReviewPromptPolicy
        let costly = card(today: nil, week: 0, thirty: 4.2)
        XCTAssertTrue(P.cardShowsCost(costly, showsCost: true, totalsVisible: true, isDemoMode: false))
        XCTAssertTrue(P.cardShowsCost(card(today: 0.01, week: nil, thirty: nil),
                                      showsCost: true, totalsVisible: true, isDemoMode: false))
        XCTAssertFalse(P.cardShowsCost(costly, showsCost: false, totalsVisible: true, isDemoMode: false),
                       "costs switched off")
        XCTAssertFalse(P.cardShowsCost(costly, showsCost: true, totalsVisible: false, isDemoMode: false),
                       "the card's usage figures hidden")
        XCTAssertFalse(P.cardShowsCost(costly, showsCost: true, totalsVisible: true, isDemoMode: true),
                       "Try Demo")
        XCTAssertFalse(P.cardShowsCost(card(today: 0, week: 0, thirty: 0),
                                       showsCost: true, totalsVisible: true, isDemoMode: false), "$0.00")
        XCTAssertFalse(P.cardShowsCost(card(today: nil, week: nil, thirty: nil),
                                       showsCost: true, totalsVisible: true, isDemoMode: false), "a dash")
    }

    // MARK: - Keys and wiring

    /// Both keys survive the App Store -> Developer ID move like every other
    /// app key (the migration copies only these prefixes).
    func testTheKeysCarryTheAppOwnedPrefix() {
        for key in [MacReviewPrompt.costDaysKey, MacReviewPrompt.askedVersionKey] {
            XCTAssertTrue(UnsandboxedDataMigration.appOwnedKeyPrefixes.contains { key.hasPrefix($0) }, key)
        }
    }

    /// The app begins the prompt in `init`, after the first-run check (which
    /// must read the defaults before anything writes them) and before
    /// `AppState`; a provider card's usage row reports a cost through the
    /// modifier; and that modifier is the only place in the apps that asks
    /// for a rating.
    func testTheAppBeginsThePromptAndOnlyTheCardAsks() throws {
        let app = try Self.code(at: "CLI Pulse Bar/CLIPulseBarApp.swift")
        let firstRun = try XCTUnwrap(app.range(of: "self.firstRunWelcome = firstRunWelcome"))
        let begin = try XCTUnwrap(app.range(of: "MacReviewPrompt.shared.begin("))
        let appState = try XCTUnwrap(app.range(of: "let state = AppState(runtimeEnvironment: runtimeEnvironment)"))
        XCTAssertTrue(firstRun.upperBound <= begin.lowerBound, "begin must come after the first-run check")
        XCTAssertTrue(begin.upperBound <= appState.lowerBound, "begin must come before AppState")
        XCTAssertNotNil(app.range(of: "isFirstSession: firstRunWelcome || !runtimeEnvironment.isLaunchSafe"))

        let tab = try Self.code(at: "CLI Pulse Bar/ProvidersTab.swift")
        let section = try XCTUnwrap(tab.range(of: "                usageSection(\n"))
        let modifier = try XCTUnwrap(tab.range(of: ".modifier(ReviewPromptOnCostShown(showsCost: MacReviewPromptPolicy.cardShowsCost("))
        XCTAssertTrue(section.upperBound <= modifier.lowerBound)
        XCTAssertNotNil(tab.range(of: "isDemoMode: state.isDemoMode)))"))
        XCTAssertNotNil(tab.range(of: "guard shows, MacReviewPrompt.shared.costShown(onDay: DayKey.string(from: Date())) else { return }"))

        // One caller of the rating prompt across the app and the package.
        var callers: [String] = []
        for folder in [
            "CLI Pulse Bar", "CLI Pulse Bar iOS", "CLI Pulse Bar Watch", "CLI Pulse Widgets",
            "CLIPulseHelper", "CLIPulseCore/Sources",
        ] {
            let root = Self.projectRoot.appendingPathComponent(folder)
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
            for file in files {
                let text = Self.withoutComments(try String(contentsOf: file, encoding: .utf8))
                if text.contains("requestReview(") || text.contains("SKStoreReviewController") {
                    callers.append(folder + "/" + file.lastPathComponent)
                }
            }
        }
        XCTAssertEqual(callers, ["CLI Pulse Bar/ProvidersTab.swift"])
    }

    private static var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // CLIPulseCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // CLIPulseCore
            .deletingLastPathComponent()  // CLI Pulse Bar
    }

    /// A source file with its `//` comments removed, so a comment cannot
    /// satisfy or break a check.
    private static func code(at relativePath: String) throws -> String {
        withoutComments(try String(contentsOf: projectRoot.appendingPathComponent(relativePath), encoding: .utf8))
    }

    private static func withoutComments(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                var quotes = 0
                var previous: Character = " "
                for index in line.indices {
                    let character = line[index]
                    if character == "\"" { quotes += 1 }
                    if character == "/", previous == "/", quotes % 2 == 0 {
                        return line[line.startIndex..<line.index(before: index)]
                    }
                    previous = character
                }
                return line
            }
            .joined(separator: "\n")
    }
}

private extension ProviderCardUsage {
    func with(today: Cell, week: Cell, thirty: Cell) -> ProviderCardUsage {
        ProviderCardUsage(today: today, week: week, thirtyDays: thirty,
                          thisMac: thisMac, account: account, scope: scope)
    }
}
#endif
