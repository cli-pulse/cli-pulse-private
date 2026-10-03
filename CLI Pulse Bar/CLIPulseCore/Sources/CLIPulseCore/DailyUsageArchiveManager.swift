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
    private var backfillRunning = false

    /// Not reset when Codex starts being counted differently, so the older
    /// Codex days the year-long read counted the old way stay as they are;
    /// `CodexEstimateChangeNote` tracks them and the Usage Dashboard says so.
    /// A second run would no longer harm the Claude share (it merges provider
    /// by provider, `mergeScanEntriesByProvider`, keeping every stored Claude
    /// slice and every provider it does not find), but recounting older Codex
    /// days is a change of its own, not a side effect of this flag.
    public static let defaultBackfillKey = "cli_pulse_daily_archive_backfilled_v1"
    /// The only read in the app that goes further back than the routine 30
    /// days. v1.55: what the disclosure says it may do, and nothing more.
    static let backfillDays = LocalScanDisclosure.historyWindowDays

    /// `backfillScan` is a seam for tests, which must never walk the real
    /// `~/.codex` and `~/.claude` of whoever runs them.
    init(
        root: URL? = nil,
        defaults: UserDefaults = .standard,
        backfillKey: String = DailyUsageArchiveManager.defaultBackfillKey,
        now: @escaping @Sendable () -> Date = { Date() },
        codexNoteReasons: [CodexEstimateChangeNote.Reason] = CodexEstimateChangeNote.Reason.shipped,
        backfillScan: @escaping @Sendable (CostUsageScanner.Options) async -> CostUsageScanResult)
    {
        self.root = root
        self.defaults = defaults
        self.backfillKey = backfillKey
        self.now = now
        self.codexNoteReasons = codexNoteReasons
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
        guard !defaults.bool(forKey: backfillKey), !backfillRunning else { return }
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

    static func nowMs() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }
}
#endif
