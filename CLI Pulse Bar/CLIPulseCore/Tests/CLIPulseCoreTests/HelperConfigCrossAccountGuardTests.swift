import XCTest
@testable import CLIPulseCore

#if os(macOS)

/// Pins the cross-account guard added to `HelperConfig.loadIfMatches(...)`
/// on 2026-05-08. Background:
///
/// Production bug: macOS user signed into Supabase account A, paired
/// helper → app-group `helper_config` saved with (deviceId_A, userId_A).
/// Later signed into account B. App-group still held A's config. App
/// path called `HelperConfig.load()?.deviceId` and sent that stale
/// device id as `p_device_id` on every `upsert_daily_usage` RPC. Server
/// checked `devices.user_id == auth.uid()` for that device — userId_A
/// vs userId_B → mismatch → errcode 42501 → HTTP 403. Mac sync_daily
/// usage bounced silently every refresh. iPhone read stale cloud data
/// forever.
///
/// `loadIfMatches(authenticatedUserId:)` is the guarded loader that
/// callers must use whenever they need `p_device_id`. It returns nil
/// on mismatch (caller falls through to the no-device-id path; server
/// uses the sentinel UUID and skips the ownership check).
final class HelperConfigCrossAccountGuardTests: XCTestCase {

    private var productionRuntime: CLIPulseRuntimeEnvironment {
        CLIPulseRuntimeEnvironment.resolveForTesting(
            infoDictionary: [
                "CFBundleIdentifier": "yyh.CLI-Pulse",
            ],
            environment: [:]
        )
    }

    private func makePersistence(
        deviceId: String? = nil,
        userId: String? = nil,
        secret: String? = "test-secret-xyz"
    ) -> HelperConfig.PersistenceAccess {
        struct Stored: Codable {
            let deviceId: String
            let userId: String
            let deviceName: String
            let helperVersion: String
        }
        let data: Data?
        if let deviceId, let userId {
            data = try! JSONEncoder().encode(
                Stored(
                    deviceId: deviceId,
                    userId: userId,
                    deviceName: "test-device",
                    helperVersion: "test-1.0"
                )
            )
        } else {
            data = nil
        }
        return HelperConfig.PersistenceAccess(
            loadStoredData: { data },
            saveStoredData: { _ in },
            removeStoredData: {},
            loadSecret: { secret },
            saveSecret: { _ in },
            removeSecret: {},
            loadLegacyFileData: { nil }
        )
    }

    func testLoadIfMatches_returnsNil_whenStoredUserIdDiffersFromAuth() {
        let persistence = makePersistence(
            deviceId: "device-A",
            userId: "00000000-0000-0000-0000-aaaaaaaaaaaa"
        )
        let cfg = HelperConfig.loadIfMatches(
            authenticatedUserId: "00000000-0000-0000-0000-bbbbbbbbbbbb",
            runtimeEnvironment: productionRuntime,
            persistence: persistence
        )
        XCTAssertNil(cfg, "cross-account stale config must NOT surface — returning it would route the prior account's device_id to the new account's upsert_daily_usage RPC and trigger 42501/403")
    }

    func testLoadIfMatches_returnsConfig_whenStoredUserIdMatchesAuth() {
        let userId = "00000000-0000-0000-0000-cccccccccccc"
        let persistence = makePersistence(
            deviceId: "device-A",
            userId: userId
        )
        let cfg = HelperConfig.loadIfMatches(
            authenticatedUserId: userId,
            runtimeEnvironment: productionRuntime,
            persistence: persistence
        )
        XCTAssertNotNil(cfg, "match must return config so the upload path can pass p_device_id")
        XCTAssertEqual(cfg?.deviceId, "device-A")
        XCTAssertEqual(cfg?.userId, userId)
    }

    func testLoadIfMatches_returnsNil_whenAuthIdIsNil() {
        let persistence = makePersistence(
            deviceId: "device-A",
            userId: "00000000-0000-0000-0000-dddddddddddd"
        )
        let cfg = HelperConfig.loadIfMatches(
            authenticatedUserId: nil,
            runtimeEnvironment: productionRuntime,
            persistence: persistence
        )
        XCTAssertNil(cfg, "no auth = no p_device_id; sentinel UUID path is the safe default")
    }

    func testLoadIfMatches_returnsNil_whenAuthIdIsEmpty() {
        let persistence = makePersistence(
            deviceId: "device-A",
            userId: "00000000-0000-0000-0000-eeeeeeeeeeee"
        )
        let cfg = HelperConfig.loadIfMatches(
            authenticatedUserId: "",
            runtimeEnvironment: productionRuntime,
            persistence: persistence
        )
        XCTAssertNil(cfg)
    }

    func testLoadIfMatches_returnsNil_whenNothingStored() {
        let cfg = HelperConfig.loadIfMatches(
            authenticatedUserId: "00000000-0000-0000-0000-ffffffffffff",
            runtimeEnvironment: productionRuntime,
            persistence: makePersistence()
        )
        XCTAssertNil(cfg)
    }
}

#endif
