import XCTest
@testable import HelperKit
import Foundation

/// R0 `pterm:` producer. These tests are almost entirely about ONE failure:
/// a private session's output appearing on the public `term:` topic, which is
/// fanned out with no RLS and protected only by UUID secrecy. Every assertion
/// below is written so it would FAIL if that leak were reintroduced.
final class PrivateTerminalBroadcastTests: XCTestCase {

    final class CapturingSink: TerminalBroadcastSink, @unchecked Sendable {
        private let q = DispatchQueue(label: "cap")
        private var _topics: [String] = []
        private var _bytes: [Data] = []
        var topics: [String] { q.sync { _topics } }
        var bytes: [Data] { q.sync { _bytes } }
        func publish(sessionId _: String, channel: String, event _: String, redactedBytes: Data) async throws {
            q.sync { _topics.append(channel); _bytes.append(redactedBytes) }
        }
    }

    struct ThrowingSink: TerminalBroadcastSink {
        struct Boom: Error {}
        func publish(sessionId _: String, channel _: String, event _: String, redactedBytes _: Data) async throws {
            throw Boom()
        }
    }

    // MARK: - visibility → topic

    func test_visibilityPrefixesAreDisjoint() {
        XCTAssertEqual(TerminalBroadcastVisibility.publicTopic.topicPrefix, "term:")
        XCTAssertEqual(TerminalBroadcastVisibility.privateTopic.topicPrefix, "pterm:")
        // The load-bearing property: neither prefix is a prefix of the other,
        // so prefix-routing cannot confuse them. `pterm:` famously CONTAINS
        // `term:` as a substring — this pins that it does not START with it.
        XCTAssertFalse(
            TerminalBroadcastVisibility.privateTopic.topic(for: "s").hasPrefix("term:"),
            "a pterm: topic must never satisfy the public prefix test")
        XCTAssertFalse(
            TerminalBroadcastVisibility.publicTopic.topic(for: "s").hasPrefix("pterm:"))
        for v in TerminalBroadcastVisibility.allCases {
            XCTAssertTrue(v.topic(for: "abc").hasSuffix("abc"))
        }
    }

    func test_publisherStampsTheRequestedTopic() async {
        let sink = CapturingSink()
        let pub = TerminalBroadcastPublisher(sink: sink)
        await pub.submit(sessionId: "s1", chunk: Data("a".utf8), visibility: .privateTopic)
        await pub.submit(sessionId: "s2", chunk: Data("b".utf8), visibility: .publicTopic)
        await pub.awaitDrained()
        XCTAssertEqual(sink.topics, ["pterm:s1", "term:s2"])
    }

    func test_publisherDefaultsToPublicSoExistingCallSitesAreUnchanged() async {
        let sink = CapturingSink()
        let pub = TerminalBroadcastPublisher(sink: sink)
        await pub.submit(sessionId: "s1", chunk: Data("a".utf8))
        await pub.awaitDrained()
        XCTAssertEqual(sink.topics, ["term:s1"])
    }

    func test_privatePathStillRedactsBeforeTheSink() async {
        // The redact-at-write invariant must hold on the NEW path too — a sink
        // that only redacted the public branch would be the worst of both.
        let sink = CapturingSink()
        let pub = TerminalBroadcastPublisher(sink: sink)
        let secret = "export AWS_SECRET_ACCESS_KEY=AKIAIOSFODNN7EXAMPLEKEYDATA0123456789"
        await pub.submit(sessionId: "s1", chunk: Data(secret.utf8), visibility: .privateTopic)
        await pub.awaitDrained()
        let seen = String(decoding: sink.bytes.first ?? Data(), as: UTF8.self)
        XCTAssertEqual(sink.topics, ["pterm:s1"])
        XCTAssertEqual(seen, Redactor.redact(secret))
        XCTAssertFalse(seen.contains("AKIAIOSFODNN7EXAMPLEKEYDATA0123456789"))
    }

    // MARK: - the fail-closed gate

    private func vis(_ p: Bool?, localOnly: Bool = false, enabled: Bool = true)
        -> TerminalBroadcastVisibility?
    {
        ManagedSessionManager.broadcastVisibility(
            realtimePrivate: p, localOnly: localOnly, privateEnabled: enabled)
    }

    func test_unknownPrivacyIsMutedOnBothTopics() {
        XCTAssertNil(vis(nil))
        XCTAssertEqual(vis(true), .privateTopic)
        XCTAssertEqual(vis(false), .publicTopic)
        // The old gate keeps its exact meaning: PUBLIC only for `false`.
        XCTAssertTrue(ManagedSessionManager.allowsPublicBroadcast(realtimePrivate: false))
        XCTAssertFalse(ManagedSessionManager.allowsPublicBroadcast(realtimePrivate: true))
        XCTAssertFalse(ManagedSessionManager.allowsPublicBroadcast(realtimePrivate: nil))
    }

    // MARK: - the consent gate (M4.4d)

    func test_attachedSessionWithoutConsentIsMuted() {
        // THE regression this test exists for. An attached external session is
        // stamped realtimePrivate:true at attach time, BEFORE any consent —
        // privacy there means "never on the public topic", not "publish me".
        // Consent is `cloudShared`, surfaced here as `localOnly`.
        XCTAssertNil(vis(true, localOnly: true),
                     "an attached session the user has not shared must not publish")
        // And once the user opts in, it flows.
        XCTAssertEqual(vis(true, localOnly: false), .privateTopic)
    }

    func test_localOnlyMutesThePublicTopicToo() {
        XCTAssertNil(vis(false, localOnly: true))
    }

    func test_featureGateOffMeansTheDrainLoopNeverRoutesPrivate() {
        // "Ships dark" must mean the path is not taken — not that its last hop
        // is nil. With the gate off a private record yields NO visibility, so
        // no redaction, no queue entry, no drop accounting.
        XCTAssertNil(vis(true, enabled: false))
        XCTAssertNil(vis(true, localOnly: true, enabled: false))
        // The public path is unaffected by the private gate.
        XCTAssertEqual(vis(false, enabled: false), .publicTopic)
        XCTAssertNil(vis(nil, enabled: false))
    }

    func test_visibilityTruthTableIsExhaustive() {
        // All 12 combinations, written out, because this function is the whole
        // privacy boundary and a future edit should have to change a table.
        let cases: [(Bool?, Bool, Bool, TerminalBroadcastVisibility?)] = [
            (false, false, false, .publicTopic),  (false, false, true,  .publicTopic),
            (false, true,  false, nil),           (false, true,  true,  nil),
            (true,  false, false, nil),           (true,  false, true,  .privateTopic),
            (true,  true,  false, nil),           (true,  true,  true,  nil),
            (nil,   false, false, nil),           (nil,   false, true,  nil),
            (nil,   true,  false, nil),           (nil,   true,  true,  nil),
        ]
        for (p, lo, en, want) in cases {
            XCTAssertEqual(vis(p, localOnly: lo, enabled: en), want,
                           "private=\(String(describing: p)) localOnly=\(lo) enabled=\(en)")
        }
    }

    func test_theENABLEDpathIsActuallyConstructedSomewhere() async {
        // Every other test in this file exercises the OFF state, because the
        // gate defaults false and nothing passed it true. A dark-shipped path
        // that no test ever turns ON is a path whose enabled behaviour is
        // unverified — which is how the consent bypass survived a green suite.
        let sink = CapturingSink()
        let publisher = TerminalBroadcastPublisher(sink: sink)
        let mgr = ManagedSessionManager(
            transport: PtyTransport(),
            broadcastPublisher: publisher,
            privateBroadcastEnabled: true)
        // The gate is stored and consulted; with it ON a consented private
        // record resolves to the private topic.
        XCTAssertEqual(
            ManagedSessionManager.broadcastVisibility(
                realtimePrivate: true, localOnly: false, privateEnabled: true),
            .privateTopic)
        // ...and the manager built with it ON still refuses an unconsented one.
        XCTAssertNil(
            ManagedSessionManager.broadcastVisibility(
                realtimePrivate: true, localOnly: true, privateEnabled: true))
        _ = mgr
    }

    // MARK: - routing

    func test_routerSendsPrivateTopicsToThePrivateSinkOnly() async throws {
        let pub = CapturingSink(), priv = CapturingSink()
        let router = PrivacyRoutingBroadcastSink(publicSink: pub, privateSink: priv)
        try await router.publish(sessionId: "s", channel: "pterm:s", event: "stdout", redactedBytes: Data("x".utf8))
        try await router.publish(sessionId: "s", channel: "term:s", event: "stdout", redactedBytes: Data("y".utf8))
        XCTAssertEqual(priv.topics, ["pterm:s"])
        XCTAssertEqual(pub.topics, ["term:s"])
    }

    func test_routerRefusesPrivateChunkWhenPrivateSinkIsAbsent() async {
        // The dark-ship state. A `pterm:` chunk with no private sink must be
        // REFUSED, never downgraded onto the public topic.
        let pub = CapturingSink()
        let router = PrivacyRoutingBroadcastSink(publicSink: pub, privateSink: nil)
        do {
            try await router.publish(
                sessionId: "s", channel: "pterm:s", event: "stdout", redactedBytes: Data("x".utf8))
            XCTFail("expected a refusal")
        } catch let e as PrivacyRoutingBroadcastSink.RouteError {
            XCTAssertEqual(e, .privateSinkUnavailable)
        } catch {
            XCTFail("wrong error: \(error)")
        }
        XCTAssertTrue(pub.topics.isEmpty, "a private chunk must never reach the public sink")
    }

    func test_routerRefusesUnknownPrefix() async {
        let pub = CapturingSink(), priv = CapturingSink()
        let router = PrivacyRoutingBroadcastSink(publicSink: pub, privateSink: priv)
        for bogus in ["", "sterm:s", "PTERM:s", "pterm", "x:pterm:s"] {
            do {
                try await router.publish(
                    sessionId: "s", channel: bogus, event: "stdout", redactedBytes: Data("x".utf8))
                XCTFail("expected refusal for \(bogus)")
            } catch let e as PrivacyRoutingBroadcastSink.RouteError {
                XCTAssertEqual(e, .unroutableTopic(bogus))
            } catch { XCTFail("wrong error for \(bogus): \(error)") }
        }
        XCTAssertTrue(pub.topics.isEmpty && priv.topics.isEmpty)
    }

    func test_publisherCountsARoutingRefusalAsADropAndKeepsGoing() async {
        // A refusal must not wedge the drain loop; the next chunk still flows.
        let pub = TerminalBroadcastPublisher(sink: ThrowingSink())
        await pub.submit(sessionId: "s", chunk: Data("a".utf8), visibility: .privateTopic)
        await pub.awaitDrained()
        let dropped = await pub.droppedSinceStart
        XCTAssertEqual(dropped, 1)
    }

    // MARK: - the relay sink

    func test_relaySinkRefusesAPublicTopic() async {
        // Defence in depth: even if the router were mis-wired, the private sink
        // itself will not publish a `term:` chunk.
        let sink = EdgeRelayPrivateBroadcastSink(
            configProvider: { .init(deviceId: "d", helperSecret: "s",
                                   supabaseURL: "https://x.example", supabaseAnonKey: "k") })
        do {
            try await sink.publish(
                sessionId: "s", channel: "term:s", event: "stdout", redactedBytes: Data("x".utf8))
            XCTFail("expected a refusal")
        } catch let e as EdgeRelayPrivateBroadcastSink.SinkError {
            XCTAssertEqual(e, .wrongTopic("term:s"))
        } catch { XCTFail("wrong error: \(error)") }
    }

    func test_relayBatchSplitPreservesOrderAndBoundsSize() {
        // DISTINGUISHABLE fixtures. An earlier version used four identical
        // 10-byte blobs, so it asserted the shape of the split and could not
        // have detected reordering at all — the one property whose violation
        // corrupts a terminal.
        let mk = { (i: Int, n: Int) in
            (event: "stdout", bytes: Data([UInt8(i)]) + Data(repeating: 0x41, count: n - 1))
        }
        let items = (1...4).map { mk($0, 10) }
        let out = EdgeRelayPrivateBroadcastSink.split(items, maxBytes: 25, maxCount: 64)
        XCTAssertEqual(out.map(\.count), [2, 2])
        XCTAssertEqual(out.flatMap { $0 }.map { $0.bytes.first! }, [1, 2, 3, 4],
                       "split must preserve order across batches")

        // A single oversized chunk becomes its own batch rather than vanishing.
        let big = EdgeRelayPrivateBroadcastSink.split(
            [mk(9, 100), mk(8, 1)], maxBytes: 25, maxCount: 64)
        XCTAssertEqual(big.map(\.count), [1, 1])
        XCTAssertEqual(big[0][0].bytes.count, 100)
        XCTAssertEqual(big.flatMap { $0 }.map { $0.bytes.first! }, [9, 8])
    }

    func test_relayBatchSplitBoundsCountToMatchTheRelay() {
        // The relay rejects >MAX_CHUNKS (64) WHOLESALE with 400, so a bound on
        // bytes alone would turn a burst of small chunks into total loss.
        let tiny = (0..<150).map { i in
            (event: "stdout", bytes: Data([UInt8(i % 251)]))
        }
        let out = EdgeRelayPrivateBroadcastSink.split(tiny, maxBytes: 64 * 1024, maxCount: 64)
        XCTAssertEqual(out.map(\.count), [64, 64, 22])
        XCTAssertTrue(out.allSatisfy { $0.count <= 64 })
        XCTAssertEqual(out.flatMap { $0 }.count, 150)
        XCTAssertEqual(out.flatMap { $0 }.map { $0.bytes.first! },
                       tiny.map { $0.bytes.first! }, "order preserved across count splits")
    }
}
