import Foundation

/// Inter-process communication constants between the main app and the Login Item helper.
/// Both processes share the `group.yyh.CLI-Pulse` app group.
public enum HelperIPC {

    // MARK: - DistributedNotificationCenter names

    /// Posted by the helper after refreshing local collector data and after sync-capable cycles.
    /// The main app can observe this to trigger an immediate refresh.
    /// Note: treat as a hint — always validate data freshness from app group files.
    public static let didSyncNotificationName = Notification.Name("CLIPulseHelperDidSync")

    /// Posted by the helper when it starts up.
    public static let didStartNotificationName = Notification.Name("CLIPulseHelperDidStart")

    // MARK: - Shared UserDefaults keys (suite: group.yyh.CLI-Pulse)

    public static let suiteName = "group.yyh.CLI-Pulse"

    /// Helper status JSON: { "state": "running"|"idle"|"error", "lastSync": ISO8601, "error": "..." }
    public static let statusKey = "helper_status"

    /// Helper config (HelperConfig encoded as JSON data)
    public static let configKey = "helper_config"

    /// Provider configs (array of ProviderConfig, written by main app for helper to read)
    public static let providerConfigsKey = "helper_provider_configs"

    /// Sync interval in seconds (Int, written by main app, read by helper)
    public static let syncIntervalKey = "helper_sync_interval"

    /// Collector results JSON (written by helper after each collection cycle, read by main app).
    /// v1 was a JSON dictionary keyed by provider name. v2 is a versioned,
    /// account-array envelope with an optional v1 provider projection.
    public static let collectorResultsKey = "helper_collector_results"

    // MARK: - Collector results wire contract

    public enum CollectorDataKind: String, Codable, Equatable, Sendable {
        case quota
        case credits
        case statusOnly
    }

    /// The collector's capability declaration, preserved across the helper
    /// boundary instead of being guessed by the main app.
    public struct CollectorMetadataPayload: Codable, Equatable, Sendable {
        public let displayName: String
        public let category: String
        public let supportsExactCost: Bool
        public let supportsQuota: Bool
        public let defaultQuota: Int?

        private enum CodingKeys: String, CodingKey {
            case category
            case displayName = "display_name"
            case supportsExactCost = "supports_exact_cost"
            case supportsQuota = "supports_quota"
            case defaultQuota = "default_quota"
        }

        public init(
            displayName: String,
            category: String,
            supportsExactCost: Bool,
            supportsQuota: Bool,
            defaultQuota: Int?
        ) {
            self.displayName = displayName
            self.category = category
            self.supportsExactCost = supportsExactCost
            self.supportsQuota = supportsQuota
            self.defaultQuota = defaultQuota
        }

        public init(_ metadata: ProviderMetadata) {
            self.init(
                displayName: metadata.display_name,
                category: metadata.category,
                supportsExactCost: metadata.supports_exact_cost,
                supportsQuota: metadata.supports_quota,
                defaultQuota: metadata.default_quota
            )
        }

        public var providerMetadata: ProviderMetadata {
            ProviderMetadata(
                display_name: displayName,
                category: category,
                supports_exact_cost: supportsExactCost,
                supports_quota: supportsQuota,
                default_quota: defaultQuota
            )
        }
    }

    /// Secret-free usage data shared across the helper boundary.
    public struct CollectorUsagePayload: Codable, Equatable, Sendable {
        public let quota: Int?
        public let remaining: Int?
        public let todayUsage: Int?
        public let weekUsage: Int?
        public let statusText: String?
        public let planType: String?
        public let resetTime: String?
        public let tiers: [TierDTO]?
        public let metadata: CollectorMetadataPayload?

        private enum CodingKeys: String, CodingKey {
            case quota, remaining, tiers, metadata
            case todayUsage = "today_usage"
            case weekUsage = "week_usage"
            case statusText = "status_text"
            case planType = "plan_type"
            case resetTime = "reset_time"
        }

        public init(
            quota: Int?,
            remaining: Int?,
            todayUsage: Int?,
            weekUsage: Int?,
            statusText: String?,
            planType: String?,
            resetTime: String?,
            tiers: [TierDTO]?,
            metadata: CollectorMetadataPayload? = nil
        ) {
            self.quota = quota
            self.remaining = remaining
            self.todayUsage = todayUsage
            self.weekUsage = weekUsage
            self.statusText = statusText
            self.planType = planType
            self.resetTime = resetTime
            self.tiers = tiers
            self.metadata = metadata
        }
    }

    public struct CollectorAccountPayload: Codable, Equatable, Sendable {
        public let accountID: UUID
        public let provider: String
        public let accountLabel: String?
        public let dataKind: CollectorDataKind
        public let usage: CollectorUsagePayload

        private enum CodingKeys: String, CodingKey {
            case accountID = "account_id"
            case provider
            case accountLabel = "account_label"
            case dataKind = "data_kind"
            case usage
        }

        public init(
            accountID: UUID,
            provider: String,
            accountLabel: String?,
            dataKind: CollectorDataKind,
            usage: CollectorUsagePayload
        ) {
            self.accountID = accountID
            self.provider = provider
            self.accountLabel = accountLabel
            self.dataKind = dataKind
            self.usage = usage
        }
    }

    public struct CollectorResultsEnvelopeV1: Codable, Equatable, Sendable {
        public let timestamp: String?
        public let providers: [String: CollectorUsagePayload]

        public init(timestamp: String?, providers: [String: CollectorUsagePayload]) {
            self.timestamp = timestamp
            self.providers = providers
        }
    }

    public struct CollectorResultsEnvelopeV2: Codable, Equatable, Sendable {
        public let version: Int
        public let timestamp: String
        public let accounts: [CollectorAccountPayload]
        /// Kept during the compatibility window so a v1 main app paired with
        /// a v2 helper can still read one row per provider.
        public let providers: [String: CollectorUsagePayload]?

        public init(
            version: Int = 2,
            timestamp: String,
            accounts: [CollectorAccountPayload],
            providers: [String: CollectorUsagePayload]?
        ) {
            self.version = version
            self.timestamp = timestamp
            self.accounts = accounts
            self.providers = providers
        }
    }

    public enum DecodedCollectorResults: Sendable {
        case v1(CollectorResultsEnvelopeV1)
        case v2(CollectorResultsEnvelopeV2)
    }

    public enum CollectorResultsError: Error, Equatable {
        case unsupportedVersion(Int)
        case invalidTimestamp
        case stale
    }

    private struct CollectorResultsVersionProbe: Decodable {
        let version: Int?
    }

    public static func encodeCollectorResultsV2(
        _ envelope: CollectorResultsEnvelopeV2
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(envelope)
    }

    /// Decode both the typed v2 envelope and both historical v1 shapes:
    /// `{timestamp, providers}` and the older unwrapped provider dictionary.
    public static func decodeCollectorResults(
        _ data: Data,
        now: Date = Date(),
        maxAge: TimeInterval = 300
    ) throws -> DecodedCollectorResults {
        let decoder = JSONDecoder()
        let probe = try decoder.decode(CollectorResultsVersionProbe.self, from: data)

        if let version = probe.version {
            guard version == 2 else {
                throw CollectorResultsError.unsupportedVersion(version)
            }
            let envelope = try decoder.decode(CollectorResultsEnvelopeV2.self, from: data)
            guard let timestamp = sharedISO8601Formatter.date(from: envelope.timestamp) else {
                throw CollectorResultsError.invalidTimestamp
            }
            guard now.timeIntervalSince(timestamp) <= maxAge else {
                throw CollectorResultsError.stale
            }
            return .v2(envelope)
        }

        if let envelope = try? decoder.decode(CollectorResultsEnvelopeV1.self, from: data) {
            if let timestampString = envelope.timestamp {
                guard let timestamp = sharedISO8601Formatter.date(from: timestampString) else {
                    throw CollectorResultsError.invalidTimestamp
                }
                guard now.timeIntervalSince(timestamp) <= maxAge else {
                    throw CollectorResultsError.stale
                }
            }
            return .v1(envelope)
        }

        let providers = try decoder.decode([String: CollectorUsagePayload].self, from: data)
        return .v1(CollectorResultsEnvelopeV1(timestamp: nil, providers: providers))
    }

    /// Write collector results to app group for the main app to read.
    public static func writeCollectorResults(_ json: Data) {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        defaults.set(json, forKey: collectorResultsKey)
        // No deprecated `synchronize()` — the system coalesces the
        // cross-process flush; the explicit sync flush only added a blocking
        // cfprefsd XPC round-trip.
    }

    /// Read collector results written by helper.
    public static func readCollectorResults() -> Data? {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return nil }
        return defaults.data(forKey: collectorResultsKey)
    }

    // MARK: - Status

    public enum State: String, Codable, Sendable {
        case running
        case idle
        case error
    }

    public struct Status: Codable, Sendable {
        public let state: State
        public let lastSync: Date?
        public let error: String?
        public let helperVersion: String?

        public init(state: State, lastSync: Date? = nil, error: String? = nil, helperVersion: String? = nil) {
            self.state = state
            self.lastSync = lastSync
            self.error = error
            self.helperVersion = helperVersion
        }
    }

    /// Read helper status from shared UserDefaults.
    public static func readStatus() -> Status? {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = defaults.data(forKey: statusKey) else { return nil }
        return try? JSONDecoder().decode(Status.self, from: data)
    }

    /// Write helper status to shared UserDefaults.
    public static func writeStatus(_ status: Status) {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = try? JSONEncoder().encode(status) else { return }
        defaults.set(data, forKey: statusKey)
        // No deprecated `synchronize()` — see writeCollectorResults.
    }

    /// Post a sync notification via DistributedNotificationCenter.
    #if os(macOS)
    public static func postSyncNotification() {
        DistributedNotificationCenter.default().postNotificationName(
            didSyncNotificationName, object: nil, userInfo: nil,
            deliverImmediately: true
        )
    }

    public static func postStartNotification() {
        DistributedNotificationCenter.default().postNotificationName(
            didStartNotificationName, object: nil, userInfo: nil,
            deliverImmediately: true
        )
    }
    #endif
}
