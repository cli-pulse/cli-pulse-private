import XCTest
@testable import CLIPulseCore

#if os(macOS)

/// Unit tests for HelperInstaller's pure-logic helpers (version comparison
/// and architecture gate). Network / file / UDS paths are out of scope for
/// unit tests — exercised in the v1.16 ship E2E checklist (plan §7).
final class HelperInstallerTests: XCTestCase {

    func test_compareVersions_equalReturnsZero() {
        XCTAssertEqual(HelperInstaller.compareVersions("1.16.0", "1.16.0"), 0)
        XCTAssertEqual(HelperInstaller.compareVersions("1.0.0", "1.0.0"), 0)
    }

    func test_compareVersions_olderReturnsNegative() {
        XCTAssertLessThan(HelperInstaller.compareVersions("1.15.0", "1.16.0"), 0)
        XCTAssertLessThan(HelperInstaller.compareVersions("1.16.0", "1.16.1"), 0)
        XCTAssertLessThan(HelperInstaller.compareVersions("0.0.0", "1.0.0"), 0)
    }

    func test_compareVersions_newerReturnsPositive() {
        XCTAssertGreaterThan(HelperInstaller.compareVersions("1.16.1", "1.16.0"), 0)
        XCTAssertGreaterThan(HelperInstaller.compareVersions("2.0.0", "1.99.99"), 0)
    }

    func test_compareVersions_handlesShortVersionStrings() {
        // "1.16" treated as "1.16.0"
        XCTAssertEqual(HelperInstaller.compareVersions("1.16", "1.16.0"), 0)
        XCTAssertLessThan(HelperInstaller.compareVersions("1.16", "1.16.1"), 0)
    }

    func test_assertArchitectureMatches_failsWhenWrong() {
        // Build a manifest claiming the OPPOSITE arch from the host so we
        // can prove the guard fires. Rather than hard-coding which arch
        // we're on, just assert that one of the two is wrong.
        let armManifest = HelperInstaller.Manifest(
            version: "1.16.0",
            arch: "arm64",
            url: "https://example.com/p.pkg",
            sha256: "abc",
            sizeBytes: 1,
            minOsVersion: "13.0",
            releaseNotesUrl: nil
        )
        let intelManifest = HelperInstaller.Manifest(
            version: "1.16.0",
            arch: "x86_64",
            url: "https://example.com/p.pkg",
            sha256: "abc",
            sizeBytes: 1,
            minOsVersion: "13.0",
            releaseNotesUrl: nil
        )
        // Exactly one of the two should throw.
        let armPasses = (try? HelperInstaller.assertArchitectureMatches(armManifest)) != nil
        let intelPasses = (try? HelperInstaller.assertArchitectureMatches(intelManifest)) != nil
        XCTAssertTrue(armPasses != intelPasses, "Exactly one arch should match this host")
    }

    // MARK: - shouldReprobe (RC-2 popover-reopen re-probe gate)

    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    func test_shouldReprobe_installStatesNeverReprobe() {
        // The install flow owns these — a popover re-open must not race it,
        // regardless of how old lastChecked is.
        for state in [HelperInstaller.State.downloading(progress: 0.5),
                      .installing] {
            XCTAssertFalse(
                HelperInstaller.shouldReprobe(
                    state: state, lastChecked: nil, now: t0, maxAge: 8,
                    refreshInFlight: false),
                "\(state) should never re-probe (nil lastChecked)")
            XCTAssertFalse(
                HelperInstaller.shouldReprobe(
                    state: state,
                    lastChecked: t0.addingTimeInterval(-3600),
                    now: t0, maxAge: 8, refreshInFlight: false),
                "\(state) should never re-probe (very stale lastChecked)")
        }
    }

    /// A running `refresh()` owns the state: nothing re-probes on top of it,
    /// whatever the state and however old the last check.
    func test_shouldReprobe_neverWhileARefreshRuns() {
        for state in [HelperInstaller.State.checking, .notInstalled,
                      .running(version: "1.18.0"), .bundled(version: "1.30.0")] {
            for lastChecked in [nil, t0.addingTimeInterval(-3600)] {
                XCTAssertFalse(
                    HelperInstaller.shouldReprobe(
                        state: state, lastChecked: lastChecked, now: t0, maxAge: 8,
                        refreshInFlight: true),
                    "\(state), lastChecked \(String(describing: lastChecked))")
            }
        }
    }

    /// `.checking` with no refresh running is where `state` starts, before
    /// anything probed. Read as "mid-flight" it blocked the popover's first
    /// probe, and `helperPresent` stayed false after every launch until the
    /// user opened Settings (review of #610).
    func test_shouldReprobe_checkingBeforeAnyProbeReprobes() {
        XCTAssertTrue(HelperInstaller.shouldReprobe(
            state: .checking, lastChecked: nil, now: t0, maxAge: 8,
            refreshInFlight: false))
        // Throttled like a settled state once something has checked.
        XCTAssertFalse(HelperInstaller.shouldReprobe(
            state: .checking, lastChecked: t0.addingTimeInterval(-2), now: t0, maxAge: 8,
            refreshInFlight: false))
    }

    func test_shouldReprobe_settledStatesReprobeWhenStale() {
        // The post-install case: state settled `.notInstalled` but the helper
        // bound its socket later; on the next popover open (> maxAge) we must
        // re-probe so it flips to `.running`.
        let settled: [HelperInstaller.State] = [
            .notInstalled, .unreachable("sock"), .error("x"),
            .running(version: "1.18.0"),
            .updateAvailable(installed: "1.17.0", latest: "1.18.0"),
        ]
        for state in settled {
            // Older than maxAge → re-probe.
            XCTAssertTrue(
                HelperInstaller.shouldReprobe(
                    state: state,
                    lastChecked: t0.addingTimeInterval(-10),
                    now: t0, maxAge: 8, refreshInFlight: false),
                "\(state) older than maxAge should re-probe")
            // Never checked → re-probe.
            XCTAssertTrue(
                HelperInstaller.shouldReprobe(
                    state: state, lastChecked: nil, now: t0, maxAge: 8,
                    refreshInFlight: false),
                "\(state) with nil lastChecked should re-probe")
        }
    }

    func test_shouldReprobe_settledStatesThrottleWhenFresh() {
        // Rapid open/close toggling within maxAge must not hammer the
        // manifest endpoint with overlapping refreshes.
        for state in [HelperInstaller.State.notInstalled,
                      .running(version: "1.18.0")] {
            XCTAssertFalse(
                HelperInstaller.shouldReprobe(
                    state: state,
                    lastChecked: t0.addingTimeInterval(-2),
                    now: t0, maxAge: 8, refreshInFlight: false),
                "\(state) checked 2s ago should NOT re-probe (maxAge 8)")
        }
    }

    // MARK: - SessionControlHello.paired plumbing (RC-1 app-side)

    func test_sessionControlHello_pairedDefaultsNilForOlderHelpers() {
        let hello = SessionControlHello(
            protocolVersion: 1,
            supportedMethods: ["hello"],
            capabilities: SessionControlCapabilities(
                sendInput: true, subscribeEvents: false, approvals: false))
        XCTAssertNil(hello.paired, "older helper (no paired field) → nil")
    }

    func test_sessionControlHello_pairedRoundTrips() {
        let unpaired = SessionControlHello(
            protocolVersion: 1, supportedMethods: ["hello"],
            capabilities: SessionControlCapabilities(
                sendInput: true, subscribeEvents: false, approvals: false),
            paired: false)
        XCTAssertEqual(unpaired.paired, false)
    }

    // MARK: - SessionControlHello.implementation plumbing (v1.43 app-side)

    private func makeHello(impl: String?, version: String = "1.30.0") -> SessionControlHello {
        SessionControlHello(
            protocolVersion: 1,
            supportedMethods: ["hello"],
            capabilities: SessionControlCapabilities(
                sendInput: true, subscribeEvents: false, approvals: false),
            helperVersion: version,
            implementation: impl)
    }

    func test_sessionControlHello_implementationDefaultsNilForOlderHelpers() {
        let hello = SessionControlHello(
            protocolVersion: 1, supportedMethods: ["hello"],
            capabilities: SessionControlCapabilities(
                sendInput: true, subscribeEvents: false, approvals: false))
        XCTAssertNil(hello.implementation, "older helper (no implementation field) → nil")
        XCTAssertFalse(hello.isSwiftBundled, "nil implementation must not read as bundled")
    }

    func test_sessionControlHello_isSwiftBundledOnlyForExactValue() {
        XCTAssertTrue(makeHello(impl: "swift-bundled").isSwiftBundled)
        XCTAssertFalse(makeHello(impl: "python-pkg").isSwiftBundled)
        // Additive tolerance: an unknown future value must NOT read as bundled.
        XCTAssertFalse(makeHello(impl: "some-future-impl").isSwiftBundled)
        XCTAssertFalse(makeHello(impl: nil).isSwiftBundled)
    }

    // MARK: - resolveState (v1.43 nag suppression + regression pins)

    private func pkgManifest(_ version: String) -> HelperInstaller.Manifest {
        HelperInstaller.Manifest(
            version: version, arch: "arm64", url: "https://example.com/p.pkg",
            sha256: "abc", sizeBytes: 1, minOsVersion: "13.0", releaseNotesUrl: nil)
    }

    /// THE nag root-fix + primary regression pin: a bundled (swift-bundled)
    /// owner must resolve to `.bundled` even when the `.pkg` manifest advertises
    /// a HIGHER version. Pre-v1.43 this exact input produced `.updateAvailable`
    /// — the perpetual, unclearable nag. If this ever flips back to
    /// `.updateAvailable`, the shipped bug is back.
    func test_resolveState_bundledOwnerNeverNagsEvenWhenManifestNewer() {
        let state = HelperInstaller.resolveState(
            hello: makeHello(impl: "swift-bundled", version: "1.29.0"),
            manifest: pkgManifest("1.30.0"),   // .pkg claims a newer version
            socketExists: true,
            udsPath: "/tmp/sock")
        XCTAssertEqual(state, .bundled(version: "1.29.0"),
                       "bundled owner must show .bundled, NOT .updateAvailable")
    }

    func test_resolveState_bundledOwnerIsBundledWithNoManifest() {
        let state = HelperInstaller.resolveState(
            hello: makeHello(impl: "swift-bundled", version: "1.30.0"),
            manifest: nil, socketExists: true, udsPath: "/tmp/sock")
        XCTAssertEqual(state, .bundled(version: "1.30.0"))
    }

    /// Regression guard the OTHER direction: `.pkg` owners keep their update
    /// prompt exactly as before — the fix must not suppress legitimate nags.
    func test_resolveState_pkgOwnerOlderThanManifestStillNags() {
        let state = HelperInstaller.resolveState(
            hello: makeHello(impl: "python-pkg", version: "1.29.0"),
            manifest: pkgManifest("1.30.0"), socketExists: true, udsPath: "/tmp/sock")
        XCTAssertEqual(state, .updateAvailable(installed: "1.29.0", latest: "1.30.0"))
    }

    /// A pre-v1.43 helper omits `implementation` (nil) → legacy `.pkg` compare
    /// path, byte-for-byte unchanged (backward compat: new app ↔ old helper).
    func test_resolveState_olderHelperMissingImplFallsBackToLegacyCompare() {
        let older = HelperInstaller.resolveState(
            hello: makeHello(impl: nil, version: "1.29.0"),
            manifest: pkgManifest("1.30.0"), socketExists: true, udsPath: "/tmp/sock")
        XCTAssertEqual(older, .updateAvailable(installed: "1.29.0", latest: "1.30.0"))
        let upToDate = HelperInstaller.resolveState(
            hello: makeHello(impl: nil, version: "1.30.0"),
            manifest: pkgManifest("1.30.0"), socketExists: true, udsPath: "/tmp/sock")
        XCTAssertEqual(upToDate, .running(version: "1.30.0"))
    }

    func test_resolveState_pkgOwnerUpToDateIsRunning() {
        let state = HelperInstaller.resolveState(
            hello: makeHello(impl: "python-pkg", version: "1.30.0"),
            manifest: pkgManifest("1.30.0"), socketExists: true, udsPath: "/tmp/sock")
        XCTAssertEqual(state, .running(version: "1.30.0"))
    }

    func test_resolveState_helloNilSocketPresentIsUnreachable() {
        let state = HelperInstaller.resolveState(
            hello: nil, manifest: pkgManifest("1.30.0"),
            socketExists: true, udsPath: "/tmp/x.sock")
        guard case .unreachable = state else {
            return XCTFail("socket present + no hello → .unreachable, got \(state)")
        }
    }

    func test_resolveState_helloNilNoSocketIsNotInstalled() {
        let state = HelperInstaller.resolveState(
            hello: nil, manifest: nil, socketExists: false, udsPath: "/tmp/x.sock")
        XCTAssertEqual(state, .notInstalled)
    }

    func test_shouldReprobe_bundledStateReprobesWhenStale() {
        // `.bundled` is a settled state: it must re-probe when stale (a helper
        // swap changes the reported version) but throttle when fresh.
        XCTAssertTrue(HelperInstaller.shouldReprobe(
            state: .bundled(version: "1.30.0"),
            lastChecked: t0.addingTimeInterval(-10), now: t0, maxAge: 8,
            refreshInFlight: false))
        XCTAssertTrue(HelperInstaller.shouldReprobe(
            state: .bundled(version: "1.30.0"),
            lastChecked: nil, now: t0, maxAge: 8, refreshInFlight: false))
        XCTAssertFalse(HelperInstaller.shouldReprobe(
            state: .bundled(version: "1.30.0"),
            lastChecked: t0.addingTimeInterval(-2), now: t0, maxAge: 8,
            refreshInFlight: false))
    }
    // MARK: - helperPresent: the answer that survives a re-probe

    /// Settled states answer; `.unreachable` is present because a sandboxed
    /// build can be refused the socket of a healthy helper.
    func test_helperPresent_settledStatesAnswer() {
        for previously in [false, true] {
            XCTAssertTrue(HelperInstaller.helperPresent(after: .running(version: "1.0"), previously: previously))
            XCTAssertTrue(HelperInstaller.helperPresent(
                after: .updateAvailable(installed: "1.0", latest: "1.1"), previously: previously))
            XCTAssertTrue(HelperInstaller.helperPresent(after: .bundled(version: "1.0"), previously: previously))
            XCTAssertTrue(HelperInstaller.helperPresent(after: .unreachable("x"), previously: previously))
            XCTAssertFalse(HelperInstaller.helperPresent(after: .notInstalled, previously: previously))
        }
    }

    /// Every re-probe passes through `.checking`, each time the popover opens:
    /// the answer holds through it instead of dropping to false and back, which
    /// would make the Yield Score card blink out of the Overview.
    func test_helperPresent_holdsThroughTransientStates() {
        for state: HelperInstaller.State in [
            .checking, .downloading(progress: 0.5), .installing, .error("x"),
        ] {
            XCTAssertTrue(HelperInstaller.helperPresent(after: state, previously: true), "\(state)")
            XCTAssertFalse(HelperInstaller.helperPresent(after: state, previously: false), "\(state)")
        }
    }

    // MARK: - v1.44: the unreachable message must not assert a cause

    /// The advice must no longer promise the helper is present and fixable by
    /// reinstalling. The case that actually shows up is a SANDBOXED build that
    /// cannot reach `~/.clipulse` at all — connect returns EPERM while a healthy
    /// helper holds the socket, and "uninstall and reinstall" cannot fix a
    /// permission boundary.
    func testUnreachableTextDoesNotPromiseAReinstallWillFixIt() {
        let state = HelperInstaller.resolveState(
            hello: nil, manifest: nil, socketExists: true,
            udsPath: "/Users/x/.clipulse/clipulse-helper.sock"
        )
        guard case .unreachable(let message) = state else {
            return XCTFail("expected .unreachable, got \(state)")
        }
        // No sandbox claim: the only path this can ever report is the app-group
        // container, which the app-group entitlement PERMITS — so "the sandbox
        // blocks this path" is false by construction. Review caught that after
        // I had already written it.
        XCTAssertFalse(
            message.lowercased().contains("sandbox"),
            "cannot claim the sandbox blocks a path the entitlement allows. Got: \(message)"
        )
        XCTAssertTrue(
            message.lowercased().contains("local scanning"),
            "should say what still works, since that is the true part. Got: \(message)"
        )
        XCTAssertFalse(
            message.lowercased().contains("may be restarting"),
            "that was a guess among three causes, and the likeliest was missing"
        )
    }

    // MARK: - refreshIfStale on a fresh launch (review of #610)

    @MainActor
    private func makeInstaller(
        client: @escaping () -> SessionControlClient
    ) -> HelperInstaller {
        makeProbeOnlyHelperInstaller(client: client)
    }

    /// The popover's hook is the only probe most launches get. On a fresh
    /// installer (`state` still the initial `.checking`, nothing checked) it
    /// must probe exactly once, and a second call right after must not.
    @MainActor
    func test_refreshIfStale_probesOnceOnAFreshInstaller() async {
        var probes = 0
        let installer = makeInstaller {
            probes += 1
            return ScriptedHelloClient(reply: nil, delayNanoseconds: 0)
        }
        XCTAssertEqual(installer.state, .checking)
        XCTAssertNil(installer.lastChecked)

        await installer.refreshIfStale()
        XCTAssertEqual(probes, 1, "a fresh launch must probe")
        XCTAssertNotNil(installer.lastChecked)
        XCTAssertEqual(installer.state, .notInstalled)

        await installer.refreshIfStale()
        XCTAssertEqual(probes, 1, "a second call within maxAge must not probe again")
    }

    /// What the Yield Score card waits for: a helper that answers is present
    /// after the first popover probe, without a visit to Settings.
    @MainActor
    func test_refreshIfStale_findsTheHelperOnAFreshInstaller() async {
        let hello = makeHello(impl: "swift-bundled")
        let installer = makeInstaller {
            ScriptedHelloClient(reply: hello, delayNanoseconds: 0)
        }
        XCTAssertFalse(installer.helperPresent)

        await installer.refreshIfStale()

        XCTAssertEqual(installer.state, .bundled(version: "1.30.0"))
        XCTAssertTrue(installer.helperPresent)
    }

    /// While a refresh is running (`state` reads `.checking` then too), the
    /// hook must not start a second one on top of it.
    @MainActor
    func test_refreshIfStale_doesNotStackOnARunningRefresh() async {
        var probes = 0
        let installer = makeInstaller {
            probes += 1
            return ScriptedHelloClient(reply: nil, delayNanoseconds: 300_000_000)
        }
        let first = Task { @MainActor in await installer.refresh() }
        for _ in 0..<1000 where probes == 0 { await Task.yield() }
        XCTAssertEqual(probes, 1, "the first refresh must have started")

        await installer.refreshIfStale()
        XCTAssertEqual(probes, 1, "no second probe while the first runs")

        await first.value
        XCTAssertEqual(installer.state, .notInstalled)
    }
}


/// A `HelperInstaller` with the production capabilities, so `refresh()` is
/// allowed to probe, that reaches nothing real: `client` answers the probe, and
/// the socket path and manifest URL do not exist, so both fail at once.
@MainActor
func makeProbeOnlyHelperInstaller(
    client: @escaping () -> SessionControlClient
) -> HelperInstaller {
    let runtime = CLIPulseRuntimeEnvironment.resolveForTesting(
        infoDictionary: ["CFBundleIdentifier": "yyh.CLI-Pulse"],
        environment: [:]
    )
    XCTAssertTrue(runtime.capabilities.allowsHelperManifestRefresh)
    XCTAssertTrue(runtime.capabilities.allowsHelperRegistration)
    return HelperInstaller(
        runtimeEnvironment: runtime,
        manifestURL: URL(fileURLWithPath: "/nonexistent-cli-pulse-test/helper-latest.json"),
        urlSession: .shared,
        helloClient: client,
        productionPathResolver: {
            HelperInstaller.ProductionPaths(
                udsPath: "/nonexistent-cli-pulse-test/clipulse-helper.sock",
                helperDir: "/nonexistent-cli-pulse-test/CLI-Pulse-Helper")
        }
    )
}

/// A hello client that answers `reply` (nil: helper not running) after
/// `delayNanoseconds`. Only `hello()` is used by `HelperInstaller.refresh()`.
struct ScriptedHelloClient: SessionControlClient {
    let reply: SessionControlHello?
    let delayNanoseconds: UInt64

    func hello() async throws -> SessionControlHello {
        if delayNanoseconds > 0 { try? await Task.sleep(nanoseconds: delayNanoseconds) }
        guard let reply else { throw SessionControlError.helperNotRunning }
        return reply
    }

    func startManagedSession(
        provider: String, clientLabel: String?, cwdBasename: String?, cwdHmac: String?
    ) async throws -> SessionControlStartResult {
        throw SessionControlError.notImplemented
    }

    func listSessions() async throws -> [SessionControlSummary] { [] }

    func stopSession(sessionId: String) async throws {
        throw SessionControlError.notImplemented
    }
}
#endif
