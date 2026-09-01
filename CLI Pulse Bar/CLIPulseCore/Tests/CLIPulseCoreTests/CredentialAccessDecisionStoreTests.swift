#if os(macOS)
import Security
import XCTest
@testable import CLIPulseCore

final class CredentialAccessDecisionStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "test.credentialdeny.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testUnknownScopeIsNotDenied() {
        XCTAssertFalse(
            CredentialAccessDecisionStore.isDenied(
                scope: .claudeCodeImport,
                defaults: defaults
            )
        )
    }

    func testDenialSurvivesStoreReopen() {
        let scope = CredentialAccessScope.browserSafeStorage(
            provider: "Cursor",
            browser: "Edge"
        )
        CredentialAccessDecisionStore.recordDenial(scope: scope, defaults: defaults)

        let reopened = UserDefaults(suiteName: suiteName)!
        XCTAssertTrue(
            CredentialAccessDecisionStore.isDenied(scope: scope, defaults: reopened)
        )
    }

    func testExplicitTryAgainClearsOnlyRequestedScope() {
        let edge = CredentialAccessScope.browserSafeStorage(
            provider: "Cursor",
            browser: "Edge"
        )
        let chrome = CredentialAccessScope.browserSafeStorage(
            provider: "Cursor",
            browser: "Chrome"
        )
        CredentialAccessDecisionStore.recordDenial(scope: edge, defaults: defaults)
        CredentialAccessDecisionStore.recordDenial(scope: chrome, defaults: defaults)

        CredentialAccessDecisionStore.clearDenial(scope: edge, defaults: defaults)

        XCTAssertFalse(CredentialAccessDecisionStore.isDenied(scope: edge, defaults: defaults))
        XCTAssertTrue(CredentialAccessDecisionStore.isDenied(scope: chrome, defaults: defaults))
    }

    func testOnlyInteractiveRefusalStatusesCountAsDenial() {
        XCTAssertTrue(CredentialAccessDecisionStore.statusIndicatesDenial(errSecUserCanceled))
        XCTAssertTrue(CredentialAccessDecisionStore.statusIndicatesDenial(errSecAuthFailed))
        XCTAssertFalse(CredentialAccessDecisionStore.statusIndicatesDenial(errSecItemNotFound))
        XCTAssertFalse(CredentialAccessDecisionStore.statusIndicatesDenial(errSecSuccess))
        XCTAssertFalse(
            CredentialAccessDecisionStore.statusIndicatesDenial(errSecInteractionNotAllowed)
        )
    }
}
#endif
