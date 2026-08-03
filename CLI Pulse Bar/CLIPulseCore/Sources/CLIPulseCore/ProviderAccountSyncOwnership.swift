import Foundation

/// Cloud-write ownership for local provider account metadata. Provider
/// credentials remain machine-local, but account labels and quota snapshots
/// must never be uploaded through a different CLIPulse/Supabase identity.
public enum ProviderAccountSyncOwnership {
    public static func normalizedUserID(
        _ value: String?
    ) -> String? {
        guard let value else { return nil }
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    /// First authenticated owner claims legacy/unowned configs exactly once.
    /// Existing ownership is terminal until a future explicit migration UI
    /// makes reassignment a deliberate user action.
    @discardableResult
    public static func bindUnowned(
        configs: inout [ProviderConfig],
        to userID: String
    ) -> Bool {
        guard let owner = normalizedUserID(userID) else {
            return false
        }
        var changed = false
        for index in configs.indices where
            normalizedUserID(
                configs[index].syncOwnerUserID
            ) == nil
        {
            configs[index].syncOwnerUserID = owner
            changed = true
        }
        return changed
    }

    public static func accountIDs(
        in configs: [ProviderConfig],
        ownedBy userID: String
    ) -> Set<UUID> {
        guard let owner = normalizedUserID(userID) else {
            return []
        }
        return Set(
            configs.compactMap { config in
                normalizedUserID(config.syncOwnerUserID) == owner
                    ? config.accountID
                    : nil
            }
        )
    }

    public static func ownerForDeletion(
        _ config: ProviderConfig
    ) -> String? {
        normalizedUserID(config.syncOwnerUserID)
    }
}
