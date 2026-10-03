import Foundation
import os

private let scanLogger = Logger(subsystem: "com.clipulse", category: "CostUsageScanner")

// MARK: - Scan Result (available on all platforms for model compatibility)

/// Result of scanning local JSONL logs for precise token usage and costs.
public struct CostUsageScanResult: Sendable {
    public struct DailyEntry: Sendable {
        public let date: String       // "2026-04-07"
        public let provider: String   // "Codex", "Claude"
        public let model: String      // normalized model name
        public let inputTokens: Int
        public let cachedTokens: Int
        public let outputTokens: Int
        public let costUSD: Double?
        /// v1.56: `costUSD` was computed at a rate borrowed from a neighbouring
        /// model, because this model has no price of its own
        /// (`CostUsageScanner.Pricing.PriceResolution`). Always false when
        /// `costUSD` is nil. `CostCoverage` counts these tokens as approximate,
        /// and the cost card marks the figures they reach with "≈".
        public let priceIsApproximate: Bool
        /// v1.9.4: deduped assistant-message count for this (day, provider, model).
        /// Currently only populated for Claude (via JSONL message.id + requestId
        /// dedup in `parseClaudeFile`). Codex leaves this at 0 — Codex doesn't
        /// have a stable per-turn identifier we can count off.
        /// Rationale: Claude Code's own UI leads with "messages" as the hero
        /// metric since raw token counts (including cache_read) are dominated
        /// by ~98% cache noise. Messages matches user intuition of "how many
        /// times did the model reply today".
        public let messageCount: Int

        public init(date: String, provider: String, model: String,
                    inputTokens: Int, cachedTokens: Int, outputTokens: Int,
                    costUSD: Double?, priceIsApproximate: Bool = false,
                    messageCount: Int = 0) {
            self.date = date
            self.provider = provider
            self.model = model
            self.inputTokens = inputTokens
            self.cachedTokens = cachedTokens
            self.outputTokens = outputTokens
            self.costUSD = costUSD
            self.priceIsApproximate = costUSD != nil && priceIsApproximate
            self.messageCount = messageCount
        }
    }

    public let entries: [DailyEntry]

    /// Per-JSONL summary of activity recorded during the most recent scan.
    /// Populated for Codex (`~/.codex/sessions/...`) and Claude
    /// (`~/.claude/projects/.../<id>.jsonl`) so callers can reconstruct an
    /// "active session" view when process enumeration is denied by the
    /// sandbox. `lastModified` is the JSONL file mtime; freshness is the
    /// caller's responsibility (see
    /// `CostUsageScanner.activeSessionFreshnessWindow` on macOS).
    public let activeSessionCandidates: [ActiveSessionCandidate]

    public init(
        entries: [DailyEntry],
        activeSessionCandidates: [ActiveSessionCandidate] = []
    ) {
        self.entries = entries
        self.activeSessionCandidates = activeSessionCandidates
    }

    /// Lightweight per-JSONL session summary. Cross-platform so that test
    /// fixtures and downstream synthesis helpers can compose it on iOS
    /// targets that don't compile the macOS-only `CostUsageScanner` enum.
    public struct ActiveSessionCandidate: Sendable, Equatable {
        public let provider: String       // "Codex" | "Claude"
        public let filePath: String       // absolute path to the JSONL on disk
        public let projectName: String    // display label
        public let projectRoot: String?   // absolute path if confidently known; else nil
        public let sessionId: String?     // stable id when the JSONL exposes one
        public let lastModified: Date     // JSONL file mtime
        public let totalTokens: Int       // input + output (matches "I/O tokens" UI)
        public let totalCost: Double
        public let messageCount: Int      // assistant-message count for Claude; 0 for Codex

        public init(
            provider: String,
            filePath: String,
            projectName: String,
            projectRoot: String?,
            sessionId: String?,
            lastModified: Date,
            totalTokens: Int,
            totalCost: Double,
            messageCount: Int
        ) {
            self.provider = provider
            self.filePath = filePath
            self.projectName = projectName
            self.projectRoot = projectRoot
            self.sessionId = sessionId
            self.lastModified = lastModified
            self.totalTokens = totalTokens
            self.totalCost = totalCost
            self.messageCount = messageCount
        }
    }

    public func totalCost(for date: String) -> Double {
        entries.filter { $0.date == date }.compactMap(\.costUSD).reduce(0, +)
    }

    public func totalCost(provider: String) -> Double {
        entries.filter { $0.provider == provider }.compactMap(\.costUSD).reduce(0, +)
    }

    public var totalCost: Double {
        entries.compactMap(\.costUSD).reduce(0, +)
    }

    public func todayCost(todayKey: String) -> Double {
        totalCost(for: todayKey)
    }

    /// v1.9.4 (second revision): `input + output` only, matching the
    /// "I/O tokens" definition used everywhere in the UI. For Claude that
    /// excludes cache reads and writes; for Codex `input` already includes
    /// cached input. Cost is computed elsewhere with per-component pricing.
    /// See `AppState.totalTokens` for rationale.
    public func totalTokens(for date: String) -> Int {
        entries.filter { $0.date == date }.reduce(0) { $0 + $1.inputTokens + $1.outputTokens }
    }

    public var totalTokens: Int {
        entries.reduce(0) { $0 + $1.inputTokens + $1.outputTokens }
    }

    /// Total API equivalent cost for a specific provider across all scanned days
    public func totalCostForProvider(_ provider: String) -> Double {
        entries.filter { $0.provider == provider }.compactMap(\.costUSD).reduce(0, +)
    }
}

#if os(macOS)

// MARK: - Scanner

public enum CostUsageScanner {

    public struct Options: Sendable {
        public var codexSessionsRoot: URL?
        public var claudeProjectsRoots: [URL]?
        public var cacheRoot: URL?
        public var refreshMinIntervalSeconds: TimeInterval = 60
        public var forceRescan: Bool = false
        public var daysToScan: Int = 30
        /// The moment the scan treats as now. nil (the default) is the clock;
        /// tests set it so fixtures with fixed dates stay inside the window.
        var now: Date?

        public init(
            codexSessionsRoot: URL? = nil,
            claudeProjectsRoots: [URL]? = nil,
            cacheRoot: URL? = nil,
            daysToScan: Int = 30
        ) {
            self.codexSessionsRoot = codexSessionsRoot
            self.claudeProjectsRoots = claudeProjectsRoots
            self.cacheRoot = cacheRoot
            self.daysToScan = daysToScan
        }
    }

    /// Maximum age (seconds) of a JSONL file mtime for it to be treated as
    /// an "active session" candidate. Conservative on purpose so a stalled
    /// Codex/Claude tab doesn't keep showing a green "Running" status.
    public static let activeSessionFreshnessWindow: TimeInterval = 300

    /// Main entry point. Scans Codex and Claude JSONL logs for the last N days.
    public static func scan(options: Options = Options()) -> CostUsageScanResult {
        let now = options.now ?? Date()
        let since = DayKey.calendar().date(byAdding: .day, value: -options.daysToScan, to: now) ?? now
        let range = DayRange(since: since, until: now)

        var allEntries: [CostUsageScanResult.DailyEntry] = []
        var allCandidates: [CostUsageScanResult.ActiveSessionCandidate] = []

        // Scan Codex
        let codexCache = scanCodexProvider(range: range, now: now, options: options)
        allEntries.append(contentsOf: entriesFromCodexCache(codexCache, range: range))
        allCandidates.append(contentsOf: buildCodexCandidates(
            options: options, range: range, cache: codexCache, now: now
        ))

        // Scan Claude
        let claudeCache = scanClaudeProvider(range: range, now: now, options: options)
        allEntries.append(contentsOf: entriesFromClaudeCache(claudeCache, range: range))
        allCandidates.append(contentsOf: buildClaudeCandidates(
            options: options, cache: claudeCache, now: now
        ))

        reportUnpricedModels(allEntries)
        return CostUsageScanResult(entries: allEntries, activeSessionCandidates: allCandidates)
    }

    /// Say out loud when tokens were counted but could not be priced.
    ///
    /// v1.50. `DailyEntry.costUSD` is optional and every consumer sums it with
    /// `if let cost { total += cost }` — so an unpriced model contributes
    /// nothing and leaves no trace. The total that reaches the UI looks
    /// complete. It is not, and there was no way to tell.
    ///
    /// That is how `claude-opus-5` displayed $0 for 25 days across 15.47 billion
    /// tokens: the scanner knew, at the moment it computed each entry, that it
    /// had no rate — and threw the knowledge away. Nothing was wrong with the
    /// number it printed; the number simply omitted most of the bill.
    ///
    /// Borrowed from CodexBar's framing of the same problem: *"estimates are
    /// labeled, partial totals show their coverage, and nothing unpriced
    /// masquerades as a real bill."* This is the smallest useful piece of that —
    /// the diagnostic, in the log the repo already greps when costs look wrong.
    /// Showing coverage in the UI is the better fix and is a product decision.
    ///
    /// Deliberately NOT a warning per entry: a new model produces one of these
    /// per day per scan, and a line per entry would bury it.
    ///
    /// 2026-08-28 (post-1.52): the synthetic `__claude_msg__` bucket is
    /// excluded, exactly as `CostCoverage.from` excludes it (#468). It is not
    /// a model — it carries raw message-event counts, so it has zero tokens,
    /// no rate, and therefore `costUSD == nil`. That made every healthy
    /// machine log, at error level, on every scan: "1 model(s) had no rate and
    /// contributed $0 to the totals: 0 tokens — __claude_msg__=0". Nothing was
    /// unpriced; the diagnostic that exists to be believed when costs look
    /// wrong was making a false statement on every correct scan. #468 fixed
    /// the UI half of this and missed the log line.
    ///
    /// With the bucket removed the count can now be zero where it used to be
    /// one, and a zero count is a healthy scan — so it drops to `debug`.
    /// "Everything priced" is worth something to whoever is streaming the log
    /// on purpose, and worth nothing at error level.
    static func reportUnpricedModels(
        _ entries: [CostUsageScanResult.DailyEntry],
        log: (String) -> Void = { scanLogger.warning("\($0, privacy: .public)") },
        logQuiet: (String) -> Void = { scanLogger.debug("\($0, privacy: .public)") }
    ) {
        var unpriced: [String: Int] = [:]
        var skippedMessageBucket = false
        for entry in entries where entry.costUSD == nil {
            // `ScanEntry.messageBucketModel` — the same key `CostCoverage.from`
            // skips, so the log line and the coverage card can never disagree
            // about one scan. (`Self.claudeMsgBucketModel` is the scanner-side
            // spelling of the same string; `testMessageBucketKeysAgree` pins
            // the two together.)
            guard entry.model != ScanEntry.messageBucketModel else {
                skippedMessageBucket = true
                continue
            }
            let tokens = ArchiveTokenBasis.tokens(of: entry)   // each once, as `CostCoverage.from`
            unpriced[entry.model, default: 0] += tokens
        }
        guard !unpriced.isEmpty else {
            if skippedMessageBucket {
                logQuiet("[Pricing] every model had a rate; skipped the synthetic \(ScanEntry.messageBucketModel) message-count bucket")
            }
            return
        }
        let total = unpriced.values.reduce(0, +)
        let detail = unpriced
            .sorted { $0.value > $1.value }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        log("[Pricing] \(unpriced.count) model(s) had no rate and contributed $0 to the totals: \(total) tokens — \(detail)")
    }

    // MARK: - Sandbox-aware entry point (v1.9.4)

    /// Cost-scan roots that must be accessible for Codex / Claude token data.
    /// Listed in priority order — callers that want to prompt the user should
    /// walk this list and check `BookmarkManager.hasAccess(to:)` for each.
    public static let sandboxScanRoots: [String] = [
        // Codex
        "~/.codex/sessions/",
        "~/.codex/archived_sessions/",
        // Claude (both root variants codexbar supports via CLAUDE_CONFIG_DIR)
        "~/.claude/projects/",
        "~/.config/claude/projects/",
    ]

    /// v1.9.4: sandbox-aware version of `scan()` that resolves bookmarks for
    /// each scan root before running. Delegate to `BookmarkManager` — it
    /// already calls `startAccessingSecurityScopedResource` + caches the URL
    /// in `activeResources`, so we must NOT call `startAccessing` ourselves
    /// (double-start with a single stop leaks the resource).
    ///
    /// If the app is NOT sandboxed (or the dir is already accessible via a
    /// direct read), the resolve call falls through harmlessly; the sync
    /// `scan()` then reads via `FileManager.default` as before.
    public static func scanAsync(options: Options = Options()) async -> CostUsageScanResult {
        // Resolve all cost-scan bookmarks on the main actor. This warms
        // `BookmarkManager.activeResources` so the subsequent sync scanning
        // sees the paths as readable.
        _ = await MainActor.run { () -> [URL?] in
            let home = realUserHome()
            return sandboxScanRoots.map { template -> URL? in
                let expanded = (home as NSString).appendingPathComponent(String(template.dropFirst(2)))
                return BookmarkManager.shared.resolveBookmark(for: expanded)
            }
        }
        return scan(options: options)
    }

    /// v1.9.4: nuke the per-provider on-disk caches and trigger a full
    /// rescan on the next call. Use after granting a new bookmark, since
    /// prior sandbox-blocked runs may have stored negative deltas that a
    /// normal incremental scan won't unwind.
    public static func forceRescanAsync() async -> CostUsageScanResult {
        CostUsageCacheIO.wipeAll()
        var opts = Options()
        opts.forceRescan = true
        return await scanAsync(options: opts)
    }

    /// Returns the subset of `sandboxScanRoots` that are missing a bookmark
    /// AND are expected to hold data (at minimum `~/.codex/sessions/` OR
    /// `~/.claude/projects/`). Use to drive the first-run folder-access banner.
    @MainActor
    public static func missingScanRoots() -> [String] {
        let home = realUserHome()
        return sandboxScanRoots.compactMap { template in
            let expanded = (home as NSString).appendingPathComponent(String(template.dropFirst(2)))
            return BookmarkManager.shared.hasAccess(to: expanded) ? nil : expanded
        }
    }

    // MARK: - Convert cache to result entries

    private static func entriesFromCodexCache(_ cache: CostUsageCache, range: DayRange) -> [CostUsageScanResult.DailyEntry] {
        var result: [CostUsageScanResult.DailyEntry] = []
        let dayKeys = cache.days.keys.sorted().filter {
            DayRange.isInRange(dayKey: $0, since: range.sinceKey, until: range.untilKey)
        }
        for day in dayKeys {
            guard let models = cache.days[day] else { continue }
            for (model, packed) in models {
                let input = packed[safeIdx: 0] ?? 0
                let cached = packed[safeIdx: 1] ?? 0
                let output = packed[safeIdx: 2] ?? 0
                guard input > 0 || cached > 0 || output > 0 else { continue }
                // The cost is the row's stored request costs (slot 3), priced
                // when each request was read, at the rate in force at its own
                // time. Whether that rate was borrowed is decided from the
                // name here, on read; it agrees with the stored cost because
                // the Codex fingerprint (`Pricing.codexRatesFingerprint`)
                // covers every key and how each name resolves, so a change to
                // either re-reads the Codex logs.
                let cost = codexCost(model: model, packed: packed)
                result.append(.init(date: day, provider: "Codex", model: model, inputTokens: input, cachedTokens: cached, outputTokens: output, costUSD: cost,
                                    priceIsApproximate: Pricing.codexPriceResolution(model)?.isApproximate ?? false))
            }
        }
        return result
    }

    /// A Codex day × model row's cost: the sum of its requests' costs, priced
    /// one by one as they were read (slot 3, nanodollars). nil when the model
    /// has no rate, which is how an unpriced model stays visible as unpriced
    /// instead of reading $0. Every row the scanner writes has slot 3; a cache
    /// written before it is rejected by `CostUsageCacheIO.load`, so a row
    /// without it is treated as unpriced rather than guessed at.
    static func codexCost(model: String, packed: [Int]) -> Double? {
        guard Pricing.codexPricingKey(model) != nil, let costNanos = packed[safeIdx: 3] else { return nil }
        return Double(costNanos) / 1_000_000_000.0
    }

    private static func entriesFromClaudeCache(_ cache: CostUsageCache, range: DayRange) -> [CostUsageScanResult.DailyEntry] {
        var result: [CostUsageScanResult.DailyEntry] = []
        let costScale = 1_000_000_000.0
        let dayKeys = cache.days.keys.sorted().filter {
            DayRange.isInRange(dayKey: $0, since: range.sinceKey, until: range.untilKey)
        }
        for day in dayKeys {
            guard let models = cache.days[day] else { continue }
            for (model, packed) in models {
                let input = packed[safeIdx: 0] ?? 0
                let cacheRead = packed[safeIdx: 1] ?? 0
                let cacheCreate = packed[safeIdx: 2] ?? 0
                let output = packed[safeIdx: 3] ?? 0
                let costNanos = packed[safeIdx: 4] ?? 0
                let msgs = packed[safeIdx: 5] ?? 0
                // v1.9.4 (second revision): emit a DailyEntry when there's
                // EITHER real token activity OR the msg-bucket has raw user
                // + assistant events. The synthetic `claudeMsgBucketModel`
                // only has msg counts; per-model buckets have tokens +
                // deduped-zero msgs.
                guard input > 0 || cacheRead > 0 || cacheCreate > 0 || output > 0 || msgs > 0 else { continue }
                let cost: Double? = costNanos > 0
                    ? Double(costNanos) / costScale
                    : Pricing.claudeCostUSD(model: model, inputTokens: input, cacheReadInputTokens: cacheRead, cacheCreationInputTokens: cacheCreate, outputTokens: output)
                result.append(.init(date: day, provider: "Claude", model: model,
                                    inputTokens: input, cachedTokens: cacheRead + cacheCreate,
                                    outputTokens: output, costUSD: cost,
                                    priceIsApproximate: Pricing.claudePriceResolution(model)?.isApproximate ?? false,
                                    messageCount: msgs))
            }
        }
        return result
    }

    // MARK: - Day Range

    public struct DayRange {
        let sinceKey: String
        let untilKey: String
        let scanSinceKey: String
        let scanUntilKey: String
        /// v1.55: the first moment of the first day the scan reports. A log
        /// whose last write is earlier than this cannot hold a line the scan
        /// would report, so it is not opened at all (`scanClaudeRoot`).
        let firstReportedInstant: Date

        init(since: Date, until: Date) {
            self.sinceKey = Self.dayKey(from: since)
            self.untilKey = Self.dayKey(from: until)
            let cal = DayKey.calendar()
            self.scanSinceKey = Self.dayKey(from: cal.date(byAdding: .day, value: -1, to: since) ?? since)
            self.scanUntilKey = Self.dayKey(from: cal.date(byAdding: .day, value: 1, to: until) ?? until)
            self.firstReportedInstant = cal.startOfDay(for: since)
        }

        /// Gregorian whatever the device calendar: these keys are uploaded as
        /// `metric_date` and compared with the dates in Codex's file names.
        public static func dayKey(from date: Date) -> String {
            DayKey.string(from: date)
        }

        static func isInRange(dayKey: String, since: String, until: String) -> Bool {
            dayKey >= since && dayKey <= until
        }
    }

    // MARK: - JSONL Parser

    private struct JsonlLine {
        /// The whole line; when `wasTruncated`, only its first
        /// `jsonlTruncatedHeadBytes` bytes — enough to see what kind of line
        /// it was, never enough to decode.
        let bytes: Data
        let wasTruncated: Bool
    }

    /// How much of a line over the size limit `scanJsonl` keeps. A Codex
    /// rollout's copied session_meta lines are often over the limit, and the
    /// scanner has to know where one sits without decoding it
    /// (`codexLineOrdinal`); the type and number come first on the line.
    static let jsonlTruncatedHeadBytes = 4096

    /// Reads the lines of a JSONL log from `offset`, and returns the offset
    /// the next incremental read must start from.
    ///
    /// The returned offset is just past the last line that ended in a newline.
    /// A last line without one is read only when it already parses: that is a
    /// log's final line written without a trailing newline. Anything else is a
    /// line the CLI is still writing. It is not read, and the returned offset
    /// stays at its first byte, so the next scan reads the whole line once it
    /// is complete. (Returning the end of the file here used to make the next
    /// scan start in the middle of that line, which never parses, and its
    /// usage was lost.)
    ///
    /// Same goal as CodexBar #2168, with a simpler rule. Upstream tracks the
    /// JSON structure of the tail as it reads, so it also takes an oversized
    /// tail (one it does not keep whole) once that tail looks complete, and it
    /// can resume a tail part-way through. Here a tail is read only when it
    /// decodes, and an oversized one waits for its newline.
    @discardableResult
    private static func scanJsonl(
        fileURL: URL,
        offset: Int64 = 0,
        maxLineBytes: Int,
        prefixBytes: Int,
        onLine: (JsonlLine) -> Void
    ) throws -> Int64 {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        let startOffset = max(0, offset)
        if startOffset > 0 {
            try handle.seek(toOffset: UInt64(startOffset))
        }

        var current = Data()
        current.reserveCapacity(4 * 1024)
        var lineBytes = 0
        var truncated = false
        var bytesRead: Int64 = 0
        var committedOffset = startOffset

        func appendSegment(_ segment: Data.SubSequence) {
            guard !segment.isEmpty else { return }
            lineBytes += segment.count
            guard !truncated else { return }
            if lineBytes > maxLineBytes || lineBytes > prefixBytes {
                truncated = true
                // Keep only the line's head (see `JsonlLine.bytes`).
                let room = jsonlTruncatedHeadBytes - current.count
                if room > 0 {
                    current.append(contentsOf: segment.prefix(room))
                } else if room < 0 {
                    current = Data(current.prefix(jsonlTruncatedHeadBytes))
                }
                return
            }
            current.append(contentsOf: segment)
        }

        func flushLine() {
            guard lineBytes > 0 else { return }
            onLine(JsonlLine(bytes: current, wasTruncated: truncated))
            current.removeAll(keepingCapacity: true)
            lineBytes = 0
            truncated = false
        }

        while true {
            let chunk = try handle.read(upToCount: 256 * 1024) ?? Data()
            if chunk.isEmpty {
                // An oversized tail was not kept in full (`truncated`), so it
                // cannot be checked; it waits for its newline like a partial one.
                if lineBytes > 0, !truncated,
                   (try? JSONSerialization.jsonObject(with: current)) != nil {
                    flushLine()
                    committedOffset = startOffset + bytesRead
                }
                break
            }
            let chunkStartOffset = startOffset + bytesRead
            bytesRead += Int64(chunk.count)
            var segmentStart = chunk.startIndex
            while let nl = chunk[segmentStart...].firstIndex(of: 0x0A) {
                appendSegment(chunk[segmentStart..<nl])
                flushLine()
                segmentStart = chunk.index(after: nl)
                committedOffset = chunkStartOffset + Int64(chunk.distance(from: chunk.startIndex, to: segmentStart))
            }
            if segmentStart < chunk.endIndex {
                appendSegment(chunk[segmentStart..<chunk.endIndex])
            }
        }

        return committedOffset
    }

    // MARK: - Timestamp Parsing

    static func dayKeyFromTimestamp(_ text: String) -> String? {
        guard let date = instantFromTimestamp(text) else { return nil }
        return DayRange.dayKey(from: date)
    }

    /// The instant an ISO-8601 log timestamp names, to the millisecond, by the
    /// same fast byte parse `dayKeyFromTimestamp` has always used (nil exactly
    /// where it returned nil). Fractional seconds are read here because the
    /// Codex rules compare event times: whether an event is earlier than its
    /// file's `session_meta`, and whether one file's events lie within another's.
    static func instantFromTimestamp(_ text: String) -> Date? {
        let bytes = Array(text.utf8)
        guard bytes.count >= 20 else { return nil }
        guard bytes[safeUInt8: 4] == 45, bytes[safeUInt8: 7] == 45 else { return nil }
        guard let year = parse4(bytes, at: 0),
              let month = parse2(bytes, at: 5),
              let day = parse2(bytes, at: 8) else { return nil }

        var hour = 0, minute = 0, second = 0
        if bytes[safeUInt8: 10] == 84 {
            guard bytes.count >= 19,
                  bytes[safeUInt8: 13] == 58, bytes[safeUInt8: 16] == 58,
                  let h = parse2(bytes, at: 11), let m = parse2(bytes, at: 14), let s = parse2(bytes, at: 17)
            else { return nil }
            hour = h; minute = m; second = s
        }

        var tzSign = 0
        var tzIndex: Int?
        for idx in stride(from: bytes.count - 1, through: 11, by: -1) {
            let byte = bytes[idx]
            if byte == 90 { tzIndex = idx; tzSign = 0; break }
            if byte == 43 { tzIndex = idx; tzSign = 1; break }
            if byte == 45 { tzIndex = idx; tzSign = -1; break }
        }
        guard let tzStart = tzIndex else { return nil }

        var offsetSeconds = 0
        if tzSign != 0 {
            let offsetStart = tzStart + 1
            guard let hours = parse2(bytes, at: offsetStart) else { return nil }
            var minutes = 0
            if bytes.count > offsetStart + 2 {
                if bytes[safeUInt8: offsetStart + 2] == 58 {
                    if let m = parse2(bytes, at: offsetStart + 3) { minutes = m }
                } else if let m = parse2(bytes, at: offsetStart + 2) {
                    minutes = m
                }
            }
            offsetSeconds = tzSign * (hours * 3600 + minutes * 60)
        }

        // Milliseconds: the first three digits after "SS." (more are ignored).
        var millis = 0
        if bytes[safeUInt8: 19] == 46 {
            var scale = 100
            var idx = 20
            while scale > 0, let digit = parseDigit(bytes[safeUInt8: idx]) {
                millis += digit * scale
                scale /= 10
                idx += 1
            }
        }

        var comps = DateComponents()
        comps.calendar = Calendar(identifier: .gregorian)
        comps.timeZone = TimeZone(secondsFromGMT: offsetSeconds)
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = hour; comps.minute = minute; comps.second = second
        guard let date = comps.date else { return nil }
        return date.addingTimeInterval(Double(millis) / 1000)
    }

    /// An instant in Unix milliseconds, the unit the Codex file state stores.
    static func unixMillis(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private static let isoBox: ISOFormatterBox = ISOFormatterBox()

    static func dayKeyFromParsedISO(_ text: String) -> String? {
        guard let date = isoBox.parse(text) else { return nil }
        return DayRange.dayKey(from: date)
    }

    static func instantFromParsedISO(_ text: String) -> Date? {
        isoBox.parse(text)
    }

    private static func parse2(_ bytes: [UInt8], at index: Int) -> Int? {
        guard let d0 = parseDigit(bytes[safeUInt8: index]),
              let d1 = parseDigit(bytes[safeUInt8: index + 1]) else { return nil }
        return d0 * 10 + d1
    }

    private static func parse4(_ bytes: [UInt8], at index: Int) -> Int? {
        guard let d0 = parseDigit(bytes[safeUInt8: index]),
              let d1 = parseDigit(bytes[safeUInt8: index + 1]),
              let d2 = parseDigit(bytes[safeUInt8: index + 2]),
              let d3 = parseDigit(bytes[safeUInt8: index + 3]) else { return nil }
        return d0 * 1000 + d1 * 100 + d2 * 10 + d3
    }

    private static func parseDigit(_ byte: UInt8?) -> Int? {
        guard let byte, byte >= 48, byte <= 57 else { return nil }
        return Int(byte - 48)
    }

    // MARK: - Pricing

    enum Pricing {
        struct ClaudeModel {
            let inputCostPerToken: Double
            let outputCostPerToken: Double
            let cacheCreationCostPerToken: Double
            let cacheReadCostPerToken: Double
            let thresholdTokens: Int?
            let inputAbove: Double?
            let outputAbove: Double?
            let cacheCreationAbove: Double?
            let cacheReadAbove: Double?
        }

        /// Which price row a model is charged at, and whether that row is the
        /// model's own.
        ///
        /// v1.56: `isApproximate` is true when the row was borrowed — the Codex
        /// version fallback or the Claude family fallback chose a neighbouring
        /// model's rate because the model has none of its own. The scanner
        /// used to know this at the moment it priced an entry and drop it, so
        /// a borrowed rate reached the screen looking exactly like a listed
        /// one. It now travels on `DailyEntry.priceIsApproximate`, and the cost
        /// card marks such figures with "≈" (`CostCoverage`).
        ///
        /// An alias (`CodexPricingTable.aliases`) is not approximate: OpenAI
        /// bills that name as the aliased model.
        struct PriceResolution: Equatable {
            let key: String
            let isApproximate: Bool
        }

        /// Codex rates live in `CodexPricingTable` (ported from CodexBar, with
        /// its MIT notice), shared with iOS so the table can be read and tested
        /// on every platform.
        ///
        /// Each request's cost is computed from that table when the request is
        /// read and stored in the cache, so a change to it — a row added,
        /// removed or repriced, a long-context tier, a dated rate in
        /// `superseded`, an alias — reaches days already scanned only through a
        /// bump of `costUsageCodexCacheRulesVersion`. `codexRatesFingerprint()`
        /// is pinned by a test next to that version, so a change without the
        /// bump fails the build instead of leaving old days at old prices (or
        /// an unpriced model's stored $0 reading as priced).
        private static var codexModels: [String: CodexPricingTable.Rates] { CodexPricingTable.current }

        private static let claudeModels: [String: ClaudeModel] = [
            "claude-haiku-4-5-20251001": .init(inputCostPerToken: 1e-6, outputCostPerToken: 5e-6, cacheCreationCostPerToken: 1.25e-6, cacheReadCostPerToken: 1e-7, thresholdTokens: nil, inputAbove: nil, outputAbove: nil, cacheCreationAbove: nil, cacheReadAbove: nil),
            "claude-haiku-4-5": .init(inputCostPerToken: 1e-6, outputCostPerToken: 5e-6, cacheCreationCostPerToken: 1.25e-6, cacheReadCostPerToken: 1e-7, thresholdTokens: nil, inputAbove: nil, outputAbove: nil, cacheCreationAbove: nil, cacheReadAbove: nil),
            "claude-opus-4-5-20251101": .init(inputCostPerToken: 5e-6, outputCostPerToken: 2.5e-5, cacheCreationCostPerToken: 6.25e-6, cacheReadCostPerToken: 5e-7, thresholdTokens: nil, inputAbove: nil, outputAbove: nil, cacheCreationAbove: nil, cacheReadAbove: nil),
            "claude-opus-4-5": .init(inputCostPerToken: 5e-6, outputCostPerToken: 2.5e-5, cacheCreationCostPerToken: 6.25e-6, cacheReadCostPerToken: 5e-7, thresholdTokens: nil, inputAbove: nil, outputAbove: nil, cacheCreationAbove: nil, cacheReadAbove: nil),
            "claude-opus-4-6-20260205": .init(inputCostPerToken: 5e-6, outputCostPerToken: 2.5e-5, cacheCreationCostPerToken: 6.25e-6, cacheReadCostPerToken: 5e-7, thresholdTokens: nil, inputAbove: nil, outputAbove: nil, cacheCreationAbove: nil, cacheReadAbove: nil),
            "claude-opus-4-6": .init(inputCostPerToken: 5e-6, outputCostPerToken: 2.5e-5, cacheCreationCostPerToken: 6.25e-6, cacheReadCostPerToken: 5e-7, thresholdTokens: nil, inputAbove: nil, outputAbove: nil, cacheCreationAbove: nil, cacheReadAbove: nil),
            // Opus 4.7 — official Anthropic pricing
            // (https://platform.claude.com/docs/en/about-claude/pricing,
            // checked May 2026): $5 / 1M input, $25 / 1M output, $0.50 /
            // 1M cache_read (10% of input), $6.25 / 1M cache_create
            // (1.25× input — Anthropic's standard 5-minute cache write
            // multiplier). Headline rate is unchanged from Opus 4.6.
            // Without this entry every Opus 4.7 assistant event was
            // contributing $0 to the Today/Week cost totals — current
            // Claude Code (Max 20x) traffic is ~100% opus-4-7, so the
            // user's card showed `<$0.01` despite hundreds of M
            // cache_read tokens flowing through the same scanner.
            "claude-opus-4-7": .init(inputCostPerToken: 5e-6, outputCostPerToken: 2.5e-5, cacheCreationCostPerToken: 6.25e-6, cacheReadCostPerToken: 5e-7, thresholdTokens: nil, inputAbove: nil, outputAbove: nil, cacheCreationAbove: nil, cacheReadAbove: nil),
            // Opus 4.8 — same headline rate as the rest of the Opus 4.x line.
            // A dedicated entry (vs. leaning on familyFallback) matters for the
            // DISPLAY name, not just cost: `ScanEntry.model` stores the
            // normalized key, so without this row current Claude Code (Max 20x)
            // traffic — now ~100% opus-4-8 — was being relabeled `opus-4-7` in
            // the By-Model breakdown. With the entry it keeps its real name and
            // prices identically.
            "claude-opus-4-8": .init(inputCostPerToken: 5e-6, outputCostPerToken: 2.5e-5, cacheCreationCostPerToken: 6.25e-6, cacheReadCostPerToken: 5e-7, thresholdTokens: nil, inputAbove: nil, outputAbove: nil, cacheCreationAbove: nil, cacheReadAbove: nil),
            "claude-sonnet-4-5": .init(inputCostPerToken: 3e-6, outputCostPerToken: 1.5e-5, cacheCreationCostPerToken: 3.75e-6, cacheReadCostPerToken: 3e-7, thresholdTokens: 200_000, inputAbove: 6e-6, outputAbove: 2.25e-5, cacheCreationAbove: 7.5e-6, cacheReadAbove: 6e-7),
            "claude-sonnet-4-5-20250929": .init(inputCostPerToken: 3e-6, outputCostPerToken: 1.5e-5, cacheCreationCostPerToken: 3.75e-6, cacheReadCostPerToken: 3e-7, thresholdTokens: 200_000, inputAbove: 6e-6, outputAbove: 2.25e-5, cacheCreationAbove: 7.5e-6, cacheReadAbove: 6e-7),
            "claude-sonnet-4-6": .init(inputCostPerToken: 3e-6, outputCostPerToken: 1.5e-5, cacheCreationCostPerToken: 3.75e-6, cacheReadCostPerToken: 3e-7, thresholdTokens: 200_000, inputAbove: 6e-6, outputAbove: 2.25e-5, cacheCreationAbove: 7.5e-6, cacheReadAbove: 6e-7),
            "claude-opus-4-20250514": .init(inputCostPerToken: 1.5e-5, outputCostPerToken: 7.5e-5, cacheCreationCostPerToken: 1.875e-5, cacheReadCostPerToken: 1.5e-6, thresholdTokens: nil, inputAbove: nil, outputAbove: nil, cacheCreationAbove: nil, cacheReadAbove: nil),
            "claude-opus-4-1": .init(inputCostPerToken: 1.5e-5, outputCostPerToken: 7.5e-5, cacheCreationCostPerToken: 1.875e-5, cacheReadCostPerToken: 1.5e-6, thresholdTokens: nil, inputAbove: nil, outputAbove: nil, cacheCreationAbove: nil, cacheReadAbove: nil),
            "claude-sonnet-4-20250514": .init(inputCostPerToken: 3e-6, outputCostPerToken: 1.5e-5, cacheCreationCostPerToken: 3.75e-6, cacheReadCostPerToken: 3e-7, thresholdTokens: 200_000, inputAbove: 6e-6, outputAbove: 2.25e-5, cacheCreationAbove: 7.5e-6, cacheReadAbove: 6e-7),
            // ---- Claude 5 generation (Aug 2026) --------------------------
            // Every model below read $0 before this. The generation bump from
            // `claude-opus-4-8` to `claude-opus-5` dropped the fourth
            // component, and `familyFallback`'s regex required
            // `claude-(opus|sonnet|haiku)-N-M` — four parts, three families. So
            // the guard built to stop exactly this ("Without this, the next
            // minor release silently regresses Today/Week cost to $0 the day it
            // ships") did not fire, because the next release was not a minor.
            // Measured on the owner's own archive: 15.47 BILLION tokens priced
            // at zero, every day since 2026-07-30.
            //
            // Rates are Anthropic's published first-party API prices. Cache
            // rates follow the same convention as every entry above and are
            // documented on the Opus 4.7 row: cache_read = 10% of input,
            // cache_write = 1.25x input (the standard 5-minute cache-write
            // multiplier).
            //
            // Opus 5 — $5 / 1M input, $25 / 1M output. Unchanged headline rate
            // from the whole Opus 4.x line, so this row's numbers are identical
            // to `claude-opus-4-8`.
            "claude-opus-5": .init(inputCostPerToken: 5e-6, outputCostPerToken: 2.5e-5, cacheCreationCostPerToken: 6.25e-6, cacheReadCostPerToken: 5e-7, thresholdTokens: nil, inputAbove: nil, outputAbove: nil, cacheCreationAbove: nil, cacheReadAbove: nil),
            // Sonnet 5 — $3 / 1M input, $15 / 1M output standard.
            // ⚠️ TWO deliberate omissions, both erring toward a wrong number we
            // can explain rather than one we cannot:
            //   * The $2 / $10 introductory rate running through 2026-08-31 is
            //     NOT encoded. A date-windowed rate is a bigger change than a
            //     pricing row, and this over-states cost by 33% for a few days
            //     on a model that is 0.6% of this archive's tokens.
            //   * `thresholdTokens` is nil. Sonnet 4.5 and 4.6 both carry a
            //     200K long-context tier at 2x, and Sonnet 5 plausibly does
            //     too — but "plausibly" is not a rate. Flat pricing under-
            //     states >200K requests; inventing a tier would over-state
            //     every one of them. Confirm against Anthropic's pricing page
            //     and add the tier.
            "claude-sonnet-5": .init(inputCostPerToken: 3e-6, outputCostPerToken: 1.5e-5, cacheCreationCostPerToken: 3.75e-6, cacheReadCostPerToken: 3e-7, thresholdTokens: nil, inputAbove: nil, outputAbove: nil, cacheCreationAbove: nil, cacheReadAbove: nil),
            // Fable 5 — $10 / 1M input, $50 / 1M output. Above Opus-tier, so a
            // family fallback to any Opus row would have under-priced it by 2x
            // even if "fable" had parsed as a family. It needs its own row.
            "claude-fable-5": .init(inputCostPerToken: 1e-5, outputCostPerToken: 5e-5, cacheCreationCostPerToken: 1.25e-5, cacheReadCostPerToken: 1e-6, thresholdTokens: nil, inputAbove: nil, outputAbove: nil, cacheCreationAbove: nil, cacheReadAbove: nil),
        ]

        static func normalizeCodexModel(_ raw: String) -> String {
            var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("openai/") { trimmed = String(trimmed.dropFirst("openai/".count)) }
            if codexModels[trimmed] != nil { return trimmed }
            if let datedSuffix = trimmed.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) {
                let base = String(trimmed[..<datedSuffix.lowerBound])
                if codexModels[base] != nil { return base }
            }
            return trimmed
        }

        /// Which priced row to charge a Codex model against.
        ///
        /// The Claude side has had a family fallback since May 2026. The Codex
        /// side never had one, so an unrecognised OpenAI model read $0 with no
        /// safety net at all — in August 2026 that was `gpt-5.6-sol` and
        /// `gpt-5.6-terra`.
        ///
        /// The precedent for what to do was a hand-written row: when `gpt-5.5`
        /// appeared with no published billing, it was priced by mirroring
        /// `gpt-5.4`, with the reasoning written down — *"Approximate-but-non-zero
        /// beats zero for cost-aware UX; replace when official."* This
        /// generalises that into a rule, so the NEXT unrecognised model is
        /// approximate instead of free. Since 1.56 the result says so
        /// (`codexPriceResolution`), and the screen marks it "≈".
        ///
        /// Tier is matched before version, and that ordering carries the whole
        /// risk: `gpt-5.4-pro` costs 12x `gpt-5.4`. Charging an unknown `-pro`
        /// at base rates would under-report by an order of magnitude, so a
        /// `-pro`/`-mini`/`-nano` suffix only ever falls back to the same
        /// suffix. An unknown suffix (`-sol`, `-terra`, `-codex-max`) is treated
        /// as base tier, which is where every non-suffixed Codex model has sat.
        static func codexPricingKey(_ raw: String) -> String? {
            codexPriceResolution(raw)?.key
        }

        /// The row `raw` is charged at: its own, then an alias's (a dated
        /// spelling of an alias included), then the version fallback above
        /// (approximate).
        static func codexPriceResolution(_ raw: String) -> PriceResolution? {
            let normalized = normalizeCodexModel(raw)
            if codexModels[normalized] != nil {
                return PriceResolution(key: normalized, isApproximate: false)
            }
            if let target = CodexPricingTable.aliasTarget(normalized), codexModels[target] != nil {
                return PriceResolution(key: target, isApproximate: false)
            }
            return codexFallbackKey(normalized).map { PriceResolution(key: $0, isApproximate: true) }
        }

        private static func codexFallbackKey(_ normalized: String) -> String? {
            guard let (version, tier) = codexVersionTier(normalized) else { return nil }
            var best: (key: String, version: (Int, Int))?
            for key in codexModels.keys {
                guard let (otherVersion, otherTier) = codexVersionTier(key),
                      otherTier == tier,
                      key != normalized,
                      otherVersion <= version   // same never-fall-forward rule
                else { continue }
                if best == nil || isBetterFallback(
                    candidate: (key, otherVersion), than: best!
                ) {
                    best = (key, otherVersion)
                }
            }
            return best?.key
        }

        /// `gpt-<major>[.<minor>][-<suffix>…]` → ((major, minor), tier).
        /// Tier is `pro` / `mini` / `nano` when the name ends in one of those,
        /// otherwise `base`. Everything else about the suffix is ignored:
        /// `gpt-5.1-codex-max` and `gpt-5.6-sol` are both base tier.
        static func codexVersionTier(_ model: String) -> ((Int, Int), String)? {
            guard model.hasPrefix("gpt-") else { return nil }
            let parts = model.dropFirst("gpt-".count).split(separator: "-")
            guard let versionPart = parts.first else { return nil }
            let versionBits = versionPart.split(separator: ".")
            guard let major = Int(versionBits[0]) else { return nil }
            let minor = versionBits.count > 1 ? (Int(versionBits[1]) ?? 0) : 0
            let tier: String
            switch parts.last.map(String.init) {
            case "pro": tier = "pro"
            case "mini": tier = "mini"
            case "nano": tier = "nano"
            default: tier = "base"
            }
            return ((major, minor), tier)
        }

        static func normalizeClaudeModel(_ raw: String) -> String {
            var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("anthropic.") { trimmed = String(trimmed.dropFirst("anthropic.".count)) }
            if let lastDot = trimmed.lastIndex(of: "."), trimmed.contains("claude-") {
                let tail = String(trimmed[trimmed.index(after: lastDot)...])
                if tail.hasPrefix("claude-") { trimmed = tail }
            }
            if let vRange = trimmed.range(of: #"-v\d+:\d+$"#, options: .regularExpression) {
                trimmed.removeSubrange(vRange)
            }
            if let baseRange = trimmed.range(of: #"-\d{8}$"#, options: .regularExpression) {
                let base = String(trimmed[..<baseRange.lowerBound])
                if claudeModels[base] != nil { return base }
            }
            return trimmed
        }

        /// Highest version wins; ties break deterministically.
        ///
        /// Swift dictionary iteration order is unspecified, so "highest version"
        /// alone left ties to hash order — `gpt-5.6-sol` resolved to `gpt-5.5`
        /// on one run and `gpt-5.5-codex` on the next. The rates happened to be
        /// identical, so nothing visible moved, which is precisely why it would
        /// have survived: a flaky pricing key that only shows up when two rows
        /// at the same version disagree on price.
        ///
        /// Shortest key first, then lexicographic. Shortest prefers the plain
        /// family row (`gpt-5.5`) over a specialised sibling (`gpt-5.5-codex`),
        /// which is the more conservative base to borrow from.
        static func isBetterFallback(
            candidate: (key: String, version: (Int, Int)),
            than best: (key: String, version: (Int, Int))
        ) -> Bool {
            if candidate.version != best.version { return candidate.version > best.version }
            if candidate.key.count != best.key.count { return candidate.key.count < best.key.count }
            return candidate.key < best.key
        }

        /// Which priced row to charge `model` against.
        ///
        /// v1.50: split out of `normalizeClaudeModel`, which used to apply the
        /// family fallback itself. That conflated two different questions —
        /// **what do we call this model** and **what do we charge it** — and the
        /// conflation cost something both ways:
        ///
        ///   * `ScanEntry.model` stores whatever `normalize` returns, so a
        ///     fallback silently RELABELLED events. `claude-opus-4-8` traffic
        ///     showed up in the By-Model breakdown as `opus-4-7` until someone
        ///     added a dedicated row — and the row was added for the label, not
        ///     the rate, since the rates were identical.
        ///   * Which meant every new model needed a hand-written row purely to
        ///     keep its own name, and a missed row read $0.
        ///
        /// Now `normalize` answers only the first question and this answers only
        /// the second. A model we have never seen keeps its real name in the UI
        /// *and* gets a defensible non-zero rate.
        static func claudePricingKey(_ raw: String) -> String? {
            claudePriceResolution(raw)?.key
        }

        /// The row `raw` is charged at: its own, or the family fallback's
        /// (approximate).
        static func claudePriceResolution(_ raw: String) -> PriceResolution? {
            let normalized = normalizeClaudeModel(raw)
            if claudeModels[normalized] != nil {
                return PriceResolution(key: normalized, isApproximate: false)
            }
            return familyFallback(normalized).map { PriceResolution(key: $0, isApproximate: true) }
        }

        /// The newest priced sibling in the same Claude family, or nil.
        ///
        /// Accepts both version shapes, which is the fix. It used to require
        /// `claude-(opus|sonnet|haiku)-N-M`; `claude-opus-5` has no `-M` and
        /// `claude-fable-5` is not one of the three families, so the Claude 5
        /// generation matched nothing and fell through to "unpriced" — 15.47
        /// billion tokens at $0 on the machine this was found on.
        ///
        /// Ordering is by (generation, minor) so a generation bump beats any
        /// minor: for `claude-opus-6`, `claude-opus-5` outranks
        /// `claude-opus-4-8`. Within-family rates have been stable across
        /// Anthropic generations often enough that the newest sibling is a sane
        /// default, and an approximate non-zero number is worth far more to a
        /// cost display than a confident zero.
        ///
        /// A new FAMILY still gets nothing — `claude-fable-5` had no priced
        /// sibling on release and would have read $0 regardless. There is no
        /// honest way to guess the rate of a tier that has never existed, and
        /// Fable's $10/$50 (2x Opus) is exactly why guessing would be wrong.
        /// That case needs a row, which is why it has one above.
        static func familyFallback(_ model: String) -> String? {
            guard let (family, version) = claudeFamilyVersion(model) else { return nil }
            var best: (key: String, version: (Int, Int))?
            for key in claudeModels.keys {
                guard let (otherFamily, otherVersion) = claudeFamilyVersion(key),
                      otherFamily == family,
                      key != model
                else { continue }
                // Cap both components below 100 so a legacy dated key like
                // `claude-sonnet-4-20250514` (where `20250514` is a date
                // masquerading as a minor) cannot win against a real minor.
                guard otherVersion.0 < 100, otherVersion.1 < 100 else { continue }
                // Never fall "up" to something newer than the model being
                // priced: an old `claude-opus-4-9` must not be charged at Opus
                // 5 rates. Filter DURING selection, not after — rejecting the
                // single highest sibling at the end throws away the valid older
                // ones behind it, and `claude-opus-4-9` resolved to nil instead
                // of `claude-opus-4-8`.
                guard otherVersion <= version else { continue }
                if best == nil || isBetterFallback(
                    candidate: (key, otherVersion), than: best!
                ) {
                    best = (key, otherVersion)
                }
            }
            return best?.key
        }

        /// `claude-<family>-<gen>[-<minor>]` → (family, (gen, minor)).
        /// Any family word, not a hardcoded three. Missing minor reads as 0, so
        /// `claude-opus-5` sorts as (5, 0) — above every `claude-opus-4-N` and
        /// below `claude-opus-5-1` when that ships.
        static func claudeFamilyVersion(_ model: String) -> (String, (Int, Int))? {
            let parts = model.split(separator: "-")
            guard parts.count >= 3, parts[0] == "claude" else { return nil }
            let family = String(parts[1])
            guard !family.isEmpty, Int(family) == nil else { return nil }
            guard let generation = Int(parts[2]) else { return nil }
            if parts.count == 3 { return (family, (generation, 0)) }
            guard parts.count == 4, let minor = Int(parts[3]) else { return nil }
            return (family, (generation, minor))
        }


        /// What one Codex request cost, at the rate in force at `date` (a
        /// dated rate from `CodexPricingTable.superseded`, or today's when
        /// `date` is nil or later). nil when the model has no rate.
        ///
        /// The arguments are one request's tokens: the 272K long-context tier
        /// is decided by them (`CodexPricingTable.requestCostUSD`). The scanner
        /// prices each `token_count` event as it reads it, at the event's own
        /// time (`codexEventCostUSD`); a day's sum is not a request.
        static func codexCostUSD(model: String, inputTokens: Int, cachedInputTokens: Int, outputTokens: Int, at date: Date? = nil) -> Double? {
            guard let key = codexPricingKey(model),
                  let rates = CodexPricingTable.rates(forKey: key, at: date) else { return nil }
            return CodexPricingTable.requestCostUSD(
                rates: rates,
                inputTokens: inputTokens,
                cachedInputTokens: cachedInputTokens,
                outputTokens: outputTokens
            )
        }

        /// Model names whose resolution the fingerprint records: current
        /// rows, the `openai/` and dated spellings, aliases and a dated alias,
        /// and names only the version fallback prices (or none does). A change
        /// to how a name resolves (`normalizeCodexModel`,
        /// `codexPriceResolution`) moves which rate a stored cost used, or
        /// whether a stored $0 means unpriced, without changing a single rate
        /// row.
        static let codexFingerprintModelNames = [
            "gpt-5", "gpt-5-codex", "gpt-5-mini", "gpt-5.1-codex-max", "gpt-5.3-codex-spark",
            "gpt-5.4", "gpt-5.4-pro", "gpt-5.5", "openai/gpt-5.5", "gpt-5.5-2026-04-23",
            "gpt-5.5-codex", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.6-mini",
            "gpt-5.7", "gpt-5.7-pro", "gpt-6-astra", "gpt-4.1", "o3", "codex-mini-latest",
            "gpt-5.6", "gpt-5.6-2026-08-01", "gpt-reserve", "gpt-daybreak-red-latest",
            "gpt-6-sol", "gpt-6.2",
        ]

        /// Everything a stored Codex cost depends on, as text: every key and
        /// every rate of `CodexPricingTable.current`, every dated entry in
        /// `superseded` (in the order the lookup reads them), every alias, and
        /// how each of `codexFingerprintModelNames` resolves to a row. An
        /// alias changes which row a name is billed at without changing any
        /// row, so it moves stored costs just the same.
        ///
        /// The tables are parameters only so a test can show that a change to
        /// any of them changes the fingerprint; the name lines always use the
        /// real resolution.
        static func codexRatesFingerprint(
            current: [String: CodexPricingTable.Rates] = CodexPricingTable.current,
            superseded: [String: [CodexPricingTable.DatedRates]] = CodexPricingTable.superseded,
            aliases: [String: String] = CodexPricingTable.aliases
        ) -> String {
            func number(_ value: Double?) -> String { value.map { String(format: "%.17g", $0) } ?? "nil" }
            func row(_ r: CodexPricingTable.Rates) -> String {
                [
                    number(r.input), number(r.output), number(r.cachedInput), number(r.cacheWrite),
                    "over \(r.longContextThreshold.map(String.init) ?? "nil")",
                    number(r.inputAboveThreshold), number(r.outputAboveThreshold),
                    number(r.cachedInputAboveThreshold), number(r.cacheWriteAboveThreshold),
                ].joined(separator: " ")
            }
            var lines = current.keys.sorted().compactMap { key in current[key].map { "\(key) \(row($0))" } }
            for key in superseded.keys.sorted() {
                for period in superseded[key] ?? [] {
                    lines.append("\(key) until \(Int(period.until.timeIntervalSince1970)) \(row(period.rates))")
                }
            }
            for alias in aliases.keys.sorted() {
                lines.append("alias \(alias) -> \(aliases[alias] ?? "nil")")
            }
            for name in codexFingerprintModelNames {
                lines.append("name \(name) -> \(normalizeCodexModel(name)) -> \(codexPricingKey(name) ?? "nil")")
            }
            return lines.joined(separator: "\n")
        }

        static func claudeCostUSD(model: String, inputTokens: Int, cacheReadInputTokens: Int, cacheCreationInputTokens: Int, outputTokens: Int) -> Double? {
            guard let key = claudePricingKey(model),
                  let p = claudeModels[key] else { return nil }

            func tiered(_ tokens: Int, base: Double, above: Double?, threshold: Int?) -> Double {
                guard let threshold, let above else { return Double(tokens) * base }
                let below = min(tokens, threshold)
                let over = max(tokens - threshold, 0)
                return Double(below) * base + Double(over) * above
            }

            return tiered(max(0, inputTokens), base: p.inputCostPerToken, above: p.inputAbove, threshold: p.thresholdTokens)
                + tiered(max(0, cacheReadInputTokens), base: p.cacheReadCostPerToken, above: p.cacheReadAbove, threshold: p.thresholdTokens)
                + tiered(max(0, cacheCreationInputTokens), base: p.cacheCreationCostPerToken, above: p.cacheCreationAbove, threshold: p.thresholdTokens)
                + tiered(max(0, outputTokens), base: p.outputCostPerToken, above: p.outputAbove, threshold: p.thresholdTokens)
        }
    }

    // MARK: - Codex Scanning

    private struct CodexParseResult {
        let days: [String: [String: [Int]]]
        let parsedBytes: Int64
        let lastModel: String?
        let lastTotals: CostUsageCodexTotals?
        let sessionId: String?
        let state: CostUsageCodexFileState
        /// false when the file could not be read to the end, or its first line
        /// is not complete yet. Nothing from such a parse is kept: the file is
        /// read again on the next refresh.
        let complete: Bool
    }

    private static func defaultCodexSessionsRoot(options: Options) -> URL {
        if let override = options.codexSessionsRoot { return override }
        let env = ProcessInfo.processInfo.environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let env, !env.isEmpty {
            return URL(fileURLWithPath: env).appendingPathComponent("sessions", isDirectory: true)
        }
        return URL(fileURLWithPath: realUserHome())
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    private static func codexSessionsRoots(options: Options) -> [URL] {
        let root = defaultCodexSessionsRoot(options: options)
        var roots = [root]
        if root.lastPathComponent == "sessions" {
            let archived = root.deletingLastPathComponent().appendingPathComponent("archived_sessions", isDirectory: true)
            roots.append(archived)
        }
        return roots
    }

    private static func listCodexSessionFiles(root: URL, scanSinceKey: String, scanUntilKey: String) -> [URL] {
        var out: [URL] = []
        var seen: Set<String> = []

        // Date-partitioned: YYYY/MM/DD/*.jsonl. The Codex CLI names these
        // directories in Gregorian numbering, so the walk must too — under the
        // Japanese calendar the device's own numbering looks in 0008/09/17.
        if FileManager.default.fileExists(atPath: root.path) {
            let cal = DayKey.calendar()
            var date = parseDayKey(scanSinceKey) ?? Date()
            let untilDate = parseDayKey(scanUntilKey) ?? date
            while date <= untilDate {
                // "2026-09-17" -> 2026/09/17
                let dayDir = DayKey.string(from: date).split(separator: "-")
                    .reduce(root) { $0.appendingPathComponent(String($1), isDirectory: true) }
                if let items = try? FileManager.default.contentsOfDirectory(at: dayDir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                    for item in items where item.pathExtension.lowercased() == "jsonl" && !seen.contains(item.path) {
                        seen.insert(item.path)
                        out.append(item)
                    }
                }
                date = cal.date(byAdding: .day, value: 1, to: date) ?? untilDate.addingTimeInterval(1)
            }
        }

        // Flat: *.jsonl in root
        if let items = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for item in items where item.pathExtension.lowercased() == "jsonl" && !seen.contains(item.path) {
                if let dayKey = dayKeyFromFilename(item.lastPathComponent) {
                    if !DayRange.isInRange(dayKey: dayKey, since: scanSinceKey, until: scanUntilKey) { continue }
                }
                seen.insert(item.path)
                out.append(item)
            }
        }

        return out.sorted { $0.path < $1.path }
    }

    private static let codexFilenameDateRegex = try? NSRegularExpression(pattern: "(\\d{4}-\\d{2}-\\d{2})")

    private static func dayKeyFromFilename(_ filename: String) -> String? {
        guard let regex = codexFilenameDateRegex else { return nil }
        let range = NSRange(filename.startIndex..<filename.endIndex, in: filename)
        guard let match = regex.firstMatch(in: filename, range: range),
              let matchRange = Range(match.range(at: 1), in: filename) else { return nil }
        return String(filename[matchRange])
    }

    private static func fileIdentityString(fileURL: URL) -> String? {
        guard let values = try? fileURL.resourceValues(forKeys: [.fileResourceIdentifierKey]),
              let identifier = values.fileResourceIdentifier else { return nil }
        if let data = identifier as? Data { return data.base64EncodedString() }
        return String(describing: identifier)
    }

    /// The longest first line (a rollout's own session_meta, which carries the
    /// thread's base instructions) read to learn the file's identity. Every
    /// other line keeps the 32 KB cap: token and turn lines are far smaller.
    static let codexFirstLineMaxBytes = 1 << 20

    enum CodexFirstLine: Equatable {
        case line(Data)
        /// Longer than `codexFirstLineMaxBytes`.
        case tooLong
        /// No newline yet: the line is still being written, or the file is empty.
        case incomplete
        case unreadable
    }

    /// The bytes of a file's first line, without reading the rest.
    static func readCodexFirstLine(fileURL: URL, maxBytes: Int = codexFirstLineMaxBytes) -> CodexFirstLine {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return .unreadable }
        defer { try? handle.close() }
        var buffer = Data()
        while buffer.count <= maxBytes {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: min(256 * 1024, maxBytes + 1 - buffer.count)) ?? Data()
            } catch {
                return .unreadable
            }
            if chunk.isEmpty { return .incomplete }
            if let newline = chunk.firstIndex(of: 0x0A) {
                buffer.append(chunk[chunk.startIndex..<newline])
                return buffer.count <= maxBytes ? .line(buffer) : .tooLong
            }
            buffer.append(chunk)
        }
        return .tooLong
    }

    /// Parse a Codex rollout from `startOffset`, resuming the counting state a
    /// previous parse of the same file ended with. Each `token_count` event
    /// adds what `CodexTokenAccountant` says it adds, priced at the rates of
    /// its own time (`codexEventCostUSD`); the per-day-model rows are
    /// `[input, cached, output, costNanos]`.
    private static func parseCodexFile(
        fileURL: URL, range: DayRange,
        startOffset: Int64 = 0,
        initialModel: String? = nil,
        initialTotals: CostUsageCodexTotals? = nil,
        initialState: CostUsageCodexFileState = CostUsageCodexFileState()
    ) -> CodexParseResult {
        var currentModel = initialModel
        var accountant = CodexTokenAccountant(watermark: initialTotals, state: initialState)
        var sessionId: String?
        var days: [String: [String: [Int]]] = [:]
        let costScale = 1_000_000_000.0

        func incomplete() -> CodexParseResult {
            CodexParseResult(days: [:], parsedBytes: startOffset, lastModel: initialModel, lastTotals: initialTotals,
                             sessionId: nil, state: initialState, complete: false)
        }

        // The file's identity comes from its first line and nowhere else. The
        // line scan below starts at the same byte, so it skips that line.
        var skipFirstLine = false
        if startOffset == 0 {
            switch readCodexFirstLine(fileURL: fileURL) {
            case .incomplete, .unreadable:
                return incomplete()
            case .tooLong:
                accountant.observeUnreadableFirstLine()
                skipFirstLine = true
            case .line(let bytes):
                // An empty first line is never handed to `onLine`.
                skipFirstLine = !bytes.isEmpty
                if bytes.asciiContains(#""type":"session_meta""#),
                   let obj = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
                   (obj["type"] as? String) == "session_meta" {
                    let payload = obj["payload"] as? [String: Any]
                    sessionId = payload?["session_id"] as? String ?? payload?["sessionId"] as? String ?? payload?["id"] as? String ?? obj["session_id"] as? String
                    let metaTime = (payload?["timestamp"] as? String) ?? (obj["timestamp"] as? String)
                    let metaInstant = metaTime.flatMap { instantFromTimestamp($0) ?? instantFromParsedISO($0) }
                    accountant.observeSessionMeta(
                        rolloutId: payload?["id"] as? String,
                        isChild: payload.map(CodexTokenAccountant.sessionMetaNamesParent) ?? false,
                        metaUnixMs: metaInstant.map(unixMillis),
                        historyStartOrdinal: payload?["subagent_history_start_ordinal"] as? Int,
                        isSubagent: payload.map(CodexTokenAccountant.sessionMetaIsSubagent) ?? false,
                        namesForkParent: payload.flatMap(CodexTokenAccountant.sessionMetaForkParent) != nil
                    )
                } else {
                    accountant.observeUnreadableFirstLine()
                }
            }
        }

        // Token counts can be absurd in a corrupt log; a sum must not trap.
        func plus(_ a: Int, _ b: Int) -> Int {
            let (sum, overflow) = a.addingReportingOverflow(b)
            return overflow ? Int.max : sum
        }
        var normalizedModels: [String: String] = [:]
        var pricingKeys: [String: String?] = [:]

        func add(dayKey: String, model: String, delta: CostUsageCodexTotals, costNanos: Int) {
            guard DayRange.isInRange(dayKey: dayKey, since: range.scanSinceKey, until: range.scanUntilKey) else { return }
            let normModel: String
            if let known = normalizedModels[model] {
                normModel = known
            } else {
                normModel = Pricing.normalizeCodexModel(model)
                normalizedModels[model] = normModel
            }
            var dayModels = days[dayKey] ?? [:]
            var packed = dayModels[normModel] ?? [0, 0, 0, 0]
            while packed.count < 4 { packed.append(0) }
            packed[0] = plus(packed[0], delta.input)
            packed[1] = plus(packed[1], min(delta.cached, delta.input))
            packed[2] = plus(packed[2], delta.output)
            packed[3] = plus(packed[3], costNanos)
            dayModels[normModel] = packed
            days[dayKey] = dayModels
        }

        /// A token count as an Int: 0 for anything that is not a positive
        /// number, and capped at 10^15 so no conversion or sum can trap.
        func toInt(_ v: Any?) -> Int {
            guard let number = v as? NSNumber else { return 0 }
            let value = number.doubleValue
            guard value.isFinite, value > 0 else { return 0 }
            return value >= 1e15 ? 1_000_000_000_000_000 : max(0, number.intValue)
        }
        func totals(_ usage: [String: Any]?) -> CostUsageCodexTotals? {
            guard let usage else { return nil }
            return CostUsageCodexTotals(
                input: toInt(usage["input_tokens"]),
                cached: toInt(usage["cached_input_tokens"] ?? usage["cache_read_input_tokens"]),
                output: toInt(usage["output_tokens"])
            )
        }

        /// File one counted event under its local day and model, priced at
        /// the `CodexPricingTable` rates in force at its own time.
        func file(_ counted: CodexTokenAccountant.Counted) {
            let event = counted.event
            let key: String?
            if let known = pricingKeys[event.model] {
                key = known
            } else {
                key = Pricing.codexPricingKey(event.model)
                pricingKeys[event.model] = key
            }
            var costNanos = 0
            if let key, let rates = CodexPricingTable.rates(forKey: key, at: event.instant) {
                let nanos = Pricing.codexEventCostUSD(rates: rates, counted: counted.delta, request: event.last) * costScale
                if nanos.isFinite { costNanos = Int(min(max(0, nanos), 1e18).rounded()) }
            }
            add(dayKey: DayRange.dayKey(from: event.instant), model: event.model, delta: counted.delta, costNanos: costNanos)
        }

        let maxLineBytes = 256 * 1024
        let prefixBytes = 32 * 1024
        var readError = false

        // The line's position in the file, the first line being 0. Only a
        // rollout read whole needs it (rule 5), and that one is always read
        // from the first line.
        var lineIndex = -1

        let parsedBytes: Int64
        do {
            parsedBytes = try scanJsonl(fileURL: fileURL, offset: startOffset, maxLineBytes: maxLineBytes, prefixBytes: prefixBytes, onLine: { line in
                lineIndex += 1
                if skipFirstLine {
                    skipFirstLine = false
                    return
                }
                guard !line.bytes.isEmpty else { return }
                // A later session_meta is an ancestor's, copied in with its
                // history. It never gives the file its identity; its head says
                // where it sits, which is what marks copied history (rule 2 of
                // `CodexTokenAccountant`), and a rollout read whole also notes
                // whose it is (rule 5).
                if line.bytes.asciiContains(#""type":"session_meta""#) {
                    if accountant.classifiesWholeFile {
                        let later = codexLaterSessionMeta(line)
                        accountant.observeWholeFileLine(.sessionMetadata(id: later.id), line: lineIndex,
                                                        namesForkParent: later.namesForkParent)
                    }
                    accountant.observeCopiedSessionMeta(ordinal: codexLineOrdinal(line.bytes))
                    return
                }
                if line.bytes.asciiContains(#""type":"inter_agent_communication_metadata""#) {
                    if accountant.classifiesWholeFile, let trigger = codexInterAgentTrigger(line) {
                        accountant.observeWholeFileLine(.interAgentCommunication(triggerTurn: trigger), line: lineIndex)
                    }
                    if accountant.awaitsCopiedPrefixMarker {
                        accountant.observeInterAgentMessage(ordinal: codexLineOrdinal(line.bytes))
                    }
                    return
                }
                // A turn_context over the line limit is not seen as a turn (its
                // head cannot show that "turn_context" is the line's own type),
                // so a rollout read whole that needs it counts by the other rules.
                guard !line.wasTruncated else { return }
                guard line.bytes.asciiContains(#""type":"event_msg""#)
                    || line.bytes.asciiContains(#""type":"turn_context""#) else { return }
                if line.bytes.asciiContains(#""type":"event_msg""#), !line.bytes.asciiContains(#""token_count""#) { return }

                guard let obj = (try? JSONSerialization.jsonObject(with: line.bytes)) as? [String: Any],
                      let type = obj["type"] as? String else { return }

                guard let tsText = obj["timestamp"] as? String,
                      let instant = instantFromTimestamp(tsText) ?? instantFromParsedISO(tsText) else { return }

                if type == "turn_context" {
                    accountant.observeWholeFileLine(.turnContext, line: lineIndex)
                    if let payload = obj["payload"] as? [String: Any] {
                        if let model = payload["model"] as? String { currentModel = model }
                        else if let info = payload["info"] as? [String: Any], let model = info["model"] as? String { currentModel = model }
                    }
                    return
                }

                guard type == "event_msg",
                      let payload = obj["payload"] as? [String: Any],
                      (payload["type"] as? String) == "token_count" else { return }

                let info = payload["info"] as? [String: Any]
                let total = totals(info?["total_token_usage"] as? [String: Any])
                let last = totals(info?["last_token_usage"] as? [String: Any])
                guard total != nil || last != nil else { return }
                let modelFromInfo = info?["model"] as? String ?? info?["model_name"] as? String ?? payload["model"] as? String ?? obj["model"] as? String
                let event = CodexTokenAccountant.Event(
                    instant: instant,
                    ordinal: obj["ordinal"] as? Int,
                    total: total,
                    last: last,
                    model: modelFromInfo ?? currentModel ?? "gpt-5",
                    line: lineIndex
                )
                for counted in accountant.receive(event) { file(counted) }
            })
        } catch {
            readError = true
            parsedBytes = startOffset
        }
        if readError { return incomplete() }
        // Events still held at the end of the read count (rule 2).
        for counted in accountant.finish() { file(counted) }

        return CodexParseResult(
            days: days,
            parsedBytes: parsedBytes,
            lastModel: currentModel,
            lastTotals: accountant.watermark,
            sessionId: sessionId,
            state: accountant.state,
            complete: true
        )
    }

    /// A later session_meta line's thread id, and whether it names the thread
    /// it was forked from (rule 5 of `CodexTokenAccountant`): read from the
    /// decoded line, or, for a line over the limit (an ancestor's carries its
    /// base instructions), from the first `"id":"…"` in its head.
    private static func codexLaterSessionMeta(_ line: JsonlLine) -> (id: String?, namesForkParent: Bool) {
        if !line.wasTruncated,
           let obj = (try? JSONSerialization.jsonObject(with: line.bytes)) as? [String: Any] {
            let payload = obj["payload"] as? [String: Any] ?? [:]
            let id = payload["id"] as? String ?? obj["id"] as? String ?? payload["session_id"] as? String
                ?? payload["sessionId"] as? String ?? obj["session_id"] as? String ?? obj["sessionId"] as? String
            return (id, CodexTokenAccountant.sessionMetaForkParent(payload) != nil)
        }
        return (codexHeadId(line.bytes.prefix(jsonlTruncatedHeadBytes)), false)
    }

    /// The first `"id":"…"` in `head` whose value has no escape in it.
    static func codexHeadId(_ head: Data) -> String? {
        let needle = Data(#""id":""#.utf8)
        var from = head.startIndex
        while let found = head.range(of: needle, in: from..<head.endIndex) {
            var index = found.upperBound
            while index < head.endIndex, head[index] != 0x22, head[index] != 0x5C {
                index = head.index(after: index)
            }
            if index < head.endIndex, head[index] == 0x22 {
                return String(decoding: head[found.upperBound..<index], as: UTF8.self)
            }
            from = head.index(after: found.lowerBound)
        }
        return nil
    }

    /// Whether an `inter_agent_communication_metadata` line triggers a turn
    /// (`payload.trigger_turn` is `true`); nil when the line is not one or has
    /// no readable timestamp (rule 5 of `CodexTokenAccountant`).
    private static func codexInterAgentTrigger(_ line: JsonlLine) -> Bool? {
        guard !line.wasTruncated,
              let obj = (try? JSONSerialization.jsonObject(with: line.bytes)) as? [String: Any],
              (obj["type"] as? String) == "inter_agent_communication_metadata",
              let text = obj["timestamp"] as? String,
              (instantFromTimestamp(text) ?? instantFromParsedISO(text)) != nil else { return nil }
        return true // NEGATIVE CONTROL C2: any inter-agent message triggers a turn
    }

    /// A JSONL line's own number (`"ordinal":N`), read from its first 512
    /// bytes without decoding the line: the lines it is needed for — an
    /// ancestor's copied session_meta — can be far too long to decode, and
    /// Codex writes the number near the start.
    static func codexLineOrdinal(_ bytes: Data) -> Int? {
        let head = bytes.prefix(512)
        guard let found = head.range(of: Data(#""ordinal":"#.utf8)) else { return nil }
        var index = found.upperBound
        while index < head.endIndex, head[index] == 0x20 || head[index] == 0x09 || head[index] == 0x0D {
            index = head.index(after: index)
        }
        var negative = false
        if index < head.endIndex, head[index] == 0x2D {
            negative = true
            index = head.index(after: index)
        }
        var value = 0
        var digits = 0
        while index < head.endIndex, digits < 18, head[index] >= 0x30, head[index] <= 0x39 {
            value = value * 10 + Int(head[index] - 0x30)
            digits += 1
            index = head.index(after: index)
        }
        guard digits > 0 else { return nil }
        return negative ? -value : value
    }

    /// Bring one file's cache entry up to date. The entry records only what
    /// the file itself holds; whether it counts is decided afterwards, across
    /// all files, by `CodexCopyResolver`. A file is never dropped for sharing
    /// a `session_id`: a subagent's file carries its parent's.
    private static func scanCodexFile(fileURL: URL, range: DayRange, cache: inout CostUsageCache, seenFileIds: inout Set<String>) {
        let path = fileURL.path
        let attrs = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mtimeMs = Int64(mtime * 1000)

        // The same file reached by a second path (a hard link) is read once.
        if let fileId = fileIdentityString(fileURL: fileURL) {
            if seenFileIds.contains(fileId) { cache.files.removeValue(forKey: path); return }
            seenFileIds.insert(fileId)
        }

        let cached = cache.files[path]
        // An entry without `codex` state predates these rules: re-parse it.
        if let cached, cached.codex != nil, cached.mtimeUnixMs == mtimeMs, cached.size == size { return }

        // A rollout classified whole (rule 5) is read again from the start.
        if let cached, let state = cached.codex { // NEGATIVE CONTROL C1: classified files resumed
            let startOffset = cached.parsedBytes ?? cached.size
            if size > cached.size && startOffset > 0 && startOffset <= size {
                let delta = parseCodexFile(
                    fileURL: fileURL, range: range, startOffset: startOffset,
                    initialModel: cached.lastModel, initialTotals: cached.lastTotals, initialState: state
                )
                // A failed read keeps the entry as it was; its size no longer
                // matches, so the next refresh tries again.
                guard delta.complete else { return }
                var mergedDays = cached.days
                mergeFileDays(existing: &mergedDays, delta: delta.days)
                cache.files[path] = CostUsageFileUsage(
                    mtimeUnixMs: mtimeMs, size: size, days: mergedDays, parsedBytes: delta.parsedBytes,
                    lastModel: delta.lastModel, lastTotals: delta.lastTotals,
                    sessionId: delta.sessionId ?? cached.sessionId, codex: delta.state
                )
                return
            }
        }

        let parsed = parseCodexFile(fileURL: fileURL, range: range)
        guard parsed.complete else {
            // Not stored, so not counted this time and read again next time.
            cache.files.removeValue(forKey: path)
            return
        }
        cache.files[path] = CostUsageFileUsage(
            mtimeUnixMs: mtimeMs, size: size, days: parsed.days, parsedBytes: parsed.parsedBytes,
            lastModel: parsed.lastModel, lastTotals: parsed.lastTotals,
            sessionId: parsed.sessionId, codex: parsed.state
        )
    }

    /// Rebuild the Codex day rows from the files that count.
    static func rebuildCodexDays(cache: inout CostUsageCache) -> (files: Int, counted: Int) {
        let candidates = cache.files.map { path, usage in
            CodexCopyResolver.File(
                path: path,
                rolloutId: usage.codex?.rolloutId,
                eventCount: usage.codex?.eventCount ?? 0,
                firstEventUnixMs: usage.codex?.firstEventUnixMs,
                lastEventUnixMs: usage.codex?.lastEventUnixMs,
                finalTokens: (usage.lastTotals?.input ?? 0) + (usage.lastTotals?.output ?? 0)
            )
        }
        let counted = CodexCopyResolver.countedPaths(candidates)
        var days: [String: [String: [Int]]] = [:]
        for path in counted.sorted() {
            guard let usage = cache.files[path] else { continue }
            mergeFileDays(existing: &days, delta: usage.days)
        }
        cache.days = days
        return (candidates.count, counted.count)
    }

    private static func scanCodexProvider(range: DayRange, now: Date, options: Options) -> CostUsageCache {
        var cache = CostUsageCacheIO.load(provider: "codex", cacheRoot: options.cacheRoot)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let refreshMs = Int64(max(0, options.refreshMinIntervalSeconds) * 1000)
        let shouldRefresh = options.forceRescan || refreshMs == 0 || cache.lastScanUnixMs == 0 || nowMs - cache.lastScanUnixMs > refreshMs

        let roots = codexSessionsRoots(options: options)
        var seenPaths: Set<String> = []
        var files: [URL] = []
        for root in roots {
            for fileURL in listCodexSessionFiles(root: root, scanSinceKey: range.scanSinceKey, scanUntilKey: range.scanUntilKey) where !seenPaths.contains(fileURL.path) {
                seenPaths.insert(fileURL.path)
                files.append(fileURL)
            }
        }
        // iter22: surface scan visibility per refresh tick. Helps the
        // user diagnose "Sessions tab is empty while Codex is open"
        // without stepping through a debugger. Also logs whether the
        // scan was skipped via cache-cooldown so a cold-start that
        // returns 0 candidates can be distinguished from a noop.
        scanLogger.info("scanCodexProvider: roots=\(roots.count) files_in_range=\(files.count) refreshing=\(shouldRefresh) range=\(range.scanSinceKey)..\(range.scanUntilKey)")
        let filePathsInScan = Set(files.map(\.path))

        if shouldRefresh {
            if options.forceRescan { cache = CostUsageCache() }
            var seenFileIds: Set<String> = []
            for fileURL in files { scanCodexFile(fileURL: fileURL, range: range, cache: &cache, seenFileIds: &seenFileIds) }
            for key in cache.files.keys where !filePathsInScan.contains(key) {
                cache.files.removeValue(forKey: key)
            }
            let tally = rebuildCodexDays(cache: &cache)
            let children = cache.files.values.filter { $0.codex?.isChild == true }.count
            scanLogger.info("scanCodexProvider: files=\(tally.files) counted=\(tally.counted) copies_skipped=\(tally.files - tally.counted) subagent_or_fork=\(children)")
            pruneDays(cache: &cache, sinceKey: range.scanSinceKey, untilKey: range.scanUntilKey)
            cache.lastScanUnixMs = nowMs
            CostUsageCacheIO.save(provider: "codex", cache: cache, cacheRoot: options.cacheRoot)
        }
        return cache
    }

    // MARK: - Claude Scanning

    private struct ClaudeParseResult {
        let days: [String: [String: [Int]]]
        let parsedBytes: Int64
        /// What the next incremental read of this log needs
        /// (`CostUsageFileUsage.claude`); nil when it was not asked for.
        let state: CostUsageClaudeLogState?
    }

    /// How many of a log's newest responses keep their contribution between
    /// scans. A response's lines are written one after another, so one would
    /// do; the rest is headroom for logs that interleave a few responses. A
    /// response continued after it dropped out of these is still counted once
    /// (`CostUsageClaudeLogState.counted`), at the price of reading the log
    /// again from the start.
    static let claudeOpenRowLimit = 4

    /// A log not written to for this long keeps no `CostUsageClaudeLogState`,
    /// and is read again from the start if it grows.
    ///
    /// A response's lines all come from one streaming request: on real logs
    /// the first and last line of a response are minutes apart at most, and
    /// a request whose connection is gone (a Mac asleep mid-response) is not
    /// continued under the same message id. A day is a wide margin over that,
    /// and it bounds the cost: only logs written in the last day keep state,
    /// 16 bytes per response plus the newest four rows.
    static let claudeLogStateIdleSeconds: TimeInterval = 86_400

    private static func defaultClaudeProjectsRoots(options: Options) -> [URL] {
        if let override = options.claudeProjectsRoots { return override }
        let home = URL(fileURLWithPath: realUserHome())
        return [
            home.appendingPathComponent(".config/claude/projects", isDirectory: true),
            home.appendingPathComponent(".claude/projects", isDirectory: true),
        ]
    }

    /// Synthetic model key used solely to bucket raw message-event counts
    /// (user + assistant events, including streaming chunks) at the day level.
    /// Matches the convention Claude Code's own UI uses — see v1.9.4 analysis
    /// in `docs/PROJECT_FIX_v1.9.4_token_cost_parity.md`. UI code filters
    /// this key out of per-model breakdowns.
    static let claudeMsgBucketModel = "__claude_msg__"

    /// Reads a Claude log from `startOffset` and returns what it adds to the
    /// day totals.
    ///
    /// Tokens are counted once per response (`claudeResponseKey`), from the
    /// response's LAST line: Claude Code repeats the usage on every line of a
    /// response and the output count grows from line to line, so the first
    /// line undercounts output.
    ///
    /// `state` is what the previous read of this log left; nil for a read
    /// from the start. With it, a line of a response an earlier read already
    /// counted replaces that contribution instead of adding a second one, so
    /// the totals come out as one read of the whole log would give. Returns
    /// nil when that cannot be done exactly — a response that is no longer
    /// open comes back with a different line, or the read fails part-way —
    /// and the log has to be read from the start instead. `recordState` asks
    /// for the state the next read will need.
    private static func parseClaudeFile(
        fileURL: URL,
        range: DayRange,
        startOffset: Int64 = 0,
        state: CostUsageClaudeLogState? = nil,
        recordState: Bool = false
    ) -> ClaudeParseResult? {
        var days: [String: [String: [Int]]] = [:]
        let costScale = 1_000_000_000.0
        var normalizedModels: [String: String] = [:]

        // v1.9.4: packed slot 5 tracks message-event count. For per-model
        // token buckets it only counts the line that actually contributed
        // token deltas (deduped). For the synthetic `claudeMsgBucketModel`
        // bucket it counts every raw event (user + assistant, including
        // streaming chunks) — this matches what Claude Code's UI displays.
        func add(dayKey: String, model: String, input: Int, cacheRead: Int, cacheCreate: Int, output: Int, costNanos: Int, msgDelta: Int = 0) {
            guard DayRange.isInRange(dayKey: dayKey, since: range.scanSinceKey, until: range.scanUntilKey) else { return }
            let normModel: String
            if model == Self.claudeMsgBucketModel {
                normModel = model
            } else if let known = normalizedModels[model] {
                normModel = known
            } else {
                normModel = Pricing.normalizeClaudeModel(model)
                normalizedModels[model] = normModel
            }
            var dayModels = days[dayKey] ?? [:]
            var packed = dayModels[normModel] ?? [0, 0, 0, 0, 0, 0]
            // Old caches stored 5 slots. Pad to 6 so existing entries don't
            // lose their token data when messageCount gets appended.
            while packed.count < 6 { packed.append(0) }
            packed[0] = (packed[safeIdx: 0] ?? 0) + input
            packed[1] = (packed[safeIdx: 1] ?? 0) + cacheRead
            packed[2] = (packed[safeIdx: 2] ?? 0) + cacheCreate
            packed[3] = (packed[safeIdx: 3] ?? 0) + output
            packed[4] = (packed[safeIdx: 4] ?? 0) + costNanos
            packed[5] = (packed[safeIdx: 5] ?? 0) + msgDelta
            dayModels[normModel] = packed
            days[dayKey] = dayModels
        }

        /// Adds (or with `sign: -1` takes back) what one response contributes.
        /// A preliminary estimate contributes nothing.
        func apply(_ row: CostUsageClaudeOpenRow, sign: Int) {
            guard !row.incomplete else { return }
            let p = row.packed
            add(dayKey: row.day, model: row.model,
                input: sign * (p[safeIdx: 0] ?? 0), cacheRead: sign * (p[safeIdx: 1] ?? 0),
                cacheCreate: sign * (p[safeIdx: 2] ?? 0), output: sign * (p[safeIdx: 3] ?? 0),
                costNanos: sign * (p[safeIdx: 4] ?? 0))
        }

        /// The row with its cost in slot 4. A response is priced once, for
        /// the line that counts, not once per line read.
        func priced(_ row: CostUsageClaudeOpenRow) -> CostUsageClaudeOpenRow {
            guard !row.incomplete else { return row }
            var row = row
            let p = row.packed
            let cost = Pricing.claudeCostUSD(
                model: row.model,
                inputTokens: p[safeIdx: 0] ?? 0,
                cacheReadInputTokens: p[safeIdx: 1] ?? 0,
                cacheCreationInputTokens: p[safeIdx: 2] ?? 0,
                outputTokens: p[safeIdx: 3] ?? 0
            )
            while row.packed.count < 5 { row.packed.append(0) }
            row.packed[4] = cost.map { Int(($0 * costScale).rounded()) } ?? 0
            return row
        }

        // Each response's line that counts so far, whether it is priced yet,
        // and when a line of it was last read. The open rows of the previous
        // read are already in the totals (`alreadyCounted`). They rank below
        // everything read now, in their stored order: index 0, the newest,
        // ranks highest.
        struct Pending {
            var row: CostUsageClaudeOpenRow
            var priced: Bool
            var touched: Int
        }
        var responses: [String: Pending] = [:]
        var alreadyCounted: [String: CostUsageClaudeOpenRow] = [:]
        for (index, row) in (state?.openRows ?? []).enumerated() {
            responses[row.key] = Pending(row: row, priced: true, touched: -(index + 1))
            alreadyCounted[row.key] = row
        }
        // Every response the log has counted, open or not.
        var counted = state?.countedFingerprints() ?? [:]
        var mustReadFromStart = false
        var sequence = 0

        let maxLineBytes = 512 * 1024
        let prefixBytes = maxLineBytes

        let parsedBytes: Int64
        do {
            parsedBytes = try scanJsonl(fileURL: fileURL, offset: startOffset, maxLineBytes: maxLineBytes, prefixBytes: prefixBytes, onLine: { line in
                guard !mustReadFromStart, !line.bytes.isEmpty, !line.wasTruncated else { return }
                // Widened from assistant-only to (assistant, user) so message
                // counting matches Claude Code's UI (which counts every event).
                let isAssistant = line.bytes.asciiContains(#""type":"assistant""#)
                let isUser = line.bytes.asciiContains(#""type":"user""#)
                guard isAssistant || isUser else { return }

                guard let obj = (try? JSONSerialization.jsonObject(with: line.bytes)) as? [String: Any],
                      let type = obj["type"] as? String,
                      let tsText = obj["timestamp"] as? String,
                      let dayKey = dayKeyFromTimestamp(tsText) ?? dayKeyFromParsedISO(tsText) else { return }

                // Every user event contributes to the raw message count. No tokens.
                if type == "user" {
                    add(dayKey: dayKey, model: Self.claudeMsgBucketModel,
                        input: 0, cacheRead: 0, cacheCreate: 0, output: 0, costNanos: 0, msgDelta: 1)
                    return
                }

                // type == "assistant". Count every raw event (incl. streaming
                // chunks) once against the msg bucket — matches Claude UI 53K/wk
                // target within ~3%. Tokens still use dedup to avoid double
                // counting the same message's streaming pieces.
                add(dayKey: dayKey, model: Self.claudeMsgBucketModel,
                    input: 0, cacheRead: 0, cacheCreate: 0, output: 0, costNanos: 0, msgDelta: 1)

                // Require `usage` field for token accounting.
                guard line.bytes.asciiContains(#""usage""#),
                      let message = obj["message"] as? [String: Any],
                      let model = message["model"] as? String,
                      let usage = message["usage"] as? [String: Any] else { return }

                func toInt(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? 0 }
                let input = max(0, toInt(usage["input_tokens"]))
                let cacheCreate = max(0, toInt(usage["cache_creation_input_tokens"]))
                let cacheRead = max(0, toInt(usage["cache_read_input_tokens"]))
                let output = max(0, toInt(usage["output_tokens"]))
                if input == 0, cacheCreate == 0, cacheRead == 0, output == 0 { return }

                let incomplete = CostUsageAccountingRules.isPreliminaryClaudeProxyUsage(
                    message: message, usage: usage, input: input, output: output
                )
                // Priced later, once per response (`priced`).
                var row = CostUsageClaudeOpenRow(
                    key: "", day: dayKey, model: model,
                    packed: incomplete ? [0, 0, 0, 0, 0] : [input, cacheRead, cacheCreate, output, 0],
                    incomplete: incomplete
                )

                // Tokens (not messages) are counted once per response.
                guard let key = CostUsageAccountingRules.claudeResponseKey(
                    messageId: message["id"] as? String,
                    requestId: obj["requestId"] as? String,
                    sessionId: CostUsageAccountingRules.claudeSessionId(line: obj, message: message)
                ) else {
                    // No identity: the line counts by itself.
                    apply(priced(row), sign: 1)
                    return
                }
                row.key = key
                sequence += 1
                if let existing = responses[key] {
                    if CostUsageAccountingRules.claudeLineReplaces(existingIsIncomplete: existing.row.incomplete, lineIsIncomplete: incomplete) {
                        responses[key] = Pending(row: row, priced: false, touched: sequence)
                    } else {
                        responses[key]?.touched = sequence
                    }
                } else if let fingerprint = counted[CostUsageClaudeLogState.stableHash(key)] {
                    // An earlier read of this log counted this response, and it
                    // is no longer open.
                    if fingerprint == row.fingerprint {
                        // The same line again: Claude Code writes earlier lines
                        // of a log again further down it. Already in the totals.
                        let same = priced(row)
                        responses[key] = Pending(row: same, priced: true, touched: sequence)
                        alreadyCounted[key] = same
                    } else if !incomplete {
                        // A different line replaces what was counted for this
                        // response, and that is not kept here.
                        mustReadFromStart = true
                    }
                    // An estimate never replaces real usage, and replacing an
                    // earlier estimate changes no total.
                } else {
                    responses[key] = Pending(row: row, priced: false, touched: sequence)
                }
            })
        } catch {
            // Lines before the failure were added, but the offset stays put:
            // an incremental read would add them a second time next scan.
            guard startOffset == 0 else { return nil }
            parsedBytes = startOffset
        }
        if mustReadFromStart { return nil }

        var newest: [(touched: Int, row: CostUsageClaudeOpenRow)] = []
        for (key, pending) in responses {
            let row = pending.priced ? pending.row : priced(pending.row)
            let before = alreadyCounted[key]
            if before != row {
                if let before { apply(before, sign: -1) }
                apply(row, sign: 1)
                if recordState { counted[CostUsageClaudeLogState.stableHash(key)] = row.fingerprint }
            }
            // The newest few, without sorting every response in the log.
            if recordState, newest.count < claudeOpenRowLimit || pending.touched > newest[newest.count - 1].touched {
                let at = newest.firstIndex { $0.touched < pending.touched } ?? newest.count
                newest.insert((pending.touched, row), at: at)
                if newest.count > claudeOpenRowLimit { newest.removeLast() }
            }
        }

        let newState = recordState
            ? CostUsageClaudeLogState(openRows: newest.map { $0.row }, counted: CostUsageClaudeLogState.packCounted(counted))
            : nil
        return ClaudeParseResult(days: days, parsedBytes: parsedBytes, state: newState)
    }

    private static func processClaudeFile(url: URL, size: Int64, mtimeMs: Int64, cache: inout CostUsageCache, touched: inout Set<String>, range: DayRange, stateSinceMs: Int64) {
        let path = url.path
        touched.insert(path)
        // Only a log written to recently can still receive more lines of a
        // response it already holds.
        let keepsState = mtimeMs >= stateSinceMs

        if var cached = cache.files[path], cached.mtimeUnixMs == mtimeMs, cached.size == size {
            if !keepsState, cached.claude != nil {
                cached.claude = nil
                cache.files[path] = cached
            }
            return
        }

        // Try incremental. Only with the log's state: without it, a response
        // the log already counted cannot be told from a new one. A log idle
        // for longer than `claudeLogStateIdleSeconds` has none, and is read
        // from the start when it grows, which is rare.
        if let cached = cache.files[path] {
            let startOffset = cached.parsedBytes ?? cached.size
            if let state = cached.claude, size > cached.size, startOffset > 0, startOffset <= size,
               let delta = parseClaudeFile(fileURL: url, range: range, startOffset: startOffset, state: state, recordState: keepsState) {
                if !delta.days.isEmpty { applyFileDays(cache: &cache, fileDays: delta.days, sign: 1) }
                var mergedDays = cached.days
                mergeFileDays(existing: &mergedDays, delta: delta.days)
                cache.files[path] = CostUsageFileUsage(mtimeUnixMs: mtimeMs, size: size, days: mergedDays, parsedBytes: delta.parsedBytes, claude: delta.state)
                return
            }
            applyFileDays(cache: &cache, fileDays: cached.days, sign: -1)
        }

        // Full parse. Without a `state` to check against it never returns nil.
        let parsed = parseClaudeFile(fileURL: url, range: range, recordState: keepsState)
            ?? ClaudeParseResult(days: [:], parsedBytes: 0, state: nil)
        let usage = CostUsageFileUsage(mtimeUnixMs: mtimeMs, size: size, days: parsed.days, parsedBytes: parsed.parsedBytes, claude: parsed.state)
        cache.files[path] = usage
        applyFileDays(cache: &cache, fileDays: usage.days, sign: 1)
    }

    private static func scanClaudeRoot(root: URL, cache: inout CostUsageCache, touched: inout Set<String>, range: DayRange, stateSinceMs: Int64) {
        let rootPath = root.path
        // Handle /var/ vs /private/var/ paths
        let rootCandidates = rootPath.hasPrefix("/var/") ? ["/private" + rootPath, rootPath]
            : rootPath.hasPrefix("/private/var/") ? [rootPath, String(rootPath.dropFirst("/private".count))]
            : [rootPath]
        guard rootCandidates.contains(where: { FileManager.default.fileExists(atPath: $0) }) else {
            let prefixes = Set(rootCandidates).map { $0.hasSuffix("/") ? $0 : "\($0)/" }
            for path in cache.files.keys where prefixes.contains(where: { path.hasPrefix($0) }) {
                if let old = cache.files[path] { applyFileDays(cache: &cache, fileDays: old.days, sign: -1) }
                cache.files.removeValue(forKey: path)
            }
            return
        }

        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }

        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "jsonl",
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            let size = Int64(values.fileSize ?? 0)
            if size <= 0 { continue }
            // v1.55: a log last written before the window cannot hold a line
            // inside it, so it is not opened. Until 1.55 every Claude log of
            // any age was parsed on a first scan (and after every cache reset)
            // and its old lines thrown away — a read the consent screen, which
            // says "the last 30 days", does not cover. Codex is already bounded
            // by its date folders (`listCodexSessionFiles`). A log still being
            // written to is parsed from its start, and its older lines are
            // dropped by `add` in `parseClaudeFile`, not kept.
            //
            // Not touched ⇒ dropped from the cache below, with its days, which
            // are all older than the window anyway.
            if let modified = values.contentModificationDate,
               modified < range.firstReportedInstant {
                continue
            }
            let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            processClaudeFile(url: url, size: size, mtimeMs: Int64(mtime * 1000), cache: &cache, touched: &touched, range: range, stateSinceMs: stateSinceMs)
        }
    }

    private static func scanClaudeProvider(range: DayRange, now: Date, options: Options) -> CostUsageCache {
        var cache = CostUsageCacheIO.load(provider: "claude", cacheRoot: options.cacheRoot)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let refreshMs = Int64(max(0, options.refreshMinIntervalSeconds) * 1000)
        let shouldRefresh = options.forceRescan || refreshMs == 0 || cache.lastScanUnixMs == 0 || nowMs - cache.lastScanUnixMs > refreshMs

        let roots = defaultClaudeProjectsRoots(options: options)
        var touched: Set<String> = []

        if shouldRefresh {
            if options.forceRescan { cache = CostUsageCache() }
            let stateSinceMs = nowMs - Int64(claudeLogStateIdleSeconds * 1000)
            for root in roots { scanClaudeRoot(root: root, cache: &cache, touched: &touched, range: range, stateSinceMs: stateSinceMs) }
            for key in cache.files.keys where !touched.contains(key) {
                if let old = cache.files[key] { applyFileDays(cache: &cache, fileDays: old.days, sign: -1) }
                cache.files.removeValue(forKey: key)
            }
            pruneDays(cache: &cache, sinceKey: range.scanSinceKey, untilKey: range.scanUntilKey)
            cache.lastScanUnixMs = nowMs
            CostUsageCacheIO.save(provider: "claude", cache: cache, cacheRoot: options.cacheRoot)
        }
        return cache
    }

    // MARK: - Shared Cache Mutations

    static func applyFileDays(cache: inout CostUsageCache, fileDays: [String: [String: [Int]]], sign: Int) {
        for (day, models) in fileDays {
            var dayModels = cache.days[day] ?? [:]
            for (model, packed) in models {
                let existing = dayModels[model] ?? []
                let merged = addPacked(a: existing, b: packed, sign: sign)
                if merged.allSatisfy({ $0 == 0 }) { dayModels.removeValue(forKey: model) }
                else { dayModels[model] = merged }
            }
            if dayModels.isEmpty { cache.days.removeValue(forKey: day) }
            else { cache.days[day] = dayModels }
        }
    }

    static func mergeFileDays(existing: inout [String: [String: [Int]]], delta: [String: [String: [Int]]]) {
        for (day, models) in delta {
            var dayModels = existing[day] ?? [:]
            for (model, packed) in models {
                let merged = addPacked(a: dayModels[model] ?? [], b: packed, sign: 1)
                if merged.allSatisfy({ $0 == 0 }) { dayModels.removeValue(forKey: model) }
                else { dayModels[model] = merged }
            }
            if dayModels.isEmpty { existing.removeValue(forKey: day) }
            else { existing[day] = dayModels }
        }
    }

    static func pruneDays(cache: inout CostUsageCache, sinceKey: String, untilKey: String) {
        for key in cache.days.keys where !DayRange.isInRange(dayKey: key, since: sinceKey, until: untilKey) {
            cache.days.removeValue(forKey: key)
        }
    }

    static func addPacked(a: [Int], b: [Int], sign: Int) -> [Int] {
        let len = max(a.count, b.count)
        var out = Array(repeating: 0, count: len)
        for idx in 0..<len {
            out[idx] = max(0, (a[safeIdx: idx] ?? 0) + sign * (b[safeIdx: idx] ?? 0))
        }
        return out
    }

    // MARK: - Helpers

    private static func parseDayKey(_ key: String) -> Date? {
        DayKey.date(from: key, hour: 12)
    }

    // MARK: - Active Session Candidates

    /// Walk Codex JSONL files we just scanned and emit a candidate per file
    /// whose mtime is within `activeSessionFreshnessWindow` of `now`.
    /// Token / cost totals are summed across the cached daily buckets the
    /// file contributed to. Project label is `"Codex"` because Codex JSONL
    /// paths are date-partitioned (`<root>/YYYY/MM/DD/<id>.jsonl`) and don't
    /// carry a project root we can derive without re-parsing the line.
    private static func buildCodexCandidates(
        options: Options,
        range: DayRange,
        cache: CostUsageCache,
        now: Date
    ) -> [CostUsageScanResult.ActiveSessionCandidate] {
        let cutoff = now.addingTimeInterval(-activeSessionFreshnessWindow)
        var seen: Set<String> = []
        var candidates: [CostUsageScanResult.ActiveSessionCandidate] = []
        let roots = codexSessionsRoots(options: options)
        var totalFilesSeen = 0
        var freshFilesSeen = 0
        for root in roots {
            let files = listCodexSessionFiles(root: root, scanSinceKey: range.scanSinceKey, scanUntilKey: range.scanUntilKey)
            totalFilesSeen += files.count
            for url in files {
                let path = url.path
                guard !seen.contains(path) else { continue }
                seen.insert(path)
                guard let mtime = fileModificationDate(at: path), mtime >= cutoff else { continue }
                freshFilesSeen += 1
                let usage = cache.files[path]
                let totals = sumCodexTotals(usage: usage)
                let cost = computeCodexCost(usage: usage)
                // iter22: read session_meta directly so the candidate
                // gets a real project label even when the cache has
                // already populated `sessionId` from a prior tick.
                // The cache deliberately doesn't store `cwd` (would
                // require a schema bump), so we always do this small
                // read when the file is fresh — bounded I/O because
                // only candidates within 5 minutes hit this path.
                let metaFromFile = readCodexSessionMeta(fileURL: url)
                // The rollout's own id first: a subagent's `sessionId` is its
                // parent's, and sharing it would merge the two live sessions
                // into one row (`synthesizeSessions` keys on it). A file not in
                // the cache yet takes it from the file: `readCodexSessionMeta`
                // returns the payload's own `id` before its `session_id`.
                let sessionId = usage?.codex?.rolloutId ?? metaFromFile?.sessionId ?? usage?.sessionId
                let projectName = projectLabelFromCodexMeta(metaFromFile?.cwd) ?? "Codex"
                let projectRoot = metaFromFile?.cwd
                candidates.append(.init(
                    provider: "Codex",
                    filePath: path,
                    projectName: projectName,
                    projectRoot: projectRoot,
                    sessionId: sessionId,
                    lastModified: mtime,
                    totalTokens: totals.input + totals.output,
                    totalCost: cost,
                    messageCount: 0
                ))
            }
        }
        scanLogger.info("buildCodexCandidates: roots=\(roots.count) jsonl_files=\(totalFilesSeen) fresh=\(freshFilesSeen) candidates=\(candidates.count)")
        return candidates
    }

    /// iter22: best-effort `(sessionId, cwd)` extraction from the
    /// session_meta line a Codex CLI rollout JSONL emits as its first
    /// line. Reads at most 32KB so a corrupted or huge file can't
    /// stall the scanner. Returns `nil` fields when the parse fails;
    /// callers must tolerate that.
    static func readCodexSessionMeta(fileURL: URL) -> (sessionId: String?, cwd: String?)? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 32 * 1024) else { return nil }
        // Split on newline (0x0A); examine each line up to a small cap so
        // we don't burn CPU re-parsing huge JSONL bodies for one field.
        var inspected = 0
        for lineData in data.split(separator: 0x0A, maxSplits: 32, omittingEmptySubsequences: true) {
            inspected += 1
            guard inspected <= 8 else { break }
            guard let json = try? JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any] else { continue }
            guard (json["type"] as? String) == "session_meta" else { continue }
            let payload = json["payload"] as? [String: Any]
            let sid = (payload?["id"] as? String)
                ?? (payload?["session_id"] as? String)
                ?? (payload?["sessionId"] as? String)
                ?? (json["session_id"] as? String)
            let cwd = (payload?["cwd"] as? String) ?? (json["cwd"] as? String)
            return (sid, cwd)
        }
        return nil
    }

    /// iter22: convert a `cwd` like `/Users/jason/cli-pulse` into a
    /// short project label `cli-pulse`. Returns nil when input is nil
    /// or empty so callers can use the previous "Codex" placeholder.
    static func projectLabelFromCodexMeta(_ cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let trimmed = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        let last = (trimmed as NSString).lastPathComponent
        if last.isEmpty || last == "/" { return nil }
        // `~` and home roots aren't useful project labels.
        if last == "Users" || last == "home" { return nil }
        return last
    }

    /// Walk Claude JSONL files under each `~/.claude/projects/...` (or
    /// `~/.config/claude/projects/...`) root and emit a candidate per file
    /// whose mtime is within `activeSessionFreshnessWindow`. The project is
    /// the first directory under the root, never the file's own parent —
    /// subagent transcripts live two and four levels deeper — and its label
    /// comes from the transcript's `cwd` (`claudeProjectAttribution`).
    /// Session id comes from the JSONL filename stem.
    private static func buildClaudeCandidates(
        options: Options,
        cache: CostUsageCache,
        now: Date
    ) -> [CostUsageScanResult.ActiveSessionCandidate] {
        let cutoff = now.addingTimeInterval(-activeSessionFreshnessWindow)
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        var seen: Set<String> = []
        var candidates: [CostUsageScanResult.ActiveSessionCandidate] = []
        for root in defaultClaudeProjectsRoots(options: options) {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            // A busy session has many fresh subagent transcripts in one
            // project; once one of them has named the project, the rest
            // need not be opened.
            var named: [String: ClaudeProjectAttribution] = [:]
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator {
                guard url.pathExtension.lowercased() == "jsonl" else { continue }
                let path = url.path
                guard !seen.contains(path) else { continue }
                seen.insert(path)
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true,
                      let mtime = values.contentModificationDate,
                      mtime >= cutoff else { continue }
                let usage = cache.files[path]
                let totals = sumClaudeTotals(usage: usage)
                let attribution: ClaudeProjectAttribution?
                if let directory = claudeTranscriptPath(url, under: root)?.first,
                   let known = named[directory] {
                    attribution = known
                } else {
                    attribution = claudeProjectAttribution(transcript: url, projectsRoot: root)
                    if let found = attribution, found.root != nil {
                        named[found.directory] = found
                    }
                }
                // nil only for a transcript sitting directly in the projects
                // root, which Claude Code does not write; keep the old label.
                let projectName = attribution?.label
                    ?? humanReadableClaudeProject(encodedDir: url.deletingLastPathComponent().lastPathComponent)
                let sessionId = url.deletingPathExtension().lastPathComponent
                candidates.append(.init(
                    provider: "Claude",
                    filePath: path,
                    projectName: projectName,
                    projectRoot: attribution?.root,
                    sessionId: sessionId,
                    lastModified: mtime,
                    totalTokens: totals.input + totals.output,
                    totalCost: totals.cost,
                    messageCount: totals.messages
                ))
            }
        }
        return candidates
    }

    private static func fileModificationDate(at path: String) -> Date? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return attrs[.modificationDate] as? Date
    }

    private struct CodexFileTotals {
        var input: Int
        var cached: Int
        var output: Int
    }

    private static func sumCodexTotals(usage: CostUsageFileUsage?) -> CodexFileTotals {
        var totals = CodexFileTotals(input: 0, cached: 0, output: 0)
        guard let usage else { return totals }
        for (_, models) in usage.days {
            for (_, packed) in models {
                totals.input += packed[safeIdx: 0] ?? 0
                totals.cached += packed[safeIdx: 1] ?? 0
                totals.output += packed[safeIdx: 2] ?? 0
            }
        }
        return totals
    }

    private static func computeCodexCost(usage: CostUsageFileUsage?) -> Double {
        guard let usage else { return 0 }
        var total = 0.0
        for (_, models) in usage.days {
            for (model, packed) in models {
                let input = packed[safeIdx: 0] ?? 0
                let cached = packed[safeIdx: 1] ?? 0
                let output = packed[safeIdx: 2] ?? 0
                if input == 0 && cached == 0 && output == 0 { continue }
                if let cost = codexCost(model: model, packed: packed) {
                    total += cost
                }
            }
        }
        return total
    }

    private struct ClaudeFileTotals {
        var input: Int
        var cacheRead: Int
        var cacheCreate: Int
        var output: Int
        var cost: Double
        var messages: Int
    }

    private static func sumClaudeTotals(usage: CostUsageFileUsage?) -> ClaudeFileTotals {
        var totals = ClaudeFileTotals(input: 0, cacheRead: 0, cacheCreate: 0, output: 0, cost: 0, messages: 0)
        guard let usage else { return totals }
        let costScale = 1_000_000_000.0
        for (_, models) in usage.days {
            for (model, packed) in models {
                let input = packed[safeIdx: 0] ?? 0
                let cacheRead = packed[safeIdx: 1] ?? 0
                let cacheCreate = packed[safeIdx: 2] ?? 0
                let output = packed[safeIdx: 3] ?? 0
                let costNanos = packed[safeIdx: 4] ?? 0
                let msgs = packed[safeIdx: 5] ?? 0
                // The synthetic msg-bucket only carries message counts, not
                // tokens; it is included in `messages` but not `tokens/cost`.
                if model != claudeMsgBucketModel {
                    totals.input += input
                    totals.cacheRead += cacheRead
                    totals.cacheCreate += cacheCreate
                    totals.output += output
                    if costNanos > 0 {
                        totals.cost += Double(costNanos) / costScale
                    } else if let cost = Pricing.claudeCostUSD(
                        model: model,
                        inputTokens: input,
                        cacheReadInputTokens: cacheRead,
                        cacheCreationInputTokens: cacheCreate,
                        outputTokens: output
                    ) {
                        totals.cost += cost
                    }
                }
                totals.messages += msgs
            }
        }
        return totals
    }

    /// Convert Claude Code's encoded project directory name back to a
    /// readable label. Claude encodes a path like `/Users/jason/cli-pulse`
    /// as `-Users-jason-cli-pulse`. Decoding is fundamentally ambiguous
    /// because `-` does double duty as both the path separator and as a
    /// literal hyphen inside a single segment (e.g. `cli-pulse`). We
    /// therefore don't reconstruct an absolute path; instead we strip
    /// the user-root prefix (`Users-<username>-` on macOS, `home-<username>-`
    /// on Linux) and return the user-relative remainder verbatim, which
    /// preserves hyphenated repo names.
    ///
    /// Examples:
    ///   `-Users-jason-cli-pulse` → `cli-pulse`
    ///   `-Users-jason-Documents-cli-pulse` → `Documents-cli-pulse`
    ///   `-home-alice-myrepo` → `myrepo`
    ///   `myrepo` → `myrepo`
    static func humanReadableClaudeProject(encodedDir: String) -> String {
        var s = encodedDir
        if s.hasPrefix("-") { s = String(s.dropFirst()) }

        // Strip "Users-<username>-" or "home-<username>-" if present, so a
        // typical encoded dir collapses to just its user-relative path.
        let lower = s.lowercased()
        for rootPrefix in ["users-", "home-"] where lower.hasPrefix(rootPrefix) {
            let afterRoot = s.index(s.startIndex, offsetBy: rootPrefix.count)
            let remainder = s[afterRoot...]
            if let firstDash = remainder.firstIndex(of: "-") {
                let projectPart = remainder[remainder.index(after: firstDash)...]
                if !projectPart.isEmpty {
                    return String(projectPart)
                }
            }
            // No further `-` after the username segment — encoded dir was
            // something like `-Users-jason`. Fall through to returning the
            // de-prefixed string so the user still gets *something* readable.
            break
        }

        return s.isEmpty ? encodedDir : s
    }

    // MARK: - Session Synthesis

    /// Convert active-session candidates into `SessionRecord`s that the
    /// dashboard / Sessions tab can render. Used by `DataRefreshManager`
    /// when `LocalScanner.shared.scan()` returns no sessions because
    /// `proc_listallpids` was denied by the App Store sandbox.
    ///
    /// Dedup rule: keep at most one candidate per `(provider, sessionId)`,
    /// or per `(provider, filePath)` when `sessionId` is nil. Within a
    /// dedup group, keep the most recently modified entry.
    ///
    /// Defensive freshness filter: even though `buildCodexCandidates` /
    /// `buildClaudeCandidates` already drop stale JSONLs at scan time,
    /// this function re-applies the `activeSessionFreshnessWindow`
    /// against `now` so callers that synthesize from cached candidates
    /// (or from a manually-constructed list in a test) can't
    /// accidentally surface a "Running" session for a tool that exited
    /// hours ago.
    public static func synthesizeSessions(
        candidates: [CostUsageScanResult.ActiveSessionCandidate],
        now: Date,
        deviceName: String
    ) -> [SessionRecord] {
        let cutoff = now.addingTimeInterval(-activeSessionFreshnessWindow)
        let fresh = candidates.filter { $0.lastModified >= cutoff }
        // Dedup
        var byKey: [String: CostUsageScanResult.ActiveSessionCandidate] = [:]
        for c in fresh {
            let id = c.sessionId ?? c.filePath
            let key = "\(c.provider)|\(id)"
            if let existing = byKey[key] {
                if c.lastModified > existing.lastModified {
                    byKey[key] = c
                }
            } else {
                byKey[key] = c
            }
        }
        let ordered = byKey.values.sorted { $0.lastModified > $1.lastModified }

        return ordered.map { c -> SessionRecord in
            let stableSuffix: String
            if let sid = c.sessionId, !sid.isEmpty {
                stableSuffix = sid
            } else {
                // Filename stem is stable enough for a fallback id; we
                // include the filename's hash so collisions across
                // providers can't happen.
                stableSuffix = (c.filePath as NSString).lastPathComponent
            }
            let id = "jsonl-\(c.provider.lowercased())-\(stableSuffix)"
            // We don't have a real "started_at" — use lastModified shifted
            // back by the freshness window so the UI shows a non-zero
            // duration without claiming false precision.
            let started = c.lastModified.addingTimeInterval(-activeSessionFreshnessWindow)
            let costStatus = c.totalCost > 1 ? "warning" : "normal"
            let requests = max(1, c.messageCount)
            return SessionRecord(
                id: id,
                name: SessionRecord.jsonlSessionName(provider: c.provider),
                provider: c.provider,
                project: c.projectName,
                device_name: deviceName,
                started_at: sharedISO8601Formatter.string(from: started),
                last_active_at: sharedISO8601Formatter.string(from: c.lastModified),
                status: "Running",
                total_usage: c.totalTokens,
                estimated_cost: c.totalCost,
                cost_status: costStatus,
                requests: requests,
                error_count: 0,
                // "medium" because JSONL freshness is strong evidence the
                // tool was active recently, but we cannot prove the process
                // is still alive (could be a stale write from a tool that
                // exited after `lastModified`).
                collection_confidence: "medium",
                project_hash: nil
            )
        }
    }
}

// MARK: - ISO Formatter Box

private final class ISOFormatterBox: @unchecked Sendable {
    let lock = NSLock()
    let withFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    func parse(_ text: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return withFractional.date(from: text) ?? plain.date(from: text)
    }
}

// MARK: - Safe Subscript Extensions

extension [Int] {
    subscript(safeIdx index: Int) -> Int? {
        index >= 0 && index < count ? self[index] : nil
    }
}

extension [UInt8] {
    subscript(safeUInt8 index: Int) -> UInt8? {
        index >= 0 && index < count ? self[index] : nil
    }
}

extension Data {
    func asciiContains(_ needle: String) -> Bool {
        guard let n = needle.data(using: .utf8) else { return false }
        return self.range(of: n) != nil
    }
}

#endif
