#if os(macOS)
import AuthenticationServices
import CoreFoundation
import CryptoKit
import Darwin
import Foundation

// MARK: - Errors

public enum GeminiOAuthError: LocalizedError {
    case noCallback
    case sessionStartFailed
    case noAuthCode
    case stateMismatch
    case tokenExchangeFailed(Int)
    case tokenRefreshFailed(Int)
    case invalidTokenResponse
    case noRefreshToken
    case clientNotConfigured
    case alreadyInProgress
    case randomGenerationFailed
    case credentialPersistenceFailed

    public var errorDescription: String? {
        switch self {
        case .noCallback:            return "OAuth callback not received"
        case .sessionStartFailed:    return "Failed to start authentication session"
        case .noAuthCode:            return "No authorization code in callback"
        case .stateMismatch:         return "OAuth state parameter mismatch"
        case .tokenExchangeFailed(let s): return "Token exchange failed (HTTP \(s))"
        case .tokenRefreshFailed(let s):  return "Token refresh failed (HTTP \(s))"
        case .invalidTokenResponse:  return "Invalid token response from Google"
        case .noRefreshToken:        return "No refresh token available"
        case .clientNotConfigured:   return "OAuth client ID not configured — see docs/GEMINI_OAUTH_SETUP.md"
        case .alreadyInProgress:     return "OAuth flow already in progress"
        case .randomGenerationFailed: return "Secure random generation failed"
        case .credentialPersistenceFailed:
            return "Could not safely save or remove Gemini credentials. Please retry."
        }
    }
}

// MARK: - Stored token container

public struct GeminiStoredTokens: Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiry: Date?

    public var isExpired: Bool {
        guard let exp = expiry else { return true }
        return exp < Date()
    }
}

/// OAuth result held only in the provider editor until the user presses Save.
/// Keeping this value in memory makes Cancel a true rollback boundary.
public struct GeminiAuthorizationTokens: Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expiry: Date

    public init(
        accessToken: String,
        refreshToken: String,
        expiry: Date
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiry = expiry
    }
}

public enum GeminiCredentialMutation: Equatable, Sendable {
    case unchanged
    case connect
    case disconnect
}

public enum GeminiConnectionTestDisposition:
    Equatable,
    Sendable
{
    case usePersistedCredentials
    case authorizationReadyToSave
    case stagedForRemoval
}

/// Pure editor state. Connect and Disconnect alter only this draft; `commit`
/// is invoked by the Save action and is the sole Keychain mutation boundary.
public struct GeminiCredentialDraft: Sendable {
    public private(set) var isConnected: Bool
    public private(set) var pendingMutation:
        GeminiCredentialMutation = .unchanged

    private let originallyConnected: Bool
    private var pendingAuthorization: GeminiAuthorizationTokens?

    public init(isConnected: Bool) {
        self.isConnected = isConnected
        self.originallyConnected = isConnected
    }

    public mutating func stageAuthorization(
        _ authorization: GeminiAuthorizationTokens
    ) {
        pendingAuthorization = authorization
        pendingMutation = .connect
        isConnected = true
    }

    public mutating func stageDisconnect() {
        pendingAuthorization = nil
        pendingMutation =
            originallyConnected ? .disconnect : .unchanged
        isConnected = false
    }

    /// Test Connection must respect the same Save/Cancel transaction as the
    /// editor. A staged authorization has already exchanged a valid OAuth
    /// code but is not yet in Keychain; a staged disconnect must never probe
    /// the old persisted token and report a misleading success.
    public var connectionTestDisposition:
        GeminiConnectionTestDisposition
    {
        switch pendingMutation {
        case .unchanged:
            return .usePersistedCredentials
        case .connect:
            return .authorizationReadyToSave
        case .disconnect:
            return .stagedForRemoval
        }
    }
}

/// Durable retry marker for account-scoped Gemini credential deletion.
/// A queued account is always treated as disconnected; reads opportunistically
/// retry cleanup and never expose a partially deleted token set.
final class GeminiCredentialDeletionOutbox {
    struct PendingDeletion: Equatable {
        let operationID: String
        let targetEpoch: UInt64
        let deleteLegacyCredential: Bool
        let legacyCredentialIdentity: String?
    }

    static let productionSuiteName = HelperIPC.suiteName
    static let shared = GeminiCredentialDeletionOutbox(
        defaults: UserDefaults(
            suiteName: productionSuiteName
        )
    )

    private static let processLock = NSLock()
    private let defaults: UserDefaults?
    private let storageKeyPrefix: String

    init(
        defaults: UserDefaults? = UserDefaults(
            suiteName: productionSuiteName
        ),
        storageKeyPrefix: String =
            "cli_pulse_gemini_credential_deletion_outbox_v1"
    ) {
        self.defaults = defaults
        self.storageKeyPrefix = storageKeyPrefix
    }

    /// Persists the complete deletion intent before any epoch or credential
    /// mutation. If the process dies immediately after this method returns,
    /// another App/Helper process can establish `targetEpoch` first and then
    /// resume every cleanup obligation without re-deriving it from partially
    /// deleted Keychain state.
    func beginDeletion(
        _ accountID: UUID,
        deleteLegacyCredential: Bool,
        legacyCredentialIdentity: String?
    ) -> PendingDeletion? {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        guard let defaults else { return nil }
        _ = defaults.synchronize()
        switch loadDeletionMarkerUnlocked(
            defaults: defaults,
            accountID: accountID
        ) {
        case .valid(let existing):
            return existing
        case .missing, .legacy, .corrupt:
            // An explicit Disconnect may replace an old/corrupt marker with
            // the self-describing format. Opportunistic recovery never does.
            break
        }
        guard
            let current = loadEpochUnlocked(
                defaults: defaults,
                accountID: accountID
            ),
            current < UInt64(Int64.max)
        else {
            return nil
        }
        let pending = PendingDeletion(
            operationID:
                UUID().uuidString.lowercased(),
            targetEpoch: current + 1,
            deleteLegacyCredential:
                deleteLegacyCredential,
            legacyCredentialIdentity:
                legacyCredentialIdentity
        )
        guard
            !deleteLegacyCredential
                || (
                    legacyCredentialIdentity.map(
                        Self.isValidLegacyCredentialIdentity
                    ) == true
                )
        else {
            return nil
        }
        defaults.set(
            deletionMarkerValue(pending),
            forKey: storageKey(for: accountID)
        )
        _ = defaults.synchronize()
        guard
            case let .valid(stored) =
                loadDeletionMarkerUnlocked(
                    defaults: defaults,
                    accountID: accountID
                ),
            stored == pending
        else {
            return nil
        }
        return pending
    }

    func contains(_ accountID: UUID) -> Bool {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        // If the shared app-group domain is unavailable, fail closed. The app
        // and helper must never disagree by silently falling back to their
        // separate standard-defaults domains.
        guard let defaults else { return true }
        _ = defaults.synchronize()
        return defaults.object(
            forKey: storageKey(for: accountID)
        ) != nil
    }

    func pendingDeletion(
        _ accountID: UUID
    ) -> PendingDeletion? {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        guard let defaults else { return nil }
        _ = defaults.synchronize()
        guard
            case let .valid(pending) =
                loadDeletionMarkerUnlocked(
                    defaults: defaults,
                    accountID: accountID
                )
        else {
            return nil
        }
        return pending
    }

    /// A credential replacement is distinct from a deletion: every reader
    /// must fail closed while it is in progress, but it must not
    /// opportunistically delete the bundle that the writer is committing.
    func hasPendingCredentialWrite(
        _ accountID: UUID
    ) -> Bool {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        guard let defaults else { return true }
        _ = defaults.synchronize()
        switch loadWriteMarkerUnlocked(
            defaults: defaults,
            accountID: accountID
        ) {
        case .missing:
            return false
        case .valid, .corrupt:
            return true
        }
    }

    func pendingCredentialWrite(
        _ accountID: UUID
    ) -> (operationID: String, epoch: UInt64)? {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        guard let defaults else { return nil }
        _ = defaults.synchronize()
        guard
            case let .valid(
                operationID,
                failedEpoch
            ) =
                loadWriteMarkerUnlocked(
                    defaults: defaults,
                    accountID: accountID
                ),
            let failedEpoch
        else {
            return nil
        }
        return (operationID, failedEpoch)
    }

    /// Installs a cross-process write barrier before advancing the epoch.
    /// A refresh that started earlier observes the new epoch; one that starts
    /// later observes the barrier. The returned operation ID prevents another
    /// process from completing somebody else's replacement.
    func beginCredentialWrite(
        _ accountID: UUID
    ) -> (operationID: String, epoch: UInt64)? {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        guard let defaults else { return nil }
        _ = defaults.synchronize()
        guard
            defaults.object(
                forKey: storageKey(for: accountID)
            ) == nil,
            case .missing = loadWriteMarkerUnlocked(
                defaults: defaults,
                accountID: accountID
            ),
            let current = loadEpochUnlocked(
                defaults: defaults,
                accountID: accountID
            ),
            current < UInt64(Int64.max)
        else {
            return nil
        }

        let operationID = UUID().uuidString.lowercased()
        let next = current + 1
        defaults.set(
            "v1|\(operationID)|\(next)",
            forKey: writeStorageKey(for: accountID)
        )
        _ = defaults.synchronize()
        guard
            case let .valid(
                storedOperationID,
                storedEpoch
            ) =
                loadWriteMarkerUnlocked(
                    defaults: defaults,
                    accountID: accountID
                ),
            storedOperationID == operationID,
            storedEpoch == next,
            defaults.object(
                forKey: storageKey(for: accountID)
            ) == nil
        else {
            return nil
        }

        defaults.set(
            Int64(next),
            forKey: epochStorageKey(for: accountID)
        )
        _ = defaults.synchronize()
        guard
            loadEpochUnlocked(
                defaults: defaults,
                accountID: accountID
            ) == next,
            case let .valid(
                verifiedOperationID,
                verifiedEpoch
            ) =
                loadWriteMarkerUnlocked(
                    defaults: defaults,
                    accountID: accountID
                ),
            verifiedOperationID == operationID,
            verifiedEpoch == next,
            defaults.object(
                forKey: storageKey(for: accountID)
            ) == nil
        else {
            return nil
        }
        return (operationID, next)
    }

    func matchesCredentialWrite(
        _ accountID: UUID,
        operationID: String
    ) -> Bool {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        guard let defaults else { return false }
        _ = defaults.synchronize()
        guard
            case let .valid(
                storedOperationID,
                _
            ) =
                loadWriteMarkerUnlocked(
                    defaults: defaults,
                    accountID: accountID
                ),
            storedOperationID == operationID
        else {
            return false
        }
        return true
    }

    @discardableResult
    func completeCredentialWrite(
        _ accountID: UUID,
        operationID: String
    ) -> Bool {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        guard let defaults else { return false }
        _ = defaults.synchronize()
        guard
            case let .valid(
                storedOperationID,
                failedEpoch
            ) =
                loadWriteMarkerUnlocked(
                    defaults: defaults,
                    accountID: accountID
                ),
            storedOperationID == operationID,
            let failedEpoch,
            loadEpochUnlocked(
                defaults: defaults,
                accountID: accountID
            ) == failedEpoch
        else {
            return false
        }
        defaults.removeObject(
            forKey: writeStorageKey(for: accountID)
        )
        _ = defaults.synchronize()
        if case .missing = loadWriteMarkerUnlocked(
            defaults: defaults,
            accountID: accountID
        ) {
            return true
        }
        return false
    }

    /// Restores the previous active epoch when a replacement could not be
    /// persisted. The caller holds `GeminiCredentialMutationLock`, so no App
    /// or Helper mutation can interleave between the operation/epoch checks
    /// and this rollback.
    @discardableResult
    func rollbackCredentialWrite(
        _ accountID: UUID,
        operationID: String,
        failedEpoch: UInt64
    ) -> Bool {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        guard
            failedEpoch > 0,
            let defaults
        else {
            return false
        }
        _ = defaults.synchronize()
        guard
            defaults.object(
                forKey: storageKey(for: accountID)
            ) == nil,
            let currentEpoch = loadEpochUnlocked(
                defaults: defaults,
                accountID: accountID
            ),
            currentEpoch == failedEpoch
                || currentEpoch == failedEpoch - 1,
            case let .valid(
                storedOperationID,
                storedFailedEpoch
            ) =
                loadWriteMarkerUnlocked(
                    defaults: defaults,
                    accountID: accountID
                ),
            storedOperationID == operationID,
            storedFailedEpoch == failedEpoch
        else {
            return false
        }

        if currentEpoch == failedEpoch {
            defaults.set(
                Int64(failedEpoch - 1),
                forKey: epochStorageKey(for: accountID)
            )
            _ = defaults.synchronize()
        }
        guard
            defaults.object(
                forKey: storageKey(for: accountID)
            ) == nil,
            loadEpochUnlocked(
                defaults: defaults,
                accountID: accountID
            ) == failedEpoch - 1,
            case let .valid(
                verifiedOperationID,
                verifiedFailedEpoch
            ) =
                loadWriteMarkerUnlocked(
                    defaults: defaults,
                    accountID: accountID
                ),
            verifiedOperationID == operationID,
            verifiedFailedEpoch == failedEpoch
        else {
            return false
        }

        defaults.removeObject(
            forKey: writeStorageKey(for: accountID)
        )
        _ = defaults.synchronize()
        guard
            defaults.object(
                forKey: storageKey(for: accountID)
            ) == nil,
            loadEpochUnlocked(
                defaults: defaults,
                accountID: accountID
            ) == failedEpoch - 1,
            case .missing = loadWriteMarkerUnlocked(
                defaults: defaults,
                accountID: accountID
            )
        else {
            return false
        }
        return true
    }

    /// Disconnect wins over a credential replacement. The deletion marker and
    /// advanced epoch are installed first, so removing this barrier cannot
    /// reopen a read window or permit the displaced writer to commit.
    @discardableResult
    func cancelCredentialWrite(
        _ accountID: UUID
    ) -> Bool {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        guard let defaults else { return false }
        _ = defaults.synchronize()
        defaults.removeObject(
            forKey: writeStorageKey(for: accountID)
        )
        _ = defaults.synchronize()
        if case .missing = loadWriteMarkerUnlocked(
            defaults: defaults,
            accountID: accountID
        ) {
            return true
        }
        return false
    }

    @discardableResult
    func markCompleted(
        _ accountID: UUID,
        operationID: String
    ) -> Bool {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        guard let defaults else { return false }
        _ = defaults.synchronize()
        guard
            case let .valid(pending) =
                loadDeletionMarkerUnlocked(
                    defaults: defaults,
                    accountID: accountID
                ),
            pending.operationID == operationID,
            loadEpochUnlocked(
                defaults: defaults,
                accountID: accountID
            ) == pending.targetEpoch
        else {
            return false
        }
        let key = storageKey(for: accountID)
        defaults.removeObject(forKey: key)
        _ = defaults.synchronize()
        return defaults.object(forKey: key) == nil
    }

    /// Monotonic credential generation shared by the main app and helper.
    /// The value remains after a deletion marker is completed so a refresh
    /// that started before Disconnect can never write its result back later.
    func credentialEpoch(_ accountID: UUID) -> UInt64? {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        guard let defaults else { return nil }
        _ = defaults.synchronize()
        return loadEpochUnlocked(
            defaults: defaults,
            accountID: accountID
        )
    }

    /// Idempotently establishes the tombstone epoch encoded in a previously
    /// persisted deletion marker. This is deliberately a separate step so a
    /// crash between marker creation and epoch advancement remains recoverable.
    func ensureDeletionEpoch(
        _ accountID: UUID,
        pending: PendingDeletion
    ) -> Bool {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        guard let defaults else { return false }
        _ = defaults.synchronize()
        guard
            case let .valid(stored) =
                loadDeletionMarkerUnlocked(
                    defaults: defaults,
                    accountID: accountID
                ),
            stored == pending,
            let current = loadEpochUnlocked(
                defaults: defaults,
                accountID: accountID
            ),
            current == pending.targetEpoch
                || (
                    pending.targetEpoch > 0
                    && current
                        == pending.targetEpoch - 1
                )
        else {
            return false
        }
        if current != pending.targetEpoch {
            guard let persistedEpoch =
                Int64(exactly: pending.targetEpoch)
            else {
                return false
            }
            defaults.set(
                persistedEpoch,
                forKey: epochStorageKey(
                    for: accountID
                )
            )
            _ = defaults.synchronize()
        }
        guard
            loadEpochUnlocked(
                defaults: defaults,
                accountID: accountID
            ) == pending.targetEpoch,
            case let .valid(verified) =
                loadDeletionMarkerUnlocked(
                    defaults: defaults,
                    accountID: accountID
                ),
            verified == pending
        else {
            return false
        }
        return true
    }

    private func storageKey(for accountID: UUID) -> String {
        "\(storageKeyPrefix).\(accountID.uuidString.lowercased())"
    }

    private enum DeletionMarker {
        case missing
        case legacy
        case valid(PendingDeletion)
        case corrupt
    }

    private func deletionMarkerValue(
        _ pending: PendingDeletion
    ) -> String {
        [
            "v3",
            pending.operationID,
            String(pending.targetEpoch),
            pending.deleteLegacyCredential
                ? "1"
                : "0",
            pending.legacyCredentialIdentity ?? "",
        ].joined(separator: "|")
    }

    private func loadDeletionMarkerUnlocked(
        defaults: UserDefaults,
        accountID: UUID
    ) -> DeletionMarker {
        let key = storageKey(for: accountID)
        guard let raw = defaults.object(forKey: key) else {
            return .missing
        }
        // Compatibility with the original Boolean outbox. It remains
        // fail-closed and can be replaced only by an explicit Disconnect.
        if
            let number = raw as? NSNumber,
            CFGetTypeID(number) == CFBooleanGetTypeID()
        {
            return .legacy
        }
        guard let value = raw as? String else {
            return .corrupt
        }
        let parts = value.split(
            separator: "|",
            omittingEmptySubsequences: false
        ).map(String.init)
        // v2 carried only a Boolean legacy-delete obligation and cannot
        // distinguish its target from a later global reauthorization.
        if parts.first == "v2" {
            return .legacy
        }
        guard
            parts.count == 5,
            parts[0] == "v3",
            UUID(uuidString: parts[1]) != nil,
            let targetEpoch = UInt64(parts[2]),
            targetEpoch > 0,
            targetEpoch <= UInt64(Int64.max),
            parts[3] == "0"
                || parts[3] == "1",
            (
                parts[3] == "0"
                    && parts[4].isEmpty
            )
                || (
                    parts[3] == "1"
                    && Self
                        .isValidLegacyCredentialIdentity(
                            parts[4]
                        )
                )
        else {
            return .corrupt
        }
        return .valid(
            PendingDeletion(
                operationID: parts[1],
                targetEpoch: targetEpoch,
                deleteLegacyCredential:
                    parts[3] == "1",
                legacyCredentialIdentity:
                    parts[4].isEmpty
                        ? nil
                        : parts[4]
            )
        )
    }

    private static func isValidLegacyCredentialIdentity(
        _ identity: String
    ) -> Bool {
        if identity.hasPrefix("generation:") {
            let raw = String(
                identity.dropFirst("generation:".count)
            )
            return UUID(uuidString: raw) != nil
                && raw.utf8.count == 36
        }
        if identity.hasPrefix("digest:") {
            let raw = identity.dropFirst("digest:".count)
            return raw.utf8.count == 64
                && raw.utf8.allSatisfy {
                    (48...57).contains($0)
                        || (97...102).contains($0)
                }
        }
        return false
    }

    private func epochStorageKey(
        for accountID: UUID
    ) -> String {
        "\(storageKeyPrefix).epoch.\(accountID.uuidString.lowercased())"
    }

    private func writeStorageKey(
        for accountID: UUID
    ) -> String {
        "\(storageKeyPrefix).write.\(accountID.uuidString.lowercased())"
    }

    private enum WriteMarker {
        case missing
        case valid(
            operationID: String,
            failedEpoch: UInt64?
        )
        case corrupt
    }

    private func loadWriteMarkerUnlocked(
        defaults: UserDefaults,
        accountID: UUID
    ) -> WriteMarker {
        let key = writeStorageKey(for: accountID)
        guard let raw = defaults.object(forKey: key) else {
            return .missing
        }
        guard
            let value = raw as? String
        else {
            return .corrupt
        }
        // Compatibility with the first write-barrier build. Its marker did
        // not persist the target epoch, so it remains fail-closed and can be
        // cleared by an explicit Disconnect, but is not auto-recovered.
        if UUID(uuidString: value) != nil {
            return .valid(
                operationID: value,
                failedEpoch: nil
            )
        }
        let parts = value.split(
            separator: "|",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard
            parts.count == 3,
            parts[0] == "v1",
            UUID(uuidString: parts[1]) != nil,
            let failedEpoch = UInt64(parts[2]),
            failedEpoch > 0
        else {
            return .corrupt
        }
        return .valid(
            operationID: parts[1],
            failedEpoch: failedEpoch
        )
    }

    private func loadEpochUnlocked(
        defaults: UserDefaults,
        accountID: UUID
    ) -> UInt64? {
        let key = epochStorageKey(for: accountID)
        guard let value = defaults.object(forKey: key) else {
            return 0
        }
        guard
            let number = value as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID()
        else {
            return nil
        }
        let signed = number.int64Value
        guard signed >= 0 else { return nil }
        return UInt64(signed)
    }
}

/// Short cross-process critical section for Gemini credential mutations.
///
/// App and Helper have separate in-memory locks, so the epoch checks and the
/// Keychain write they protect must also be serialized through one per-user
/// advisory lock file. The durable outbox/write markers remain the crash
/// recovery source of truth; this lock only closes check-then-write races
/// between live processes.
final class GeminiCredentialMutationLock {
    private final class ProcessLockState {
        let lock = NSRecursiveLock()
        var recursionDepth = 0
    }

    static let shared = GeminiCredentialMutationLock(
        lockFilePath: productionLockFilePath
    )

    private static let processLockRegistryLock =
        NSLock()
    private static var processLocks:
        [String: ProcessLockState] = [:]
    private static let acquisitionTimeoutNanoseconds:
        UInt64 = 2_000_000_000
    private let lockFilePath: String
    private let processState: ProcessLockState

    private static var productionLockFilePath: String {
        let homeDirectory: String
        if
            let account = Darwin.getpwuid(Darwin.geteuid()),
            let path = account.pointee.pw_dir
        {
            homeDirectory = String(cString: path)
        } else {
            homeDirectory = NSHomeDirectory()
        }
        let root: URL
        if MASSandboxGate.isSandboxed {
            // MAS App + embedded LoginItem are entitled for this app group.
            root = URL(fileURLWithPath: homeDirectory)
                .appendingPathComponent("Library")
                .appendingPathComponent(
                    "Group Containers"
                )
                .appendingPathComponent(
                    HelperIPC.suiteName
                )
                .appendingPathComponent("Library")
                .appendingPathComponent(
                    "Application Support"
                )
                .appendingPathComponent("CLIPulse")
        } else {
            // The unsandboxed DEVID/.pkg helper must not touch Group
            // Containers: doing so triggers the recurring macOS app-data
            // consent dialog. Keep its lock beside the helper token file.
            root = URL(fileURLWithPath: homeDirectory)
                .appendingPathComponent(".config")
                .appendingPathComponent("clipulse")
        }
        return root.appendingPathComponent(
            ".gemini-credential.lock"
        ).path
    }

    init(lockFilePath: String) {
        self.lockFilePath = lockFilePath
        processState = Self.processLockState(
            for: lockFilePath
        )
    }

    private static func processLockState(
        for path: String
    ) -> ProcessLockState {
        processLockRegistryLock.lock()
        defer { processLockRegistryLock.unlock() }
        if let existing = processLocks[path] {
            return existing
        }
        let created = ProcessLockState()
        processLocks[path] = created
        return created
    }

    func withLock<T>(
        or failure: T,
        _ body: () -> T
    ) -> T {
        let deadline =
            DispatchTime.now().uptimeNanoseconds
            &+ Self.acquisitionTimeoutNanoseconds
        while !processState.lock.try() {
            guard
                DispatchTime.now().uptimeNanoseconds
                    < deadline
            else {
                return failure
            }
            Darwin.usleep(10_000)
        }
        defer { processState.lock.unlock() }

        if processState.recursionDepth > 0 {
            processState.recursionDepth += 1
            defer {
                processState.recursionDepth -= 1
            }
            return body()
        }

        let directory = URL(
            fileURLWithPath: lockFilePath
        ).deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [
                    .posixPermissions: 0o700,
                ]
            )
        } catch {
            return failure
        }

        let directoryDescriptor = Darwin.open(
            directory.path,
            O_RDONLY
                | O_CLOEXEC
                | O_NOFOLLOW
                | O_DIRECTORY
        )
        guard directoryDescriptor >= 0 else {
            return failure
        }
        defer {
            _ = Darwin.close(directoryDescriptor)
        }
        var directoryMetadata = stat()
        guard
            Darwin.fstat(
                directoryDescriptor,
                &directoryMetadata
            ) == 0,
            directoryMetadata.st_uid
                == Darwin.geteuid(),
            directoryMetadata.st_mode
                & S_IFMT == S_IFDIR
        else {
            return failure
        }
        if
            directoryMetadata.st_mode
                & (S_IRWXG | S_IRWXO) != 0
        {
            guard
                Darwin.fchmod(
                    directoryDescriptor,
                    S_IRWXU
                ) == 0
            else {
                return failure
            }
        }
        guard
            Darwin.fstat(
                directoryDescriptor,
                &directoryMetadata
            ) == 0,
            directoryMetadata.st_uid
                == Darwin.geteuid(),
            directoryMetadata.st_mode
                & S_IFMT == S_IFDIR,
            directoryMetadata.st_mode
                & (S_IRWXG | S_IRWXO) == 0
        else {
            return failure
        }

        let lockFileName = URL(
            fileURLWithPath: lockFilePath
        ).lastPathComponent
        guard
            !lockFileName.isEmpty,
            !lockFileName.contains("/")
        else {
            return failure
        }
        let descriptor = Darwin.openat(
            directoryDescriptor,
            lockFileName,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            return failure
        }
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard
            Darwin.fstat(descriptor, &metadata) == 0,
            metadata.st_uid == Darwin.geteuid(),
            metadata.st_nlink == 1,
            metadata.st_mode & S_IFMT == S_IFREG,
            Darwin.fchmod(
                descriptor,
                S_IRUSR | S_IWUSR
            ) == 0,
            Darwin.fstat(descriptor, &metadata) == 0,
            metadata.st_uid == Darwin.geteuid(),
            metadata.st_nlink == 1,
            metadata.st_mode & S_IFMT == S_IFREG,
            metadata.st_mode
                & (S_IRWXG | S_IRWXO) == 0
        else {
            return failure
        }
        var pathMetadata = stat()
        guard
            Darwin.fstatat(
                directoryDescriptor,
                lockFileName,
                &pathMetadata,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
            pathMetadata.st_dev == metadata.st_dev,
            pathMetadata.st_ino == metadata.st_ino
        else {
            return failure
        }
        while Darwin.lockf(
            descriptor,
            F_TLOCK,
            0
        ) != 0 {
            guard
                Darwin.errno == EACCES
                    || Darwin.errno == EAGAIN,
                DispatchTime.now().uptimeNanoseconds
                    < deadline
            else {
                return failure
            }
            Darwin.usleep(10_000)
        }
        defer { _ = Darwin.lockf(descriptor, F_ULOCK, 0) }
        processState.recursionDepth = 1
        defer { processState.recursionDepth = 0 }
        return body()
    }
}

// MARK: - Manager

/// Manages CLI Pulse's own Google OAuth2 flow for Gemini quota access.
///
/// Flow: ASWebAuthenticationSession + PKCE (public client, no client_secret).
/// Tokens: Keychain (primary) + `~/.config/clipulse/gemini_tokens.json` (Python helper,
///   access_token only — refresh_token stays in Keychain).
public final class GeminiOAuthManager: NSObject, @unchecked Sendable {
    typealias TokenDataLoader =
        @Sendable (URLRequest) async throws
            -> (Data, URLResponse)

    static let defaultTokenDataLoader:
        TokenDataLoader = { request in
            try await URLSession.shared.data(for: request)
        }

    // ── Configuration ────────────────────────────────────────────────
    // Replace after creating an iOS-type OAuth client in Google Cloud Console.
    // See docs/GEMINI_OAUTH_SETUP.md for instructions.
    public static let clientID = "REPLACE_WITH_YOUR_CLIENT_ID.apps.googleusercontent.com"

    public static var callbackScheme: String {
        clientID.split(separator: ".").reversed().joined(separator: ".")
    }
    public static var redirectURI: String {
        "\(callbackScheme):/oauthredirect"
    }

    private static let scope = "https://www.googleapis.com/auth/cloud-platform"
    private static let authEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    private static let tokenEndpoint = "https://oauth2.googleapis.com/token"

    // ── Keychain keys ────────────────────────────────────────────────
    private static var accessGroup: String {
        KeychainHelper.sharedAccessGroup
    }
    static let keyAccessToken  = "gemini.oauth.access_token"
    static let keyRefreshToken = "gemini.oauth.refresh_token"
    static let keyExpiry       = "gemini.oauth.expiry"
    static let keyBundle       = "gemini.oauth.bundle.v1"
    static let keyGlobalPendingBundle =
        "gemini.oauth.bundle.pending.v1"
    static let keyGlobalTransactionControl =
        "gemini.oauth.transaction.control.v1"
    static let keyLegacyOwner = "gemini.oauth.legacy_owner"

    static func accountKey(
        _ base: String,
        accountID: UUID
    ) -> String {
        "\(base).account.\(accountID.uuidString)"
    }

    static func accountBundleKey(
        accountID: UUID,
        credentialEpoch: UInt64
    ) -> String {
        // Two alternating physical slots are sufficient because every writer
        // must hold the shared mutation lock and compare the full monotonic
        // epoch before writing. Reusing the slot after two epochs prevents an
        // ignored cleanup failure from creating an unreachable, unbounded
        // history of refresh-token records.
        "\(accountKey(keyBundle, accountID: accountID)).slot.\(credentialEpoch % 2)"
    }

    // ── Shared file for Python helper ────────────────────────────────
    private static var sharedDir: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".config/clipulse")
    }
    static var sharedTokenFilePath: String {
        (sharedDir as NSString).appendingPathComponent("gemini_tokens.json")
    }

    static func globalTransactionMarkerPath(
        sharedTokenFilePath: String
    ) -> String {
        "\(sharedTokenFilePath).transaction"
    }

    static func globalTransactionStagePath(
        sharedTokenFilePath: String,
        operationID: String
    ) -> String {
        "\(sharedTokenFilePath).pending.\(operationID)"
    }

    // ── Singleton ────────────────────────────────────────────────────
    public static let shared = GeminiOAuthManager()

    private let secretStore: any ProviderSecretStoring
    private let deletionOutbox: GeminiCredentialDeletionOutbox
    private let credentialMutationLock:
        GeminiCredentialMutationLock
    private let tokenFilePath: String
    private let tokenDataLoader: TokenDataLoader
    private let credentialLock = NSRecursiveLock()

    // authSession is only accessed on MainActor (UI-driven OAuth flow).
    // @unchecked Sendable on class is safe because all mutable state is MainActor-isolated.
    @MainActor private var authSession: ASWebAuthenticationSession?
    private override init() {
        secretStore = KeychainProviderSecretStore()
        deletionOutbox = .shared
        credentialMutationLock = .shared
        tokenFilePath = Self.sharedTokenFilePath
        tokenDataLoader = Self.defaultTokenDataLoader
        super.init()
    }

    init(
        secretStore: any ProviderSecretStoring,
        deletionOutbox: GeminiCredentialDeletionOutbox,
        credentialMutationLock:
            GeminiCredentialMutationLock = .shared,
        sharedTokenFilePath: String,
        tokenDataLoader:
            @escaping TokenDataLoader =
                GeminiOAuthManager.defaultTokenDataLoader
    ) {
        self.secretStore = secretStore
        self.deletionOutbox = deletionOutbox
        self.credentialMutationLock =
            credentialMutationLock
        tokenFilePath = sharedTokenFilePath
        self.tokenDataLoader = tokenDataLoader
        super.init()
    }

    // MARK: - Public API

    /// Whether CLI Pulse has its own Gemini OAuth tokens in Keychain.
    public var isConnected: Bool { loadTokens() != nil }

    public func isConnected(
        accountID: UUID,
        allowLegacyFallback: Bool = true
    ) -> Bool {
        loadTokens(
            accountID: accountID,
            allowLegacyFallback: allowLegacyFallback
        ) != nil
    }

    /// Read-only connection check for transactional editors. Unlike
    /// `loadTokens`, this does not claim a legacy owner or copy credentials
    /// into an account-scoped Keychain slot merely because a window opened.
    public func isConnectedWithoutMigration(
        accountID: UUID,
        allowLegacyFallback: Bool = true
    ) -> Bool {
        guard
            let credentialEpoch =
                deletionOutbox.credentialEpoch(accountID),
            !deletionOutbox.contains(accountID),
            !deletionOutbox
                .hasPendingCredentialWrite(accountID)
        else {
            return false
        }
        return withCredentialLock {
            let account = readAccountCredential(
                accountID: accountID,
                credentialEpoch: credentialEpoch
            )
            switch account.read {
            case .corrupt:
                return false
            case .valid(let loaded):
                if loaded.origin == .legacyCopy {
                    guard
                        ProviderSharedCredentialOwner.isOwner(
                            kind: .gemini,
                            accountID: accountID
                        ),
                        case let .valid(provenance) =
                            readLegacyProvenance(
                                accountID: accountID
                            ),
                        provenance.state == .inherited,
                        provenance.accountGeneration
                            == loaded.generation
                            || provenance
                                .accountGeneration
                                == loaded.parentGeneration
                    else {
                        return false
                    }
                }
                return true
            case .missing:
                break
            }
            guard
                allowLegacyFallback,
                loadTokens(
                    keys: Self.tokenKeys(accountID: nil)
                ) != nil
            else {
                return false
            }
            return ProviderSharedCredentialOwner.canUse(
                kind: .gemini,
                accountID: accountID
            )
        }
    }

    /// Start the full OAuth2 authorization flow (opens browser sheet).
    /// Compatibility API for callers that explicitly want immediate commit.
    @MainActor
    public func authorize(
        accountID: UUID? = nil
    ) async throws -> (accessToken: String, refreshToken: String) {
        let authorization = try await authorizeForEditing(
            accountID: accountID
        )
        guard commitAuthorization(
            authorization,
            accountID: accountID
        ) else {
            throw GeminiOAuthError.credentialPersistenceFailed
        }
        return (
            authorization.accessToken,
            authorization.refreshToken
        )
    }

    /// Run OAuth without touching Keychain. ProviderConfigEditor keeps the
    /// returned secret-bearing value in memory and commits it only on Save.
    @MainActor
    public func authorizeForEditing(
        accountID: UUID? = nil
    ) async throws -> GeminiAuthorizationTokens {
        guard Self.clientID != "REPLACE_WITH_YOUR_CLIENT_ID.apps.googleusercontent.com" else {
            throw GeminiOAuthError.clientNotConfigured
        }
        // Prevent concurrent auth sessions
        guard authSession == nil else {
            throw GeminiOAuthError.alreadyInProgress
        }

        let verifier  = try Self.generateCodeVerifier()
        let challenge = Self.generateCodeChallenge(from: verifier)
        let state     = UUID().uuidString

        guard var comps = URLComponents(string: Self.authEndpoint) else {
            throw GeminiOAuthError.sessionStartFailed
        }
        comps.queryItems = [
            .init(name: "client_id",             value: Self.clientID),
            .init(name: "redirect_uri",          value: Self.redirectURI),
            .init(name: "response_type",         value: "code"),
            .init(name: "scope",                 value: Self.scope),
            .init(name: "state",                 value: state),
            .init(name: "code_challenge",        value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "access_type",           value: "offline"),
            .init(name: "prompt",                value: "consent"),
        ]

        guard let authURL = comps.url else {
            throw GeminiOAuthError.sessionStartFailed
        }

        defer { self.authSession = nil }

        let callbackURL: URL = try await withCheckedThrowingContinuation { cont in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: Self.callbackScheme
            ) { url, error in
                if let error { cont.resume(throwing: error) }
                else if let url { cont.resume(returning: url) }
                else { cont.resume(throwing: GeminiOAuthError.noCallback) }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.authSession = session
            if !session.start() {
                self.authSession = nil
                cont.resume(throwing: GeminiOAuthError.sessionStartFailed)
            }
        }

        // Parse callback
        guard let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems,
              let code = items.first(where: { $0.name == "code" })?.value else {
            throw GeminiOAuthError.noAuthCode
        }
        guard items.first(where: { $0.name == "state" })?.value == state else {
            throw GeminiOAuthError.stateMismatch
        }

        // Exchange code → tokens
        let tokens = try await exchangeCode(code, codeVerifier: verifier)

        // Require a refresh token on initial connect
        let rt = tokens.refresh.isEmpty
            ? withCredentialLock {
                if let accountID {
                    return loadTokens(
                        accountID: accountID,
                        allowLegacyFallback: false
                    )?.refreshToken ?? ""
                }
                return loadTokens(
                    keys: Self.tokenKeys(accountID: nil)
                )?.refreshToken ?? ""
            }
            : tokens.refresh
        return GeminiAuthorizationTokens(
            accessToken: tokens.access,
            refreshToken: rt,
            expiry: Date().addingTimeInterval(tokens.expiresIn)
        )
    }

    @discardableResult
    public func commitAuthorization(
        _ authorization: GeminiAuthorizationTokens,
        accountID: UUID? = nil
    ) -> Bool {
        withCredentialLock {
            credentialMutationLock.withLock(or: false) {
                guard
                    recoverGlobalCredentialTransactionAssumingMutationLock()
                else {
                    return false
                }
                let expectedEpoch: UInt64?
                let credentialWriteID: String?
                if let accountID {
                    if deletionOutbox.contains(accountID) {
                        guard resumeAccountDeletionAssumingMutationLock(
                            accountID: accountID
                        ) else {
                            return false
                        }
                    }
                    guard
                        recoverAbandonedCredentialWrite(
                            accountID: accountID
                        ),
                        let write =
                            deletionOutbox
                                .beginCredentialWrite(accountID)
                    else {
                        return false
                    }
                    expectedEpoch = write.epoch
                    credentialWriteID = write.operationID
                } else {
                    guard
                        prepareForGlobalCredentialMutationAssumingMutationLock()
                    else {
                        return false
                    }
                    expectedEpoch = nil
                    credentialWriteID = nil
                }
                let stored = storeTokensAssumingMutationLock(
                    access: authorization.accessToken,
                    refresh: authorization.refreshToken,
                    expiresIn: max(
                        0,
                        authorization.expiry.timeIntervalSinceNow
                    ),
                    accountID: accountID,
                    origin: .independent,
                    expectedEpoch: expectedEpoch,
                    credentialWriteID: credentialWriteID
                )
                guard stored != nil else {
                    if
                        let accountID,
                        let credentialWriteID,
                        let expectedEpoch
                    {
                        _ = deletionOutbox
                            .rollbackCredentialWrite(
                                accountID,
                                operationID:
                                    credentialWriteID,
                                failedEpoch: expectedEpoch
                            )
                    }
                    return false
                }
                if let accountID {
                    guard let credentialWriteID else {
                        return false
                    }
                    guard deletionOutbox
                        .completeCredentialWrite(
                            accountID,
                            operationID:
                                credentialWriteID
                        )
                    else {
                        return false
                    }
                    // The independent bundle is committed as soon as the
                    // write barrier is removed. Provenance and retired-slot
                    // cleanup are idempotent follow-ups retried by reads and
                    // Disconnect; a crash here cannot roll the epoch back to
                    // a credential whose provenance was already removed.
                    _ = supersedeLegacyProvenance(
                        accountID: accountID
                    )
                    if let expectedEpoch {
                        _ = cleanupRetiredCredentialSlots(
                            accountID: accountID,
                            currentEpoch: expectedEpoch
                        )
                    }
                    return true
                }
                return true
            }
        }
    }

    /// Refresh the stored access token using the refresh token.
    public func refreshAccessToken(
        accountID: UUID? = nil
    ) async throws -> String {
        let context = withCredentialLock {
            credentialMutationLock.withLock(
                or: Optional<RefreshCredentialContext>.none
            ) {
                guard
                    recoverGlobalCredentialTransactionAssumingMutationLock()
                else {
                    return nil
                }
                return refreshCredentialContext(
                    accountID: accountID
                )
            }
        }
        guard let context else {
            throw GeminiOAuthError.noRefreshToken
        }
        let rt = context.refreshToken

        let body = Self.formEncode([
            "client_id":     Self.clientID,
            "grant_type":    "refresh_token",
            "refresh_token": rt,
        ])

        var req = URLRequest(url: URL(string: Self.tokenEndpoint)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        req.httpBody = body.data(using: .utf8)

        let (data, resp) = try await tokenDataLoader(req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            // Clear tokens on permanent auth errors so isConnected reflects reality
            if (400...401).contains(status) {
                _ = clearCredentialAfterPermanentRefreshFailure(
                    context: context,
                    accountID: accountID
                )
            }
            throw GeminiOAuthError.tokenRefreshFailed(status)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let at = json["access_token"] as? String else {
            throw GeminiOAuthError.invalidTokenResponse
        }

        let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        let newRT = json["refresh_token"] as? String ?? rt

        guard commitRefreshCredential(
            access: at,
            refresh: newRT,
            expiresIn: expiresIn,
            accountID: accountID,
            context: context
        ) else {
            throw GeminiOAuthError.credentialPersistenceFailed
        }
        return at
    }

    private func clearCredentialAfterPermanentRefreshFailure(
        context: RefreshCredentialContext,
        accountID: UUID?
    ) -> Bool {
        withCredentialLock {
            credentialMutationLock.withLock(or: false) {
                guard
                    recoverGlobalCredentialTransactionAssumingMutationLock()
                else {
                    return false
                }
                guard refreshContextIsCurrent(
                    context,
                    accountID: accountID
                ) else {
                    // The 400/401 belongs to a credential that has already
                    // been replaced or disconnected. Validate before touching
                    // the current inherited owner: it may belong to a newer
                    // global generation.
                    return true
                }
                if accountID == nil {
                    guard
                        prepareForGlobalCredentialMutationAssumingMutationLock()
                    else {
                        return false
                    }
                    guard refreshContextIsCurrent(
                        context,
                        accountID: accountID
                    ) else {
                        // Owner cleanup may have completed a pending
                        // Disconnect and retired this generation.
                        return true
                    }
                }
                if let accountID {
                    return clearAccountCredentialsAssumingMutationLock(
                        accountID: accountID
                    )
                }
                return deleteGlobalCredentialAssumingMutationLock()
            }
        }
    }

    private func commitRefreshCredential(
        access: String,
        refresh: String,
        expiresIn: TimeInterval,
        accountID: UUID?,
        context: RefreshCredentialContext
    ) -> Bool {
        withCredentialLock {
            credentialMutationLock.withLock(or: false) {
                guard
                    recoverGlobalCredentialTransactionAssumingMutationLock()
                else {
                    return false
                }
                guard refreshContextIsCurrent(
                    context,
                    accountID: accountID
                ) else {
                    // Do not detach a current inherited owner until the
                    // refresh response proves it belongs to the active
                    // credential generation.
                    return false
                }
                if accountID == nil {
                    guard
                        prepareForGlobalCredentialMutationAssumingMutationLock()
                    else {
                        return false
                    }
                    guard refreshContextIsCurrent(
                        context,
                        accountID: accountID
                    ) else {
                        // Owner cleanup may have completed a pending
                        // Disconnect and retired this generation.
                        return false
                    }
                }
                let keys = Self.tokenKeys(
                    accountID: accountID,
                    credentialEpoch: context.epoch
                )
                let previousBundle = secretStore.load(
                    key: keys.bundle,
                    accessGroup: Self.accessGroup
                )
                guard let stored =
                    storeTokensAssumingMutationLock(
                        access: access,
                        refresh: refresh,
                        expiresIn: expiresIn,
                        accountID: accountID,
                        origin: context.origin,
                        parentGeneration:
                            context.generation,
                        expectedEpoch: context.epoch
                    )
                else {
                    return false
                }
                if
                    let accountID,
                    context.origin == .legacyCopy
                {
                    guard
                        advanceInheritedProvenanceAfterRefresh(
                            accountID: accountID,
                            previousGeneration:
                                context.generation,
                            newGeneration:
                                stored.generation
                        )
                    else {
                        restoreAtomicBundle(
                            previousBundle,
                            keys: keys
                        )
                        return false
                    }
                }
                return true
            }
        }
    }

    private func refreshContextIsCurrent(
        _ context: RefreshCredentialContext,
        accountID: UUID?
    ) -> Bool {
        if let accountID {
            guard
                let epoch = context.epoch,
                deletionOutbox.credentialEpoch(accountID)
                    == epoch,
                !deletionOutbox.contains(accountID),
                !deletionOutbox
                    .hasPendingCredentialWrite(accountID),
                case let .valid(loaded) =
                    readAccountCredential(
                        accountID: accountID,
                        credentialEpoch: epoch
                    ).read,
                loaded.generation == context.generation,
                loaded.tokens.refreshToken
                    == context.refreshToken
            else {
                return false
            }
            return true
        }
        guard
            case let .valid(loaded) = readCredential(
                keys: Self.tokenKeys(accountID: nil)
            ),
            loaded.generation == context.generation,
            loaded.tokens.refreshToken
                == context.refreshToken
        else {
            return false
        }
        return true
    }

    /// Load current tokens from Keychain. Returns nil if not present.
    public func loadTokens(
        accountID: UUID? = nil,
        allowLegacyFallback: Bool = true
    ) -> GeminiStoredTokens? {
        withCredentialLock {
            credentialMutationLock.withLock(
                or: Optional<GeminiStoredTokens>.none
            ) {
                guard
                    recoverGlobalCredentialTransactionAssumingMutationLock()
                else {
                    return nil
                }
                guard let accountID else {
                    return loadTokens(
                        keys: Self.tokenKeys(accountID: nil)
                    )
                }
                guard
                    var credentialEpoch =
                        deletionOutbox
                            .credentialEpoch(accountID)
                else {
                    return nil
                }
                if deletionOutbox.contains(accountID) {
                    _ = credentialMutationLock
                        .withLock(or: false) {
                            guard deletionOutbox
                                .contains(accountID)
                            else {
                                return true
                            }
                            return resumeAccountDeletionAssumingMutationLock(
                                accountID: accountID
                            )
                        }
                    return nil
                }
                if deletionOutbox
                    .hasPendingCredentialWrite(accountID)
                {
                    let recovered = credentialMutationLock
                        .withLock(or: false) {
                            recoverAbandonedCredentialWrite(
                                accountID: accountID
                            )
                        }
                    guard
                        recovered,
                        let refreshedEpoch =
                            deletionOutbox
                                .credentialEpoch(accountID),
                        !deletionOutbox.contains(accountID),
                        !deletionOutbox
                            .hasPendingCredentialWrite(
                                accountID
                            )
                    else {
                        return nil
                    }
                    credentialEpoch = refreshedEpoch
                }
                let loaded = loadAccountTokens(
                    accountID: accountID,
                    credentialEpoch: credentialEpoch,
                    allowLegacyFallback: allowLegacyFallback
                )
                if loaded != nil {
                    _ = credentialMutationLock
                        .withLock(or: false) {
                            guard
                                deletionOutbox
                                    .credentialEpoch(accountID)
                                    == credentialEpoch,
                                !deletionOutbox
                                    .contains(accountID),
                                !deletionOutbox
                                    .hasPendingCredentialWrite(
                                        accountID
                                    )
                            else {
                                return false
                            }
                            return cleanupRetiredCredentialSlots(
                                accountID: accountID,
                                currentEpoch: credentialEpoch
                            )
                        }
                }
                return loaded
            }
        }
    }

    private func loadTokens(keys: TokenKeys) -> GeminiStoredTokens? {
        switch readCredential(keys: keys) {
        case .missing, .corrupt:
            return nil
        case .valid(let loaded):
            return loaded.tokens
        }
    }

    private func loadLegacyIndividualTokens(
        keys: TokenKeys
    ) -> GeminiStoredTokens? {
        guard let at = secretStore.load(
            key: keys.access,
            accessGroup: Self.accessGroup
        ),
              !at.isEmpty else { return nil }
        let rt = secretStore.load(
            key: keys.refresh,
            accessGroup: Self.accessGroup
        )
        var expiry: Date?
        if let s = secretStore.load(
            key: keys.expiry,
            accessGroup: Self.accessGroup
        ),
           let ts = Double(s) {
            expiry = Date(timeIntervalSince1970: ts)
        }
        return GeminiStoredTokens(accessToken: at, refreshToken: rt, expiry: expiry)
    }

    /// Remove all stored tokens (Keychain + shared file).
    static func allowsTokenCleanup(
        in runtimeEnvironment: CLIPulseRuntimeEnvironment
    ) -> Bool {
        runtimeEnvironment.capabilities.allowsLiveCollection
    }

    @discardableResult
    public func clearTokens(
        accountID: UUID? = nil
    ) -> Bool {
        withCredentialLock {
            guard let accountID else {
                return credentialMutationLock
                    .withLock(or: false) {
                        guard
                            recoverGlobalCredentialTransactionAssumingMutationLock()
                        else {
                            return false
                        }
                        guard
                            prepareForGlobalCredentialMutationAssumingMutationLock()
                        else {
                            return false
                        }
                        return deleteGlobalCredentialAssumingMutationLock()
                    }
            }
            return credentialMutationLock.withLock(or: false) {
                clearAccountCredentialsAssumingMutationLock(
                    accountID: accountID
                )
            }
        }
    }

    /// Runtime-gated cleanup for app composition roots. QA and quarantined
    /// builds deny the operation before any credential or owner-store access.
    @discardableResult
    public func clearTokens(
        accountID: UUID? = nil,
        runtimeEnvironment: CLIPulseRuntimeEnvironment
    ) -> Bool {
        guard Self.allowsTokenCleanup(in: runtimeEnvironment) else {
            return false
        }
        return clearTokens(accountID: accountID)
    }

    private enum LegacyMigrationState: String {
        case prepared
        case inherited
    }

    private struct LegacyProvenance {
        let state: LegacyMigrationState
        let legacyDigest: String?
        let accountGeneration: String?
    }

    private enum LegacyProvenanceRead {
        case missing
        case valid(LegacyProvenance)
        case corrupt
    }

    private func loadAccountTokens(
        accountID: UUID,
        credentialEpoch: UInt64,
        allowLegacyFallback: Bool
    ) -> GeminiStoredTokens? {
        let currentKeys = Self.tokenKeys(
            accountID: accountID,
            credentialEpoch: credentialEpoch
        )
        let selection = readAccountCredential(
            accountID: accountID,
            credentialEpoch: credentialEpoch
        )
        let provenance = readLegacyProvenance(
            accountID: accountID
        )
        let legacyRead = readCredential(
            keys: Self.tokenKeys(accountID: nil)
        )

        switch selection.read {
        case .corrupt:
            return nil
        case .valid(let loaded):
            switch loaded.origin {
            case .independent:
                _ = supersedeLegacyProvenance(
                    accountID: accountID
                )
                return loaded.tokens
            case .legacyCopy:
                return validatedInheritedTokens(
                    loaded,
                    provenance: provenance,
                    legacyRead: legacyRead,
                    accountID: accountID,
                    accountKeys: selection.keys
                )
            case nil:
                return migrateLegacyIndividualAccountCredential(
                    loaded,
                    provenance: provenance,
                    legacyRead: legacyRead,
                    accountID: accountID,
                    accountKeys: currentKeys
                )
            }
        case .missing:
            guard allowLegacyFallback else {
                return nil
            }
            return migrateGlobalLegacyCredential(
                provenance: provenance,
                legacyRead: legacyRead,
                accountID: accountID,
                accountKeys: currentKeys
            )
        }
    }

    private func clearAccountCredentialsAssumingMutationLock(
        accountID: UUID
    ) -> Bool {
        let pending: GeminiCredentialDeletionOutbox
            .PendingDeletion
        if let existing =
            deletionOutbox.pendingDeletion(accountID)
        {
            pending = existing
        } else {
            guard
                let legacyIntent =
                    deletionRequiresLegacyCredential(
                        accountID: accountID
                    )
            else {
                return false
            }
            let deleteLegacy: Bool
            let legacyIdentity: String?
            switch legacyIntent {
            case .preserveGlobal:
                deleteLegacy = false
                legacyIdentity = nil
            case .delete(let identity):
                deleteLegacy = true
                legacyIdentity = identity
            }
            guard
                let created =
                    deletionOutbox.beginDeletion(
                        accountID,
                        deleteLegacyCredential:
                            deleteLegacy,
                        legacyCredentialIdentity:
                            legacyIdentity
                    )
            else {
                return false
            }
            pending = created
        }
        return finishAccountDeletionAssumingMutationLock(
            accountID: accountID,
            pending: pending
        )
    }

    private func resumeAccountDeletionAssumingMutationLock(
        accountID: UUID
    ) -> Bool {
        guard let pending =
            deletionOutbox.pendingDeletion(accountID)
        else {
            // Old/corrupt markers remain fail-closed. Only a new explicit
            // Disconnect may replace them with a self-describing marker.
            return false
        }
        return finishAccountDeletionAssumingMutationLock(
            accountID: accountID,
            pending: pending
        )
    }

    /// Global credential mutations share the same lock as ownership changes.
    /// Before replacing or clearing the global source, finish any pending
    /// owner deletion and detach a live inherited account copy while preserving
    /// the current global credential. The subsequent mutation can then publish
    /// or delete the global source without leaving a copied refresh token.
    private func prepareForGlobalCredentialMutationAssumingMutationLock()
        -> Bool
    {
        guard
            resolvePendingOwnerDeletionBeforeGlobalMutation()
        else {
            return false
        }
        let owner: UUID
        switch ProviderSharedCredentialOwner.lookup(
            kind: .gemini
        ) {
        case .unowned:
            return true
        case .owned(let current):
            owner = current
        case .unavailable, .corrupt:
            return false
        }
        guard
            let epoch =
                deletionOutbox.credentialEpoch(owner),
            !deletionOutbox.contains(owner)
        else {
            return false
        }
        let accountRead = readAccountCredential(
            accountID: owner,
            credentialEpoch: epoch
        ).read
        switch accountRead {
        case .valid(let account)
            where account.origin == .independent:
            return supersedeLegacyProvenance(
                accountID: owner
            )
        case .corrupt:
            return false
        case .valid, .missing:
            break
        }

        let provenance =
            readLegacyProvenance(accountID: owner)
        switch provenance {
        case .corrupt:
            return false
        case .valid:
            return detachAccountPreservingGlobalAssumingMutationLock(
                accountID: owner
            )
        case .missing:
            break
        }

        if case let .valid(account) = accountRead,
           account.origin == .legacyCopy {
            return detachAccountPreservingGlobalAssumingMutationLock(
                accountID: owner
            )
        }
        if
            case let .valid(account) = accountRead,
            case let .valid(global) = readCredential(
                keys: Self.tokenKeys(accountID: nil)
            ),
            tokensEquivalent(
                account.tokens,
                global.tokens
            )
        {
            return detachAccountPreservingGlobalAssumingMutationLock(
                accountID: owner
            )
        }
        // A deterministic owner can be selected before that account first
        // reads the shared credential. With no inherited provenance or
        // equivalent account copy there is nothing to detach.
        return true
    }

    private func detachAccountPreservingGlobalAssumingMutationLock(
        accountID: UUID
    ) -> Bool {
        guard
            let pending =
                deletionOutbox.beginDeletion(
                    accountID,
                    deleteLegacyCredential: false,
                    legacyCredentialIdentity: nil
                )
        else {
            return false
        }
        return finishAccountDeletionAssumingMutationLock(
            accountID: accountID,
            pending: pending
        )
    }

    /// Finish a durable owner deletion before any global mutation. The caller
    /// already holds `credentialMutationLock`, which now also serializes every
    /// App/Helper owner change.
    private func resolvePendingOwnerDeletionBeforeGlobalMutation()
        -> Bool
    {
        let owner: UUID
        switch ProviderSharedCredentialOwner.lookup(
            kind: .gemini
        ) {
        case .unowned:
            return true
        case .owned(let current):
            owner = current
        case .unavailable, .corrupt:
            return false
        }
        guard deletionOutbox.contains(owner) else {
            return true
        }
        guard let pending =
            deletionOutbox.pendingDeletion(owner)
        else {
            return false
        }
        return finishAccountDeletionAssumingMutationLock(
            accountID: owner,
            pending: pending
        )
    }

    private func finishAccountDeletionAssumingMutationLock(
        accountID: UUID,
        pending:
            GeminiCredentialDeletionOutbox.PendingDeletion
    ) -> Bool {
        guard
            deletionOutbox.ensureDeletionEpoch(
                accountID,
                pending: pending
            ),
            deletionOutbox.cancelCredentialWrite(
                accountID
            ),
            clearAccountTokensNow(
                accountID: accountID,
                pending: pending
            )
        else {
            return false
        }
        return deletionOutbox.markCompleted(
            accountID,
            operationID: pending.operationID
        )
    }

    /// Decides whether Disconnect owns the global legacy credential before
    /// any account slot is removed. The result is persisted in the deletion
    /// marker, so a retry never has to infer the obligation from partially
    /// deleted state.
    private enum LegacyDeletionIntent {
        case preserveGlobal
        case delete(identity: String)
    }

    private func deletionRequiresLegacyCredential(
        accountID: UUID
    ) -> LegacyDeletionIntent? {
        guard let currentEpoch =
            deletionOutbox.credentialEpoch(accountID)
        else {
            return nil
        }
        let current = readAccountCredential(
            accountID: accountID,
            credentialEpoch: currentEpoch
        ).read
        let alternate = readAccountCredential(
            accountID: accountID,
            credentialEpoch:
                currentEpoch % 2 == 0 ? 1 : 0
        ).read
        let compatibility = readCredential(
            keys: Self.tokenKeys(accountID: accountID)
        )
        let accountRead: CredentialRead
        switch current {
        case .valid, .corrupt:
            accountRead = current
        case .missing:
            switch alternate {
            case .valid, .corrupt:
                accountRead = alternate
            case .missing:
                accountRead = compatibility
            }
        }
        let provenance =
            readLegacyProvenance(accountID: accountID)
        let legacyRead = readCredential(
            keys: Self.tokenKeys(accountID: nil)
        )
        let ownsSharedCredential =
            ProviderSharedCredentialOwner.isOwner(
                kind: .gemini,
                accountID: accountID
            )
        guard ownsSharedCredential else {
            return .preserveGlobal
        }
        if case .corrupt = provenance {
            return nil
        }
        if case .corrupt = legacyRead {
            return nil
        }
        if deletionOwnsLegacyCredential(
            accountRead: accountRead,
            provenance: provenance,
            legacyRead: legacyRead
        ) {
            guard let identity =
                globalCredentialIdentity(legacyRead)
            else {
                return nil
            }
            return .delete(identity: identity)
        }
        // A previous failed cleanup may already have removed every account
        // slot. The owner + provenance digest still proves that the global
        // credential belongs to this deletion transaction.
        guard
            case let .valid(stored) = provenance,
            let expectedDigest = stored.legacyDigest,
            case let .valid(legacy) = legacyRead,
            expectedDigest == tokenDigest(legacy.tokens),
            let identity =
                globalCredentialIdentity(legacyRead)
        else {
            return .preserveGlobal
        }
        switch accountRead {
        case .missing, .corrupt:
            return .delete(identity: identity)
        case .valid:
            return .preserveGlobal
        }
    }

    private func clearAccountTokensNow(
        accountID: UUID,
        pending:
            GeminiCredentialDeletionOutbox.PendingDeletion
    ) -> Bool {
        guard
            deletionOutbox.credentialEpoch(accountID)
                == pending.targetEpoch
        else {
            return false
        }
        // The monotonic epoch is mapped onto two physical bundle slots.
        // Deleting both slots plus the pre-epoch compatibility slot therefore
        // reaches every credential that any cooperative writer can create.
        let firstSlotDeleted = deleteTokens(
            keys: Self.tokenKeys(
                accountID: accountID,
                credentialEpoch: 0
            )
        )
        let secondSlotDeleted = deleteTokens(
            keys: Self.tokenKeys(
                accountID: accountID,
                credentialEpoch: 1
            )
        )
        let compatibilityDeleted = deleteTokens(
            keys: Self.tokenKeys(accountID: accountID)
        )
        guard
            firstSlotDeleted,
            secondSlotDeleted,
            compatibilityDeleted
        else {
            return false
        }
        if pending.deleteLegacyCredential {
            guard let targetIdentity =
                pending.legacyCredentialIdentity
            else {
                return false
            }
            let stillOwnsGlobal =
                ProviderSharedCredentialOwner.isOwner(
                    kind: .gemini,
                    accountID: accountID
                )
            if stillOwnsGlobal {
                let currentGlobal = readCredential(
                    keys: Self.tokenKeys(accountID: nil)
                )
                let shouldDeleteCurrentGlobal: Bool
                switch currentGlobal {
                case .missing, .corrupt:
                    // Global writes are blocked while this marker is live,
                    // so missing/corrupt state can only be an interrupted
                    // deletion of the targeted credential.
                    shouldDeleteCurrentGlobal = true
                case .valid(let loaded):
                    if loaded.generation != nil {
                        shouldDeleteCurrentGlobal =
                            globalCredentialIdentity(
                                currentGlobal
                            ) == targetIdentity
                    } else {
                        // Pre-bundle/partially deleted legacy records have no
                        // generation. With the global mutation gate below,
                        // they cannot be a later independent authorization.
                        shouldDeleteCurrentGlobal = true
                    }
                }
                if shouldDeleteCurrentGlobal {
                    guard
                        deleteGlobalCredentialAssumingMutationLock()
                    else {
                        return false
                    }
                }
            }
        }
        let markerKey = legacyOwnerKey(
            accountID: accountID
        )
        guard
            ProviderSharedCredentialOwner.release(
                kind: .gemini,
                accountID: accountID
            ),
            secretStore.delete(
                key: markerKey,
                accessGroup: Self.accessGroup
            ),
            secretStore.load(
                key: markerKey,
                accessGroup: Self.accessGroup
            ) == nil
        else {
            return false
        }
        return true
    }

    private func cleanupRetiredCredentialSlots(
        accountID: UUID,
        currentEpoch: UInt64
    ) -> Bool {
        let alternateEpoch: UInt64 =
            currentEpoch % 2 == 0 ? 1 : 0
        let alternateDeleted = deleteTokens(
            keys: Self.tokenKeys(
                accountID: accountID,
                credentialEpoch: alternateEpoch
            )
        )
        let compatibilityDeleted = deleteTokens(
            keys: Self.tokenKeys(accountID: accountID)
        )
        return alternateDeleted && compatibilityDeleted
    }

    /// Called only while holding `credentialMutationLock`. If a live App or
    /// Helper writer existed it would still own that lock, so a remaining
    /// write marker here is an abandoned transaction. Remove only the
    /// uncommitted epoch bundle, then restore the previous active epoch.
    private func recoverAbandonedCredentialWrite(
        accountID: UUID
    ) -> Bool {
        guard deletionOutbox
            .hasPendingCredentialWrite(accountID)
        else {
            return true
        }
        guard
            !deletionOutbox.contains(accountID),
            let pending =
                deletionOutbox
                    .pendingCredentialWrite(accountID)
        else {
            return false
        }
        let failedBundleKey = Self.tokenKeys(
            accountID: accountID,
            credentialEpoch: pending.epoch
        ).bundle
        guard
            secretStore.delete(
                key: failedBundleKey,
                accessGroup: Self.accessGroup
            ),
            secretStore.load(
                key: failedBundleKey,
                accessGroup: Self.accessGroup
            ) == nil
        else {
            return false
        }
        return deletionOutbox.rollbackCredentialWrite(
            accountID,
            operationID: pending.operationID,
            failedEpoch: pending.epoch
        )
    }

    private func migrateGlobalLegacyCredential(
        provenance: LegacyProvenanceRead,
        legacyRead: CredentialRead,
        accountID: UUID,
        accountKeys: TokenKeys
    ) -> GeminiStoredTokens? {
        guard case let .valid(legacy) = legacyRead else {
            return nil
        }
        let digest = tokenDigest(legacy.tokens)
        switch provenance {
        case .corrupt:
            return nil
        case .valid(let existing):
            if let existingDigest = existing.legacyDigest,
               existingDigest != digest {
                return nil
            }
        case .missing:
            break
        }
        guard
            ProviderSharedCredentialOwner.claim(
                kind: .gemini,
                accountID: accountID
            ),
            let epoch =
                deletionOutbox.credentialEpoch(accountID),
            writeLegacyProvenance(
                LegacyProvenance(
                    state: .prepared,
                    legacyDigest: digest,
                    accountGeneration: nil
                ),
                accountID: accountID
            ),
            let copied = copyTokens(
                legacy.tokens,
                to: accountKeys,
                accountID: accountID,
                expectedEpoch: epoch
            ),
            let generation = copied.generation,
            writeLegacyProvenance(
                LegacyProvenance(
                    state: .inherited,
                    legacyDigest: digest,
                    accountGeneration: generation
                ),
                accountID: accountID
            )
        else {
            return nil
        }
        return copied.tokens
    }

    private func migrateLegacyIndividualAccountCredential(
        _ account: LoadedTokenBundle,
        provenance: LegacyProvenanceRead,
        legacyRead: CredentialRead,
        accountID: UUID,
        accountKeys: TokenKeys
    ) -> GeminiStoredTokens? {
        if
            case let .valid(legacy) = legacyRead,
            ProviderSharedCredentialOwner.isOwner(
                kind: .gemini,
                accountID: accountID
            ),
            tokensEquivalent(
                account.tokens,
                legacy.tokens
            )
        {
            let digest = tokenDigest(legacy.tokens)
            if case let .valid(existing) = provenance,
               let existingDigest = existing.legacyDigest,
               existingDigest != digest {
                return nil
            }
            guard
                let epoch =
                    deletionOutbox.credentialEpoch(accountID),
                let copied = copyTokens(
                    account.tokens,
                    to: accountKeys,
                    accountID: accountID,
                    expectedEpoch: epoch
                ),
                let generation = copied.generation,
                writeLegacyProvenance(
                    LegacyProvenance(
                        state: .inherited,
                        legacyDigest: digest,
                        accountGeneration: generation
                    ),
                    accountID: accountID
                )
            else {
                return nil
            }
            return copied.tokens
        }

        guard case .corrupt = provenance else {
            guard
                let epoch =
                    deletionOutbox.credentialEpoch(accountID),
                let migrated = storeTokens(
                    access: account.tokens.accessToken,
                    refresh:
                        account.tokens.refreshToken ?? "",
                    expiresIn: max(
                        0,
                        account.tokens.expiry?
                            .timeIntervalSinceNow ?? 0
                    ),
                    accountID: accountID,
                    origin: .independent,
                    expectedEpoch: epoch
                )
            else {
                return nil
            }
            _ = supersedeLegacyProvenance(
                accountID: accountID
            )
            return migrated.tokens
        }
        return nil
    }

    private func validatedInheritedTokens(
        _ account: LoadedTokenBundle,
        provenance: LegacyProvenanceRead,
        legacyRead: CredentialRead,
        accountID: UUID,
        accountKeys: TokenKeys
    ) -> GeminiStoredTokens? {
        guard
            ProviderSharedCredentialOwner.isOwner(
                kind: .gemini,
                accountID: accountID
            )
        else {
            // Ownership moved to another enabled account. Revoke this stale
            // inherited copy without touching the global source.
            _ = deleteTokens(keys: accountKeys)
            _ = secretStore.delete(
                key: legacyOwnerKey(accountID: accountID),
                accessGroup: Self.accessGroup
            )
            return nil
        }
        let legacyDigest: String?
        if case let .valid(legacy) = legacyRead {
            legacyDigest = tokenDigest(legacy.tokens)
        } else {
            legacyDigest = nil
        }
        switch provenance {
        case .corrupt:
            return nil
        case .missing:
            guard
                case let .valid(legacy) = legacyRead,
                tokensEquivalent(
                    account.tokens,
                    legacy.tokens
                ),
                let generation = account.generation,
                writeLegacyProvenance(
                    LegacyProvenance(
                        state: .inherited,
                        legacyDigest:
                            tokenDigest(legacy.tokens),
                        accountGeneration: generation
                    ),
                    accountID: accountID
                )
            else {
                return nil
            }
            return account.tokens
        case .valid(let stored):
            guard
                let legacyDigest,
                case .valid = legacyRead
            else {
                // An inherited account copy is valid only while its bound
                // global source still exists. A global clear or permanent
                // refresh failure must not leave the copied refresh token
                // usable on its own.
                return nil
            }
            if let expectedDigest = stored.legacyDigest,
               expectedDigest != legacyDigest {
                return nil
            }
            guard let generation = account.generation else {
                return nil
            }
            if stored.state == .inherited,
               stored.accountGeneration == generation {
                return account.tokens
            }
            if stored.state == .inherited,
               stored.accountGeneration
                    == account.parentGeneration,
               writeLegacyProvenance(
                    LegacyProvenance(
                        state: .inherited,
                        legacyDigest:
                            stored.legacyDigest
                                ?? legacyDigest,
                        accountGeneration: generation
                    ),
                    accountID: accountID
               ) {
                return account.tokens
            }
            if stored.accountGeneration == nil,
               writeLegacyProvenance(
                    LegacyProvenance(
                        state: .inherited,
                        legacyDigest: legacyDigest,
                        accountGeneration: generation
                    ),
                    accountID: accountID
               ) {
                return account.tokens
            }
            if stored.state == .prepared,
               stored.legacyDigest == nil
                    || stored.legacyDigest == legacyDigest,
               writeLegacyProvenance(
                    LegacyProvenance(
                        state: .inherited,
                        legacyDigest: legacyDigest,
                        accountGeneration: generation
                    ),
                    accountID: accountID
               ) {
                return account.tokens
            }
            return nil
        }
    }

    private func deletionOwnsLegacyCredential(
        accountRead: CredentialRead,
        provenance: LegacyProvenanceRead,
        legacyRead: CredentialRead
    ) -> Bool {
        guard case let .valid(stored) = provenance else {
            return false
        }
        if case let .valid(account) = accountRead,
           account.origin == .independent {
            return false
        }
        if stored.state == .prepared,
           case let .valid(legacy) = legacyRead {
            return stored.legacyDigest == nil
                || stored.legacyDigest
                    == tokenDigest(legacy.tokens)
        }
        guard
            stored.state == .inherited,
            case let .valid(account) = accountRead,
            case let .valid(legacy) = legacyRead,
            let expectedDigest = stored.legacyDigest,
            expectedDigest == tokenDigest(legacy.tokens)
        else {
            return false
        }
        if account.origin == .independent {
            return false
        }
        if let generation = stored.accountGeneration {
            return account.generation == generation
                || account.parentGeneration == generation
        }
        guard case let .valid(legacy) = legacyRead else {
            return false
        }
        return tokensEquivalent(
            account.tokens,
            legacy.tokens
        )
    }

    private func legacyOwnerKey(
        accountID: UUID
    ) -> String {
        Self.accountKey(
            Self.keyLegacyOwner,
            accountID: accountID
        )
    }

    private func readLegacyProvenance(
        accountID: UUID
    ) -> LegacyProvenanceRead {
        guard let raw = secretStore.load(
            key: legacyOwnerKey(accountID: accountID),
            accessGroup: Self.accessGroup
        ) else {
            return .missing
        }
        if raw == "prepared" {
            return .valid(
                LegacyProvenance(
                    state: .prepared,
                    legacyDigest: nil,
                    accountGeneration: nil
                )
            )
        }
        if raw == "inherited" || raw == "1" {
            return .valid(
                LegacyProvenance(
                    state: .inherited,
                    legacyDigest: nil,
                    accountGeneration: nil
                )
            )
        }
        let parts = raw.split(
            separator: "|",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard
            parts.count >= 2,
            let state = LegacyMigrationState(
                rawValue: parts[0]
            ),
            !parts[1].isEmpty
        else {
            return .corrupt
        }
        let generation =
            parts.count > 2 && !parts[2].isEmpty
                ? parts[2] : nil
        if state == .inherited,
           generation.flatMap(UUID.init(uuidString:)) == nil {
            return .corrupt
        }
        return .valid(
            LegacyProvenance(
                state: state,
                legacyDigest: parts[1],
                accountGeneration: generation
            )
        )
    }

    private func writeLegacyProvenance(
        _ provenance: LegacyProvenance,
        accountID: UUID
    ) -> Bool {
        guard let digest = provenance.legacyDigest else {
            return false
        }
        let value: String
        switch provenance.state {
        case .prepared:
            value = "prepared|\(digest)"
        case .inherited:
            guard let generation =
                provenance.accountGeneration
            else {
                return false
            }
            value =
                "inherited|\(digest)|\(generation)"
        }
        let key = legacyOwnerKey(accountID: accountID)
        guard secretStore.save(
            key: key,
            value: value,
            accessGroup: Self.accessGroup
        ) else {
            return false
        }
        return secretStore.load(
            key: key,
            accessGroup: Self.accessGroup
        ) == value
    }

    private func supersedeLegacyProvenance(
        accountID: UUID
    ) -> Bool {
        let key = legacyOwnerKey(accountID: accountID)
        guard
            ProviderSharedCredentialOwner.release(
                kind: .gemini,
                accountID: accountID
            ),
            secretStore.delete(
                key: key,
                accessGroup: Self.accessGroup
            ),
            secretStore.load(
                key: key,
                accessGroup: Self.accessGroup
            ) == nil
        else {
            return false
        }
        return true
    }

    private func advanceInheritedProvenanceAfterRefresh(
        accountID: UUID,
        previousGeneration: String?,
        newGeneration: String?
    ) -> Bool {
        guard
            let previousGeneration,
            let newGeneration,
            case let .valid(provenance) =
                readLegacyProvenance(
                    accountID: accountID
                ),
            provenance.state == .inherited,
            provenance.accountGeneration
                == previousGeneration,
            provenance.legacyDigest != nil
        else {
            return false
        }
        return writeLegacyProvenance(
            LegacyProvenance(
                state: .inherited,
                legacyDigest: provenance.legacyDigest,
                accountGeneration: newGeneration
            ),
            accountID: accountID
        )
    }

    private func tokenDigest(
        _ tokens: GeminiStoredTokens
    ) -> String {
        let canonical = [
            tokens.accessToken,
            tokens.refreshToken ?? "<nil>",
            tokens.expiry.map {
                String($0.timeIntervalSince1970)
            } ?? "<nil>",
        ].joined(separator: "\u{0}")
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func secretValueDigest(
        _ value: String
    ) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func currentLegacyGlobalKeyDigests()
        -> GlobalLegacyKeyDigests?
    {
        let keys = Self.tokenKeys(accountID: nil)
        let access = secretStore.load(
            key: keys.access,
            accessGroup: Self.accessGroup
        ).map(secretValueDigest)
        let refresh = secretStore.load(
            key: keys.refresh,
            accessGroup: Self.accessGroup
        ).map(secretValueDigest)
        let expiry = secretStore.load(
            key: keys.expiry,
            accessGroup: Self.accessGroup
        ).map(secretValueDigest)
        guard
            access != nil
                || refresh != nil
                || expiry != nil
        else {
            return nil
        }
        return GlobalLegacyKeyDigests(
            access: access,
            refresh: refresh,
            expiry: expiry
        )
    }

    private func globalCredentialIdentity(
        _ read: CredentialRead
    ) -> String? {
        guard case let .valid(loaded) = read else {
            return nil
        }
        if let generation = loaded.generation {
            return "generation:\(generation)"
        }
        return "digest:\(tokenDigest(loaded.tokens))"
    }

    private func tokensEquivalent(
        _ lhs: GeminiStoredTokens,
        _ rhs: GeminiStoredTokens
    ) -> Bool {
        guard
            lhs.accessToken == rhs.accessToken,
            lhs.refreshToken == rhs.refreshToken
        else {
            return false
        }
        switch (lhs.expiry, rhs.expiry) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return abs(
                lhs.timeIntervalSince1970
                    - rhs.timeIntervalSince1970
            ) < 0.001
        default:
            return false
        }
    }

    private func withCredentialLock<T>(
        _ body: () -> T
    ) -> T {
        credentialLock.lock()
        defer { credentialLock.unlock() }
        return body()
    }

    // MARK: - Private helpers

    private struct TokenBundle {
        let access: String
        let refresh: String
        let expiresIn: TimeInterval
    }

    private enum StoredTokenOrigin: String, Codable {
        case independent
        case legacyCopy
    }

    private struct StoredTokenBundle: Codable {
        let version: Int
        let generation: String
        let parentGeneration: String?
        let origin: StoredTokenOrigin
        let accessToken: String
        let refreshToken: String?
        let expiry: Double?
    }

    private enum GlobalTransactionOperation:
        String,
        Codable,
        Equatable
    {
        case replace
        case clear
    }

    private struct GlobalCredentialTransaction:
        Codable,
        Equatable
    {
        let version: Int
        let operationID: String
        let authorizationNonce: String
        let operation: GlobalTransactionOperation
        let expectedOldIdentity: String?
        let targetGeneration: String?
        let legacyKeyDigests: GlobalLegacyKeyDigests?
    }

    private struct GlobalLegacyKeyDigests:
        Codable,
        Equatable
    {
        let access: String?
        let refresh: String?
        let expiry: String?
    }

    private enum GlobalCredentialTransactionRead {
        case missing
        case valid(GlobalCredentialTransaction)
        case corrupt
    }

    private enum SecureFileRead {
        case missing
        case data(Data)
        case invalid
    }

    private struct LoadedTokenBundle {
        let tokens: GeminiStoredTokens
        let generation: String?
        let parentGeneration: String?
        let origin: StoredTokenOrigin?
    }

    private struct RefreshCredentialContext {
        let refreshToken: String
        let epoch: UInt64?
        let origin: StoredTokenOrigin
        let generation: String?
    }

    private enum CredentialRead {
        case missing
        case valid(LoadedTokenBundle)
        case corrupt
    }

    private struct TokenKeys {
        let bundle: String
        let access: String
        let refresh: String
        let expiry: String
    }

    private struct AccountCredentialSelection {
        let read: CredentialRead
        let keys: TokenKeys
    }

    private static func tokenKeys(
        accountID: UUID?,
        credentialEpoch: UInt64? = nil
    ) -> TokenKeys {
        guard let accountID else {
            return TokenKeys(
                bundle: keyBundle,
                access: keyAccessToken,
                refresh: keyRefreshToken,
                expiry: keyExpiry
            )
        }
        return TokenKeys(
            bundle: credentialEpoch.map {
                accountBundleKey(
                    accountID: accountID,
                    credentialEpoch: $0
                )
            } ?? accountKey(
                keyBundle,
                accountID: accountID
            ),
            access: accountKey(keyAccessToken, accountID: accountID),
            refresh: accountKey(keyRefreshToken, accountID: accountID),
            expiry: accountKey(keyExpiry, accountID: accountID)
        )
    }

    private func readCredential(
        keys: TokenKeys,
        allowLegacyIndividualFallback: Bool = true
    ) -> CredentialRead {
        if let rawBundle = secretStore.load(
            key: keys.bundle,
            accessGroup: Self.accessGroup
        ) {
            guard
                let data = rawBundle.data(using: .utf8),
                let stored = try? JSONDecoder().decode(
                    StoredTokenBundle.self,
                    from: data
                ),
                stored.version == 1,
                UUID(uuidString: stored.generation) != nil,
                !stored.accessToken.isEmpty
            else {
                return .corrupt
            }
            return .valid(
                LoadedTokenBundle(
                    tokens: GeminiStoredTokens(
                        accessToken: stored.accessToken,
                        refreshToken: stored.refreshToken,
                        expiry: stored.expiry.map {
                            Date(timeIntervalSince1970: $0)
                        }
                    ),
                    generation: stored.generation,
                    parentGeneration:
                        stored.parentGeneration,
                    origin: stored.origin
                )
            )
        }
        guard allowLegacyIndividualFallback else {
            return .missing
        }
        guard let legacy = loadLegacyIndividualTokens(
            keys: keys
        ) else {
            return .missing
        }
        return .valid(
            LoadedTokenBundle(
                tokens: legacy,
                generation: nil,
                parentGeneration: nil,
                origin: nil
            )
        )
    }

    /// Selects only the bundle belonging to the current credential epoch.
    /// Epoch zero may read the pre-epoch account slot for a one-way
    /// compatibility transition. Once an account has mutated, old slots are
    /// never considered again, so a retired writer cannot resurrect them.
    private func readAccountCredential(
        accountID: UUID,
        credentialEpoch: UInt64
    ) -> AccountCredentialSelection {
        let currentKeys = Self.tokenKeys(
            accountID: accountID,
            credentialEpoch: credentialEpoch
        )
        let current = readCredential(
            keys: currentKeys,
            allowLegacyIndividualFallback: false
        )
        switch current {
        case .valid, .corrupt:
            return AccountCredentialSelection(
                read: current,
                keys: currentKeys
            )
        case .missing:
            break
        }
        guard credentialEpoch == 0 else {
            return AccountCredentialSelection(
                read: .missing,
                keys: currentKeys
            )
        }
        let legacyKeys = Self.tokenKeys(
            accountID: accountID
        )
        return AccountCredentialSelection(
            read: readCredential(keys: legacyKeys),
            keys: legacyKeys
        )
    }

    private func refreshCredentialContext(
        accountID: UUID?
    ) -> RefreshCredentialContext? {
        if let accountID {
            guard
                let epoch =
                    deletionOutbox
                        .credentialEpoch(accountID),
                !deletionOutbox.contains(accountID),
                !deletionOutbox
                    .hasPendingCredentialWrite(accountID),
                let tokens = loadTokens(
                    accountID: accountID
                ),
                let refresh = tokens.refreshToken,
                !refresh.isEmpty
            else {
                return nil
            }
            let selection = readAccountCredential(
                accountID: accountID,
                credentialEpoch: epoch
            )
            guard
                case let .valid(loaded) = selection.read,
                deletionOutbox
                    .credentialEpoch(accountID) == epoch,
                !deletionOutbox.contains(accountID),
                !deletionOutbox
                    .hasPendingCredentialWrite(accountID)
            else {
                return nil
            }
            return RefreshCredentialContext(
                refreshToken: refresh,
                epoch: epoch,
                origin: loaded.origin ?? .independent,
                generation: loaded.generation
            )
        }
        guard
            case let .valid(loaded) = readCredential(
                keys: Self.tokenKeys(accountID: nil)
            ),
            let refresh = loaded.tokens.refreshToken,
            !refresh.isEmpty
        else {
            return nil
        }
        return RefreshCredentialContext(
            refreshToken: refresh,
            epoch: nil,
            origin: loaded.origin ?? .independent,
            generation: loaded.generation
        )
    }

    private func exchangeCode(_ code: String, codeVerifier: String) async throws -> TokenBundle {
        let body = Self.formEncode([
            "client_id":     Self.clientID,
            "code":          code,
            "code_verifier": codeVerifier,
            "grant_type":    "authorization_code",
            "redirect_uri":  Self.redirectURI,
        ])

        var req = URLRequest(url: URL(string: Self.tokenEndpoint)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        req.httpBody = body.data(using: .utf8)

        let (data, resp) = try await tokenDataLoader(req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            throw GeminiOAuthError.tokenExchangeFailed(status)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let at = json["access_token"] as? String else {
            throw GeminiOAuthError.invalidTokenResponse
        }

        return TokenBundle(
            access:    at,
            refresh:   json["refresh_token"] as? String ?? "",
            expiresIn: (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        )
    }

    private func storeTokens(
        access: String,
        refresh: String,
        expiresIn: TimeInterval,
        accountID: UUID?,
        origin: StoredTokenOrigin,
        parentGeneration: String? = nil,
        expectedEpoch: UInt64? = nil,
        credentialWriteID: String? = nil
    ) -> LoadedTokenBundle? {
        credentialMutationLock.withLock(
            or: Optional<LoadedTokenBundle>.none
        ) {
            storeTokensAssumingMutationLock(
                access: access,
                refresh: refresh,
                expiresIn: expiresIn,
                accountID: accountID,
                origin: origin,
                parentGeneration: parentGeneration,
                expectedEpoch: expectedEpoch,
                credentialWriteID: credentialWriteID
            )
        }
    }

    private func storeTokensAssumingMutationLock(
        access: String,
        refresh: String,
        expiresIn: TimeInterval,
        accountID: UUID?,
        origin: StoredTokenOrigin,
        parentGeneration: String? = nil,
        expectedEpoch: UInt64? = nil,
        credentialWriteID: String? = nil
    ) -> LoadedTokenBundle? {
        if let accountID {
            guard
                let expectedEpoch,
                deletionOutbox
                    .credentialEpoch(accountID)
                    == expectedEpoch
            else {
                return nil
            }
            if let credentialWriteID {
                guard
                    !deletionOutbox.contains(accountID),
                    deletionOutbox.matchesCredentialWrite(
                        accountID,
                        operationID: credentialWriteID
                    )
                else {
                    return nil
                }
            } else {
                guard
                    !deletionOutbox.contains(accountID),
                    !deletionOutbox
                        .hasPendingCredentialWrite(
                            accountID
                        )
                else {
                    return nil
                }
            }
        }
        let group = Self.accessGroup
        let keys = Self.tokenKeys(
            accountID: accountID,
            credentialEpoch: expectedEpoch
        )
        let previousBundle = secretStore.load(
            key: keys.bundle,
            accessGroup: group
        )
        let stored = StoredTokenBundle(
            version: 1,
            generation: UUID().uuidString.lowercased(),
            parentGeneration: parentGeneration,
            origin: origin,
            accessToken: access,
            refreshToken: refresh.isEmpty ? nil : refresh,
            expiry:
                Date()
                    .addingTimeInterval(expiresIn)
                    .timeIntervalSince1970
        )
        guard
            let data = try? JSONEncoder().encode(stored),
            let encoded = String(
                data: data,
                encoding: .utf8
            )
        else {
            return nil
        }
        if accountID == nil {
            return replaceGlobalCredentialAssumingMutationLock(
                stored: stored,
                encoded: encoded
            )
        }
        guard
            secretStore.save(
                key: keys.bundle,
                value: encoded,
                accessGroup: group
            )
        else {
            return nil
        }
        guard
            secretStore.load(
                key: keys.bundle,
                accessGroup: group
            ) == encoded,
            case let .valid(loaded) =
                readCredential(keys: keys),
            loaded.generation == stored.generation,
            loaded.tokens.accessToken == access,
            loaded.tokens.refreshToken
                == (refresh.isEmpty ? nil : refresh)
        else {
            restoreAtomicBundle(
                previousBundle,
                keys: keys
            )
            return nil
        }

        if let accountID {
            guard
                deletionOutbox
                    .credentialEpoch(accountID)
                    == expectedEpoch
            else {
                // Disconnect won the race. Never restore the old bundle here:
                // the deletion path may already have removed it.
                _ = secretStore.delete(
                    key: keys.bundle,
                    accessGroup: group
                )
                return nil
            }
            if let credentialWriteID {
                guard
                    !deletionOutbox.contains(accountID),
                    deletionOutbox.matchesCredentialWrite(
                        accountID,
                        operationID: credentialWriteID
                    )
                else {
                    _ = secretStore.delete(
                        key: keys.bundle,
                        accessGroup: group
                    )
                    return nil
                }
            } else {
                guard
                    !deletionOutbox.contains(accountID),
                    !deletionOutbox
                        .hasPendingCredentialWrite(
                            accountID
                        )
                else {
                    _ = secretStore.delete(
                        key: keys.bundle,
                        accessGroup: group
                    )
                    return nil
                }
            }
        }

        return loaded
    }

    /// Publishes the Keychain bundle and helper JSON as one recoverable
    /// cross-resource transaction. The marker is durable before either live
    /// representation changes, so the App or Helper can fail closed until a
    /// later App process finishes the same operation under the shared lock.
    private func replaceGlobalCredentialAssumingMutationLock(
        stored: StoredTokenBundle,
        encoded: String
    ) -> LoadedTokenBundle? {
        guard
            recoverGlobalCredentialTransactionAssumingMutationLock()
        else {
            return nil
        }
        let current = readCredential(
            keys: Self.tokenKeys(accountID: nil)
        )
        if case .corrupt = current {
            return nil
        }
        let transaction = GlobalCredentialTransaction(
            version: 1,
            operationID:
                UUID().uuidString.lowercased(),
            authorizationNonce:
                UUID().uuidString.lowercased(),
            operation: .replace,
            expectedOldIdentity:
                globalCredentialIdentity(current),
            targetGeneration: stored.generation,
            legacyKeyDigests:
                currentLegacyGlobalKeyDigests()
        )
        guard
            writeAuthorizedGlobalTransaction(
                transaction
            )
        else {
            return nil
        }
        guard
            secretStore.save(
                key: Self.keyGlobalPendingBundle,
                value: encoded,
                accessGroup: Self.accessGroup
            ),
            secretStore.load(
                key: Self.keyGlobalPendingBundle,
                accessGroup: Self.accessGroup
            ) == encoded
        else {
            _ = abortGlobalCredentialTransaction(
                transaction
            )
            return nil
        }
        guard
            finishGlobalCredentialTransaction(
                transaction
            ),
            case let .valid(loaded) = readCredential(
                keys: Self.tokenKeys(accountID: nil)
            ),
            loaded.generation == stored.generation
        else {
            return nil
        }
        return loaded
    }

    private func deleteGlobalCredentialAssumingMutationLock()
        -> Bool
    {
        guard
            recoverGlobalCredentialTransactionAssumingMutationLock()
        else {
            return false
        }
        let current = readCredential(
            keys: Self.tokenKeys(accountID: nil)
        )
        if case .corrupt = current {
            return false
        }
        let transaction = GlobalCredentialTransaction(
            version: 1,
            operationID:
                UUID().uuidString.lowercased(),
            authorizationNonce:
                UUID().uuidString.lowercased(),
            operation: .clear,
            expectedOldIdentity:
                globalCredentialIdentity(current),
            targetGeneration: nil,
            legacyKeyDigests:
                currentLegacyGlobalKeyDigests()
        )
        guard
            writeAuthorizedGlobalTransaction(
                transaction
            )
        else {
            return false
        }
        return finishGlobalCredentialTransaction(
            transaction
        )
    }

    /// Called only while holding `credentialMutationLock`.
    private func recoverGlobalCredentialTransactionAssumingMutationLock()
        -> Bool
    {
        let marker = readGlobalTransactionMarker()
        let control = readGlobalTransactionControl()
        switch (marker, control) {
        case (.missing, .missing):
            return true
        case (
            .valid(let markerTransaction),
            .valid(let controlTransaction)
        ):
            guard
                markerTransaction
                    == controlTransaction
            else {
                return false
            }
            return finishGlobalCredentialTransaction(
                markerTransaction
            )
        case (
            .missing,
            .valid(let controlTransaction)
        ):
            // The Keychain record is authoritative. A crash can happen after
            // it is committed but before the disk marker is durable, or after
            // the marker is removed during final cleanup. Recreate the marker
            // and resume the idempotent transaction.
            guard
                writeGlobalTransactionMarker(
                    controlTransaction
                )
            else {
                return false
            }
            return finishGlobalCredentialTransaction(
                controlTransaction
            )
        case (.corrupt, _), (_, .corrupt):
            return false
        case (.valid, .missing):
            // A same-user process can write the helper directory but cannot
            // authorize Keychain mutation. Never execute a disk-only marker.
            return false
        }
    }

    private func finishGlobalCredentialTransaction(
        _ transaction: GlobalCredentialTransaction
    ) -> Bool {
        guard
            globalTransactionIsAuthorized(
                transaction
            )
        else {
            return false
        }
        switch transaction.operation {
        case .replace:
            return finishGlobalCredentialReplacement(
                transaction
            )
        case .clear:
            return finishGlobalCredentialClear(
                transaction
            )
        }
    }

    private func finishGlobalCredentialReplacement(
        _ transaction: GlobalCredentialTransaction
    ) -> Bool {
        guard
            let targetGeneration =
                transaction.targetGeneration,
            UUID(uuidString: targetGeneration) != nil
        else {
            return false
        }

        let globalKeys = Self.tokenKeys(accountID: nil)
        var activeRead = readCredential(keys: globalKeys)
        let activeIdentity =
            globalCredentialIdentity(activeRead)
        let targetIdentity =
            "generation:\(targetGeneration)"
        if activeIdentity != targetIdentity {
            guard
                activeIdentity
                    == transaction.expectedOldIdentity
            else {
                return false
            }
            guard
                let pendingRaw = secretStore.load(
                    key: Self.keyGlobalPendingBundle,
                    accessGroup: Self.accessGroup
                )
            else {
                // The marker is the first durable write. A crash before the
                // pending Keychain bundle is saved leaves the old active
                // credential untouched, so this empty transaction can be
                // safely rolled back instead of blocking every future read.
                return abortGlobalCredentialTransaction(
                    transaction
                )
            }
            guard
                let pending =
                    decodeStoredTokenBundle(
                        pendingRaw,
                        expectedGeneration:
                            targetGeneration
                    )
            else {
                // No live representation changed yet. Treat a malformed
                // pending bundle as unusable transaction input and preserve
                // the verified old active credential.
                return abortGlobalCredentialTransaction(
                    transaction
                )
            }
            guard
                secretStore.save(
                    key: globalKeys.bundle,
                    value: pendingRaw,
                    accessGroup: Self.accessGroup
                ),
                secretStore.load(
                    key: globalKeys.bundle,
                    accessGroup: Self.accessGroup
                ) == pendingRaw
            else {
                return false
            }
            activeRead = readCredential(keys: globalKeys)
            guard
                globalCredentialIdentity(activeRead)
                    == targetIdentity,
                pending.generation == targetGeneration
            else {
                return false
            }
        }

        guard
            let activeRaw = secretStore.load(
                key: globalKeys.bundle,
                accessGroup: Self.accessGroup
            ),
            let activeStored = decodeStoredTokenBundle(
                activeRaw,
                expectedGeneration: targetGeneration
            ),
            let sharedData =
                encodeSharedCredentialFile(
                    activeStored
                )
        else {
            return false
        }

        let stagePath =
            Self.globalTransactionStagePath(
                sharedTokenFilePath: tokenFilePath,
                operationID:
                    transaction.operationID
            )
        guard
            writeSecureFile(
                sharedData,
                path: stagePath
            ),
            verifySharedCredentialFile(
                path: stagePath,
                stored: activeStored
            ),
            publishSecureFile(
                from: stagePath,
                to: tokenFilePath
            ),
            verifySharedCredentialFile(
                path: tokenFilePath,
                stored: activeStored
            ),
            deleteLegacyGlobalIndividualTokens(
                matching:
                    transaction.legacyKeyDigests
            ),
            deletePendingGlobalBundle(),
            removeSecureFile(
                path:
                    Self.globalTransactionMarkerPath(
                        sharedTokenFilePath:
                            tokenFilePath
                    )
            ),
            deleteGlobalTransactionControl()
        else {
            return false
        }
        return globalTransactionMetadataIsMissing()
    }

    private func finishGlobalCredentialClear(
        _ transaction: GlobalCredentialTransaction
    ) -> Bool {
        guard transaction.targetGeneration == nil else {
            return false
        }
        let current = readCredential(
            keys: Self.tokenKeys(accountID: nil)
        )
        switch current {
        case .corrupt:
            return false
        case .missing:
            break
        case .valid(let loaded):
            let identity =
                globalCredentialIdentity(current)
            if loaded.generation != nil {
                guard
                    identity
                        == transaction
                            .expectedOldIdentity
                else {
                    // A bundled credential with another generation can only
                    // be a later replacement; never let an old clear marker
                    // delete it.
                    return false
                }
            } else {
                guard
                    transaction
                        .expectedOldIdentity?
                        .hasPrefix("digest:")
                        == true,
                    transaction
                        .legacyKeyDigests
                        != nil
                else {
                    return false
                }
            }
            // A legacy clear can stop between keys and change the aggregate
            // digest. Per-key digests below delete only fields that still
            // match the original target; a later writer's field survives.
        }
        let stagePath =
            Self.globalTransactionStagePath(
                sharedTokenFilePath: tokenFilePath,
                operationID:
                    transaction.operationID
            )
        guard
            deleteGlobalBundle(),
            deleteLegacyGlobalIndividualTokens(
                matching:
                    transaction.legacyKeyDigests
            ),
            removeSecureFile(path: tokenFilePath),
            removeSecureFile(path: stagePath),
            deletePendingGlobalBundle(),
            removeSecureFile(
                path:
                    Self.globalTransactionMarkerPath(
                        sharedTokenFilePath:
                            tokenFilePath
                    )
            ),
            deleteGlobalTransactionControl()
        else {
            return false
        }
        return globalTransactionMetadataIsMissing()
    }

    private func abortGlobalCredentialTransaction(
        _ transaction: GlobalCredentialTransaction
    ) -> Bool {
        let stagePath =
            Self.globalTransactionStagePath(
                sharedTokenFilePath: tokenFilePath,
                operationID:
                    transaction.operationID
            )
        guard
            removeSecureFile(path: stagePath),
            removeSecureFile(
                path: "\(stagePath).tmp"
            ),
            deletePendingGlobalBundle(),
            removeSecureFile(
                path:
                    Self.globalTransactionMarkerPath(
                        sharedTokenFilePath:
                            tokenFilePath
                    )
            ),
            deleteGlobalTransactionControl()
        else {
            // Keep both authorization records whenever a secret-bearing
            // staged file or pending Keychain bundle cannot be removed. The
            // Helper remains fail-closed and the next App process can retry.
            return false
        }
        return globalTransactionMetadataIsMissing()
    }

    private func deletePendingGlobalBundle() -> Bool {
        guard
            secretStore.load(
                key: Self.keyGlobalPendingBundle,
                accessGroup: Self.accessGroup
            ) != nil
        else {
            return true
        }
        return secretStore.delete(
            key: Self.keyGlobalPendingBundle,
            accessGroup: Self.accessGroup
        )
            && secretStore.load(
                key: Self.keyGlobalPendingBundle,
                accessGroup: Self.accessGroup
            ) == nil
    }

    private func deleteLegacyGlobalIndividualTokens(
        matching expected:
            GlobalLegacyKeyDigests?
    ) -> Bool {
        guard let expected else {
            return true
        }
        let keys = Self.tokenKeys(accountID: nil)
        return deleteLegacyGlobalValue(
            key: keys.access,
            expectedDigest: expected.access
        )
            && deleteLegacyGlobalValue(
                key: keys.refresh,
                expectedDigest: expected.refresh
            )
            && deleteLegacyGlobalValue(
                key: keys.expiry,
                expectedDigest: expected.expiry
            )
    }

    private func deleteLegacyGlobalValue(
        key: String,
        expectedDigest: String?
    ) -> Bool {
        guard let expectedDigest else {
            // The field did not exist when this transaction began. If another
            // process creates it later, it is not part of our delete target.
            return true
        }
        guard
            let current = secretStore.load(
                key: key,
                accessGroup: Self.accessGroup
            )
        else {
            return true
        }
        guard
            secretValueDigest(current)
                == expectedDigest
        else {
            // A later writer replaced this individual field. Preserve it.
            return true
        }
        return secretStore.delete(
            key: key,
            accessGroup: Self.accessGroup
        )
            && secretStore.load(
                key: key,
                accessGroup: Self.accessGroup
            ) == nil
    }

    private func deleteGlobalBundle() -> Bool {
        let key = Self.tokenKeys(accountID: nil).bundle
        guard
            secretStore.load(
                key: key,
                accessGroup: Self.accessGroup
            ) != nil
        else {
            return true
        }
        return secretStore.delete(
            key: key,
            accessGroup: Self.accessGroup
        )
            && secretStore.load(
                key: key,
                accessGroup: Self.accessGroup
            ) == nil
    }

    private func decodeStoredTokenBundle(
        _ raw: String,
        expectedGeneration: String
    ) -> StoredTokenBundle? {
        guard
            let data = raw.data(using: .utf8),
            let stored = try? JSONDecoder().decode(
                StoredTokenBundle.self,
                from: data
            ),
            stored.version == 1,
            stored.generation
                == expectedGeneration,
            UUID(uuidString: stored.generation) != nil,
            !stored.accessToken.isEmpty,
            stored.expiry?.isFinite != false
        else {
            return nil
        }
        return stored
    }

    private func restoreAtomicBundle(
        _ previous: String?,
        keys: TokenKeys
    ) {
        if let previous {
            _ = secretStore.save(
                key: keys.bundle,
                value: previous,
                accessGroup: Self.accessGroup
            )
        } else {
            _ = secretStore.delete(
                key: keys.bundle,
                accessGroup: Self.accessGroup
            )
        }
    }

    private func writeAuthorizedGlobalTransaction(
        _ transaction: GlobalCredentialTransaction
    ) -> Bool {
        guard
            writeGlobalTransactionControl(
                transaction
            )
        else {
            return false
        }
        guard
            writeGlobalTransactionMarker(
                transaction
            )
        else {
            // No credential representation has changed yet. If no valid
            // marker exists, remove the just-created authorization record;
            // otherwise leave both for deterministic recovery.
            if
                case let .valid(persisted) =
                    readGlobalTransactionMarker(),
                persisted == transaction
            {
                return false
            }
            _ = deleteGlobalTransactionControl()
            return false
        }
        return true
    }

    private func encodedGlobalTransaction(
        _ transaction: GlobalCredentialTransaction
    ) -> Data? {
        guard
            validateGlobalTransaction(transaction),
            let data = try? JSONEncoder().encode(
                transaction
            )
        else {
            return nil
        }
        return data
    }

    private func writeGlobalTransactionControl(
        _ transaction: GlobalCredentialTransaction
    ) -> Bool {
        guard
            let data =
                encodedGlobalTransaction(
                    transaction
                ),
            let encoded = String(
                data: data,
                encoding: .utf8
            )
        else {
            return false
        }
        return secretStore.save(
            key:
                Self
                    .keyGlobalTransactionControl,
            value: encoded,
            accessGroup: Self.accessGroup
        )
            && secretStore.load(
                key:
                    Self
                        .keyGlobalTransactionControl,
                accessGroup: Self.accessGroup
            ) == encoded
    }

    private func writeGlobalTransactionMarker(
        _ transaction: GlobalCredentialTransaction
    ) -> Bool {
        guard
            let data =
                encodedGlobalTransaction(
                    transaction
                )
        else {
            return false
        }
        let path =
            Self.globalTransactionMarkerPath(
                sharedTokenFilePath: tokenFilePath
            )
        return writeSecureFile(data, path: path)
            && {
                guard
                    case let .valid(persisted) =
                        readGlobalTransactionMarker()
                else {
                    return false
                }
                return persisted == transaction
            }()
    }

    private func readGlobalTransactionMarker()
        -> GlobalCredentialTransactionRead
    {
        let path =
            Self.globalTransactionMarkerPath(
                sharedTokenFilePath: tokenFilePath
            )
        switch readSecureFile(
            path: path,
            maximumBytes: 16 * 1024
        ) {
        case .missing:
            return .missing
        case .invalid:
            return .corrupt
        case .data(let data):
            guard
                let transaction =
                    try? JSONDecoder().decode(
                        GlobalCredentialTransaction.self,
                        from: data
                    ),
                validateGlobalTransaction(
                    transaction
                )
            else {
                return .corrupt
            }
            return .valid(transaction)
        }
    }

    private func readGlobalTransactionControl()
        -> GlobalCredentialTransactionRead
    {
        guard
            let raw = secretStore.load(
                key:
                    Self
                        .keyGlobalTransactionControl,
                accessGroup: Self.accessGroup
            )
        else {
            return .missing
        }
        guard
            let data = raw.data(using: .utf8),
            let transaction =
                try? JSONDecoder().decode(
                    GlobalCredentialTransaction.self,
                    from: data
                ),
            validateGlobalTransaction(
                transaction
            )
        else {
            return .corrupt
        }
        return .valid(transaction)
    }

    private func deleteGlobalTransactionControl()
        -> Bool
    {
        guard
            secretStore.load(
                key:
                    Self
                        .keyGlobalTransactionControl,
                accessGroup: Self.accessGroup
            ) != nil
        else {
            return true
        }
        return secretStore.delete(
            key:
                Self
                    .keyGlobalTransactionControl,
            accessGroup: Self.accessGroup
        )
            && secretStore.load(
                key:
                    Self
                        .keyGlobalTransactionControl,
                accessGroup: Self.accessGroup
            ) == nil
    }

    private func globalTransactionIsAuthorized(
        _ transaction: GlobalCredentialTransaction
    ) -> Bool {
        guard
            case let .valid(marker) =
                readGlobalTransactionMarker(),
            case let .valid(control) =
                readGlobalTransactionControl()
        else {
            return false
        }
        return marker == transaction
            && control == transaction
    }

    private func globalTransactionMetadataIsMissing()
        -> Bool
    {
        guard
            case .missing =
                readGlobalTransactionMarker(),
            case .missing =
                readGlobalTransactionControl()
        else {
            return false
        }
        return true
    }

    private func validateGlobalTransaction(
        _ transaction: GlobalCredentialTransaction
    ) -> Bool {
        guard
            transaction.version == 1,
            UUID(
                uuidString:
                    transaction.operationID
            ) != nil,
            UUID(
                uuidString:
                    transaction
                        .authorizationNonce
            ) != nil,
            transaction.expectedOldIdentity.map(
                Self.isValidGlobalCredentialIdentity
            ) != false,
            validateLegacyKeyDigests(
                transaction.legacyKeyDigests
            )
        else {
            return false
        }
        switch transaction.operation {
        case .replace:
            guard
                let generation =
                    transaction.targetGeneration,
                UUID(uuidString: generation) != nil
            else {
                return false
            }
            return true
        case .clear:
            return transaction.targetGeneration == nil
        }
    }

    private func validateLegacyKeyDigests(
        _ digests: GlobalLegacyKeyDigests?
    ) -> Bool {
        guard let digests else {
            return true
        }
        let values = [
            digests.access,
            digests.refresh,
            digests.expiry,
        ]
        guard values.contains(where: { $0 != nil })
        else {
            return false
        }
        return values.allSatisfy {
            $0.map(Self.isValidSHA256Digest)
                ?? true
        }
    }

    private static func isValidSHA256Digest(
        _ value: String
    ) -> Bool {
        value.count == 64
            && value.allSatisfy {
                ("0"..."9").contains($0)
                    || ("a"..."f").contains($0)
            }
    }

    private static func isValidGlobalCredentialIdentity(
        _ identity: String
    ) -> Bool {
        if identity.hasPrefix("generation:") {
            let value = String(
                identity.dropFirst(
                    "generation:".count
                )
            )
            return UUID(uuidString: value) != nil
        }
        guard identity.hasPrefix("digest:") else {
            return false
        }
        let value = identity.dropFirst(
            "digest:".count
        )
        return isValidSHA256Digest(
            String(value)
        )
    }

    /// The helper file intentionally excludes the refresh token. Its
    /// generation binds it to the active Keychain bundle during recovery.
    private func encodeSharedCredentialFile(
        _ stored: StoredTokenBundle
    ) -> Data? {
        var object: [String: Any] = [
            "version": 1,
            "generation": stored.generation,
            "access_token": stored.accessToken,
            "client_id": Self.clientID,
        ]
        if let expiry = stored.expiry {
            let milliseconds =
                (expiry * 1000)
                    .rounded(.towardZero)
            guard
                milliseconds.isFinite,
                let exact =
                    Int64(exactly: milliseconds)
            else {
                return nil
            }
            object["expiry_date"] = exact
        }
        return try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    private func verifySharedCredentialFile(
        path: String,
        stored: StoredTokenBundle
    ) -> Bool {
        guard
            case let .data(data) = readSecureFile(
                path: path,
                maximumBytes: 1024 * 1024
            ),
            let object =
                try? JSONSerialization.jsonObject(
                    with: data
                ) as? [String: Any],
            object["version"] as? NSNumber == 1,
            object["generation"] as? String
                == stored.generation,
            object["access_token"] as? String
                == stored.accessToken,
            object["client_id"] as? String
                == Self.clientID,
            object["refresh_token"] == nil
        else {
            return false
        }
        guard let expiry = stored.expiry else {
            return object["expiry_date"] == nil
        }
        let milliseconds =
            (expiry * 1000).rounded(.towardZero)
        guard
            let expected =
                Int64(exactly: milliseconds),
            let actual =
                object["expiry_date"] as? NSNumber
        else {
            return false
        }
        return actual.int64Value == expected
    }

    private func writeSecureFile(
        _ data: Data,
        path: String
    ) -> Bool {
        let destination =
            URL(fileURLWithPath: path)
        let directory =
            destination.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [
                    .posixPermissions: 0o700,
                ]
            )
        } catch {
            return false
        }
        guard validateSecureDirectory(directory.path) else {
            return false
        }

        // A deterministic name lets the next recovery remove a 0600 temp file
        // left by a power loss during write/fsync. The shared mutation lock
        // guarantees that no cooperative writer can own this path concurrently.
        let temporaryPath = "\(path).tmp"
        guard removeSecureFile(path: temporaryPath)
        else {
            return false
        }
        let descriptor = Darwin.open(
            temporaryPath,
            O_WRONLY
                | O_CREAT
                | O_EXCL
                | O_CLOEXEC
                | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            return false
        }
        var shouldRemoveTemporary = true
        defer {
            _ = Darwin.close(descriptor)
            if shouldRemoveTemporary {
                _ = Darwin.unlink(temporaryPath)
            }
        }
        guard
            Darwin.fchmod(
                descriptor,
                S_IRUSR | S_IWUSR
            ) == 0,
            writeAll(data, descriptor: descriptor),
            Darwin.fsync(descriptor) == 0
        else {
            return false
        }
        var metadata = stat()
        guard
            Darwin.fstat(
                descriptor,
                &metadata
            ) == 0,
            validateSecureRegularFile(metadata)
        else {
            return false
        }
        guard
            Darwin.rename(
                temporaryPath,
                path
            ) == 0
        else {
            return false
        }
        shouldRemoveTemporary = false
        guard
            fsyncDirectory(directory.path),
            case let .data(persisted) =
                readSecureFile(
                    path: path,
                    maximumBytes:
                        max(data.count, 1)
                )
        else {
            return false
        }
        return persisted == data
    }

    private func publishSecureFile(
        from sourcePath: String,
        to destinationPath: String
    ) -> Bool {
        guard
            case .data = readSecureFile(
                path: sourcePath,
                maximumBytes: 1024 * 1024
            ),
            URL(fileURLWithPath: sourcePath)
                .deletingLastPathComponent()
                == URL(
                    fileURLWithPath:
                        destinationPath
                ).deletingLastPathComponent(),
            Darwin.rename(
                sourcePath,
                destinationPath
            ) == 0,
            fsyncDirectory(
                URL(
                    fileURLWithPath:
                        destinationPath
                ).deletingLastPathComponent().path
            ),
            case .data = readSecureFile(
                path: destinationPath,
                maximumBytes: 1024 * 1024
            )
        else {
            return false
        }
        return true
    }

    private func removeSecureFile(
        path: String
    ) -> Bool {
        var metadata = stat()
        guard Darwin.lstat(path, &metadata) == 0 else {
            return Darwin.errno == ENOENT
        }
        let kind = metadata.st_mode & S_IFMT
        guard
            metadata.st_uid == Darwin.geteuid(),
            (
                kind == S_IFREG
                    || kind == S_IFLNK
            ),
            kind != S_IFREG
                || metadata.st_nlink == 1,
            Darwin.unlink(path) == 0
        else {
            return false
        }
        return fsyncDirectory(
            URL(fileURLWithPath: path)
                .deletingLastPathComponent().path
        )
    }

    private func readSecureFile(
        path: String,
        maximumBytes: Int
    ) -> SecureFileRead {
        let descriptor = Darwin.open(
            path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            return Darwin.errno == ENOENT
                ? .missing : .invalid
        }
        defer { _ = Darwin.close(descriptor) }
        var metadata = stat()
        guard
            Darwin.fstat(
                descriptor,
                &metadata
            ) == 0,
            validateSecureRegularFile(metadata),
            metadata.st_size >= 0,
            metadata.st_size
                <= off_t(maximumBytes)
        else {
            return .invalid
        }
        var data = Data()
        var buffer =
            [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(
                descriptor,
                &buffer,
                buffer.count
            )
            if count == 0 {
                break
            }
            if count < 0 {
                if Darwin.errno == EINTR {
                    continue
                }
                return .invalid
            }
            guard
                data.count + Int(count)
                    <= maximumBytes
            else {
                return .invalid
            }
            data.append(
                contentsOf:
                    buffer.prefix(Int(count))
            )
        }
        return .data(data)
    }

    private func validateSecureRegularFile(
        _ metadata: stat
    ) -> Bool {
        metadata.st_uid == Darwin.geteuid()
            && metadata.st_nlink == 1
            && metadata.st_mode & S_IFMT == S_IFREG
            && metadata.st_mode
                & (S_IRWXG | S_IRWXO) == 0
    }

    private func validateSecureDirectory(
        _ path: String
    ) -> Bool {
        var metadata = stat()
        guard
            Darwin.lstat(path, &metadata) == 0,
            metadata.st_uid == Darwin.geteuid(),
            metadata.st_mode & S_IFMT == S_IFDIR,
            metadata.st_mode
                & (S_IWGRP | S_IWOTH) == 0
        else {
            return false
        }
        return true
    }

    private func writeAll(
        _ data: Data,
        descriptor: Int32
    ) -> Bool {
        data.withUnsafeBytes { rawBuffer in
            guard
                let baseAddress =
                    rawBuffer.baseAddress
            else {
                return data.isEmpty
            }
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(
                        by: offset
                    ),
                    data.count - offset
                )
                if count < 0 {
                    if Darwin.errno == EINTR {
                        continue
                    }
                    return false
                }
                guard count > 0 else {
                    return false
                }
                offset += count
            }
            return true
        }
    }

    private func fsyncDirectory(
        _ path: String
    ) -> Bool {
        let descriptor = Darwin.open(
            path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            return false
        }
        defer { _ = Darwin.close(descriptor) }
        var metadata = stat()
        guard
            Darwin.fstat(
                descriptor,
                &metadata
            ) == 0,
            metadata.st_uid == Darwin.geteuid(),
            metadata.st_mode & S_IFMT == S_IFDIR,
            metadata.st_mode
                & (S_IWGRP | S_IWOTH) == 0
        else {
            return false
        }
        return Darwin.fsync(descriptor) == 0
    }

    private func copyTokens(
        _ tokens: GeminiStoredTokens,
        to keys: TokenKeys,
        accountID: UUID,
        expectedEpoch: UInt64
    ) -> LoadedTokenBundle? {
        let expiresIn = max(
            0,
            tokens.expiry?
                .timeIntervalSinceNow ?? 0
        )
        return storeTokens(
            access: tokens.accessToken,
            refresh: tokens.refreshToken ?? "",
            expiresIn: expiresIn,
            accountID: accountID,
            origin: .legacyCopy,
            expectedEpoch: expectedEpoch
        )
    }

    private func deleteTokens(keys: TokenKeys) -> Bool {
        let bundleDeleted = secretStore.delete(
            key: keys.bundle,
            accessGroup: Self.accessGroup
        )
        let accessDeleted = secretStore.delete(
            key: keys.access,
            accessGroup: Self.accessGroup
        )
        let refreshDeleted = secretStore.delete(
            key: keys.refresh,
            accessGroup: Self.accessGroup
        )
        let expiryDeleted = secretStore.delete(
            key: keys.expiry,
            accessGroup: Self.accessGroup
        )
        return bundleDeleted
            && accessDeleted
            && refreshDeleted
            && expiryDeleted
            && secretStore.load(
                key: keys.bundle,
                accessGroup: Self.accessGroup
            ) == nil
            && secretStore.load(
                key: keys.access,
                accessGroup: Self.accessGroup
            ) == nil
            && secretStore.load(
                key: keys.refresh,
                accessGroup: Self.accessGroup
            ) == nil
            && secretStore.load(
                key: keys.expiry,
                accessGroup: Self.accessGroup
            ) == nil
    }

    // MARK: - PKCE

    // `internal` (not private) so the PKCE generation is unit-testable against the
    // RFC 7636 vector — these are pure/deterministic apart from the RNG in the
    // verifier, and a regression here silently breaks the Gemini OAuth handshake.
    static func generateCodeVerifier() throws -> String {
        var buf = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, buf.count, &buf)
        guard status == errSecSuccess else {
            throw GeminiOAuthError.randomGenerationFailed
        }
        return Data(buf).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func generateCodeChallenge(from verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - URL encoding

    private static func formEncode(_ params: [String: String]) -> String {
        params.map { k, v in
            let ek = k.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? k
            let ev = v.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? v
            return "\(ek)=\(ev)"
        }.joined(separator: "&")
    }
}

public extension GeminiCredentialDraft {
    @discardableResult
    func commit(
        using manager: GeminiOAuthManager = .shared,
        accountID: UUID
    ) -> Bool {
        switch pendingMutation {
        case .unchanged:
            return true
        case .connect:
            guard let pendingAuthorization else {
                return false
            }
            return manager.commitAuthorization(
                pendingAuthorization,
                accountID: accountID
            )
        case .disconnect:
            return manager.clearTokens(
                accountID: accountID
            )
        }
    }
}

// MARK: - Presentation context

extension GeminiOAuthManager: ASWebAuthenticationPresentationContextProviding {
    @MainActor
    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.windows.first(where: \.isKeyWindow)
            ?? NSApplication.shared.windows.first
            ?? ASPresentationAnchor()
    }
}
#endif
