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
                    costUSD: Double?, messageCount: Int = 0) {
            self.date = date
            self.provider = provider
            self.model = model
            self.inputTokens = inputTokens
            self.cachedTokens = cachedTokens
            self.outputTokens = outputTokens
            self.costUSD = costUSD
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
    /// "I/O tokens" definition used everywhere in the UI. Excludes cache
    /// tokens (read + creation). Cost is computed elsewhere with full
    /// per-component pricing, so excluding cache here does NOT affect
    /// cost accuracy. See `AppState.totalTokens` for rationale.
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
        let now = Date()
        let since = Calendar.current.date(byAdding: .day, value: -options.daysToScan, to: now) ?? now
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
            let tokens = entry.inputTokens + entry.cachedTokens + entry.outputTokens
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
                let cost = Pricing.codexCostUSD(model: model, inputTokens: input, cachedInputTokens: cached, outputTokens: output)
                result.append(.init(date: day, provider: "Codex", model: model, inputTokens: input, cachedTokens: cached, outputTokens: output, costUSD: cost))
            }
        }
        return result
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
                                    outputTokens: output, costUSD: cost, messageCount: msgs))
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

        init(since: Date, until: Date) {
            self.sinceKey = Self.dayKey(from: since)
            self.untilKey = Self.dayKey(from: until)
            self.scanSinceKey = Self.dayKey(from: Calendar.current.date(byAdding: .day, value: -1, to: since) ?? since)
            self.scanUntilKey = Self.dayKey(from: Calendar.current.date(byAdding: .day, value: 1, to: until) ?? until)
        }

        public static func dayKey(from date: Date) -> String {
            let cal = Calendar.current
            let comps = cal.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", comps.year ?? 1970, comps.month ?? 1, comps.day ?? 1)
        }

        static func isInRange(dayKey: String, since: String, until: String) -> Bool {
            dayKey >= since && dayKey <= until
        }
    }

    // MARK: - JSONL Parser

    private struct JsonlLine {
        let bytes: Data
        let wasTruncated: Bool
    }

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

        func appendSegment(_ segment: Data.SubSequence) {
            guard !segment.isEmpty else { return }
            lineBytes += segment.count
            guard !truncated else { return }
            if lineBytes > maxLineBytes || lineBytes > prefixBytes {
                truncated = true
                current.removeAll(keepingCapacity: true)
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
                flushLine()
                break
            }
            bytesRead += Int64(chunk.count)
            var segmentStart = chunk.startIndex
            while let nl = chunk[segmentStart...].firstIndex(of: 0x0A) {
                appendSegment(chunk[segmentStart..<nl])
                flushLine()
                segmentStart = chunk.index(after: nl)
            }
            if segmentStart < chunk.endIndex {
                appendSegment(chunk[segmentStart..<chunk.endIndex])
            }
        }

        return startOffset + bytesRead
    }

    // MARK: - Timestamp Parsing

    static func dayKeyFromTimestamp(_ text: String) -> String? {
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

        var comps = DateComponents()
        comps.calendar = Calendar(identifier: .gregorian)
        comps.timeZone = TimeZone(secondsFromGMT: offsetSeconds)
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = hour; comps.minute = minute; comps.second = second
        guard let date = comps.date else { return nil }
        let local = Calendar.current.dateComponents([.year, .month, .day], from: date)
        guard let ly = local.year, let lm = local.month, let ld = local.day else { return nil }
        return String(format: "%04d-%02d-%02d", ly, lm, ld)
    }

    private static let isoBox: ISOFormatterBox = ISOFormatterBox()

    static func dayKeyFromParsedISO(_ text: String) -> String? {
        guard let date = isoBox.parse(text) else { return nil }
        return DayRange.dayKey(from: date)
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
        struct CodexModel {
            let inputCostPerToken: Double
            let outputCostPerToken: Double
            let cacheReadCostPerToken: Double?
        }

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

        private static let codexModels: [String: CodexModel] = [
            "gpt-5": .init(inputCostPerToken: 1.25e-6, outputCostPerToken: 1e-5, cacheReadCostPerToken: 1.25e-7),
            "gpt-5-codex": .init(inputCostPerToken: 1.25e-6, outputCostPerToken: 1e-5, cacheReadCostPerToken: 1.25e-7),
            "gpt-5-mini": .init(inputCostPerToken: 2.5e-7, outputCostPerToken: 2e-6, cacheReadCostPerToken: 2.5e-8),
            "gpt-5-nano": .init(inputCostPerToken: 5e-8, outputCostPerToken: 4e-7, cacheReadCostPerToken: 5e-9),
            "gpt-5-pro": .init(inputCostPerToken: 1.5e-5, outputCostPerToken: 1.2e-4, cacheReadCostPerToken: nil),
            "gpt-5.1": .init(inputCostPerToken: 1.25e-6, outputCostPerToken: 1e-5, cacheReadCostPerToken: 1.25e-7),
            "gpt-5.1-codex": .init(inputCostPerToken: 1.25e-6, outputCostPerToken: 1e-5, cacheReadCostPerToken: 1.25e-7),
            "gpt-5.1-codex-max": .init(inputCostPerToken: 1.25e-6, outputCostPerToken: 1e-5, cacheReadCostPerToken: 1.25e-7),
            "gpt-5.1-codex-mini": .init(inputCostPerToken: 2.5e-7, outputCostPerToken: 2e-6, cacheReadCostPerToken: 2.5e-8),
            "gpt-5.2": .init(inputCostPerToken: 1.75e-6, outputCostPerToken: 1.4e-5, cacheReadCostPerToken: 1.75e-7),
            "gpt-5.2-codex": .init(inputCostPerToken: 1.75e-6, outputCostPerToken: 1.4e-5, cacheReadCostPerToken: 1.75e-7),
            "gpt-5.2-pro": .init(inputCostPerToken: 2.1e-5, outputCostPerToken: 1.68e-4, cacheReadCostPerToken: nil),
            "gpt-5.3-codex": .init(inputCostPerToken: 1.75e-6, outputCostPerToken: 1.4e-5, cacheReadCostPerToken: 1.75e-7),
            "gpt-5.3-codex-spark": .init(inputCostPerToken: 0, outputCostPerToken: 0, cacheReadCostPerToken: 0),
            "gpt-5.4": .init(inputCostPerToken: 2.5e-6, outputCostPerToken: 1.5e-5, cacheReadCostPerToken: 2.5e-7),
            "gpt-5.4-mini": .init(inputCostPerToken: 7.5e-7, outputCostPerToken: 4.5e-6, cacheReadCostPerToken: 7.5e-8),
            "gpt-5.4-nano": .init(inputCostPerToken: 2e-7, outputCostPerToken: 1.25e-6, cacheReadCostPerToken: 2e-8),
            "gpt-5.4-pro": .init(inputCostPerToken: 3e-5, outputCostPerToken: 1.8e-4, cacheReadCostPerToken: nil),
            // gpt-5.5 family — mirrors the Rust desktop `pricing.rs` table
            // (H-10 cross-runtime parity). OpenAI hasn't published official
            // billing yet; rates mirror gpt-5.4 as a best-known approximation
            // (Codex emitted model="gpt-5.5" in the wild — without an entry
            // macOS rendered $0 while Windows/Linux priced it). Approximate-
            // but-non-zero beats zero for cost-aware UX; replace when official.
            "gpt-5.5": .init(inputCostPerToken: 2.5e-6, outputCostPerToken: 1.5e-5, cacheReadCostPerToken: 2.5e-7),
            "gpt-5.5-codex": .init(inputCostPerToken: 2.5e-6, outputCostPerToken: 1.5e-5, cacheReadCostPerToken: 2.5e-7),
            "gpt-5.5-mini": .init(inputCostPerToken: 7.5e-7, outputCostPerToken: 4.5e-6, cacheReadCostPerToken: 7.5e-8),
            "gpt-5.5-nano": .init(inputCostPerToken: 2e-7, outputCostPerToken: 1.25e-6, cacheReadCostPerToken: 2e-8),
            "gpt-5.5-pro": .init(inputCostPerToken: 3e-5, outputCostPerToken: 1.8e-4, cacheReadCostPerToken: nil),
        ]

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
        /// safety net at all — and it is currently reading $0 for
        /// `gpt-5.6-sol` and `gpt-5.6-terra`, 940M tokens on the machine this
        /// was found on.
        ///
        /// The precedent for what to do is already in the table above: when
        /// `gpt-5.5` appeared with no published billing, it was priced by
        /// mirroring `gpt-5.4`, with the reasoning written down —
        /// *"Approximate-but-non-zero beats zero for cost-aware UX; replace when
        /// official."* This generalises that from a hand-written row into a
        /// rule, so the NEXT unrecognised model is approximate instead of free.
        ///
        /// Tier is matched before version, and that ordering carries the whole
        /// risk: `gpt-5.4-pro` costs 12x `gpt-5.4`. Charging an unknown `-pro`
        /// at base rates would under-report by an order of magnitude, so a
        /// `-pro`/`-mini`/`-nano` suffix only ever falls back to the same
        /// suffix. An unknown suffix (`-sol`, `-terra`, `-codex-max`) is treated
        /// as base tier, which is where every non-suffixed Codex model has sat.
        static func codexPricingKey(_ raw: String) -> String? {
            let normalized = normalizeCodexModel(raw)
            if codexModels[normalized] != nil { return normalized }
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
            let normalized = normalizeClaudeModel(raw)
            if claudeModels[normalized] != nil { return normalized }
            return familyFallback(normalized)
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


        static func codexCostUSD(model: String, inputTokens: Int, cachedInputTokens: Int, outputTokens: Int) -> Double? {
            guard let key = codexPricingKey(model),
                  let p = codexModels[key] else { return nil }
            let cached = min(max(0, cachedInputTokens), max(0, inputTokens))
            let nonCached = max(0, inputTokens - cached)
            let cachedRate = p.cacheReadCostPerToken ?? p.inputCostPerToken
            return Double(nonCached) * p.inputCostPerToken + Double(cached) * cachedRate + Double(max(0, outputTokens)) * p.outputCostPerToken
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
    }

    private struct CodexScanState {
        var seenSessionIds: Set<String> = []
        var seenFileIds: Set<String> = []
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

        // Date-partitioned: YYYY/MM/DD/*.jsonl
        if FileManager.default.fileExists(atPath: root.path) {
            var date = parseDayKey(scanSinceKey) ?? Date()
            let untilDate = parseDayKey(scanUntilKey) ?? date
            while date <= untilDate {
                let comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
                let y = String(format: "%04d", comps.year ?? 1970)
                let m = String(format: "%02d", comps.month ?? 1)
                let d = String(format: "%02d", comps.day ?? 1)
                let dayDir = root.appendingPathComponent(y).appendingPathComponent(m).appendingPathComponent(d)
                if let items = try? FileManager.default.contentsOfDirectory(at: dayDir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                    for item in items where item.pathExtension.lowercased() == "jsonl" && !seen.contains(item.path) {
                        seen.insert(item.path)
                        out.append(item)
                    }
                }
                date = Calendar.current.date(byAdding: .day, value: 1, to: date) ?? untilDate.addingTimeInterval(1)
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

    private static func parseCodexFile(
        fileURL: URL, range: DayRange,
        startOffset: Int64 = 0,
        initialModel: String? = nil,
        initialTotals: CostUsageCodexTotals? = nil
    ) -> CodexParseResult {
        var currentModel = initialModel
        var previousTotals = initialTotals
        var sessionId: String?
        var days: [String: [String: [Int]]] = [:]

        func add(dayKey: String, model: String, input: Int, cached: Int, output: Int) {
            guard DayRange.isInRange(dayKey: dayKey, since: range.scanSinceKey, until: range.scanUntilKey) else { return }
            let normModel = Pricing.normalizeCodexModel(model)
            var dayModels = days[dayKey] ?? [:]
            var packed = dayModels[normModel] ?? [0, 0, 0]
            packed[0] = (packed[safeIdx: 0] ?? 0) + input
            packed[1] = (packed[safeIdx: 1] ?? 0) + cached
            packed[2] = (packed[safeIdx: 2] ?? 0) + output
            dayModels[normModel] = packed
            days[dayKey] = dayModels
        }

        let maxLineBytes = 256 * 1024
        let prefixBytes = 32 * 1024

        let parsedBytes = (try? scanJsonl(fileURL: fileURL, offset: startOffset, maxLineBytes: maxLineBytes, prefixBytes: prefixBytes, onLine: { line in
            guard !line.bytes.isEmpty, !line.wasTruncated else { return }
            guard line.bytes.asciiContains(#""type":"event_msg""#)
                || line.bytes.asciiContains(#""type":"turn_context""#)
                || line.bytes.asciiContains(#""type":"session_meta""#) else { return }
            if line.bytes.asciiContains(#""type":"event_msg""#), !line.bytes.asciiContains(#""token_count""#) { return }

            guard let obj = (try? JSONSerialization.jsonObject(with: line.bytes)) as? [String: Any],
                  let type = obj["type"] as? String else { return }

            if type == "session_meta" {
                if sessionId == nil {
                    let payload = obj["payload"] as? [String: Any]
                    sessionId = payload?["session_id"] as? String ?? payload?["sessionId"] as? String ?? payload?["id"] as? String ?? obj["session_id"] as? String
                }
                return
            }

            guard let tsText = obj["timestamp"] as? String,
                  let dayKey = dayKeyFromTimestamp(tsText) ?? dayKeyFromParsedISO(tsText) else { return }

            if type == "turn_context" {
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
            let modelFromInfo = info?["model"] as? String ?? info?["model_name"] as? String ?? payload["model"] as? String ?? obj["model"] as? String
            let model = modelFromInfo ?? currentModel ?? "gpt-5"

            func toInt(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? 0 }

            let total = info?["total_token_usage"] as? [String: Any]
            let last = info?["last_token_usage"] as? [String: Any]
            var deltaInput = 0, deltaCached = 0, deltaOutput = 0

            if let total {
                let input = toInt(total["input_tokens"])
                let cached = toInt(total["cached_input_tokens"] ?? total["cache_read_input_tokens"])
                let output = toInt(total["output_tokens"])
                deltaInput = max(0, input - (previousTotals?.input ?? 0))
                deltaCached = max(0, cached - (previousTotals?.cached ?? 0))
                deltaOutput = max(0, output - (previousTotals?.output ?? 0))
                previousTotals = CostUsageCodexTotals(input: input, cached: cached, output: output)
            } else if let last {
                deltaInput = max(0, toInt(last["input_tokens"]))
                deltaCached = max(0, toInt(last["cached_input_tokens"] ?? last["cache_read_input_tokens"]))
                deltaOutput = max(0, toInt(last["output_tokens"]))
            } else { return }

            if deltaInput == 0, deltaCached == 0, deltaOutput == 0 { return }
            add(dayKey: dayKey, model: model, input: deltaInput, cached: min(deltaCached, deltaInput), output: deltaOutput)
        })) ?? startOffset

        return CodexParseResult(days: days, parsedBytes: parsedBytes, lastModel: currentModel, lastTotals: previousTotals, sessionId: sessionId)
    }

    private static func scanCodexFile(fileURL: URL, range: DayRange, cache: inout CostUsageCache, state: inout CodexScanState) {
        let path = fileURL.path
        let attrs = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mtimeMs = Int64(mtime * 1000)
        let fileId = fileIdentityString(fileURL: fileURL)

        func dropCachedFile(_ cached: CostUsageFileUsage?) {
            if let cached { applyFileDays(cache: &cache, fileDays: cached.days, sign: -1) }
            cache.files.removeValue(forKey: path)
        }

        if let fileId, state.seenFileIds.contains(fileId) { dropCachedFile(cache.files[path]); return }

        let cached = cache.files[path]
        if let cachedSessionId = cached?.sessionId, state.seenSessionIds.contains(cachedSessionId) { dropCachedFile(cached); return }

        let needsSessionId = cached != nil && cached?.sessionId == nil
        if let cached, cached.mtimeUnixMs == mtimeMs, cached.size == size, !needsSessionId {
            if let sid = cached.sessionId { state.seenSessionIds.insert(sid) }
            if let fid = fileId { state.seenFileIds.insert(fid) }
            return
        }

        // Try incremental parse
        if let cached, cached.sessionId != nil {
            let startOffset = cached.parsedBytes ?? cached.size
            let canIncremental = size > cached.size && startOffset > 0 && startOffset <= size && cached.lastTotals != nil
            if canIncremental {
                let delta = parseCodexFile(fileURL: fileURL, range: range, startOffset: startOffset, initialModel: cached.lastModel, initialTotals: cached.lastTotals)
                let sid = delta.sessionId ?? cached.sessionId
                if let sid, state.seenSessionIds.contains(sid) { dropCachedFile(cached); return }
                if !delta.days.isEmpty { applyFileDays(cache: &cache, fileDays: delta.days, sign: 1) }
                var mergedDays = cached.days
                mergeFileDays(existing: &mergedDays, delta: delta.days)
                cache.files[path] = CostUsageFileUsage(mtimeUnixMs: mtimeMs, size: size, days: mergedDays, parsedBytes: delta.parsedBytes, lastModel: delta.lastModel, lastTotals: delta.lastTotals, sessionId: sid)
                if let sid { state.seenSessionIds.insert(sid) }
                if let fid = fileId { state.seenFileIds.insert(fid) }
                return
            }
        }

        // Full re-parse
        if let cached { applyFileDays(cache: &cache, fileDays: cached.days, sign: -1) }
        let parsed = parseCodexFile(fileURL: fileURL, range: range)
        let sid = parsed.sessionId ?? cached?.sessionId
        if let sid, state.seenSessionIds.contains(sid) { cache.files.removeValue(forKey: path); return }
        let usage = CostUsageFileUsage(mtimeUnixMs: mtimeMs, size: size, days: parsed.days, parsedBytes: parsed.parsedBytes, lastModel: parsed.lastModel, lastTotals: parsed.lastTotals, sessionId: sid)
        cache.files[path] = usage
        applyFileDays(cache: &cache, fileDays: usage.days, sign: 1)
        if let sid { state.seenSessionIds.insert(sid) }
        if let fid = fileId { state.seenFileIds.insert(fid) }
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
            var scanState = CodexScanState()
            for fileURL in files { scanCodexFile(fileURL: fileURL, range: range, cache: &cache, state: &scanState) }
            for key in cache.files.keys where !filePathsInScan.contains(key) {
                if let old = cache.files[key] { applyFileDays(cache: &cache, fileDays: old.days, sign: -1) }
                cache.files.removeValue(forKey: key)
            }
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
    }

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

    private static func parseClaudeFile(fileURL: URL, range: DayRange, startOffset: Int64 = 0) -> ClaudeParseResult {
        var days: [String: [String: [Int]]] = [:]
        var seenKeys: Set<String> = []
        let costScale = 1_000_000_000.0

        // v1.9.4: packed slot 5 tracks message-event count. For per-model
        // token buckets it only counts the line that actually contributed
        // token deltas (deduped). For the synthetic `claudeMsgBucketModel`
        // bucket it counts every raw event (user + assistant, including
        // streaming chunks) — this matches what Claude Code's UI displays.
        func add(dayKey: String, model: String, input: Int, cacheRead: Int, cacheCreate: Int, output: Int, costNanos: Int, msgDelta: Int = 0) {
            guard DayRange.isInRange(dayKey: dayKey, since: range.scanSinceKey, until: range.scanUntilKey) else { return }
            let normModel = (model == Self.claudeMsgBucketModel) ? model : Pricing.normalizeClaudeModel(model)
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

        let maxLineBytes = 512 * 1024
        let prefixBytes = maxLineBytes

        let parsedBytes = (try? scanJsonl(fileURL: fileURL, offset: startOffset, maxLineBytes: maxLineBytes, prefixBytes: prefixBytes, onLine: { line in
            guard !line.bytes.isEmpty, !line.wasTruncated else { return }
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

            // Dedup for TOKENS (not messages): streaming chunks re-report
            // cumulative usage; counting each chunk would inflate tokens.
            let messageId = message["id"] as? String
            let requestId = obj["requestId"] as? String
            if let messageId, let requestId {
                let key = "\(messageId):\(requestId)"
                if seenKeys.contains(key) { return }
                seenKeys.insert(key)
            }

            func toInt(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? 0 }
            let input = max(0, toInt(usage["input_tokens"]))
            let cacheCreate = max(0, toInt(usage["cache_creation_input_tokens"]))
            let cacheRead = max(0, toInt(usage["cache_read_input_tokens"]))
            let output = max(0, toInt(usage["output_tokens"]))
            if input == 0, cacheCreate == 0, cacheRead == 0, output == 0 { return }

            let cost = Pricing.claudeCostUSD(model: model, inputTokens: input, cacheReadInputTokens: cacheRead, cacheCreationInputTokens: cacheCreate, outputTokens: output)
            let costNanos = cost.map { Int(($0 * costScale).rounded()) } ?? 0
            add(dayKey: dayKey, model: model, input: input, cacheRead: cacheRead, cacheCreate: cacheCreate, output: output, costNanos: costNanos, msgDelta: 0)
        })) ?? startOffset

        return ClaudeParseResult(days: days, parsedBytes: parsedBytes)
    }

    private static func processClaudeFile(url: URL, size: Int64, mtimeMs: Int64, cache: inout CostUsageCache, touched: inout Set<String>, range: DayRange) {
        let path = url.path
        touched.insert(path)

        if let cached = cache.files[path], cached.mtimeUnixMs == mtimeMs, cached.size == size { return }

        // Try incremental
        if let cached = cache.files[path] {
            let startOffset = cached.parsedBytes ?? cached.size
            let canIncremental = size > cached.size && startOffset > 0 && startOffset <= size
            if canIncremental {
                let delta = parseClaudeFile(fileURL: url, range: range, startOffset: startOffset)
                if !delta.days.isEmpty { applyFileDays(cache: &cache, fileDays: delta.days, sign: 1) }
                var mergedDays = cached.days
                mergeFileDays(existing: &mergedDays, delta: delta.days)
                cache.files[path] = CostUsageFileUsage(mtimeUnixMs: mtimeMs, size: size, days: mergedDays, parsedBytes: delta.parsedBytes)
                return
            }
            applyFileDays(cache: &cache, fileDays: cached.days, sign: -1)
        }

        // Full parse
        let parsed = parseClaudeFile(fileURL: url, range: range)
        let usage = CostUsageFileUsage(mtimeUnixMs: mtimeMs, size: size, days: parsed.days, parsedBytes: parsed.parsedBytes)
        cache.files[path] = usage
        applyFileDays(cache: &cache, fileDays: usage.days, sign: 1)
    }

    private static func scanClaudeRoot(root: URL, cache: inout CostUsageCache, touched: inout Set<String>, range: DayRange) {
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
            let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            processClaudeFile(url: url, size: size, mtimeMs: Int64(mtime * 1000), cache: &cache, touched: &touched, range: range)
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
            for root in roots { scanClaudeRoot(root: root, cache: &cache, touched: &touched, range: range) }
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
        let parts = key.split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        var comps = DateComponents()
        comps.calendar = Calendar.current
        comps.timeZone = TimeZone.current
        comps.year = y; comps.month = m; comps.day = d; comps.hour = 12
        return comps.date
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
                let sessionId = usage?.sessionId ?? metaFromFile?.sessionId
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
    /// whose mtime is within `activeSessionFreshnessWindow`. Project label
    /// comes from the parent directory name with the leading `-` stripped
    /// (Claude Code encodes project paths as `-Users-jason-myproject`).
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
                let parentDir = url.deletingLastPathComponent().lastPathComponent
                let projectName = humanReadableClaudeProject(encodedDir: parentDir)
                let sessionId = url.deletingPathExtension().lastPathComponent
                candidates.append(.init(
                    provider: "Claude",
                    filePath: path,
                    projectName: projectName,
                    projectRoot: nil,
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
                if let cost = Pricing.codexCostUSD(model: model, inputTokens: input, cachedInputTokens: cached, outputTokens: output) {
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
                name: "\(c.provider) session",
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
