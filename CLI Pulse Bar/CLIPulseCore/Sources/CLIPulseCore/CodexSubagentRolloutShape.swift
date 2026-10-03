// Derived from steipete/CodexBar
// Sources/CodexBarCore/Vendored/CostUsage/CodexSubagentRolloutShape.swift,
// taken at upstream commit 3bbf6bc4 (2026-10-03)
// (https://github.com/steipete/CodexBar). The classification is upstream's,
// line for line; not verbatim in these respects:
//
//   * It is a top-level type here, not nested in `CostUsageScanner`, and its
//     totals are CLI Pulse's `CostUsageCodexTotals` (input, cached, output;
//     no reasoning), compared with `==` and `isAtLeast`.
//   * The scanner-side code that feeds it and acts on its answer is ours
//     (`CodexTokenAccountant.finishWholeFile`). Upstream acts on a copied
//     prefix without an owned suffix by resolving the parent's totals from
//     the parent's file, or counts nothing; CLI Pulse has no cross-file
//     resolution and counts such a file by its other rules instead, and it
//     classifies only subagent rollouts without a history ordinal
//     (`subagent_history_start_ordinal`), which upstream handles separately
//     too.
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

enum CodexSubagentCounterSemantics: Equatable {
    case independent
    case copiedPrefix
}

/// Where a subagent rollout's own history starts, decided from the whole file.
///
/// Subagent source is lineage evidence, not counter semantics. The first
/// session metadata owns leaf identity. Embedded ancestor metadata proves a
/// copied prefix by itself. Compact rollouts can establish inheritance from a
/// zero-usage opening snapshot or a first-turn boundary. The first owned event
/// supplies its component baseline; inherited snapshots need not exactly match
/// it. Independently restarted counters still count their opening usage.
struct CodexSubagentRolloutShape {
    let counterSemantics: CodexSubagentCounterSemantics
    let ownedSuffix: OwnedSuffix?
    let ownedSuffixCandidate: OwnedSuffixCandidate?
    let inferredParentSessionID: String?

    struct OwnedSuffix: Equatable {
        /// The line the subagent's own history starts at.
        let startLineIndex: Int
        /// The cumulative total it starts counting from.
        let rawTotalsBaseline: CostUsageCodexTotals
        /// Its first own token event; token events between the start and
        /// this one are copied snapshots.
        var firstTokenLineIndex: Int?
    }

    struct OwnedSuffixCandidate: Equatable {
        let ownedSuffix: OwnedSuffix
        let parentTotalsAtBoundary: CostUsageCodexTotals
        let isLocallyConfirmed: Bool
    }

    struct Observation: Equatable {
        let lineIndex: Int
        let kind: Kind

        enum Kind: Equatable {
            case sessionMetadata(id: String?)
            case turnContext
            case interAgentCommunication(triggerTurn: Bool)
            case tokenCount(total: CostUsageCodexTotals?, last: CostUsageCodexTotals?)
        }
    }

    static func classify(
        leafSessionID: String?,
        observedSessionIDs: [String?]
    ) -> Self {
        let normalizedLeafID = normalizedSessionID(leafSessionID)

        let ancestorIDs = observedSessionIDs.map(normalizedSessionID).filter { $0 != normalizedLeafID }
        let hasEmbeddedAncestor = !ancestorIDs.isEmpty || (normalizedLeafID == nil && observedSessionIDs.count > 1)
        let distinctAncestorIDs = Set(ancestorIDs.compactMap { $0 })

        return Self(
            counterSemantics: hasEmbeddedAncestor ? .copiedPrefix : .independent,
            ownedSuffix: nil,
            ownedSuffixCandidate: nil,
            inferredParentSessionID: distinctAncestorIDs.count == 1 ? distinctAncestorIDs.first : nil)
    }

    static func classify(
        leafSessionID: String?,
        observations: [Observation],
        hasExplicitParent: Bool = false
    ) -> Self {
        let metadataIDs = observations.reduce(into: [String?]()) { result, observation in
            guard case let .sessionMetadata(id) = observation.kind else { return }
            result.append(id)
        }
        let metadataShape = classify(leafSessionID: leafSessionID, observedSessionIDs: metadataIDs)
        let canProposeParentConfirmedSuffix = metadataShape.counterSemantics == .independent
            && hasExplicitParent
        guard metadataShape.counterSemantics == .copiedPrefix || canProposeParentConfirmedSuffix
        else { return metadataShape }

        let normalizedLeafID = normalizedSessionID(leafSessionID)
        var lastRawTotals: CostUsageCodexTotals?
        var pendingTurnContext: (lineIndex: Int, baseline: CostUsageCodexTotals)?
        var ownedSuffix: OwnedSuffix?
        var parentTotalsAtBoundary: CostUsageCodexTotals?
        var locallyConfirmedBoundary = false
        var inspectedOwnedSuffixFirstTotal = false
        var observedAuthoritativeMetadata = false
        var observedTurnContext = false
        var inheritedOpening = false

        for observation in observations {
            switch observation.kind {
            case let .sessionMetadata(id):
                let normalizedID = normalizedSessionID(id)
                let isEmbeddedAncestor: Bool
                if !observedAuthoritativeMetadata {
                    isEmbeddedAncestor = false
                } else if let normalizedLeafID {
                    isEmbeddedAncestor = normalizedID != normalizedLeafID
                } else {
                    isEmbeddedAncestor = true
                }
                observedAuthoritativeMetadata = true
                if isEmbeddedAncestor {
                    // A later ancestor meta proves that any earlier candidate boundary was replay.
                    ownedSuffix = nil
                    parentTotalsAtBoundary = nil
                    locallyConfirmedBoundary = false
                    inspectedOwnedSuffixFirstTotal = false
                }
                pendingTurnContext = nil

            case .turnContext:
                let isFirstTurnContext = !observedTurnContext
                observedTurnContext = true
                let acceptsBoundary = metadataShape.counterSemantics == .copiedPrefix
                    || (canProposeParentConfirmedSuffix && isFirstTurnContext)
                pendingTurnContext = acceptsBoundary
                    ? lastRawTotals.map { (observation.lineIndex, $0) }
                    : nil
                if inheritedOpening, isFirstTurnContext, let pendingTurnContext {
                    ownedSuffix = OwnedSuffix(
                        startLineIndex: pendingTurnContext.lineIndex,
                        rawTotalsBaseline: pendingTurnContext.baseline)
                    inspectedOwnedSuffixFirstTotal = false
                }

            case let .interAgentCommunication(triggerTurn):
                if ownedSuffix == nil,
                   triggerTurn,
                   let pendingTurnContext,
                   observation.lineIndex > pendingTurnContext.lineIndex, // NEGATIVE CONTROL C3: adjacency dropped
                   metadataShape.counterSemantics == .copiedPrefix
                   || totalsContainUsage(pendingTurnContext.baseline)
                {
                    ownedSuffix = OwnedSuffix(
                        startLineIndex: pendingTurnContext.lineIndex,
                        rawTotalsBaseline: pendingTurnContext.baseline)
                    parentTotalsAtBoundary = pendingTurnContext.baseline
                    locallyConfirmedBoundary = false
                    inspectedOwnedSuffixFirstTotal = false
                }
                pendingTurnContext = nil

            case let .tokenCount(total, last):
                if lastRawTotals == nil, canProposeParentConfirmedSuffix, !observedTurnContext,
                   let total, let last, totalsContainUsage(total), !totalsContainUsage(last)
                {
                    // A zero-component opening event carries inherited context, not child usage.
                    inheritedOpening = true
                    ownedSuffix = OwnedSuffix(startLineIndex: observation.lineIndex, rawTotalsBaseline: total)
                    parentTotalsAtBoundary = total
                    locallyConfirmedBoundary = true
                }
                if inheritedOpening, !observedTurnContext,
                   let total, let last, totalsContainUsage(last),
                   total != lastRawTotals
                {
                    inheritedOpening = false
                    ownedSuffix = OwnedSuffix(
                        startLineIndex: observation.lineIndex,
                        rawTotalsBaseline: lastRawTotals ?? total)
                    inspectedOwnedSuffixFirstTotal = false
                }
                if !inspectedOwnedSuffixFirstTotal,
                   let suffix = ownedSuffix,
                   let total,
                   total != suffix.rawTotalsBaseline
                {
                    inspectedOwnedSuffixFirstTotal = true
                    if let last {
                        let copiedSnapshot = totalsContainUsage(suffix.rawTotalsBaseline)
                            && total == last
                            && total.isAtLeast(suffix.rawTotalsBaseline)
                        ownedSuffix = OwnedSuffix(
                            startLineIndex: suffix.startLineIndex,
                            rawTotalsBaseline: copiedSnapshot ? total : total.subtractingClamped(last),
                            firstTokenLineIndex: observation.lineIndex)
                        inspectedOwnedSuffixFirstTotal = !copiedSnapshot
                        locallyConfirmedBoundary = true
                    }
                }
                if let total {
                    lastRawTotals = total
                }
                pendingTurnContext = nil
            }
        }

        if metadataShape.counterSemantics == .copiedPrefix {
            return Self(
                counterSemantics: .copiedPrefix,
                ownedSuffix: ownedSuffix,
                ownedSuffixCandidate: nil,
                inferredParentSessionID: metadataShape.inferredParentSessionID)
        }

        let candidate: OwnedSuffixCandidate?
        if let ownedSuffix, let parentTotalsAtBoundary {
            candidate = OwnedSuffixCandidate(
                ownedSuffix: ownedSuffix,
                parentTotalsAtBoundary: parentTotalsAtBoundary,
                isLocallyConfirmed: locallyConfirmedBoundary)
        } else {
            candidate = nil
        }
        return Self(
            counterSemantics: .independent,
            ownedSuffix: nil,
            ownedSuffixCandidate: candidate,
            inferredParentSessionID: metadataShape.inferredParentSessionID)
    }

    static func sameConcreteSessionID(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs = normalizedSessionID(lhs),
              let rhs = normalizedSessionID(rhs)
        else { return false }
        return lhs == rhs
    }

    static func totalsContainUsage(_ totals: CostUsageCodexTotals) -> Bool {
        totals.input > 0 || totals.cached > 0 || totals.output > 0
    }

    static func normalizedSessionID(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
#endif
