import Foundation

/// Durable, credential-free retry queue for account rows that were removed
/// locally before Supabase confirmed their deletion. Every entry is scoped to
/// the authenticated CLIPulse user so an account switch can never replay user
/// A's deletion under user B's session.
@MainActor
final class ProviderAccountDeletionOutbox {
    static let shared = ProviderAccountDeletionOutbox()

    struct Intent: Codable, Hashable, Sendable {
        let userID: String
        let accountID: UUID
        /// Optional only so an unreleased v1 local queue can still decode.
        /// Every newly enqueued delete records the non-secret provider and
        /// provider-less legacy intents are never sent to the server.
        let provider: ProviderKind?
        /// Identifies one enqueue operation so a stale in-flight response
        /// cannot complete a newer retry for the same owner and account.
        /// Optional only so existing v1 queue payloads remain decodable.
        let generation: UUID?

        init(
            userID: String,
            accountID: UUID,
            provider: ProviderKind?,
            generation: UUID? = UUID()
        ) {
            self.userID = userID
            self.accountID = accountID
            self.provider = provider
            self.generation = generation
        }
    }

    private let defaults: UserDefaults
    private let storageKey: String
    private var corruptBackupKey: String {
        "\(storageKey).corrupt_backup"
    }

    private struct Envelope: Codable {
        let version: Int
        let intents: [Intent]
    }

    private enum LoadState {
        case missing
        case valid(Set<Intent>)
        case corrupt
    }

    init(
        defaults: UserDefaults = .standard,
        storageKey: String =
            "cli_pulse_provider_account_deletion_outbox_v1"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    var hasCorruptStorage: Bool {
        if case .corrupt = loadState() {
            preserveCorruptStorage()
            return true
        }
        return false
    }

    @discardableResult
    func enqueue(
        userID: String,
        accountID: UUID,
        provider: ProviderKind
    ) -> Bool {
        guard let owner = normalizedUserID(userID) else {
            return false
        }
        guard case var .valid(records) =
            loadStateTreatingMissingAsEmpty()
        else {
            preserveCorruptStorage()
            return false
        }
        records = Set(records.filter {
            $0.userID != owner || $0.accountID != accountID
        })
        let intent = Intent(
            userID: owner,
            accountID: accountID,
            provider: provider
        )
        records.insert(
            intent
        )
        guard saveRecords(records) else { return false }
        guard case let .valid(saved) = loadState() else {
            return false
        }
        return saved.contains(intent)
    }

    func pendingAccountIDs(for userID: String) -> [UUID] {
        guard let owner = normalizedUserID(userID) else { return [] }
        return readableRecords()
            .filter { $0.userID == owner }
            .map(\.accountID)
            .sorted { $0.uuidString < $1.uuidString }
    }

    func pendingIntents() -> [Intent] {
        readableRecords().sorted(by: Self.recordOrder)
    }

    func pendingIntents(for userID: String) -> [Intent] {
        guard let owner = normalizedUserID(userID) else { return [] }
        return readableRecords()
            .filter { $0.userID == owner }
            .sorted(by: Self.recordOrder)
    }

    @discardableResult
    func markCompleted(_ completedIntent: Intent) -> Bool {
        guard
            let owner = normalizedUserID(completedIntent.userID)
        else {
            return false
        }
        guard case var .valid(records) =
            loadStateTreatingMissingAsEmpty()
        else {
            preserveCorruptStorage()
            return false
        }
        records.remove(
            Intent(
                userID: owner,
                accountID: completedIntent.accountID,
                provider: completedIntent.provider,
                generation: completedIntent.generation
            )
        )
        return saveRecords(records)
    }

    private func normalizedUserID(_ value: String) -> String? {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private func readableRecords() -> Set<Intent> {
        switch loadState() {
        case .missing:
            return []
        case .valid(let records):
            return records
        case .corrupt:
            preserveCorruptStorage()
            return []
        }
    }

    private func loadStateTreatingMissingAsEmpty()
        -> LoadState
    {
        switch loadState() {
        case .missing:
            return .valid([])
        case .valid(let records):
            return .valid(records)
        case .corrupt:
            return .corrupt
        }
    }

    private func loadState() -> LoadState {
        guard defaults.object(forKey: storageKey) != nil else {
            return .missing
        }
        guard let data = defaults.data(forKey: storageKey) else {
            return .corrupt
        }
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(
            Envelope.self,
            from: data
        ) {
            guard envelope.version == 1 else {
                return .corrupt
            }
            return .valid(Set(envelope.intents))
        }
        // Backward compatibility for the unreleased v1 array/set payload.
        if let records = try? decoder.decode(
            Set<Intent>.self,
            from: data
        ) {
            return .valid(records)
        }
        if let records = try? decoder.decode(
            [Intent].self,
            from: data
        ) {
            return .valid(Set(records))
        }
        return .corrupt
    }

    private func preserveCorruptStorage() {
        guard defaults.object(forKey: corruptBackupKey) == nil else {
            return
        }
        if let data = defaults.data(forKey: storageKey) {
            defaults.set(data, forKey: corruptBackupKey)
        } else if let value = defaults.object(forKey: storageKey) {
            defaults.set(
                Data(String(describing: value).utf8),
                forKey: corruptBackupKey
            )
        }
    }

    @discardableResult
    private func saveRecords(_ records: Set<Intent>) -> Bool {
        guard !records.isEmpty else {
            defaults.removeObject(forKey: storageKey)
            return defaults.object(forKey: storageKey) == nil
        }
        let ordered = records.sorted(by: Self.recordOrder)
        guard let data = try? JSONEncoder().encode(
            Envelope(version: 1, intents: ordered)
        ) else {
            return false
        }
        defaults.set(data, forKey: storageKey)
        guard case let .valid(saved) = loadState() else {
            return false
        }
        return saved == records
    }

    private static func recordOrder(
        _ lhs: Intent,
        _ rhs: Intent
    ) -> Bool {
        if lhs.userID != rhs.userID {
            return lhs.userID < rhs.userID
        }
        if lhs.accountID != rhs.accountID {
            return lhs.accountID.uuidString
                < rhs.accountID.uuidString
        }
        if lhs.provider != rhs.provider {
            return (lhs.provider?.rawValue ?? "")
                < (rhs.provider?.rawValue ?? "")
        }
        return (lhs.generation?.uuidString ?? "")
            < (rhs.generation?.uuidString ?? "")
    }
}

enum ProviderAccountDeletionRecovery {
    static func accountIDsToRemove(
        from configs: [ProviderConfig],
        pending: [ProviderAccountDeletionOutbox.Intent]
    ) -> [UUID] {
        var configByAccount: [UUID: ProviderConfig] = [:]
        for config in configs {
            configByAccount[config.accountID] = config
        }
        return pending.compactMap { intent in
            guard
                let config = configByAccount[intent.accountID],
                ProviderAccountSyncOwnership.normalizedUserID(
                    config.syncOwnerUserID
                ) == ProviderAccountSyncOwnership
                    .normalizedUserID(intent.userID),
                intent.provider == nil
                    || intent.provider == config.kind
            else {
                return nil
            }
            return intent.accountID
        }
        .sorted { $0.uuidString < $1.uuidString }
    }
}
