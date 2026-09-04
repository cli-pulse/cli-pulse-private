import XCTest
import CryptoKit
@testable import CLIPulseCore

/// Remote-control M0 — QR pairing, key derivation, and the stored records.
final class LANPairingTests: XCTestCase {

    private let did = "0f4b2b9e-7c1e-4d7d-9b0e-6a3f9c1d2e5f"

    // MARK: - QR payload

    func testMintProducesFreshNoncesAndSixtySecondExpiry() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let a = LANPairing.QRPayload.mint(deviceID: did, now: now)
        let b = LANPairing.QRPayload.mint(deviceID: did, now: now)
        XCTAssertEqual(a.nonce.count, 32)
        XCTAssertNotEqual(a.nonce, b.nonce, "two QRs must never share a nonce")
        XCTAssertEqual(a.expiresAt, now.addingTimeInterval(60))
    }

    func testPayloadRoundTripsThroughTheURL() throws {
        let p = LANPairing.QRPayload.mint(deviceID: did)
        let url = p.urlString
        XCTAssertTrue(url.hasPrefix("clipulse://pair?"), url)
        let back = try LANPairing.QRPayload.parse(url)
        XCTAssertEqual(back.deviceID, p.deviceID)
        XCTAssertEqual(back.nonce, p.nonce)
        // Seconds resolution on the wire.
        XCTAssertEqual(Int(back.expiresAt.timeIntervalSince1970), Int(p.expiresAt.timeIntervalSince1970))
        XCTAssertEqual(back.version, LANLinkProtocol.version)
    }

    func testTheQRStopsWorkingAtSixtySeconds() {
        // The acceptance criterion, as a pure check — the live listener
        // teardown is exercised on hardware.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let p = LANPairing.QRPayload.mint(deviceID: did, now: now)
        XCTAssertFalse(p.isExpired(now: now.addingTimeInterval(59.9)))
        XCTAssertTrue(p.isExpired(now: now.addingTimeInterval(60.0)))
        XCTAssertTrue(p.isExpired(now: now.addingTimeInterval(3600)))
    }

    func testParseRefusesForeignURLs() {
        XCTAssertThrowsError(try LANPairing.QRPayload.parse("https://example.com/pair?v=1")) { e in
            XCTAssertEqual(e as? LANPairing.QRPayload.ParseError, .notAPairingURL)
        }
        XCTAssertThrowsError(try LANPairing.QRPayload.parse("clipulse://oauth?code=x")) { e in
            XCTAssertEqual(e as? LANPairing.QRPayload.ParseError, .notAPairingURL)
        }
    }

    func testParseRefusesShortNonce() {
        let short = Data(repeating: 1, count: 16).base64URLEncoded
        let url = "clipulse://pair?v=1&did=\(did)&n=\(short)&exp=1700000060"
        XCTAssertThrowsError(try LANPairing.QRPayload.parse(url)) { e in
            XCTAssertEqual(e as? LANPairing.QRPayload.ParseError, .badNonce)
        }
    }

    func testParseRefusesMissingFieldsAndWrongVersion() {
        let n = Data(repeating: 1, count: 32).base64URLEncoded
        XCTAssertThrowsError(try LANPairing.QRPayload.parse("clipulse://pair?v=1&n=\(n)&exp=1")) { e in
            XCTAssertEqual(e as? LANPairing.QRPayload.ParseError, .missingField("did"))
        }
        XCTAssertThrowsError(try LANPairing.QRPayload.parse("clipulse://pair?v=1&did=\(did)&n=\(n)")) { e in
            XCTAssertEqual(e as? LANPairing.QRPayload.ParseError, .missingField("exp"))
        }
        XCTAssertThrowsError(try LANPairing.QRPayload.parse("clipulse://pair?v=9&did=\(did)&n=\(n)&exp=1")) { e in
            XCTAssertEqual(e as? LANPairing.QRPayload.ParseError, .unsupportedVersion(9))
        }
    }

    func testBase64URLRoundTripCoversAllByteValues() {
        let all = Data((0...255).map { UInt8($0) })
        let s = all.base64URLEncoded
        XCTAssertFalse(s.contains("+")); XCTAssertFalse(s.contains("/")); XCTAssertFalse(s.contains("="))
        XCTAssertEqual(Data(base64URLEncoded: s), all)
    }

    // MARK: - Pairing PSK

    func testPairingPSKIsDeterministicFromThePayloadAndPrefixed() throws {
        let p = LANPairing.QRPayload.mint(deviceID: did)
        let k1 = try LANPairing.pairingPSK(for: p)
        let k2 = try LANPairing.pairingPSK(for: p)
        XCTAssertEqual(k1, k2, "both ends must derive the same channel key from the same QR")
        XCTAssertEqual(k1.identity, "pair:" + did)
        XCTAssertEqual(k1.key.bitCount, 256)
    }

    func testDifferentNoncesGiveDifferentPairingPSKs() throws {
        let a = LANPairing.QRPayload.mint(deviceID: did)
        let b = LANPairing.QRPayload.mint(deviceID: did)
        XCTAssertNotEqual(try LANPairing.pairingPSK(for: a).key, try LANPairing.pairingPSK(for: b).key)
    }

    // MARK: - Session PSK from in-channel ECDH

    func testSessionPSKIsSymmetricAcrossMacAndPhone() throws {
        // The property pairing rests on: each side, holding only its own
        // private key and the other's public key, computes the same PSK.
        let mac = LANPairing.LocalIdentity.generate()
        let phone = LANPairing.LocalIdentity.generate()
        let nonce = Data(repeating: 7, count: 32)

        let macSide = try LANPairing.sessionKey(
            myPrivateKey: mac.privateKey, peerPublicKey: phone.publicKey,
            macPublicKey: mac.publicKey, phonePublicKey: phone.publicKey, nonce: nonce)
        let phoneSide = try LANPairing.sessionKey(
            myPrivateKey: phone.privateKey, peerPublicKey: mac.publicKey,
            macPublicKey: mac.publicKey, phonePublicKey: phone.publicKey, nonce: nonce)

        XCTAssertEqual(macSide, phoneSide)
        // The PSK identity names the PHONE on both ends — it is what the
        // Mac's listener registers and what the phone presents.
        XCTAssertEqual(LANPairing.pskIdentity(phoneID: phone.deviceID), "peer:" + phone.deviceID)
    }

    func testSessionPSKIsNotAFunctionOfTheQRAlone() throws {
        // Two pairings from the same nonce with different ephemeral keys
        // must yield different session keys — otherwise photographing
        // the QR would be enough.
        let nonce = Data(repeating: 7, count: 32)
        let mac = LANPairing.LocalIdentity.generate()
        let phone1 = LANPairing.LocalIdentity.generate()
        let phone2 = LANPairing.LocalIdentity.generate()
        let k1 = try LANPairing.sessionKey(
            myPrivateKey: mac.privateKey, peerPublicKey: phone1.publicKey,
            macPublicKey: mac.publicKey, phonePublicKey: phone1.publicKey, nonce: nonce)
        let k2 = try LANPairing.sessionKey(
            myPrivateKey: mac.privateKey, peerPublicKey: phone2.publicKey,
            macPublicKey: mac.publicKey, phonePublicKey: phone2.publicKey, nonce: nonce)
        XCTAssertNotEqual(k1, k2)
    }

    func testPairingAndSessionKeysNeverCollideEvenWithSharedInputs() throws {
        // Domain separation: same nonce fed to both derivations must not
        // produce the same bytes.
        let p = LANPairing.QRPayload.mint(deviceID: did)
        let mac = LANPairing.LocalIdentity.generate()
        let phone = LANPairing.LocalIdentity.generate()
        let pairing = try LANPairing.pairingPSK(for: p)
        let session = try LANPairing.sessionKey(
            myPrivateKey: mac.privateKey, peerPublicKey: phone.publicKey,
            macPublicKey: mac.publicKey, phonePublicKey: phone.publicKey, nonce: p.nonce)
        XCTAssertNotEqual(pairing.key, session)
    }

    // MARK: - SAS

    func testShortAuthStringIsSixDigitsAndDeterministic() {
        let secret = Data((0..<32).map { UInt8($0) })
        let a = LANPairing.shortAuthString(exporterSecret: secret)
        XCTAssertEqual(a.count, 6)
        XCTAssertTrue(a.allSatisfy(\.isNumber))
        XCTAssertEqual(a, LANPairing.shortAuthString(exporterSecret: secret))
        // Leading zeros are preserved so both screens show identical text.
        XCTAssertEqual(LANPairing.shortAuthString(exporterSecret: Data(repeating: 0, count: 32)), "000000")
    }

    func testShortAuthStringDiffersForDifferentExporters() {
        let a = LANPairing.shortAuthString(exporterSecret: Data((0..<32).map { UInt8($0) }))
        let b = LANPairing.shortAuthString(exporterSecret: Data((0..<32).map { UInt8(255 - $0) }))
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Records

    func testLocalIdentityRoundTripsThroughSerialization() throws {
        let id = LANPairing.LocalIdentity.generate()
        let s = try id.serialized()
        let back = try LANPairing.LocalIdentity.deserialize(s)
        XCTAssertEqual(back, id)
        XCTAssertEqual(back.publicKey.rawRepresentation, id.publicKey.rawRepresentation)
    }

    func testPairedPeerControlFlagRoundTripsAndDefaultsToFalseForLegacyRecords() throws {
        // M1: the Mac remembers per phone whether it may control sessions.
        // A record written by M0 has no such field and must read back as
        // NOT allowed — the promise M0 made was "watch".
        let allowed = try LANPairing.PairedPeer(
            id: "phone-1", displayName: "P", pskIdentity: "peer:phone-1",
            sessionKey: SymmetricKey(size: .bits256),
            peerPublicKey: LANPairing.LocalIdentity.generate().publicKey,
            pairedAt: Date(timeIntervalSince1970: 1_700_000_000), controlAllowed: true)
        XCTAssertTrue(try LANPairing.PairedPeer.deserialize(try allowed.serialized()).controlAllowed)
        XCTAssertNotEqual(allowed, allowed.withControlAllowed(false))
        XCTAssertFalse(allowed.withControlAllowed(false).controlAllowed)

        let legacy = try allowed.serialized().replacingOccurrences(of: "\"ctl\":true", with: "")
            .replacingOccurrences(of: ",}", with: "}").replacingOccurrences(of: ",,", with: ",")
        XCTAssertFalse(legacy.contains("ctl"), legacy)
        let back = try LANPairing.PairedPeer.deserialize(legacy)
        XCTAssertFalse(back.controlAllowed)
        XCTAssertEqual(back.id, "phone-1")
    }

    func testPairedPeerRoundTripsAndRejectsCorruption() throws {
        let peer = try LANPairing.PairedPeer(
            id: "phone-1", displayName: "Jason's iPhone", pskIdentity: "peer:phone-1",
            sessionKey: SymmetricKey(size: .bits256),
            peerPublicKey: LANPairing.LocalIdentity.generate().publicKey,
            pairedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let s = try peer.serialized()
        XCTAssertEqual(try LANPairing.PairedPeer.deserialize(s), peer)
        XCTAssertEqual(peer.presharedKey.identity, "peer:phone-1")

        // Every malformed shape is `.corrupt` — the caller cannot act on
        // finer distinctions. Records are built explicitly rather than by
        // editing encoder output, because JSONEncoder escapes `/` as `\/`
        // and a random key's base64 may or may not contain one; a test
        // that flips on the RNG is not a test.
        func record(_ fields: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: fields), as: UTF8.self)
        }
        let goodPK = peer.peerPublicKey.rawRepresentation.base64EncodedString()
        let goodPSK = peer.sessionKey.withUnsafeBytes { Data($0).base64EncodedString() }

        let cases: [(String, String)] = [
            ("short key",   try record(["id": "p", "name": "n", "pid": "peer:p", "at": 0,
                                    "psk": Data(repeating: 1, count: 16).base64EncodedString(), "pk": goodPK])),
            ("empty id",    try record(["id": "", "name": "n", "pid": "peer:p", "at": 0, "psk": goodPSK, "pk": goodPK])),
            ("empty pid",   try record(["id": "p", "name": "n", "pid": "", "at": 0, "psk": goodPSK, "pk": goodPK])),
            ("bad base64",  try record(["id": "p", "name": "n", "pid": "peer:p", "at": 0, "psk": "!!!", "pk": goodPK])),
            ("bad pubkey",  try record(["id": "p", "name": "n", "pid": "peer:p", "at": 0, "psk": goodPSK,
                                    "pk": Data(repeating: 9, count: 5).base64EncodedString()])),
            ("missing field", try record(["id": "p", "psk": goodPSK])),
            ("not json",    "not json"),
        ]
        for (label, raw) in cases {
            XCTAssertThrowsError(try LANPairing.PairedPeer.deserialize(raw), label) { e in
                XCTAssertEqual(e as? LANPairing.PairingStoreError, .corrupt, label)
            }
        }
        XCTAssertThrowsError(try LANPairing.LocalIdentity.deserialize("{}")) { e in
            XCTAssertEqual(e as? LANPairing.PairingStoreError, .corrupt)
        }
    }
}
