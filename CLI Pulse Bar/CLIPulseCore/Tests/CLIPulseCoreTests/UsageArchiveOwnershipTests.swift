import XCTest
@testable import CLIPulseCore

/// Two defects in the usage-activity heatmap archive, pinned together because
/// they share a cause: `AppState.usageArchive` is account-scoped data behind a
/// five-minute cache, and it had no owner.
///
/// 1. Demo mode showed a fully populated dashboard with one empty card. The
///    archive fetch ran unauthenticated, returned nothing, and the heatmap fell
///    back to its scope caption — visible in the 1.53.0 App Store screenshot.
///
/// 2. `applySignedOutState` resets every other piece of account state so "a
///    different account signing in on the same device doesn't briefly inherit
///    the previous user's" data, but the archive (added later, v1.41) was never
///    added to that list. A sign-out and a different sign-in inside the TTL
///    showed the first account's heatmap — and since an empty fetch
///    deliberately keeps the previous archive, possibly for much longer.
///
/// Fixing (1) naively makes (2) worse — Demo would become one more owner whose
/// days leak into the next account — which is why the fix is ownership, not a
/// demo branch alone.
@MainActor
final class UsageArchiveOwnershipTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "UsageArchiveOwnershipTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    /// Isolated defaults, so `isDemoMode` (an @AppStorage key) never touches the
    /// real app's domain; no launch setup, so no Keychain or helper side effects.
    /// The default APIClient has no user, so `fetchDailyUsage` returns [] without
    /// a network call — which is exactly the "empty fetch" case that matters here.
    private func makeState() -> AppState {
        AppState(
            runtimeEnvironment: .resolveForTesting(infoDictionary: [:], environment: [:]),
            defaults: defaults,
            performLaunchSetup: false)
    }

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private let fixedToday = Date(timeIntervalSince1970: 1_789_000_000)   // a fixed instant

    private func someAccountArchive() -> DailyUsageArchive {
        var a = DailyUsageArchive()
        a.mergeCloudDays([CloudEntry(date: DailyUsageStats.localDayKey(), provider: "Claude",
                                     model: "m", inputTokens: 7_777, cachedTokens: 0,
                                     outputTokens: 0, cost: 1)])
        return a
    }

    // MARK: - The demo series

    func testDemoDailyUsageIsDeterministic() {
        let a = DemoDataProvider.dailyUsage(days: 365, today: fixedToday, calendar: utc)
        let b = DemoDataProvider.dailyUsage(days: 365, today: fixedToday, calendar: utc)
        XCTAssertEqual(a, b, "screenshots and tests need the same demo heatmap every time")
        XCTAssertFalse(a.isEmpty)
    }

    func testDemoTodayMatchesTheDashboardFixture() {
        let key = DailyUsageStats.localDayKey(fixedToday, calendar: utc)
        let todayRows = DemoDataProvider.dailyUsage(days: 365, today: fixedToday, calendar: utc)
            .filter { $0.date == key }
        var byProvider: [String: Int] = [:]
        for r in todayRows { byProvider[r.provider, default: 0] += r.inputTokens + r.cachedTokens + r.outputTokens }

        let fixture = DemoDataProvider.generate().providers
        for p in fixture {
            XCTAssertEqual(byProvider[p.provider], p.today_usage,
                           "heatmap today cell must agree with the Usage Today tile for \(p.provider)")
        }
    }

    func testDemoSeriesLooksLikeAYearOfUseNotAWall() {
        var archive = DailyUsageArchive()
        archive.mergeCloudDays(DemoDataProvider.dailyUsage(days: 365, today: fixedToday, calendar: utc))
        let active = archive.days.values.filter { $0.tokens > 0 }.count
        XCTAssertGreaterThan(active, 180, "too sparse to read as a habit")
        XCTAssertLessThan(active, 340, "no idle days at all reads as fabricated")

        var weekday = [Int](), weekend = [Int]()
        for (key, day) in archive.days {
            guard let w = DailyUsageStats.weekdayIndex(key) else { continue }
            (w == 0 || w == 6 ? { weekend.append(day.tokens) } : { weekday.append(day.tokens) })()
        }
        let avg = { (xs: [Int]) in xs.isEmpty ? 0 : Double(xs.reduce(0, +)) / Double(xs.count) }
        XCTAssertLessThan(avg(weekend), avg(weekday), "weekends should be quieter than weekdays")
    }

    // MARK: - Demo fills the card

    func testDemoModeFillsTheHeatmapArchive() async {
        let state = makeState()
        state.isDemoMode = true

        await state.refreshUsageArchive()

        XCTAssertGreaterThan(state.usageArchive.days.count, 150)
        XCTAssertEqual(state.usageArchiveOwner, AppState.demoUsageArchiveOwner)
    }

    // MARK: - Ownership

    /// The case the ownership exists for: leave Demo and sign in within the TTL.
    /// Without the owner check the cached demo days are returned as-is, and the
    /// real account's (empty) fetch would not replace them either.
    func testLeavingDemoWithinTTLNeverShowsDemoDays() async {
        let state = makeState()
        state.isDemoMode = true
        await state.refreshUsageArchive()
        XCTAssertFalse(state.usageArchive.days.isEmpty, "precondition: demo archive built")

        state.isDemoMode = false
        state.userId = "acct-real"
        await state.refreshUsageArchive()   // not forced: inside the TTL

        XCTAssertTrue(state.usageArchive.days.isEmpty,
                      "a real account must never see Demo's sample days")
        XCTAssertEqual(state.usageArchiveOwner, "acct-real")
    }

    /// The pre-existing leak, independent of Demo: account A's archive is cached,
    /// account B signs in inside the TTL.
    func testAccountSwitchWithinTTLDropsThePreviousAccountsDays() async {
        let state = makeState()
        state.userId = "acct-A"
        state.adoptUsageArchive(someAccountArchive(), owner: "acct-A")

        state.userId = "acct-B"
        await state.refreshUsageArchive()

        XCTAssertTrue(state.usageArchive.days.isEmpty, "account B must not see account A's heatmap")
        XCTAssertEqual(state.usageArchiveOwner, "acct-B")
    }

    /// The documented behaviour that must survive: for the SAME account, a
    /// failed or empty fetch keeps the archive rather than blanking the card.
    func testSameOwnerEmptyFetchStillKeepsTheArchive() async {
        let state = makeState()
        state.userId = "acct-A"
        let archive = someAccountArchive()
        state.adoptUsageArchive(archive, owner: "acct-A")

        await state.refreshUsageArchive(force: true)   // bypass TTL; fetch returns []

        XCTAssertEqual(state.usageArchive, archive)
    }

    func testSignOutClearsTheArchive() {
        let state = makeState()
        state.userId = "acct-A"
        state.adoptUsageArchive(someAccountArchive(), owner: "acct-A")

        state.applySignedOutState()

        XCTAssertTrue(state.usageArchive.days.isEmpty)
        XCTAssertNil(state.usageArchiveOwner)
    }
}
