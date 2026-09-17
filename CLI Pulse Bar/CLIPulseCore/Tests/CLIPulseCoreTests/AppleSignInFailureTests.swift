import XCTest
import AuthenticationServices
@testable import CLIPulseCore

/// Dismissing the Sign in with Apple sheet on the iPhone login screen left a red
/// "The operation couldn't be completed. (com.apple.AuthenticationServices.
/// AuthorizationError error 1001.)" under the button.
///
/// Asserted under zh-Hans: the generic line is English copy in English, so a
/// broken lookup would pass there.
final class AppleSignInFailureTests: XCTestCase {

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

    func testCancellingIsNotAnError() {
        let cancelled = ASAuthorizationError(.canceled)
        XCTAssertNil(AppleSignInFailure.signInMessage(for: cancelled))
        XCTAssertNil(AppleSignInFailure.linkMessage(for: cancelled))
        // As SignInWithAppleButton hands it over: a bridged NSError.
        let bridged = NSError(domain: ASAuthorizationError.errorDomain, code: ASAuthorizationError.canceled.rawValue)
        XCTAssertNil(AppleSignInFailure.signInMessage(for: bridged))
    }

    func testOtherFailuresShowTheAppsOwnLineNotTheSystemDomain() {
        for code in [ASAuthorizationError.Code.failed, .unknown, .invalidResponse, .notHandled] {
            let error = ASAuthorizationError(code)
            let signIn = AppleSignInFailure.signInMessage(for: error)
            XCTAssertEqual(signIn, "登录失败，请重试。", "\(code)")
            XCTAssertFalse(signIn?.contains("AuthenticationServices") ?? true)
            XCTAssertEqual(AppleSignInFailure.linkMessage(for: error), "关联失败，请重试。", "\(code)")
        }
    }

    /// Code 1001 in some other domain is not a cancelled Apple sheet.
    func testOnlyTheAuthorizationDomainCountsAsCancellation() {
        let lookalike = NSError(domain: NSURLErrorDomain, code: 1001)
        XCTAssertEqual(AppleSignInFailure.signInMessage(for: lookalike), L10n.auth.signInFailedGeneric)
    }
}
