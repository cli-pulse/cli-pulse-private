import Foundation

/// Provider-first grouping shared by compact clients such as iPhone, iPad,
/// and Apple Watch. Account snapshots are already credential-free, so this
/// type contains presentation order only and never local ProviderConfig data.
public struct ProviderAccountGroup:
    Equatable,
    Identifiable,
    Sendable
{
    public let provider: ProviderKind
    public let accounts: [ProviderAccountUsage]

    public var id: String { provider.rawValue }

    public init(
        provider: ProviderKind,
        accounts: [ProviderAccountUsage]
    ) {
        self.provider = provider
        self.accounts = accounts
    }
}

public enum ProviderAccountPresentation {
    /// Two normal 120-second refresh cycles plus one minute of tolerance.
    /// Compact clients must stop implying real-time quota after this window.
    public static let staleAfter: TimeInterval = 5 * 60

    /// Groups cloud/local account snapshots by provider using the product's
    /// canonical provider order. Named accounts sort first; unnamed accounts
    /// use their stable UUID as the deterministic fallback.
    public static func groups(
        _ accounts: [ProviderAccountUsage]
    ) -> [ProviderAccountGroup] {
        let providerOrder = Dictionary(
            uniqueKeysWithValues:
                ProviderKind.allCases.enumerated().map {
                    ($0.element, $0.offset)
                }
        )

        return Dictionary(grouping: accounts, by: \.provider)
            .map { provider, groupedAccounts in
                ProviderAccountGroup(
                    provider: provider,
                    accounts: groupedAccounts.sorted(
                        by: accountComesBefore
                    )
                )
            }
            .sorted { lhs, rhs in
                let lhsOrder = providerOrder[lhs.provider] ?? .max
                let rhsOrder = providerOrder[rhs.provider] ?? .max
                if lhsOrder != rhsOrder {
                    return lhsOrder < rhsOrder
                }
                return lhs.provider.rawValue
                    < rhs.provider.rawValue
            }
    }

    /// Account groups that do not already have a provider-level card.
    /// Compact clients use this for partial cloud snapshots so account data
    /// remains visible even when the aggregate provider row is unavailable.
    public static func groups(
        _ accounts: [ProviderAccountUsage],
        excluding representedProviders: Set<ProviderKind>
    ) -> [ProviderAccountGroup] {
        groups(accounts).filter {
            !representedProviders.contains($0.provider)
        }
    }

    /// Cloud summaries can include disabled rows for management surfaces.
    /// Read-only glance clients show active rows only.
    public static func enabledAccounts(
        _ accounts: [ProviderAccountUsage]
    ) -> [ProviderAccountUsage] {
        accounts.filter { account in
            account.statusText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare("disabled")
                != .orderedSame
        }
    }

    public static func enabledGroups(
        _ accounts: [ProviderAccountUsage]
    ) -> [ProviderAccountGroup] {
        groups(enabledAccounts(accounts))
    }

    /// Legacy summaries have no account rows, so their provider names remain
    /// visible. Once v2 is active, visibility is derived only from enabled
    /// account groups; an all-disabled provider must not be revived by its
    /// aggregate compatibility row.
    public static func visibleProviderNames(
        accounts: [ProviderAccountUsage],
        legacyProviderNames: [String],
        usesLegacyFallback: Bool
    ) -> Set<String> {
        if usesLegacyFallback {
            return Set(legacyProviderNames)
        }
        return Set(
            enabledGroups(accounts).map(\.provider.rawValue)
        )
    }

    public static func mostConstrainedEnabledAccount(
        in accounts: [ProviderAccountUsage]
    ) -> ProviderAccountUsage? {
        ProviderState.mostConstrainedAccount(
            in: enabledAccounts(accounts)
        )
    }

    /// Quota freshness is the primary timestamp shown to mobile clients.
    /// Plan evidence is a useful fallback for older partial rows.
    public static func freshnessTimestamp(
        for account: ProviderAccountUsage
    ) -> String? {
        if let observedAt = normalized(account.observedAt) {
            return observedAt
        }
        return account.planEvidence.observedAt.map {
            sharedISO8601Formatter.string(from: $0)
        }
    }

    public static func latestFreshnessTimestamp(
        in accounts: [ProviderAccountUsage]
    ) -> String? {
        let timestamps = accounts.compactMap(
            freshnessTimestamp(for:)
        )
        let newest = timestamps.compactMap { timestamp in
            sharedISO8601Parse(timestamp).map {
                (timestamp: timestamp, date: $0)
            }
        }
        .max { $0.date < $1.date }
        return newest?.timestamp ?? timestamps.first
    }

    /// Missing or malformed observation time is stale by definition: a
    /// compact client cannot honestly present that snapshot as current.
    public static func isStale(
        _ account: ProviderAccountUsage,
        now: Date = Date(),
        staleAfter interval: TimeInterval = staleAfter
    ) -> Bool {
        guard
            let timestamp = freshnessTimestamp(for: account),
            let observedAt = sharedISO8601Parse(timestamp)
        else {
            return true
        }
        return now.timeIntervalSince(observedAt) > max(0, interval)
    }

    private static func accountComesBefore(
        _ lhs: ProviderAccountUsage,
        _ rhs: ProviderAccountUsage
    ) -> Bool {
        let lhsLabel = normalized(lhs.accountLabel)
        let rhsLabel = normalized(rhs.accountLabel)

        switch (lhsLabel, rhsLabel) {
        case let (lhsLabel?, rhsLabel?):
            let comparison = lhsLabel.caseInsensitiveCompare(
                rhsLabel
            )
            if comparison != .orderedSame {
                return comparison == .orderedAscending
            }
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            break
        }

        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func normalized(
        _ value: String?
    ) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return trimmed.isEmpty ? nil : trimmed
    }
}
