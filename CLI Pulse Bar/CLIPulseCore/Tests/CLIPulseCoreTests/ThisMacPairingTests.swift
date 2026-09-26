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

    /// What a helper from before `errorCode` stored for an HTTP failure:
    /// `error.localizedDescription`, i.e. `pairing.error_http_status` ("HTTP %1$d
    /// from %2$@: %3$@") with the body cut at 200 characters. That is every
    /// helper released so far, and it keeps running after the app updates.
    private func legacyText(_ status: Int, _ function: String, _ body: String) -> String {
        "HTTP \(status) from \(function): \(body.prefix(200))"
    }

    /// The Macs broken today run such a helper. Its text carries the server's
    /// body, which decides it by the rule the token comes from.
    func testTheTextOfAHelperFromBeforeErrorCodeOffersTheRepair() {
        for function in ["helper_heartbeat", "helper_sync"] {
            let legacy = failure(nil, deviceId: nil, text: legacyText(400, function, deviceGoneBody))
            XCTAssertEqual(decide(pairedDeviceId: device, status: legacy), .deviceRemoved, function)
        }
        // Nor does the wrapper's wording (its old ja format, say).
        let ja = failure(nil, deviceId: nil, text: "helper_sync が HTTP 400 を返しました: \(deviceGoneBody)")
        XCTAssertEqual(decide(pairedDeviceId: device, status: ja), .deviceRemoved)
    }

    /// Only that exact failure. Another P0001, another code with the same
    /// words, a network error, a truncated body or loose words in the text do
    /// not count, and neither does it on a status that is not an error.
    func testNoOtherTextOfAnOldHelperOffersTheRepair() {
        let texts = [
            legacyText(400, "helper_sync", #"{"code":"P0001","details":null,"hint":null,"message":"Too many sessions (max 500)"}"#),
            legacyText(400, "helper_sync", #"{"code":"P0002","message":"Device not found or unauthorized"}"#),
            legacyText(503, "helper_sync", "<html>Device not found or unauthorized P0001</html>"),
            legacyText(400, "helper_sync", String(deviceGoneBody.prefix(60))),
            "The Internet connection appears to be offline.",
            "P0001 Device not found or unauthorized",
            "",
        ]
        for text in texts {
            XCTAssertEqual(
                decide(pairedDeviceId: device, status: failure(nil, deviceId: nil, text: text)),
                .notNeeded,
                text
            )
        }
        let notAnError = HelperIPC.Status(
            state: .running, lastSync: nil, error: legacyText(400, "helper_sync", deviceGoneBody),
            errorCode: nil, helperVersion: "1.0.0"
        )
        XCTAssertEqual(decide(pairedDeviceId: device, status: notAnError), .notNeeded)
    }

    /// When there is a token, the token decides; the text beside it is only
    /// English detail for diagnosis.
    func testATokenOutranksTheTextBesideIt() {
        let status = failure("network", deviceId: device, text: legacyText(400, "helper_sync", deviceGoneBody))
        XCTAssertEqual(decide(pairedDeviceId: device, status: status), .notNeeded)
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

    /// A second Mac on an account another device paired, or a Mac whose helper
    /// is paired to another account: no pairing record for this account,
    /// whatever the helper last wrote.
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
    /// like the QA runtime. Signed in to a paired account, it must still not
    /// ask, and a refresh clears whatever was there.
    func testARuntimeThatCannotPairClearsTheState() {
        let state = AppState()
        XCTAssertFalse(state.runtimeEnvironment.capabilities.allowsHelperRegistration)
        state.isAuthenticated = true
        state.isPaired = true
        state.authState.thisMacPairing = .deviceRemoved
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

/// The views read these two instead of each spelling the rule out; the app
/// target has no unit tests, so this is where the rule is pinned.
@MainActor
final class ThisMacPairingViewPredicateTests: XCTestCase {

    func testTheTruthTable() {
        let rows: [(isPaired: Bool, state: ThisMacPairing.State, showsFlow: Bool, syncing: Bool)] = [
            (false, .notNeeded, true, false),
            (true, .notNeeded, false, true),
            (true, .notSetUp, true, false),
            (true, .deviceRemoved, true, false),
        ]
        for row in rows {
            let auth = AuthState()
            auth.isPaired = row.isPaired
            auth.thisMacPairing = row.state
            XCTAssertEqual(auth.showsPairingFlow, row.showsFlow, "\(row)")
            XCTAssertEqual(auth.isThisMacSyncing, row.syncing, "\(row)")
        }
    }
}

/// Settings › Advanced › Background Sync, read in zh-Hans (a broken lookup
/// would still produce English and pass under en).
final class HelperStatusLineTests: XCTestCase {
    private var previousOverride: String?
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let device = "8f0c3a52-1111-4c1e-9d7e-3b1f5d0a2c44"
    private let deviceGoneBody = #"{"code":"P0001","details":null,"hint":null,"message":"Device not found or unauthorized"}"#

    override func setUp() {
        super.setUp()
        previousOverride = LocaleOverrideStore.shared.override
        LocaleOverrideStore.shared.set("zh-Hans")
    }

    override func tearDown() {
        LocaleOverrideStore.shared.set(previousOverride)
        super.tearDown()
    }

    /// With no pairing the helper still wrote "running, synced now" (and one
    /// paired to another account syncs that one). On a Mac not set up for this
    /// account that read "Synced just now" in green under "This Mac isn't
    /// paired with your account yet".
    func testAMacNotSetUpForThisAccountIsNeverShownAsSynced() {
        let claims = [
            HelperIPC.Status(state: .running, lastSync: now, helperVersion: "1.0.0"),
            HelperIPC.Status(state: .running, lastSync: now.addingTimeInterval(-300), helperVersion: "1.0.0", deviceId: "other-account-device"),
            HelperIPC.Status(state: .running, lastSync: nil, helperVersion: "1.0.0"),
        ]
        for status in claims {
            let line = HelperStatusLine.make(status: status, thisMacPairing: .notSetUp, now: now)
            XCTAssertEqual(line, HelperStatusLine(tone: .attention, text: "未同步", isError: false))
            XCTAssertEqual(line.text, L10n.settings.notPaired)
        }
    }

    func testAPairedMacShowsWhatTheHelperDid() {
        XCTAssertEqual(
            HelperStatusLine.make(
                status: HelperIPC.Status(state: .running, lastSync: now.addingTimeInterval(-10), helperVersion: "1.0.0", deviceId: device),
                thisMacPairing: .notNeeded, now: now
            ),
            HelperStatusLine(tone: .good, text: "刚刚同步", isError: false)
        )
        XCTAssertEqual(
            HelperStatusLine.make(
                status: HelperIPC.Status(state: .running, lastSync: now.addingTimeInterval(-180), helperVersion: "1.0.0", deviceId: device),
                thisMacPairing: .notNeeded, now: now
            ),
            HelperStatusLine(tone: .good, text: "3 分钟前同步", isError: false)
        )
        // What a helper with no pairing writes now: running, no sync.
        XCTAssertEqual(
            HelperStatusLine.make(
                status: HelperIPC.Status(state: .running, lastSync: nil, helperVersion: "1.0.0"),
                thisMacPairing: .notNeeded, now: now
            ),
            HelperStatusLine(tone: .good, text: "运行中", isError: false)
        )
        XCTAssertEqual(
            HelperStatusLine.make(
                status: HelperIPC.Status(state: .idle, helperVersion: "1.0.0"),
                thisMacPairing: .notNeeded, now: now
            ),
            HelperStatusLine(tone: .inactive, text: "未运行", isError: false)
        )
    }

    /// The removed Mac's failure reads as the line above it does, from a
    /// current helper's token and from an old helper's text alike.
    func testTheDeviceGoneFailureIsShownInTheUsersLanguage() {
        let expected = HelperStatusLine(
            tone: .failure,
            text: "这台 Mac 已不再与你的账户配对。如需恢复同步，请在「设置」中重新设置云同步。",
            isError: true
        )
        let current = HelperIPC.Status(
            state: .error, lastSync: nil, error: "helper_sync HTTP 400",
            errorCode: "http_400_device_not_paired", helperVersion: "1.0.0", deviceId: device
        )
        XCTAssertEqual(HelperStatusLine.make(status: current, thisMacPairing: .deviceRemoved, now: now), expected)
        let legacy = HelperIPC.Status(
            state: .error, lastSync: nil, error: "HTTP 400 from helper_sync: \(deviceGoneBody)",
            errorCode: nil, helperVersion: "1.0.0"
        )
        XCTAssertEqual(HelperStatusLine.make(status: legacy, thisMacPairing: .deviceRemoved, now: now), expected)
    }
}

#if os(macOS)
/// `ThisMacPairing` decides from the app-group record alone. A Keychain read
/// fails while the login keychain is locked just as it does when the secret is
/// gone, and reading that as "not paired" would offer to pair again and add a
/// second device row for this Mac.
final class HelperConfigPairedDeviceIdTests: XCTestCase {
    private let user = "00000000-0000-0000-0000-aaaaaaaaaaaa"
    private let otherUser = "00000000-0000-0000-0000-bbbbbbbbbbbb"

    private var productionRuntime: CLIPulseRuntimeEnvironment {
        CLIPulseRuntimeEnvironment.resolveForTesting(
            infoDictionary: ["CFBundleIdentifier": "yyh.CLI-Pulse"],
            environment: [:]
        )
    }

    private func persistence(userId: String?, deviceId: String = "device-A") -> HelperConfig.PersistenceAccess {
        struct Stored: Codable {
            let deviceId: String
            let userId: String
            let deviceName: String
            let helperVersion: String
        }
        let data = userId.map {
            try! JSONEncoder().encode(
                Stored(deviceId: deviceId, userId: $0, deviceName: "Mac", helperVersion: "1.0.0")
            )
        }
        return HelperConfig.PersistenceAccess(
            loadStoredData: { data },
            saveStoredData: { _ in XCTFail("must not write") },
            removeStoredData: { XCTFail("must not remove") },
            loadSecret: {
                XCTFail("must not read the Keychain")
                return nil
            },
            saveSecret: { _ in XCTFail("must not write the Keychain") },
            removeSecret: { XCTFail("must not touch the Keychain") },
            loadLegacyFileData: {
                XCTFail("must not read the legacy file")
                return nil
            }
        )
    }

    private func deviceId(_ auth: String?, _ persistence: HelperConfig.PersistenceAccess) -> String? {
        HelperConfig.pairedDeviceId(
            authenticatedUserId: auth,
            runtimeEnvironment: productionRuntime,
            persistence: persistence
        )
    }

    /// The record is enough: the secret is never read, so a locked keychain
    /// cannot make a paired Mac look unpaired.
    func testARecordForTheSignedInAccountIsThePairing() {
        XCTAssertEqual(deviceId(user, persistence(userId: user)), "device-A")
    }

    func testNoRecordOrAnotherAccountsRecordIsNoPairing() {
        XCTAssertNil(deviceId(user, persistence(userId: nil)))
        XCTAssertNil(deviceId(user, persistence(userId: otherUser)))
        XCTAssertNil(deviceId(user, persistence(userId: user, deviceId: "")))
    }

    func testNoSignedInAccountIsNoPairing() {
        XCTAssertNil(deviceId(nil, persistence(userId: user)))
        XCTAssertNil(deviceId("", persistence(userId: user)))
    }
}
#endif
