#if os(macOS)
import Foundation
import ServiceManagement
import OSLog

/// Phase 4 helper-bundling: register and supervise the embedded
/// `cli_pulse_helper` LaunchAgent so users don't need a Python install
/// or GitHub checkout to use the local fast-path Sessions feature.
///
/// Architecture rationale:
///
///   * The macOS app is sandboxed (`com.apple.security.app-sandbox`).
///     A sandboxed parent cannot spawn an unsandboxed child via
///     `Process` / `posix_spawn`; the child inherits the parent's
///     sandbox by default. The helper needs full user-level
///     filesystem + subprocess access (it reads
///     `~/.claude/settings.json`, walks git repos, spawns Claude
///     PTY children for managed sessions). So child-process
///     embedding is structurally wrong.
///
///   * `SMAppService.agent(plistName:)` (macOS 13+) registers a
///     LaunchAgent shipped inside the app bundle at
///     `Contents/Library/LaunchAgents/<name>.plist`. launchd then
///     starts the agent in the user's login session WITHOUT the
///     sandbox restrictions of the parent app — exactly the right
///     trust boundary for our daemon.
///
///   * Communication happens via the existing app-group container
///     UDS socket (`~/Library/Group Containers/group.yyh.CLI-Pulse/`).
///     The app accesses that path via its sandbox group entitlement;
///     the unsandboxed agent accesses the same path as a regular
///     directory under `$HOME/Library`. Both sides see the same
///     socket file.
///
/// The LaunchAgent plist on disk is rewritten on first registration
/// to substitute three placeholders:
///
/// Phase 4D P1.4 (Codex review fix): the previous design used
/// runtime placeholders below + `installAgentPlist()` to substitute
/// them. That was abandoned because mutating the signed bundle's
/// LaunchAgents plist invalidated the code signature, breaking
/// SMAppService.register on notarised builds.
///
/// The current design ships the plist as-is in the bundle:
///   * BundleProgram is a relative path (`Contents/Helpers/
///     cli_pulse_helper`) — launchd resolves it against the app
///     bundle, no runtime substitution.
///   * The plist deliberately has NO `StandardOutPath` /
///     `StandardErrorPath` keys — launchd does NOT expand `~` in
///     those keys (Phase 4E e2e 2026-05-07 finding) and any tilde
///     would crash the helper with EX_CONFIG. Helper logging goes
///     through `Logger(subsystem: "yyh.CLI-Pulse.helper.agent", ...)`
///     os_log, viewable via `log show --predicate "process ==
///     'cli_pulse_helper'"`. Don't reintroduce path-based logging
///     keys; the embed_helper_in_archive.sh + verify-archive-
///     embedding CI both reject tilde paths now.
///   * Supabase URL + anon key live in the app's Info.plist; the
///     helper reads them via the helper-config file the macOS app
///     writes on first launch (NOT via plist substitution).
public actor HelperLifecycleManager {

    /// Current state of the agent registration. Drives the
    /// Settings → Helper status surface in SwiftUI so the user
    /// can see whether the embedded helper is running, missing,
    /// crashed-restarting, etc.
    public enum Status: Sendable, Equatable {
        /// First-launch state: app hasn't tried to register yet.
        case notRegistered
        /// `SMAppService.agent.register()` succeeded; launchd has
        /// the plist and is starting / supervising the helper.
        case registered
        /// User explicitly disabled the agent via
        /// `unregisterAgent()` (Settings → Helper → Stop).
        case userDisabled
        /// Registration call failed (sandbox, permissions, plist
        /// malformed, …). Detail string carries the localised
        /// reason for surfacing in the Settings panel.
        case registrationFailed(String)
        /// Build does NOT contain the embedded helper at the
        /// expected `Contents/Helpers/cli_pulse_helper` path. This
        /// is the expected state for development builds before the
        /// "Build Helper Binary" Run Script phase has run, OR for
        /// any build where the Copy Files phase was skipped. UI
        /// shows a "embedded helper missing — falling back to
        /// manually-started daemon" hint.
        case bundledBinaryMissing
    }

    private let logger = Logger(subsystem: "yyh.CLI-Pulse", category: "HelperLifecycle")

    /// `Label` field of the LaunchAgent plist; MUST match the
    /// filename in `Contents/Library/LaunchAgents/` (Apple's
    /// resolver pairs them by exact match).
    ///
    /// **Important:** disambiguated from the MAS LoginItem identifier
    /// `yyh.CLI-Pulse.helper` (`CLIPulseHelper.app` bundle ID, claimed
    /// by `HelperLogin` via `SMAppService.loginItem(identifier:)`).
    /// Pre-fix both occupied the same launchd label slot — MAS-strip-
    /// inert (the agent plist is removed from MAS archives) but a P1
    /// for any Developer ID DMG distribution. See
    /// `feedback_loginitem_launchagent_collision.md`.
    public static let agentLabel = "yyh.CLI-Pulse.helper.agent"
    public static let agentPlistName = "yyh.CLI-Pulse.helper.agent.plist"

    /// Bundled LaunchAgent plist basename. The macOS app target's
    /// "Embed Helper LaunchAgent" Copy Files phase ships this file
    /// to `Contents/Library/LaunchAgents/`.
    public static let plistResourceName = "yyh.CLI-Pulse.helper.agent"

    /// v1.43 — UserDefaults key that recorded the app version at which we last
    /// completed a bundled-helper swap. **Retired in v1.46**: it was written
    /// whenever `launchctl kickstart` exited 0, and that exit code says nothing
    /// about whether the job then spawned — on the machine that surfaced this
    /// bug it read `1.46.0/99` while the agent had failed to exec 22,138 times.
    /// A sentinel that latches "done" off a signal that cannot fail is worse
    /// than no sentinel: it disables the one retry path. Registration health is
    /// now measured directly on every launch (`reconcileBundledAgent`), so
    /// nothing needs remembering. Kept only so the key can be cleaned up.
    public static let retiredHelperSwapAppVersionKey = "cli_pulse_last_helper_swap_app_version"

    private var lastKnownStatus: Status = .notRegistered

    public init() {}

    // MARK: - Public entry points

    /// Idempotent: ensure the embedded helper is registered with
    /// launchd. Safe to call on every app launch — re-registering
    /// the same plist with the same label is a no-op for
    /// SMAppService.
    ///
    /// Phase 4D P1.4 (Codex): does NOT mutate the signed app
    /// bundle anymore. The plist already lives at
    /// `Contents/Library/LaunchAgents/yyh.CLI-Pulse.helper.agent.plist`
    /// in shippable form (BundleProgram only — no log paths;
    /// see yyh.CLI-Pulse.helper.agent.plist comments for why). SMAppService.
    /// register reads it directly without any runtime substitution.
    @discardableResult
    public func ensureRegistered() async -> Status {
        guard Self.locateBundledHelperBinary() != nil else {
            logger.error("embedded helper binary missing at Contents/Helpers/cli_pulse_helper")
            lastKnownStatus = .bundledBinaryMissing
            return lastKnownStatus
        }
        guard Self.bundledAgentPlistExists() else {
            logger.error("embedded LaunchAgent plist missing at Contents/Library/LaunchAgents/\(Self.agentPlistName, privacy: .public)")
            lastKnownStatus = .registrationFailed(
                "Bundled LaunchAgent plist missing — Xcode build phase did not place it under Contents/Library/LaunchAgents/."
            )
            return lastKnownStatus
        }
        // SMAppService.agent registers the .plist by NAME (not path);
        // the framework looks under the calling app's
        // Contents/Library/LaunchAgents/. The plist there MUST be
        // signed in (no runtime mutation since Phase 4D P1.4).
        let service = SMAppService.agent(plistName: Self.agentPlistName)
        do {
            try service.register()
            logger.info("registered LaunchAgent \(Self.agentLabel, privacy: .public)")
            lastKnownStatus = .registered
        } catch let error as NSError {
            // SMAppService.Error.unsupportedFile (1010) on dev
            // builds without proper signing — surface as a clear
            // diagnostic. Other codes (already-registered,
            // permission-denied) propagate verbatim.
            let detail = "SMAppService.register failed: \(error.domain)/\(error.code) \(error.localizedDescription)"
            logger.error("\(detail)")
            lastKnownStatus = .registrationFailed(detail)
        }
        return lastKnownStatus
    }

    /// Tear down the agent. Used by the Settings → "Stop helper"
    /// button when the user wants to opt out of local Sessions.
    /// Returns the new status (`.userDisabled` on success).
    @discardableResult
    public func unregisterAgent() async -> Status {
        let service = SMAppService.agent(plistName: Self.agentPlistName)
        do {
            try await service.unregister()
            logger.info("unregistered LaunchAgent \(Self.agentLabel, privacy: .public)")
            lastKnownStatus = .userDisabled
        } catch let error as NSError {
            let detail = "SMAppService.unregister failed: \(error.domain)/\(error.code) \(error.localizedDescription)"
            logger.error("\(detail)")
            lastKnownStatus = .registrationFailed(detail)
        }
        return lastKnownStatus
    }

    public func currentStatus() -> Status { lastKnownStatus }

    // MARK: - Registration reconciliation (v1.46, replaces the v1.43 kickstart)

    /// What `reconcileBundledAgent` did.
    public enum ReconcileOutcome: Sendable, Equatable {
        /// Nothing to reconcile on this build (no bundled agent / not DEVID),
        /// or launchd could not be asked. Detail says which.
        case skipped(String)
        /// launchd says the agent is running and bound to this build.
        case healthy
        /// Registration was rebuilt, and the agent is running afterwards.
        case repaired(was: HelperAgentHealth.Verdict)
        /// Registration was rebuilt and the agent is *still* not running.
        /// The helper is genuinely broken — this is the state worth surfacing.
        case repairFailed(was: HelperAgentHealth.Verdict, now: HelperAgentHealth.Verdict)
    }

    /// Pure: given the verdict before repair and the verdict after (nil if we
    /// could not re-measure), what happened? Split out so the decision is
    /// testable without launchd.
    static func reconcileOutcome(
        before: HelperAgentHealth.Verdict,
        after: HelperAgentHealth.Verdict?
    ) -> ReconcileOutcome {
        guard before.needsRepair else { return .healthy }
        guard let after else {
            return .repairFailed(was: before, now: .indeterminate("re-check unavailable"))
        }
        // A repaired job may legitimately not be `running` the instant we look
        // (KeepAlive throttle, mid-exec). Only a verdict that still calls for
        // repair counts as a failed repair.
        return after.needsRepair
            ? .repairFailed(was: before, now: after)
            : .repaired(was: before)
    }

    /// Measure whether the registered LaunchAgent is actually running, and
    /// rebuild the registration if it is not.
    ///
    /// This replaces v1.43's `kickstartBundledHelperIfAppUpdated`. That one
    /// fired once per app version, restarted the job with
    /// `launchctl kickstart -k`, and recorded success when `launchctl` exited
    /// 0. All three parts were wrong for the failure it needed to catch:
    ///
    ///   * `launchctl kickstart` exits 0 for a job that fails to exec
    ///     milliseconds later — measured against a job that had failed 22,138
    ///     times. So "success" was recorded for a helper that never ran.
    ///   * The sentinel then latched, so the one retry path was disabled
    ///     permanently.
    ///   * `kickstart` restarts a job but never rebinds it. A registration
    ///     bound to a bundle path that no longer exists (see
    ///     `HelperAgentHealth` for how a user gets there — running the app once
    ///     from the mounted DMG is enough) fails identically after a kickstart.
    ///
    /// Now: ask launchd on every launch, and when the answer is bad do the one
    /// thing that actually fixes it — `unregister()` + `register()`, which
    /// rebinds the parent bundle, picks up the current plist's
    /// `ProgramArguments`, and restarts the helper from the new binary. That
    /// subsumes the version-change swap: an in-place update leaves the record
    /// pinned to the old build, which reads as `.staleRegistration` and repairs
    /// on the next launch. No sentinel, so nothing can latch it off.
    ///
    /// Self-limiting: a successful repair sets `parent bundle version` to the
    /// running build, so the next launch reads `.running` and does nothing.
    ///
    /// Effectively DEVID-only, but gated at **runtime** rather than with
    /// `#if DEVID_BUILD`: MAS strips the bundled agent plist from the archive,
    /// so the `bundledAgentPlistExists()` guard below returns `.skipped` before
    /// anything execs, and a sandboxed build that somehow got past it just gets
    /// `.skipped("launchctl unavailable")` from the failed spawn.
    ///
    /// The compile-time gate is deliberately *not* used here: `swift test` does
    /// not define `DEVID_BUILD`, so a `#if DEVID_BUILD` body is never type-
    /// checked by the test suite and can rot green (see
    /// `feedback_guards_that_never_run.md`). The call site in `AppState` stays
    /// DEVID-gated, so behaviour is unchanged.
    @discardableResult
    public func reconcileBundledAgent(
        currentBundleVersion: String?,
        settleDelay: Duration = .seconds(3)
    ) async -> ReconcileOutcome {
        guard Self.locateBundledHelperBinary() != nil, Self.bundledAgentPlistExists() else {
            return .skipped("no bundled agent in this build")
        }
        guard let health = await Self.inspectOffActor() else {
            return .skipped("launchctl unavailable")
        }
        let before = HelperAgentHealth.verdict(for: health, currentBundleVersion: currentBundleVersion)
        guard before.needsRepair else {
            logger.info("helper agent healthy (\(before.description, privacy: .public), runs=\(health.runs ?? -1, privacy: .public))")
            lastKnownStatus = .registered
            return .healthy
        }

        logger.error(
            "helper agent NOT running: \(before.description, privacy: .public) — launchd record says state=\(health.state ?? "?", privacy: .public) runs=\(health.runs ?? -1, privacy: .public) lastExit=\(health.lastExitCodeText ?? health.lastExitReason ?? "none", privacy: .public); rebuilding registration"
        )

        let service = SMAppService.agent(plistName: Self.agentPlistName)
        // Ignore an unregister failure: a job launchd has never heard of
        // (`.notRegistered`) throws here and the register below is the fix.
        do { try await service.unregister() } catch let error as NSError {
            logger.info("unregister during repair returned \(error.domain, privacy: .public)/\(error.code, privacy: .public) — continuing to register")
        }
        do {
            try service.register()
        } catch let error as NSError {
            let detail = "re-register failed: \(error.domain)/\(error.code) \(error.localizedDescription)"
            logger.error("\(detail, privacy: .public)")
            lastKnownStatus = .registrationFailed(detail)
            return .repairFailed(was: before, now: .indeterminate(detail))
        }

        // Give launchd a moment to exec before re-measuring, otherwise we read
        // the `xpcproxy` transition and report a working repair as failed.
        try? await Task.sleep(for: settleDelay)
        let after = await Self.inspectOffActor().map {
            HelperAgentHealth.verdict(for: $0, currentBundleVersion: currentBundleVersion)
        }
        let outcome = Self.reconcileOutcome(before: before, after: after)
        switch outcome {
        case .repaired:
            logger.info("helper agent registration rebuilt; agent is running")
            lastKnownStatus = .registered
        case .repairFailed(_, let now):
            logger.error("helper agent still not running after re-registration: \(now.description, privacy: .public)")
            lastKnownStatus = .registrationFailed("LaunchAgent will not start: \(now.description)")
        case .healthy, .skipped:
            break
        }
        return outcome
    }

    /// `HelperAgentInspector.inspect` blocks its thread on `waitUntilExit()`.
    /// Running it inline would hold this actor — and a cooperative-pool thread —
    /// for the duration of a `launchctl` spawn, so it goes on a detached task.
    private static func inspectOffActor() async -> HelperAgentHealth? {
        await Task.detached(priority: .utility) {
            HelperAgentInspector.inspect(label: Self.agentLabel)
        }.value
    }

    // MARK: - Internals

    /// Resolve the embedded helper binary path inside this build's
    /// .app bundle. Returns `nil` when the binary is missing — the
    /// caller surfaces `.bundledBinaryMissing` rather than failing
    /// the registration outright (development builds may not have
    /// run the build phase yet).
    public static func locateBundledHelperBinary() -> URL? {
        // App bundle layout (macOS .app):
        //   CLI Pulse Bar.app/             ← Bundle.main.bundleURL
        //     Contents/
        //       MacOS/CLI Pulse Bar         ← Bundle.main.executableURL
        //       Helpers/cli_pulse_helper    ← what we want
        //       Library/LaunchAgents/yyh.CLI-Pulse.helper.agent.plist
        guard let contents = appContentsDir() else { return nil }
        let helper = contents
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("cli_pulse_helper")
        return FileManager.default.isExecutableFile(atPath: helper.path) ? helper : nil
    }

    /// Path SMAppService expects the agent plist to live at: the
    /// Contents/Library/LaunchAgents/ subdirectory of the calling
    /// app's bundle.
    ///
    /// Phase 4D P1.4 (Codex): post-distribution write into a
    /// signed app bundle invalidates the signature, so the plist
    /// is shipped in-bundle as-is — no runtime mutation. This
    /// path is only used to verify the plist is actually present
    /// before calling SMAppService.register.
    public static func agentPlistPath() -> URL? {
        return appContentsDir()?
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent(agentPlistName)
    }

    /// Verify the bundled LaunchAgent plist is in place. Used by
    /// `ensureRegistered` to surface a clear `.registrationFailed`
    /// status when the Xcode "Copy Files" build phase didn't run
    /// (dev builds where the project file's Copy Files entry was
    /// removed by accident, etc.).
    public static func bundledAgentPlistExists() -> Bool {
        guard let path = agentPlistPath() else { return false }
        return FileManager.default.fileExists(atPath: path.path)
    }

    /// Resolve `<.app>/Contents/` for the running bundle. Uses
    /// `Bundle.main.bundleURL` rather than walking from
    /// `executableURL`, because xctest runtimes have an executable
    /// path two levels up from a non-.app directory and walking up
    /// from there produces nonsense paths under
    /// `/Applications/Xcode.app/Contents/Developer/usr/...`.
    /// Returns nil for non-.app bundles (xctest, command-line tools)
    /// — the caller surfaces `.bundledBinaryMissing` for those.
    private static func appContentsDir() -> URL? {
        let bundleURL = Bundle.main.bundleURL
        // .app bundles end with `.app`; if not, we're inside a
        // test runner / cli tool and the `Contents/` shim doesn't
        // exist.
        guard bundleURL.pathExtension == "app" else { return nil }
        return bundleURL.appendingPathComponent("Contents", isDirectory: true)
    }

    /// Phase 4D P1.4 (Codex review fix): the previous
    /// `installAgentPlist` + `substitutePlistTemplate` pair has
    /// been removed. Runtime substitution wrote into the signed
    /// app bundle's `Contents/Library/LaunchAgents/`, which
    /// invalidates the code signature and makes
    /// SMAppService.register fail on properly notarised builds.
    ///
    /// The replacement strategy:
    ///   * `BundleProgram` in the plist refs the helper binary
    ///     by RELATIVE path (`Contents/Helpers/cli_pulse_helper`),
    ///     resolved by launchd against the registering app's
    ///     bundle. No build- or runtime-known absolute path is
    ///     needed.
    ///   * Logs use `~/Library/Logs/...` so launchd expands
    ///     `~` against the user's home at agent-start time.
    ///   * Supabase URL + anon key are NOT in the LaunchAgent
    ///     plist anymore. The Swift helper reads them from the
    ///     app's `Info.plist` via the helper-config file at
    ///     startup (or, for the local-only fast path, doesn't
    ///     need them at all).
    ///
    /// Result: the plist that ships inside the .app is the
    /// final form SMAppService consumes. No mutation, no
    /// signature invalidation, no per-install path-rewriting.
}

/// Setup-time errors that prevent registration from being attempted.
/// Surface each as a `.registrationFailed(detail)` status with a
/// human-readable message so the Settings panel can render
/// something actionable.
public enum HelperLifecycleError: Error, LocalizedError {
    case bundleLayoutBroken

    public var errorDescription: String? {
        switch self {
        case .bundleLayoutBroken:
            return "Cannot resolve Contents/Library/LaunchAgents path from the running executable. Bundle layout is unexpected — running from a non-standard location."
        }
    }
}
#endif
