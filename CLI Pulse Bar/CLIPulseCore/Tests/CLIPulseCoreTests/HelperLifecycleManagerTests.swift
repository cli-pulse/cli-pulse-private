import XCTest
@testable import CLIPulseCore

#if os(macOS)

/// Tests for `HelperLifecycleManager`, the Phase 4 helper-bundling
/// surface that registers the embedded `cli_pulse_helper` LaunchAgent
/// via `SMAppService.agent(plistName:)`.
///
/// We do NOT spin up SMAppService against launchd here (that's an
/// integration concern that needs a real signed app bundle). These
/// tests cover:
///
///   * Agent label / plist filename pinning — the LaunchAgent plist
///     filename and `Label` field MUST match for SMAppService to
///     resolve them. A typo in either drift breaks registration.
///   * Pure plist-template substitution — placeholder syntax + every
///     of the four expected tokens get replaced verbatim.
///   * Bundle-layout helpers return the right paths under a fake
///     bundle structure (helps catch refactor breakage).
final class HelperLifecycleManagerTests: XCTestCase {

    // MARK: - Naming contract

    func testAgentLabelMatchesPlistFilename() {
        // SMAppService.agent(plistName:) resolves the on-disk plist
        // by name. The plist's <Label> field MUST equal the filename
        // minus `.plist`. Any drift between the two strings breaks
        // registration silently (launchd accepts the plist but the
        // app's `service.status` check refers to a different label
        // and reports "not registered").
        XCTAssertEqual(
            HelperLifecycleManager.agentPlistName,
            "\(HelperLifecycleManager.agentLabel).plist",
            "agent plist filename and Label MUST stay in sync; SMAppService pairs them by exact match"
        )
    }

    func testAgentPlistResourceNameIsBaseFileName() {
        // Keep the resource basename aligned with the final
        // LaunchAgent plist filename copied into
        // Contents/Library/LaunchAgents.
        XCTAssertEqual(
            HelperLifecycleManager.plistResourceName,
            "yyh.CLI-Pulse.helper.agent",
            "LaunchAgent resource basename must match the bundled plist filename without .plist"
        )
    }

    // MARK: - B3 collision-disambiguation invariants

    func testAgentLabelDisambiguatedFromLoginItemIdentifier() {
        // The MAS LoginItem (CLIPulseHelper.app) bundle ID is
        // `yyh.CLI-Pulse.helper` (see CLIPulseBarApp.swift HelperLogin).
        // `SMAppService.loginItem(identifier:)` claims that string as
        // a launchd label slot. The LaunchAgent MUST use a different
        // label — pre-fix they collided, causing undefined launchd
        // behavior when both registrations ran on Developer ID
        // distribution (MAS-strip made it inert). See
        // `feedback_loginitem_launchagent_collision.md`.
        XCTAssertNotEqual(
            HelperLifecycleManager.agentLabel,
            "yyh.CLI-Pulse.helper",
            "agent label must NOT match LoginItem identifier — they share launchd's label namespace"
        )
        XCTAssertEqual(
            HelperLifecycleManager.agentLabel,
            "yyh.CLI-Pulse.helper.agent",
            "agent label fixed to the disambiguated value documented in feedback_loginitem_launchagent_collision.md"
        )
    }

    // MARK: - Bundle layout helpers
    //
    // Phase 4D P1.4 dropped the runtime plist-substitution path
    // because writing into a signed app bundle invalidates the
    // signature. The plist is shipped in its final form. The
    // substitutePlistTemplate tests it backed have been removed
    // along with the function; what remains is verifying that the
    // bundle-layout helpers find the plist and binary at the
    // expected paths.

    func testLocateBundledHelperBinary_returnsNilForTestBundle() {
        // The XCTest runner bundle has no Contents/Helpers/
        // cli_pulse_helper. Pin that the lookup returns nil rather
        // than misresolving to some other path the test runner has
        // executable bits on. Production builds populate that path
        // via the Phase 4 Run Script + Copy Files build phases.
        XCTAssertNil(
            HelperLifecycleManager.locateBundledHelperBinary(),
            "test bundle should not have an embedded helper; if this fails, the test runner's bundle layout changed"
        )
    }

    func testAgentPlistPath_returnsNilForXCTestRuntime() {
        // The xctest runner is not a .app bundle; `Bundle.main.
        // bundleURL` lands on the test bundle / xctest CLI which
        // has no `.app` extension. Pin that the lookup returns
        // nil rather than producing a nonsense path under
        // `/Applications/Xcode.app/Contents/Developer/usr/...`
        // (the pre-fix behaviour walked up from executableURL and
        // resolved a useless URL there). Production .app bundles
        // hit a different code path which is integration-tested
        // against a signed build.
        XCTAssertNil(
            HelperLifecycleManager.agentPlistPath(),
            "non-.app bundle should return nil; if this fails, the test runtime is now somehow inside a real .app and the bundle-detection heuristic needs updating"
        )
    }

    // MARK: - Reconciliation outcome (v1.46, replaces the v1.43 kickstart)
    //
    // The v1.43 `shouldKickstartHelperForAppUpdate` tests are gone with the
    // function. They pinned a decision made from a persisted sentinel, and the
    // sentinel was the bug: it was written whenever `launchctl kickstart`
    // exited 0, which it does even when the job it kickstarted fails to exec.
    // On the machine that surfaced this, the sentinel read `1.46.0/99` — a
    // recorded successful swap — while the agent had failed 22,138 times. The
    // replacement decides from launchd's live job record instead, so what needs
    // pinning is how a before/after pair of verdicts maps to an outcome.

    func testReconcileOutcome_healthyWhenNothingNeededRepair() {
        // A running, current-build agent must not be torn down and rebuilt.
        XCTAssertEqual(
            HelperLifecycleManager.reconcileOutcome(before: .running, after: nil),
            .healthy,
            "a healthy agent must be left alone — re-registering restarts the helper for no reason"
        )
    }

    func testReconcileOutcome_indeterminateIsNotRepaired() {
        // We do not tear down a registration on a signal we could not read.
        XCTAssertEqual(
            HelperLifecycleManager.reconcileOutcome(before: .indeterminate("xpcproxy"), after: nil),
            .healthy
        )
    }

    func testReconcileOutcome_repairedWhenAgentRunsAfterwards() {
        let before = HelperAgentHealth.Verdict.spawnFailing("78: EX_CONFIG")
        XCTAssertEqual(
            HelperLifecycleManager.reconcileOutcome(before: before, after: .running),
            .repaired(was: before)
        )
    }

    func testReconcileOutcome_staleRegistrationCountsAsRepairedOnceRebound() {
        // The in-place-update case: record pinned to the old build, agent fine.
        // After re-registration the version matches, so the verdict is
        // `.running` and this reports repaired — this is what replaces the
        // v1.43 version-change kickstart.
        let before = HelperAgentHealth.Verdict.staleRegistration(recorded: "96", current: "99")
        XCTAssertEqual(
            HelperLifecycleManager.reconcileOutcome(before: before, after: .running),
            .repaired(was: before)
        )
    }

    func testReconcileOutcome_repairFailedWhenStillBrokenAfterwards() {
        // The state the old code could not represent at all: we tried, and the
        // helper still will not start. Must NOT report success.
        let before = HelperAgentHealth.Verdict.spawnFailing("78: EX_CONFIG")
        let after = HelperAgentHealth.Verdict.spawnFailing("78: EX_CONFIG")
        XCTAssertEqual(
            HelperLifecycleManager.reconcileOutcome(before: before, after: after),
            .repairFailed(was: before, now: after)
        )
    }

    func testReconcileOutcome_repairFailedWhenRecheckUnavailable() {
        // Unverifiable is not success. The v1.43 bug in one line: it recorded a
        // completed swap from a signal (`launchctl` exit 0) that could not fail.
        let before = HelperAgentHealth.Verdict.notRegistered
        guard case .repairFailed = HelperLifecycleManager.reconcileOutcome(before: before, after: nil) else {
            return XCTFail("an unverifiable repair must not be reported as repaired")
        }
    }
}

#endif
