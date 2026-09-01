#if os(macOS)
import Security
import XCTest
@testable import CLIPulseCore

final class KeychainBackgroundAccessTests: XCTestCase {
    override func setUp() {
        super.setUp()
        LegacyKeychainUIGate.disableProcessWideUI()
    }

    override func tearDown() {
        LegacyKeychainUIGate.disableProcessWideUI()
        super.tearDown()
    }

    func testAppOwnedKeychainReadsFailInsteadOfShowingAuthenticationUI() {
        let query = KeychainHelper.loadQuery(key: "test-key")
        let policy = query[kSecUseAuthenticationUI as String] as? String
        XCTAssertEqual(policy, kSecUseAuthenticationUIFail as String)
    }

    func testNestedGateRestoresEachEnteringState() {
        XCTAssertFalse(LegacyKeychainUIGate.isProcessWideUIAllowed())

        LegacyKeychainUIGate.withUserInteractionAllowed {
            XCTAssertTrue(LegacyKeychainUIGate.isProcessWideUIAllowed())
            LegacyKeychainUIGate.withInteractionDisabled {
                XCTAssertFalse(LegacyKeychainUIGate.isProcessWideUIAllowed())
            }
            XCTAssertTrue(LegacyKeychainUIGate.isProcessWideUIAllowed())
        }

        XCTAssertFalse(LegacyKeychainUIGate.isProcessWideUIAllowed())
    }

    func testThrowingBodyRestoresDisabledState() {
        enum Expected: Error { case stop }

        XCTAssertThrowsError(
            try LegacyKeychainUIGate.withUserInteractionAllowed {
                XCTAssertTrue(LegacyKeychainUIGate.isProcessWideUIAllowed())
                throw Expected.stop
            }
        )
        XCTAssertFalse(LegacyKeychainUIGate.isProcessWideUIAllowed())
    }

    func testConcurrentBackgroundGateWaitsForExplicitReadAndEndsDisabled() {
        let explicitEntered = expectation(description: "explicit entered")
        let explicitMayExit = DispatchSemaphore(value: 0)
        let backgroundDidEnter = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(
            label: "test.keychain-gate",
            attributes: .concurrent
        )

        queue.async {
            LegacyKeychainUIGate.withUserInteractionAllowed {
                XCTAssertTrue(LegacyKeychainUIGate.isProcessWideUIAllowed())
                explicitEntered.fulfill()
                explicitMayExit.wait()
            }
        }
        wait(for: [explicitEntered], timeout: 1)

        queue.async {
            LegacyKeychainUIGate.withInteractionDisabled {
                XCTAssertFalse(LegacyKeychainUIGate.isProcessWideUIAllowed())
                backgroundDidEnter.signal()
            }
        }

        XCTAssertEqual(
            backgroundDidEnter.wait(timeout: .now() + 0.1),
            .timedOut,
            "background work must not change process UI state mid-read"
        )
        explicitMayExit.signal()
        XCTAssertEqual(
            backgroundDidEnter.wait(timeout: .now() + 1),
            .success
        )
        XCTAssertFalse(LegacyKeychainUIGate.isProcessWideUIAllowed())
    }
}
#endif
