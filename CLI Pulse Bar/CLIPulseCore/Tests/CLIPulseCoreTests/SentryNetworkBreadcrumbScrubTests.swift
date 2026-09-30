import XCTest
@testable import CLIPulseCore

/// v1.55: crash reports stay on, but what they carry about web requests is cut
/// down to what a crash needs.
///
/// sentry-cocoa records each request the app makes as an `http` breadcrumb
/// (`SentryNetworkTracker.addBreadcrumbForSessionTask`, 9.11): `url` without
/// its query, then the query under `http.query` and the fragment under
/// `http.fragment`. A request to our server's REST API names the account in
/// its query (`profiles?id=eq.<user id>`), and a claude.ai request names the
/// Claude organization in its path. The breadcrumbs below are built the way
/// that tracker builds them.
final class SentryNetworkBreadcrumbScrubTests: XCTestCase {
    private let userID = "6f1c1a52-3b0e-4d7a-9c55-0d9e8f7a6b5c"
    private let orgID = "0a9b8c7d-6e5f-4a3b-8c2d-1e0f9a8b7c6d"

    /// An `http` breadcrumb as sentry-cocoa's network tracker records it.
    private func httpBreadcrumb(url: String, query: String?, fragment: String? = nil) -> Breadcrumb {
        let crumb = Breadcrumb(level: .info, category: "http")
        crumb.type = "http"
        var data: [String: Any] = [
            "url": url,
            "method": "GET",
            "status_code": 200,
            "reason": "no error",
            "request_body_size": 0,
            "response_body_size": 512,
        ]
        if let query { data["http.query"] = query }
        if let fragment { data["http.fragment"] = fragment }
        crumb.data = data
        return crumb
    }

    private func scrubbed(_ crumb: Breadcrumb) throws -> [String: Any] {
        let out = try XCTUnwrap(SentryLogger.scrub(breadcrumb: crumb), "a breadcrumb must be kept, not dropped")
        return out.data ?? [:]
    }

    // MARK: - the query and the fragment

    func testTheQueryAndTheFragmentAreDropped() throws {
        let data = try scrubbed(httpBreadcrumb(
            url: "https://abcd.supabase.co/rest/v1/profiles",
            query: "select=*&id=eq.\(userID)",
            fragment: "section"))
        XCTAssertNil(data["http.query"], "the query names the account")
        XCTAssertNil(data["http.fragment"])
        XCTAssertFalse("\(data)".contains(userID))
    }

    func testWhatACrashNeedsStays() throws {
        // Negative control: a request with nothing to hide keeps its address
        // and everything else sentry-cocoa recorded about it.
        let data = try scrubbed(httpBreadcrumb(
            url: "https://abcd.supabase.co/rest/v1/rpc/app_dashboard_summary_v2", query: nil))
        XCTAssertEqual(data["url"] as? String, "https://abcd.supabase.co/rest/v1/rpc/app_dashboard_summary_v2")
        XCTAssertEqual(data["method"] as? String, "GET")
        XCTAssertEqual(data["status_code"] as? Int, 200)
        XCTAssertEqual(data["response_body_size"] as? Int, 512)
    }

    // MARK: - identifiers in the path

    func testAnIdentifierInThePathIsReplaced() throws {
        let data = try scrubbed(httpBreadcrumb(
            url: "https://claude.ai/api/organizations/\(orgID)/usage", query: nil))
        XCTAssertEqual(data["url"] as? String, "https://claude.ai/api/organizations/[id]/usage")
    }

    func testIdentifiersThatAreNotUUIDsAreReplacedInThePathToo() {
        // `redact` catches UUIDs anywhere; a numeric, hex or percent-encoded
        // email identifier is caught only by the per-segment rule.
        XCTAssertEqual(SentryLogger.scrubURL("https://api.example.test/v1/users/1234567/usage"),
                       "https://api.example.test/v1/users/[id]/usage")
        XCTAssertEqual(SentryLogger.scrubURL("https://api.example.test/groups/0123456789abcdef0123/x"),
                       "https://api.example.test/groups/[id]/x")
        XCTAssertEqual(SentryLogger.scrubURL("https://api.example.test/u/someone%40example.com"),
                       "https://api.example.test/u/[id]")
    }

    func testAnAddressThatStillHasItsQueryLosesIt() {
        // Not every address comes through sentry-cocoa's sanitizer.
        XCTAssertEqual(
            SentryLogger.scrubURL("https://abcd.supabase.co/rest/v1/profiles?id=eq.\(userID)#top"),
            "https://abcd.supabase.co/rest/v1/profiles")
    }

    func testWhichSegmentsCountAsIdentifiers() {
        let ids = [userID, userID.uppercased(), "eq.\(userID)", "123456", "4821",
                   "0123456789abcdef0123", "someone@example.com", "someone%40example.com",
                   "gen-lang-client-0123456789"]
        for segment in ids {
            XCTAssertTrue(SentryLogger.isIdentifierSegment(Substring(segment)), segment)
        }
        // Names an API defines stay readable.
        let names = ["", "rest", "v1", "rpc", "usage", "app_dashboard_summary_v2", "organizations",
                     "oauth", "v1internal:loadCodeAssist", "helper_heartbeat", "2fa", "backend-api"]
        for segment in names {
            XCTAssertFalse(SentryLogger.isIdentifierSegment(Substring(segment)), segment)
        }
    }

    func testAnAddressWithNoPathIsKept() {
        XCTAssertEqual(SentryLogger.scrubURL("https://claude.ai"), "https://claude.ai")
        XCTAssertEqual(SentryLogger.scrubURL("https://claude.ai/"), "https://claude.ai/")
    }

    // MARK: - other breadcrumb data, and messages

    func testIdentifiersAreReplacedInEveryBreadcrumbString() throws {
        let crumb = Breadcrumb(level: .info, category: "navigation")
        crumb.message = "opened account \(userID) for someone@example.com"
        crumb.data = ["screen": "account/\(userID)", "count": 3]
        let out = try XCTUnwrap(SentryLogger.scrub(breadcrumb: crumb))
        XCTAssertEqual(out.message, "opened account [id] for [email]")
        XCTAssertEqual(out.data?["screen"] as? String, "account/[id]")
        XCTAssertEqual(out.data?["count"] as? Int, 3)
    }

    func testTheExistingSensitiveKeyRuleStillHolds() throws {
        let crumb = Breadcrumb(level: .info, category: "pairing")
        crumb.data = ["access_token": "abc", "error_code": "HelperAPIError.expired"]
        let out = try XCTUnwrap(SentryLogger.scrub(breadcrumb: crumb))
        XCTAssertEqual(out.data?["access_token"] as? String, "[scrubbed]")
        XCTAssertEqual(out.data?["error_code"] as? String, "HelperAPIError.expired")
    }

    // MARK: - beforeSend

    func testAnEventsBreadcrumbsAreScrubbedAgainBeforeItIsSent() throws {
        // A crash is sent on the next launch, with breadcrumbs an older build
        // recorded without this scrubber.
        let event = Event(level: .fatal)
        event.breadcrumbs = [
            httpBreadcrumb(url: "https://claude.ai/api/organizations/\(orgID)/usage", query: "x=1"),
            httpBreadcrumb(url: "https://abcd.supabase.co/rest/v1/profiles", query: "id=eq.\(userID)"),
        ]
        let sent = try XCTUnwrap(SentryLogger.scrub(event: event))
        let crumbs = try XCTUnwrap(sent.breadcrumbs)
        XCTAssertEqual(crumbs.count, 2)
        for crumb in crumbs {
            XCTAssertNil(crumb.data?["http.query"])
            let url = try XCTUnwrap(crumb.data?["url"] as? String)
            XCTAssertFalse(url.contains(orgID) || url.contains(userID), url)
        }
    }

    func testAnEventsRequestKeepsNoQueryCookiesOrHeaders() throws {
        let event = Event(level: .error)
        let request = SentryRequest()
        request.url = "https://abcd.supabase.co/rest/v1/devices/\(userID)?select=*"
        request.queryString = "id=eq.\(userID)"
        request.fragment = "x"
        request.cookies = "sb-access-token=abc"
        request.headers = ["Authorization": "Bearer abc"]
        event.request = request
        let sent = try XCTUnwrap(SentryLogger.scrub(event: event))
        XCTAssertEqual(sent.request?.url, "https://abcd.supabase.co/rest/v1/devices/[id]")
        XCTAssertNil(sent.request?.queryString)
        XCTAssertNil(sent.request?.fragment)
        XCTAssertNil(sent.request?.cookies)
        XCTAssertNil(sent.request?.headers)
    }
}
