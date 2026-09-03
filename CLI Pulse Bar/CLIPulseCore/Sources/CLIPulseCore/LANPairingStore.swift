import Foundation

/// Keychain persistence for the LAN pairing records — this device's own
/// identity and the peers it has paired with.
///
/// Goes through `KeychainHelper`, never `SecItem*` directly. That helper
/// routes every access to an in-memory dictionary when XCTest is loaded,
/// which is the reason `AppState()` no longer hangs the test suite on the
/// real login keychain. A new credential path that bypassed it would
/// bring the hang back, and CI cannot catch that — a fresh runner's
/// keychain simply returns "not found".
///
/// No access group: these records are per-app on each device. The
/// LoginItem helper does not need them, and iOS has no keychain-sharing
/// entitlement anyway. Nothing here syncs to iCloud — pairing is between
/// two specific devices, and a key that followed the user's account to a
/// third device would defeat the point.
public enum LANPairingStore {

    static let identityKey = "cli_pulse_lan_identity"
    static let peerIndexKey = "cli_pulse_lan_peer_index"
    static func peerKey(_ id: String) -> String { "cli_pulse_lan_peer_" + id }

    // MARK: - Identity

    /// This device's identity, created on first use and stable after.
    public static func loadOrCreateIdentity() throws -> LANPairing.LocalIdentity {
        if let raw = KeychainHelper.load(key: identityKey) {
            if let id = try? LANPairing.LocalIdentity.deserialize(raw) { return id }
            // A corrupt identity is unrecoverable: peers paired against
            // its public key can no longer be served. Start fresh and
            // drop them — better an honest re-pair than a silent mismatch.
            removeAllPeers()
        }
        let fresh = LANPairing.LocalIdentity.generate()
        guard KeychainHelper.save(key: identityKey, value: try fresh.serialized()) else {
            throw LANPairing.PairingStoreError.keychainWriteFailed
        }
        return fresh
    }

    // MARK: - Peers

    public static func peers() -> [LANPairing.PairedPeer] {
        peerIDs().compactMap { id in
            guard let raw = KeychainHelper.load(key: peerKey(id)) else { return nil }
            return try? LANPairing.PairedPeer.deserialize(raw)
        }
    }

    public static func peer(id: String) -> LANPairing.PairedPeer? {
        guard let raw = KeychainHelper.load(key: peerKey(id)) else { return nil }
        return try? LANPairing.PairedPeer.deserialize(raw)
    }

    /// Insert or replace. Re-pairing the same device replaces its key.
    public static func save(_ peer: LANPairing.PairedPeer) throws {
        guard KeychainHelper.save(key: peerKey(peer.id), value: try peer.serialized()) else {
            throw LANPairing.PairingStoreError.keychainWriteFailed
        }
        var ids = peerIDs()
        if !ids.contains(peer.id) {
            ids.append(peer.id)
            guard writeIndex(ids) else { throw LANPairing.PairingStoreError.keychainWriteFailed }
        }
    }

    public static func remove(peerID: String) {
        _ = KeychainHelper.delete(key: peerKey(peerID))
        _ = writeIndex(peerIDs().filter { $0 != peerID })
    }

    /// "Forget every phone" — also used when the identity is regenerated.
    public static func removeAllPeers() {
        for id in peerIDs() { _ = KeychainHelper.delete(key: peerKey(id)) }
        _ = KeychainHelper.delete(key: peerIndexKey)
    }

    // MARK: - Index

    private static func peerIDs() -> [String] {
        guard let raw = KeychainHelper.load(key: peerIndexKey),
              let data = raw.data(using: .utf8),
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return ids
    }

    private static func writeIndex(_ ids: [String]) -> Bool {
        guard let data = try? JSONEncoder().encode(ids) else { return false }
        return KeychainHelper.save(key: peerIndexKey, value: String(decoding: data, as: UTF8.self))
    }
}
