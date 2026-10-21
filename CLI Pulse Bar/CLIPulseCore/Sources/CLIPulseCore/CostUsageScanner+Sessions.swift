#if os(macOS)
import Foundation

// v1.58 (P1-5): the scan's rows split by session (`SessionUsage.swift`).
//
// As for Projects, both caches already keep every log's own rows
// (`CostUsageFileUsage.days`), so a session's rows are the sum of its logs'
// rows, and no log is read again:
//   * Codex: the logs whose rows count (`CodexCopyResolver`), by the
//     conversation each names (`CostUsageFileUsage.sessionId`, P0-1a). A
//     subagent's rollout names its parent's, so it adds to its parent's row.
//   * Claude: by transcript, with what is written under it
//     (`CostUsageScanner.claudeSession`), in `claudeSplit` beside Projects.
//
// Only the reported days count (`DayRange.sinceKey...untilKey`): a log's own
// rows are not trimmed to them, and a Codex log's also hold the day before.

extension CostUsageScanner {

    /// A provider's rows by session, and what each session is.
    struct SessionSplit {
        var entries: [CostUsageScanResult.SessionEntry] = []
        var details: [CostUsageScanResult.SessionDetail] = []
    }

    /// Gathers what each session is from its logs, one log at a time.
    struct SessionAccumulator {
        private struct Session {
            var project: ProjectIdentity
            /// The tokens of the log `project` was taken from, and whether
            /// that log is the session's own (not a subagent's).
            var projectTokens: Int
            var projectFromOwnLog: Bool
            var lastModifiedUnixMs: Int64
            var subagentLastDays: [String]
        }

        private var sessions: [String: Session] = [:]

        /// One log of the session `key` with usage in the reported days.
        ///
        /// The session's project is its own log's (the heaviest, when a
        /// conversation was continued in a second file), else its heaviest
        /// subagent's: a subagent can run in another folder, and the
        /// session ran where its own log says. A tie keeps the log added
        /// first, so callers add logs in a fixed order.
        mutating func add(
            key: String, project: ProjectIdentity, tokens: Int, isSubagent: Bool,
            modifiedUnixMs: Int64, latestDay: String)
        {
            var session = sessions[key] ?? Session(
                project: project, projectTokens: tokens, projectFromOwnLog: !isSubagent,
                lastModifiedUnixMs: modifiedUnixMs, subagentLastDays: [])
            let replaces = (!isSubagent && !session.projectFromOwnLog)
                || ((!isSubagent) == session.projectFromOwnLog && tokens > session.projectTokens)
            if replaces {
                session.project = project
                session.projectTokens = tokens
                session.projectFromOwnLog = !isSubagent
            }
            session.lastModifiedUnixMs = max(session.lastModifiedUnixMs, modifiedUnixMs)
            if isSubagent { session.subagentLastDays.append(latestDay) }
            sessions[key] = session
        }

        func details(provider: String) -> [CostUsageScanResult.SessionDetail] {
            sessions.keys.sorted().compactMap { key in
                guard let session = sessions[key] else { return nil }
                return CostUsageScanResult.SessionDetail(
                    provider: provider, key: key, project: session.project,
                    lastActivity: Date(timeIntervalSince1970: Double(session.lastModifiedUnixMs) / 1000),
                    subagentLastDays: session.subagentLastDays.sorted())
            }
        }
    }

    /// The conversation a Codex log belongs to: the `session_id` its
    /// session_meta names (a subagent's names its parent's), else its own
    /// thread id, else the log alone.
    static func codexSessionKey(_ usage: CostUsageFileUsage, path: String) -> String {
        if let id = usage.sessionId, !id.isEmpty { return "codex:" + id }
        if let id = usage.codex?.rolloutId, !id.isEmpty { return "codex:" + id }
        return "codex-file:" + path
    }

    /// The Codex rows of the reported days, by session.
    ///
    /// - Parameter identities: the project each log counts for
    ///   (`codexProjects`), so a session names the project Projects counts
    ///   its usage in.
    static func codexSessions(
        cache: CostUsageCache, range: DayRange, identities: [String: ProjectIdentity]
    ) -> SessionSplit {
        var rows: [String: [String: [String: [Int]]]] = [:]
        var sessions = SessionAccumulator()
        for path in codexCountedPaths(cache).sorted() {
            guard let usage = cache.files[path] else { continue }
            let key = codexSessionKey(usage, path: path)
            var tokens = 0
            var latestDay: String?
            for (day, models) in usage.days
            where DayRange.isInRange(dayKey: day, since: range.sinceKey, until: range.untilKey) {
                for (model, packed) in models {
                    let input = packed[safeIdx: 0] ?? 0
                    let cached = packed[safeIdx: 1] ?? 0
                    let output = packed[safeIdx: 2] ?? 0
                    // The same rows `entriesFromCodexCache` keeps.
                    guard input > 0 || cached > 0 || output > 0 else { continue }
                    rows[key, default: [:]][day, default: [:]][model] = addPacked(
                        a: rows[key]?[day]?[model] ?? [], b: packed, sign: 1)
                    tokens = SessionUsageRanking.plusSaturating(
                        tokens, SessionUsageRanking.plusSaturating(max(0, input), max(0, output)))
                    if day > (latestDay ?? "") { latestDay = day }
                }
            }
            guard let latestDay else { continue }
            sessions.add(
                key: key, project: identities[path] ?? .unknown, tokens: tokens,
                isSubagent: usage.codex?.isSubagent == true, modifiedUnixMs: usage.mtimeUnixMs,
                latestDay: latestDay)
        }

        var split = SessionSplit()
        for (key, days) in rows {
            for (day, models) in days {
                for (model, packed) in models {
                    // Priced as `entriesFromCodexCache` prices the day's row:
                    // each request at its own time (slot 3), so the sessions
                    // of a row add up to the row to the nanodollar.
                    split.entries.append(.init(
                        provider: "Codex", session: key, date: day, model: model,
                        inputTokens: packed[safeIdx: 0] ?? 0,
                        cachedTokens: packed[safeIdx: 1] ?? 0,
                        outputTokens: packed[safeIdx: 2] ?? 0,
                        costUSD: codexCost(model: model, packed: packed),
                        priceIsApproximate: Pricing.codexPriceResolution(model)?.isApproximate ?? false))
                }
            }
        }
        split.details = sessions.details(provider: "Codex")
        return split
    }
}
#endif
