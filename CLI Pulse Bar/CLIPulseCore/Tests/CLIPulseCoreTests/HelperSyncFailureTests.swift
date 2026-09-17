import XCTest
@testable import CLIPulseCore

/// The Login Item helper stored its sync error as ready-made text, formatted in
/// its own process — which never sees the in-app language — with the raw
/// PostgREST body in it, and Settings › Advanced showed that verbatim. It now
/// stores a token; these tests pin the token and the app-side rendering.
///
/// Rendering is asserted under zh-Hans: in English a broken lookup still
/// returns English copy and would pass.
final class HelperSyncFailureTests: XCTestCase {

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

    private let deviceGone = #"{"code":"P0001","details":null,"hint":null,"message":"Device not found or unauthorized"}"#
    private let timeoutBody = #"{"code":"57014","message":"canceling statement due to statement timeout"}"#
    private let tooManySessions = #"{"code":"P0001","details":null,"hint":null,"message":"Too many sessions (max 500)"}"#

    // MARK: - What the helper stores

    func testTheStoredCodeIsAStableTokenWithoutTheBody() {
        let http = HelperAPIError.httpError(status: 400, function: "helper_sync", body: deviceGone)
        XCTAssertEqual(HelperSyncFailure.code(for: http), "http_400_device_not_paired")
        XCTAssertEqual(
            HelperSyncFailure.code(for: HelperAPIError.httpError(status: 400, function: "helper_sync", body: tooManySessions)),
            "http_400_failed"
        )
        XCTAssertEqual(
            HelperSyncFailure.code(for: HelperAPIError.httpError(status: 500, function: "helper_heartbeat", body: timeoutBody)),
            "http_500_timeout"
        )
        XCTAssertEqual(HelperSyncFailure.code(for: URLError(.timedOut)), "network")
        XCTAssertEqual(HelperSyncFailure.code(for: HelperAPIError.notConfigured), "not_configured")
        XCTAssertEqual(HelperSyncFailure.code(for: HelperAPIError.parseFailed("x")), "parse_failed")
        XCTAssertEqual(HelperSyncFailure.code(for: CocoaError(.fileReadCorruptFile)), "unknown")
    }

    /// The token must not depend on the language the helper runs in.
    func testTheStoredCodeDoesNotFollowTheLocale() {
        let error = HelperAPIError.httpError(status: 503, function: "helper_sync", body: "")
        let chinese = HelperSyncFailure.code(for: error)
        LocaleOverrideStore.shared.set("en")
        XCTAssertEqual(HelperSyncFailure.code(for: error), chinese)
    }

    // MARK: - What Settings shows

    func testEveryCodeTheHelperWritesRendersInTheAppLanguage() {
        let errors: [(Error, String)] = [
            (HelperAPIError.httpError(status: 400, function: "helper_sync", body: deviceGone),
             "这台 Mac 已不再与你的账户配对。请在设置中重新配对以恢复同步。"),
            (HelperAPIError.httpError(status: 400, function: "helper_sync", body: tooManySessions), "服务器返回错误（HTTP 400）。"),
            (HelperAPIError.httpError(status: 500, function: "helper_sync", body: timeoutBody), L10n.serverError.timeout),
            (URLError(.notConnectedToInternet), "无法连接服务器，请检查网络连接。"),
            (HelperAPIError.notConfigured, L10n.a11y.configurationErrorBody),
            (HelperAPIError.pairingRejected(code: "expired", message: "Pairing code expired"), L10n.pairing.errorCodeExpired),
            (HelperAPIError.parseFailed("cannot decode"), "后台同步失败，将自动重试。"),
            (CocoaError(.fileReadCorruptFile), "后台同步失败，将自动重试。"),
        ]
        for (error, expected) in errors {
            let code = HelperSyncFailure.code(for: error)
            let shown = HelperSyncFailure.displayText(code: code, storedText: "English detail")
            XCTAssertEqual(shown, expected, "code \(code)")
            XCTAssertFalse(shown?.contains("{") ?? true, "JSON reached Settings: \(shown ?? "nil")")
            XCTAssertNotEqual(shown, "English detail", "the stored English detail was shown for \(code)")
        }
    }

    /// A status written by a helper from before the field: its text is all there is.
    func testAStatusWithoutACodeShowsItsStoredText() {
        XCTAssertEqual(HelperSyncFailure.displayText(code: nil, storedText: "old helper text"), "old helper text")
        XCTAssertNil(HelperSyncFailure.displayText(code: nil, storedText: nil))
    }

    /// A newer helper's token this build has never seen: localized, not the English detail.
    func testAnUnknownCodeShowsTheGenericLine() {
        for code in ["some_future_code", "http_x_timeout", "http_500_future_reason", "rejected_future"] {
            XCTAssertEqual(
                HelperSyncFailure.displayText(code: code, storedText: "English detail"),
                L10n.advanced.helperSyncFailed, code
            )
        }
    }

    // MARK: - The stored status across versions

    func testAStatusFromAnOlderHelperStillDecodes() throws {
        let old = #"{"state":"error","error":"HTTP 400 from helper_sync: {}","helperVersion":"1.0.0"}"#
        let status = try JSONDecoder().decode(HelperIPC.Status.self, from: Data(old.utf8))
        XCTAssertEqual(status.state, .error)
        XCTAssertNil(status.errorCode)
        XCTAssertEqual(status.error, "HTTP 400 from helper_sync: {}")
    }

    func testTheCodeRoundTripsThroughTheSharedStatus() throws {
        let written = HelperIPC.Status(state: .error, error: "helper_sync HTTP 500", errorCode: "http_500_timeout")
        let data = try JSONEncoder().encode(written)
        let read = try JSONDecoder().decode(HelperIPC.Status.self, from: data)
        XCTAssertEqual(read.errorCode, "http_500_timeout")
        XCTAssertEqual(HelperSyncFailure.displayText(code: read.errorCode, storedText: read.error), "服务器响应超时，请重试。")
    }
}
