import Foundation
import Combine

/// v1.10 P2-3 slice 5: final P2-3 extraction. Provider-related observable
/// state lives here so the Providers tab, Overview tab, Settings → Providers
/// section, and provider-config editor re-render on provider changes only,
/// instead of on every unrelated `AppState` mutation.
///
/// `AppState` still owns the canonical instance (`public let providerState`)
/// and exposes the 5 fields as computed forwarders so internal callers
/// (`DataRefreshManager` inside `extension AppState`, `DemoDataProvider`,
/// `setProviderEnabled`, `toggleProvider`, etc.) keep mutating through
/// implicit `self`.
///
/// The MenuBarLabel view must also observe this state — `menuBarIcon` reads
/// `mostUsedProvider` which in turn reads `providers` and
/// `enabledProviderNames` (computed from `providerConfigs`). Without the
/// observer, the menu-bar icon wouldn't refresh when a provider's usage
/// changes.
@MainActor
public final class ProviderState: ObservableObject {
    @Published public var providers: [ProviderUsage] = []
    @Published public var providerAccounts: [ProviderAccountUsage] = []
    @Published public var providerConfigs: [ProviderConfig] = ProviderConfig.defaults()
    @Published public var providerDetails: [ProviderDetail] = []
    @Published public var costSummary: CostSummary = CostSummary()
    /// Stable account targeted by the standalone "Provider Settings" window.
    /// Provider kind is not unique once one agent can have multiple accounts,
    /// so every caller must route the account UUID end to end.
    @Published public var editingProviderAccountID: UUID?
    @Published public private(set) var draftProviderAccountIDs: Set<UUID> = []

    public init() {}

    /// Convenience derived from `providerConfigs`. Mirrors
    /// `AppState.enabledProviderNames` so callers that observe `ProviderState`
    /// directly don't have to route through `AppState.objectWillChange`
    /// (which would no longer fire for `providerConfigs` changes after the
    /// P2-3 slice 5 extraction).
    public var enabledProviderNames: Set<String> {
        Set(providerConfigs.filter(\.isEnabled).map(\.kind.rawValue))
    }

    /// Number of loaded provider kinds currently monitored. Multiple usage
    /// rows or enabled accounts for one provider still represent one tracked
    /// provider; default-enabled configs without a loaded row do not.
    public var enabledProviderCount: Int {
        let enabledNames = enabledProviderNames
        return Set(
            providers
                .map(\.provider)
                .filter(enabledNames.contains)
        ).count
    }

    public var editingProviderConfig: ProviderConfig? {
        guard let editingProviderAccountID else { return nil }
        return providerConfigs.first {
            $0.accountID == editingProviderAccountID
        }
    }

    public func configs(for kind: ProviderKind) -> [ProviderConfig] {
        providerConfigs
            .filter { $0.kind == kind }
            .sorted {
                if $0.sortOrder != $1.sortOrder {
                    return $0.sortOrder < $1.sortOrder
                }
                return $0.accountID.uuidString
                    < $1.accountID.uuidString
            }
    }

    /// Creates a disabled account draft with a stable UUID. The caller opens
    /// the credential editor explicitly and decides when monitoring is enabled.
    @discardableResult
    public func addProviderAccount(
        kind: ProviderKind,
        accountID: UUID = UUID(),
        syncOwnerUserID: String? = nil
    ) -> UUID {
        guard !providerConfigs.contains(where: {
            $0.accountID == accountID
        }) else {
            return accountID
        }

        let nextSortOrder =
            (providerConfigs.map(\.sortOrder).max() ?? -1) + 1
        providerConfigs.append(
            ProviderConfig(
                kind: kind,
                accountID: accountID,
                isEnabled: false,
                sortOrder: nextSortOrder,
                syncOwnerUserID: syncOwnerUserID
            )
        )
        draftProviderAccountIDs.insert(accountID)
        return accountID
    }

    @discardableResult
    public func commitProviderAccountDraft(
        _ accountID: UUID
    ) -> Bool {
        draftProviderAccountIDs.remove(accountID) != nil
    }

    public func isProviderAccountDraft(
        _ accountID: UUID
    ) -> Bool {
        draftProviderAccountIDs.contains(accountID)
    }

    /// Cancels only an account created by the current unsaved Add Account
    /// flow. Existing accounts are never removed by editor cancellation.
    @discardableResult
    public func cancelProviderAccountDraft(
        _ accountID: UUID
    ) -> Bool {
        guard draftProviderAccountIDs.remove(accountID) != nil else {
            return false
        }
        _ = removeProviderAccount(accountID)
        return true
    }

    /// Returns false only when the UUID is unknown. Other accounts of the
    /// same provider are never touched.
    @discardableResult
    public func setProviderAccountEnabled(
        _ accountID: UUID,
        isEnabled: Bool
    ) -> Bool {
        guard let index = providerConfigs.firstIndex(where: {
            $0.accountID == accountID
        }) else {
            return false
        }
        providerConfigs[index].isEnabled = isEnabled
        return true
    }

    /// Removes one exact account from in-memory configuration and normalized
    /// account usage. Secret deletion and metadata persistence are explicit
    /// AppState responsibilities so they can remain narrowly scoped.
    @discardableResult
    public func removeProviderAccount(
        _ accountID: UUID
    ) -> ProviderConfig? {
        guard let index = providerConfigs.firstIndex(where: {
            $0.accountID == accountID
        }) else {
            return nil
        }

        let removed = providerConfigs.remove(at: index)
        draftProviderAccountIDs.remove(accountID)
        providerAccounts.removeAll { $0.id == accountID }
        if editingProviderAccountID == accountID {
            editingProviderAccountID = nil
        }
        return removed
    }

    /// Lowest remaining ratio across an account's valid quota windows.
    /// Unknown windows remain unknown instead of being treated as full or
    /// empty.
    public nonisolated static func remainingFraction(
        for account: ProviderAccountUsage
    ) -> Double? {
        var fractions = account.tiers.compactMap { tier -> Double? in
            guard tier.quota > 0 else { return nil }
            return boundedRemainingFraction(
                remaining: tier.remaining,
                quota: tier.quota
            )
        }
        if let quota = account.quota,
           quota > 0,
           let remaining = account.remaining {
            fractions.append(
                boundedRemainingFraction(
                    remaining: remaining,
                    quota: quota
                )
            )
        }
        return fractions.min()
    }

    public nonisolated static func mostConstrainedAccount(
        in accounts: [ProviderAccountUsage]
    ) -> ProviderAccountUsage? {
        accounts.compactMap { account in
            remainingFraction(for: account).map {
                (account: account, fraction: $0)
            }
        }
        .min {
            if $0.fraction != $1.fraction {
                return $0.fraction < $1.fraction
            }
            return $0.account.id.uuidString
                < $1.account.id.uuidString
        }?
        .account
    }

    public nonisolated static func mostConstrainedAccount(
        in accounts: [ProviderAccountUsage],
        enabledAccountIDs: Set<UUID>
    ) -> ProviderAccountUsage? {
        mostConstrainedAccount(
            in: accounts.filter {
                enabledAccountIDs.contains($0.id)
            }
        )
    }

    private nonisolated static func boundedRemainingFraction(
        remaining: Int,
        quota: Int
    ) -> Double {
        min(
            max(Double(remaining) / Double(quota), 0),
            1
        )
    }
}
