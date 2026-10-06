// DailyUsageArchiveManager — macOS glue between the scanner/cloud and the pure
// DailyUsageArchive spine (v1.40 PR-4). Loads/saves the durable archive, folds
// every refresh's scan result into it, runs the one-time 365-day backfill in an
// ISOLATED throwaway cacheRoot (so the live 30-day cache's Today bookkeeping is
// never corrupted), and fills other-device days from the cloud.
//
// An actor: the archive is mutable shared state touched from the refresh path.
// The heavy backfill parse runs on the actor's executor (off the main thread).

#if os(macOS)
import Foundation

public extension Notification.Name {
    /// Posted after the durable usage archive is mutated + saved, so the
    /// dashboard window + Overview card can re-snapshot live (they otherwise
    /// only load once via `.task`, and `.menuBarExtraStyle(.window)` keeps the
    /// popover content alive across close/reopen).
    static let dailyUsageArchiveDidChange = Notification.Name("cli_pulse_daily_usage_archive_did_change")
}

public actor DailyUsageArchiveManager {
    public static let shared = DailyUsageArchiveManager()

    // Loaded lazily inside the actor (off the main thread) — the disk read must
    // NOT happen on the MainActor first-touch, since this menu-bar agent is
    // app-hang-sensitive. nil until the first actor-isolated method runs.
    private var archive: DailyUsageArchive?
    private let root: URL?                 // nil ⇒ default Application Support
    private let defaults: UserDefaults
    private let backfillKey: String
    private let backfillScan: @Sendable (CostUsageScanner.Options) async -> CostUsageScanResult
    private let now: @Sendable () -> Date
    /// The reasons the Codex note tells about: `Reason.shipped`, or a test's.
    private let codexNoteReasons: [CodexEstimateChangeNote.Reason]
    /// The Codex rules version the history rebuild works to:
    /// `costUsageCodexCacheRulesVersion`, or a test's.
    private let codexRulesVersion: Int
    private let codexHistoryRebuildKey: String
    private var backfillRunning = false
    private var rebuildRunning = false

    /// Not reset when Codex starts being counted differently. Recounting the
    /// older Codex days is the history rebuild's job
    /// (`rebuildCodexHistoryIfNeeded`), which reads the Codex logs only; a
    /// second backfill would read a year of Claude transcripts for nothing.
    public static let defaultBackfillKey = "cli_pulse_daily_archive_backfilled_v1"
    /// What the Codex history rebuild has finished (`CodexHistoryRebuild.State`).
    public static let defaultCodexHistoryRebuildKey = "cli_pulse_codex_history_rebuild_v1"
    /// The reads in the app that go further back than the routine 30 days: the
    /// backfill and the Codex history rebuild. v1.55: what the disclosure says
    /// may be read, and nothing more.
    static let backfillDays = LocalScanDisclosure.historyWindowDays

    /// `backfillScan` is a seam for tests, which must never walk the real
    /// `~/.codex` and `~/.claude` of whoever runs them.
    init(
        root: URL? = nil,
        defaults: UserDefaults = .standard,
        backfillKey: String = DailyUsageArchiveManager.defaultBackfillKey,
        codexHistoryRebuildKey: String = DailyUsageArchiveManager.defaultCodexHistoryRebuildKey,
        now: @escaping @Sendable () -> Date = { Date() },
        codexNoteReasons: [CodexEstimateChangeNote.Reason] = CodexEstimateChangeNote.Reason.shipped,
        codexRulesVersion: Int = costUsageCodexCacheRulesVersion,
        backfillScan: @escaping @Sendable (CostUsageScanner.Options) async -> CostUsageScanResult)
    {
        self.root = root
        self.defaults = defaults
        self.backfillKey = backfillKey
        self.codexHistoryRebuildKey = codexHistoryRebuildKey
        self.now = now
        self.codexNoteReasons = codexNoteReasons
        self.codexRulesVersion = codexRulesVersion
        self.backfillScan = backfillScan
        self.archive = nil   // deferred to first actor-isolated access (off-main)
    }

    public init(
        root: URL? = nil,
        defaults: UserDefaults = .standard,
        backfillKey: String = DailyUsageArchiveManager.defaultBackfillKey)
    {
        self.init(
            root: root,
            defaults: defaults,
            backfillKey: backfillKey,
            backfillScan: { await CostUsageScanner.scanAsync(options: $0) })
    }

    /// The archive, loading from disk on first access (on the actor executor).
    private func loaded() -> DailyUsageArchive {
        if let archive { return archive }
        let a = DailyUsageArchiveIO.load(root: root)
        archive = a
        return a
    }

    /// Current archive snapshot (for the dashboard window — PR-5).
    public func snapshot() -> DailyUsageArchive { loaded() }

    // MARK: - Record a refresh scan (authoritative local, replace-by-day)

    /// Replaces each day of the routine 30-day read, except the day Claude
    /// Code's cleanup is working through (`DailyUsageArchive.claudeCleanupReach`),
    /// usually the read's oldest (across a daylight-saving change, possibly the
    /// day after it). Its Claude share was recorded in full the day before;
    /// the read now sees only the transcripts cleanup has not deleted yet, so
    /// that day is merged provider by provider and its Claude slice is not
    /// lowered. `now` is a seam for tests; nil reads the manager's clock, the
    /// one the Codex note is dated by.
    public func record(_ scanResult: CostUsageScanResult, now: Date? = nil) {
        guard !scanResult.entries.isEmpty else { return }
        var a = loaded()
        codexNoteWillWrite(a)
        let codexFromRead = a.mergeScanEntries(
            scanResult.entries.map(Self.scanEntry),
            claudeCleanupReach: DailyUsageArchive.claudeCleanupReach(now: now ?? self.now()))
        a.lastUpdatedUnixMs = Self.nowMs()
        archive = a
        DailyUsageArchiveIO.save(a, root: root)
        codexNoteDidWrite(codexFromRead, in: a)
        NotificationCenter.default.post(name: .dailyUsageArchiveDidChange, object: nil)
    }

    // MARK: - Merge cloud daily usage (fill-only, other devices / pre-history)

    public func mergeCloud(_ rows: [DailyUsage]) {
        let filtered = rows.filter { $0.model != ScanEntry.messageBucketModel }
        guard !filtered.isEmpty else { return }
        var a = loaded()
        codexNoteWillWrite(a)
        let filled = a.mergeCloudDays(filtered.map(Self.cloudEntry))
        a.lastUpdatedUnixMs = Self.nowMs()
        archive = a
        DailyUsageArchiveIO.save(a, root: root)
        codexNoteDidWrite(filled, in: a)
        NotificationCenter.default.post(name: .dailyUsageArchiveDidChange, object: nil)
    }

    // MARK: - One-time 365-day backfill (isolated cacheRoot)

    /// Runs once (guarded by `defaults[backfillKey]`). Callers should invoke
    /// this only after a normal scan succeeded, so folder access is confirmed —
    /// then a successful backfill (even one that finds little history) marks the
    /// flag done. Uses a throwaway temp cacheRoot; NEVER the production cache.
    ///
    /// v1.55 — `historyReadAllowed` is the user's answer to disclosure v2
    /// (`LocalCollectionPolicy.allowsReadingBeyondRoutineWindow`). Until 1.55
    /// this ran for everyone whose scan succeeded, while the consent screen said
    /// "last 30 days". It is a required argument, not a default, so no caller can
    /// reach the year-long read without saying which answer it is acting on.
    ///
    /// Refusing returns before the done-flag is touched: a "not yet" must not be
    /// recorded as "already backfilled", or a later yes would find nothing left
    /// to do.
    ///
    /// Because a yes can come months after "Last 30 days only", the read can
    /// meet an archive that already holds those months, on days whose Claude
    /// transcripts Claude Code has since deleted, all of them or some. It is
    /// merged provider by provider (`mergeScanEntriesByProvider`): a day keeps
    /// the slice of a provider the read did not find, and its Claude slice is
    /// never lowered.
    public func runBackfillIfNeeded(historyReadAllowed: Bool) async {
        guard historyReadAllowed else { return }
        guard !defaults.bool(forKey: backfillKey), !backfillRunning, !rebuildRunning else { return }
        backfillRunning = true
        defer { backfillRunning = false }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-pulse-backfill-\(UUID().uuidString)", isDirectory: true)
        var options = CostUsageScanner.Options(cacheRoot: tmp, daysToScan: Self.backfillDays)
        options.forceRescan = true   // not an init param — set after construction

        let result = await backfillScan(options)
        if !result.entries.isEmpty {
            var a = loaded()
            codexNoteWillWrite(a)
            let codexFromRead = a.mergeScanEntriesByProvider(result.entries.map(Self.scanEntry))
            a.lastUpdatedUnixMs = Self.nowMs()
            archive = a
            DailyUsageArchiveIO.save(a, root: root)
            codexNoteDidWrite(codexFromRead, in: a)
            NotificationCenter.default.post(name: .dailyUsageArchiveDidChange, object: nil)
        }
        try? FileManager.default.removeItem(at: tmp)   // discard the throwaway cache
        defaults.set(true, forKey: backfillKey)        // access was confirmed by caller — done

        // It read the Codex logs under the current rules, as the history
        // rebuild would: the archive's part of that is done, unless it found
        // no Codex log at all while the history holds older Codex days.
        var state = CodexHistoryRebuild.State.load(from: defaults, key: codexHistoryRebuildKey)
        if state.archiveIsDue(rulesVersion: codexRulesVersion),
           archiveRecountWorked(read: result.entries, before: CodexHistoryRebuild.routineWindowFirstDay(now: now())) {
            state.archiveRulesVersion = codexRulesVersion
            state.save(to: defaults, key: codexHistoryRebuildKey)
        }
    }

    // MARK: - v1.56: the Codex history rebuild

    /// Counts the archive's Codex days older than the routine read again under
    /// the current Codex rules, and replaces this Mac's Codex rows for those
    /// days in the signed-in account's cloud. See `CodexHistoryRebuild`.
    ///
    /// `historyReadAllowed` is the user's answer to disclosure v2, as for the
    /// backfill: without a yes nothing is read, and nothing is recorded, so a
    /// later yes still finds the work to do. `cloud` is nil while signed out;
    /// the archive's part runs either way, and the cloud's on a later refresh
    /// that has an account.
    ///
    /// Once per rules version for the archive, and once per rules version and
    /// account for the cloud. Every step is idempotent: running it again
    /// rewrites the same figures and sends the same rows.
    public func rebuildCodexHistoryIfNeeded(historyReadAllowed: Bool, cloud: CodexHistoryCloud?) async {
        guard historyReadAllowed, !rebuildRunning, !backfillRunning else { return }
        let version = codexRulesVersion
        var state = CodexHistoryRebuild.State.load(from: defaults, key: codexHistoryRebuildKey)
        let archiveDue = state.archiveIsDue(rulesVersion: version)
        let cloudDue = state.cloudIsDue(rulesVersion: version, account: cloud?.account)
        guard archiveDue || cloudDue else { return }
        let started = now()
        if let after = state.retryAfterUnixMs, Self.unixMs(started) < after { return }
        rebuildRunning = true
        defer { rebuildRunning = false }

        let firstRoutineDay = CodexHistoryRebuild.routineWindowFirstDay(now: started)
        var incomplete = false

        // The cloud first: one request tells whether this Mac has older Codex
        // rows there at all. A year of logs is read only for a part that needs it.
        var cloudRows: [CodexHistoryCloud.Row] = []
        if cloudDue, let cloud {
            if let rows = await cloud.thisMacsCodexRows(Self.backfillDays + 2) {
                cloudRows = rows.filter { $0.date < firstRoutineDay }
                if cloudRows.isEmpty { state.cloudRulesVersionByAccount[cloud.account] = version }
            } else {
                incomplete = true
            }
        }
        var archiveNeedsRead = false
        if archiveDue {
            if CodexHistoryRebuild.hasCodexDay(in: loaded(), before: firstRoutineDay) {
                archiveNeedsRead = true
            } else {
                state.archiveRulesVersion = version   // no older Codex day to recount
            }
        }

        if archiveNeedsRead || !cloudRows.isEmpty {
            let read = await readCodexYear()
            let older = CodexHistoryRebuild.olderCodexEntries(read.entries, before: firstRoutineDay)
            let sawCodex = read.entries.contains { $0.provider == CodexHistoryRebuild.codex }

            if archiveNeedsRead {
                if !older.isEmpty {
                    var a = loaded()
                    codexNoteWillWrite(a)
                    let codexFromRead = a.mergeScanEntriesByProvider(older.map(Self.scanEntry))
                    a.lastUpdatedUnixMs = Self.nowMs()
                    archive = a
                    DailyUsageArchiveIO.save(a, root: root)
                    codexNoteDidWrite(codexFromRead, in: a)
                    NotificationCenter.default.post(name: .dailyUsageArchiveDidChange, object: nil)
                }
                if archiveRecountWorked(read: read.entries, before: firstRoutineDay) {
                    state.archiveRulesVersion = version
                } else {
                    incomplete = true
                }
            }

            if !cloudRows.isEmpty, let cloud {
                let rows = CodexHistoryRebuild.cloudUpload(
                    rebuilt: older, thisMacsRows: cloudRows, zeroDroppedModels: !cloud.isUnpairedStandIn)
                if !sawCodex {
                    incomplete = true   // nothing read to replace them with; not "done"
                } else if rows.isEmpty {
                    state.cloudRulesVersionByAccount[cloud.account] = version
                } else if await cloud.upload(rows) {
                    state.cloudRulesVersionByAccount[cloud.account] = version
                } else {
                    incomplete = true
                }
            }
        }

        state.retryAfterUnixMs = incomplete
            ? Self.unixMs(started.addingTimeInterval(CodexHistoryRebuild.retryInterval))
            : nil
        state.save(to: defaults, key: codexHistoryRebuildKey)
    }

    /// A year of Codex logs and nothing else, read into a throwaway cache, as
    /// the backfill reads both.
    private func readCodexYear() async -> CostUsageScanResult {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-pulse-codex-rebuild-\(UUID().uuidString)", isDirectory: true)
        var options = CostUsageScanner.Options(cacheRoot: tmp, daysToScan: Self.backfillDays)
        options.forceRescan = true
        options.providers = [.codex]
        let result = await backfillScan(options)
        try? FileManager.default.removeItem(at: tmp)
        return result
    }

    /// Whether a read that went through the Codex logs counts as the archive's
    /// recount: it found Codex usage (so the logs could be read), or the
    /// archive holds no Codex day before `firstRoutineDay` for it to recount.
    /// A read that found none while there are such days may only have been
    /// unable to read the Codex folder.
    private func archiveRecountWorked(read entries: [CostUsageScanResult.DailyEntry], before firstRoutineDay: String) -> Bool {
        entries.contains { $0.provider == CodexHistoryRebuild.codex }
            || !CodexHistoryRebuild.hasCodexDay(in: loaded(), before: firstRoutineDay)
    }

    // MARK: - The Codex estimate note's bookkeeping

    /// Before a write: on this version's first write, and on the first write of
    /// a later version that ships a new reason, start a note from the archive as
    /// the previous version left it (the day, whether this Mac had Codex
    /// figures, and which Codex days they are). Every path that writes the
    /// archive calls this first.
    private func codexNoteWillWrite(_ archive: DailyUsageArchive) {
        CodexEstimateChangeNote
            .next(after: CodexEstimateChangeNote.load(from: defaults), before: archive,
                  on: DayKey.string(from: now()), shipped: codexNoteReasons)?
            .save(to: defaults)
    }

    /// After a write: `codexFromRead` are the days whose Codex share the write
    /// took from the read or the cloud (what `mergeScanEntries`,
    /// `mergeScanEntriesByProvider` and `mergeCloudDays` return), so they no
    /// longer hold old figures. Only these days: a read writes only the days
    /// it has entries for, a day merged provider by provider keeps its stored
    /// Codex slice where the read has no Codex entries for it, and a Codex day
    /// the read has nothing for keeps its old figure however far back the read
    /// reached.
    private func codexNoteDidWrite(_ codexFromRead: Set<String>, in archive: DailyUsageArchive) {
        guard var note = CodexEstimateChangeNote.load(from: defaults), !note.oldCodexDays.isEmpty else { return }
        let before = note
        note.recordWrite(of: codexFromRead, in: archive)
        if note != before { note.save(to: defaults) }
    }

    // MARK: - Adapters

    /// Each token once (`ArchiveTokenBasis`): Codex's cached input is part of
    /// its input and is not added a second time.
    static func scanEntry(_ e: CostUsageScanResult.DailyEntry) -> ScanEntry {
        ScanEntry(archiving: e)
    }

    static func cloudEntry(_ u: DailyUsage) -> CloudEntry {
        CloudEntry(archiving: u)
    }

    static func nowMs() -> Int64 { unixMs(Date()) }

    static func unixMs(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
}
#endif
