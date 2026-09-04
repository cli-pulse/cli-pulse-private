import XCTest
import CryptoKit
@testable import CLIPulseCore

/// Remote-control M0 — Keychain persistence of identity and peers.
///
/// Runs against `KeychainHelper`'s in-memory store (XCTest is loaded),
/// which is also the point: this file going through `KeychainHelper`
/// rather than `SecItem*` is what keeps the suite from blocking on the
/// real login keychain.
final class LANPairingStoreTests: XCTestCase {

    override func setUp() {
        super.setUp()
        KeychainHelper.inMemoryStoreForTesting = [:]
    }

    private func peer(_ id: String) throws -> LANPairing.PairedPeer {
        try LANPairing.PairedPeer(
            id: id, displayName: "Phone \(id)", pskIdentity: "peer:\(id)",
            sessionKey: SymmetricKey(size: .bits256),
            peerPublicKey: LANPairing.LocalIdentity.generate().publicKey,
            pairedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testIdentityIsCreatedOnceAndStable() throws {
        let a = try LANPairingStore.loadOrCreateIdentity()
        let b = try LANPairingStore.loadOrCreateIdentity()
        XCTAssertEqual(a, b, "identity must not change between launches")
        XCTAssertFalse(a.deviceID.isEmpty)
    }

    func testPeersSaveListReplaceAndRemove() throws {
        XCTAssertTrue(LANPairingStore.peers().isEmpty)
        try LANPairingStore.save(try peer("a"))
        try LANPairingStore.save(try peer("b"))
        XCTAssertEqual(Set(LANPairingStore.peers().map(\.id)), ["a", "b"])

        // Re-pairing replaces, does not duplicate.
        let a2 = try peer("a")
        try LANPairingStore.save(a2)
        XCTAssertEqual(LANPairingStore.peers().count, 2)
        XCTAssertEqual(LANPairingStore.peer(id: "a"), a2)

        LANPairingStore.remove(peerID: "a")
        XCTAssertEqual(LANPairingStore.peers().map(\.id), ["b"])
        XCTAssertNil(LANPairingStore.peer(id: "a"))

        LANPairingStore.removeAllPeers()
        XCTAssertTrue(LANPairingStore.peers().isEmpty)
    }

    func testCorruptIdentityIsRegeneratedAndPeersDropped() throws {
        try LANPairingStore.save(try peer("x"))
        _ = KeychainHelper.save(key: LANPairingStore.identityKey, value: "garbage")
        let fresh = try LANPairingStore.loadOrCreateIdentity()
        XCTAssertFalse(fresh.deviceID.isEmpty)
        XCTAssertTrue(LANPairingStore.peers().isEmpty,
                      "peers paired against a lost identity cannot be served; they must go")
    }

    func testCorruptPeerRecordIsSkippedNotFatal() throws {
        try LANPairingStore.save(try peer("good"))
        _ = KeychainHelper.save(key: LANPairingStore.peerKey("bad"), value: "{}")
        // Force "bad" into the index.
        _ = KeychainHelper.save(key: LANPairingStore.peerIndexKey, value: "[\"good\",\"bad\"]")
        XCTAssertEqual(LANPairingStore.peers().map(\.id), ["good"])
    }
}
