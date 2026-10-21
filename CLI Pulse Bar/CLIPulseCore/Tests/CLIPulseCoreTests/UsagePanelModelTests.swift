#if os(macOS)
import AppKit
import Combine
import XCTest
@testable import CLIPulseCore

/// v1.57 (P1-2): the slide-out panel's data stays live.
///
/// D11: the panel was handed the archive snapshot it opened with and never
/// read it again, so a panel left open across a refresh showed old figures.
/// The provider mode reads the refresh's scan, not only the archive.
@MainActor
final class UsagePanelModelTests: XCTestCase {

    private actor ArchiveSource {
        var archive: DailyUsageArchive
        var reads = 0
        init(_ archive: DailyUsageArchive) { self.archive = archive }
        func set(_ archive: DailyUsageArchive) { self.archive = archive }
        func read() -> DailyUsageArchive { reads += 1; return archive }
    }

    private nonisolated static func archive(tokens: Int) -> DailyUsageArchive {
        DailyUsageArchive(days: ["2026-10-06": DayRollup(tokens: tokens)])
    }

    private func entry(_ date: String, _ provider: String, tokens: Int, cost: Double?) -> CostUsageScanResult.DailyEntry {
        .init(date: date, provider: provider, model: "m", inputTokens: tokens, cachedTokens: 0,
              outputTokens: 0, costUSD: cost)
    }

    private let fixedNow: () -> Date = {
        DayKey.date(from: "2026-10-07", hour: 12) ?? Date()
    }

    func testTheArchiveIsReadAgainWhenItIsWritten() async {
        let center = NotificationCenter()
        let source = ArchiveSource(Self.archive(tokens: 1))
        let model = UsagePanelModel(notificationCenter: center, loadArchive: { await source.read() })
        model.seed(archive: Self.archive(tokens: 1), readStartedAt: model.reloadGeneration)

        await source.set(Self.archive(tokens: 2))
        center.post(name: .dailyUsageArchiveDidChange, object: nil)
        // The notification is delivered on the main run loop.
        for _ in 0..<50 where model.archive?.days["2026-10-06"]?.tokens != 2 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            await model.settle()
        }
        XCTAssertEqual(model.archive?.days["2026-10-06"]?.tokens, 2, "the open panel shows the new figures")
        let reads = await source.reads
        XCTAssertGreaterThanOrEqual(reads, 1)
    }

    /// A loader whose first read waits until `open()`, so a test decides
    /// when the older read finishes instead of racing a timer. Later reads
    /// return at once.
    private actor Gate {
        private var entered = 0
        private var isOpen = false
        private var release: CheckedContinuation<Void, Never>?
        private var entryWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

        /// The read's number: 1 for the first.
        func read() async -> Int {
            entered += 1
            let number = entered
            let ready = entryWaiters.filter { $0.count <= entered }
            entryWaiters.removeAll { $0.count <= entered }
            ready.forEach { $0.continuation.resume() }
            if number == 1, !isOpen {
                await withCheckedContinuation { release = $0 }
            }
            return number
        }

        func waitUntilEntered(_ count: Int) async {
            guard entered < count else { return }
            await withCheckedContinuation { entryWaiters.append((count, $0)) }
        }

        func open() {
            isOpen = true
            release?.resume()
            release = nil
        }
    }

    /// The first read sees the old archive and finishes last; the second,
    /// started after the archive changed, finishes first. The newer stands.
    func testAnOlderReadThatFinishesLastDoesNotWin() async {
        let gate = Gate()
        let model = UsagePanelModel(notificationCenter: NotificationCenter(), loadArchive: {
            Self.archive(tokens: await gate.read() == 1 ? 1 : 3)
        })
        model.reloadArchive()
        let older = model.currentReloadTask
        await gate.waitUntilEntered(1)
        model.reloadArchive()
        await model.settle()
        XCTAssertEqual(model.archive?.days["2026-10-06"]?.tokens, 3)

        await gate.open()
        await older?.value
        XCTAssertEqual(model.archive?.days["2026-10-06"]?.tokens, 3, "the newer read stands")
    }

    /// The archive the panel opens with is read after any reload still in
    /// flight from before it was shown; that reload must not replace it.
    func testAReloadFromBeforeTheSeedDoesNotReplaceIt() async {
        let gate = Gate()
        let model = UsagePanelModel(notificationCenter: NotificationCenter(), loadArchive: {
            _ = await gate.read()
            return Self.archive(tokens: 1)
        })
        model.reloadArchive()
        let older = model.currentReloadTask
        await gate.waitUntilEntered(1)
        // The seed's read began after that reload started.
        model.seed(archive: Self.archive(tokens: 5), readStartedAt: model.reloadGeneration)

        await gate.open()
        await older?.value
        XCTAssertEqual(model.archive?.days["2026-10-06"]?.tokens, 5, "the seed stands")
    }

    /// The archive is written while the seed's read is under way, so a
    /// reload starts after it began. That reload is newer: the seed stands
    /// in for an older archive while it runs, and does not cancel it.
    func testAReloadStartedDuringTheSeedsReadIsNotCancelled() async {
        let gate = Gate()
        let model = UsagePanelModel(notificationCenter: NotificationCenter(), loadArchive: {
            _ = await gate.read()
            return Self.archive(tokens: 7)
        })
        // What an earlier opening of the panel left.
        model.seed(archive: Self.archive(tokens: 1), readStartedAt: model.reloadGeneration)

        let readStartedAt = model.reloadGeneration
        model.reloadArchive()   // the write's notification, during the read
        let newer = model.currentReloadTask
        await gate.waitUntilEntered(1)
        model.seed(archive: Self.archive(tokens: 5), readStartedAt: readStartedAt)
        XCTAssertEqual(model.archive?.days["2026-10-06"]?.tokens, 5, "the seed replaces the older archive")

        await gate.open()
        await newer?.value
        XCTAssertEqual(model.archive?.days["2026-10-06"]?.tokens, 7, "the newer reload lands")
    }

    /// The same, with the newer reload already finished when the seed's read
    /// returns: the seed is the older of the two and is dropped.
    func testASeedOlderThanAFinishedReloadIsDropped() async {
        let model = UsagePanelModel(notificationCenter: NotificationCenter(), loadArchive: {
            Self.archive(tokens: 7)
        })
        let readStartedAt = model.reloadGeneration
        model.reloadArchive()
        await model.settle()
        model.seed(archive: Self.archive(tokens: 5), readStartedAt: readStartedAt)
        XCTAssertEqual(model.archive?.days["2026-10-06"]?.tokens, 7, "the newer reload stands")
    }

    /// The grant-access state names the Codex and Claude log folders, so it
    /// is only for those two: a provider the scan never reads (Gemini) gets
    /// "no usage", whatever macOS blocks.
    func testOnlyTheScannedProvidersAskForTheLogFolders() {
        XCTAssertTrue(ProviderUsagePanelView.asksForFolderAccess(provider: "Codex", scope: .thisMac, needsFolderAccess: true))
        XCTAssertTrue(ProviderUsagePanelView.asksForFolderAccess(provider: "Claude", scope: .thisMac, needsFolderAccess: true))
        XCTAssertFalse(ProviderUsagePanelView.asksForFolderAccess(provider: "Gemini", scope: .thisMac, needsFolderAccess: true))
        XCTAssertFalse(ProviderUsagePanelView.asksForFolderAccess(provider: "Codex", scope: .allDevices, needsFolderAccess: true))
        XCTAssertFalse(ProviderUsagePanelView.asksForFolderAccess(provider: "Codex", scope: .thisMac, needsFolderAccess: false))
    }

    func testTheProviderModeFollowsTheScan() {
        let scan = CurrentValueSubject<CostUsageScanResult?, Never>(nil)
        let cloud = CurrentValueSubject<[DailyUsage], Never>([])
        let folder = CurrentValueSubject<Bool, Never>(false)
        let model = UsagePanelModel(notificationCenter: NotificationCenter(), now: fixedNow, loadArchive: { DailyUsageArchive() })
        model.follow(scan: scan.eraseToAnyPublisher(), cloud: cloud.eraseToAnyPublisher(),
                     needsFolderAccess: folder.eraseToAnyPublisher())

        XCTAssertFalse(model.days(for: "Codex", in: .thisMac).hasUsage)
        scan.send(CostUsageScanResult(entries: [entry("2026-10-06", "Codex", tokens: 500, cost: 1.5)]))
        let days = model.days(for: "Codex", in: .thisMac)
        XCTAssertEqual(days.day("2026-10-06")?.tokens, 500)
        XCTAssertEqual(days.scope, .thisMac)

        // A later refresh replaces it.
        scan.send(CostUsageScanResult(entries: [entry("2026-10-06", "Codex", tokens: 800, cost: 2)]))
        XCTAssertEqual(model.days(for: "Codex", in: .thisMac).day("2026-10-06")?.tokens, 800)

        folder.send(true)
        XCTAssertTrue(model.needsFolderAccess)
    }

    /// v1.58: and its rows by project, every provider's, which the provider
    /// mode's Projects card lists; a refresh replaces them, and a scan that
    /// is gone takes them with it.
    func testTheProviderModeFollowsTheScansProjects() {
        let scan = CurrentValueSubject<CostUsageScanResult?, Never>(nil)
        let model = UsagePanelModel(notificationCenter: NotificationCenter(), now: fixedNow, loadArchive: { DailyUsageArchive() })
        model.follow(scan: scan.eraseToAnyPublisher(), cloud: Just([]).eraseToAnyPublisher(),
                     needsFolderAccess: Just(false).eraseToAnyPublisher())
        XCTAssertTrue(model.scanProjects.isEmpty)

        let project = ProjectIdentity.folder("/Users/sample/Projects/demo-app")
        func split(_ tokens: Int, _ provider: String) -> CostUsageScanResult.ProjectEntry {
            .init(provider: provider, project: project, date: "2026-10-06", model: "m",
                  inputTokens: tokens, cachedTokens: 0, outputTokens: 0, costUSD: 1)
        }
        scan.send(CostUsageScanResult(entries: [], projects: [split(500, "Codex"), split(70, "Claude")]))
        XCTAssertEqual(model.scanProjects.map(\.inputTokens), [500, 70])
        scan.send(CostUsageScanResult(entries: [], projects: [split(800, "Codex")]))
        XCTAssertEqual(model.scanProjects.map(\.inputTokens), [800])
        scan.send(nil)
        XCTAssertTrue(model.scanProjects.isEmpty)
    }

    func testThisMacIsShownFirstAndAPickedScopeIsKept() {
        let scan = CurrentValueSubject<CostUsageScanResult?, Never>(
            CostUsageScanResult(entries: [entry("2026-10-06", "Codex", tokens: 500, cost: 1)]))
        let cloud = CurrentValueSubject<[DailyUsage], Never>([
            DailyUsage(date: "2026-10-06", provider: "Codex", model: "m", inputTokens: 900, cachedTokens: 0,
                       outputTokens: 0, cost: 2),
            DailyUsage(date: "2026-10-06", provider: "Gemini", model: "g", inputTokens: 10, cachedTokens: 0,
                       outputTokens: 0, cost: 0.1),
        ])
        let model = UsagePanelModel(notificationCenter: NotificationCenter(), now: fixedNow, loadArchive: { DailyUsageArchive() })
        model.follow(scan: scan.eraseToAnyPublisher(), cloud: cloud.eraseToAnyPublisher(),
                     needsFolderAccess: Just(false).eraseToAnyPublisher())

        XCTAssertEqual(model.availableScopes(for: "Codex"), [.thisMac, .allDevices])
        XCTAssertEqual(model.scope(for: "Codex"), .thisMac)
        model.scopeChoice["Codex"] = .allDevices
        XCTAssertEqual(model.scope(for: "Codex"), .allDevices)
        XCTAssertEqual(model.days(for: "Codex", in: .allDevices).totalTokens, 900)
        // A provider this Mac does not scan opens on the synced rows.
        XCTAssertEqual(model.scope(for: "Gemini"), .allDevices)
        // A pick with nothing left in it falls back.
        cloud.send([])
        XCTAssertEqual(model.scope(for: "Codex"), .thisMac)
    }

    /// v1.57: clicking a provider card's chart opens the panel on the scope
    /// the card's figures are labelled with (`prefer`), not the panel's own
    /// first choice, and the days shown are the days the card drew from.
    func testACardOpensThePanelOnTheScopeItNames() {
        let entries = [entry("2026-10-06", "Codex", tokens: 500, cost: 1)]
        let rows = [DailyUsage(date: "2026-10-06", provider: "Codex", model: "m", inputTokens: 900,
                               cachedTokens: 0, outputTokens: 0, cost: 2)]
        let cloud = CurrentValueSubject<[DailyUsage], Never>(rows)
        let model = UsagePanelModel(notificationCenter: NotificationCenter(), now: fixedNow, loadArchive: { DailyUsageArchive() })
        model.follow(scan: Just(CostUsageScanResult(entries: entries)).eraseToAnyPublisher(),
                     cloud: cloud.eraseToAnyPublisher(), needsFolderAccess: Just(false).eraseToAnyPublisher())
        let windows = ProviderUsageWindows(now: fixedNow())
        let signedIn = ProviderCardUsageBuilder.build(
            provider: "Codex", usage: nil, scanEntries: entries, cloudRows: rows, readsCloud: true, windows: windows)
        XCTAssertEqual(signedIn.scope, .allDevices)
        XCTAssertEqual(model.scope(for: "Codex"), .thisMac, "the panel on its own starts on This Mac")

        model.prefer(signedIn.scope, for: "Codex")
        XCTAssertEqual(model.scope(for: "Codex"), .allDevices)
        let shown = model.days(for: "Codex", in: model.scope(for: "Codex"))
        let bars = signedIn.chartDays(.cost)
        XCTAssertEqual(shown.days.map(\.dateKey), bars.map(\.dateKey))
        XCTAssertEqual(shown.day("2026-10-06")?.cost, bars.first { $0.dateKey == "2026-10-06" }?.cost)
        XCTAssertEqual(shown.day("2026-10-06")?.tokens, 900)

        // Signed out, the card names This Mac, and the panel follows it.
        let signedOut = ProviderCardUsageBuilder.build(
            provider: "Codex", usage: nil, scanEntries: entries, cloudRows: rows, readsCloud: false, windows: windows)
        model.prefer(signedOut.scope, for: "Codex")
        XCTAssertEqual(model.scope(for: "Codex"), .thisMac)
        // A scope with nothing in it is not kept: the panel shows the one
        // that has usage.
        model.prefer(.allDevices, for: "Codex")
        cloud.send([])
        XCTAssertEqual(model.scope(for: "Codex"), .thisMac)
    }

    /// A provider card opens the panel counting tokens as the card does
    /// (input + output), so the panel's total is the card's 30 Days; the
    /// Usage Dashboard's rows open it counting each token once, as the
    /// dashboard does. Claude's cache tells the two apart.
    func testACardOpensThePanelCountingAsTheCardCounts() {
        let entries = [CostUsageScanResult.DailyEntry(
            date: "2026-10-06", provider: "Claude", model: "m",
            inputTokens: 1_000, cachedTokens: 9_000, outputTokens: 200, costUSD: 2)]
        let model = UsagePanelModel(notificationCenter: NotificationCenter(), now: fixedNow, loadArchive: { DailyUsageArchive() })
        model.follow(scan: Just(CostUsageScanResult(entries: entries)).eraseToAnyPublisher(),
                     cloud: Just([DailyUsage]()).eraseToAnyPublisher(), needsFolderAccess: Just(false).eraseToAnyPublisher())
        XCTAssertEqual(model.providerBasis, .eachOnce)
        let eachOnce = model.days(for: "Claude", in: .thisMac)
        XCTAssertEqual(eachOnce.totalTokens, 10_200, "each once: input, cache and output")

        let card = ProviderCardUsageBuilder.build(
            provider: "Claude", usage: nil, scanEntries: entries, cloudRows: [], readsCloud: false,
            windows: ProviderUsageWindows(now: fixedNow()))
        model.open("Claude", scope: card.scope, basis: ProviderCardUsage.tokenBasis)
        let shown = model.days(for: "Claude", in: model.scope(for: "Claude"))
        XCTAssertEqual(shown.basis, .inputOutput)
        XCTAssertEqual(shown.totalTokens, card.thirtyDays.ioTokens, "the panel's total is the card's 30 Days")
        XCTAssertEqual(shown.totalTokens, 1_200)
        XCTAssertEqual(shown.totalCost, card.thirtyDays.cost ?? -1, accuracy: 0.0001)

        // The total names the count it is in: Spanish says E/S.
        let saved = LocaleOverrideStore.shared.override
        defer { LocaleOverrideStore.shared.set(saved) }
        LocaleOverrideStore.shared.set("es")
        XCTAssertTrue(shown.totalValueText.hasSuffix(" tokens de E/S"), shown.totalValueText)
        XCTAssertTrue(eachOnce.totalValueText.hasSuffix(" tokens"), eachOnce.totalValueText)
        XCTAssertFalse(eachOnce.totalValueText.contains("E/S"))
    }

    func testTheCardOffersTheHistoryOnlyWhenThereIsUsage() {
        let now = fixedNow()
        let scan = CostUsageScanResult(entries: [entry("2026-10-06", "Claude", tokens: 10, cost: nil)])
        XCTAssertTrue(UsagePanelModel.hasHistory(provider: "Claude", scan: scan, cloud: [], now: now))
        XCTAssertFalse(UsagePanelModel.hasHistory(provider: "Codex", scan: scan, cloud: [], now: now))
        // Older than the window.
        let old = CostUsageScanResult(entries: [entry("2026-08-01", "Codex", tokens: 10, cost: 1)])
        XCTAssertFalse(UsagePanelModel.hasHistory(provider: "Codex", scan: old, cloud: [], now: now))
        let cloud = [DailyUsage(date: "2026-10-01", provider: "Gemini", model: "g", inputTokens: 10,
                                cachedTokens: 0, outputTokens: 0, cost: 0)]
        XCTAssertTrue(UsagePanelModel.hasHistory(provider: "Gemini", scan: nil, cloud: cloud, now: now))
    }

    func testThePanelGrowsDownFromItsTopAndStaysOnScreen() {
        let frame = NSRect(x: 100, y: 300, width: 480, height: 500)   // top at 800
        let taller = DashboardPanelController.frame(fitting: 600, in: frame, top: 800, screenBottom: 0)
        XCTAssertEqual(taller, NSRect(x: 100, y: 200, width: 480, height: 600))
        let shorter = DashboardPanelController.frame(fitting: 300, in: frame, top: 800, screenBottom: 0)
        XCTAssertEqual(shorter.maxY, 800)
        XCTAssertEqual(shorter.height, 300)
        // Taller than the room below the top: the bottom stays on screen.
        let clamped = DashboardPanelController.frame(fitting: 700, in: frame, top: 800, screenBottom: 150)
        XCTAssertEqual(clamped.minY, 150)
        XCTAssertEqual(clamped.height, 700)
    }
}
#endif
