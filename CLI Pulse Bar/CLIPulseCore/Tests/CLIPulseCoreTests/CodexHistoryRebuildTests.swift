// v1.56 (P0-17): the Codex days of the usage history older than the routine
// read, counted again under the current rules, in the archive and in this
// Mac's cloud rows. macOS-gated: the archive manager and the scanner are
// macOS-only.

#if os(macOS)
import XCTest
@testable import CLIPulseCore

final class CodexHistoryRebuildTests: XCTestCase {

    private typealias Entry = CostUsageScanResult.DailyEntry
    private typealias Row = CodexHistoryCloud.Row

    private var root: URL!
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-rebuild-\(UUID().uuidString)", isDirectory: true)
        suite = "codex-rebuild-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    /// The routine read at noon on this day starts on 2026-09-20.
    private static let today = "2026-10-20"
    private static let oldDay = "2026-06-01"

    private func noon(_ key: String) -> Date { DayKey.date(from: key, hour: 12)! }

    /// One read through the scanner seam: whose logs it asked for, and how far
    /// back.
    private struct Read: Equatable, Sendable {
        let providers: Set<ProviderKind>
        let days: Int
    }

    private actor ReadLog {
        private(set) var reads: [Read] = []
        func record(_ options: CostUsageScanner.Options) {
            reads.append(Read(providers: options.providers, days: options.daysToScan))
        }
    }

    /// A manager whose scanner seam answers like the scanner: the Codex rows
    /// only when Codex logs are asked for, the Claude rows only when Claude's
    /// are. The Claude rows are larger than anything stored, so a read that
    /// took them would show in Claude's slice.
    private func manager(
        today: String = CodexHistoryRebuildTests.today,
        rulesVersion: Int = 5,
        codexRead: [Entry] = [],
        claudeRead: [Entry] = [],
        log: ReadLog
    ) -> DailyUsageArchiveManager {
        let date = noon(today)
        return DailyUsageArchiveManager(
            root: root, defaults: defaults, backfillKey: "backfilled", now: { date },
            codexRulesVersion: rulesVersion,
            backfillScan: { options in
                await log.record(options)
                var entries: [Entry] = []
                if options.providers.contains(.codex) { entries += codexRead }
                if options.providers.contains(.claude) { entries += claudeRead }
                return CostUsageScanResult(entries: entries)
            })
    }

    /// What an earlier version left: each day with Claude's share (4,800
    /// tokens, 12 messages) and Codex's old figure, its cached input counted
    /// twice (17,100 tokens).
    private func previousVersionLeft(_ days: [String], claude: Bool = true, codex: Bool = true) {
        var entries: [ScanEntry] = []
        for day in days {
            if claude {
                entries.append(ScanEntry(date: day, provider: "Claude", model: "claude-sonnet-4-5",
                                         inputTokens: 500, cachedTokens: 4_000, outputTokens: 300,
                                         cost: 2.5, messages: 0))
                entries.append(ScanEntry(date: day, provider: "Claude", model: ScanEntry.messageBucketModel,
                                         inputTokens: 0, cachedTokens: 0, outputTokens: 0, cost: 0, messages: 12))
            }
            if codex {
                entries.append(ScanEntry(date: day, provider: "Codex", model: "gpt-5",
                                         inputTokens: 9_000, cachedTokens: 8_000, outputTokens: 100,
                                         cost: 0.9, messages: 0))
            }
        }
        var a = DailyUsageArchive()
        a.mergeScanEntries(entries)
        XCTAssertTrue(DailyUsageArchiveIO.save(a, root: root))
    }

    /// A Codex row as the scanner reports it: `input` includes `cached`.
    private static func codexRow(
        _ day: String, model: String = "gpt-5",
        input: Int = 9_000, cached: Int = 8_000, output: Int = 100, cost: Double = 1.7
    ) -> Entry {
        .init(date: day, provider: "Codex", model: model,
              inputTokens: input, cachedTokens: cached, outputTokens: output, costUSD: cost)
    }

    private static func claudeRow(_ day: String) -> Entry {
        .init(date: day, provider: "Claude", model: "claude-sonnet-4-5",
              inputTokens: 90_000, cachedTokens: 0, outputTokens: 9_000, costUSD: 40, messageCount: 99)
    }

    private func codexTokens(_ day: String, in archive: DailyUsageArchive) -> Int? {
        archive.days[day]?.perProvider["Codex"]?.tokens
    }

    private var state: CodexHistoryRebuild.State {
        .load(from: defaults, key: DailyUsageArchiveManager.defaultCodexHistoryRebuildKey)
    }

    private static func encoded<T: Encodable>(_ value: T?) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return value.flatMap { try? encoder.encode($0) }
    }

    // MARK: - The archive

    /// The point of the provider-scoped merge: on a day with both providers
    /// the rebuild takes the read's Codex slice, and Claude's share comes
    /// through exactly as stored, models and messages included. A whole-day
    /// replace (the routine read's `mergeScanEntries`) would drop it.
    func test_a_day_with_claude_and_codex_takes_the_new_codex_slice_and_keeps_claude_byte_for_byte() async throws {
        previousVersionLeft([Self.oldDay])
        let before = try XCTUnwrap(DailyUsageArchiveIO.load(root: root).days[Self.oldDay])
        XCTAssertEqual(before.perProvider["Codex"]?.tokens, 17_100, "control: the old figure")
        let log = ReadLog()
        let m = manager(
            codexRead: [Self.codexRow(Self.oldDay),
                        Self.codexRow(Self.oldDay, model: "gpt-5.6-luna", input: 2_000, cached: 1_500,
                                      output: 40, cost: 0.1)],
            claudeRead: [Self.claudeRow(Self.oldDay)],
            log: log)

        await m.rebuildCodexHistoryIfNeeded(historyReadAllowed: true, cloud: nil)

        let reads = await log.reads
        XCTAssertEqual(reads, [Read(providers: [.codex], days: LocalScanDisclosure.historyWindowDays)],
                       "the rebuild reads a year of Codex logs and nothing of Claude's")
        for archive in [await m.snapshot(), DailyUsageArchiveIO.load(root: root)] {
            let day = try XCTUnwrap(archive.days[Self.oldDay])
            XCTAssertEqual(Self.encoded(day.perProvider["Claude"]), Self.encoded(before.perProvider["Claude"]),
                           "Claude's slice changed")
            XCTAssertEqual(Self.encoded(day.perModel["claude-sonnet-4-5"]),
                           Self.encoded(before.perModel["claude-sonnet-4-5"]), "Claude's model changed")
            XCTAssertEqual(day.messages, 12)
            // Codex: each token once, from the read.
            XCTAssertEqual(day.perProvider["Codex"]?.tokens, 9_100 + 2_040)
            XCTAssertEqual(day.perProvider["Codex"]?.cost ?? 0, 1.8, accuracy: 1e-9)
            XCTAssertEqual(day.perModel["gpt-5"]?.tokens, 9_100)
            XCTAssertEqual(day.perModel["gpt-5.6-luna"]?.tokens, 2_040, "the subagent's model is new")
            XCTAssertEqual(day.tokens, 4_800 + 11_140)
            XCTAssertEqual(day.cost, 2.5 + 1.8, accuracy: 1e-9)
        }
        XCTAssertEqual(state.archiveRulesVersion, 5)
    }

    /// Only with a yes to older history. A refusal reads nothing, uploads
    /// nothing, and records nothing, so a later yes still finds the work.
    func test_without_a_yes_to_older_history_nothing_is_read_sent_or_recorded() async throws {
        previousVersionLeft([Self.oldDay])
        let log = ReadLog()
        let cloud = FakeCloud(rows: [Row(date: Self.oldDay, model: "gpt-5")])
        let m = manager(codexRead: [Self.codexRow(Self.oldDay)], log: log)

        await m.rebuildCodexHistoryIfNeeded(historyReadAllowed: false, cloud: cloud.cloud())

        var reads = await log.reads
        XCTAssertEqual(reads, [], "read older logs without a yes")
        XCTAssertEqual(cloud.fetches, [], "asked the cloud without a yes")
        XCTAssertEqual(cloud.uploads.count, 0)
        let snapshot1 = await m.snapshot()
        XCTAssertEqual(codexTokens(Self.oldDay, in: snapshot1), 17_100)
        XCTAssertNil(defaults.data(forKey: DailyUsageArchiveManager.defaultCodexHistoryRebuildKey),
                     "a refusal was recorded")

        // The other half: the same manager after a yes.
        await m.rebuildCodexHistoryIfNeeded(historyReadAllowed: true, cloud: cloud.cloud())
        reads = await log.reads
        XCTAssertEqual(reads.count, 1)
        let snapshot2 = await m.snapshot()
        XCTAssertEqual(codexTokens(Self.oldDay, in: snapshot2), 9_100)
        XCTAssertEqual(cloud.uploads.count, 1)
    }

    /// Once per rules version; a second run under the same version does
    /// nothing at all, and a run under a later version rewrites the same
    /// figures and sends the same rows when the logs are the same.
    func test_it_runs_once_per_rules_version_and_running_it_again_changes_nothing() async throws {
        previousVersionLeft([Self.oldDay, "2026-07-01"])
        let log = ReadLog()
        let cloud = FakeCloud(rows: [Row(date: Self.oldDay, model: "gpt-5"), Row(date: "2026-07-01", model: "gpt-5")])
        let read = [Self.codexRow(Self.oldDay), Self.codexRow("2026-07-01", input: 4_000, cached: 3_000, cost: 0.4)]

        let first = manager(rulesVersion: 5, codexRead: read, log: log)
        await first.rebuildCodexHistoryIfNeeded(historyReadAllowed: true, cloud: cloud.cloud())
        let afterFirst = await first.snapshot().days
        await first.rebuildCodexHistoryIfNeeded(historyReadAllowed: true, cloud: cloud.cloud())
        await manager(rulesVersion: 5, codexRead: read, log: log)
            .rebuildCodexHistoryIfNeeded(historyReadAllowed: true, cloud: cloud.cloud())

        var reads = await log.reads
        XCTAssertEqual(reads.count, 1, "ran again under the same rules version")
        XCTAssertEqual(cloud.fetches.count, 1)
        XCTAssertEqual(cloud.uploads.count, 1)

        let later = manager(rulesVersion: 6, codexRead: read, log: log)
        await later.rebuildCodexHistoryIfNeeded(historyReadAllowed: true, cloud: cloud.cloud())
        reads = await log.reads
        XCTAssertEqual(reads.count, 2, "a new rules version did not run it again")
        XCTAssertEqual(cloud.uploads.count, 2)
        XCTAssertEqual(cloud.uploads[1].map(FakeCloud.describe), cloud.uploads[0].map(FakeCloud.describe),
                       "the same logs sent different rows")
        let snapshot3 = await later.snapshot()
        XCTAssertEqual(snapshot3.days, afterFirst, "the same logs gave different figures")
        XCTAssertEqual(state.archiveRulesVersion, 6)
        XCTAssertEqual(state.cloudRulesVersionByAccount, ["user-a": 6])
    }

    /// The routine read keeps its own 31 days current; the rebuild leaves
    /// them alone, in the archive and in the cloud.
    func test_only_days_before_the_routine_read_are_rebuilt() async throws {
        XCTAssertEqual(CodexHistoryRebuild.routineWindowFirstDay(now: noon(Self.today)), "2026-09-20")
        let days = [Self.oldDay, "2026-09-19", "2026-09-20", "2026-10-15"]
        previousVersionLeft(days)
        let log = ReadLog()
        let cloud = FakeCloud(rows: days.map { Row(date: $0, model: "gpt-5") })
        let m = manager(codexRead: days.map { Self.codexRow($0) }, log: log)

        await m.rebuildCodexHistoryIfNeeded(historyReadAllowed: true, cloud: cloud.cloud())

        let a = await m.snapshot()
        XCTAssertEqual(codexTokens(Self.oldDay, in: a), 9_100)
        XCTAssertEqual(codexTokens("2026-09-19", in: a), 9_100)
        XCTAssertEqual(codexTokens("2026-09-20", in: a), 17_100, "rewrote a day the routine read covers")
        XCTAssertEqual(codexTokens("2026-10-15", in: a), 17_100, "rewrote a day the routine read covers")
        XCTAssertEqual(Set(cloud.uploads.flatMap { $0.map(\.date) }), [Self.oldDay, "2026-09-19"])
    }

    /// A day whose Codex log is gone keeps its old figure, and the Usage
    /// Dashboard keeps saying so for that day only. Once the logs reach every
    /// old day, the line goes.
    func test_the_dashboard_line_names_only_the_days_the_logs_could_not_reach() async throws {
        previousVersionLeft([Self.oldDay, "2026-07-01"])
        let log = ReadLog()
        let m = manager(codexRead: [Self.codexRow(Self.oldDay)], log: log)
        await m.record(CostUsageScanResult(entries: [Self.codexRow("2026-10-19")]))
        var note = try XCTUnwrap(CodexEstimateChangeNote.load(from: defaults))
        XCTAssertEqual(note.oldCodexDays, [Self.oldDay, "2026-07-01"], "control")

        await m.rebuildCodexHistoryIfNeeded(historyReadAllowed: true, cloud: nil)

        note = try XCTUnwrap(CodexEstimateChangeNote.load(from: defaults))
        XCTAssertEqual(note.oldCodexDays, ["2026-07-01"], "June was recounted; July's log is gone")
        XCTAssertNotNil(note.dashboardLine())
        let snapshot4 = await m.snapshot()
        XCTAssertEqual(codexTokens("2026-07-01", in: snapshot4), 17_100)
    }

    func test_the_dashboard_line_goes_once_every_old_day_is_recounted() async throws {
        previousVersionLeft([Self.oldDay, "2026-07-01"])
        let log = ReadLog()
        let m = manager(codexRead: [Self.codexRow(Self.oldDay), Self.codexRow("2026-07-01")], log: log)
        await m.record(CostUsageScanResult(entries: [Self.codexRow("2026-10-19")]))
        XCTAssertNotNil(CodexEstimateChangeNote.load(from: defaults)?.dashboardLine(), "control")

        await m.rebuildCodexHistoryIfNeeded(historyReadAllowed: true, cloud: nil)

        let note = try XCTUnwrap(CodexEstimateChangeNote.load(from: defaults))
        XCTAssertEqual(note.oldCodexDays, [])
        XCTAssertNil(note.dashboardLine())
    }

    /// A read that finds no Codex log at all, on a Mac whose history holds
    /// older Codex days, may not have been able to read the Codex folder. It
    /// is not recorded as done, and it is not repeated on every refresh: a day
    /// later it is tried again.
    func test_a_read_that_finds_no_codex_log_is_tried_again_a_day_later() async throws {
        previousVersionLeft([Self.oldDay])
        let log = ReadLog()
        let m = manager(codexRead: [], log: log)
        await m.rebuildCodexHistoryIfNeeded(historyReadAllowed: true, cloud: nil)
        await m.rebuildCodexHistoryIfNeeded(historyReadAllowed: true, cloud: nil)
        var reads = await log.reads
        XCTAssertEqual(reads.count, 1, "tried again on the next refresh")
        XCTAssertNil(state.archiveRulesVersion, "a read that found nothing was recorded as done")
        let snapshot5 = await m.snapshot()
        XCTAssertEqual(codexTokens(Self.oldDay, in: snapshot5), 17_100)

        let nextDay = manager(today: "2026-10-21", codexRead: [Self.codexRow(Self.oldDay)], log: log)
        await nextDay.rebuildCodexHistoryIfNeeded(historyReadAllowed: true, cloud: nil)
        await nextDay.rebuildCodexHistoryIfNeeded(historyReadAllowed: true, cloud: nil)
        reads = await log.reads
        XCTAssertEqual(reads.count, 2)
        let snapshot6 = await nextDay.snapshot()
        XCTAssertEqual(codexTokens(Self.oldDay, in: snapshot6), 9_100)
        XCTAssertEqual(state.archiveRulesVersion, 5)
        XCTAssertNil(state.retryAfterUnixMs)
    }

    /// Nothing older than the routine read holds Codex: nothing to recount,
    /// so no year of logs is read for it.
    func test_a_history_without_older_codex_days_reads_nothing() async throws {
        previousVersionLeft([Self.oldDay], codex: false)
        let log = ReadLog()
        let cloud = FakeCloud(rows: [Row(date: "2026-10-15", model: "gpt-5")])   // newer only
        let m = manager(codexRead: [Self.codexRow(Self.oldDay)], log: log)

        await m.rebuildCodexHistoryIfNeeded(historyReadAllowed: true, cloud: cloud.cloud())

        let reads = await log.reads
        XCTAssertEqual(reads, [])
        XCTAssertEqual(cloud.fetches.count, 1)
        XCTAssertEqual(cloud.uploads.count, 0)
        XCTAssertEqual(state.archiveRulesVersion, 5)
        XCTAssertEqual(state.cloudRulesVersionByAccount, ["user-a": 5])
        let snapshot7 = await m.snapshot()
        XCTAssertNil(snapshot7.days[Self.oldDay]?.perProvider["Codex"],
                     "added a Codex day it was not asked to recount")
    }

    /// The backfill reads Codex under the current rules too: run for the
    /// first time in 1.56, it leaves the rebuild nothing to read for the
    /// archive.
    func test_a_backfill_under_the_current_rules_leaves_the_archive_nothing_to_read() async throws {
        previousVersionLeft([Self.oldDay])
        let log = ReadLog()
        let m = manager(codexRead: [Self.codexRow(Self.oldDay)], log: log)

        await m.runBackfillIfNeeded(historyReadAllowed: true)
        await m.rebuildCodexHistoryIfNeeded(historyReadAllowed: true, cloud: nil)

        let reads = await log.reads
        XCTAssertEqual(reads, [Read(providers: [.codex, .claude], days: LocalScanDisclosure.historyWindowDays)],
                       "one read, the backfill's")
        let snapshot8 = await m.snapshot()
        XCTAssertEqual(codexTokens(Self.oldDay, in: snapshot8), 9_100)
        XCTAssertEqual(state.archiveRulesVersion, 5)
    }

    // MARK: - The cloud

    /// This Mac's older Codex rows are replaced from the read, not the
    /// archive: input including cached, as the routine upload sends it. Only
    /// days where both have Codex; a model the read no longer reports on such
    /// a day is zeroed, since the server never deletes a row.
    func test_the_cloud_gets_this_macs_older_codex_rows_from_the_read() async throws {
        previousVersionLeft([Self.oldDay, "2026-07-01", "2026-08-01"])
        let log = ReadLog()
        let cloud = FakeCloud(rows: [
            Row(date: Self.oldDay, model: "gpt-5"),
            Row(date: Self.oldDay, model: "gpt-5-codex"),       // no longer reported that day
            Row(date: "2026-07-01", model: "gpt-5"),             // its log is gone
            Row(date: "2026-10-15", model: "gpt-5"),             // the routine read's
        ])
        let m = manager(codexRead: [
            Self.codexRow(Self.oldDay),
            Self.codexRow(Self.oldDay, model: "gpt-5.6-luna", input: 2_000, cached: 1_500, output: 40, cost: 0.1),
            Self.codexRow("2026-08-01"),                         // never synced from this Mac
        ], log: log)

        await m.rebuildCodexHistoryIfNeeded(historyReadAllowed: true, cloud: cloud.cloud())

        XCTAssertEqual(cloud.fetches, [LocalScanDisclosure.historyWindowDays + 2])
        XCTAssertEqual(cloud.uploads.count, 1)
        XCTAssertEqual(cloud.uploads.first?.map(FakeCloud.describe), [
            "2026-06-01 Codex gpt-5 9000/8000/100 1.7",
            "2026-06-01 Codex gpt-5-codex 0/0/0 0.0",
            "2026-06-01 Codex gpt-5.6-luna 2000/1500/40 0.1",
        ])
        XCTAssertEqual(state.cloudRulesVersionByAccount, ["user-a": 5])
    }

    /// An upload that fails is not recorded: a day later the cloud's part runs
    /// again, reading the logs again for it, and the archive's part, already
    /// done, is not repeated.
    func test_a_failed_upload_is_tried_again_a_day_later() async throws {
        previousVersionLeft([Self.oldDay])
        let log = ReadLog()
        let cloud = FakeCloud(rows: [Row(date: Self.oldDay, model: "gpt-5")], accepts: false)
        let read = [Self.codexRow(Self.oldDay)]
        let m = manager(codexRead: read, log: log)
        await m.rebuildCodexHistoryIfNeeded(historyReadAllowed: true, cloud: cloud.cloud())
        await m.rebuildCodexHistoryIfNeeded(historyReadAllowed: true, cloud: cloud.cloud())
        XCTAssertEqual(cloud.uploads.count, 1, "tried again on the next refresh")
        XCTAssertEqual(state.archiveRulesVersion, 5, "the archive's part did not count as done")
        XCTAssertEqual(state.cloudRulesVersionByAccount, [:], "a failed upload was recorded as done")

        cloud.accepts = true
        let nextDay = manager(today: "2026-10-21", codexRead: read, log: log)
        await nextDay.rebuildCodexHistoryIfNeeded(historyReadAllowed: true, cloud: cloud.cloud())
        await nextDay.rebuildCodexHistoryIfNeeded(historyReadAllowed: true, cloud: cloud.cloud())
        XCTAssertEqual(cloud.uploads.count, 2)
        XCTAssertEqual(state.cloudRulesVersionByAccount, ["user-a": 5])
        let reads = await log.reads
        XCTAssertEqual(reads.count, 2)
    }

    /// The cloud could not be asked: the archive's part still runs, and the
    /// cloud's waits a day.
    func test_a_cloud_that_cannot_be_read_leaves_the_archive_part_to_run() async throws {
        previousVersionLeft([Self.oldDay])
        let log = ReadLog()
        let cloud = FakeCloud(rows: nil)
        let m = manager(codexRead: [Self.codexRow(Self.oldDay)], log: log)
        await m.rebuildCodexHistoryIfNeeded(historyReadAllowed: true, cloud: cloud.cloud())

        let snapshot9 = await m.snapshot()
        XCTAssertEqual(codexTokens(Self.oldDay, in: snapshot9), 9_100)
        XCTAssertEqual(cloud.uploads.count, 0)
        XCTAssertEqual(state.archiveRulesVersion, 5)
        XCTAssertEqual(state.cloudRulesVersionByAccount, [:])
        XCTAssertNotNil(state.retryAfterUnixMs)
    }

    /// Signed out, only the archive. Signed in later, the cloud's part runs
    /// for that account, and again for another account this Mac signs in to.
    func test_the_cloud_part_runs_per_account_when_one_is_signed_in() async throws {
        previousVersionLeft([Self.oldDay])
        let log = ReadLog()
        let cloud = FakeCloud(rows: [Row(date: Self.oldDay, model: "gpt-5")])
        let m = manager(codexRead: [Self.codexRow(Self.oldDay)], log: log)

        await m.rebuildCodexHistoryIfNeeded(historyReadAllowed: true, cloud: nil)
        XCTAssertEqual(state.archiveRulesVersion, 5)
        XCTAssertEqual(cloud.fetches.count, 0)

        await m.rebuildCodexHistoryIfNeeded(historyReadAllowed: true, cloud: cloud.cloud())
        await m.rebuildCodexHistoryIfNeeded(historyReadAllowed: true, cloud: cloud.cloud())
        XCTAssertEqual(cloud.uploads.count, 1)

        await m.rebuildCodexHistoryIfNeeded(historyReadAllowed: true, cloud: cloud.cloud(account: "user-b"))
        XCTAssertEqual(cloud.uploads.count, 2)
        XCTAssertEqual(state.cloudRulesVersionByAccount, ["user-a": 5, "user-b": 5])
        let reads = await log.reads
        XCTAssertEqual(reads.count, 3, "one read for the archive, one per account")
    }

    // MARK: - The cloud plan, on its own

    func test_the_plan_sends_only_days_both_sides_have_and_zeroes_rows_the_read_dropped() {
        let rebuilt: [Entry] = [
            Self.codexRow("2026-06-01"),
            Self.codexRow("2026-06-02", model: "gpt-5.5"),
            Self.claudeRow("2026-06-01"),                                  // not Codex
            .init(date: "2026-06-01", provider: "Codex", model: ScanEntry.messageBucketModel,
                  inputTokens: 0, cachedTokens: 0, outputTokens: 0, costUSD: 0),
        ]
        let cloud = [
            Row(date: "2026-06-01", model: "gpt-5"),
            Row(date: "2026-06-01", model: "o3"),
            Row(date: "2026-06-03", model: "gpt-5"),
        ]
        let plan = CodexHistoryRebuild.cloudUpload(rebuilt: rebuilt, thisMacsRows: cloud)
        XCTAssertEqual(plan.map(FakeCloud.describe), [
            "2026-06-01 Codex gpt-5 9000/8000/100 1.7",
            "2026-06-01 Codex o3 0/0/0 0.0",
        ])
        XCTAssertEqual(CodexHistoryRebuild.cloudUpload(rebuilt: rebuilt, thisMacsRows: []).count, 0)
        XCTAssertEqual(CodexHistoryRebuild.cloudUpload(rebuilt: [], thisMacsRows: cloud).count, 0)
    }

    // MARK: - The scanner reads only the providers it is asked for

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-rebuild-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// A Codex rollout and a Claude transcript on the same day; scans asked
    /// for Codex only, and for both.
    private func scan(providers: Set<ProviderKind>?) throws -> (entries: [Entry], cacheFiles: [String]) {
        let home = try tempDir()
        let codexDay = home.appendingPathComponent("sessions/2026/09/10", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDay, withIntermediateDirectories: true)
        let usage = #"{"input_tokens":1000,"cached_input_tokens":600,"output_tokens":10}"#
        try Data([
            #"{"timestamp":"2026-09-10T12:00:00.000Z","type":"session_meta","payload":{"id":"s1","session_id":"s1","timestamp":"2026-09-10T12:00:00.000Z"}}"#,
            #"{"timestamp":"2026-09-10T12:01:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":\#(usage),"last_token_usage":\#(usage)}}}"#,
        ].joined(separator: "\n").appending("\n").utf8).write(to: codexDay.appendingPathComponent("rollout-s1.jsonl"))
        let project = home.appendingPathComponent("claude/-Users-someone-project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data((#"{"type":"assistant","timestamp":"2026-09-10T12:00:00.000Z","requestId":"req-1","message":{"id":"msg-1","model":"claude-sonnet-4-5","usage":{"input_tokens":200,"output_tokens":100}}}"# + "\n").utf8)
            .write(to: project.appendingPathComponent("session.jsonl"))

        let cache = home.appendingPathComponent("cache", isDirectory: true)
        var options = CostUsageScanner.Options(
            codexSessionsRoot: home.appendingPathComponent("sessions", isDirectory: true),
            claudeProjectsRoots: [home.appendingPathComponent("claude", isDirectory: true)],
            cacheRoot: cache,
            daysToScan: 30)
        options.forceRescan = true
        options.refreshMinIntervalSeconds = 0
        options.now = ISO8601DateFormatter().date(from: "2026-09-30T12:00:00Z")
        if let providers { options.providers = providers }
        let entries = CostUsageScanner.scan(options: options).entries
        let files = (try? FileManager.default.contentsOfDirectory(
            atPath: cache.appendingPathComponent("cost-usage").path)) ?? []
        return (entries, files.filter { !$0.hasPrefix(".") }.sorted())
    }

    func test_a_codex_only_scan_neither_reads_nor_caches_claude() throws {
        let both = try scan(providers: nil)
        XCTAssertEqual(Set(both.entries.map(\.provider)), ["Codex", "Claude"], "control: both are read by default")
        XCTAssertEqual(both.cacheFiles, ["claude-v2.json", "codex-v2.json"])

        let codexOnly = try scan(providers: [.codex])
        XCTAssertEqual(Set(codexOnly.entries.map(\.provider)), ["Codex"])
        XCTAssertEqual(codexOnly.entries.reduce(0) { $0 + $1.inputTokens }, 1_000)
        XCTAssertEqual(codexOnly.cacheFiles, ["codex-v2.json"], "the Claude cache was written")
    }

    func test_the_default_scan_reads_both_providers() {
        XCTAssertEqual(CostUsageScanner.Options().providers, [.codex, .claude])
    }
}

/// The signed-in account's side, recorded.
private final class FakeCloud: @unchecked Sendable {
    private let lock = NSLock()
    private let rows: [CodexHistoryCloud.Row]?
    private var _accepts: Bool
    private var _fetches: [Int] = []
    private var _uploads: [[CostUsageScanResult.DailyEntry]] = []

    init(rows: [CodexHistoryCloud.Row]?, accepts: Bool = true) {
        self.rows = rows
        self._accepts = accepts
    }

    var accepts: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _accepts }
        set { lock.lock(); _accepts = newValue; lock.unlock() }
    }
    var fetches: [Int] { lock.lock(); defer { lock.unlock() }; return _fetches }
    var uploads: [[CostUsageScanResult.DailyEntry]] { lock.lock(); defer { lock.unlock() }; return _uploads }

    func cloud(account: String = "user-a") -> CodexHistoryCloud {
        CodexHistoryCloud(
            account: account,
            thisMacsCodexRows: { days in self.fetched(days) },
            upload: { rows in self.uploaded(rows) })
    }

    private func fetched(_ days: Int) -> [CodexHistoryCloud.Row]? {
        lock.lock(); defer { lock.unlock() }
        _fetches.append(days)
        return rows
    }

    private func uploaded(_ rows: [CostUsageScanResult.DailyEntry]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        _uploads.append(rows)
        return _accepts
    }

    static func describe(_ e: CostUsageScanResult.DailyEntry) -> String {
        "\(e.date) \(e.provider) \(e.model) \(e.inputTokens)/\(e.cachedTokens)/\(e.outputTokens) \(e.costUSD ?? -1)"
    }
}
#endif
