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
