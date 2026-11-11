import XCTest
@testable import CLIPulseCore

/// 1.63: crash reports stop carrying a per-device hash and the titles of the
/// screens and buttons the user saw.
///
/// sentry-cocoa 9.12.1 writes `device_app_hash` into the `app` context of every
/// crash report (`SentryDefaultCrashReporter`), and its breadcrumb tracker
/// records on iPhone a screen opening as a `ui.lifecycle` crumb and a control's
/// action as a `touch` crumb, both with a `title`. The fixtures below are built
/// the way the SDK builds them; the titles are invented.
final class SentryDeviceLinkScrubTests: XCTestCase {
    private let hash = "3f786850e387550fdab836ed7e6dc881de23001b"

    private func crashEvent(app: [String: Any]?, other: [String: [String: Any]] = [:]) -> Event {
        let event = Event(level: .fatal)
        var context = other
        if let app { context["app"] = app }
        event.context = context.isEmpty ? nil : context
        return event
    }

    private func crumb(_ category: String, data: [String: Any]) -> Breadcrumb {
        let crumb = Breadcrumb(level: .info, category: category)
        crumb.data = data
        return crumb
    }

    // MARK: - device_app_hash

    func testTheDeviceHashLeavesTheAppContextAndTheRestStays() throws {
        let event = crashEvent(
            app: ["device_app_hash": hash, "app_name": "CLI Pulse", "app_version": "1.63.0", "app_build": "118"],
            other: ["os": ["name": "iOS", "version": "27.0"], "device": ["model": "iPhone17,1"]]
        )
        let sent = try XCTUnwrap(SentryLogger.scrub(event: event))
        let context = try XCTUnwrap(sent.context)
        let app = try XCTUnwrap(context["app"])
        XCTAssertNil(app["device_app_hash"])
        XCTAssertEqual(app["app_name"] as? String, "CLI Pulse")
        XCTAssertEqual(app["app_version"] as? String, "1.63.0")
        XCTAssertEqual(app["app_build"] as? String, "118")
        XCTAssertEqual(context["os"]?["version"] as? String, "27.0")
        XCTAssertEqual(context["device"]?["model"] as? String, "iPhone17,1")
    }

    func testAnEventWithoutTheHashIsLeftAsItWas() throws {
        let noContext = try XCTUnwrap(SentryLogger.scrub(event: crashEvent(app: nil)))
        XCTAssertNil(noContext.context)

        let emptyApp = try XCTUnwrap(SentryLogger.scrub(event: crashEvent(app: [:])))
        XCTAssertEqual(emptyApp.context?["app"]?.count, 0)

        let noHash = try XCTUnwrap(SentryLogger.scrub(event: crashEvent(
            app: ["app_name": "CLI Pulse"], other: ["os": ["name": "macOS"]]
        )))
        XCTAssertEqual(noHash.context?["app"]?["app_name"] as? String, "CLI Pulse")
        XCTAssertEqual(noHash.context?["os"]?["name"] as? String, "macOS")
    }

    func testTheHashOnlyMattersInTheAppContext() throws {
        // A key of that name anywhere else is not the SDK's device hash, and
        // this rule does not touch it.
        let event = crashEvent(app: ["app_name": "CLI Pulse"], other: ["custom": ["device_app_hash": "x"]])
        let sent = try XCTUnwrap(SentryLogger.scrub(event: event))
        XCTAssertEqual(sent.context?["custom"]?["device_app_hash"] as? String, "x")
    }

    // MARK: - screen and button titles

    func testAScreenOpeningKeepsTheScreenButNotItsTitle() throws {
        let opened = crumb("ui.lifecycle", data: [
            "screen": "MachineDetailHostingController",
            "title": "Sample Studio Mac",
            "beingPresented": "false",
        ])
        let out = try XCTUnwrap(SentryLogger.scrub(breadcrumb: opened))
        let data = try XCTUnwrap(out.data)
        XCTAssertNil(data["title"], "removed, not replaced by a placeholder")
        XCTAssertEqual(data["screen"] as? String, "MachineDetailHostingController")
        XCTAssertEqual(data["beingPresented"] as? String, "false")
    }

    func testATouchKeepsTheViewButNotTheButtonTitle() throws {
        let touched = crumb("touch", data: ["view": "<UIButton: 0x1>", "title": "Reconnect to demo-mac"])
        let data = try XCTUnwrap(SentryLogger.scrub(breadcrumb: touched)?.data)
        XCTAssertNil(data["title"])
        XCTAssertEqual(data["view"] as? String, "<UIButton: 0x1>")
    }

    func testOtherCategoriesAreUnchangedByTheTitleRule() throws {
        // The category match is exact: these are the SDK's own strings.
        for category in ["navigation", "app.lifecycle", "UI.Lifecycle", "touches"] {
            let other = crumb(category, data: ["title": "Overview"])
            let data = try XCTUnwrap(SentryLogger.scrub(breadcrumb: other)?.data)
            XCTAssertEqual(data["title"] as? String, "Overview", category)
        }
    }

    func testACrashSentOnTheNextLaunchLosesBothKindsOfTitle() throws {
        // A crash is sent on the next launch, with breadcrumbs an older build
        // recorded without this rule.
        let event = crashEvent(app: ["device_app_hash": hash])
        event.breadcrumbs = [
            crumb("ui.lifecycle", data: ["screen": "SessionDetailHostingController", "title": "refactor the parser"]),
            crumb("touch", data: ["view": "<UIButton: 0x2>", "title": "Sample Studio Mac"]),
            crumb("navigation", data: ["title": "Overview"]),
        ]
        let sent = try XCTUnwrap(SentryLogger.scrub(event: event))
        let crumbs = try XCTUnwrap(sent.breadcrumbs)
        XCTAssertEqual(crumbs.count, 3)
        XCTAssertNil(crumbs[0].data?["title"])
        XCTAssertEqual(crumbs[0].data?["screen"] as? String, "SessionDetailHostingController")
        XCTAssertNil(crumbs[1].data?["title"])
        XCTAssertEqual(crumbs[2].data?["title"] as? String, "Overview")
        XCTAssertNil(sent.context?["app"]?["device_app_hash"])
    }

    // MARK: - options

    func testMetricsAreOffAndThePrivacyOptionsHold() {
        let options = Options()
        XCTAssertTrue(options.enableMetrics, "the SDK default this guards against")
        SentryLogger.applyPrivacyOptions(options)
        XCTAssertFalse(options.enableMetrics)
        XCTAssertFalse(options.sendDefaultPii)
        XCTAssertFalse(options.enableCaptureFailedRequests)
    }
}
