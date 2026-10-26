// 59-01 (1.59): every value of the closed `UploadOutcome.Reason` set, through
// the log line and the reporter.
//
// The log line is `privacy: .public` as a whole, which is only safe while it
// is made of the reason's token and integers. The reporter is the Sentry
// event, which may fire only on the third failure in a row and only once a
// day. Both are pinned here for every reason, so a reason added without
// deciding how it counts does not compile (`sample(for:)` is an exhaustive
// switch), and a reason whose kind changes fails `decidedKinds`.
// `SentryUploadReporterScopeTests` pins what the event itself carries.

import Foundation
import XCTest
@testable import CLIPulseCore

@MainActor
final class UploadOutcomeTests: XCTestCase {

    /// One outcome per reason. Exhaustive: a new reason has to be added here.
    static func sample(for reason: UploadOutcome.Reason) -> UploadOutcome {
        switch reason {
        case .uploaded: return .uploaded(rows: 12, status: 200, afterTokenRefresh: true)
        case .rejected: return .rejected(status: 403)
        case .unauthorized: return .unauthorized(afterRetry: false)
        case .unauthorizedAfterRetry: return .unauthorized(afterRetry: true)
        case .networkFailed: return .networkFailed
        case .serverUnreachable: return .serverUnreachable
        case .offline: return .offline
        case .noAnswer: return .noAnswer
        case .cloudReadFailed: return .cloudReadFailed(status: 500)
        case .refreshStuck: return .refreshInFlight(seconds: UploadOutcome.stuckRefreshSeconds)
        case .refreshInFlight: return .refreshInFlight(seconds: 42)
        case .sessionExpired: return .sessionExpired
        case .consentDeclined: return .consentDeclined
        case .consentUnanswered: return .consentUnanswered
        case .folderAccessMissing: return .folderAccessMissing
        case .scanEmpty: return .scanEmpty
        case .nothingToUpload: return .nothingToUpload
        case .authorizationChanged: return .authorizationChanged
        case .cancelled: return .cancelled
        case .signedOut: return .signedOut
        case .demo: return .demo
        case .notAMac: return .notAMac
        }
    }

    /// Written out rather than read back from `kind`: this is the decision.
    /// Failures are what should not happen to a running, signed-in Mac that
    /// has something to send, and only they may page anyone. A refresh that
    /// ran to its end with nothing to send by design is `finished` and ends a
    /// row of failures; one that did not run to its end, or whose state
    /// changed under it, is `inconclusive` and leaves the row as it is.
    static let decidedKinds: [UploadOutcome.Reason: UploadOutcome.Kind] = [
        .uploaded: .success,
        .rejected: .failure,
        .unauthorized: .failure,
        .unauthorizedAfterRetry: .failure,
        .networkFailed: .failure,
        .serverUnreachable: .failure,
        .offline: .inconclusive,
        .noAnswer: .inconclusive,
        .cloudReadFailed: .failure,
        .refreshStuck: .failure,
        .refreshInFlight: .inconclusive,
        .sessionExpired: .inconclusive,
        .consentDeclined: .finished,
        .consentUnanswered: .finished,
        .folderAccessMissing: .finished,
        .scanEmpty: .finished,
        .nothingToUpload: .finished,
        .authorizationChanged: .inconclusive,
        .cancelled: .inconclusive,
        .signedOut: .finished,
        .demo: .finished,
        .notAMac: .inconclusive,
    ]

    /// The whole line: tokens, `key=value` pairs whose values are integers or
    /// tokens, nothing else. A string from the user's data (a path, a model
    /// name, an error's text) cannot match this.
    static let safeLine = try! NSRegularExpression(
        pattern: #"^upload outcome=[a-z_]+ route=(cloud|local|none)( [a-z_]+=([0-9]+|unknown))+$"#
    )

    static func isSafe(_ line: String) -> Bool {
        safeLine.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    // MARK: - The set

    func testEveryReasonRoundTripsAndHasItsDecidedKind() {
        XCTAssertEqual(Set(Self.decidedKinds.keys), Set(UploadOutcome.Reason.allCases),
                       "every reason needs a decided kind")
        for reason in UploadOutcome.Reason.allCases {
            let outcome = Self.sample(for: reason)
            XCTAssertEqual(outcome.reason, reason)
            XCTAssertEqual(outcome.kind, Self.decidedKinds[reason], "\(reason)")
            XCTAssertNotNil(reason.rawValue.range(of: #"^[a-z_]+$"#, options: .regularExpression),
                            "\(reason.rawValue) is not a plain token")
        }
    }

    func testAStuckRefreshIsAFailureAndASlowOneIsNot() {
        let limit = UploadOutcome.stuckRefreshSeconds
        XCTAssertEqual(UploadOutcome.refreshInFlight(seconds: limit - 1).reason, .refreshInFlight)
        XCTAssertEqual(UploadOutcome.refreshInFlight(seconds: limit).reason, .refreshStuck)
        XCTAssertEqual(UploadOutcome.refreshInFlight(seconds: nil).reason, .refreshInFlight,
                       "an unknown age is not evidence of a stuck refresh")
    }

    /// Only the codes with which the system says there is no network are
    /// `offline`. A timeout or a dropped connection is what a Mac with no
    /// network and a server that never answers both end in, so it claims
    /// neither (`no_answer`). Everything else leaves the caller's reason.
    func testWhatAnErrorSaysAboutTheNetwork() {
        for code in [URLError.Code.notConnectedToInternet, .dataNotAllowed,
                     .internationalRoamingOff, .callIsActive] {
            XCTAssertEqual(UploadOutcome.networkOutcome(URLError(code)), .offline, "\(code)")
        }
        for code in [URLError.Code.timedOut, .networkConnectionLost] {
            XCTAssertEqual(UploadOutcome.networkOutcome(URLError(code)), .noAnswer,
                           "\(code) cannot tell this Mac's network from our server")
        }
        for code in [URLError.Code.cannotFindHost, .cannotConnectToHost, .secureConnectionFailed,
                     .serverCertificateUntrusted, .badServerResponse] {
            XCTAssertNil(UploadOutcome.networkOutcome(URLError(code)), "\(code)")
        }
        XCTAssertNil(UploadOutcome.networkOutcome(APIError.httpError(status: 503, body: "")))
        XCTAssertNil(UploadOutcome.networkOutcome(CancellationError()))
    }

    // MARK: - The log line, for every reason

    func testEveryReasonLogsOneSafeLineNamingIt() {
        for reason in UploadOutcome.Reason.allCases {
            for route in [UploadRoute.cloud, .local, .none] {
                var lines: [String] = []
                let tracker = UploadOutcomeTracker(
                    reporter: RecordingUploadReporter(),
                    defaults: Self.freshDefaults(),
                    log: { lines.append($0) }
                )
                tracker.record(Self.sample(for: reason), route: route)
                XCTAssertEqual(lines.count, 1, "\(reason): one line per outcome")
                guard let line = lines.first else { continue }
                XCTAssertTrue(Self.isSafe(line), "\(reason) logged an unsafe line: \(line)")
                XCTAssertTrue(line.hasPrefix("upload outcome=\(reason.rawValue) route=\(route.rawValue)"), line)
            }
        }
    }

    func testTheLineCarriesTheNumbersThatExplainIt() {
        func line(_ outcome: UploadOutcome) -> String {
            var lines: [String] = []
            let tracker = UploadOutcomeTracker(
                reporter: RecordingUploadReporter(), defaults: Self.freshDefaults(),
                log: { lines.append($0) })
            tracker.record(outcome, route: .cloud)
            return lines.first ?? ""
        }
        XCTAssertEqual(line(.uploaded(rows: 12, status: 200, afterTokenRefresh: true)),
                       "upload outcome=uploaded route=cloud status=200 rows=12 token_refreshed=1 failures_in_a_row=0")
        XCTAssertEqual(line(.unauthorized(afterRetry: true)),
                       "upload outcome=unauthorized_after_retry route=cloud status=401 failures_in_a_row=1")
        XCTAssertEqual(line(.cloudReadFailed(status: nil)),
                       "upload outcome=cloud_read_failed route=cloud failures_in_a_row=1")
        XCTAssertEqual(line(.refreshInFlight(seconds: 900)),
                       "upload outcome=refresh_stuck route=cloud in_flight_s=900 failures_in_a_row=1")
        XCTAssertEqual(line(.refreshInFlight(seconds: nil)),
                       "upload outcome=refresh_in_flight route=cloud in_flight_s=unknown failures_in_a_row=0")
    }

    // MARK: - The reporter, for every reason

    /// Three in a row of each reason: a failure reports once, on the third;
    /// anything else never reports.
    func testOnlyAThirdFailureInARowReports() {
        for reason in UploadOutcome.Reason.allCases {
            let reporter = RecordingUploadReporter()
            let tracker = UploadOutcomeTracker(
                reporter: reporter, defaults: Self.freshDefaults(), log: { _ in })
            let outcome = Self.sample(for: reason)

            tracker.record(outcome, route: .local)
            tracker.record(outcome, route: .local)
            XCTAssertEqual(reporter.reports, [], "\(reason) reported before the third time")
            tracker.record(outcome, route: .local)

            if Self.decidedKinds[reason] == .failure {
                XCTAssertEqual(reporter.reports, [
                    UploadFailureReport(reason: reason, status: outcome.status, route: .local, failuresInARow: 3),
                ], "\(reason)")
            } else {
                XCTAssertEqual(reporter.reports, [], "\(reason) is not a failure and must not report")
            }
        }
    }

    func testASuccessResetsTheCountAndInconclusiveOutcomesLeaveIt() {
        let reporter = RecordingUploadReporter()
        let tracker = UploadOutcomeTracker(reporter: reporter, defaults: Self.freshDefaults(), log: { _ in })

        tracker.record(.networkFailed, route: .cloud)
        tracker.record(.networkFailed, route: .cloud)
        tracker.record(.uploaded(rows: 1, status: 200, afterTokenRefresh: false), route: .cloud)
        tracker.record(.networkFailed, route: .cloud)
        tracker.record(.networkFailed, route: .cloud)
        XCTAssertEqual(tracker.failuresInARow, 2)
        XCTAssertEqual(reporter.reports, [], "a success in between must reset the count")

        // A refresh that did not run to its end says nothing about whether
        // uploads work: the count stays where it was.
        for reason in UploadOutcome.Reason.allCases where Self.decidedKinds[reason] == .inconclusive {
            tracker.record(Self.sample(for: reason), route: .cloud)
            XCTAssertEqual(tracker.failuresInARow, 2, "\(reason) moved the count")
        }
        tracker.record(.rejected(status: 500), route: .cloud)
        XCTAssertEqual(reporter.reports.map(\.reason), [.rejected])
        XCTAssertEqual(reporter.reports.first?.status, 500)
        XCTAssertEqual(reporter.reports.first?.failuresInARow, 3)
    }

    /// A Mac that never uploads (no provider found, "Not now") never gets a
    /// success. Its clean refreshes still end a row of failures, or three
    /// blips over weeks of menu-bar uptime would be reported as three in a
    /// row.
    func testAFinishedRefreshEndsTheRowOfFailures() {
        let reporter = RecordingUploadReporter()
        let tracker = UploadOutcomeTracker(reporter: reporter, defaults: Self.freshDefaults(), log: { _ in })
        for outcome: UploadOutcome in [.cloudReadFailed(status: 503), .scanEmpty,
                                       .serverUnreachable, .scanEmpty,
                                       .refreshInFlight(seconds: 900)] {
            tracker.record(outcome, route: .cloud)
        }
        XCTAssertEqual(tracker.failuresInARow, 1)
        XCTAssertEqual(reporter.reports, [], "three failures with clean refreshes between are not in a row")

        for reason in UploadOutcome.Reason.allCases where Self.decidedKinds[reason] == .finished {
            let tracker = UploadOutcomeTracker(reporter: reporter, defaults: Self.freshDefaults(), log: { _ in })
            tracker.record(.networkFailed, route: .local)
            tracker.record(.networkFailed, route: .local)
            tracker.record(Self.sample(for: reason), route: .local)
            XCTAssertEqual(tracker.failuresInARow, 0, "\(reason) did not end the row")
            tracker.record(.networkFailed, route: .local)
            tracker.record(.networkFailed, route: .local)
            XCTAssertEqual(reporter.reports, [], "\(reason): the two failures before it were counted again")
        }
    }

    func testAtMostOneReportAnInstallADay() throws {
        let defaults = Self.freshDefaults()
        let reporter = RecordingUploadReporter()
        var now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-27T01:00:00Z"))
        let tracker = UploadOutcomeTracker(reporter: reporter, defaults: defaults, now: { now }, log: { _ in })

        for _ in 0..<10 { tracker.record(.rejected(status: 403), route: .cloud) }
        XCTAssertEqual(reporter.reports.count, 1, "ten failures in one day are one report")

        // The mark is the install's, not the tracker's: a relaunch the same
        // day does not report again.
        let relaunched = UploadOutcomeTracker(reporter: reporter, defaults: defaults, now: { now }, log: { _ in })
        for _ in 0..<5 { relaunched.record(.networkFailed, route: .local) }
        XCTAssertEqual(reporter.reports.count, 1, "a relaunch reported again the same day")

        // The next UTC day, still failing: one more.
        now = now.addingTimeInterval(24 * 3_600)
        tracker.record(.rejected(status: 403), route: .cloud)
        XCTAssertEqual(reporter.reports.count, 2)
        XCTAssertEqual(reporter.reports.last?.failuresInARow, 11)
    }

    func testTheRouteTokens() {
        XCTAssertEqual(UploadRoute(.cloud), .cloud)
        XCTAssertEqual(UploadRoute(.localOnly), .local)
        XCTAssertEqual(UploadRoute(.noOp), UploadRoute.none)
    }

    // MARK: - Negative controls for the checks above

    /// The safe-line check must reject what it exists to keep out.
    func testTheSafeLineCheckRejectsUserData() {
        XCTAssertTrue(Self.isSafe("upload outcome=scan_empty route=local failures_in_a_row=0"))
        XCTAssertFalse(Self.isSafe("upload outcome=rejected route=cloud status=403 error=Failing row contains (a@b.c)"))
        XCTAssertFalse(Self.isSafe("upload outcome=scan_empty route=local path=/Users/someone/.codex"))
        XCTAssertFalse(Self.isSafe("upload outcome=uploaded route=cloud model=claude-opus-5"))
    }

    // MARK: - Helpers

    static func freshDefaults() -> UserDefaults {
        let suite = "upload-outcome-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}

final class RecordingUploadReporter: UploadReporter, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [UploadFailureReport] = []

    var reports: [UploadFailureReport] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func reportRepeatedFailure(_ report: UploadFailureReport) {
        lock.lock(); defer { lock.unlock() }
        stored.append(report)
    }
}

/// What the Sentry event carries beyond the SDK's standard envelope, which
/// PRIVACY.md lists: four tags, the fingerprint, the level, the message, and
/// no breadcrumbs. A tag added here or a `clearBreadcrumbs()` dropped turns
/// PRIVACY.md untrue; this is what catches it.
final class SentryUploadReporterScopeTests: XCTestCase {

    static let report = UploadFailureReport(
        reason: .cloudReadFailed, status: 503, route: .cloud, failuresInARow: 3)

    func testTheEventAddsOnlyTheReasonAndNoBreadcrumbs() throws {
        // `capture(message:block:)` hands the block a copy of the current
        // scope, which has the breadcrumbs of the last refreshes.
        let current = Scope()
        current.addBreadcrumb(Breadcrumb(level: .info, category: "http"))
        current.addBreadcrumb(Breadcrumb(level: .info, category: "app.lifecycle"))
        let event = Scope(scope: current)
        let before = event.serialize()
        XCTAssertEqual((before["breadcrumbs"] as? [Any])?.count, 2,
                       "control: the copy did not carry the breadcrumbs, so their removal proves nothing")

        SentryUploadReporter.configure(event, for: Self.report)
        let after = event.serialize()

        XCTAssertNil(after["breadcrumbs"], "the upload event must carry no breadcrumbs (PRIVACY.md)")
        XCTAssertEqual(after["tags"] as? [String: String], [
            "upload_reason": "cloud_read_failed",
            "upload_status": "503",
            "upload_route": "cloud",
            "upload_failures_in_a_row": "3",
        ])
        XCTAssertEqual(after["fingerprint"] as? [String], ["daily-usage-upload", "cloud_read_failed"])
        XCTAssertEqual(after["level"] as? String, "warning")
        // Nothing else of ours: no user, no extras, no contexts.
        let added = Set(after.keys).subtracting(before.keys)
        XCTAssertEqual(added, ["tags", "fingerprint", "level"])
        for key in ["user", "extra", "context", "attributes"] {
            XCTAssertNil(after[key], "\(key) was set on the upload event")
        }

        // Only the event's copy loses them: a crash report keeps its own.
        XCTAssertEqual((current.serialize()["breadcrumbs"] as? [Any])?.count, 2)
    }

    func testAMissingStatusIsAWordAndTheMessageIsTheReason() {
        let scope = Scope()
        let report = UploadFailureReport(reason: .serverUnreachable, status: nil, route: .local, failuresInARow: 4)
        SentryUploadReporter.configure(scope, for: report)
        XCTAssertEqual((scope.serialize()["tags"] as? [String: String])?["upload_status"], "none")
        XCTAssertEqual(SentryUploadReporter.message(for: report), "daily-usage-upload server_unreachable")
    }
}
