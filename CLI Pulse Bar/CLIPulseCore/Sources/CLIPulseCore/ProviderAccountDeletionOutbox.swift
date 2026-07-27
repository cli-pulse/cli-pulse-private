import Foundation

/// Durable, credential-free retry queue for account rows that were removed
/// locally before Supabase confirmed their deletion. Every entry is scoped to
/// the authenticated CLIPulse user so an account switch can never replay user
/// A's deletion under user B's session.
@MainActor
final class ProviderAccountDeletionOutbox {
    static let shared = ProviderAccountDeletionOutbox()

    private struct Record: Codable, Hashable {
        let userID: String
        let accountID: UUID
    }

    private let defaults: UserDefaults
    private let storageKey: String

    init(
        defaults: UserDefaults = .standard,
        storageKey: String =
            "cli_pulse_provider_account_deletion_outbox_v1"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    func enqueue(userID: String, accountID: UUID) {
        guard let owner = normalizedUserID(userID) else { return }
        var records = loadRecords()
        records.insert(
            Record(userID: owner, accountID: accountID)
        )
        saveRecords(records)
    }

    func pendingAccountIDs(for userID: String) -> [UUID] {
        guard let owner = normalizedUserID(userID) else { return [] }
        return loadRecords()
            .filter { $0.userID == owner }
            .map(\.accountID)
            .sorted { $0.uuidString < $1.uuidString }
    }

    func markCompleted(userID: String, accountID: UUID) {
        guard let owner = normalizedUserID(userID) else { return }
        var records = loadRecords()
        records.remove(
            Record(userID: owner, accountID: accountID)
        )
        saveRecords(records)
    }

    private func normalizedUserID(_ value: String) -> String? {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private func loadRecords() -> Set<Record> {
        guard
            let data = defaults.data(forKey: storageKey),
            let records = try? JSONDecoder().decode(
                Set<Record>.self,
                from: data
            )
        else {
            return []
        }
        return records
    }

    private func saveRecords(_ records: Set<Record>) {
        guard !records.isEmpty else {
            defaults.removeObject(forKey: storageKey)
            return
        }
        let ordered = records.sorted(by: Self.recordOrder)
        guard let data = try? JSONEncoder().encode(ordered) else {
            return
        }
        defaults.set(data, forKey: storageKey)
    }

    private static func recordOrder(
        _ lhs: Record,
        _ rhs: Record
    ) -> Bool {
        if lhs.userID != rhs.userID {
            return lhs.userID < rhs.userID
        }
        return lhs.accountID.uuidString < rhs.accountID.uuidString
    }
}
