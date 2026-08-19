import Foundation
#if canImport(Combine)
import Combine
#endif

/// v1.19.1 — runtime privacy preferences. Two-tier toggle:
///
/// - `skipClaudeKeychain` — when true, every cross-app Claude Code
///   keychain read (`ClaudeCredentials.readKeychainCredentials()`) is
///   bypassed at its call sites. User-initiated reads from the
///   Provider Config "Connect Claude Code" button are intentionally
///   NOT guarded — explicit user action overrides this preference.
///
/// - `localOnlyMode` — master toggle. When on, forces
///   `skipClaudeKeychain` to true and reserves room for future
///   external-API enrichment opt-outs. UI disables the per-toggle
///   when master is active.
///
/// Defaults: both OFF (preserves pre-1.19.1 behaviour for users who
/// already accepted the keychain prompt + populated the cache). This
/// is opt-in.
///
/// Motivation: macOS 26.x Keychain Agent rejects valid login passwords
/// in cross-app ACL grants on the user's Mac (see
/// `feedback_keychain_agent_bug_macos26` memory). Users must be able
/// to escape the buggy dialog without losing all telemetry.
public final class PrivacySettings: ObservableObject {
    public static let shared = PrivacySettings()

    private enum Keys {
        static let skipClaudeKeychain = "privacy.skipClaudeKeychain"
        static let localOnlyMode = "privacy.localOnlyMode"
        // v1.34 R1d: managed-session safety toggle (co-located here for the same
        // didSet→defaults plumbing). The `privacy.` namespace is in the
        // UnsandboxedDataMigration allowlist, so it survives the MAS→DEVID move.
        static let blockClaudeOnOutdatedHelper = "privacy.blockClaudeOnOutdatedHelper"
        // v1.45: shared with UserDefaultsAnonymousTelemetryStore, which reads
        // the same keys without importing this type (it must work before any
        // UI exists). AnonymousTelemetryMigrationAllowlistTests pins them
        // together, so a rename here fails there rather than silently
        // detaching the switch from what it switches.
        static let anonymousTelemetryEnabled = UserDefaultsAnonymousTelemetryStore.enabledKey
    }

    @Published public var skipClaudeKeychain: Bool {
        didSet {
            defaults.set(skipClaudeKeychain, forKey: Keys.skipClaudeKeychain)
        }
    }

    @Published public var localOnlyMode: Bool {
        didSet {
            defaults.set(localOnlyMode, forKey: Keys.localOnlyMode)
            if localOnlyMode && !skipClaudeKeychain {
                skipClaudeKeychain = true
            }
        }
    }

    /// v1.34 R1d: when ON, the app HARD-BLOCKS starting a managed Claude session
    /// whenever the helper owning the socket is below the OAuth-injection floor
    /// (which would silently run Claude on the API, not the user's Max/Pro
    /// plan). Default OFF = warn-only: the session is allowed but a prominent
    /// banner tells the user to update the helper.
    @Published public var blockClaudeOnOutdatedHelper: Bool {
        didSet {
            defaults.set(blockClaudeOnOutdatedHelper, forKey: Keys.blockClaudeOnOutdatedHelper)
        }
    }

    /// v1.45 — anonymous install telemetry. Two facts, no account, no PII:
    /// the app ran for the first time, and it later found a CLI and had a
    /// number to show. See `AnonymousInstallTelemetry`.
    ///
    /// Defaults ON, which is only defensible because first launch discloses it
    /// before anything is sent. `localOnlyMode` overrides it regardless — that
    /// check lives in the telemetry store so it also applies to code paths that
    /// never construct this object.
    @Published public var anonymousTelemetryEnabled: Bool {
        didSet {
            defaults.set(anonymousTelemetryEnabled, forKey: Keys.anonymousTelemetryEnabled)
        }
    }

    /// True when `localOnlyMode` is already suppressing telemetry, so the UI can
    /// show the switch as inactive instead of letting someone toggle a control
    /// that does nothing.
    public var telemetrySuppressedByLocalOnly: Bool { localOnlyMode }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedLocalOnly = defaults.bool(forKey: Keys.localOnlyMode)
        let storedSpecific = defaults.bool(forKey: Keys.skipClaudeKeychain)
        self.localOnlyMode = storedLocalOnly
        self.skipClaudeKeychain = storedLocalOnly || storedSpecific
        self.blockClaudeOnOutdatedHelper = defaults.bool(forKey: Keys.blockClaudeOnOutdatedHelper)
        // Absent means on. Reading it through `object(forKey:)` first keeps
        // `bool(forKey:)`'s false-for-missing from reading as an opt-out.
        self.anonymousTelemetryEnabled =
            (defaults.object(forKey: Keys.anonymousTelemetryEnabled) as? Bool) ?? true
    }
}
