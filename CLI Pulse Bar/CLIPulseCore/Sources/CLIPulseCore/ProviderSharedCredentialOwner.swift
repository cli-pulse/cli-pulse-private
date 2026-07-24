import Foundation

/// Assigns each provider-global compatibility source (CLI files, helper
/// snapshots, environment variables) to exactly one local account.
///
/// Explicit credentials remain account-scoped in `ProviderConfig`/Keychain.
/// This store exists only for legacy sources that cannot identify more than
/// one account. Without an owner, running two configs for the same provider
/// would report the same external account twice.
enum ProviderSharedCredentialOwner {
    private static let supportedKinds: Set<ProviderKind> = [
        .claude,
        .gemini,
    ]
    private static let lock = NSLock()

    /// Injectable for focused tests. The production value is shared with the
    /// helper so both processes make the same legacy-account assignment.
    static var defaults: UserDefaults =
        UserDefaults(suiteName: HelperIPC.suiteName) ?? .standard

    static func reconcile(configs: [ProviderConfig]) {
        lock.withLock {
            for kind in supportedKinds {
                let eligible = configs
                    .filter { $0.kind == kind && $0.isEnabled }
                    .sorted {
                        if $0.sortOrder != $1.sortOrder {
                            return $0.sortOrder < $1.sortOrder
                        }
                        return $0.accountID.uuidString
                            < $1.accountID.uuidString
                    }
                let eligibleIDs = Set(eligible.map(\.accountID))
                let key = ownerKey(for: kind)

                if let current = storedOwner(forKey: key),
                   eligibleIDs.contains(current) {
                    continue
                }

                if let replacement = eligible.first?.accountID {
                    defaults.set(
                        replacement.uuidString,
                        forKey: key
                    )
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
    }

    /// Returns true for the existing owner, or atomically claims an unowned
    /// global source. Production refreshes call `reconcile` before fan-out,
    /// while this fallback keeps direct strategy calls deterministic.
    static func claim(
        kind: ProviderKind,
        accountID: UUID
    ) -> Bool {
        guard supportedKinds.contains(kind) else { return false }
        return lock.withLock {
            let key = ownerKey(for: kind)
            if let current = storedOwner(forKey: key) {
                return current == accountID
            }
            defaults.set(accountID.uuidString, forKey: key)
            return true
        }
    }

    static func isOwner(
        kind: ProviderKind,
        accountID: UUID
    ) -> Bool {
        guard supportedKinds.contains(kind) else { return false }
        return lock.withLock {
            storedOwner(forKey: ownerKey(for: kind)) == accountID
        }
    }

    static func release(
        kind: ProviderKind,
        accountID: UUID
    ) {
        guard supportedKinds.contains(kind) else { return }
        lock.withLock {
            let key = ownerKey(for: kind)
            guard storedOwner(forKey: key) == accountID else {
                return
            }
            defaults.removeObject(forKey: key)
        }
    }

    private static func ownerKey(for kind: ProviderKind) -> String {
        "cli_pulse_provider_shared_credential_owner_\(kind.rawValue)"
    }

    private static func storedOwner(forKey key: String) -> UUID? {
        guard let raw = defaults.string(forKey: key) else {
            return nil
        }
        guard let owner = UUID(uuidString: raw) else {
            defaults.removeObject(forKey: key)
            return nil
        }
        return owner
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
