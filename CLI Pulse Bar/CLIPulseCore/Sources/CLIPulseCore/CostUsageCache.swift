#if os(macOS)
import Foundation

// MARK: - Cache Types

/// Cache-rules version for the Claude cache (and for any provider without its
/// own version below). Bump it when a change to `CostUsageScanner` would make
/// numbers already stored in `claude-v2.json` wrong: a Claude pricing row
/// added, removed or repriced, or a change to how Claude lines are counted.
///
/// Why: per-event cost is computed inside `parseClaudeFile` and stored as
/// `costNanos` in the per-day-model bucket. The `entriesFromClaudeCache`
/// reconstruction has a fallback that re-runs `Pricing.claudeCostUSD` when the
/// bucket's summed `costNanos` is exactly zero — but that fallback gives the
/// WRONG answer once even one new event lands in a previously-zero bucket: the
/// bucket then has partial cost, the fallback is skipped, and only the new
/// events' contribution is reported.
///
/// A bump invalidates that provider's saved cache on the next `load()`
/// (returns an empty cache), forcing the next scan to re-parse every JSONL file
/// of THAT provider with the current rules. The versions are per provider
/// because the costs are: the Claude logs on a busy machine are thousands of
/// files and gigabytes, the Codex logs a hundred-odd files, and a Codex change
/// has no reason to make anyone re-read their Claude history.
///
/// History (one shared number until 1.56, so entries 1–4 apply to both caches):
///   1 — initial schema (no version field on disk; default Int = 0
///       on legacy files made them count as "stale" against this
///       constant, which is the desired behaviour).
///   2 — May 2026: `claude-opus-4-7` priced + family-fallback added
///       (PR fix-claude-usage-cost-accuracy). Caches written with
///       pricingVersion=0 had `costNanos=0` for every Opus 4.7
///       event; bump invalidates them so a normal refresh — not a
///       manual Force Rescan — produces correct Today/Week cost.
///   3 — Jul 2026: `claude-opus-4-8` priced with a dedicated entry.
///       Before this, the family fallback relabeled every opus-4-8
///       event `opus-4-7`, so the By-Model breakdown mis-attributed
///       ~all current Claude Code traffic. The stored per-file model
///       key is the normalized name, so a bump is required to re-parse
///       existing logs under the correct `opus-4-8` label.
///   4 — Aug 2026: the Claude 5 generation priced, and the pricing key
///       split away from the display name. Every cache written before
///       this holds `costNanos=0` for every `claude-opus-5`,
///       `claude-fable-5`, `claude-sonnet-5`, `gpt-5.6-sol` and
///       `gpt-5.6-terra` event — 15.47 billion tokens at zero on the
///       machine this was found on, every day since 2026-07-30. Same
///       failure as bump 2, one generation later: the family fallback
///       required a four-component `claude-opus-4-8` shape and the
///       generation bump dropped the fourth component. Without this
///       bump the fix would only apply to logs written from here on,
///       and every historical day would keep reading $0.
///   5 — not used for Claude. It is the Codex cache's first version of its
///       own (`costUsageCodexCacheRulesVersion`); skipping it keeps every
///       number naming one set of rules.
///   6 — 1.56: Claude responses are counted once, from their last line (it
///       was the first line, which undercounts output: a response's output
///       count grows line by line), including lines read by a later scan and
///       lines a log repeats further down; a response without a `requestId`
///       is identified by its session and message id; a proxy's preliminary
///       estimate is not billed. See `CostUsageAccountingRules` and
///       `CostUsageClaudeLogState`. A cache written under 4 holds responses
///       counted from their first line, some of them more than once.
let costUsageCachePricingVersion: Int = 6

/// Cache-rules version for the Codex cache (`codex-v2.json`). Bump it when
/// `CodexPricingTable` changes (a row added, removed or repriced, a dated rate,
/// an alias), when `normalizeCodexModel` or `codexPriceResolution` changes what
/// a model is stored under or which row it is billed at, or when the rules that
/// decide which Codex tokens count change. Only the Codex logs are re-read.
///
/// Each Codex request is priced when it is read and its cost stored in slot 3
/// of the day × model row, so cached days keep the price they were read at
/// until this is bumped. `CodexTokenAccountingTests.
/// test_codex_rate_changes_come_with_a_rules_version_bump` pins a fingerprint
/// of the table and of how a fixed list of names resolves next to this number,
/// so a pricing change without the bump fails the build.
///
/// History (1–4: see `costUsageCachePricingVersion`):
///   5 — 1.56: Codex accounting rules. Every rollout file counts on its own
///       (a subagent's file is no longer dropped for sharing its parent's
///       `session_id`); files that share a `payload.id` are copies only when
///       one's events lie within the other's time span; the cumulative
///       counter's baseline only rises; a subagent or fork does not count
///       history copied from its parent (lines before its
///       `subagent_history_start_ordinal` once an ancestor's session_meta is
///       copied in ahead of them, or, in a migrated rollout with no such
///       session_meta, the parent's replayed tail before the first
///       inter-agent message), and no file counts a counter carried over from
///       before its first event; and each request is priced when it is read,
///       at the `CodexPricingTable` rate in force at its own time, into slot 3
///       of the day × model row. A cache written under 4 holds token-only rows
///       counted by the old rules. (Changed before 1.56 shipped, so still 5.)
let costUsageCodexCacheRulesVersion: Int = 5

enum CostUsageCacheRules {
    /// The rules version a cache for `provider` must carry to be trusted.
    static func version(forProvider provider: String) -> Int {
        provider.lowercased() == "codex" ? costUsageCodexCacheRulesVersion : costUsageCachePricingVersion
    }
}

struct CostUsageCache: Codable {
    var version: Int = 1
    /// Rules version this cache was computed against. Loaded caches whose
    /// `pricingVersion` differs from `CostUsageCacheRules.version(forProvider:)`
    /// are treated as stale and returned as empty by `CostUsageCacheIO.load`.
    /// Default `0` so pre-version-bump on-disk files (no `pricingVersion` key)
    /// are invalidated as soon as we ship the first version > 0. The key keeps
    /// its old name so existing files still decode.
    var pricingVersion: Int = 0
    var lastScanUnixMs: Int64 = 0
    /// filePath -> file usage
    var files: [String: CostUsageFileUsage] = [:]
    /// dayKey -> model -> packed usage [input, cached, output, costNanos] for
    /// Codex, [input, cacheRead, cacheCreate, output, costNanos, messages] for
    /// Claude. For Codex this is rebuilt from `files` on every refresh, from the
    /// files that count (`CodexCopyResolver`).
    var days: [String: [String: [Int]]] = [:]
}

struct CostUsageFileUsage: Codable {
    var mtimeUnixMs: Int64
    var size: Int64
    var days: [String: [String: [Int]]]
    var parsedBytes: Int64?
    var lastModel: String?
    /// Codex: the cumulative counter's baseline — the highest total counted
    /// so far, which never goes down (`CodexTokenAccountant`).
    var lastTotals: CostUsageCodexTotals?
    /// Codex: `session_meta.payload.session_id`, the conversation this file
    /// belongs to. A subagent's file carries its parent's, so this is a
    /// display identity (which conversation), never a counting one.
    var sessionId: String?
    /// Codex only: what the counting rules need to resume this file and to
    /// decide whether it is a copy of another. nil in a cache written before
    /// the 1.56 rules, and for Claude; a Codex entry without it is re-parsed
    /// from the start.
    var codex: CostUsageCodexFileState? = nil
    /// Claude only: what an incremental read of this log needs to count each
    /// response once. Kept while the log is being written to; nil otherwise,
    /// and a Claude log without it is read again from the start when it grows.
    var claude: CostUsageClaudeLogState? = nil
}

/// What one Claude response adds to a log's totals, keyed by
/// `CostUsageAccountingRules.claudeResponseKey`.
struct CostUsageClaudeOpenRow: Codable, Equatable {
    var key: String
    var day: String
    /// The model as the log names it; `parseClaudeFile` normalizes it.
    var model: String
    /// [input, cacheRead, cacheCreate, output, costNanos]. All zero for a
    /// preliminary estimate, which is not billed.
    var packed: [Int]
    var incomplete: Bool

    /// A stable 64-bit hash of what the row adds, cost aside: the cost follows
    /// from the model and the tokens under the cache's rules version.
    var fingerprint: UInt64 {
        let p = packed
        let text = "\(day)\u{1F}\(model)\u{1F}\(p[safeIdx: 0] ?? 0),\(p[safeIdx: 1] ?? 0),\(p[safeIdx: 2] ?? 0),\(p[safeIdx: 3] ?? 0)\u{1F}\(incomplete ? 1 : 0)"
        return CostUsageClaudeLogState.stableHash(text)
    }
}

/// Per-log state of the Claude counting rules for a log still being written
/// to, so that an incremental read counts each response once, as a read of
/// the whole log would.
///
/// Two things can reach an incremental read for a response an earlier read
/// already counted: the rest of a response that was still streaming, and a
/// copy of an earlier line that Claude Code writes again further down the
/// same log (same message, request and usage, with its original timestamp).
struct CostUsageClaudeLogState: Codable, Equatable {
    /// The newest responses, latest first, with what each one added. A line of
    /// one of them read later replaces its contribution.
    var openRows: [CostUsageClaudeOpenRow] = []
    /// Every response counted in the log: 16 bytes each, a stable hash of its
    /// key followed by the `fingerprint` of the line that counts, both
    /// little-endian. A response found here that is no longer open is either
    /// the same line again, which adds nothing, or a different one, and then
    /// the log is read again from the start.
    var counted: Data = Data()

    /// FNV-1a, 64-bit, over UTF-8. Stable across launches, unlike `Hasher`.
    static func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    /// `counted` as key hash → fingerprint.
    func countedFingerprints() -> [UInt64: UInt64] {
        var map: [UInt64: UInt64] = [:]
        let bytes = [UInt8](counted)
        guard bytes.count % 16 == 0 else { return map }
        map.reserveCapacity(bytes.count / 16)
        func word(_ at: Int) -> UInt64 {
            var value: UInt64 = 0
            for i in 0..<8 { value |= UInt64(bytes[at + i]) << (8 * UInt64(i)) }
            return value
        }
        var offset = 0
        while offset < bytes.count {
            map[word(offset)] = word(offset + 8)
            offset += 16
        }
        return map
    }

    static func packCounted(_ map: [UInt64: UInt64]) -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(map.count * 16)
        for key in map.keys.sorted() {
            for word in [key, map[key] ?? 0] {
                for i in 0..<8 { bytes.append(UInt8(truncatingIfNeeded: word >> (8 * UInt64(i)))) }
            }
        }
        return Data(bytes)
    }
}

struct CostUsageCodexTotals: Codable, Equatable {
    var input: Int
    var cached: Int
    var output: Int
}

/// Per-file state of the Codex counting rules, persisted so an incremental
/// parse resumes with exactly the state a full parse would have reached.
struct CostUsageCodexFileState: Codable, Equatable {
    /// `session_meta.payload.id`: this rollout's own thread id. Two files that
    /// carry the same one are the same thread — a copy, or a later file that
    /// continues it — and `CodexCopyResolver` decides which.
    var rolloutId: String?
    /// session_meta names a parent (`parent_thread_id`, `forked_from_id`, or a
    /// `subagent` source): the file may begin with history copied from it.
    var isChild: Bool = false
    /// The first session_meta's time (`payload.timestamp`, else the line's),
    /// in Unix milliseconds. A child's events before it were copied in.
    var metaUnixMs: Int64?
    /// A child's `subagent_history_start_ordinal`: the number of the first
    /// line of its own history, as Codex wrote it. Whether the lines numbered
    /// before it were copied in is `copiedPrefix`.
    var historyStartOrdinal: Int?
    /// How the copied part of a child with a `historyStartOrdinal` was
    /// recognised; nil until it has been (`CodexTokenAccountant`).
    var copiedPrefix: CodexCopiedPrefix?
    /// The first line has been read for the file's identity (whether or not
    /// it held a readable session_meta). Later session_meta lines are the
    /// copied metadata of ancestors and never replace it.
    var sawMeta: Bool = false
    /// The file's first own event has been checked for an inherited baseline.
    var baselineChecked: Bool = false
    /// Token events this file counts as its own (after the copied-history rule),
    /// whether or not they added tokens.
    var eventCount: Int = 0
    var firstEventUnixMs: Int64?
    var lastEventUnixMs: Int64?
}

/// What marks the copied part of a child rollout that names a history
/// boundary (`subagent_history_start_ordinal`). Codex writes two shapes:
///
/// * A current child rollout copies its ancestor's history in *with* the
///   ancestor's session_meta, just after its own, and numbers its own history
///   from the boundary. The lines before the boundary are the ancestor's.
/// * Codex's migration of older subagent rollouts rewrites them without the
///   copied session_meta lines and moves the boundary to the end of the file,
///   so every line is numbered before it. The boundary marks nothing there:
///   the file holds the subagent's own work, which starts at the parent's
///   first inter-agent message to it. What comes before that message is the
///   parent's last requests, replayed.
enum CodexCopiedPrefix: String, Codable, Equatable {
    /// An ancestor's session_meta came before the boundary: the lines numbered
    /// before the boundary are copied history.
    case ancestorMetadata
    /// No copied session_meta; an inter-agent message came before the
    /// boundary: the token events before it were the parent's replayed tail,
    /// and everything after it counts.
    case interAgentMessage
    /// Neither came before the held events had to be decided — at the end of
    /// a read, or at a line numbered past the boundary: they counted, and so
    /// does the rest.
    case noMarker
}

// MARK: - Cache IO

enum CostUsageCacheIO {
    private static func defaultCacheRoot() -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent("CLIPulse", isDirectory: true)
    }

    static func cacheFileURL(provider: String, cacheRoot: URL? = nil) -> URL {
        let root = cacheRoot ?? defaultCacheRoot()
        return root
            .appendingPathComponent("cost-usage", isDirectory: true)
            .appendingPathComponent("\(provider.lowercased())-v2.json", isDirectory: false)
    }

    static func load(provider: String, cacheRoot: URL? = nil) -> CostUsageCache {
        let url = cacheFileURL(provider: provider, cacheRoot: cacheRoot)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(CostUsageCache.self, from: data),
              decoded.version == 1,
              decoded.pricingVersion == CostUsageCacheRules.version(forProvider: provider),
              hasOnlyGregorianDayKeys(decoded) else {
            // Either schema-version drift OR pricing-rules drift —
            // both invalidate the cached cost numbers, both heal
            // automatically by returning an empty cache here so the
            // next scan re-parses every JSONL file with current rules.
            return CostUsageCache()
        }
        return decoded
    }

    /// A cache written while the scanner still followed the device calendar
    /// holds keys like `0008-09-17` (Japanese) or `2569-09-17` (Buddhist). The
    /// Gregorian scanner prunes those from `days`, but each file's entry keeps
    /// them along with its parsed offset, so the file is never re-read and its
    /// usage stays missing until it ages out of the window. Starting over costs
    /// one full re-parse, the same price a pricing bump pays; no version number
    /// is spent on it, and a cache that was already Gregorian is untouched.
    static func hasOnlyGregorianDayKeys(_ cache: CostUsageCache) -> Bool {
        guard cache.days.keys.allSatisfy(DayKey.isPlausible) else { return false }
        return cache.files.values.allSatisfy { file in
            file.days.keys.allSatisfy(DayKey.isPlausible)
        }
    }

    static func save(provider: String, cache: CostUsageCache, cacheRoot: URL? = nil) {
        let url = cacheFileURL(provider: provider, cacheRoot: cacheRoot)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Stamp the cache with the provider's current rules version on every
        // save. Otherwise a freshly-parsed cache could be saved with
        // pricingVersion=0 (the dataclass default) and look stale
        // immediately on the next load.
        var stamped = cache
        stamped.pricingVersion = CostUsageCacheRules.version(forProvider: provider)

        let tmp = dir.appendingPathComponent(".tmp-\(UUID().uuidString).json")
        guard let data = try? JSONEncoder().encode(stamped) else { return }
        do {
            try data.write(to: tmp, options: [.atomic])
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    /// v1.9.4: wipe all `cost-usage/*.json` caches. Called by the "Force
    /// Rescan" button after the user grants new bookmarks, because stale
    /// subtractions from prior sandbox-blocked runs (where `scanClaudeRoot`
    /// decided the root didn't exist and applied `sign: -1` to all file days)
    /// can leave the disk cache reporting less than what the JSONLs actually
    /// contain.
    static func wipeAll(cacheRoot: URL? = nil) {
        let root = (cacheRoot ?? defaultCacheRoot()).appendingPathComponent("cost-usage", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        try? FileManager.default.removeItem(at: root)
    }
}

#endif
