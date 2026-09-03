import XCTest
@testable import CLIPulseCore

/// Remote-control M0 — the phone↔agent envelope and framing.
final class LANLinkProtocolTests: XCTestCase {

    // MARK: - M0 allowlist is pinned, not implied

    func testM0ReadOnlySetIsExactlyTheSixReadVerbs() {
        // If someone adds a verb to `readOnly` without meaning to, this
        // is the line that goes red. The M1 verbs must NOT be here.
        XCTAssertEqual(
            LANLinkProtocol.Method.readOnly,
            [.hello, .ping, .sessionsList, .sessionTail, .sessionSubscribe, .sessionUnsubscribe]
        )
        for m in [LANLinkProtocol.Method.sessionInput, .sessionResize, .sessionStart,
                  .sessionStop, .approvalDecide] {
            XCTAssertFalse(m.isReadOnly, "\(m.rawValue) is an M1 verb and must not be read-only")
        }
    }

    func testEveryMethodSpellingIsStable() {
        // Wire spellings are a contract with shipped phones. Pin them.
        let expected: [LANLinkProtocol.Method: String] = [
            .hello: "hello", .ping: "ping",
            .sessionsList: "sessions.list", .sessionTail: "session.tail",
            .sessionSubscribe: "session.subscribe", .sessionUnsubscribe: "session.unsubscribe",
            .sessionInput: "session.input", .sessionResize: "session.resize",
            .sessionStart: "session.start", .sessionStop: "session.stop",
            .approvalDecide: "approval.decide",
        ]
        XCTAssertEqual(Set(expected.keys), Set(LANLinkProtocol.Method.allCases))
        for (m, s) in expected { XCTAssertEqual(m.rawValue, s) }
    }

    func testNoMethodIsSpelledLikeAHelperVerb() {
        // The phone speaks to the APP, not the helper. A LAN method that
        // shares a helper verb's exact spelling invites someone to proxy
        // it straight through. The helper's verbs are snake_case; ours
        // are dotted — assert the namespaces cannot collide.
        let helperSpellings: Set<String> = [
            "start_session", "list_sessions", "stop_session", "send_input",
            "send_input_raw", "resize", "get_tail_snapshot", "subscribe_events",
            "approve_action", "get_pending_approvals", "attach_wrapped_session",
            "attach",   // does not exist on the helper either; pinned so nobody adds it
        ]
        for m in LANLinkProtocol.Method.allCases {
            XCTAssertFalse(helperSpellings.contains(m.rawValue),
                           "\(m.rawValue) collides with a helper verb spelling")
        }
    }

    // MARK: - Envelope round trips

    func testRequestRoundTrip() throws {
        let f = LANLinkFrame.request(id: "r1", method: "sessions.list",
                                     params: ["limit": .int(50), "q": .string("x")])
        let back = try LANLinkFrame.decode(try f.encode())
        XCTAssertEqual(back, f)
    }

    func testOkReplyRoundTrip() throws {
        let f = LANLinkFrame.reply(id: "r1", ok: true,
                                   result: ["sessions": .array([.object(["id": .string("s1")])])],
                                   error: nil)
        XCTAssertEqual(try LANLinkFrame.decode(try f.encode()), f)
    }

    func testErrorReplyRoundTrip() throws {
        let f = LANLinkFrame.reply(id: "r2", ok: false, result: [:],
                                   error: LANLinkWireError(code: "session_not_found", message: "gone"))
        XCTAssertEqual(try LANLinkFrame.decode(try f.encode()), f)
    }

    func testEventRoundTripKeepsSeqAsUInt64() throws {
        let f = LANLinkFrame.event(kind: "output", subscription: "sub-1",
                                   seq: 9_007_199_254_740_000,   // > 2^53, must not go through Double
                                   data: ["bytes_b64": .string("aGk=")])
        XCTAssertEqual(try LANLinkFrame.decode(try f.encode()), f)
    }

    func testHeartbeatRoundTrip() throws {
        let f = LANLinkFrame.heartbeat(ts: 1_700_000_000.5)
        XCTAssertEqual(try LANLinkFrame.decode(try f.encode()), f)
    }

    // MARK: - Classification is by key presence

    func testClassifyRefusesWrongVersion() {
        XCTAssertThrowsError(try LANLinkFrame.classify(["v": 2, "hb": 1.0])) { e in
            XCTAssertEqual(e as? LANLinkFrame.DecodeError, .unsupportedVersion(2))
        }
        XCTAssertThrowsError(try LANLinkFrame.classify(["hb": 1.0])) { e in
            XCTAssertEqual(e as? LANLinkFrame.DecodeError, .unsupportedVersion(nil))
        }
    }

    func testClassifyRefusesShapeWithNoMarker() {
        XCTAssertThrowsError(try LANLinkFrame.classify(["v": 1, "foo": "bar"])) { e in
            XCTAssertEqual(e as? LANLinkFrame.DecodeError, .unrecognisedShape)
        }
    }

    func testDecodeRefusesInvalidJSON() {
        XCTAssertThrowsError(try LANLinkFrame.decode(Data("{not json".utf8))) { e in
            XCTAssertEqual(e as? LANLinkFrame.DecodeError, .invalidJSON)
        }
    }

    func testDecodeRefusesOversizedBodyBeforeParsing() {
        let big = Data(repeating: 0x20, count: LANLinkProtocol.maxFrameBytes + 1)
        XCTAssertThrowsError(try LANLinkFrame.decode(big)) { e in
            XCTAssertEqual(e as? LANLinkFrame.DecodeError, .tooLarge(big.count))
        }
    }

    // MARK: - Error routing

    func testAgentSpecificAndSharedCodesRouteToTypedErrors() {
        XCTAssertEqual(LANLinkWireError(code: "helper_not_running", message: "").asSessionControlError,
                       .helperNotRunning)
        XCTAssertEqual(LANLinkWireError(code: "session_not_found", message: "").asSessionControlError,
                       .sessionNotFound)
        XCTAssertEqual(LANLinkWireError(code: "local_control_off", message: "").asSessionControlError,
                       .localControlOff)
        XCTAssertEqual(LANLinkWireError(code: "not_implemented", message: "").asSessionControlError,
                       .notImplemented)
        XCTAssertEqual(LANLinkWireError(code: "unauthenticated", message: "").asSessionControlError,
                       .unauthenticated)
    }

    // MARK: - Framer

    func testFramerJoinsAndSplitsExactly() throws {
        let a = Data("alpha".utf8), b = Data("beta".utf8), c = Data()
        var stream = Data()
        stream.append(try LANLinkFramer.frame(a))
        stream.append(try LANLinkFramer.frame(b))
        stream.append(try LANLinkFramer.frame(c))

        var framer = LANLinkFramer()
        let frames = try framer.append(stream)
        XCTAssertEqual(frames, [a, b, c])
        XCTAssertEqual(framer.pendingByteCount, 0)
    }

    func testFramerHandlesEveryByteBoundary() throws {
        // Feed the stream one byte at a time — the boundary between
        // header and body, and between frames, must all be handled.
        let bodies = [Data("x".utf8), Data("yy".utf8), Data("zzz".utf8)]
        var stream = Data()
        for b in bodies { stream.append(try LANLinkFramer.frame(b)) }

        var framer = LANLinkFramer()
        var got: [Data] = []
        for byte in stream {
            got.append(contentsOf: try framer.append(Data([byte])))
        }
        XCTAssertEqual(got, bodies)
    }

    func testFramerRejectsOversizedHeaderWithoutBuffering() {
        var framer = LANLinkFramer()
        var header = Data()
        var len = UInt32(LANLinkProtocol.maxFrameBytes + 1).bigEndian
        withUnsafeBytes(of: &len) { header.append(contentsOf: $0) }
        XCTAssertThrowsError(try framer.append(header)) { e in
            XCTAssertEqual(e as? LANLinkFramer.FrameError,
                           .tooLarge(claimed: LANLinkProtocol.maxFrameBytes + 1))
        }
    }

    func testFramerRefusesToFrameOversizedBody() {
        let big = Data(repeating: 0, count: LANLinkProtocol.maxFrameBytes + 1)
        XCTAssertThrowsError(try LANLinkFramer.frame(big))
    }

    func testMaxFrameMatchesHelperFraming() throws {
        // Same cap as HelperKit's Framing.maxPayload — read from source so
        // it cannot drift silently.
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        let src = try String(contentsOf: url.appendingPathComponent(
            "HelperSwift/Sources/HelperKit/Framing.swift"), encoding: .utf8)
        XCTAssertTrue(src.contains("maxPayload: Int = 1 << 20"),
                      "HelperKit Framing cap changed; update LANLinkProtocol.maxFrameBytes")
        XCTAssertEqual(LANLinkProtocol.maxFrameBytes, 1 << 20)
    }

    // MARK: - Timings encode the acceptance criteria

    func testSilenceTimeoutSatisfiesThreeSecondDisconnectCriterion() {
        XCTAssertLessThanOrEqual(LANLinkProtocol.peerSilenceTimeout, 3.0)
        XCTAssertLessThan(LANLinkProtocol.heartbeatInterval, LANLinkProtocol.peerSilenceTimeout / 2,
                          "at least two heartbeats must fit in the silence window or one lost packet disconnects")
    }
}
