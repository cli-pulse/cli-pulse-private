import Foundation

public enum AgentSetupStep:
    String, Codable, CaseIterable, Equatable, Sendable
{
    case welcome
    case privacy
    case discovery
    case review
    case connection
    case syncMode
    case completed
}

/// Why an in-progress V2 flow is allowed to resume. In particular, a stale
/// `.newUser` run must not bypass the non-blocking upgrade prompt after that
/// user later completes the legacy onboarding during a feature-flag rollback.
public enum AgentSetupRunOrigin:
    String, Codable, Equatable, Sendable
{
    case newUser
    case existingUserUpgrade
    case explicitRerun
}

public struct AgentSetupProgress: Codable, Equatable, Sendable {
    public var version: Int
    public var step: AgentSetupStep
    public var selectedAccountIDs: Set<UUID>
    public var completedAt: Date?
    public var origin: AgentSetupRunOrigin?

    public init(
        version: Int,
        step: AgentSetupStep,
        selectedAccountIDs: Set<UUID>,
        completedAt: Date?,
        origin: AgentSetupRunOrigin? = nil
    ) {
        self.version = version
        self.step = step
        self.selectedAccountIDs = selectedAccountIDs
        self.completedAt = completedAt
        self.origin = origin
    }
}

public struct AgentSetupFeatureFlags: Equatable, Sendable {
    public static let newUsersDefaultsKey = "onboarding_v2_new_users"
    public static let existingUsersDefaultsKey =
        "onboarding_v2_existing_users"

    public let newUsersV2: Bool
    public let existingUsersV2: Bool

    public init(
        newUsersV2: Bool,
        existingUsersV2: Bool
    ) {
        self.newUsersV2 = newUsersV2
        self.existingUsersV2 = existingUsersV2
    }

    public static func load(
        from defaults: UserDefaults = .standard
    ) -> AgentSetupFeatureFlags {
        AgentSetupFeatureFlags(
            newUsersV2: defaults.bool(
                forKey: newUsersDefaultsKey
            ),
            existingUsersV2: defaults.bool(
                forKey: existingUsersDefaultsKey
            )
        )
    }
}

public enum AgentSetupRoute: Equatable, Sendable {
    case mainApp
    case legacyOnboarding
    case upgradePrompt
    case v2Onboarding(AgentSetupStep)
}

public struct AgentSetupStoredState: Equatable, Sendable {
    public var legacyCompleted: Bool
    public var onboardingVersion: Int?
    public var progress: AgentSetupProgress?
    public var upgradePromptDismissed: Bool
    /// Version sniffed from the persisted JSON envelope even when a newer
    /// step prevents this client from decoding the full progress payload.
    public var persistedProgressVersion: Int?
    public var progressWasUnreadable: Bool

    public init(
        legacyCompleted: Bool,
        onboardingVersion: Int?,
        progress: AgentSetupProgress?,
        upgradePromptDismissed: Bool,
        persistedProgressVersion: Int? = nil,
        progressWasUnreadable: Bool = false
    ) {
        self.legacyCompleted = legacyCompleted
        self.onboardingVersion = onboardingVersion
        self.progress = progress
        self.upgradePromptDismissed = upgradePromptDismissed
        self.persistedProgressVersion =
            persistedProgressVersion ?? progress?.version
        self.progressWasUnreadable = progressWasUnreadable
    }
}

/// Pure onboarding routing and progress state. It has no SwiftUI, Keychain,
/// Provider secret, process, or network dependency. Persistence is handled by
/// `AgentSetupStateStore`, whose key set is intentionally narrow.
public struct AgentSetupState: Equatable, Sendable {
    public static let currentVersion = 2

    private var storedState: AgentSetupStoredState
    private let featureFlags: AgentSetupFeatureFlags

    public init(
        storedState: AgentSetupStoredState,
        featureFlags: AgentSetupFeatureFlags
    ) {
        self.storedState = storedState
        self.featureFlags = featureFlags
    }

    public var progress: AgentSetupProgress? {
        storedState.progress
    }

    public var persistenceSnapshot: AgentSetupStoredState {
        storedState
    }

    public var route: AgentSetupRoute {
        // A downgraded client must never reinterpret or overwrite progress
        // created by a newer state-machine version.
        if mustPreserveStoredProgress {
            return .mainApp
        }

        if let progress = validProgress,
           progress.step != .completed {
            if storedState.legacyCompleted {
                let explicitlyAuthorizedResume =
                    progress.origin == .existingUserUpgrade
                    || progress.origin == .explicitRerun
                if explicitlyAuthorizedResume {
                    return featureFlags.existingUsersV2
                        ? .v2Onboarding(progress.step)
                        : .mainApp
                }
                if featureFlags.existingUsersV2,
                   !storedState.upgradePromptDismissed {
                    return .upgradePrompt
                }
                return .mainApp
            }
            return featureFlags.newUsersV2
                ? .v2Onboarding(progress.step)
                : .legacyOnboarding
        }

        if (storedState.onboardingVersion ?? 0) >= Self.currentVersion
            || validProgress?.step == .completed
        {
            return .mainApp
        }

        if storedState.legacyCompleted {
            if featureFlags.existingUsersV2,
               !storedState.upgradePromptDismissed {
                return .upgradePrompt
            }
            return .mainApp
        }

        if featureFlags.newUsersV2 {
            return .v2Onboarding(.welcome)
        }
        return .legacyOnboarding
    }

    public mutating func beginNewUserSetup() {
        guard !mustPreserveStoredProgress else { return }
        replaceProgress(AgentSetupProgress(
            version: Self.currentVersion,
            step: .welcome,
            selectedAccountIDs: [],
            completedAt: nil,
            origin: .newUser
        ))
    }

    public mutating func acceptExistingUserUpgrade() {
        guard !mustPreserveStoredProgress else { return }
        let selections =
            validProgress?.selectedAccountIDs ?? []
        replaceProgress(AgentSetupProgress(
            version: Self.currentVersion,
            step: .discovery,
            selectedAccountIDs: selections,
            completedAt: nil,
            origin: .existingUserUpgrade
        ))
        storedState.upgradePromptDismissed = true
    }

    public mutating func dismissExistingUserUpgrade() {
        guard !mustPreserveStoredProgress else { return }
        storedState.upgradePromptDismissed = true
    }

    /// An explicit Settings rerun starts at passive discovery and preserves
    /// the stable selected account UUID set from the prior run.
    public mutating func beginRerun() {
        guard !mustPreserveStoredProgress else { return }
        let selections =
            validProgress?.selectedAccountIDs ?? []
        replaceProgress(AgentSetupProgress(
            version: Self.currentVersion,
            step: .discovery,
            selectedAccountIDs: selections,
            completedAt: nil,
            origin: .explicitRerun
        ))
        storedState.upgradePromptDismissed = true
    }

    public mutating func move(to step: AgentSetupStep) {
        if step == .completed {
            complete()
            return
        }
        guard ensureProgress() else { return }
        storedState.progress?.step = step
        storedState.progress?.completedAt = nil
    }

    public mutating func selectAccount(_ accountID: UUID) {
        guard ensureProgress() else { return }
        storedState.progress?.selectedAccountIDs.insert(accountID)
    }

    public mutating func deselectAccount(_ accountID: UUID) {
        guard !mustPreserveStoredProgress else { return }
        storedState.progress?.selectedAccountIDs.remove(accountID)
    }

    public mutating func complete(at date: Date = Date()) {
        guard ensureProgress() else { return }
        storedState.progress?.step = .completed
        storedState.progress?.completedAt = date
        storedState.onboardingVersion = Self.currentVersion
        // Keep the legacy flag true while the existing macOS launch surface is
        // still present; Task 10 will route through this state without causing
        // the v1 wizard to reappear.
        storedState.legacyCompleted = true
        storedState.upgradePromptDismissed = true
    }

    private var validProgress: AgentSetupProgress? {
        guard
            let progress = storedState.progress,
            progress.version == Self.currentVersion
        else {
            return nil
        }
        return progress
    }

    private var mustPreserveStoredProgress: Bool {
        if storedState.progressWasUnreadable {
            return true
        }
        if let version = storedState.persistedProgressVersion,
           version > Self.currentVersion {
            return true
        }
        if let progress = storedState.progress,
           progress.version > Self.currentVersion {
            return true
        }
        return (storedState.onboardingVersion ?? 0)
            > Self.currentVersion
    }

    @discardableResult
    private mutating func ensureProgress() -> Bool {
        guard !mustPreserveStoredProgress else { return false }
        guard validProgress == nil else { return true }
        replaceProgress(AgentSetupProgress(
            version: Self.currentVersion,
            step: storedState.legacyCompleted ? .discovery : .welcome,
            selectedAccountIDs: [],
            completedAt: nil,
            origin: storedState.legacyCompleted ? nil : .newUser
        ))
        return true
    }

    private mutating func replaceProgress(
        _ progress: AgentSetupProgress
    ) {
        storedState.progress = progress
        storedState.persistedProgressVersion = progress.version
        storedState.progressWasUnreadable = false
    }
}

public final class AgentSetupStateStore {
    public static let onboardingVersionKey =
        "cli_pulse_onboarding_version"
    public static let legacyCompletedKey =
        "cli_pulse_onboarding_completed"
    public static let progressKey =
        "cli_pulse_agent_setup_progress_v2"
    public static let upgradePromptDismissedKey =
        "cli_pulse_onboarding_v2_upgrade_prompt_dismissed"

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> AgentSetupStoredState {
        let version = (
            defaults.object(
                forKey: Self.onboardingVersionKey
            ) as? NSNumber
        )?.intValue
        let progressData = defaults.data(forKey: Self.progressKey)
        let progress = progressData.flatMap {
            try? decoder.decode(AgentSetupProgress.self, from: $0)
        }
        let progressVersion = progress?.version
            ?? progressData.flatMap(Self.persistedProgressVersion)

        return AgentSetupStoredState(
            legacyCompleted: defaults.bool(
                forKey: Self.legacyCompletedKey
            ),
            onboardingVersion: version,
            progress: progress,
            upgradePromptDismissed: defaults.bool(
                forKey: Self.upgradePromptDismissedKey
            ),
            persistedProgressVersion: progressVersion,
            progressWasUnreadable:
                progressData != nil && progress == nil
        )
    }

    public func save(_ state: AgentSetupState) {
        let snapshot = state.persistenceSnapshot
        // Preserve the exact bytes and any fields unknown to this downgraded
        // client. Re-encoding a future progress payload would silently strip
        // those fields even when state mutations correctly no-op.
        if snapshot.progressWasUnreadable {
            return
        }
        if let version = snapshot.persistedProgressVersion,
           version > AgentSetupState.currentVersion {
            return
        }
        if let progress = snapshot.progress,
           progress.version > AgentSetupState.currentVersion {
            return
        }
        if let version = snapshot.onboardingVersion,
           version > AgentSetupState.currentVersion {
            return
        }
        defaults.set(
            snapshot.legacyCompleted,
            forKey: Self.legacyCompletedKey
        )

        if let version = snapshot.onboardingVersion {
            defaults.set(version, forKey: Self.onboardingVersionKey)
        } else {
            defaults.removeObject(forKey: Self.onboardingVersionKey)
        }

        if let progress = snapshot.progress,
           let data = try? encoder.encode(progress) {
            defaults.set(data, forKey: Self.progressKey)
        } else {
            defaults.removeObject(forKey: Self.progressKey)
        }

        if snapshot.upgradePromptDismissed {
            defaults.set(
                true,
                forKey: Self.upgradePromptDismissedKey
            )
        } else {
            defaults.removeObject(
                forKey: Self.upgradePromptDismissedKey
            )
        }
    }

    /// Reset only v2 setup progress. Existing ProviderConfig data, account
    /// UUIDs, Keychain secrets, and the v1-completed compatibility flag are
    /// outside this method's key set and therefore remain untouched.
    public func resetProgress() {
        defaults.removeObject(forKey: Self.onboardingVersionKey)
        defaults.removeObject(forKey: Self.progressKey)
        defaults.removeObject(
            forKey: Self.upgradePromptDismissedKey
        )
    }

    private static func persistedProgressVersion(
        in data: Data
    ) -> Int? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any],
            let number = dictionary["version"] as? NSNumber
        else {
            return nil
        }
        return number.intValue
    }
}
