import XCTest
@testable import CLIPulseCore

/// A failed Supabase response used to reach the sign-in, delete-account, linked
/// accounts and pairing screens as `HTTP 403：{"code":403,"error_code":"otp_expired",…}`:
/// only the wrapper was translated, the body was English server JSON.
///
/// Every assertion runs under zh-Hans. In English the localized value equals the
/// fallback copy, so a broken lookup would still pass there.
final class ServerErrorReasonTests: XCTestCase {

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

    // Bodies as GoTrue and PostgREST actually send them.
    private let otpExpired = #"{"code":403,"error_code":"otp_expired","msg":"Token has expired or is invalid"}"#
    private let emailRateLimit = #"{"code":429,"error_code":"over_email_send_rate_limit","msg":"email rate limit exceeded"}"#
    private let badPassword = #"{"code":400,"error_code":"invalid_credentials","msg":"Invalid login credentials"}"#
    private let lastIdentity = #"{"code":422,"error_code":"single_identity_not_deletable","msg":"User must have at least 1 identity after unlinking"}"#
    private let statementTimeout = #"{"code":"57014","details":null,"hint":null,"message":"canceling statement due to statement timeout"}"#
    /// A `raise exception` from one of our RPCs that has no message of its own.
    private let raisedException = #"{"code":"P0001","details":null,"hint":null,"message":"Too many sessions (max 500)"}"#
    private let deviceGone = #"{"code":"P0001","details":null,"hint":null,"message":"Device not found or unauthorized"}"#

    func testTheSignInFailuresUsersHitAreLocalizedAndCarryNoBody() {
        let cases: [(Int, String, String)] = [
            (403, otpExpired, L10n.serverError.codeInvalidOrExpired),
            (429, emailRateLimit, L10n.serverError.rateLimited),
            (400, badPassword, L10n.serverError.invalidCredentials),
            (422, lastIdentity, L10n.serverError.lastIdentity),
            (500, statementTimeout, L10n.serverError.timeout),
        ]
        for (status, body, expected) in cases {
            let shown = APIError.httpError(status: status, body: body).localizedDescription
            XCTAssertEqual(shown, expected, "HTTP \(status) \(body)")
            assertNoServerText(shown, body: body)
        }
        XCTAssertEqual(L10n.serverError.codeInvalidOrExpired, "验证码错误或已过期，请重新获取验证码。",
                       "the zh-Hans lookup is not being used")
    }

    /// A code the app has no message for keeps the status — support needs it —
    /// and loses the body, including the English exception text our own RPCs raise.
    func testAnUnknownCodeFallsBackToTheStatusWithoutTheBody() {
        let shown = APIError.httpError(status: 400, body: raisedException).localizedDescription
        XCTAssertEqual(shown, "服务器返回错误（HTTP 400）。")
        assertNoServerText(shown, body: raisedException)
    }

    func testStatusDecidesWhenThereIsNoCode() {
        XCTAssertEqual(ServerErrorReason.classify(status: 429, body: ""), .rateLimited)
        XCTAssertEqual(ServerErrorReason.classify(status: 503, body: "<html>Bad gateway</html>"), .unavailable)
        XCTAssertEqual(ServerErrorReason.classify(status: 404, body: "not json"), .failed)
        XCTAssertEqual(ServerErrorReason.classify(status: 0, body: ""), .failed)
        let shown = APIError.httpError(status: 503, body: "<html>Bad gateway</html>").localizedDescription
        XCTAssertTrue(shown.contains("503"), shown)
        XCTAssertFalse(shown.contains("html"), shown)
    }

    /// GoTrue's own `code` is the numeric status; only `error_code` names the case.
    /// Reading `code` first as a string must not shadow it.
    func testGoTrueNumericCodeDoesNotShadowErrorCode() {
        XCTAssertEqual(ServerErrorReason.serverCode(in: otpExpired), "otp_expired")
        XCTAssertEqual(ServerErrorReason.serverCode(in: statementTimeout), "57014")
        XCTAssertNil(ServerErrorReason.serverCode(in: "{}"))
        XCTAssertNil(ServerErrorReason.serverCode(in: "[1,2]"))
    }

    /// The pairing screen and the helper's status line render `HelperAPIError`,
    /// which appended the first 200 characters of the body.
    func testHelperHTTPErrorsAreLocalizedWithoutTheBodyOrTheRPCName() {
        let shown = HelperAPIError.httpError(status: 400, function: "helper_sync", body: raisedException)
            .localizedDescription
        XCTAssertEqual(shown, "服务器返回错误（HTTP 400）。")
        XCTAssertFalse(shown.contains("helper_sync"), shown)
        assertNoServerText(shown, body: raisedException)
    }

    /// The body is still on the case: `isProviderAccountRPCUnavailable` parses it.
    func testTheBodyStaysOnTheErrorValue() {
        guard case let .httpError(_, body) = APIError.httpError(status: 404, body: raisedException) else {
            return XCTFail("case changed")
        }
        XCTAssertEqual(body, raisedException)
    }

    /// Delete-account shows the description as its alert text; the status must survive.
    func testDeleteAccountFailureKeepsTheStatusAndDropsTheBody() {
        guard case let .other(message) = DeleteAccountFailure.classify(
            APIError.httpError(status: 400, body: raisedException)
        ) else {
            return XCTFail("expected .other")
        }
        XCTAssertTrue(message.contains("400"), message)
        assertNoServerText(message, body: raisedException)
    }

    /// The helper's heartbeat and sync raise this when the Mac's device row is gone
    /// or its secret no longer matches. Shown as "HTTP 400" it gave no hint that
    /// retrying is pointless and the Mac has to be paired again.
    func testAMissingDeviceAsksToPairAgain() {
        XCTAssertEqual(ServerErrorReason.classify(status: 400, body: deviceGone), .deviceNotPaired)
        let shown = HelperAPIError.httpError(status: 400, function: "helper_heartbeat", body: deviceGone)
            .localizedDescription
        XCTAssertEqual(shown, "这台 Mac 已不再与你的账户配对。如需恢复同步，请在设置中重新设置云同步。")
        assertNoServerText(shown, body: deviceGone)
        XCTAssertFalse(shown.contains("Device not found"), shown)
    }

    /// P0001 is every plain `raise exception`, so the code alone must not match,
    /// and the text alone under another code must not either.
    func testOnlyThatExceptionUnderP0001MeansTheDeviceIsGone() {
        XCTAssertEqual(ServerErrorReason.classify(status: 400, body: raisedException), .failed)
        let sameTextOtherCode = #"{"code":"P0002","message":"Device not found or unauthorized"}"#
        XCTAssertEqual(ServerErrorReason.classify(status: 400, body: sameTextOtherCode), .failed)
        // The app's own machine-command RPC raises a shorter text about another device.
        let appSide = #"{"code":"P0001","message":"Device not found"}"#
        XCTAssertEqual(ServerErrorReason.classify(status: 400, body: appSide), .failed)
    }

    func testEveryReasonHasZhHansCopyWithItsSpecifiersFilled() {
        for reason in ServerErrorReason.allCases {
            let shown = reason.localizedText(status: 502)
            XCTAssertFalse(shown.isEmpty, "\(reason)")
            XCTAssertFalse(shown.contains("%"), "unfilled specifier for \(reason): \(shown)")
            XCTAssertFalse(shown.contains("server_error."), "raw key for \(reason): \(shown)")
            // Brand, protocol and product names stay Latin in every language.
            let prose = ["CLI Pulse", "HTTP", "Mac"].reduce(shown) {
                $0.replacingOccurrences(of: $1, with: "")
            }
            XCTAssertNil(prose.range(of: "[A-Za-z]{3,}", options: .regularExpression),
                         "English left in the zh-Hans text for \(reason): \(shown)")
        }
    }

    private func assertNoServerText(_ shown: String, body: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(shown.contains("{"), "JSON reached the screen: \(shown)", file: file, line: line)
        if let code = ServerErrorReason.serverCode(in: body) {
            XCTAssertFalse(shown.contains(code), "server code reached the screen: \(shown)", file: file, line: line)
        }
    }
}
