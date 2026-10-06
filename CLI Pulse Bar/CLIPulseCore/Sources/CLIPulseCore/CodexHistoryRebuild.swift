import Foundation

/// v1.56 (P0-17): the Codex days of the usage history that are older than the
/// routine 30-day read, counted again by the current Codex rules.
///
/// WHY
/// ---
/// The archive keeps one total per day and provider (`DailyUsageArchive`), not
/// the input / cached / output split it was added up from, so a day stored
/// under older Codex rules cannot be corrected where it is. The routine read
/// rewrites the last 30 days on every refresh. Nothing rewrote anything older:
/// the year-long read (the backfill) runs once per Mac, and on most Macs it ran
/// before 1.55. So when 1.56 changed how Codex is counted (cached input once,
/// subagent sessions, published prices), every older Codex day kept its old
/// figure, in the Mac's history and in the cloud rows the iPhone builds its
/// year from.
///
/// WHAT (`DailyUsageArchiveManager.rebuildCodexHistoryIfNeeded`)
/// ----
/// Once per Codex rules version (`costUsageCodexCacheRulesVersion`), and only
/// after a yes to disclosure v2 (older history), the archive manager reads a
/// year of Codex logs, the window the backfill reads, and no Claude log at all
/// (`CostUsageScanner.Options.providers`). Only the days before the routine
/// read's first day are used: the routine read keeps the newer ones current.
///
/// * The archive: each of those days takes the read's Codex slice, provider by
///   provider (`DailyUsageArchive.mergeScanEntriesByProvider`). The read has no
///   Claude rows, so every stored Claude slice stays exactly as it was. A day
///   for which the read finds no Codex keeps its stored Codex figure (its log
///   was deleted, or another device's usage filled it in), and
///   `CodexEstimateChangeNote` keeps naming it as counted the old way.
/// * The cloud, while signed in: this Mac's own Codex rows for those days are
///   replaced from the read (`cloudUpload(rebuilt:thisMacsRows:zeroDroppedModels:)`),
///   not from the archive, which has no split to send.
///
/// A backfill that runs under the current rules has already counted the
/// archive's Codex days this way, so it marks the archive's part done
/// (`DailyUsageArchiveManager.runBackfillIfNeeded`).
///
/// Each part is marked done separately, once it has worked. A read that finds
/// no Codex log at all, on a Mac whose history holds older Codex days, has
/// not worked: on the App Store build the Codex folder may simply not be
/// readable yet. It is tried again after `retryInterval`, which is cheap when
/// there is nothing to read; so is a cloud request that fails. Before a year
/// of logs is read for the cloud, the server is asked whether it takes rows
/// under this Mac's device id at all (`CodexHistoryCloud.acceptsUploads`), so
/// an upload it refuses on every try costs a request a day, not a read.
///
/// The cloud's part runs only when it is known which device id this Mac's
/// rows are under (`APIClient.DailyUsageDevice`): a paired Mac whose helper
/// secret cannot be read (the login keychain locks with the screen) skips it
/// on that refresh, and nothing is recorded.
///
/// LIMITS
/// ------
/// A day's Codex slice becomes what the read finds, and on a paired Mac a
/// model the read no longer reports is zeroed in the cloud. So sessions the
/// read cannot see count as gone: logs deleted by hand, and on the App Store
/// build the sessions Codex moved to `~/.codex/archived_sessions/` when that
/// folder has no grant of its own ("Codex Archived Logs",
/// `BookmarkManager.knownDirectories`). The sandbox cannot tell that folder
/// missing from not granted, and waiting for a grant would keep every App
/// Store user who has no archived sessions on the old rules' figures, so the
/// rebuild does not wait. The routine 30-day read and the backfill have the
/// same blind spot.
public enum CodexHistoryRebuild {

    static let codex = ProviderKind.codex.rawValue

    /// How long after an attempt that left something undone the next one may
    /// start. A refresh runs every few minutes, and a read of a year of Codex
    /// logs is too heavy to repeat at that pace.
    public static let retryInterval: TimeInterval = 24 * 3_600

    /// The first day the routine read covers at `now`: the day of
    /// `now − routineWindowDays`, as `CostUsageScanner.scan` counts it. The
    /// rebuild uses only the days before it.
    public static func routineWindowFirstDay(now: Date) -> String {
        let since = DayKey.calendar().date(
            byAdding: .day, value: -LocalScanDisclosure.routineWindowDays, to: now) ?? now
        return DayKey.string(from: since)
    }

    /// The read's Codex rows for the days before `firstRoutineDay`. Anything
    /// else in the read (a Claude row a scanner seam returned anyway, a day the
    /// routine read covers) is left out.
    public static func olderCodexEntries(
        _ entries: [CostUsageScanResult.DailyEntry],
        before firstRoutineDay: String
    ) -> [CostUsageScanResult.DailyEntry] {
        entries.filter { $0.provider == codex && $0.date < firstRoutineDay }
    }

    /// Whether `archive` holds a Codex figure on a day before `firstRoutineDay`,
    /// the only kind of day the rebuild recounts in the archive.
    public static func hasCodexDay(in archive: DailyUsageArchive, before firstRoutineDay: String) -> Bool {
        archive.days.contains { key, day in
            key < firstRoutineDay && (day.perProvider[codex]?.tokens ?? 0) > 0
        }
    }

    // MARK: - The cloud

    #if os(macOS)
    // The plan is the Mac's: the model names it compares are the scanner's
    // (`CostUsageScanner.Pricing.normalizeCodexModel`), which is macOS-only.

    /// The rows to upsert so that this Mac's Codex rows in the cloud say what
    /// the rebuilt read says, for the days both have:
    ///
    /// * every rebuilt Codex row of a day on which this Mac already has a Codex
    ///   row in the cloud, under the device id it uploads with;
    /// * with `zeroDroppedModels`, a zero row for each Codex model this Mac has
    ///   a row for on such a day that the read no longer reports, since
    ///   `upsert_daily_usage` never deletes a row, and a leftover one would
    ///   still be added to the day.
    ///
    /// `zeroDroppedModels` is false for a Mac that is not paired
    /// (`CodexHistoryCloud.isUnpairedStandIn`). Its rows sit under the server's
    /// one stand-in id for an unpaired Mac, which every unpaired Mac of the
    /// account uploads under, and under which `migrate_v0.37` put the rows of
    /// every device from before it. A model there that this Mac's read does not
    /// report may be another Mac's usage, so it is left alone; the models the
    /// read reports are replaced, as the routine upload replaces them every
    /// refresh.
    ///
    /// Except a stored spelling of a model the read reports under its current
    /// name (`isOlderSpelling`): a dated name such as `gpt-5-2025-08-07` that
    /// 1.56 counts as `gpt-5`, or an `openai/` prefix. That row is the same
    /// model's usage, counted under a name an earlier version kept, and
    /// `get_daily_usage` would add it to the new row; it is zeroed on that day
    /// under the stand-in too. Another unpaired Mac's usage of the same model
    /// is no different from its usage under the current name, which the
    /// routine upload already overwrites under the stand-in (one row per day
    /// and model, last writer wins). The rebuild runs again on every Codex
    /// rules bump, so a later rename of a priced model is handled the same way.
    ///
    /// A rebuilt day on which this Mac has no Codex row in the cloud is not
    /// sent. Either this Mac never uploaded that day (the backfill's history
    /// stays on the Mac, as it always has), or its rows sit under another
    /// device id: before this Mac was paired, uploads went to the server's
    /// stand-in for an unpaired Mac. `get_daily_usage` adds up every device's
    /// rows, so a second copy under this id would count the day twice on the
    /// iPhone. A day this Mac has rows for but the read has nothing on keeps
    /// them: there is nothing to replace them with.
    public static func cloudUpload(
        rebuilt: [CostUsageScanResult.DailyEntry],
        thisMacsRows: [CodexHistoryCloud.Row],
        zeroDroppedModels: Bool
    ) -> [CostUsageScanResult.DailyEntry] {
        let codexRows = rebuilt.filter { $0.provider == codex && $0.model != ScanEntry.messageBucketModel }
        let rebuiltDays = Set(codexRows.map(\.date))
        let cloudDays = Set(thisMacsRows.map(\.date))
        let days = rebuiltDays.intersection(cloudDays)

        var out = codexRows.filter { days.contains($0.date) }
        let reported = Set(out.map { CodexHistoryCloud.Row(date: $0.date, model: $0.model) })
        let stale = Set(thisMacsRows.filter { row in
            days.contains(row.date) && !reported.contains(row)
                && (zeroDroppedModels || isOlderSpelling(row, reported: reported))
        })
        for row in stale.sorted(by: { ($0.date, $0.model) < ($1.date, $1.model) }) {
            out.append(.init(date: row.date, provider: codex, model: row.model,
                             inputTokens: 0, cachedTokens: 0, outputTokens: 0, costUSD: 0))
        }
        return out.sorted { ($0.date, $0.model) < ($1.date, $1.model) }
    }

    /// Whether `row` is a model the read reports on that day, stored under
    /// another spelling: the current rules count `row.model` as a reported
    /// model (`normalizeCodexModel`), and the two names differ.
    static func isOlderSpelling(_ row: CodexHistoryCloud.Row, reported: Set<CodexHistoryCloud.Row>) -> Bool {
        let current = CostUsageScanner.Pricing.normalizeCodexModel(row.model)
        return current != row.model && reported.contains(.init(date: row.date, model: current))
    }

    #endif

    // MARK: - What has been done

    /// What the rebuild has finished, per Codex rules version. Stored by the
    /// archive manager under `DailyUsageArchiveManager.codexHistoryRebuildKey`.
    public struct State: Codable, Equatable, Sendable {
        /// The rules version the archive's older Codex days were last counted
        /// by, by this rebuild or by a backfill.
        public var archiveRulesVersion: Int?
        /// For each account: the rules version this Mac's older Codex rows in
        /// that account's cloud were last replaced by.
        public var cloudRulesVersionByAccount: [String: Int]
        /// Not before this moment (Unix ms) after an attempt that left something
        /// undone.
        public var retryAfterUnixMs: Int64?

        public init(
            archiveRulesVersion: Int? = nil,
            cloudRulesVersionByAccount: [String: Int] = [:],
            retryAfterUnixMs: Int64? = nil)
        {
            self.archiveRulesVersion = archiveRulesVersion
            self.cloudRulesVersionByAccount = cloudRulesVersionByAccount
            self.retryAfterUnixMs = retryAfterUnixMs
        }

        public func archiveIsDue(rulesVersion: Int) -> Bool {
            archiveRulesVersion != rulesVersion
        }

        public func cloudIsDue(rulesVersion: Int, account: String?) -> Bool {
            guard let account else { return false }
            return cloudRulesVersionByAccount[account] != rulesVersion
        }

        public static func load(from defaults: UserDefaults, key: String) -> State {
            guard let data = defaults.data(forKey: key),
                  let state = try? JSONDecoder().decode(State.self, from: data) else { return State() }
            return state
        }

        public func save(to defaults: UserDefaults, key: String) {
            guard let data = try? JSONEncoder().encode(self) else { return }
            defaults.set(data, forKey: key)
        }
    }
}

/// The signed-in account's side of the Codex history rebuild: this Mac's own
/// Codex rows in the cloud, and a way to replace them. Built by
/// `APIClient.codexHistoryCloud(authorizationLease:)`, bound to the lease of
/// the refresh that started the rebuild and to the device id this Mac uploads
/// with at that moment, so the rows it reads and the rows it writes are the
/// same device's, and a sign-out stops both.
public struct CodexHistoryCloud: Sendable {

    /// One of this Mac's Codex rows in the cloud: a day and a model.
    public struct Row: Sendable, Hashable {
        public let date: String
        public let model: String
        public init(date: String, model: String) {
            self.date = date; self.model = model
        }
    }

    /// The signed-in user's id. The rebuild is recorded per account.
    public let account: String
    /// True when this Mac is not paired, so its rows are read and written
    /// under the server's stand-in id for an unpaired Mac, which it shares
    /// with every other unpaired Mac of the account. The rebuild then zeroes
    /// only an older spelling of a model its read reports
    /// (`CodexHistoryRebuild.cloudUpload`).
    public let isUnpairedStandIn: Bool
    /// This Mac's Codex rows over the last `days` days, or nil when they could
    /// not be read.
    public let thisMacsCodexRows: @Sendable (_ days: Int) async -> [Row]?
    /// Whether the server takes rows under this Mac's device id right now:
    /// an upload of no rows, which writes nothing. Asked before a year of
    /// Codex logs is read for the cloud, so an account or device the server
    /// refuses (a paired device deleted on the server while this Mac still
    /// holds its pairing) costs a request a day, not a year-long read a day.
    public let acceptsUploads: @Sendable () async -> Bool
    /// Upserts `rows` under this Mac's device id; true when every batch was
    /// accepted.
    public let upload: @Sendable (_ rows: [CostUsageScanResult.DailyEntry]) async -> Bool

    public init(
        account: String,
        isUnpairedStandIn: Bool,
        thisMacsCodexRows: @escaping @Sendable (_ days: Int) async -> [Row]?,
        acceptsUploads: @escaping @Sendable () async -> Bool,
        upload: @escaping @Sendable (_ rows: [CostUsageScanResult.DailyEntry]) async -> Bool)
    {
        self.account = account
        self.isUnpairedStandIn = isUnpairedStandIn
        self.thisMacsCodexRows = thisMacsCodexRows
        self.acceptsUploads = acceptsUploads
        self.upload = upload
    }
}
