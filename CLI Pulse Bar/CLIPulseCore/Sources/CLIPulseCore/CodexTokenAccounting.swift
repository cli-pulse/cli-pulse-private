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
//   * Rule 4 of `CodexTokenAccountant` (a child's opening repeats and copied
//     snapshots) follows the replay checks on the first owned token in
//     upstream's explicit history boundary (`parseCodexFileCancellable` in
//     CostUsageScanner.swift: a total equal to the inherited one, or equal to
//     its own `last` and at or above it, is inherited) and in
//     `CodexSubagentRolloutShape.classify` (`copiedSnapshot`), taken at
//     upstream commit 3bbf6bc4 (2026-10-03). NOT verbatim: here the
//     inherited counter is tracked as the file is read, and the first own
//     request still takes rule 3's baseline.
//   * Rule 5 runs upstream's `CodexSubagentRolloutShape.classify`, ported in
//     CodexSubagentRolloutShape.swift with its own notice, over a subagent
//     rollout without a history ordinal read whole, as upstream does with its
//     buffered subagent lines. What is done with the answer differs where the
//     file names no owned suffix (see that file). NOT verbatim either: upstream
//     also takes `subagent_history_start_ordinal` from a later session_meta of
//     the same thread (a repeat of the file's own); here the ordinal comes
//     from the first line only, and a repeat can only name the fork parent. A
//     file whose first session_meta has no ordinal and a later repeat does is
//     read whole (rule 5) instead of at that boundary, and without a turn
//     marker it counts by the other rules.
//
// Ours, not upstream's: `CodexCopyResolver` (upstream deduplicates rows across
// files by session, turn and timestamp; this decides per file, by payload id
// and nested event spans) and the rest of the copied-history rules for child
// rollouts. Not ported: upstream's resolution of a fork's inherited counter
// from its parent's file (`CodexInheritedTotalsResolver`,
// `CostUsageScanner+ForkCoverage.swift`), which needs the parent's totals at
// the fork time; and its reading of a history boundary with no marker ahead
// of it, which differs from rule 2's on purpose.
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
/// 4. **A child's opening repeats what it inherited.** Until a child with a
///    history ordinal counts its first tokens, an event that repeats the
///    counter it started from — the last total of its copied events, or of an
///    opening event that reported no request of its own — adds nothing, and
///    neither does a copied snapshot: a total equal to its own request, at or
///    above that counter. The baseline moves up to the snapshot. A child's
///    counter continues from what it inherited, so its own first request
///    shows a total above its `last`; a total equal to its `last` and above
///    the inherited one is a copy of a parent's snapshot. From CodexBar.
/// 5. **A subagent without a history ordinal is read whole.** Some subagent
///    rollouts have no `subagent_history_start_ordinal` (CodexBar's "legacy"
///    shape). The Codex version alone does not decide it: on the machine this
///    was measured on, the one such rollout among 176 was written by Codex
///    0.153.4, which gave its other 57 an ordinal. The copied part then shows
///    only in the shape of the file. Such a file is read whole before any of
///    it counts, and CodexBar's `CodexSubagentRolloutShape.classify` finds
///    where the subagent's own history starts: at a turn_context immediately
///    followed by an inter-agent message that triggers a turn (its parent's
///    message to it), after the last ancestor session_meta copied in; or, in
///    a rollout that names the thread it was forked from, at its first such
///    turn once its first own event confirms it, or at an opening total with
///    no request of its own. Events before it are copied, snapshots right
///    after it are skipped, and counting starts from the counter it had
///    there. Without such a start the other rules apply.
///
/// Rules 2 to 5 are a subset of what upstream does for forks and
/// subagents. Not done: reading a fork's inherited counter from its parent's
/// file. A conversation forked from another whose first event repeats the
/// parent's last snapshot, or a copy of history with no turn marker, counts
/// that snapshot's own request once more.
///
/// Before 1.56 none of rules 2 to 5 were needed, because every subagent file
/// was dropped for sharing its parent's `session_id` — which dropped all of
/// the subagents' own usage. Counting those files without them would count
/// copied history instead; and with files of one thread now all counted
/// unless one's events lie within another's, rule 3 is also what stops a
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
        /// The line's position in the file, counting the first line as 0
        /// (only a rollout read whole needs it).
        var line: Int = 0

        var unixMs: Int64 { CostUsageScanner.unixMillis(instant) }
    }

    typealias Counted = (event: Event, delta: CostUsageCodexTotals)

    private(set) var watermark: CostUsageCodexTotals?
    private(set) var state: CostUsageCodexFileState
    /// Events held until the copied part of the file is known (rule 2). Never
    /// persisted: every read ends with `finish()`.
    private(set) var pending: [Event] = []
    /// A subagent rollout without a history ordinal (rule 5): every line the
    /// classification needs and every token event, until `finish()`.
    private(set) var observations: [CodexSubagentRolloutShape.Observation] = []
    private(set) var heldWholeFile: [Event] = []
    private var classified = false

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
        historyStartOrdinal: Int? = nil,
        isSubagent: Bool = false,
        namesForkParent: Bool = false
    ) {
        guard !state.sawMeta else { return }
        state.sawMeta = true
        state.rolloutId = rolloutId
        state.isChild = isChild
        state.metaUnixMs = metaUnixMs
        state.historyStartOrdinal = historyStartOrdinal
        state.isSubagent = isSubagent ? true : nil
        state.namesForkParent = namesForkParent ? true : nil
        if classifiesWholeFile {
            observations.append(.init(lineIndex: 0, kind: .sessionMetadata(id: rolloutId)))
        }
    }

    /// A subagent rollout without a history ordinal: where its own history
    /// starts is decided from the whole file (rule 5), so every read of it
    /// starts at the first line and nothing counts before `finish()`.
    var classifiesWholeFile: Bool { state.classifiesWholeFile }

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
        dropPending()
    }

    /// The held events were copied: they are not counted, and the last total
    /// among them is the counter the child starts from (rule 4).
    private mutating func dropPending() {
        if let total = pending.last(where: { $0.total != nil })?.total {
            state.inheritedReference = total
        }
        pending.removeAll()
    }

    /// Rule 5's view of a line of a rollout read whole: a later session_meta
    /// (`id` as the line names it; `namesForkParent` when it is the file's own,
    /// repeated, and names the thread it was forked from), a turn_context, or
    /// an inter-agent message and whether it triggers a turn.
    mutating func observeWholeFileLine(_ kind: CodexSubagentRolloutShape.Observation.Kind, line: Int, namesForkParent: Bool = false) {
        guard classifiesWholeFile, !classified else { return }
        observations.append(.init(lineIndex: line, kind: kind))
        if case let .sessionMetadata(id) = kind, namesForkParent,
           CodexSubagentRolloutShape.sameConcreteSessionID(id, state.rolloutId) {
            state.namesForkParent = true
        }
    }

    /// An `inter_agent_communication_metadata` line: a message from another
    /// agent. The first one before the boundary of a child with no copied
    /// session_meta ends the parent's replayed tail (rule 2); held events are
    /// dropped.
    mutating func observeInterAgentMessage(ordinal: Int?) {
        guard awaitsCopiedPrefixMarker, let start = state.historyStartOrdinal else { return }
        if let ordinal, ordinal >= start { return }
        state.copiedPrefix = .interAgentMessage
        dropPending()
    }

    /// The events a `token_count` event makes count now, in log order: none
    /// while it is held (rule 2), and the held ones first when it is the first
    /// past the boundary with no marker ahead of it.
    mutating func receive(_ event: Event) -> [Counted] {
        if classifiesWholeFile, !classified {
            observations.append(.init(lineIndex: event.line, kind: .tokenCount(total: event.total, last: event.last)))
            heldWholeFile.append(event)
            return []
        }
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
        if classifiesWholeFile, !classified { return finishWholeFile() }
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

    /// Rule 5, at the end of a read of a whole subagent rollout without a
    /// history ordinal. When `CodexSubagentRolloutShape` finds where the
    /// subagent's own history starts — a turn its parent's message triggers,
    /// after copied history or confirmed by its first own event, or an opening
    /// total with no request of its own — the events before it are copied, and
    /// counting starts from the counter it had there. Otherwise every held
    /// event goes through the other rules, in order, as it would have.
    private mutating func finishWholeFile() -> [Counted] {
        classified = true
        let held = heldWholeFile
        heldWholeFile = []
        let shape = CodexSubagentRolloutShape.classify(
            leafSessionID: state.rolloutId,
            observations: observations,
            hasExplicitParent: state.namesForkParent == true)
        observations = []
        var owned = shape.ownedSuffix
        if owned == nil, let candidate = shape.ownedSuffixCandidate, candidate.isLocallyConfirmed {
            owned = candidate.ownedSuffix
        }
        var counted: [Counted] = []
        guard let owned else {
            for event in held { counted += receive(event) }
            return counted
        }
        watermark = owned.rawTotalsBaseline
        state.baselineChecked = true
        for event in held {
            if event.line < owned.startLineIndex { continue }
            if let first = owned.firstTokenLineIndex, event.line < first { continue }
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
                if let total { state.inheritedReference = total }
                return nil
            }
            if let metaUnixMs = state.metaUnixMs, eventUnixMs < metaUnixMs {
                if let total { state.inheritedReference = total }
                return nil
            }
        }
        state.eventCount += 1
        state.firstEventUnixMs = min(state.firstEventUnixMs ?? eventUnixMs, eventUnixMs)
        state.lastEventUnixMs = max(state.lastEventUnixMs ?? eventUnixMs, eventUnixMs)

        guard let total else {
            // Only the request's own usage: nothing cumulative to inherit.
            state.baselineChecked = true
            guard let last, !last.isZero else { return openingCounted(nil) }
            return openingCounted(last)
        }

        // Rule 4: until a child with a history ordinal counts its first tokens,
        // a repeat of the counter it started from, or a copied snapshot (a
        // total equal to its own request, at or above that counter), adds
        // nothing.
        let opening = inOpening
        if opening, let reference = state.inheritedReference {
            if total == reference { return nil }
            if CodexSubagentRolloutShape.totalsContainUsage(reference), let last, total == last,
               total.isAtLeast(reference) {
                state.inheritedReference = total
                if state.baselineChecked {
                    watermark = watermark.map { $0.componentwiseMax(total) } ?? total
                }
                return nil
            }
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
                // counts its first total as before. A child that is known to
                // start from a copied counter (rule 4) inherits only that.
                inherited = (opening ? state.inheritedReference : nil) ?? total
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
            return openingCounted(delta.isZero ? nil : delta)
        }
        watermark = total
        return openingCounted(total.isZero ? nil : total)
    }

    /// A child with a history ordinal that has not counted any tokens yet
    /// (rule 4).
    private var inOpening: Bool {
        state.isChild && state.historyStartOrdinal != nil && state.openingSettled != true
    }

    /// Rule 4's bookkeeping after an event: the opening ends with the first
    /// tokens counted; until then the counter the child starts from is the
    /// baseline.
    private mutating func openingCounted(_ delta: CostUsageCodexTotals?) -> CostUsageCodexTotals? {
        guard inOpening else { return delta }
        if delta == nil {
            if let watermark { state.inheritedReference = watermark }
        } else {
            state.openingSettled = true
        }
        return delta
    }

    /// Whether a first `session_meta` payload names a parent: the file may
    /// start with that parent's history.
    static func sessionMetaNamesParent(_ payload: [String: Any]) -> Bool {
        if let parent = payload["parent_thread_id"] as? String, !parent.isEmpty { return true }
        if let fork = payload["forked_from_id"] as? String, !fork.isEmpty { return true }
        if let source = payload["source"] as? [String: Any], source["subagent"] != nil { return true }
        return sessionMetaIsSubagent(payload) || sessionMetaForkParent(payload) != nil
    }

    /// Whether a session_meta payload is a subagent's: `source` is
    /// "subagent", or an object with a `subagent` entry (CodexBar's
    /// `codexIsSubagentThread`).
    static func sessionMetaIsSubagent(_ payload: [String: Any]) -> Bool {
        if let source = payload["source"] as? String {
            return source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "subagent"
        }
        if let source = payload["source"] as? [String: Any] {
            return source["subagent"] is String || source["subagent"] is [String: Any]
        }
        return false
    }

    /// The thread a session_meta payload says it was forked from, in any of
    /// the spellings CodexBar reads (`codexForkParentId`).
    static func sessionMetaForkParent(_ payload: [String: Any]) -> String? {
        for key in ["forked_from_id", "forkedFromId", "parent_session_id", "parentSessionId"] {
            guard let value = payload[key] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
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

    func isAtLeast(_ other: CostUsageCodexTotals) -> Bool {
        input >= other.input && cached >= other.cached && output >= other.output
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
