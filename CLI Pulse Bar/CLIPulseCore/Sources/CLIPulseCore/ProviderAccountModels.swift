import Foundation

public enum PlanEvidenceSource: String, Codable, Sendable {
    case providerAPI
    case accountMetadata
    case localCredential
    case webFallback
    case userConfirmed
    case unknown
}

public enum DetectionConfidence: String, Codable, Sendable {
    case high
    case medium
    case low
    case unavailable
}

public struct ProviderPlanEvidence: Codable, Equatable, Sendable {
    public let rawValue: String?
    public let displayValue: String?
    public let source: PlanEvidenceSource
    public let confidence: DetectionConfidence
    public let observedAt: Date?

    public init(
        rawValue: String?,
        displayValue: String?,
        source: PlanEvidenceSource,
        confidence: DetectionConfidence,
        observedAt: Date?
    ) {
        self.rawValue = rawValue
        self.displayValue = displayValue
        self.source = source
        self.confidence = confidence
        self.observedAt = observedAt
    }
}

/// Privacy boundary for values promoted from heterogeneous collector output
/// into cloud-visible provider-account metadata. Some legacy collectors use an
/// external account email or resource hostname as `plan_type`; those values
/// may remain useful locally but are not reviewed plan evidence and must not be
/// uploaded by default.
public enum ProviderAccountCloudPrivacy {
    /// Mirrors the database `char_length(...) <= 120` contract. Keeping the
    /// check here prevents one oversized local label or collector value from
    /// rejecting the entire account-sync batch.
    private static let maxCloudTextCharacters = 120
    private static let maxCloudTiers = 24

    /// Account labels are user-authored metadata, so they may be uploaded
    /// when they fit the reviewed cloud schema. Oversized labels remain local
    /// instead of being silently truncated to a different identifier.
    public static func reviewedAccountLabel(
        _ value: String?
    ) -> String? {
        reviewedBoundedText(value)
    }

    public static func reviewedPlanType(
        _ value: String?
    ) -> String? {
        guard let trimmed = reviewedBoundedText(value) else {
            return nil
        }
        guard
            !containsEmailShapedIdentifier(trimmed),
            !containsHostShapedIdentifier(trimmed)
        else {
            return nil
        }
        return trimmed
    }

    /// Mirrors the server's per-account tier count and name bounds. Invalid
    /// collector labels stay local; valid windows retain their original order
    /// so the provider's primary/secondary ordering remains deterministic.
    public static func reviewedTiers(
        _ tiers: [TierDTO]
    ) -> [TierDTO] {
        Array(
            tiers.lazy.compactMap { tier -> TierDTO? in
                guard
                    let name = reviewedBoundedText(
                        tier.name
                    ),
                    tier.quota >= 0,
                    tier.remaining >= 0
                else {
                    return nil
                }
                return TierDTO(
                    name: name,
                    quota: tier.quota,
                    remaining: tier.remaining,
                    reset_time:
                        reviewedTimestamp(
                            tier.reset_time
                        ),
                    windowMinutes:
                        tier.windowMinutes.flatMap {
                            $0 >= 0 ? $0 : nil
                        },
                    role: tier.role
                )
            }
            .prefix(maxCloudTiers)
        )
    }

    public static func reviewedNonNegativeValue(
        _ value: Int?
    ) -> Int? {
        guard let value, value >= 0 else { return nil }
        return value
    }

    public static func reviewedTimestamp(
        _ value: String?
    ) -> String? {
        guard
            let value,
            sharedISO8601Parse(value) != nil
        else {
            return nil
        }
        return value
    }

    private static func reviewedBoundedText(
        _ value: String?
    ) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard
            !trimmed.isEmpty,
            trimmed.unicodeScalars.count
                <= maxCloudTextCharacters
        else {
            return nil
        }
        return trimmed
    }

    private static func containsEmailShapedIdentifier(
        _ value: String
    ) -> Bool {
        for index in value.indices where value[index] == "@" {
            guard
                index != value.startIndex,
                value.index(after: index) != value.endIndex
            else {
                continue
            }
            let before = value[value.index(before: index)]
            let after = value[value.index(after: index)]
            if !before.isWhitespace && !after.isWhitespace {
                return true
            }
        }
        return false
    }

    private static func containsHostShapedIdentifier(
        _ value: String
    ) -> Bool {
        if value.contains("://") {
            return true
        }
        guard !value.contains(where: \.isWhitespace) else {
            return false
        }

        let segments = value.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard segments.count >= 2 else { return false }

        let isIPv4 = segments.count == 4
            && segments.allSatisfy {
                guard let octet = Int($0) else { return false }
                return (0...255).contains(octet)
            }
        if isIPv4 { return true }

        guard
            let suffix = segments.last,
            (2...24).contains(suffix.count),
            suffix.allSatisfy(\.isLetter)
        else {
            return false
        }
        return segments.allSatisfy { segment in
            !segment.isEmpty
                && segment.allSatisfy {
                    $0.isLetter || $0.isNumber || $0 == "-"
                }
        }
    }
}

public struct ProviderAccountUsage: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let provider: ProviderKind
    public let accountLabel: String?
    public let planEvidence: ProviderPlanEvidence
    public let quota: Int?
    public let remaining: Int?
    public let tiers: [TierDTO]
    public let resetTime: String?
    public let observedAt: String?
    public let sourceDeviceID: UUID?
    public let statusText: String

    public init(
        id: UUID,
        provider: ProviderKind,
        accountLabel: String?,
        planEvidence: ProviderPlanEvidence,
        quota: Int?,
        remaining: Int?,
        tiers: [TierDTO],
        resetTime: String?,
        observedAt: String?,
        sourceDeviceID: UUID?,
        statusText: String
    ) {
        self.id = id
        self.provider = provider
        self.accountLabel = accountLabel
        self.planEvidence = planEvidence
        self.quota = quota
        self.remaining = remaining
        self.tiers = tiers
        self.resetTime = resetTime
        self.observedAt = observedAt
        self.sourceDeviceID = sourceDeviceID
        self.statusText = statusText
    }
}
