import Foundation

/// Assigns each provider-global compatibility source (CLI files, helper
/// snapshots, environment variables) to exactly one local account.
///
/// Explicit credentials remain account-scoped in `ProviderConfig`/Keychain.
/// This store exists only for legacy sources that cannot identify more than
/// one account. Without an owner, running two configs for the same provider
/// would report the same external account twice.
enum ProviderSharedCredentialOwner {
    enum Lookup: Equatable {
        case unavailable
        case unowned
        case owned(UUID)
        case corrupt
    }

    private static let supportedKinds: Set<ProviderKind> = [
        .claude,
        .gemini,
    ]
    private static let lock = NSLock()

    struct PersistenceCheckpoint {
        fileprivate struct Entry {
            let kind: ProviderKind
            let rawValue: String?
        }

        fileprivate let entries: [Entry]
    }

    /// Injectable for focused tests. The production value is shared with the
    /// helper so both processes make the same legacy-account assignment.
    static var defaults: UserDefaults? =
        UserDefaults(suiteName: HelperIPC.suiteName)
    static var synchronizeDefaults:
        (UserDefaults) -> Bool = {
            $0.synchronize()
        }

    #if os(macOS)
    /// Every App/Helper owner mutation uses the same advisory lock as Gemini
    /// credential mutation. Focused tests inject an equivalent lock whose path
    /// is isolated from production state.
    static var mutationLock:
        GeminiCredentialMutationLock = .shared
    #endif

    @discardableResult
    static func reconcile(
        configs: [ProviderConfig]
    ) -> Bool {
        withMutationLock(or: false) {
            lock.withLock {
                guard let defaults else {
                    return false
                }
                _ = synchronizeDefaults(defaults)
                guard
                    let checkpoint = persistenceCheckpoint(
                        defaults: defaults
                    )
                else {
                    return false
                }
                let kinds = supportedKinds.sorted {
                    $0.rawValue < $1.rawValue
                }
                let currentByKind =
                    Dictionary(
                        uniqueKeysWithValues:
                            kinds.map {
                                (
                                    $0,
                                    ownerLookup(
                                        defaults: defaults,
                                        forKey:
                                            ownerKey(
                                                for: $0
                                            )
                                    )
                                )
                            }
                    )
                guard
                    !currentByKind.values.contains(
                        .corrupt
                    )
                else {
                    return false
                }
                for kind in kinds {
                let eligible = configs
                    .filter {
                        $0.kind == kind
                            && $0.isEnabled
                            && $0.sharedCredentialFallbackDisabled != true
                    }
                    .sorted {
                        if $0.sortOrder != $1.sortOrder {
                            return $0.sortOrder < $1.sortOrder
                        }
                        return $0.accountID.uuidString
                            < $1.accountID.uuidString
                    }
                let eligibleIDs = Set(eligible.map(\.accountID))
                let key = ownerKey(for: kind)

                    if
                        case let .owned(current) =
                            currentByKind[kind],
                        eligibleIDs.contains(current)
                    {
                    continue
                }

                if let replacement = eligible.first?.accountID {
                    guard
                        persistOwner(
                            replacement,
                            defaults: defaults,
                            forKey: key
                        )
                    else {
                        _ = restore(
                            checkpoint,
                            defaults: defaults
                        )
                        return false
                    }
                } else {
                    guard
                        persistOwner(
                            nil,
                            defaults: defaults,
                            forKey: key
                        )
                    else {
                        _ = restore(
                            checkpoint,
                            defaults: defaults
                        )
                        return false
                    }
                    }
                }
                return true
            }
        }
    }

    static func makePersistenceCheckpoint()
        -> PersistenceCheckpoint?
    {
        withMutationLock(or: nil) {
            lock.withLock {
                guard let defaults else {
                    return nil
                }
                _ = synchronizeDefaults(defaults)
                return persistenceCheckpoint(
                    defaults: defaults
                )
            }
        }
    }

    @discardableResult
    static func restore(
        _ checkpoint: PersistenceCheckpoint
    ) -> Bool {
        withMutationLock(or: false) {
            lock.withLock {
                guard let defaults else {
                    return false
                }
                return restore(
                    checkpoint,
                    defaults: defaults
                )
            }
        }
    }

    static func withPersistenceLock<T>(
        or failure: T,
        _ body: () -> T
    ) -> T {
        withMutationLock(or: failure, body)
    }

    /// Returns true for the existing owner, or atomically claims an unowned
    /// global source. Production refreshes call `reconcile` before fan-out,
    /// while this fallback keeps direct strategy calls deterministic.
    static func claim(
        kind: ProviderKind,
        accountID: UUID
    ) -> Bool {
        guard supportedKinds.contains(kind) else { return false }
        return withMutationLock(or: false) {
            lock.withLock {
                guard let defaults else {
                    return false
                }
                _ = synchronizeDefaults(defaults)
                let key = ownerKey(for: kind)
                switch ownerLookup(
                    defaults: defaults,
                    forKey: key
                ) {
                case .owned(let current):
                    return current == accountID
                case .corrupt, .unavailable:
                    return false
                case .unowned:
                    return persistOwner(
                        accountID,
                        defaults: defaults,
                        forKey: key
                    )
                }
            }
        }
    }

    static func isOwner(
        kind: ProviderKind,
        accountID: UUID
    ) -> Bool {
        guard supportedKinds.contains(kind) else { return false }
        return withMutationLock(or: false) {
            lock.withLock {
                guard let defaults else {
                    return false
                }
                _ = synchronizeDefaults(defaults)
                return ownerLookup(
                    defaults: defaults,
                    forKey: ownerKey(for: kind)
                ) == .owned(accountID)
            }
        }
    }

    static func owner(
        kind: ProviderKind
    ) -> UUID? {
        guard supportedKinds.contains(kind) else {
            return nil
        }
        return withMutationLock(
            or: Optional<UUID>.none
        ) {
            lock.withLock {
                guard let defaults else {
                    return nil
                }
                _ = synchronizeDefaults(defaults)
                guard
                    case let .owned(owner) =
                        ownerLookup(
                            defaults: defaults,
                            forKey: ownerKey(
                                for: kind
                            )
                        )
                else {
                    return nil
                }
                return owner
            }
        }
    }

    static func lookup(
        kind: ProviderKind
    ) -> Lookup {
        guard supportedKinds.contains(kind) else {
            return .unavailable
        }
        return withMutationLock(or: .unavailable) {
            lock.withLock {
                guard let defaults else {
                    return .unavailable
                }
                _ = synchronizeDefaults(defaults)
                return ownerLookup(
                    defaults: defaults,
                    forKey: ownerKey(for: kind)
                )
            }
        }
    }

    /// Read-only eligibility check for UI previews. It deliberately does not
    /// claim an unowned shared source; opening and cancelling an editor must
    /// not change credential ownership.
    static func canUse(
        kind: ProviderKind,
        accountID: UUID
    ) -> Bool {
        guard supportedKinds.contains(kind) else { return false }
        return withMutationLock(or: false) {
            lock.withLock {
                guard let defaults else {
                    return false
                }
                _ = synchronizeDefaults(defaults)
                switch ownerLookup(
                    defaults: defaults,
                    forKey: ownerKey(for: kind)
                ) {
                case .unowned:
                    return true
                case .owned(let owner):
                    return owner == accountID
                case .corrupt, .unavailable:
                    return false
                }
            }
        }
    }

    @discardableResult
    static func release(
        kind: ProviderKind,
        accountID: UUID
    ) -> Bool {
        // Idempotent cleanup: providers without a shared compatibility source
        // have no owner record to release.
        guard supportedKinds.contains(kind) else {
            return true
        }
        return withMutationLock(or: false) {
            lock.withLock {
                guard let defaults else {
                    return false
                }
                _ = synchronizeDefaults(defaults)
                let key = ownerKey(for: kind)
                switch ownerLookup(
                    defaults: defaults,
                    forKey: key
                ) {
                case .unowned:
                    return true
                case .owned(let owner)
                    where owner != accountID:
                    return true
                case .owned:
                    return persistOwner(
                        nil,
                        defaults: defaults,
                        forKey: key
                    )
                case .corrupt, .unavailable:
                    return false
                }
            }
        }
    }

    private static func persistOwner(
        _ owner: UUID?,
        defaults: UserDefaults,
        forKey key: String
    ) -> Bool {
        let previous = defaults.object(
            forKey: key
        )
        if let owner {
            defaults.set(
                owner.uuidString,
                forKey: key
            )
        } else {
            defaults.removeObject(forKey: key)
        }
        let expected: Lookup =
            owner.map(Lookup.owned)
                ?? .unowned
        guard
            synchronizeDefaults(defaults),
            ownerLookup(
                defaults: defaults,
                forKey: key
            ) == expected
        else {
            if let previous {
                defaults.set(
                    previous,
                    forKey: key
                )
            } else {
                defaults.removeObject(
                    forKey: key
                )
            }
            _ = synchronizeDefaults(defaults)
            return false
        }
        return true
    }

    private static func persistenceCheckpoint(
        defaults: UserDefaults
    ) -> PersistenceCheckpoint? {
        let kinds = supportedKinds.sorted {
            $0.rawValue < $1.rawValue
        }
        var entries: [PersistenceCheckpoint.Entry] = []
        for kind in kinds {
            let raw = defaults.object(
                forKey: ownerKey(for: kind)
            )
            guard raw == nil || raw is String else {
                return nil
            }
            entries.append(
                PersistenceCheckpoint.Entry(
                    kind: kind,
                    rawValue: raw as? String
                )
            )
        }
        return PersistenceCheckpoint(entries: entries)
    }

    private static func restore(
        _ checkpoint: PersistenceCheckpoint,
        defaults: UserDefaults
    ) -> Bool {
        for entry in checkpoint.entries {
            let key = ownerKey(for: entry.kind)
            if let rawValue = entry.rawValue {
                defaults.set(rawValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        guard synchronizeDefaults(defaults) else {
            return false
        }
        return checkpoint.entries.allSatisfy { entry in
            let key = ownerKey(for: entry.kind)
            if let rawValue = entry.rawValue {
                return defaults.string(forKey: key) == rawValue
            }
            return defaults.object(forKey: key) == nil
        }
    }

    private static func ownerKey(for kind: ProviderKind) -> String {
        "cli_pulse_provider_shared_credential_owner_\(kind.rawValue)"
    }

    private static func ownerLookup(
        defaults: UserDefaults,
        forKey key: String
    ) -> Lookup {
        guard let raw = defaults.object(forKey: key) else {
            return .unowned
        }
        guard
            let value = raw as? String,
            let owner = UUID(uuidString: value)
        else {
            return .corrupt
        }
        return .owned(owner)
    }

    private static func withMutationLock<T>(
        or failure: T,
        _ body: () -> T
    ) -> T {
        #if os(macOS)
        return mutationLock.withLock(
            or: failure,
            body
        )
        #else
        return body()
        #endif
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
