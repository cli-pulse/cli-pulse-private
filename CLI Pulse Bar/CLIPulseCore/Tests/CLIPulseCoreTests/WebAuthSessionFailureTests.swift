import XCTest
import AuthenticationServices
@testable import CLIPulseCore

/// A Google or GitHub sign-in (or link, or Connect Gemini) whose browser sheet
/// failed for any reason other than being closed showed the system sentence,
/// with "com.apple.AuthenticationServices.WebAuthenticationSession" and the
/// error code in it.
///
/// Asserted under zh-Hans: the generic lines are English copy in English, so a
/// broken lookup would pass there.
final class WebAuthSessionFailureTests: XCTestCase {

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

    func testClosingTheSheetIsNotAnError() {
        let cancelled = ASWebAuthenticationSessionError(.canceledLogin)
        XCTAssertNil(WebAuthSessionFailure.signInMessage(for: cancelled))
        XCTAssertNil(WebAuthSessionFailure.linkMessage(for: cancelled))
        XCTAssertNil(WebAuthSessionFailure.message(for: cancelled, generic: "unused"))
        // As the session's completion handler hands it over: a bridged NSError.
        let bridged = NSError(
            domain: ASWebAuthenticationSessionError.errorDomain,
            code: ASWebAuthenticationSessionError.canceledLogin.rawValue
        )
        XCTAssertNil(WebAuthSessionFailure.signInMessage(for: bridged))
    }

    func testOtherFailuresShowTheAppsOwnLineNotTheSystemDomain() {
        for code in [ASWebAuthenticationSessionError.Code.presentationContextNotProvided, .presentationContextInvalid] {
            let error = ASWebAuthenticationSessionError(code)
            let signIn = WebAuthSessionFailure.signInMessage(for: error)
            XCTAssertEqual(signIn, "登录失败，请重试。", "\(code)")
            XCTAssertFalse(signIn?.contains("AuthenticationServices") ?? true)
            XCTAssertEqual(WebAuthSessionFailure.linkMessage(for: error), "关联失败，请重试。", "\(code)")
            // Connect Gemini passes its own line.
            XCTAssertEqual(
                WebAuthSessionFailure.message(for: error, generic: L10n.providerConfig.errorGeminiSessionStartFailed),
                "无法启动身份验证会话", "\(code)"
            )
        }
    }

    /// Code 1 in another domain is not a closed browser sheet. The iPhone call
    /// sites used to compare the code alone.
    func testOnlyTheWebAuthenticationDomainCountsAsCancellation() {
        let lookalike = NSError(domain: NSURLErrorDomain, code: ASWebAuthenticationSessionError.canceledLogin.rawValue)
        XCTAssertEqual(WebAuthSessionFailure.signInMessage(for: lookalike), "登录失败，请重试。")
        // Not even in the sibling Sign in with Apple domain.
        let sibling = NSError(domain: ASAuthorizationError.errorDomain, code: ASWebAuthenticationSessionError.canceledLogin.rawValue)
        XCTAssertEqual(WebAuthSessionFailure.linkMessage(for: sibling), "关联失败，请重试。")
    }
}
