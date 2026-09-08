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
    func test_aFreshInstallIsOff() {
        XCTAssertFalse(RemoteControlFeature.isAvailable(in: d, now: t0))
        XCTAssertFalse(RemoteControlFeature.shippedDefault)
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

    // MARK: - The manifest half, which `swift test` CANNOT compile

    /// ⚠️ `AppUpdater.swift` opens with `#if os(macOS) && DEVID_BUILD`, and
    /// `DEVID_BUILD` is not defined by `Package.swift`. So under `swift build`
    /// and `swift test` — including CI's — that file compiles to NOTHING: the
    /// manifest field and the hook below are not merely untested there, they
    /// are not even type-checked. A behavioural test referencing
    /// `AppUpdater.Manifest` does not compile in this target at all; that is
    /// how this limitation was found rather than assumed.
    ///
    /// So these are source guards, which do run, plus a real Developer ID
    /// build of the app as the compile check. Do not "fix" them into
    /// behavioural tests without first moving `Manifest` out of the
    /// conditional — and if you do that, delete these.
    private func updaterSource() throws -> String {
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/CLIPulseCore/AppUpdater.swift"),
                          encoding: .utf8)
    }

    /// Shipping code only. The ordering guard below first compared the raw
    /// file and failed, because the FIRST occurrence of `recordRemoteAllowance`
    /// is in a doc comment 100 lines above the call. A guard that matches the
    /// prose explaining the code is not a guard on the code.
    private func updaterCode() throws -> String {
        try updaterSource()
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    func test_theManifestCarriesTheAllowanceAsAnOptional() throws {
        let src = try updaterSource()
        XCTAssertTrue(src.contains("public let remoteControlEnabled: Bool?"),
                      "the manifest no longer carries the allowance, or it stopped being OPTIONAL — "
                      + "a non-optional would make every existing manifest fail to decode, taking "
                      + "the updater down with it")
        XCTAssertTrue(src.contains("case remoteControlEnabled = \"remote_control_enabled\""),
                      "the JSON key is gone or renamed; the field would silently always be nil")
    }

    func test_theAllowanceIsRecordedOnlyAfterTheManifestPassesValidation() throws {
        let src = try updaterSource()
        XCTAssertTrue(src.contains("RemoteControlFeature.recordRemoteAllowance(m.remoteControlEnabled"),
                      "nothing records the allowance — the kill switch is inert")
        // Ordering is the property: recording must sit AFTER the arch check,
        // so a manifest rejected for any other reason lets the cache decay.
        let code = try updaterCode()
        let archAt = try XCTUnwrap(code.range(of: "try Self.assertArchitectureMatches(m)"))
        let recordAt = try XCTUnwrap(code.range(of: "RemoteControlFeature.recordRemoteAllowance(m."))
        XCTAssertTrue(archAt.lowerBound < recordAt.lowerBound,
                      "the allowance is recorded before the manifest is validated — a manifest the "
                      + "updater rejects would still be able to enable the feature")
    }

    /// No second timer. The first draft of this design specified its own
    /// refresh cadence; the repo already has one, tuned by a prior audit.
    func test_noSeparatePollWasAdded() throws {
        let src = try updaterSource()
        XCTAssertFalse(src.contains("allowanceRefreshInterval"),
                       "a second poll appeared; the allowance rides the existing refresh")
    }
}
