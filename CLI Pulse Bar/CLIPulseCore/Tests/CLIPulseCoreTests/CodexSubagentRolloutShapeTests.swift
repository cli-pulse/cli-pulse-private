// Translated from steipete/CodexBar
// Tests/CodexBarTests/CodexSubagentRolloutShapeTests.swift (swift-testing),
// taken at upstream commit 3bbf6bc4 (2026-10-03)
// (https://github.com/steipete/CodexBar), to XCTest against the port in
// CodexSubagentRolloutShape.swift. One test per upstream test, same inputs and
// expectations; only the test framework and the totals type differ.
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
import XCTest
@testable import CLIPulseCore

final class CodexSubagentRolloutShapeTests: XCTestCase {
    private typealias Shape = CodexSubagentRolloutShape
    private typealias Totals = CostUsageCodexTotals

    private func totals(_ input: Int, _ cached: Int, _ output: Int) -> Totals {
        Totals(input: input, cached: cached, output: output)
    }

    func test_single_leaf_metadata_means_an_independent_counter() {
        let shape = Shape.classify(leafSessionID: "leaf", observedSessionIDs: ["leaf"])
        XCTAssertEqual(shape.counterSemantics, .independent)
    }

    func test_single_leaf_first_turn_marker_proposes_a_parent_confirmed_suffix() throws {
        let baseline = totals(1000, 900, 100)
        let shape = Shape.classify(
            leafSessionID: "leaf",
            observations: [
                .init(lineIndex: 0, kind: .sessionMetadata(id: "leaf")),
                .init(lineIndex: 1, kind: .tokenCount(total: baseline, last: baseline)),
                .init(lineIndex: 3, kind: .turnContext),
                .init(lineIndex: 4, kind: .interAgentCommunication(triggerTurn: true)),
            ],
            hasExplicitParent: true)

        let candidate = try XCTUnwrap(shape.ownedSuffixCandidate)
        XCTAssertEqual(shape.counterSemantics, .independent)
        XCTAssertNil(shape.ownedSuffix)
        XCTAssertEqual(candidate.ownedSuffix.startLineIndex, 3)
        XCTAssertEqual(candidate.parentTotalsAtBoundary.input, baseline.input)
        XCTAssertEqual(candidate.parentTotalsAtBoundary.cached, baseline.cached)
        XCTAssertEqual(candidate.parentTotalsAtBoundary.output, baseline.output)
    }

    func test_single_leaf_marker_without_an_explicit_parent_stays_independent() {
        let baseline = totals(1000, 900, 100)
        let shape = Shape.classify(
            leafSessionID: "leaf",
            observations: [
                .init(lineIndex: 0, kind: .sessionMetadata(id: "leaf")),
                .init(lineIndex: 1, kind: .tokenCount(total: baseline, last: baseline)),
                .init(lineIndex: 3, kind: .turnContext),
                .init(lineIndex: 4, kind: .interAgentCommunication(triggerTurn: true)),
            ])

        XCTAssertEqual(shape.counterSemantics, .independent)
        XCTAssertNil(shape.ownedSuffixCandidate)
    }

    func test_later_marker_after_an_earlier_turn_does_not_propose_a_suffix() {
        let baseline = totals(1000, 900, 100)
        let shape = Shape.classify(
            leafSessionID: "leaf",
            observations: [
                .init(lineIndex: 0, kind: .sessionMetadata(id: "leaf")),
                .init(lineIndex: 1, kind: .turnContext),
                .init(lineIndex: 2, kind: .tokenCount(total: baseline, last: baseline)),
                .init(lineIndex: 3, kind: .turnContext),
                .init(lineIndex: 4, kind: .interAgentCommunication(triggerTurn: true)),
            ],
            hasExplicitParent: true)

        XCTAssertEqual(shape.counterSemantics, .independent)
        XCTAssertNil(shape.ownedSuffixCandidate)
    }

    func test_zero_pre_turn_totals_do_not_propose_a_suffix() {
        let zero = totals(0, 0, 0)
        let shape = Shape.classify(
            leafSessionID: "leaf",
            observations: [
                .init(lineIndex: 0, kind: .sessionMetadata(id: "leaf")),
                .init(lineIndex: 1, kind: .tokenCount(total: zero, last: zero)),
                .init(lineIndex: 2, kind: .turnContext),
                .init(lineIndex: 3, kind: .interAgentCommunication(triggerTurn: true)),
            ],
            hasExplicitParent: true)

        XCTAssertNil(shape.ownedSuffixCandidate)
    }

    func test_nonadjacent_first_turn_trigger_does_not_propose_a_suffix() {
        let baseline = totals(1000, 900, 100)
        let shape = Shape.classify(
            leafSessionID: "leaf",
            observations: [
                .init(lineIndex: 0, kind: .sessionMetadata(id: "leaf")),
                .init(lineIndex: 1, kind: .tokenCount(total: baseline, last: baseline)),
                .init(lineIndex: 2, kind: .turnContext),
                .init(lineIndex: 4, kind: .interAgentCommunication(triggerTurn: true)),
            ],
            hasExplicitParent: true)

        XCTAssertNil(shape.ownedSuffixCandidate)
    }

    func test_embedded_ancestor_metadata_means_a_copied_prefix() {
        let shape = Shape.classify(leafSessionID: "leaf", observedSessionIDs: ["leaf", "parent"])
        XCTAssertEqual(shape.counterSemantics, .copiedPrefix)
        XCTAssertEqual(shape.inferredParentSessionID, "parent")
    }

    func test_multiple_ancestors_do_not_infer_an_ambiguous_parent() {
        let shape = Shape.classify(leafSessionID: "leaf", observedSessionIDs: ["leaf", "parent", "grandparent"])
        XCTAssertEqual(shape.counterSemantics, .copiedPrefix)
        XCTAssertNil(shape.inferredParentSessionID)
    }

    func test_repeated_leaf_metadata_does_not_invent_an_ancestor() {
        let shape = Shape.classify(leafSessionID: "leaf", observedSessionIDs: ["leaf", "leaf"])
        XCTAssertEqual(shape.counterSemantics, .independent)
    }

    func test_unknown_leaf_followed_by_a_concrete_metadata_id_is_copied() {
        let shape = Shape.classify(leafSessionID: nil, observedSessionIDs: [nil, "parent"])
        XCTAssertEqual(shape.counterSemantics, .copiedPrefix)
        XCTAssertEqual(shape.inferredParentSessionID, "parent")
    }

    func test_idless_metadata_after_a_known_leaf_is_conservatively_copied() {
        let shape = Shape.classify(leafSessionID: "leaf", observedSessionIDs: ["leaf", nil])
        XCTAssertEqual(shape.counterSemantics, .copiedPrefix)
        XCTAssertNil(shape.inferredParentSessionID)
    }

    func test_only_concrete_normalized_ids_identify_the_same_leaf() {
        XCTAssertTrue(Shape.sameConcreteSessionID(" leaf ", "leaf"))
        XCTAssertFalse(Shape.sameConcreteSessionID(nil, nil))
        XCTAssertFalse(Shape.sameConcreteSessionID("", ""))
    }

    func test_adjacent_trigger_after_the_final_ancestor_opens_an_owned_suffix() throws {
        let baseline = totals(1000, 900, 100)
        let shape = Shape.classify(
            leafSessionID: "leaf",
            observations: [
                .init(lineIndex: 0, kind: .sessionMetadata(id: "leaf")),
                .init(lineIndex: 4, kind: .tokenCount(total: baseline, last: nil)),
                .init(lineIndex: 5, kind: .sessionMetadata(id: "parent")),
                .init(lineIndex: 8, kind: .turnContext),
                .init(lineIndex: 9, kind: .interAgentCommunication(triggerTurn: true)),
            ])

        let suffix = try XCTUnwrap(shape.ownedSuffix)
        XCTAssertEqual(shape.counterSemantics, .copiedPrefix)
        XCTAssertEqual(suffix.startLineIndex, 8)
        XCTAssertEqual(suffix.rawTotalsBaseline, totals(1000, 900, 100))
    }

    func test_nonadjacent_trigger_does_not_invent_an_owned_suffix() {
        let shape = Shape.classify(
            leafSessionID: "leaf",
            observations: [
                .init(lineIndex: 0, kind: .tokenCount(total: totals(1000, 900, 100), last: nil)),
                .init(lineIndex: 1, kind: .sessionMetadata(id: "parent")),
                .init(lineIndex: 3, kind: .turnContext),
                .init(lineIndex: 5, kind: .interAgentCommunication(triggerTurn: true)),
            ])

        XCTAssertEqual(shape.counterSemantics, .copiedPrefix)
        XCTAssertNil(shape.ownedSuffix)
    }

    func test_copied_prefix_can_restart_only_with_strong_reset_evidence() throws {
        let shape = Shape.classify(
            leafSessionID: "leaf",
            observations: [
                .init(lineIndex: 0, kind: .sessionMetadata(id: "leaf")),
                .init(lineIndex: 2, kind: .tokenCount(total: totals(1000, 900, 100), last: nil)),
                .init(lineIndex: 3, kind: .sessionMetadata(id: "parent")),
                .init(lineIndex: 5, kind: .turnContext),
                .init(lineIndex: 6, kind: .interAgentCommunication(triggerTurn: true)),
                .init(lineIndex: 7, kind: .tokenCount(total: totals(50, 10, 5), last: totals(50, 10, 5))),
            ])

        let suffix = try XCTUnwrap(shape.ownedSuffix)
        XCTAssertEqual(suffix.rawTotalsBaseline, totals(0, 0, 0))
    }

    func test_first_valid_leaf_marker_owns_later_leaf_turns() throws {
        let firstBaseline = totals(1000, 900, 100)
        let shape = Shape.classify(
            leafSessionID: "leaf",
            observations: [
                .init(lineIndex: 0, kind: .sessionMetadata(id: "leaf")),
                .init(lineIndex: 1, kind: .sessionMetadata(id: "parent")),
                .init(lineIndex: 2, kind: .tokenCount(total: firstBaseline, last: nil)),
                .init(lineIndex: 4, kind: .turnContext),
                .init(lineIndex: 5, kind: .interAgentCommunication(triggerTurn: true)),
                .init(lineIndex: 6, kind: .tokenCount(total: totals(1050, 910, 105), last: nil)),
                .init(lineIndex: 8, kind: .turnContext),
                .init(lineIndex: 9, kind: .interAgentCommunication(triggerTurn: true)),
            ])

        let suffix = try XCTUnwrap(shape.ownedSuffix)
        XCTAssertEqual(suffix.startLineIndex, 4)
        XCTAssertEqual(suffix.rawTotalsBaseline.input, firstBaseline.input)
    }

    func test_later_ancestor_invalidates_a_tentative_marker() throws {
        let shape = Shape.classify(
            leafSessionID: "leaf",
            observations: [
                .init(lineIndex: 0, kind: .sessionMetadata(id: "leaf")),
                .init(lineIndex: 1, kind: .sessionMetadata(id: "parent")),
                .init(lineIndex: 2, kind: .tokenCount(total: totals(1000, 900, 100), last: nil)),
                .init(lineIndex: 3, kind: .turnContext),
                .init(lineIndex: 4, kind: .interAgentCommunication(triggerTurn: true)),
                .init(lineIndex: 5, kind: .sessionMetadata(id: "grandparent")),
                .init(lineIndex: 6, kind: .tokenCount(total: totals(2000, 1800, 200), last: nil)),
                .init(lineIndex: 8, kind: .turnContext),
                .init(lineIndex: 9, kind: .interAgentCommunication(triggerTurn: true)),
            ])

        let suffix = try XCTUnwrap(shape.ownedSuffix)
        XCTAssertEqual(suffix.startLineIndex, 8)
        XCTAssertEqual(suffix.rawTotalsBaseline.input, 2000)
    }
}
#endif
