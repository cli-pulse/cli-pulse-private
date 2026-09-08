import XCTest
@testable import CLIPulseCore

/// The remote-control gate is the switch that decides whether a feature which
/// opens a NETWORK LISTENER is offered at all. It gained a remote answer so the
/// owner can revoke it without shipping a release.
///
/// Every branch below is a way the mechanism could FAIL OPEN, and each has its
/// own test. That is deliberate: the design this replaces had six acceptance
/// criteria and not one of them touched the value the owner would actually
/// type, which is how a broken staging dial survived review.
final class RemoteControlKillSwitchTests: XCTestCase {

    private var d: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "kill-switch-\(UUID().uuidString)"
        d = UserDefaults(suiteName: suite)
    }
    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        d = nil
        super.tearDown()
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - The shipped posture

    /// Pins the default. Flipping it must be a deliberate act, not a drive-by.
    func test_aFreshInstallIsOffOnMac() {
        XCTAssertFalse(RemoteControlFeature.isAvailable(in: d, now: t0))
        XCTAssertFalse(RemoteControlFeature.shippedDefault)
    }

    /// ⚠️ The line above runs on macOS ONLY — `swift test` compiles nothing
    /// else — so it would stay green through any change to the iOS arm. The
    /// asymmetry is deliberate and load-bearing, so it is pinned as source:
    /// macOS off (the listener, remotely revocable), iOS on (a client that can
    /// reach nothing unless a Mac is already advertising, and which has no way
    /// to be turned on remotely at all).
    func test_theShippedDefaultIsAsymmetricAndBothArmsArePinned() throws {
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let src = try String(
            contentsOf: root.appendingPathComponent("Sources/CLIPulseCore/RemoteControlFeature.swift"),
            encoding: .utf8)
        let block = try XCTUnwrap(src.range(of: "#if os(iOS)").map {
            String(src[$0.lowerBound...].prefix(200))
        }, "the platform split is gone — one arm now decides both")
        XCTAssertTrue(block.contains("public static let shippedDefault = true"),
                      "the iOS arm no longer ships ON; the phone half becomes unreachable, since "
                      + "iOS has no defaults-write, no manifest fetch and no telemetry channel")
        XCTAssertTrue(block.contains("#else\n    public static let shippedDefault = false"),
                      "the macOS arm no longer ships OFF — a release would expose the listener")
    }

    // MARK: - The remote allowance

    func test_aFreshAllowanceIsHonoured() {
        RemoteControlFeature.recordRemoteAllowance(true, at: t0, in: d)
        XCTAssertTrue(RemoteControlFeature.isAvailable(in: d, now: t0.addingTimeInterval(60)))
    }

    /// THE KILL SWITCH. One manifest edit must turn it off everywhere.
    func test_theManifestSayingFalseTurnsItOff() {
        RemoteControlFeature.recordRemoteAllowance(true, at: t0, in: d)
        XCTAssertTrue(RemoteControlFeature.isAvailable(in: d, now: t0))
        RemoteControlFeature.recordRemoteAllowance(false, at: t0, in: d)
        XCTAssertFalse(RemoteControlFeature.isAvailable(in: d, now: t0))
    }

    /// REMOVING the field is also an off-switch, and must not leave the last
    /// answer standing. A manifest that loses the field — regenerated, rolled
    /// back — has to fail closed.
    func test_aManifestWithNoOpinionClearsTheAllowance() {
        RemoteControlFeature.recordRemoteAllowance(true, at: t0, in: d)
        RemoteControlFeature.recordRemoteAllowance(nil, at: t0, in: d)
        XCTAssertFalse(RemoteControlFeature.isAvailable(in: d, now: t0))
        XCTAssertNil(d.object(forKey: RemoteControlFeature.remoteAllowanceKey))
        XCTAssertNil(d.object(forKey: RemoteControlFeature.remoteAllowanceStampKey))
    }

    // MARK: - Decay, in both clock directions

    /// A kill switch a permanently offline machine can ignore forever is not a
    /// kill switch.
    func test_aStaleAllowanceDecaysToTheShippedDefault() {
        RemoteControlFeature.recordRemoteAllowance(true, at: t0, in: d)
        let justInside = t0.addingTimeInterval(RemoteControlFeature.allowanceCeiling - 1)
        let justPast = t0.addingTimeInterval(RemoteControlFeature.allowanceCeiling + 1)
        XCTAssertTrue(RemoteControlFeature.isAvailable(in: d, now: justInside))
        XCTAssertFalse(RemoteControlFeature.isAvailable(in: d, now: justPast),
                       "a cached allowance outlived the ceiling — the switch cannot be revoked")
    }

    /// The direction that DEFEATS the ceiling: a clock pushed backwards makes
    /// a stale allowance look fresh forever. Refused.
    func test_anAllowanceStampedInTheFutureIsNotTrusted() {
        RemoteControlFeature.recordRemoteAllowance(true, at: t0, in: d)
        XCTAssertFalse(RemoteControlFeature.isAvailable(in: d, now: t0.addingTimeInterval(-1)),
                       "a backwards clock revived a cached allowance")
    }

    // MARK: - The local override is the owner's escape hatch, in both directions

    func test_theLocalOverrideBeatsTheRemoteAllowance() {
        RemoteControlFeature.recordRemoteAllowance(false, at: t0, in: d)
        d.set(true, forKey: RemoteControlFeature.overrideDefaultsKey)
        XCTAssertTrue(RemoteControlFeature.isAvailable(in: d, now: t0),
                      "the remote answer overrode the owner's own machine")

        RemoteControlFeature.recordRemoteAllowance(true, at: t0, in: d)
        d.set(false, forKey: RemoteControlFeature.overrideDefaultsKey)
        XCTAssertFalse(RemoteControlFeature.isAvailable(in: d, now: t0),
                       "the remote answer forced the feature on against a local off")
    }

    // MARK: - Only a real boolean counts, for the CACHE too

    /// The override key already had this discipline; the cache must not be the
    /// weaker of the two. `UserDefaults.bool(forKey:)` reads "1"/"YES"/1 as
    /// true, so a stray value could otherwise ship the feature by accident.
    func test_aNonBooleanCacheValueIsIgnored() {
        for junk in ["YES", "1", "true"] as [Any] {
            d.set(junk, forKey: RemoteControlFeature.remoteAllowanceKey)
            d.set(t0, forKey: RemoteControlFeature.remoteAllowanceStampKey)
            XCTAssertFalse(RemoteControlFeature.isAvailable(in: d, now: t0),
                           "a \(type(of: junk)) in the cache enabled the feature")
        }
        d.set(1 as Int, forKey: RemoteControlFeature.remoteAllowanceKey)
        d.set(t0, forKey: RemoteControlFeature.remoteAllowanceStampKey)
        XCTAssertFalse(RemoteControlFeature.isAvailable(in: d, now: t0),
                       "an Int in the cache enabled the feature")
    }

    /// A value with no stamp, or a stamp of the wrong type, cannot be aged —
    /// so it must not be honoured.
    func test_anAllowanceWithNoUsableStampIsIgnored() {
        d.set(true, forKey: RemoteControlFeature.remoteAllowanceKey)
        XCTAssertFalse(RemoteControlFeature.isAvailable(in: d, now: t0), "no stamp was honoured")
        d.set("not a date", forKey: RemoteControlFeature.remoteAllowanceStampKey)
        XCTAssertFalse(RemoteControlFeature.isAvailable(in: d, now: t0), "a junk stamp was honoured")
    }

    /// Vacuity guard: if `isAvailable` were hard-wired to false every test
    /// above would pass while the mechanism did nothing. One case must be TRUE.
    func test_theMechanismCanActuallySayYes() {
        RemoteControlFeature.recordRemoteAllowance(true, at: t0, in: d)
        XCTAssertTrue(RemoteControlFeature.isAvailable(in: d, now: t0),
                      "nothing in this suite can distinguish a working mechanism from a stub")
    }

    // MARK: - The manifest half

    /// ⚠️ CORRECTED. The first version of this section claimed the manifest
    /// half could not be compiled by `swift test` "including CI's", and used
    /// source guards on that basis. Half true, and the false half mattered:
    /// `AppUpdater.swift` opens with `#if os(macOS) && DEVID_BUILD` and
    /// `Package.swift` does not define it, so the DEFAULT `swift test` — the
    /// one run locally — really does compile that file to nothing. But CI runs
    /// a SECOND pass, `swift test -Xswiftc -DDEVID_BUILD`
    /// (.github/workflows/swift-ci.yml:240), which compiles it fully and
    /// already had `AppUpdaterTests`. CI proved the claim wrong by failing:
    /// adding a field broke that file's memberwise `Manifest(...)` calls.
    ///
    /// So the decode IS behaviourally testable, and is tested below rather
    /// than grepped for. Run `swift test -Xswiftc -DDEVID_BUILD` locally
    /// before trusting a green default run on anything DEVID-gated.
    #if DEVID_BUILD
    func test_theManifestFieldIsOptionalAndDecodesBothWays() throws {
        let base = """
        {"version":"1.53.0","arch":"arm64","url":"https://example.com/a.dmg",
         "sha256":"abc","size_bytes":1,"min_os_version":"13.0"
        """
        let dec = JSONDecoder()

        let on = try dec.decode(AppUpdater.Manifest.self,
                                from: Data((base + ",\"remote_control_enabled\":true}").utf8))
        XCTAssertEqual(on.remoteControlEnabled, true)

        let off = try dec.decode(AppUpdater.Manifest.self,
                                 from: Data((base + ",\"remote_control_enabled\":false}").utf8))
        XCTAssertEqual(off.remoteControlEnabled, false)

        // The case that must NOT be conflated with `false`: nil clears the
        // cache, false is an explicit off. Every manifest shipped so far lacks
        // the field, so a non-optional here would break the updater outright.
        let silent = try dec.decode(AppUpdater.Manifest.self, from: Data((base + "}").utf8))
        XCTAssertNil(silent.remoteControlEnabled,
                     "a manifest with no opinion must decode as nil, not false")
    }

    /// The three decoded shapes drive the three resolutions, end to end.
    func test_eachDecodedShapeResolvesTheGateCorrectly() throws {
        let base = """
        {"version":"1.53.0","arch":"arm64","url":"https://example.com/a.dmg",
         "sha256":"abc","size_bytes":1,"min_os_version":"13.0"
        """
        let dec = JSONDecoder()
        for (json, expected) in [(",\"remote_control_enabled\":true}", true),
                                 (",\"remote_control_enabled\":false}", false),
                                 ("}", RemoteControlFeature.shippedDefault)] {
            let m = try dec.decode(AppUpdater.Manifest.self, from: Data((base + json).utf8))
            RemoteControlFeature.recordRemoteAllowance(m.remoteControlEnabled, at: t0, in: d)
            XCTAssertEqual(RemoteControlFeature.isAvailable(in: d, now: t0), expected,
                           "manifest \(json) resolved wrongly")
        }
    }
    #endif

    /// Ordering is a property of the SOURCE, not of a value, so it stays a
    /// source guard — and it reads shipping code only. Its first run compared
    /// prose: the first occurrence of `recordRemoteAllowance` is in a doc
    /// comment 100 lines above the call.
    private func updaterCode() throws -> String {
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/CLIPulseCore/AppUpdater.swift"),
                          encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    func test_theAllowanceIsRecordedOnlyAfterTheManifestPassesValidation() throws {
        let code = try updaterCode()
        XCTAssertTrue(code.contains("RemoteControlFeature.recordRemoteAllowance(m."),
                      "nothing records the allowance — the kill switch is inert")
        let archAt = try XCTUnwrap(code.range(of: "try Self.assertArchitectureMatches(m)"))
        let recordAt = try XCTUnwrap(code.range(of: "RemoteControlFeature.recordRemoteAllowance(m."))
        XCTAssertTrue(archAt.lowerBound < recordAt.lowerBound,
                      "the allowance is recorded before the manifest is validated — a manifest the "
                      + "updater rejects would still be able to enable the feature")
    }

    /// No second timer. The first draft specified its own refresh cadence; the
    /// repo already has one, tuned by a prior audit.
    func test_noSeparatePollWasAdded() throws {
        XCTAssertFalse(try updaterCode().contains("allowanceRefreshInterval"),
                       "a second poll appeared; the allowance rides the existing refresh")
    }
}
