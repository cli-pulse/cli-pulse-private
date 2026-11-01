// 1.61 (B5): with "Hide personal information" on, this Mac's own session rows
// are numbered like every other device, not "Hidden device".
//
// A Mac names its own rows (the process scan's and the session logs') by its
// host name, and the account's device list knows it by another name. Its host
// name now takes this Mac's number, found by its id.
//
// Asserted in Simplified Chinese, like `PersonalInfoMaskDevicesTests`.

import Foundation
import XCTest
@testable import CLIPulseCore

final class PersonalInfoMaskThisMacTests: XCTestCase {

    private var saved: String?
    override func setUp() {
        super.setUp()
        saved = LocaleOverrideStore.shared.override
        LocaleOverrideStore.shared.set("zh-Hans")
    }
    override func tearDown() {
        LocaleOverrideStore.shared.set(saved)
        super.tearDown()
    }

    private static let host = "studio-mac.local"
    /// The account's devices; this Mac is "a-1", called "Studio Mac" there.
    private static let devices: [(id: String, name: String)] = [
        (id: "c-3", name: "Phone"),
        (id: "a-1", name: "Studio Mac"),
        (id: "b-2", name: "lab-server-01"),
    ]

    private static func shown(_ name: String, _ numbers: DeviceNameNumbers, hide: Bool = true) -> String? {
        PersonalInfoMask.deviceName(name, numbers: numbers, hidePersonalInfo: hide)
    }

    // MARK: - The numbers

    func testThisMacsHostNameTakesThisMacsNumber() {
        let numbers = DeviceNameNumbers.devices(Self.devices, thisDevice: .init(name: Self.host, id: "a-1"))
        XCTAssertEqual(Self.shown(Self.host, numbers), "设备 1", "this Mac's own rows")
        XCTAssertEqual(Self.shown("Studio Mac", numbers), "设备 1", "its rows the cloud sent, by its listed name")
        XCTAssertEqual(numbers.number(forID: "a-1"), 1, "the number its card and managed rows find by id")
        XCTAssertEqual(Self.shown("lab-server-01", numbers), "设备 2", "the others are as before")
        XCTAssertEqual(Self.shown("Phone", numbers), "设备 3")
        XCTAssertEqual(Self.shown(" \(Self.host) ", numbers), "设备 1", "compared trimmed")
    }

    /// Before 1.61 the host name had no number.
    func testWithoutThisMacTheHostNameIsHidden() {
        XCTAssertEqual(Self.shown(Self.host, .devices(Self.devices)), "隐藏的设备")
    }

    /// Not paired to the account, or removed from it: after the list.
    func testAMacTheListDoesNotHaveIsNumberedAfterIt() {
        for id in [nil, "z-9"] as [String?] {
            let numbers = DeviceNameNumbers.devices(Self.devices, thisDevice: .init(name: Self.host, id: id))
            XCTAssertEqual(Self.shown(Self.host, numbers), "设备 4", "id \(id ?? "nil")")
            XCTAssertNil(numbers.number(forID: "z-9"))
        }
    }

    /// The local route's list is this Mac's own row, id "local", named by its
    /// host name: that is the number, and nothing comes after it.
    func testTheLocalRoutesOwnRowKeepsItsNumber() {
        let numbers = DeviceNameNumbers.devices(
            [(id: "local", name: Self.host)], thisDevice: .init(name: Self.host, id: "local"))
        XCTAssertEqual(Self.shown(Self.host, numbers), "设备 1")
    }

    /// A host name the list gives to another device says nothing about which
    /// one is meant; nor does one two listed devices share.
    func testAHostNameAnotherDeviceHasIsHidden() {
        let clash = DeviceNameNumbers.devices(
            Self.devices, thisDevice: .init(name: "lab-server-01", id: "a-1"))
        XCTAssertEqual(Self.shown("lab-server-01", clash), "隐藏的设备")
        XCTAssertEqual(Self.shown("Studio Mac", clash), "设备 1", "this Mac's listed name is unaffected")

        // Not paired: the same rule, not the other device's number.
        let unpaired = DeviceNameNumbers.devices(
            Self.devices, thisDevice: .init(name: "lab-server-01", id: nil))
        XCTAssertEqual(Self.shown("lab-server-01", unpaired), "隐藏的设备")

        let shared = DeviceNameNumbers.devices(
            Self.devices + [(id: "d-4", name: Self.host), (id: "e-5", name: Self.host)],
            thisDevice: .init(name: Self.host, id: "a-1"))
        XCTAssertEqual(Self.shown(Self.host, shared), "隐藏的设备")
    }

    /// The listed name and the host name being the same is the plain case.
    func testAHostNameEqualToItsListedName() {
        let numbers = DeviceNameNumbers.devices(Self.devices, thisDevice: .init(name: "Studio Mac", id: "a-1"))
        XCTAssertEqual(Self.shown("Studio Mac", numbers), "设备 1")
    }

    func testWithTheSwitchOffTheHostNameShows() {
        let numbers = DeviceNameNumbers.devices(Self.devices, thisDevice: .init(name: Self.host, id: "a-1"))
        XCTAssertEqual(Self.shown(Self.host, numbers, hide: false), Self.host)
    }

    // MARK: - The app

    #if os(macOS)
    /// `AppState.deviceNameNumbers`, which every Mac screen reads, numbers
    /// this Mac's host name by the id `refreshThisMacPairing` found.
    @MainActor
    func testTheAppNumbersThisMacByThePairingItRead() {
        let user = "00000000-0000-0000-0000-aaaaaaaaaaaa"
        let suiteName = "PersonalInfoMaskThisMacTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = AppState(
            runtimeEnvironment: TestRuntimeFixtures.productionApp,
            defaults: defaults,
            performLaunchSetup: false
        )
        state.isAuthenticated = true
        state.isPaired = true
        state.userId = user
        state.devices = Self.devices.map(Self.record)

        state.refreshThisMacPairing(helperConfig: Self.pairing(device: "a-1", user: user), readHelperStatus: { nil })
        state.refreshThisMacDevice(hostName: Self.host)

        XCTAssertEqual(state.thisMacDevice, .init(name: Self.host, id: "a-1"))
        XCTAssertEqual(Self.shown(Self.host, state.deviceNameNumbers), "设备 1")

        // Demo shows no rows of this Mac's.
        state.isDemoMode = true
        state.refreshThisMacDevice(hostName: Self.host)
        XCTAssertNil(state.thisMacDevice)
        state.isDemoMode = false
    }

    /// Every refresh records the host name it named this Mac's rows by.
    @MainActor
    func testARefreshRecordsThisMacsHostName() async {
        SessionRestoreStub.reset()
        SessionRestoreStub.respond { _ in .fail(URLError(.notConnectedToInternet)) }
        defer { SessionRestoreStub.reset() }
        let api = APIClient(token: "access", supabaseURL: "https://stub.cli-pulse.test",
                            supabaseAnonKey: "anon", session: SessionRestoreStub.session())
        let state = AppState(
            runtimeEnvironment: RefreshAfterSessionRestoreTests.refreshOnlyRuntime,
            defaults: UploadOutcomeTests.freshDefaults(),
            api: api,
            performLaunchSetup: false)
        state.isAuthenticated = true
        state.isPaired = true
        XCTAssertNil(state.thisMacDevice)

        await state.refreshAll()

        let host = await HostIdentity.shared.hostName()
        XCTAssertTrue(state.thisMacDevice?.name == host, "the host name this Mac's rows carry")

        // Signed out, nothing is put back.
        state.thisMacDevice = nil
        state.isAuthenticated = false
        await state.refreshAll()
        XCTAssertNil(state.thisMacDevice)
    }

    /// On the local route (signed in without a paired account, or local
    /// mode) this Mac is the list's own row.
    @MainActor
    func testOnTheLocalRouteThisMacIsItsOwnRow() {
        let state = Self.isolatedState()
        state.isAuthenticated = true             // an account no device is paired to
        state.isPaired = false
        XCTAssertEqual(state.refreshRoute, .localOnly)
        state.refreshThisMacDevice(hostName: Self.host)
        XCTAssertEqual(state.thisMacDevice, .init(name: Self.host, id: "local"))
    }

    /// Entering Demo forgets this Mac: Demo's rows are Demo's.
    @MainActor
    func testEnteringDemoForgetsThisMac() {
        let state = Self.isolatedState()
        state.thisMacPairedDeviceId = "a-1"
        state.refreshThisMacDevice(hostName: Self.host)
        XCTAssertNotNil(state.thisMacDevice)
        state.enterDemoMode()
        XCTAssertNil(state.thisMacDevice)
    }

    /// A sign-out forgets which device this Mac was: the next account's
    /// devices are not this one's. (The testing runtime: a sign-out deletes
    /// tokens, and the production one's are this Mac's own.)
    @MainActor
    func testASignOutForgetsWhichDeviceThisMacWas() {
        let state = Self.isolatedState()
        state.thisMacPairedDeviceId = "a-1"
        state.refreshThisMacDevice(hostName: Self.host)
        XCTAssertEqual(state.thisMacDevice?.id, "a-1")

        state.applySignedOutState()
        XCTAssertNil(state.thisMacDevice)
        XCTAssertNil(state.thisMacPairedDeviceId)
    }

    /// The testing runtime, with its own defaults: Demo is persisted, and
    /// must not leak into the test process's standard defaults.
    @MainActor
    private static func isolatedState() -> AppState {
        AppState(
            runtimeEnvironment: .resolveForTesting(infoDictionary: [:], environment: [:]),
            defaults: UploadOutcomeTests.freshDefaults(),
            performLaunchSetup: false)
    }

    private static func record(_ device: (id: String, name: String)) -> DeviceRecord {
        DeviceRecord(
            id: device.id, name: device.name, type: "macOS", system: "macOS", status: "online",
            last_sync_at: nil, helper_version: "1.0.0", current_session_count: 0,
            cpu_usage: nil, memory_usage: nil)
    }

    /// This Mac's app-group pairing record, as `ThisMacPairingTests` builds
    /// it: no Keychain read.
    private static func pairing(device: String, user: String) -> HelperConfig.PersistenceAccess {
        struct Stored: Codable {
            let deviceId: String
            let userId: String
            let deviceName: String
            let helperVersion: String
        }
        let data = try! JSONEncoder().encode(
            Stored(deviceId: device, userId: user, deviceName: "Studio Mac", helperVersion: "1.0.0"))
        return HelperConfig.PersistenceAccess(
            loadStoredData: { data },
            saveStoredData: { _ in XCTFail("must not write") },
            removeStoredData: { XCTFail("must not remove") },
            loadSecret: { XCTFail("must not read the Keychain"); return nil },
            saveSecret: { _ in XCTFail("must not write the Keychain") },
            removeSecret: { XCTFail("must not touch the Keychain") },
            loadLegacyFileData: { XCTFail("must not read the legacy file"); return nil }
        )
    }
    #endif
}
