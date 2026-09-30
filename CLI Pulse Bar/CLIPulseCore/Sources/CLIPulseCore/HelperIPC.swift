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

    /// Posted by the app when what it tells the helper about collecting
    /// changes: the local-scan answers (`LocalScanConsentStore.mirror`) or
    /// whether the app is signed in (`appSignedOutKey`). The helper runs a
    /// cycle on it, so a "Not now" or a sign-out pauses it, and a yes or a
    /// sign-in resumes it, without waiting for its timer. A hint like the
    /// others: the helper reads the values itself.
    public static let helperInputsDidChangeNotificationName =
        Notification.Name("CLIPulseHelperInputsDidChange")

    // MARK: - Shared UserDefaults keys (suite: group.yyh.CLI-Pulse)

    public static let suiteName = "group.yyh.CLI-Pulse"

    /// Helper status: `Status` encoded with a default `JSONEncoder` —
    /// { "state": "running"|"idle"|"error", "lastSync": Date, "error": English
    /// detail for diagnosis, "errorCode": `HelperSyncFailure` token, "helperVersion",
    /// "deviceId": the paired device the sync ran as }.
    /// The app shows `errorCode`, rendered in its own language, and falls back
    /// to `error` only for a status from a helper that predates `errorCode`.
    public static let statusKey = "helper_status"

    /// Helper config (HelperConfig encoded as JSON data)
    public static let configKey = "helper_config"

    /// Provider configs (array of ProviderConfig, written by main app for helper to read)
    public static let providerConfigsKey = "helper_provider_configs"

    /// Mirrors ProviderAccountFeatureFlags.writeDefaultsKey into the shared
    /// suite so the Login Item helper observes the same staged v2 rollout.
    public static let providerAccountsWriteV2Key =
        "provider_accounts_v2_write"

    /// Sync interval in seconds (Int, written by main app, read by helper)
    public static let syncIntervalKey = "helper_sync_interval"

    /// Collector results JSON (written by helper after each collection cycle, read by main app).
    /// v1 was a JSON dictionary keyed by provider name. v2 is a versioned,
    /// account-array envelope with an optional v1 provider projection.
    public static let collectorResultsKey = "helper_collector_results"

    /// `true` from when the app signs out, or starts with no session, until it
    /// next signs in (Bool, written by the app, read by the helper).
    ///
    /// The helper's pairing (`HelperConfig`) outlives a sign-out: nothing
    /// removes it. Taken alone as "signed in", it kept a signed-out Mac with
    /// no local-scan answer scanning, and every paired Mac uploading to the
    /// account it had signed out of, while the consent screen says signing out
    /// stops the scan and the privacy policy says nothing syncs unless you are
    /// signed in. Missing means the app has not said since this key existed,
    /// and the pairing is trusted as before.
    public static let appSignedOutKey = "cli_pulse_app_signed_out"

    /// Records the app's sign-in state for the helper (`appSignedOutKey`).
    /// - Returns: whether that changed what the helper would read.
    @discardableResult
    public static func recordAppSignedIn(_ signedIn: Bool, to defaults: UserDefaults) -> Bool {
        let signedOut = !signedIn
        let changed = defaults.object(forKey: appSignedOutKey) == nil
            || defaults.bool(forKey: appSignedOutKey) != signedOut
        defaults.set(signedOut, forKey: appSignedOutKey)
        return changed
    }

    /// Whether the app last said it is signed out. False when it has not said.
    public static func isAppSignedOut(_ defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: appSignedOutKey)
    }

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
        public let planOverride: String?
        public let planOverrideUpdatedAt: Date?
        public let planDetectionStartedAt: Date?
        public let dataKind: CollectorDataKind
        public let usage: CollectorUsagePayload

        private enum CodingKeys: String, CodingKey {
            case accountID = "account_id"
            case provider
            case accountLabel = "account_label"
            case planOverride = "plan_override"
            case planOverrideUpdatedAt =
                "plan_override_updated_at"
            case planDetectionStartedAt =
                "plan_detection_started_at"
            case dataKind = "data_kind"
            case usage
        }

        public init(
            accountID: UUID,
            provider: String,
            accountLabel: String?,
            planOverride: String? = nil,
            planOverrideUpdatedAt: Date? = nil,
            planDetectionStartedAt: Date? = nil,
            dataKind: CollectorDataKind,
            usage: CollectorUsagePayload
        ) {
            self.accountID = accountID
            self.provider = provider
            self.accountLabel = accountLabel
            self.planOverride = planOverride
            self.planOverrideUpdatedAt =
                planOverrideUpdatedAt
            self.planDetectionStartedAt =
                planDetectionStartedAt
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
            // v1.50: tolerant parse. This one already failed CLOSED (it
            // throws, so a payload with an unreadable timestamp is dropped
            // rather than trusted) and the current writer emits no fractional
            // seconds — so this is not a live bug. Made tolerant anyway: the
            // helper's other writers DO emit fractional seconds, and the day
            // one of them starts writing this field, the failure would be an
            // entire collector payload vanishing with no error the user sees.
            guard let timestamp = sharedISO8601Parse(envelope.timestamp) else {
                throw CollectorResultsError.invalidTimestamp
            }
            guard now.timeIntervalSince(timestamp) <= maxAge else {
                throw CollectorResultsError.stale
            }
            return .v2(envelope)
        }

        if let envelope = try? decoder.decode(CollectorResultsEnvelopeV1.self, from: data) {
            if let timestampString = envelope.timestamp {
                guard let timestamp = sharedISO8601Parse(timestampString) else {
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

    /// Why a running helper did nothing this cycle (`Status.pauseCode`). A
    /// token, like `errorCode`, so the app words it in its own language.
    public enum PauseCode {
        /// The local-scan answer does not allow reading this Mac
        /// (`LocalCollectionPolicy.HelperCycle.paused`).
        public static let localScanOff = "local_scan_off"
    }

    public struct Status: Codable, Sendable {
        public let state: State
        public let lastSync: Date?
        /// English detail for diagnosis. Helpers from before `errorCode` wrote
        /// display text here instead, formatted in the helper's own language.
        public let error: String?
        public let helperVersion: String?
        /// Stable token from `HelperSyncFailure.code(for:)`; the app renders it in
        /// the user's language. Optional so a status written by an older helper,
        /// which lacks the key, still decodes — and older apps ignore it.
        public let errorCode: String?
        /// The paired device (`HelperConfig.deviceId`) the sync ran as, so the
        /// app can tell a failure of the current pairing from one of the device
        /// it just replaced (`ThisMacPairing`). Nil when there was no pairing to
        /// sync as, and in a status from a helper that predates the field.
        public let deviceId: String?
        /// Set while the helper runs but reads and sends nothing
        /// (`PauseCode`). Optional for the same reason as `errorCode`: a status
        /// from an older helper lacks it, and older apps ignore it.
        public let pauseCode: String?

        public init(
            state: State,
            lastSync: Date? = nil,
            error: String? = nil,
            errorCode: String? = nil,
            helperVersion: String? = nil,
            deviceId: String? = nil,
            pauseCode: String? = nil
        ) {
            self.state = state
            self.lastSync = lastSync
            self.error = error
            self.errorCode = errorCode
            self.helperVersion = helperVersion
            self.deviceId = deviceId
            self.pauseCode = pauseCode
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

    /// Forget the helper's last status. The app calls this when it pairs this
    /// Mac: whatever the helper last wrote was about the pairing just replaced,
    /// and a helper from before `Status.deviceId` cannot say so. Until the
    /// helper's next cycle there is no status, which Settings shows as nothing.
    public static func clearStatus() {
        UserDefaults(suiteName: suiteName)?.removeObject(forKey: statusKey)
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

    public static func postHelperInputsDidChange() {
        DistributedNotificationCenter.default().postNotificationName(
            helperInputsDidChangeNotificationName, object: nil, userInfo: nil,
            deliverImmediately: true
        )
    }
    #endif
}
