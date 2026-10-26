#if os(macOS)
import Foundation
import os
import Security

// 1.59 (59-15 F2): why Claude is not ready, instead of `not_ready_unknown`.
//
// Before this, `ClaudeCollector.readiness` returned `.unknown` for every
// empty token: `resolveTokenDetails` returned `source: .none` from four
// different branches, and the keychain read dropped its `OSStatus`. In the
// field (`devices.collector_status`) Claude read `not_ready_unknown` on every
// device that reported it, including devices where Codex was `ok`, so
// nobody could tell "no Claude login here" from "the user said no to the
// keychain dialog" from "Strict privacy mode". The resolver now says which
// branch it ended in (`ClaudeTokenAbsence`), the keychain read says what it
// got back (`ClaudeKeychainMiss`), and `ClaudeNotReadyDiagnosis` maps the
// two to a reason.

/// Why the cross-app keychain read is on cooldown
/// (`ClaudeCredentials.installKeychainReadCooldown`). Stored as its raw value
/// in the app group, next to the cooldown's end, so both processes agree.
enum ClaudeKeychainCooldownCause: String, Sendable, Equatable {
    /// OAuth answered 401/403 for the token read from the item: Claude Code
    /// has to refresh it. The only cause before 1.59.
    case rejectedToken = "rejected_token"
    /// The user said no in macOS's dialog (59-15 F6).
    case declined
}

/// What a background read of Claude Code's keychain item ended with, when it
/// gave no token.
enum ClaudeKeychainMiss: Sendable, Equatable {
    /// Not read: a Settings › Privacy switch said skip (or, in the LoginItem
    /// helper, the app had not written its copy of them yet).
    case skipped(ClaudeKeychainAccess)
    /// Not read: the cooldown is on, for this cause.
    case onCooldown(ClaudeKeychainCooldownCause)
    /// Read, and `SecItemCopyMatching` answered this (never `errSecSuccess`).
    case status(OSStatus)
    /// Read, and the item held no token we can parse.
    case unreadable

    /// Deny, or Cancel, in macOS's "CLI Pulse wants to use …" dialog.
    /// `errSecAuthFailed` (-25293) is what Deny and a refused password give;
    /// `errSecUserCanceled` (-128) is Cancel.
    static func isDeclined(_ status: OSStatus) -> Bool {
        status == errSecAuthFailed || status == errSecUserCanceled
    }
}

/// The token resolver's keychain step (`ClaudeCredentials.readKeychainForTokenResolver`).
enum ClaudeKeychainLookup: Sendable {
    case found(ClaudeCredentials.Creds)
    case missing(ClaudeKeychainMiss)
}

/// What `ClaudeCredentials.resolveTokenDetails` ended with when it found no
/// token, in the order it checks.
enum ClaudeTokenAbsence: Sendable, Equatable {
    /// This entry was disconnected (`sharedCredentialFallbackDisabled`) and
    /// has no token of its own.
    case fallbackDisabled
    /// The machine's login is not this entry's to use: another entry holds
    /// it, or the owner record cannot be read.
    case sharedLoginNotClaimed
    /// No environment token and no credentials file; the keychain gave none.
    case keychain(ClaudeKeychainMiss)
}

/// The keychain read's answer, noted by `ClaudeCredentials.readKeychainCredentials`
/// in the log bound to the current task. A task-local, like
/// `StrictPrivacySkipLog`, so the read keeps its signature: the
/// Settings › Privacy guard and its source checks
/// (`ClaudeKeychainGateReferenceTests`) stay exactly as they are.
final class ClaudeKeychainReadLog: @unchecked Sendable {
    @TaskLocal static var current: ClaudeKeychainReadLog?

    private let lock = NSLock()
    private var noted: ClaudeKeychainMiss?

    /// Notes `miss` in the bound log. Outside one, nothing.
    static func note(_ miss: ClaudeKeychainMiss) {
        current?.record(miss)
    }

    /// The last read's answer, if a read was made.
    var miss: ClaudeKeychainMiss? { lock.withLock { noted } }

    private func record(_ miss: ClaudeKeychainMiss) {
        lock.withLock { noted = miss }
    }
}

/// Why the token resolver found no token, noted by `resolveTokenDetails` in
/// the log bound to the current task.
///
/// `ClaudeCollector.readiness` binds one around its own `isAvailable`, so
/// the reason comes from the read that decided "not ready". Resolving again
/// to ask why would read the keychain a second time, and an item that shows
/// macOS's dialog would show it twice.
final class ClaudeTokenResolutionLog: @unchecked Sendable {
    @TaskLocal static var current: ClaudeTokenResolutionLog?

    private let lock = NSLock()
    private var noted: ClaudeTokenAbsence?

    /// Notes `absence` in the bound log. Outside one, nothing.
    static func note(_ absence: ClaudeTokenAbsence) {
        current?.record(absence)
    }

    /// The first absence noted: the OAuth strategy's, which `isAvailable`
    /// asks first.
    var absence: ClaudeTokenAbsence? { lock.withLock { noted } }

    private func record(_ absence: ClaudeTokenAbsence) {
        lock.withLock { if noted == nil { noted = absence } }
    }
}

/// Maps what the resolver found to the reason a Claude row and the fleet see.
enum ClaudeNotReadyDiagnosis {
    private static let logger = Logger(subsystem: "com.clipulse", category: "ClaudeCredentials")

    /// - Parameters:
    ///   - absence: what the resolver noted, or nil when it noted nothing
    ///     (it was not asked).
    ///   - isSandboxed: the App Store build cannot see `~/.claude` without a
    ///     grant, so it never says "Not installed" (the rule
    ///     `CollectorReadinessProbe.fromConfigDirectory` documents).
    ///   - claudeConfigDirectoryExists: whether `~/.claude` is there. Asked
    ///     only outside the sandbox, where the answer is real.
    ///
    /// Two pieces of evidence from the plan are not asked for here. A
    /// `claude` binary: reaching a keychain miss means the CLI strategy
    /// already looked for one and found none, or Claude would be ready. Scan
    /// rows: the scan reads `~/.claude/projects`, so rows imply the folder.
    static func reason(
        for absence: ClaudeTokenAbsence?,
        isSandboxed: Bool = MASSandboxGate.isSandboxed,
        claudeConfigDirectoryExists: () -> Bool = {
            FileManager.default.fileExists(
                atPath: (ClaudeCredentials.realHomeDir as NSString).appendingPathComponent(".claude"))
        }
    ) -> CollectorNotReadyReason {
        guard let absence else { return .unknown }
        switch absence {
        case .fallbackDisabled:
            return .notConnected
        case .sharedLoginNotClaimed:
            // Another entry holding it is `sharedCredentialTaken`, which
            // `readiness` asks before this. What is left is an owner record
            // that cannot be read: nothing the user can act on by name.
            return .unknown
        case .keychain(let miss):
            return reason(for: miss, isSandboxed: isSandboxed,
                          claudeConfigDirectoryExists: claudeConfigDirectoryExists)
        }
    }

    private static func reason(
        for miss: ClaudeKeychainMiss,
        isSandboxed: Bool,
        claudeConfigDirectoryExists: () -> Bool
    ) -> CollectorNotReadyReason {
        switch miss {
        case .skipped(.skippedStrictPrivacyMode):
            return .strictPrivacyModeKeychain
        case .skipped(.skippedBySetting):
            // "Skip Claude Code keychain access" alone. Not
            // `strictPrivacyModeKeychain`: its hint says to turn off Strict
            // privacy mode, which is off. Connecting works whatever the
            // switch says, because the Connect button's read is the user's own.
            return .notConnected
        case .skipped(.skippedAwaitingApp), .skipped(.read):
            // The LoginItem helper before the app has written its copy of the
            // switches: a moment, not a state to name.
            return .unknown
        case .onCooldown(.declined):
            return .keychainDenied
        case .onCooldown(.rejectedToken):
            // Claude Code refreshes the token when it next runs; signing in
            // there (or just running `claude`) is the fix.
            return .missingCredentials
        case .status(let status) where ClaudeKeychainMiss.isDeclined(status):
            return .keychainDenied
        case .status(errSecItemNotFound):
            // No Claude.ai login on this Mac. The keychain's answer does not
            // depend on the sandbox, so "not signed in" holds there too; only
            // a Mac that can see `~/.claude` is gone may say "not installed".
            if isSandboxed || claudeConfigDirectoryExists() {
                return .missingCredentials
            }
            return .notInstalled
        case .status(let status):
            // -25308 (`errSecInteractionNotAllowed`, no dialog possible: a
            // locked screen, a process with no UI) and anything else.
            logger.notice("Claude not ready: keychain read status \(status, privacy: .public)")
            return .unknown
        case .unreadable:
            logger.notice("Claude not ready: keychain item holds no token this build can read")
            return .unknown
        }
    }
}
#endif
