#if os(macOS)
import Security
import XCTest
@testable import CLIPulseCore

final class BrowserDurableDenyTests: XCTestCase {
    private final class LookupRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [(service: String, allowInteraction: Bool)] = []

        func record(service: String, allowInteraction: Bool) {
            lock.lock()
            storage.append((service, allowInteraction))
            lock.unlock()
        }

        var calls: [(service: String, allowInteraction: Bool)] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    override func setUp() {
        super.setUp()
        ChromeCookieImporter.resetSafeStorageKeyCacheForTesting()
        CredentialAccessDecisionStore.clearAllSafeStorageDenials()
    }

    override func tearDown() {
        ChromeCookieImporter.resetSafeStorageKeyCacheForTesting()
        CredentialAccessDecisionStore.clearAllSafeStorageDenials()
        super.tearDown()
    }

    func testUserCancelPersistsAndDowngradesTheNextAttempt() throws {
        let first = LookupRecorder()
        try BrowserCookieKeychainAccessGate.$interactionPermit.withValue(
            BrowserCredentialInteractionPermit()
        ) {
            XCTAssertThrowsError(
                try ChromeCookieImporter.chromeSafeStorageKey(
                    for: .chrome,
                    passwordLookup: { service, _, allowInteraction in
                        first.record(service: service, allowInteraction: allowInteraction)
                        return allowInteraction
                            ? (errSecUserCanceled, nil)
                            : (errSecInteractionNotAllowed, nil)
                    }
                )
            )
        }
        let deniedServices = Set(first.calls.filter(\.allowInteraction).map(\.service))
        XCTAssertFalse(deniedServices.isEmpty)

        let second = LookupRecorder()
        XCTAssertThrowsError(
            try ChromeCookieImporter.chromeSafeStorageKey(
                for: .chrome,
                passwordLookup: { service, _, allowInteraction in
                    second.record(service: service, allowInteraction: allowInteraction)
                    return allowInteraction
                        ? (errSecItemNotFound, nil)
                        : (errSecInteractionNotAllowed, nil)
                }
            )
        )
        for call in second.calls where deniedServices.contains(call.service) {
            XCTAssertFalse(call.allowInteraction)
        }
    }

    func testExplicitTryAgainRestoresInteractiveAttempt() throws {
        let unrelatedScope = CredentialAccessScope.safeStorageService(
            "Microsoft Edge Safe Storage"
        )
        CredentialAccessDecisionStore.recordDenial(scope: unrelatedScope)
        try BrowserCookieKeychainAccessGate.$interactionPermit.withValue(
            BrowserCredentialInteractionPermit()
        ) {
            XCTAssertThrowsError(
                try ChromeCookieImporter.chromeSafeStorageKey(
                    for: .chrome,
                    passwordLookup: { _, _, allowInteraction in
                        allowInteraction
                            ? (errSecUserCanceled, nil)
                            : (errSecInteractionNotAllowed, nil)
                    }
                )
            )
        }

        let retry = LookupRecorder()
        try BrowserCookieKeychainAccessGate.$interactionPermit.withValue(
            BrowserCredentialInteractionPermit()
        ) {
            XCTAssertThrowsError(
                try ChromeCookieImporter.chromeSafeStorageKey(
                    for: .chrome,
                    passwordLookup: { service, _, allowInteraction in
                        retry.record(service: service, allowInteraction: allowInteraction)
                        return allowInteraction
                            ? (errSecItemNotFound, nil)
                            : (errSecInteractionNotAllowed, nil)
                    }
                )
            )
        }
        XCTAssertTrue(retry.calls.contains { $0.allowInteraction })
        XCTAssertTrue(
            CredentialAccessDecisionStore.isDenied(scope: unrelatedScope),
            "retrying Chrome must not erase an unrelated browser decision"
        )
        for service in Set(
            retry.calls.filter(\.allowInteraction).map(\.service)
        ) {
            XCTAssertFalse(
                CredentialAccessDecisionStore.isDenied(
                    scope: .safeStorageService(service)
                )
            )
        }
    }

    func testItemNotFoundDoesNotBecomeADenial() throws {
        try BrowserCookieKeychainAccessGate.$interactionPermit.withValue(
            BrowserCredentialInteractionPermit()
        ) {
            XCTAssertThrowsError(
                try ChromeCookieImporter.chromeSafeStorageKey(
                    for: .chrome,
                    passwordLookup: { _, _, allowInteraction in
                        allowInteraction
                            ? (errSecItemNotFound, nil)
                            : (errSecInteractionNotAllowed, nil)
                    }
                )
            )
        }
        let prefix = CredentialAccessDecisionStore.defaultsKeyPrefix + "safe-storage."
        let recorded = UserDefaults.standard.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(prefix) }
        XCTAssertTrue(recorded.isEmpty)
    }

    func testDeniedServicesAreNotReadEvenWhenSilentlyAvailable()
        throws
    {
        for label in Browser.chrome.safeStorageLabels {
            CredentialAccessDecisionStore.recordDenial(
                scope: .safeStorageService(label.service)
            )
        }
        let lookup = LookupRecorder()

        XCTAssertThrowsError(
            try ChromeCookieImporter.chromeSafeStorageKey(
                for: .chrome,
                passwordLookup: { service, _, allowInteraction in
                    lookup.record(
                        service: service,
                        allowInteraction: allowInteraction
                    )
                    return (errSecSuccess, "silently-readable-password")
                }
            )
        )

        XCTAssertTrue(
            lookup.calls.isEmpty,
            "a durable refusal must suppress the Keychain lookup itself"
        )
    }
}
#endif
