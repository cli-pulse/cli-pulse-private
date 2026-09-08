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

    func test_unknownPrivacyIsMutedOnBothTopics() {
        // nil is the whole reason broadcastVisibility is three-valued.
        XCTAssertNil(ManagedSessionManager.broadcastVisibility(realtimePrivate: nil))
        XCTAssertEqual(ManagedSessionManager.broadcastVisibility(realtimePrivate: true), .privateTopic)
        XCTAssertEqual(ManagedSessionManager.broadcastVisibility(realtimePrivate: false), .publicTopic)
        // And the old gate keeps its exact meaning: PUBLIC only for `false`.
        XCTAssertTrue(ManagedSessionManager.allowsPublicBroadcast(realtimePrivate: false))
        XCTAssertFalse(ManagedSessionManager.allowsPublicBroadcast(realtimePrivate: true))
        XCTAssertFalse(ManagedSessionManager.allowsPublicBroadcast(realtimePrivate: nil))
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
        let mk = { (n: Int) in (event: "stdout", bytes: Data(repeating: 0x41, count: n)) }
        let items = [mk(10), mk(10), mk(10), mk(10)]
        let out = EdgeRelayPrivateBroadcastSink.split(items, maxBytes: 25)
        XCTAssertEqual(out.map(\.count), [2, 2])
        XCTAssertEqual(out.flatMap { $0 }.count, items.count)
        // A single oversized chunk becomes its own batch rather than vanishing.
        let big = EdgeRelayPrivateBroadcastSink.split([mk(100), mk(1)], maxBytes: 25)
        XCTAssertEqual(big.map(\.count), [1, 1])
        XCTAssertEqual(big[0][0].bytes.count, 100)
    }
}
