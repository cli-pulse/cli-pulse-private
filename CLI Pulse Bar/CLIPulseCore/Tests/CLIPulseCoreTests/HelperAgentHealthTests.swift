import XCTest
@testable import CLIPulseCore

#if os(macOS)

/// Tests for `HelperAgentHealth` — the signal that distinguishes "the helper
/// agent is registered and running" from "the helper agent is registered and
/// has failed to spawn 22,138 times".
///
/// Every fixture below is **verbatim `launchctl print` output captured from a
/// real machine on 2026-08-07**, not hand-written: the crash-looping record is
/// the actual `yyh.CLI-Pulse.helper.agent` record from the incident, the
/// healthy one is the same job after recovery, and the code-signing one comes
/// from a signed throwaway app used to reproduce the failure modes in
/// isolation. Hand-written fixtures would have quietly dropped the nested
/// `state = active` lines, which is exactly the trap the parser has to survive.
final class HelperAgentHealthTests: XCTestCase {

    // MARK: - Fixtures

    /// The incident: registered, `.enabled` per SMAppService, and dead.
    /// Note the two nested `state = active` lines — they belong to the resource
    /// and jetsam coalitions, NOT to the job.
    private static let crashLooping = """
    gui/501/yyh.CLI-Pulse.helper.agent = {
    \tactive count = 0
    \tpath = (submitted by smd.553)
    \ttype = Submitted
    \tmanaged_by = com.apple.xpc.ServiceManagement
    \tstate = spawn scheduled

    \tprogram identifier = Contents/Helpers/cli_pulse_helper (mode: 2)
    \tparent bundle identifier = yyh.CLI-Pulse
    \tparent bundle version = 96
    \tBTM uuid = 3E70D341-3CFF-4525-969D-52B16E0E1105
    \targuments = {
    \t\tcli_pulse_helper
    \t\tdaemon
    \t\t--interval
    \t\t120
    \t}

    \tdomain = gui/501 [100015]
    \tasid = 100015
    \tminimum runtime = 30
    \texit timeout = 5
    \truns = 22138
    \tlast exit code = 78: EX_CONFIG

    \tresource coalition = {
    \t\tID = 1348
    \t\ttype = resource
    \t\tstate = active
    \t\tactive count = 1
    \t\tname = yyh.CLI-Pulse.helper.agent
    \t}

    \tjetsam coalition = {
    \t\tID = 1349
    \t\ttype = jetsam
    \t\tstate = active
    \t\tactive count = 1
    \t\tname = yyh.CLI-Pulse.helper.agent
    \t}

    \tspawn type = background (5)
    \tjob state = spawn failed
    }
    """

    /// The same job after `unregister()` + `register()` rebound it.
    private static let healthy = """
    gui/501/yyh.CLI-Pulse.helper.agent = {
    \tactive count = 1
    \tpath = (submitted by smd.89007)
    \ttype = Submitted
    \tmanaged_by = com.apple.xpc.ServiceManagement
    \tstate = running

    \tprogram identifier = Contents/Helpers/cli_pulse_helper (mode: 2)
    \tparent bundle identifier = yyh.CLI-Pulse
    \tparent bundle version = 99
    \tBTM uuid = 6258572A-648A-43E1-B520-F471DBBB4C01

    \truns = 2
    \tpid = 64011
    \tlast exit code = 0

    \tresource coalition = {
    \t\tID = 1348
    \t\ttype = resource
    \t\tstate = active
    \t}

    \tjob state = running
    }
    """

    /// Wrong code identity at the right path. launchd reports this as an exit
    /// *reason*, with no `last exit code` line at all — a parser that only
    /// looked for an exit code would call this healthy.
    private static let codeSigningRefused = """
    gui/501/yyh.SMAgentProbe.agent = {
    \tactive count = 0
    \tstate = spawn scheduled

    \tprogram identifier = Contents/Helpers/probe_helper (mode: 2)
    \tparent bundle version = 1
    \truns = 6
    \tlast exit reason = OS_REASON_CODESIGNING
    \tjob state = spawn failed
    }
    """

    /// A freshly-started job, mid-exec. Not running yet, but nothing is wrong.
    private static let transientXpcproxy = """
    gui/501/yyh.CLI-Pulse.helper.agent = {
    \tactive count = 1
    \tstate = xpcproxy

    \tparent bundle version = 99
    \truns = 1
    \tlast exit code = (never exited)
    }
    """

    /// What launchctl prints on stderr when the label is unknown (exit 113).
    private static let notFound = """
    Bad request.
    Could not find service "yyh.CLI-Pulse.helper.agent" in domain for user gui: 501
    """

    // MARK: - Parsing

    func testParse_readsTopLevelJobStateNotNestedCoalitionState() {
        // The trap: `resource coalition` and `jetsam coalition` each carry
        // `state = active`. A parser that matched "state = " anywhere in the
        // output would read this dead job as active and report exactly the lie
        // this type exists to remove. Only one-tab-indented keys are top level.
        let h = HelperAgentHealth.parse(launchctlPrint: Self.crashLooping, exitCode: 0)
        XCTAssertEqual(h.state, "spawn scheduled",
                       "top-level state must win over the nested coalition `state = active` lines")
        XCTAssertEqual(h.jobState, "spawn failed")
        XCTAssertNil(h.pid, "a job that never spawned has no pid")
    }

    func testParse_readsExitCodeNumberOutOfLaunchdsCompositeString() {
        let h = HelperAgentHealth.parse(launchctlPrint: Self.crashLooping, exitCode: 0)
        XCTAssertEqual(h.lastExitCode, 78)
        XCTAssertEqual(h.lastExitCodeText, "78: EX_CONFIG")
        XCTAssertEqual(h.runs, 22138)
        XCTAssertEqual(h.parentBundleVersion, "96")
        XCTAssertEqual(h.programIdentifier, "Contents/Helpers/cli_pulse_helper (mode: 2)")
    }

    func testParse_neverExitedIsNotExitCodeZero() {
        // "(never exited)" must not parse as 0 — they mean different things and
        // an Int(...) ?? 0 fallback would erase the difference.
        let h = HelperAgentHealth.parse(launchctlPrint: Self.transientXpcproxy, exitCode: 0)
        XCTAssertNil(h.lastExitCode)
        XCTAssertEqual(h.lastExitCodeText, "(never exited)")
    }

    func testParse_healthyRecord() {
        let h = HelperAgentHealth.parse(launchctlPrint: Self.healthy, exitCode: 0)
        XCTAssertTrue(h.jobKnown)
        XCTAssertEqual(h.state, "running")
        XCTAssertEqual(h.pid, 64011)
        XCTAssertEqual(h.lastExitCode, 0)
        XCTAssertEqual(h.parentBundleVersion, "99")
    }

    func testParse_nonZeroLaunchctlExitMeansNotRegistered() {
        // launchctl exiting non-zero is an answer, not a measurement failure.
        let h = HelperAgentHealth.parse(launchctlPrint: Self.notFound, exitCode: 113)
        XCTAssertFalse(h.jobKnown)
        XCTAssertNil(h.state)
    }

    // MARK: - Verdict
    //
    // The point of these: the verdict function must be capable of returning
    // *different* answers for different real inputs. A predicate that always
    // says "fine" passes any single happy-path assertion — see
    // feedback_status_text_always_populated_tautology.md.

    func testVerdict_crashLoopingAgentIsNotReportedAsRunning() {
        // The whole bug in one assertion. SMAppService said `.enabled` for this
        // exact record; the launchd record says otherwise.
        let h = HelperAgentHealth.parse(launchctlPrint: Self.crashLooping, exitCode: 0)
        let v = HelperAgentHealth.verdict(for: h, currentBundleVersion: "99")
        XCTAssertEqual(v, .spawnFailing("78: EX_CONFIG"))
        XCTAssertNotEqual(v, .running)
        XCTAssertTrue(v.needsRepair)
    }

    func testVerdict_spawnFailureOutranksStaleness() {
        // This record is BOTH failing and pinned to build 96 while 99 runs.
        // Reporting it as merely stale would understate it, and the detail
        // string is what a user or a log reader needs.
        let h = HelperAgentHealth.parse(launchctlPrint: Self.crashLooping, exitCode: 0)
        guard case .spawnFailing = HelperAgentHealth.verdict(for: h, currentBundleVersion: "99") else {
            return XCTFail("a job that cannot spawn must report the spawn failure, not the version drift")
        }
    }

    func testVerdict_codeSigningRefusalIsReportedWithItsOwnReason() {
        // Distinguishable from the path failure: same "not running", different
        // cause, and the cause is what tells a maintainer whether to look at
        // the bundle path or the signature. This record has no exit code line.
        let h = HelperAgentHealth.parse(launchctlPrint: Self.codeSigningRefused, exitCode: 0)
        XCTAssertEqual(
            HelperAgentHealth.verdict(for: h, currentBundleVersion: "1"),
            .spawnFailing("OS_REASON_CODESIGNING")
        )
    }

    func testVerdict_runningAndCurrentIsRunning() {
        let h = HelperAgentHealth.parse(launchctlPrint: Self.healthy, exitCode: 0)
        let v = HelperAgentHealth.verdict(for: h, currentBundleVersion: "99")
        XCTAssertEqual(v, .running)
        XCTAssertFalse(v.needsRepair, "a healthy agent must not be torn down and re-registered")
    }

    func testVerdict_runningButPinnedToPreviousBuildIsStale() {
        // An in-place update leaves a *working* agent pinned to the build that
        // registered it — verified on a real machine: replacing the bundle at
        // the same path keeps the helper running, but `parent bundle version`
        // and the job's `ProgramArguments` stay frozen at the old build. That
        // is why plist argument changes never reached upgraded users, and why
        // this is worth a re-register even though nothing is visibly broken.
        let h = HelperAgentHealth.parse(launchctlPrint: Self.healthy, exitCode: 0)
        XCTAssertEqual(
            HelperAgentHealth.verdict(for: h, currentBundleVersion: "100"),
            .staleRegistration(recorded: "99", current: "100")
        )
    }

    func testVerdict_noCurrentVersionSkipsStalenessCheck() {
        let h = HelperAgentHealth.parse(launchctlPrint: Self.healthy, exitCode: 0)
        XCTAssertEqual(HelperAgentHealth.verdict(for: h, currentBundleVersion: nil), .running)
    }

    func testVerdict_unknownLabelIsNotRegistered() {
        let h = HelperAgentHealth.parse(launchctlPrint: Self.notFound, exitCode: 113)
        let v = HelperAgentHealth.verdict(for: h, currentBundleVersion: "99")
        XCTAssertEqual(v, .notRegistered)
        XCTAssertTrue(v.needsRepair)
    }

    func testVerdict_midExecIsIndeterminateAndNotRepaired() {
        // `xpcproxy` is the moment between fork and exec. Tearing down a
        // registration here would restart a helper that was starting fine, on
        // every launch that happened to race it.
        let h = HelperAgentHealth.parse(launchctlPrint: Self.transientXpcproxy, exitCode: 0)
        let v = HelperAgentHealth.verdict(for: h, currentBundleVersion: "99")
        XCTAssertEqual(v, .indeterminate("xpcproxy"))
        XCTAssertFalse(v.needsRepair)
    }

    func testVerdict_distinguishesAllFourRealFixtures() {
        // Anti-tautology: one call site, four real records, four different
        // answers. If the verdict ever collapses to a constant, this fails.
        let verdicts = [
            HelperAgentHealth.verdict(
                for: .parse(launchctlPrint: Self.healthy, exitCode: 0), currentBundleVersion: "99"),
            HelperAgentHealth.verdict(
                for: .parse(launchctlPrint: Self.crashLooping, exitCode: 0), currentBundleVersion: "99"),
            HelperAgentHealth.verdict(
                for: .parse(launchctlPrint: Self.notFound, exitCode: 113), currentBundleVersion: "99"),
            HelperAgentHealth.verdict(
                for: .parse(launchctlPrint: Self.transientXpcproxy, exitCode: 0), currentBundleVersion: "99"),
        ]
        XCTAssertEqual(Set(verdicts.map(\.description)).count, 4,
                       "four materially different launchd records must not map to the same verdict")
    }
}

#endif
