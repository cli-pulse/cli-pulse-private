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
        model.seed(archive: Self.archive(tokens: 1))

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

    private actor Calls {
        var count = 0
        func next() -> Int { count += 1; return count }
    }

    func testAnOlderReadThatFinishesLastDoesNotWin() async {
        let calls = Calls()
        let model = UsagePanelModel(notificationCenter: NotificationCenter(), loadArchive: {
            // The first read is slow and sees the old archive; the second,
            // started after the archive changed, is quick.
            if await calls.next() == 1 {
                try? await Task.sleep(nanoseconds: 300_000_000)
                return Self.archive(tokens: 1)
            }
            return Self.archive(tokens: 3)
        })
        model.reloadArchive()
        try? await Task.sleep(nanoseconds: 20_000_000)
        model.reloadArchive()
        try? await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(model.archive?.days["2026-10-06"]?.tokens, 3, "the newer read stands")
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
