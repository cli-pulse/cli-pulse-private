import XCTest
@testable import CLIPulseCore

/// `isPaired` is the account's flag. Settings offered "Set Up Cloud Sync" only
/// while it was false, so a Mac whose own device was removed — told by
/// Settings › Advanced to "set up cloud sync again in Settings" — and a second
/// Mac on an already-paired account had no way to pair. These pin when Settings
/// now offers it, and above all when it must not: a transient failure or a
/// failure of a device already replaced would leave a second device row behind.
final class ThisMacPairingTests: XCTestCase {

    private let device = "8f0c3a52-1111-4c1e-9d7e-3b1f5d0a2c44"
    private let replacedDevice = "0b7e2d10-2222-4a55-8c3b-6e9f1a2b3c4d"

    /// The body PostgREST returns when a helper RPC raises for a missing device
    /// row or a secret that no longer matches (backend/supabase/helper_rpc.sql).
    private let deviceGoneBody = #"{"code":"P0001","details":null,"hint":null,"message":"Device not found or unauthorized"}"#

    /// The token the helper stores for that failure, produced the way the helper
    /// produces it rather than typed in, so a renamed token fails here.
    private var deviceGoneCode: String {
        HelperSyncFailure.code(
            for: HelperAPIError.httpError(status: 400, function: "helper_heartbeat", body: deviceGoneBody)
        )
    }

    private func failure(_ code: String?, deviceId: String?, text: String? = nil) -> HelperIPC.Status {
        HelperIPC.Status(
            state: .error, lastSync: nil, error: text ?? "helper_heartbeat HTTP 400",
            errorCode: code, helperVersion: "1.0.0", deviceId: deviceId
        )
    }

    private func decide(
        isAuthenticated: Bool = true,
        isPaired: Bool = true,
        canPairThisMac: Bool = true,
        pairedDeviceId: String?,
        status: HelperIPC.Status?
    ) -> ThisMacPairing.State {
        ThisMacPairing.state(
            isAuthenticated: isAuthenticated,
            isPaired: isPaired,
            canPairThisMac: canPairThisMac,
            pairedDeviceId: pairedDeviceId,
            helperStatus: status
        )
    }

    // MARK: - This Mac's device was removed

    func testTheHelpersDeviceNotFoundOffersToPairThisMacAgain() {
        XCTAssertEqual(deviceGoneCode, "http_400_device_not_paired")
        XCTAssertEqual(
            decide(pairedDeviceId: device, status: failure(deviceGoneCode, deviceId: device)),
            .deviceRemoved
        )
    }

    /// A helper started before this build writes no `deviceId`, and cannot say
    /// which pairing failed. It is believed; the app clears it when it pairs.
    func testAStatusFromAHelperWithoutDeviceIdIsBelieved() {
        XCTAssertEqual(
            decide(pairedDeviceId: device, status: failure(deviceGoneCode, deviceId: nil)),
            .deviceRemoved
        )
    }

    /// The helper can read the old credentials just before the app re-pairs and
    /// write their failure just after. That failure is about the old device.
    func testAFailureOfTheDeviceThisMacHasSinceReplacedIsStale() {
        XCTAssertEqual(
            decide(pairedDeviceId: device, status: failure(deviceGoneCode, deviceId: replacedDevice)),
            .notNeeded
        )
    }

    /// What pairing clears: the helper's next good sync, or no status at all.
    func testASuccessfulSyncOrNoStatusNeedsNothing() {
        let synced = HelperIPC.Status(
            state: .running, lastSync: Date(), helperVersion: "1.0.0", deviceId: device
        )
        XCTAssertEqual(decide(pairedDeviceId: device, status: synced), .notNeeded)
        XCTAssertEqual(decide(pairedDeviceId: device, status: nil), .notNeeded)
        XCTAssertEqual(
            decide(pairedDeviceId: device, status: HelperIPC.Status(state: .idle, helperVersion: "1.0.0")),
            .notNeeded
        )
    }

    /// Any other failure clears itself on the next good sync. Offering to pair
    /// again for one would add a device row the account never needed.
    func testTransientAndOtherFailuresDoNotOfferPairing() {
        let codes: [String?] = [
            "network",
            "http_503_unavailable",
            "http_500_timeout",
            "http_400_failed",
            "http_429_rate_limited",
            "http_401_session_expired",
            "not_configured",
            "parse_failed",
            "unknown",
            "http_400_not_a_reason",
            "device_not_paired",
            nil,
        ]
        for code in codes {
            XCTAssertEqual(
                decide(pairedDeviceId: device, status: failure(code, deviceId: device)),
                .notNeeded,
                "code \(code ?? "nil")"
            )
        }
    }

    /// A helper from before `errorCode` stored display text, the PostgREST body
    /// included. It is not parsed: such a helper shows no repair until it runs
    /// this build, rather than having English text decide anything.
    func testTheTextOfAHelperFromBeforeErrorCodeIsNotParsed() {
        let legacy = failure(nil, deviceId: nil, text: "HTTP 400 from helper_sync: \(deviceGoneBody)")
        XCTAssertEqual(decide(pairedDeviceId: device, status: legacy), .notNeeded)
    }

    /// The helper writes the token only with `.error`. A status claiming to be
    /// running is not a failure, whatever else it carries.
    func testTheTokenCountsOnlyOnAnErrorStatus() {
        let odd = HelperIPC.Status(
            state: .running, lastSync: nil, error: nil,
            errorCode: deviceGoneCode, helperVersion: "1.0.0", deviceId: device
        )
        XCTAssertEqual(decide(pairedDeviceId: device, status: odd), .notNeeded)
    }

    // MARK: - This Mac was never paired to this account

    /// A second Mac on an account another device paired, a Mac whose helper is
    /// paired to another account, or one whose secret is gone: no credentials
    /// for this account, whatever the helper last wrote.
    func testAPairedAccountWithoutCredentialsOnThisMacOffersPairing() {
        XCTAssertEqual(decide(pairedDeviceId: nil, status: nil), .notSetUp)
        XCTAssertEqual(decide(pairedDeviceId: "", status: nil), .notSetUp)
        let localOnly = HelperIPC.Status(state: .running, lastSync: Date(), helperVersion: "1.0.0")
        XCTAssertEqual(decide(pairedDeviceId: nil, status: localOnly), .notSetUp)
        XCTAssertEqual(
            decide(pairedDeviceId: nil, status: failure(deviceGoneCode, deviceId: replacedDevice)),
            .notSetUp
        )
    }

    // MARK: - Where Settings has nothing to add

    func testSignedOutOrLocalModeNeedsNothing() {
        XCTAssertEqual(
            decide(isAuthenticated: false, isPaired: false, pairedDeviceId: nil, status: failure(deviceGoneCode, deviceId: nil)),
            .notNeeded
        )
        XCTAssertEqual(
            decide(isAuthenticated: false, isPaired: true, pairedDeviceId: device, status: failure(deviceGoneCode, deviceId: device)),
            .notNeeded
        )
    }

    /// An unpaired account already sees the pairing flow; this adds nothing.
    func testAnUnpairedAccountIsLeftToThePairingFlowItAlreadyHas() {
        XCTAssertEqual(decide(isPaired: false, pairedDeviceId: nil, status: nil), .notNeeded)
        XCTAssertEqual(
            decide(isPaired: false, pairedDeviceId: device, status: failure(deviceGoneCode, deviceId: device)),
            .notNeeded
        )
    }

    /// The QA runtime and Demo mode cannot pair (the button returns early), so
    /// they must not ask to.
    func testARuntimeThatCannotPairNeverAsks() {
        XCTAssertEqual(decide(canPairThisMac: false, pairedDeviceId: nil, status: nil), .notNeeded)
        XCTAssertEqual(
            decide(canPairThisMac: false, pairedDeviceId: device, status: failure(deviceGoneCode, deviceId: device)),
            .notNeeded
        )
    }

    // MARK: - The status the helper writes

    /// A status written before `deviceId` existed must still decode, and the
    /// field must round-trip, or the stale-failure check would never engage.
    func testTheStatusDeviceIdIsOptionalOnTheWire() throws {
        let legacy = Data(#"{"state":"error","error":"helper_sync HTTP 400","errorCode":"http_400_device_not_paired","helperVersion":"1.0.0"}"#.utf8)
        let decoded = try JSONDecoder().decode(HelperIPC.Status.self, from: legacy)
        XCTAssertNil(decoded.deviceId)
        XCTAssertEqual(decoded.errorCode, "http_400_device_not_paired")

        let written = failure(deviceGoneCode, deviceId: device)
        let roundTripped = try JSONDecoder().decode(
            HelperIPC.Status.self, from: JSONEncoder().encode(written)
        )
        XCTAssertEqual(roundTripped.deviceId, device)
        XCTAssertEqual(roundTripped.errorCode, deviceGoneCode)
    }
}

/// The copy, read in zh-Hans: under English a missing key falls back to text
/// that still looks right.
final class ThisMacPairingCopyTests: XCTestCase {
    private var previousOverride: String?

    override func setUp() {
        super.setUp()
        previousOverride = LocaleOverrideStore.shared.override
        LocaleOverrideStore.shared.set("zh-Hans")
    }

    override func tearDown() {
        LocaleOverrideStore.shared.set(previousOverride)
        super.tearDown()
    }

    func testTheStateLinesAreTranslated() {
        XCTAssertEqual(L10n.pairing.thisMacRemoved, "这台 Mac 已不再与你的账户配对")
        XCTAssertEqual(L10n.pairing.thisMacRemovedHint, "它已停止同步。重新设置云同步即可恢复。")
        XCTAssertEqual(L10n.pairing.thisMacNotSetUp, "这台 Mac 尚未与你的账户配对")
        XCTAssertEqual(
            L10n.pairing.thisMacNotSetUpHint,
            "你的账户已在另一台设备上配对。设置云同步即可添加这台 Mac，让它的会话和告警也显示在你的其他设备上。"
        )
        // The hints name the button by the wording the rest of the app uses.
        XCTAssertEqual(L10n.onboarding.setUpSync, "设置云同步")
        XCTAssertTrue(L10n.pairing.thisMacRemovedHint.contains(L10n.onboarding.setUpSync))
        XCTAssertTrue(L10n.pairing.thisMacNotSetUpHint.contains(L10n.onboarding.setUpSync))
    }
}

/// The state lives on `AuthState` and is kept by `AppState`.
@MainActor
final class ThisMacPairingAppStateTests: XCTestCase {

    /// The test process is not the production app, so it cannot pair a Mac —
    /// like the QA runtime. Signed in to a paired account, it must still not ask.
    func testARuntimeThatCannotPairLeavesTheStateAlone() {
        let state = AppState()
        XCTAssertFalse(state.runtimeEnvironment.capabilities.allowsHelperRegistration)
        state.isAuthenticated = true
        state.isPaired = true
        state.refreshThisMacPairing()
        XCTAssertEqual(state.authState.thisMacPairing, .notNeeded)
    }

    /// Demo mode — how the App Store screenshots are taken — cannot pair, even
    /// in the production runtime that can. It must not ask, and must not read
    /// the Keychain or the helper's status to decide that.
    func testDemoModeNeverAsksEvenWhereTheRuntimeCouldPair() {
        let suiteName = "ThisMacPairingAppStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = AppState(
            runtimeEnvironment: TestRuntimeFixtures.productionApp,
            defaults: defaults,
            performLaunchSetup: false
        )
        XCTAssertTrue(state.runtimeEnvironment.capabilities.allowsHelperRegistration)
        state.isDemoMode = true
        state.isAuthenticated = true
        state.isPaired = true
        state.authState.thisMacPairing = .notSetUp
        state.refreshThisMacPairing()
        XCTAssertEqual(state.authState.thisMacPairing, .notNeeded)
    }

    /// A different account signing in next must not inherit this Mac's repair.
    func testSigningOutForgetsTheState() {
        let state = AppState()
        state.authState.thisMacPairing = .deviceRemoved
        state.applySignedOutState()
        XCTAssertEqual(state.authState.thisMacPairing, .notNeeded)
    }
}
