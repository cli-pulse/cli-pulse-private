// Partly derived from steipete/CodexBar, taken at upstream commit 25bba9b7
// (2026-09-28) (https://github.com/steipete/CodexBar):
//
//   * The cumulative-counter baseline in `CodexTokenAccountant` follows the
//     monotonic watermark of `CodexTotalsTracker` in
//     Sources/CodexBarCore/Vendored/CostUsage/CostUsageScanner.swift: the
//     baseline never goes down, a repeated total adds nothing, and a total
//     below the baseline is skipped instead of resetting it. NOT verbatim:
//     upstream latches an "interleaved lineage" mode after a drop and then
//     counts min(last, contained delta); this keeps only the three rules above
//     and skips the dropped event outright.
//   * Each counted event is priced with `CodexPricingTable` (the rate rows,
//     dated rates and the per-request long-context rule, ported from upstream's
//     CostUsagePricing.swift with its own notice in that file), at the rates in
//     force at the event's own time. Ours: `codexEventCostUSD`, which lets the
//     event's own request decide the tier and bills counted growth beyond that
//     request at base rates.
//
//   * The inter-agent-message boundary for migrated subagent rollouts (rule 2
//     of `CodexTokenAccountant`) is a simplified form of the owned-suffix
//     detection in `CodexSubagentRolloutShape.classify(...)` in
//     Sources/CodexBarCore/Vendored/CostUsage/CodexSubagentRolloutShape.swift,
//     where an inter-agent message that triggers a turn starts a subagent's
//     own history. NOT verbatim: here the first inter-agent message ends a
//     replayed prefix only in a child whose history boundary has no copied
//     session_meta ahead of it, without upstream's turn-context and totals
//     conditions.
//
// Ours, not upstream's: `CodexCopyResolver` (upstream deduplicates rows across
// files by session, turn and timestamp; this decides per file, by payload id
// and nested event spans) and the rest of the copied-history rules for child
// rollouts, which are a deliberately small subset of upstream's fork and
// subagent accounting (`CodexSubagentRolloutShape.swift`,
// `CostUsageScanner+ForkCoverage.swift`).
//
// ─── MIT License (full notice required by upstream) ───────────────
//
// MIT License
//
// Copyright (c) 2026 Peter Steinberger
//
// Permission is hereby granted, free of charge, to any person
// obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without
// restriction, including without limitation the rights to use, copy,
// modify, merge, publish, distribute, sublicense, and/or sell copies
// of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
// OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
// HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
// WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
// OTHER DEALINGS IN THE SOFTWARE.
// ──────────────────────────────────────────────────────────────────

#if os(macOS)
import Foundation

// MARK: - Counting one file

/// Which Codex tokens a rollout file counts, event by event.
///
/// A rollout's `token_count` events carry `total_token_usage`, a cumulative
/// counter for the thread, and `last_token_usage`, the request just made. The
/// counted amount is the growth of the cumulative counter over a baseline, so a
/// repeated event adds nothing. Three things can make that growth wrong, and
/// each has a rule:
///
/// 1. **The counter goes down.** The baseline only ever rises: an event whose
///    total is below it in any component is skipped and leaves it where it is.
///    Setting the baseline to the lower value — what the scanner did before —
///    counts the climb back up a second time. Growth above the baseline is
///    counted in full, even when it is more than the event's own request: the
///    counter also covers requests that wrote no token event of their own (an
///    aborted turn's). CodexBar counts the request there instead.
/// 2. **A child starts with its parent's history.** A subagent or fork rollout
///    can begin with the parent's history copied in, token events included.
///    Codex stamps the copied lines when it writes them, so their times say
///    nothing; what marks them depends on which of two shapes the file has
///    (`CodexCopiedPrefix`). A child's session_meta names the first line of
///    its own history (`subagent_history_start_ordinal`), and every line
///    carries its number (`ordinal`):
///    - when an ancestor's session_meta was copied in ahead of that boundary
///      (a current rollout), an event numbered before it is the parent's;
///    - when none was (Codex's migration of older subagent rollouts moves the
///      boundary to the end of the file and drops the copied session_meta
///      lines), the boundary marks nothing: the events before the parent's
///      first inter-agent message are its replayed last requests, and the
///      rest is the subagent's own. Until one of the two markers is seen, the
///      events numbered before the boundary are held (`receive`); if neither
///      comes before the end of the read or a line past the boundary, they
///      count (`finish`).
///    Copied events are not counted, nor do they move the baseline. An event
///    stamped earlier than the child's own session_meta is not its own either.
/// 3. **The counter continues from elsewhere.** When a file's first own event
///    reports a cumulative total larger than the request itself, the
///    difference was counted before this file began — by the parent a child
///    forked from, or by an earlier file of the same thread that this one
///    continues. It becomes the baseline and is not counted. A fresh counter's
///    first total equals its first request, so this changes nothing for it.
///    The difference is taken field by field and clamped at zero, so a total
///    below its own request in one field inherits nothing in that field.
///
/// Rules 2 and 3 are a minimal subset of what upstream does for forks and
/// subagents. Before 1.56 they were not needed, because every subagent file
/// was dropped for sharing its parent's `session_id` — which dropped all of
/// the subagents' own usage. Counting those files without these two rules
/// would count copied history instead; and with files of one thread now all
/// counted unless one's events lie within another's, rule 3 is also what stops a
/// continuation that carries its counter over from counting it twice.
struct CodexTokenAccountant {
    /// One `token_count` event, with what the caller needs to file it once it
    /// is counted: an event can be held (rule 2) and counted later in the read.
    struct Event {
        let instant: Date
        let ordinal: Int?
        /// `total_token_usage`
        let total: CostUsageCodexTotals?
        /// `last_token_usage`: the request this event reports.
        let last: CostUsageCodexTotals?
        /// The model in effect when the event was written.
        let model: String

        var unixMs: Int64 { CostUsageScanner.unixMillis(instant) }
    }

    typealias Counted = (event: Event, delta: CostUsageCodexTotals)

    private(set) var watermark: CostUsageCodexTotals?
    private(set) var state: CostUsageCodexFileState
    /// Events held until the copied part of the file is known (rule 2). Never
    /// persisted: every read ends with `finish()`.
    private(set) var pending: [Event] = []

    init(watermark: CostUsageCodexTotals? = nil, state: CostUsageCodexFileState = CostUsageCodexFileState()) {
        self.watermark = watermark
        self.state = state
    }

    /// Record the file's own `session_meta` — its first line. Codex writes
    /// the rollout's own there; any later session_meta is an ancestor's,
    /// copied in with its history, and never replaces it.
    mutating func observeSessionMeta(
        rolloutId: String?,
        isChild: Bool,
        metaUnixMs: Int64?,
        historyStartOrdinal: Int? = nil
    ) {
        guard !state.sawMeta else { return }
        state.sawMeta = true
        state.rolloutId = rolloutId
        state.isChild = isChild
        state.metaUnixMs = metaUnixMs
        state.historyStartOrdinal = historyStartOrdinal
    }

    /// The file's first line is not a readable session_meta (too long, or
    /// something else). The file's identity is unknown — and must stay
    /// unknown: taking a later session_meta would take a parent's copied
    /// metadata for the file's own, and match a child against its parent as
    /// if it were a copy.
    mutating func observeUnreadableFirstLine() {
        guard !state.sawMeta else { return }
        state.sawMeta = true
    }

    /// A child with a history boundary whose copied part is not known yet.
    var awaitsCopiedPrefixMarker: Bool {
        state.isChild && state.historyStartOrdinal != nil && state.copiedPrefix == nil
    }

    /// A session_meta line after the first: an ancestor's, copied in with its
    /// history. Numbered before the boundary, it shows that the lines before
    /// the boundary are copied (rule 2); held events are dropped.
    mutating func observeCopiedSessionMeta(ordinal: Int?) {
        guard awaitsCopiedPrefixMarker, let start = state.historyStartOrdinal else { return }
        if let ordinal, ordinal >= start { return }
        state.copiedPrefix = .ancestorMetadata
        pending.removeAll()
    }

    /// An `inter_agent_communication_metadata` line: a message from another
    /// agent. The first one before the boundary of a child with no copied
    /// session_meta ends the parent's replayed tail (rule 2); held events are
    /// dropped.
    mutating func observeInterAgentMessage(ordinal: Int?) {
        guard awaitsCopiedPrefixMarker, let start = state.historyStartOrdinal else { return }
        if let ordinal, ordinal >= start { return }
        state.copiedPrefix = .interAgentMessage
        pending.removeAll()
    }

    /// The events a `token_count` event makes count now, in log order: none
    /// while it is held (rule 2), and the held ones first when it is the first
    /// past the boundary with no marker ahead of it.
    mutating func receive(_ event: Event) -> [Counted] {
        var counted: [Counted] = []
        if awaitsCopiedPrefixMarker, let start = state.historyStartOrdinal, let ordinal = event.ordinal {
            if ordinal < start {
                pending.append(event)
                return []
            }
            counted = finish()
        }
        if let delta = count(eventUnixMs: event.unixMs, ordinal: event.ordinal, total: event.total, last: event.last) {
            counted.append((event: event, delta: delta))
        }
        return counted
    }

    /// No marker came for the held events: they are the file's own and count,
    /// in order. Called at the end of every read, so a read never leaves
    /// events held.
    mutating func finish() -> [Counted] {
        guard !pending.isEmpty else { return [] }
        state.copiedPrefix = .noMarker
        let held = pending
        pending = []
        var counted: [Counted] = []
        for event in held {
            if let delta = count(eventUnixMs: event.unixMs, ordinal: event.ordinal, total: event.total, last: event.last) {
                counted.append((event: event, delta: delta))
            }
        }
        return counted
    }

    /// The tokens one `token_count` event adds to this file's count, or nil
    /// when it adds none. `total` is the event's `total_token_usage`, `last`
    /// its `last_token_usage`; an event with neither is not an event.
    /// `ordinal` is the line's own number, when Codex wrote one. This judges
    /// the event now; `receive` decides whether it has to wait.
    mutating func count(
        eventUnixMs: Int64,
        ordinal: Int? = nil,
        total: CostUsageCodexTotals?,
        last: CostUsageCodexTotals?
    ) -> CostUsageCodexTotals? {
        guard total != nil || last != nil else { return nil }
        // Rule 2: history copied from the parent.
        if state.isChild {
            if state.copiedPrefix == .ancestorMetadata, let start = state.historyStartOrdinal,
               let ordinal, ordinal < start {
                return nil
            }
            if let metaUnixMs = state.metaUnixMs, eventUnixMs < metaUnixMs { return nil }
        }
        state.eventCount += 1
        state.firstEventUnixMs = min(state.firstEventUnixMs ?? eventUnixMs, eventUnixMs)
        state.lastEventUnixMs = max(state.lastEventUnixMs ?? eventUnixMs, eventUnixMs)

        guard let total else {
            // Only the request's own usage: nothing cumulative to inherit.
            state.baselineChecked = true
            guard let last, !last.isZero else { return nil }
            return last
        }

        // Rule 3: the file's first own event, continuing a counter from elsewhere.
        if !state.baselineChecked {
            state.baselineChecked = true
            let inherited: CostUsageCodexTotals?
            if let last {
                inherited = total.subtractingClamped(last)
            } else if state.isChild {
                // Without `last` nothing shows how much of a child's first
                // total is its own, so all of it is treated as the parent's:
                // at worst one request is missed, never a parent's history
                // counted. A root file without `last` (an older log format)
                // counts its first total as before.
                inherited = total
            } else {
                inherited = nil
            }
            if let inherited, !inherited.isZero {
                watermark = watermark.map { $0.componentwiseMax(inherited) } ?? inherited
            }
        }

        // Rule 1: the baseline only rises.
        if let baseline = watermark {
            if total.input < baseline.input || total.cached < baseline.cached || total.output < baseline.output {
                return nil
            }
            let delta = total.subtractingClamped(baseline)
            watermark = total
            return delta.isZero ? nil : delta
        }
        watermark = total
        return total.isZero ? nil : total
    }

    /// Whether a first `session_meta` payload names a parent: the file may
    /// start with that parent's history.
    static func sessionMetaNamesParent(_ payload: [String: Any]) -> Bool {
        if let parent = payload["parent_thread_id"] as? String, !parent.isEmpty { return true }
        if let fork = payload["forked_from_id"] as? String, !fork.isEmpty { return true }
        if let source = payload["source"] as? [String: Any], source["subagent"] != nil { return true }
        return false
    }
}

extension CostUsageCodexTotals {
    var isZero: Bool { input == 0 && cached == 0 && output == 0 }

    func subtractingClamped(_ other: CostUsageCodexTotals) -> CostUsageCodexTotals {
        CostUsageCodexTotals(
            input: max(0, input - other.input),
            cached: max(0, cached - other.cached),
            output: max(0, output - other.output)
        )
    }

    func componentwiseMax(_ other: CostUsageCodexTotals) -> CostUsageCodexTotals {
        CostUsageCodexTotals(
            input: max(input, other.input),
            cached: max(cached, other.cached),
            output: max(output, other.output)
        )
    }
}

// MARK: - Which files count

/// Which Codex rollout files count toward the totals.
///
/// Every file counts on its own, with one exception: two files that carry the
/// same `session_meta.payload.id` are the same thread, and when one file's
/// events lie within the time span of the other's, it is a copy (a copy is
/// the whole file or an earlier state of it, so its span is inside the
/// original's). Files are taken with the most events first (then the larger
/// final total, then the earlier path, so the choice never depends on
/// dictionary order), and a file whose span lies within one already taken is
/// not counted.
///
/// Files of one thread whose spans are not nested all count: each holds
/// events the other does not. Codex writes such shapes: a file with no token
/// events at all followed by a second file for the same thread, or a thread
/// continued in a later file. Keeping only the first file with a given id —
/// the obvious rule — keeps the empty one and drops the thread. The rule
/// before 1.56 was worse again: it matched on `session_id`, which a
/// subagent's file shares with its parent, so every subagent was dropped.
enum CodexCopyResolver {
    struct File: Equatable {
        let path: String
        let rolloutId: String?
        let eventCount: Int
        let firstEventUnixMs: Int64?
        let lastEventUnixMs: Int64?
        /// input + output of the file's final cumulative total.
        let finalTokens: Int
    }

    static func countedPaths(_ files: [File]) -> Set<String> {
        var counted: Set<String> = []
        var threads: [String: [File]] = [:]
        for file in files {
            guard let id = file.rolloutId, !id.isEmpty else {
                counted.insert(file.path)
                continue
            }
            threads[id, default: []].append(file)
        }
        for (_, group) in threads {
            let ordered = group.sorted { a, b in
                if a.eventCount != b.eventCount { return a.eventCount > b.eventCount }
                if a.finalTokens != b.finalTokens { return a.finalTokens > b.finalTokens }
                return a.path < b.path
            }
            var keptSpans: [(first: Int64, last: Int64)] = []
            for file in ordered {
                guard let first = file.firstEventUnixMs, let last = file.lastEventUnixMs else {
                    // No events: nothing to nest, nothing to double count.
                    counted.insert(file.path)
                    continue
                }
                if keptSpans.contains(where: { $0.first <= first && last <= $0.last }) { continue }
                keptSpans.append((first, last))
                counted.insert(file.path)
            }
        }
        return counted
    }
}

// MARK: - Pricing one request

extension CostUsageScanner.Pricing {
    /// What one `token_count` event's counted tokens cost at `rates` (the
    /// `CodexPricingTable` row in force at the event's time).
    ///
    /// `request` is the event's own `last_token_usage`, the request it
    /// reports, and it alone decides the long-context tier. When the counted
    /// growth is more than that request — the cumulative counter also covers
    /// requests that wrote no event of their own — the part beyond it is billed
    /// at base rates (`CodexPricingTable.aggregateCostUSD`): nothing shows how
    /// large those requests were, and pricing their sum as one request would
    /// put it over any threshold. Without `request`, the counted tokens are the
    /// request.
    static func codexEventCostUSD(
        rates: CodexPricingTable.Rates,
        counted: CostUsageCodexTotals,
        request: CostUsageCodexTotals?
    ) -> Double {
        guard let request else {
            return CodexPricingTable.requestCostUSD(
                rates: rates, inputTokens: counted.input,
                cachedInputTokens: counted.cached, outputTokens: counted.output
            )
        }
        let beyond = counted.subtractingClamped(request)
        let own = counted.subtractingClamped(beyond)
        return CodexPricingTable.requestCostUSD(
            rates: rates, inputTokens: own.input, cachedInputTokens: own.cached,
            outputTokens: own.output, tierInputTokens: request.input
        ) + CodexPricingTable.aggregateCostUSD(
            rates: rates, inputTokens: beyond.input, cachedInputTokens: beyond.cached,
            outputTokens: beyond.output
        )
    }
}

#endif
