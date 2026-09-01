import Foundation
import Security

/// Async wrapper over a non-interactive native Security.framework query for
/// reading credentials from the macOS Keychain. Used by Slice 2c's
/// `ClaudeQuotaFetcher` to load `Claude Code-credentials` (the JSON
/// blob the Claude CLI persists with the OAuth access/refresh tokens
/// + plan info).
///
/// The helper has no foreground authorization surface. It must therefore fail
/// closed when an item needs user interaction; launching `/usr/bin/security`
/// is deliberately avoided because that child process owns a separate
/// interaction policy and can display a password sheet despite the parent
/// helper disabling Keychain UI.
///
/// A short denial cache remains as backoff for inaccessible items. Explicit
/// refresh can clear that cache, but it still performs a non-interactive read;
/// only the main app's foreground Connect/Test Connection actions may prompt.
///
public actor KeychainReader {

    public static let watchdogTimeoutSeconds: TimeInterval = 5.0
    public static let denialCacheTTLSeconds: TimeInterval = 24 * 60 * 60

    public typealias Clock = @Sendable () -> TimeInterval

    /// Async hook for the native read (or a test fake). It returns the granular
    /// `RunResult` so the
    /// reader can distinguish "service not found" (exit 44 —
    /// `errSecItemNotFound`, the user simply hasn't paired with this
    /// service yet) from "user denied" (the prompt → Deny path) and
    /// from "watchdog tripped" (5 s timeout, prompt unanswered).
    /// (Phase 4E Slice 2b Gemini P0 — without this distinction,
    /// every user without Claude CLI installed got a 24 h denial
    /// cache for a perfectly normal absent-service case.)
    public typealias FetchHook = @Sendable (String) async -> SubprocessRunner.RunResult

    /// `errSecItemNotFound` from Security.framework — what `security`
    /// returns when the item simply doesn't exist. Distinct from
    /// `errSecAuthFailed` (user denied; exit code 51) and from a
    /// watchdog timeout.
    public static let errSecItemNotFound: Int32 = 44

    private let clock: Clock
    private let fetch: FetchHook

    /// service-name → epoch seconds when denial expires.
    private var deniedUntil: [String: TimeInterval] = [:]

    public init(
        clock: @escaping Clock = { Date().timeIntervalSince1970 },
        fetch: FetchHook? = nil
    ) {
        self.clock = clock
        self.fetch = fetch ?? { service in
            Self.fetchGenericPasswordWithoutInteraction(service: service)
        }
    }

    /// Exposed to tests so the production fail-closed policy is pinned without
    /// touching a real user's Keychain.
    static func noInteractionQuery(service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
    }

    private static func fetchGenericPasswordWithoutInteraction(
        service: String
    ) -> SubprocessRunner.RunResult {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(
            noInteractionQuery(service: service) as CFDictionary,
            &item
        )
        guard status == errSecSuccess else {
            // Preserve the legacy hook's two semantic exit codes so existing
            // tests and denial-cache behavior remain stable.
            let code: Int32 = status == Security.errSecItemNotFound
                ? Self.errSecItemNotFound
                : 51
            return .nonZeroExit(code: code, stdout: "")
        }
        guard let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else {
            return .nonZeroExit(code: Self.errSecItemNotFound, stdout: "")
        }
        return .success(stdout: value)
    }

    /// Result of a Keychain read.
    public enum Result: Sendable, Equatable {
        /// Successful read — `value` is whatever `security ... -w` printed
        /// to stdout, trimmed of trailing newline. Caller is responsible
        /// for parsing it (often as JSON).
        case success(value: String)
        /// The non-interactive read was denied, an injected legacy test hook
        /// timed out, or the service simply doesn't exist. The reader caches
        /// denial/timeout state for 24 h to avoid repeating inaccessible reads
        /// every collection cycle.
        case unavailable(reason: Reason)
    }

    public enum Reason: String, Sendable, Equatable {
        case watchdogTimeout = "watchdog_timeout"
        case userDenied = "user_denied"
        case serviceNotFound = "service_not_found"
        case denialCached = "denial_cached"
    }

    /// Read the named generic password. `forceRetry: true` clears the
    /// denial cache for this service before attempting the read,
    /// giving the user a path to flip a previous denial.
    public func find(generic service: String, forceRetry: Bool = false) async -> Result {
        if forceRetry {
            deniedUntil.removeValue(forKey: service)
        }
        if let until = deniedUntil[service], clock() < until {
            return .unavailable(reason: .denialCached)
        }

        let runResult = await fetch(service)
        switch runResult {
        case .success(let stdout):
            let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return .unavailable(reason: .serviceNotFound)
            }
            return .success(value: trimmed)

        case .nonZeroExit(let code, _):
            // `errSecItemNotFound` — the user simply hasn't paired
            // with this service yet. NOT a denial; do NOT cache, so
            // a future Claude CLI install is picked up immediately.
            if code == Self.errSecItemNotFound {
                return .unavailable(reason: .serviceNotFound)
            }
            // Any other non-zero exit (most commonly `errSecAuthFailed`
            // / `errSecMissingEntitlement` — user clicked Deny on the
            // prompt or the helper isn't entitled). Cache for 24 h.
            deniedUntil[service] = clock() + Self.denialCacheTTLSeconds
            return .unavailable(reason: .userDenied)

        case .timedOut:
            // Retained for injected/legacy fetch hooks. The production native
            // query cannot wait on UI because authentication UI is disabled.
            deniedUntil[service] = clock() + Self.denialCacheTTLSeconds
            return .unavailable(reason: .watchdogTimeout)

        case .spawnError, .cancelled:
            // Retained for injected/legacy fetch hooks. Don't cache transient
            // failures as user intent.
            return .unavailable(reason: .userDenied)
        }
    }

    /// Test-only: drop all denial state.
    public func resetDenialCacheForTesting() {
        deniedUntil.removeAll()
    }
}
