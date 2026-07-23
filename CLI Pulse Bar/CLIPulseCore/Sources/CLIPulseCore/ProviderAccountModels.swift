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
