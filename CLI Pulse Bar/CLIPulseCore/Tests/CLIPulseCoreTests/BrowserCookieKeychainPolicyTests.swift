#if os(macOS)
import Foundation
import Security
import XCTest
@testable import CLIPulseCore

final class BrowserCookieKeychainPolicyTests: XCTestCase {
    func testBackgroundSafeStorageLookupNeverRequestsInteractiveKeychainUI() {
        ChromeCookieImporter.resetSafeStorageKeyCacheForTesting()
        let recorder = KeychainInteractionRecorder()

        XCTAssertThrowsError(
            try ChromeCookieImporter.chromeSafeStorageKey(
                for: .edge,
                passwordLookup: { _, _, allowInteraction in
                    recorder.append(allowInteraction)
                    if allowInteraction {
                        return (errSecSuccess, "test-safe-storage-password")
                    }
                    return (errSecInteractionNotAllowed, nil)
                }
            )
        )
        XCTAssertFalse(
            recorder.values.contains(true),
            "background browser collection must never request interactive Keychain UI"
        )
    }

    func testUserInitiatedSafeStorageLookupMayRequestInteractiveKeychainUI() throws {
        ChromeCookieImporter.resetSafeStorageKeyCacheForTesting()
        let recorder = KeychainInteractionRecorder()

        let key = try BrowserCookieKeychainAccessGate
            .$interactionPermit.withValue(
                BrowserCredentialInteractionPermit()
            ) {
                try ChromeCookieImporter.chromeSafeStorageKey(
                    for: .chrome,
                    passwordLookup: { _, _, allowInteraction in
                        recorder.append(allowInteraction)
                        if allowInteraction {
                            return (errSecSuccess, "test-safe-storage-password")
                        }
                        return (errSecInteractionNotAllowed, nil)
                    }
                )
            }

        XCTAssertFalse(key.isEmpty)
        XCTAssertTrue(recorder.values.contains(true))
        XCTAssertEqual(recorder.values.filter { $0 }.count, 1)
        XCTAssertFalse(BrowserCookieKeychainAccessGate.allowsInteraction)
    }

    func testOneForegroundActionAllowsAtMostOneInteractiveLookup() throws {
        ChromeCookieImporter.resetSafeStorageKeyCacheForTesting()
        let recorder = KeychainInteractionRecorder()

        XCTAssertThrowsError(
            try BrowserCookieKeychainAccessGate.$interactionPermit.withValue(
                BrowserCredentialInteractionPermit()
            ) {
                try ChromeCookieImporter.chromeSafeStorageKey(
                    for: .edge,
                    passwordLookup: { _, _, allowInteraction in
                        recorder.append(allowInteraction)
                        return allowInteraction
                            ? (errSecItemNotFound, nil)
                            : (errSecInteractionNotAllowed, nil)
                    }
                )
            }
        )

        XCTAssertEqual(
            recorder.values.filter { $0 }.count,
            1,
            "one Test Connection action must not fan out into password prompts"
        )
    }
}

private final class KeychainInteractionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Bool] = []

    var values: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: Bool) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}
#endif
