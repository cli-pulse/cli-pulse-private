import XCTest
@testable import CLIPulseCore

#if os(macOS)

/// Pins the two halves of the v1.44 device-version observability fix
/// (migrate_v0.70), found while investigating low activation: 62 of ~68
/// production Macs reported `devices.helper_version = "1.0.0"`, so the fleet's
/// real version was unobservable and the "why do installed devices send no
/// data" question could not be answered.
///
/// The fix adds a SEPARATE `devices.app_version` field rather than making
/// `helper_version` truthful — because `helper_version` doubles as the
/// remote-command capability gate. Both halves of that decision are pinned here.
final class DeviceAppVersionReportingTests: XCTestCase {

    // MARK: - The new observability field

    func test_currentAppVersionString_isNotThePlaceholder() {
        XCTAssertNotEqual(
            HelperAPIClient.currentAppVersionString,
            HelperAPIClient.appPairedHelperVersion,
            "the observability value must be the real app version, not the registration placeholder"
        )
    }

    func test_currentAppVersionString_isNonEmpty() {
        XCTAssertFalse(
            HelperAPIClient.currentAppVersionString.trimmingCharacters(in: .whitespaces).isEmpty,
            "a blank version is as useless as no version"
        )
    }

    func test_currentAppVersionString_fitsTheRpcClamp() {
        // helper_report_app_version does `left(v_clean, 32)`; anything longer is
        // silently truncated server-side.
        XCTAssertLessThanOrEqual(
            HelperAPIClient.currentAppVersionString.count, 32,
            "helper_report_app_version clamps to 32 chars"
        )
    }

    // MARK: - Re-report gating (agy review: a plain "did I report" flag is wrong)

    func test_shouldReport_whenNothingReportedYet() {
        XCTAssertTrue(HelperAPIClient.shouldReportAppVersion(
            lastReportedKey: nil, deviceId: "dev-A", appVersion: "1.43.0 (96)"))
    }

    func test_shouldNotReport_whenSameDeviceAndVersionAlreadyReported() {
        let key = HelperAPIClient.appVersionReportKey(deviceId: "dev-A", appVersion: "1.43.0 (96)")
        XCTAssertFalse(HelperAPIClient.shouldReportAppVersion(
            lastReportedKey: key, deviceId: "dev-A", appVersion: "1.43.0 (96)"),
            "steady state must cost zero extra RPCs")
    }

    /// THE regression this gating exists for. The reporting daemon is
    /// long-lived and re-reads its pairing config every cycle. If the user
    /// re-pairs (or pairs a second device), `deviceId` changes underneath the
    /// process — a plain "did I report yet" boolean would leave that brand-new
    /// device row with a null version forever.
    func test_shouldReport_afterRepairingToADifferentDevice() {
        let key = HelperAPIClient.appVersionReportKey(deviceId: "dev-A", appVersion: "1.43.0 (96)")
        XCTAssertTrue(HelperAPIClient.shouldReportAppVersion(
            lastReportedKey: key, deviceId: "dev-B", appVersion: "1.43.0 (96)"),
            "a re-paired device must get its own version report")
    }

    func test_shouldReport_afterTheAppVersionChanges() {
        let key = HelperAPIClient.appVersionReportKey(deviceId: "dev-A", appVersion: "1.43.0 (96)")
        XCTAssertTrue(HelperAPIClient.shouldReportAppVersion(
            lastReportedKey: key, deviceId: "dev-A", appVersion: "1.44.0 (97)"),
            "an upgraded app must refresh the reported version")
    }

    // MARK: - Collector outcome classification (migrate_v0.71)

    /// THE regression this predicate exists for. An earlier cut ORed in
    /// `!status_text.isEmpty`, but `status_text` is a non-optional display
    /// string every collector always fills — including on its no-data paths.
    /// That made the predicate a tautology: `empty` became unreachable and the
    /// exact silent-zero devices the feature was built to find reported `ok`.
    ///
    /// Reproduces the real shape from `ClaudeResultBuilder`: signed in, but the
    /// bookmark/keychain isn't active, so quota/remaining are nil and tiers are
    /// empty while status_text still reads "Claude quota unavailable — …".
    func test_classify_silentZeroIsEmpty_evenThoughStatusTextIsPresent() {
        XCTAssertEqual(
            HelperAPIClient.classifyCollectorOutcome(
                tiersCount: 0, quota: nil, remaining: nil, todayUsage: 0, weekUsage: 0
            ),
            "empty",
            "a collector that produced no usable data must classify as empty — this is the silent-zero signal"
        )
    }

    func test_classify_realDataIsOk() {
        // Tiers present (the common Claude/Codex shape).
        XCTAssertEqual(HelperAPIClient.classifyCollectorOutcome(
            tiersCount: 3, quota: nil, remaining: nil, todayUsage: 0, weekUsage: 0), "ok")
        // Credits-style collector: no tiers, but a real balance.
        XCTAssertEqual(HelperAPIClient.classifyCollectorOutcome(
            tiersCount: 0, quota: 100, remaining: 42, todayUsage: 0, weekUsage: 0), "ok")
        // Usage-only: no quota concept at all, but the user did use it.
        XCTAssertEqual(HelperAPIClient.classifyCollectorOutcome(
            tiersCount: 0, quota: nil, remaining: nil, todayUsage: 17, weekUsage: 0), "ok")
        XCTAssertEqual(HelperAPIClient.classifyCollectorOutcome(
            tiersCount: 0, quota: nil, remaining: nil, todayUsage: 0, weekUsage: 5), "ok")
    }

    /// A zero-remaining quota is still DATA — the user is simply exhausted.
    /// `remaining: 0` must not be mistaken for "collected nothing".
    func test_classify_exhaustedQuotaIsOkNotEmpty() {
        XCTAssertEqual(HelperAPIClient.classifyCollectorOutcome(
            tiersCount: 0, quota: 100, remaining: 0, todayUsage: 0, weekUsage: 0), "ok")
    }

    // MARK: - The deliberately-preserved capability trap

    /// REGRESSION PIN. `helper_version` is overloaded: besides observability it
    /// is the remote-command capability gate — `Device.helperVersionAtLeast(1,
    /// 15, 0)` extracts the first semver from it to decide whether to offer
    /// remote Codex/Gemini session starts.
    ///
    /// App-paired devices may have NO command-capable helper (the MAS build
    /// ships none), so the value they register MUST stay below that floor. A
    /// well-meaning "let's report the real version here" change would flip every
    /// App Store device to `capable`, surfacing remote-start UI whose commands
    /// hang pending forever. If this test fails, read the doc comment on
    /// `HelperAPIClient.appPairedHelperVersion` before changing it.
    func test_appPairedHelperVersion_staysBelowTheRemoteCommandFloor() {
        let registered = HelperAPIClient.appPairedHelperVersion
        XCTAssertEqual(registered, "1.0.0", "app-paired registration value changed — see doc comment")

        // Mirror the client-side gate: first semver in the string, compared
        // against the 1.15.0 floor.
        let parts = registered.split(separator: ".").compactMap { Int($0) }
        XCTAssertGreaterThanOrEqual(parts.count, 2, "must parse as a semver for the gate to read it")
        let major = parts[0], minor = parts[1]
        let clearsFloor = (major > 1) || (major == 1 && minor >= 15)
        XCTAssertFalse(
            clearsFloor,
            "app-paired devices must NOT clear the 1.15.0 remote-command floor — the MAS build has no command-capable helper"
        )
    }

    /// The real app version WOULD clear that floor — which is exactly why it is
    /// reported through the separate `app_version` field instead. This pins the
    /// reasoning so the two values can't be quietly merged later.
    func test_realAppVersionWouldClearTheFloor_henceTheSeparateField() {
        let parts = HelperAPIClient.currentAppVersionString
            .split(whereSeparator: { !"0123456789".contains($0) })
            .compactMap { Int($0) }
        guard parts.count >= 2 else {
            return XCTFail("expected a parseable app version, got \(HelperAPIClient.currentAppVersionString)")
        }
        let clearsFloor = (parts[0] > 1) || (parts[0] == 1 && parts[1] >= 15)
        XCTAssertTrue(
            clearsFloor,
            "if the app version ever drops below 1.15.0 this rationale needs revisiting"
        )
    }
}

#endif
