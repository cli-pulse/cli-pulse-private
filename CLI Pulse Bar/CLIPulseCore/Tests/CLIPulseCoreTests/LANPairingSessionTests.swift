import XCTest
import CryptoKit
@testable import CLIPulseCore

/// Remote-control M0 — the pairing handshake, both halves, run against
/// each other over an in-memory channel pair.
final class LANPairingSessionTests: XCTestCase {

    private func pairEnds(exporter: Data = Data(repeating: 0x5A, count: 32))
        -> (mac: InMemoryLANLinkChannel, phone: InMemoryLANLinkChannel) {
        let (a, b) = InMemoryLANLinkChannel.pair(exporter: exporter)
        return (a, b)
    }

    func testSuccessfulPairingGivesBothSidesTheSameKeyAndIdentity() async throws {
        let macID = LANPairing.LocalIdentity.generate()
        let phoneID = LANPairing.LocalIdentity.generate()
        let payload = LANPairing.QRPayload.mint(deviceID: macID.deviceID)
        let (macEnd, phoneEnd) = pairEnds()

        let macSAS = LockedBox<String?>(nil)
        let phoneSAS = LockedBox<String?>(nil)

        let agent = LANPairingSession.Agent(
            channel: macEnd, identity: macID, displayName: "Studio", payload: payload,
            decide: { sas, name in
                macSAS.set(sas)
                XCTAssertEqual(name, "Jason's iPhone")
                return true
            })
        async let outcome = agent.run()
        let phonePeer = try await LANPairingSession.Client.pair(
            channel: phoneEnd, identity: phoneID, displayName: "Jason's iPhone", payload: payload,
            onSAS: { phoneSAS.set($0) })

        guard case let .paired(macPeer) = await outcome else { return XCTFail("mac did not pair") }

        // The property everything rests on.
        XCTAssertEqual(macPeer.sessionKey, phonePeer.sessionKey)
        XCTAssertEqual(macPeer.pskIdentity, "peer:" + phoneID.deviceID)
        XCTAssertEqual(phonePeer.pskIdentity, "peer:" + phoneID.deviceID, "phone must present its OWN id")
        XCTAssertEqual(macPeer.presharedKey, phonePeer.presharedKey, "what the Mac registers == what the phone presents")

        // Records point at each other.
        XCTAssertEqual(macPeer.id, phoneID.deviceID)
        XCTAssertEqual(phonePeer.id, macID.deviceID)
        XCTAssertEqual(macPeer.displayName, "Jason's iPhone")
        XCTAssertEqual(phonePeer.displayName, "Studio")
        XCTAssertEqual(macPeer.peerPublicKey.rawRepresentation, phoneID.publicKey.rawRepresentation)
        XCTAssertEqual(phonePeer.peerPublicKey.rawRepresentation, macID.publicKey.rawRepresentation)

        // Both screens showed the same code, and nobody sent it.
        XCTAssertNotNil(macSAS.get()); XCTAssertEqual(macSAS.get(), phoneSAS.get())
        XCTAssertEqual(macSAS.get()?.count, 6)
        for body in macEnd.sent + phoneEnd.sent {
            XCTAssertFalse(String(decoding: body, as: UTF8.self).contains(macSAS.get()!),
                           "the SAS must never be transmitted")
        }
    }

    func testSASBindsToTheHandshakeNotTheQR() async throws {
        // Same QR, two different handshakes (different exporters) ⇒
        // different codes. This is what defeats a bystander who
        // photographed the QR and raced the user to connect.
        let macID = LANPairing.LocalIdentity.generate()
        let payload = LANPairing.QRPayload.mint(deviceID: macID.deviceID)
        var codes: [String] = []
        for exporter in [Data(repeating: 1, count: 32), Data(repeating: 2, count: 32)] {
            let (macEnd, phoneEnd) = pairEnds(exporter: exporter)
            let agent = LANPairingSession.Agent(
                channel: macEnd, identity: macID, displayName: "M", payload: payload,
                decide: { sas, _ in codes.append(sas); return false })
            async let _ = agent.run()
            _ = try? await LANPairingSession.Client.pair(
                channel: phoneEnd, identity: .generate(), displayName: "P", payload: payload, onSAS: { _ in })
        }
        XCTAssertEqual(codes.count, 2)
        XCTAssertNotEqual(codes[0], codes[1])
    }

    func testDeclineOnTheMacIsRejectedOnThePhone() async throws {
        let macID = LANPairing.LocalIdentity.generate()
        let payload = LANPairing.QRPayload.mint(deviceID: macID.deviceID)
        let (macEnd, phoneEnd) = pairEnds()
        let agent = LANPairingSession.Agent(
            channel: macEnd, identity: macID, displayName: "M", payload: payload,
            decide: { _, _ in false })
        async let outcome = agent.run()
        do {
            _ = try await LANPairingSession.Client.pair(
                channel: phoneEnd, identity: .generate(), displayName: "P", payload: payload, onSAS: { _ in })
            XCTFail("phone should not have paired")
        } catch let e as LANPairingSession.Failure {
            XCTAssertEqual(e, .rejected)
        }
        let o = await outcome
        XCTAssertEqual(o, .rejected)
    }

    func testExpiredQRIsRefusedEvenIfTheUserWouldApprove() async throws {
        // The Mac's clock says the QR is dead; approval must not resurrect it.
        let macID = LANPairing.LocalIdentity.generate()
        let minted = Date(timeIntervalSince1970: 1_700_000_000)
        let payload = LANPairing.QRPayload.mint(deviceID: macID.deviceID, now: minted)
        let (macEnd, phoneEnd) = pairEnds()
        let agent = LANPairingSession.Agent(
            channel: macEnd, identity: macID, displayName: "M", payload: payload,
            decide: { _, _ in true },
            clock: { minted.addingTimeInterval(61) })
        async let outcome = agent.run()
        do {
            _ = try await LANPairingSession.Client.pair(
                channel: phoneEnd, identity: .generate(), displayName: "P", payload: payload, onSAS: { _ in })
            XCTFail("should have failed")
        } catch {
            // Either the agent refused, or the channel closed — both are "no".
        }
        let o = await outcome
        XCTAssertEqual(o, .expired)
    }

    func testPhoneRefusesAMacWhoseIDDoesNotMatchTheQR() async throws {
        // The QR said Mac A; whoever answered claims to be Mac B.
        let macA = LANPairing.LocalIdentity.generate()
        let macB = LANPairing.LocalIdentity.generate()
        let payload = LANPairing.QRPayload.mint(deviceID: macA.deviceID)
        let (macEnd, phoneEnd) = pairEnds()
        let agent = LANPairingSession.Agent(
            channel: macEnd, identity: macB, displayName: "Impostor", payload: payload,
            decide: { _, _ in true })
        async let _ = agent.run()
        do {
            _ = try await LANPairingSession.Client.pair(
                channel: phoneEnd, identity: .generate(), displayName: "P", payload: payload, onSAS: { _ in })
            XCTFail("phone accepted a Mac that is not the one on the QR")
        } catch let e as LANPairingSession.Failure {
            guard case .badExchange = e else { return XCTFail("\(e)") }
        }
    }

    func testOutOfOrderRequestIsRefused() async throws {
        let macID = LANPairing.LocalIdentity.generate()
        let payload = LANPairing.QRPayload.mint(deviceID: macID.deviceID)
        let (macEnd, phoneEnd) = pairEnds()
        let agent = LANPairingSession.Agent(
            channel: macEnd, identity: macID, displayName: "M", payload: payload,
            decide: { _, _ in true })
        async let outcome = agent.run()
        // Skip the exchange and go straight to await.
        try await phoneEnd.send(try LANLinkFrame.request(id: "x", method: "pair.await", params: [:]).encode())
        let o = await outcome
        guard case .failed = o else { return XCTFail("expected failure, got \(o)") }
        let replies = phoneEnd.sent   // nothing useful sent by the phone; check the mac's reply
        _ = replies
        let macReplies = macEnd.sent.compactMap { try? LANLinkFrame.decode($0) }
        guard case let .reply(_, ok, _, e)? = macReplies.first else { return XCTFail("no reply") }
        XCTAssertFalse(ok)
        XCTAssertEqual(e?.code, LANPairingSession.ErrorCode.outOfOrder)
    }

    func testSteadyRouterDoesNotKnowThePairingVerbs() async throws {
        // Belt and braces: even if a pairing-key connection reached the
        // steady router, the verbs are unknown there.
        let (macEnd, phoneEnd) = InMemoryLANLinkChannel.pair()
        let session = LANLinkAgentSession(
            channel: macEnd, backend: FakeStreamingBackend(),
            identity: LANAgentIdentity(deviceID: "m", displayName: "M", cloudDeviceID: nil),
            heartbeatInterval: 10, silenceTimeout: 10)
        let run = Task { await session.run() }
        try await phoneEnd.send(try LANLinkFrame.request(id: "1", method: "pair.exchange", params: [:]).encode())
        var iterator = phoneEnd.inbound.makeAsyncIterator()
        let body = try await iterator.next()
        guard let body, case let .reply(_, ok, _, e) = try LANLinkFrame.decode(body) else { return XCTFail() }
        XCTAssertFalse(ok)
        XCTAssertEqual(e?.code, "bad_request")
        await session.close(); _ = await run.value
    }
}

/// Tiny thread-safe box for closures that capture across actors.
final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
}
