// DailyUsageArchive — durable, un-pruned local usage history (v1.40 PR-4).
//
// The only pre-existing local history is `CostUsageCache` (Caches dir), which
// `CostUsageScanner` destructively prunes to ~30 days on every refresh tick. A
// year heatmap + lifetime stats cannot be powered by it, and widening it would
// break its pricing-version-invalidation + prune contract. This archive is a
// NEW, additive persistence tier under Application Support (durable, never in
// Caches), holding ≥370 days of per-day detail plus an uncapped monthly rollup
// so lifetime totals survive the daily cap.
//
// Schema mirrors javis603/token-monitor's proven `src/shared/history.js` shape
// (MIT). Data is Claude + Codex local JSONL history only (the two providers with
// on-disk logs) — the dashboard must label that scope so sparse data doesn't
// read as a bug.
//
// Pure + cross-platform (no os gate) so the merge/prune/fold logic is fully
// unit-testable; the macOS-only backfill scan + refresh wiring live in
// DailyUsageArchiveManager.

import Foundation

// MARK: - Rollup value types

/// Per-provider slice of a day (tokens + cost + message count).
public struct ProviderDaySlice: Codable, Sendable, Equatable {
    public var tokens: Int
    public var cost: Double
    public var messages: Int
    public init(tokens: Int = 0, cost: Double = 0, messages: Int = 0) {
        self.tokens = tokens; self.cost = cost; self.messages = messages
    }
}

/// Per-model slice of a day (tokens + cost; messages are not model-attributed).
public struct ModelDaySlice: Codable, Sendable, Equatable {
    public var tokens: Int
    public var cost: Double
    public init(tokens: Int = 0, cost: Double = 0) { self.tokens = tokens; self.cost = cost }
}

/// One day's complete usage rollup.
public struct DayRollup: Codable, Sendable, Equatable {
    public var tokens: Int
    public var cost: Double
    public var messages: Int
    public var perProvider: [String: ProviderDaySlice]
    public var perModel: [String: ModelDaySlice]

    public init(
        tokens: Int = 0, cost: Double = 0, messages: Int = 0,
        perProvider: [String: ProviderDaySlice] = [:],
        perModel: [String: ModelDaySlice] = [:])
    {
        self.tokens = tokens; self.cost = cost; self.messages = messages
        self.perProvider = perProvider; self.perModel = perModel
    }
}

/// One month's uncapped rollup (survives the daily-tier cap).
public struct MonthRollup: Codable, Sendable, Equatable {
    public var tokens: Int
    public var cost: Double
    public var messages: Int
    public init(tokens: Int = 0, cost: Double = 0, messages: Int = 0) {
        self.tokens = tokens; self.cost = cost; self.messages = messages
    }
}

// MARK: - Archive

/// Durable per-day (≥370) + per-month (uncapped) usage rollup.
///
/// Invariant: a day is in EITHER `days` OR folded into `months` (never both),
/// so lifetime totals = sum(days) + sum(months) with no double count.
/// `foldedThroughDay` is the newest day key already evicted into `months`.
public struct DailyUsageArchive: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    /// Days of per-day detail to retain (> the 370 the year-heatmap needs).
    public static let retainDays = 400

    public var version: Int
    public var days: [String: DayRollup]        // "yyyy-MM-dd" -> rollup
    public var months: [String: MonthRollup]    // "yyyy-MM" -> uncapped rollup
    public var foldedThroughDay: String?        // days <= this are in `months`, not `days`
    public var lastUpdatedUnixMs: Int64

    public init(
        version: Int = DailyUsageArchive.currentVersion,
        days: [String: DayRollup] = [:],
        months: [String: MonthRollup] = [:],
        foldedThroughDay: String? = nil,
        lastUpdatedUnixMs: Int64 = 0)
    {
        self.version = version
        self.days = days
        self.months = months
        self.foldedThroughDay = foldedThroughDay
        self.lastUpdatedUnixMs = lastUpdatedUnixMs
    }

    // MARK: Merge — local scan (authoritative, replace-by-day)

    /// Folds a scan result's entries into the archive. Each scan carries the
    /// authoritative cumulative totals for every day it covers, so days are
    /// REPLACED (not added) — re-merging the same 30-day window is idempotent.
    /// Days already evicted into `months` are skipped (never reintroduced).
    ///
    /// The routine 30-day read uses this. Rewriting whole days is how a recount
    /// under newer rules reaches the window, and how usage that now falls on
    /// another day (after a time-zone change) leaves the day it used to be on.
    ///
    /// Not on the window's oldest day, though. The read covers 31 days, from
    /// the day of `now − 30 days` through today, and Claude Code's cleanup
    /// deletes transcripts last active before `now − 720 hours`: a moment on
    /// that oldest day (across a daylight-saving change, possibly the day after
    /// it). So the read sees only what is left of that day's Claude usage,
    /// which the archive recorded in full the day before, when it was the
    /// window's second-oldest day. A day the archive holds on or before
    /// `claudeCleanupReach` (`DailyUsageArchive.claudeCleanupReach(now:)`, which
    /// `DailyUsageArchiveManager.record` passes) is merged by `mergedDay`, as
    /// the year-long read merges every day. Later days are replaced whole.
    public mutating func mergeScanEntries(
        _ entries: [ScanEntry],
        claudeCleanupReach: String? = nil,
        retainDays: Int = DailyUsageArchive.retainDays)
    {
        merge(entries, byProvider: { day in claudeCleanupReach.map { day <= $0 } ?? false }, retainDays: retainDays)
    }

    // MARK: Merge — the year-long read (provider by provider)

    /// Folds the year-long read into an archive that may already hold months
    /// of days.
    ///
    /// Since v1.55 the read can run long after the archive filled up: "Last 30
    /// days only" on the consent screen, then older history allowed later from
    /// "Choose again…" or Settings. By then Claude Code has deleted many of the
    /// older transcripts. Its cleanup (default `cleanupPeriodDays` 30) goes
    /// file by file, by each session's last activity, so an older day comes
    /// back with no Claude usage, or with only the share of a session that was
    /// resumed later. Replacing the day lowered or removed Claude's share in
    /// the heatmap and the lifetime totals. Codex keeps its logs, but a day
    /// whose Codex logs were deleted by hand lost Codex's share the same way.
    ///
    /// So each day the archive already holds is merged by `mergedDay`, which
    /// never lowers a Claude slice. A day it lacks is written as read, and a
    /// day already folded into `months` is skipped.
    ///
    /// Keys: the read and the archive are matched by day key, so both must be
    /// Gregorian. The scanner writes `DayKey` keys, and `DailyUsageArchiveIO.load`
    /// converts keys an older version wrote in another calendar first.
    public mutating func mergeScanEntriesByProvider(_ entries: [ScanEntry], retainDays: Int = DailyUsageArchive.retainDays) {
        merge(entries, byProvider: { _ in true }, retainDays: retainDays)
    }

    /// Writes each day of a read: through `mergedDay` where `byProvider` says
    /// so and the archive holds the day, replaced whole otherwise.
    private mutating func merge(_ entries: [ScanEntry], byProvider: (String) -> Bool, retainDays: Int) {
        let modelProviders = Self.modelProviders(of: entries)
        for (dayKey, read) in Self.dayRollups(of: entries) {
            if let folded = foldedThroughDay, dayKey <= folded { continue }  // already in months
            if byProvider(dayKey), let stored = days[dayKey] {
                days[dayKey] = Self.mergedDay(read, over: stored, readModelProviders: modelProviders[dayKey] ?? [:])
            } else {
                days[dayKey] = read
            }
        }
        pruneAndFold(retainDays: retainDays)
    }

    // MARK: Merging one day provider by provider

    /// Claude Code's default `cleanupPeriodDays`: when a session starts, it
    /// deletes every transcript not written to for this many days.
    public static let claudeCodeCleanupDays = 30

    /// Providers whose tool deletes its own old logs, one file at a time.
    /// A read of such a provider's older day sees only the files that are
    /// left, so it can show more usage than the archive recorded, but a
    /// smaller figure is not evidence of less. Codex keeps its logs.
    static let providersThatDeleteOldLogs: Set<String> = ["Claude"]

    /// The newest day Claude Code's default cleanup can have reached by `now`,
    /// in `timeZone`.
    ///
    /// Claude Code's cutoff is `now − cleanupPeriodDays × 24 hours`, 720 hours
    /// for the default 30, not 30 calendar days: across a daylight-saving change
    /// the two are an hour apart and can fall on different days. On the cutoff's
    /// day, transcripts last active before it may be gone.
    ///
    /// Later days keep every transcript unless `cleanupPeriodDays` is shorter
    /// than 30, and that is not only the user's choice: Claude Code reads it
    /// from user, project, local and managed-policy settings, so a project's
    /// `.claude/settings.json` or an organization's policy can shorten it. This
    /// does not read any of them.
    public static func claudeCleanupReach(now: Date = Date(), in timeZone: TimeZone = .current) -> String {
        let cutoff = now.addingTimeInterval(-Double(claudeCodeCleanupDays) * 86_400)
        return DayKey.string(from: cutoff, in: timeZone)
    }

    /// One day of a read merged over the day the archive holds, provider by
    /// provider. Each provider's slice comes whole from one side:
    ///
    /// - a provider the read did not find keeps its stored slice;
    /// - Claude keeps its stored slice where that has more tokens than the
    ///   read's (or as many tokens and more messages): the transcripts the read
    ///   did not see may have been deleted;
    /// - otherwise the provider takes the read's slice. For Codex that is how
    ///   a recount under newer rules reaches an older day, lower or higher.
    ///
    /// The day's totals are the sum of the chosen slices. Where the read's
    /// slice is chosen for every provider, the result is the read itself, as
    /// the whole-day rule gives; where the stored slice is chosen for every
    /// provider, it is the stored day.
    ///
    /// Models: a stored day does not record which provider a model is from.
    /// Each stored model is attributed to one of the day's providers where
    /// that can be told (`storedModelOwners(of:readModelProviders:)`) and goes
    /// with that provider's slice, so a model name that changed between
    /// versions is not counted under both names. A model that cannot be
    /// attributed is kept only where every provider with tokens no attributed
    /// model accounts for keeps its slice, and the read does not report it:
    /// kept beside a provider the read replaced, it could be counted twice,
    /// and the models would add up to more than the day.
    ///
    /// Limits. The archive cannot tell deleted transcripts from usage counted
    /// lower under newer rules, so a lower Claude recount does not reach a day
    /// this merges (the routine read's newer 30 days still take it). Codex logs
    /// deleted by hand in part are found, and take the smaller figure. And
    /// after a time-zone change, usage now counted on a neighbouring day is
    /// counted there, while its old day keeps a provider the read no longer
    /// finds on it, or the larger Claude slice.
    static func mergedDay(_ read: DayRollup, over stored: DayRollup, readModelProviders: [String: String]) -> DayRollup {
        var kept: Set<String> = []   // providers whose stored slice stays
        for (provider, storedSlice) in stored.perProvider {
            guard let readSlice = read.perProvider[provider] else {
                kept.insert(provider)
                continue
            }
            if providersThatDeleteOldLogs.contains(provider),
               (storedSlice.tokens, storedSlice.messages) > (readSlice.tokens, readSlice.messages) {
                kept.insert(provider)
            }
        }
        guard !kept.isEmpty else { return read }
        if read.perProvider.keys.allSatisfy(kept.contains) { return stored }

        var day = DayRollup()
        func add(_ provider: String, _ slice: ProviderDaySlice) {
            day.perProvider[provider] = slice
            day.tokens += slice.tokens
            day.cost += slice.cost
            day.messages += slice.messages
        }
        for (provider, slice) in read.perProvider where !kept.contains(provider) { add(provider, slice) }
        for provider in kept.sorted() { if let slice = stored.perProvider[provider] { add(provider, slice) } }

        for (model, slice) in read.perModel {
            if let owner = readModelProviders[model], kept.contains(owner) { continue }
            day.perModel[model] = slice
        }
        let (owners, unexplained) = Self.storedModelOwners(of: stored, readModelProviders: readModelProviders)
        // A model left unattributed is some provider's whose tokens the
        // attributed models do not account for.
        let keepUnattributed = unexplained.allSatisfy { $0.value <= 0 || kept.contains($0.key) }
        for (model, slice) in stored.perModel {
            if let owner = owners[model] {
                if kept.contains(owner) { day.perModel[model] = slice }
            } else if keepUnattributed, day.perModel[model] == nil {
                day.perModel[model] = slice
            }
        }
        return day
    }

    /// Which of a stored day's providers each of its models belongs to, where
    /// that can be told, and each provider's tokens that no attributed model
    /// accounts for.
    ///
    /// A model goes first by `provider(ofStoredModel:on:readModelProviders:)`.
    /// One that leaves open (a name no rule knows, on a day with both
    /// providers, that the read does not report) goes to the one provider whose
    /// leftover tokens (its slice less the models attributed to it so far) can
    /// hold it, since its tokens are part of its own provider's leftover. That
    /// repeats while it attributes something, as each model attributed shrinks
    /// a leftover. A model two providers' leftovers could hold, or none, stays
    /// out of `owners`.
    static func storedModelOwners(of stored: DayRollup, readModelProviders: [String: String])
        -> (owners: [String: String], unexplained: [String: Int])
    {
        var owners: [String: String] = [:]
        var leftover = stored.perProvider.mapValues(\.tokens)
        var open: [String: Int] = [:]
        for (model, slice) in stored.perModel {
            if let owner = provider(ofStoredModel: model, on: stored, readModelProviders: readModelProviders) {
                owners[model] = owner
                leftover[owner, default: 0] -= slice.tokens
            } else {
                open[model] = slice.tokens
            }
        }
        var attributed = true
        while attributed {
            attributed = false
            for model in open.keys.sorted() {
                guard let tokens = open[model] else { continue }
                let holders = leftover.filter { $0.value >= tokens }.keys
                guard holders.count == 1, let owner = holders.first else { continue }
                owners[model] = owner
                leftover[owner, default: 0] -= tokens
                open[model] = nil
                attributed = true
            }
        }
        return (owners, leftover)
    }

    /// Which of a stored day's providers `model` belongs to: the provider the
    /// read reports it under that day, else the provider its name belongs to,
    /// else the day's only provider. nil when none of these applies.
    static func provider(ofStoredModel model: String, on stored: DayRollup, readModelProviders: [String: String]) -> String? {
        let providers = stored.perProvider
        if let owner = readModelProviders[model], providers[owner] != nil { return owner }
        if let owner = Self.provider(ofModelNamed: model), providers[owner] != nil { return owner }
        return providers.count == 1 ? providers.keys.first : nil
    }

    /// The provider a model name belongs to: `claude-…` names are Claude's;
    /// `gpt-…`, `o3`-style and `…codex…` names are Codex's. nil for any other
    /// name, such as a third-party model behind Claude Code.
    static func provider(ofModelNamed model: String) -> String? {
        let name = model.lowercased()
        if name.contains("claude") { return "Claude" }
        if name.hasPrefix("gpt-") || name.contains("codex")
            || name.range(of: #"^o\d"#, options: .regularExpression) != nil {
            return "Codex"
        }
        return nil
    }

    /// For each day of a read, the provider each model was reported under.
    /// A model reported under more than one provider that day is left out.
    static func modelProviders(of entries: [ScanEntry]) -> [String: [String: String]] {
        var seen: [String: [String: Set<String>]] = [:]
        for e in entries where !e.isMessageBucket {
            seen[e.date, default: [:]][e.model, default: []].insert(e.provider)
        }
        return seen.mapValues { models in models.compactMapValues { $0.count == 1 ? $0.first : nil } }
    }

    /// Each day's rollup, built from that day's scan entries alone.
    static func dayRollups(of entries: [ScanEntry]) -> [String: DayRollup] {
        var rebuilt: [String: DayRollup] = [:]
        for e in entries {
            let tokens = max(0, e.inputTokens) + max(0, e.cachedTokens) + max(0, e.outputTokens)
            let cost = max(0, e.cost)
            let messages = max(0, e.messages)
            var day = rebuilt[e.date] ?? DayRollup()
            day.tokens += tokens
            day.cost += cost
            day.messages += messages
            var prov = day.perProvider[e.provider] ?? ProviderDaySlice()
            prov.tokens += tokens; prov.cost += cost; prov.messages += messages
            day.perProvider[e.provider] = prov
            // Skip the synthetic message bucket from the per-model breakdown —
            // it carries message counts, not real model usage (0 tokens/cost).
            if !e.isMessageBucket {
                var model = day.perModel[e.model] ?? ModelDaySlice()
                model.tokens += tokens; model.cost += cost
                day.perModel[e.model] = model
            }
            rebuilt[e.date] = day
        }
        return rebuilt
    }

    // MARK: Merge — cloud (fill-only, non-destructive)

    /// Fills days that the local scan has NEVER recorded (other devices /
    /// pre-history) from cloud daily-usage rows. Non-destructive: only writes a
    /// day absent from `days` — a locally-known day is left untouched even if it
    /// has 0 tokens, because it may still carry local message counts (near a
    /// UTC boundary) that cloud rows lack. Folded days are never reintroduced.
    public mutating func mergeCloudDays(_ rows: [CloudEntry], retainDays: Int = DailyUsageArchive.retainDays) {
        var byDay: [String: DayRollup] = [:]
        for r in rows {
            let tokens = max(0, r.inputTokens) + max(0, r.cachedTokens) + max(0, r.outputTokens)
            let cost = max(0, r.cost)
            var day = byDay[r.date] ?? DayRollup()
            day.tokens += tokens; day.cost += cost
            var prov = day.perProvider[r.provider] ?? ProviderDaySlice()
            prov.tokens += tokens; prov.cost += cost
            day.perProvider[r.provider] = prov
            var model = day.perModel[r.model] ?? ModelDaySlice()
            model.tokens += tokens; model.cost += cost
            day.perModel[r.model] = model
            byDay[r.date] = day
        }
        for (dayKey, rollup) in byDay {
            if let folded = foldedThroughDay, dayKey <= folded { continue }
            if days[dayKey] == nil { days[dayKey] = rollup }   // fill absent days only
        }
        pruneAndFold(retainDays: retainDays)
    }

    // MARK: Keys written before day keys were pinned to Gregorian

    /// The archive with every key in Gregorian numbering.
    ///
    /// Until `DayKey`, a Mac set to another calendar recorded days under that
    /// calendar's numbering. Left alone those keys never reach the heatmap,
    /// sit beside the Gregorian copies the scanner now writes (counted twice in
    /// lifetime totals), and under the Buddhist calendar — Thailand's default —
    /// they sort after every real day: `foldedThroughDay = "2569-…"` would make
    /// every later merge skip its day as already folded. Each key is re-read in
    /// the calendar that wrote it (`writtenIn`, the device's) and rekeyed; a key
    /// that still names no plausible day is dropped. A converted day replaces a
    /// Gregorian one already present, because on such a Mac the only Gregorian
    /// days so far came from cloud fill, which never outranks the local scan.
    /// Month rollups hold disjoint evicted days, so colliding months add up.
    public func normalizingDayKeys(writtenIn source: Calendar = .current) -> DailyUsageArchive {
        var out = self
        out.days = [:]
        var converted: [String: DayRollup] = [:]
        for (key, rollup) in days {
            guard let normalized = DayKey.normalizedStoredKey(key, writtenIn: source) else { continue }
            if normalized == key { out.days[key] = rollup } else { converted[normalized] = rollup }
        }
        for (key, rollup) in converted { out.days[key] = rollup }

        out.months = [:]
        for (key, rollup) in months {
            guard let day = DayKey.normalizedStoredKey(key + "-01", writtenIn: source) else { continue }
            let monthKey = String(day.prefix(7))
            var month = out.months[monthKey] ?? MonthRollup()
            month.tokens += rollup.tokens
            month.cost += rollup.cost
            month.messages += rollup.messages
            out.months[monthKey] = month
        }

        out.foldedThroughDay = foldedThroughDay.flatMap {
            DayKey.normalizedStoredKey($0, writtenIn: source)
        }
        return out
    }

    /// Evicts days older than the retention window into their month rollup.
    private mutating func pruneAndFold(retainDays: Int) {
        guard days.count > retainDays else { return }
        let sorted = days.keys.sorted()
        let evictCount = days.count - retainDays
        for dayKey in sorted.prefix(evictCount) {
            guard let rollup = days.removeValue(forKey: dayKey) else { continue }
            let monthKey = String(dayKey.prefix(7))   // "yyyy-MM"
            var month = months[monthKey] ?? MonthRollup()
            month.tokens += rollup.tokens
            month.cost += rollup.cost
            month.messages += rollup.messages
            months[monthKey] = month
            if foldedThroughDay == nil || dayKey > foldedThroughDay! { foldedThroughDay = dayKey }
        }
    }
}

// MARK: - Merge input adapters (decoupled from CostUsageScanResult / DailyUsage)

/// A single scan entry, decoupled from `CostUsageScanResult.DailyEntry` so the
/// archive core stays cross-platform + independently testable.
public struct ScanEntry: Sendable, Equatable {
    public let date: String
    public let provider: String
    public let model: String
    public let inputTokens: Int
    public let cachedTokens: Int
    public let outputTokens: Int
    public let cost: Double
    public let messages: Int
    /// The synthetic `__claude_msg__` bucket (messages only, no real model usage).
    public var isMessageBucket: Bool { model == ScanEntry.messageBucketModel }
    public static let messageBucketModel = "__claude_msg__"

    public init(
        date: String, provider: String, model: String,
        inputTokens: Int, cachedTokens: Int, outputTokens: Int,
        cost: Double, messages: Int)
    {
        self.date = date; self.provider = provider; self.model = model
        self.inputTokens = inputTokens; self.cachedTokens = cachedTokens
        self.outputTokens = outputTokens; self.cost = cost; self.messages = messages
    }
}

/// A cloud daily-usage row (get_daily_usage) — tokens + cost, no messages.
public struct CloudEntry: Sendable, Equatable {
    public let date: String
    public let provider: String
    public let model: String
    public let inputTokens: Int
    public let cachedTokens: Int
    public let outputTokens: Int
    public let cost: Double
    public init(
        date: String, provider: String, model: String,
        inputTokens: Int, cachedTokens: Int, outputTokens: Int, cost: Double)
    {
        self.date = date; self.provider = provider; self.model = model
        self.inputTokens = inputTokens; self.cachedTokens = cachedTokens
        self.outputTokens = outputTokens; self.cost = cost
    }
}

// MARK: - Persistence (Application Support/CLIPulse/usage-history-v1.json)

public enum DailyUsageArchiveIO {
    static let fileName = "usage-history-v1.json"

    /// `~/Library/Application Support/CLIPulse` (or the sandbox container's
    /// equivalent) — the app's OWN writable dir; needs no security-scoped
    /// bookmark (unlike the JSONL scan roots).
    public static func defaultRoot() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent("CLIPulse", isDirectory: true)
    }

    public static func fileURL(root: URL? = nil) -> URL {
        (root ?? defaultRoot()).appendingPathComponent(fileName, isDirectory: false)
    }

    public static func load(root: URL? = nil) -> DailyUsageArchive {
        let url = fileURL(root: root)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(DailyUsageArchive.self, from: data),
              decoded.version == DailyUsageArchive.currentVersion
        else {
            return DailyUsageArchive()
        }
        return decoded.normalizingDayKeys()
    }

    @discardableResult
    public static func save(_ archive: DailyUsageArchive, root: URL? = nil) -> Bool {
        let url = fileURL(root: root)
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(archive)
            // Atomic write via tmp + replace (CostUsageCacheIO idiom).
            let tmp = dir.appendingPathComponent(".tmp-\(UUID().uuidString).json")
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            return true
        } catch {
            return false
        }
    }
}
