/// Orders provider-account persistence and compensates every completed phase
/// when a later phase fails. Each persistence primitive must also restore its
/// own partial writes before returning `false`.
public enum ProviderAccountSaveTransactionResult: Equatable {
    case committed
    case failedRolledBack
    case failedRollbackIncomplete
}

/// Keeps the original rollback closures alive after an incomplete
/// compensation. Callers must clear this gate successfully before capturing a
/// fresh persistence baseline for the same account.
public final class ProviderAccountSaveRecovery {
    private let restoreMetadata: () -> Bool
    private let restoreSecrets: () -> Bool

    public init(
        restoreMetadata: @escaping () -> Bool,
        restoreSecrets: @escaping () -> Bool
    ) {
        self.restoreMetadata = restoreMetadata
        self.restoreSecrets = restoreSecrets
    }

    @discardableResult
    public func recover() -> Bool {
        let metadataRestored = restoreMetadata()
        let secretsRestored = restoreSecrets()
        return metadataRestored && secretsRestored
    }
}

public enum ProviderAccountSaveTransaction {
    @discardableResult
    public static func commit(
        persistSecrets: () -> Bool,
        rollbackSecrets: () -> Bool,
        persistMetadata: () -> Bool,
        rollbackMetadata: () -> Bool,
        commitProviderCredential: () -> Bool,
        finalize: () -> Void
    ) -> ProviderAccountSaveTransactionResult {
        guard persistSecrets() else {
            return rollbackSecrets()
                ? .failedRolledBack
                : .failedRollbackIncomplete
        }
        guard persistMetadata() else {
            let metadataRestored = rollbackMetadata()
            let secretsRestored = rollbackSecrets()
            return metadataRestored && secretsRestored
                ? .failedRolledBack
                : .failedRollbackIncomplete
        }
        guard commitProviderCredential() else {
            let metadataRestored = rollbackMetadata()
            let secretsRestored = rollbackSecrets()
            return metadataRestored && secretsRestored
                ? .failedRolledBack
                : .failedRollbackIncomplete
        }
        finalize()
        return .committed
    }
}
