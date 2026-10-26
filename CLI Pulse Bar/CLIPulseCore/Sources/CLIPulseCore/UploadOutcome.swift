// 59-01 (1.59): what happened to this refresh's daily-usage upload, said
// once per refresh.
//
// Until 1.58 a successful upload wrote no log line at all, a failed one only
// `warning`s whose text was `<private>`, and none of the ways a refresh ends
// before it uploads wrote anything. Between them they made "running but not
// uploading" and "not running" look the same from the outside. So every
// refresh on a Mac now ends in exactly one `UploadOutcome`:
//
//   * one `.notice` line (`DataRefresh` category) made only of the reason's
//     token and integers, so it is `privacy: .public` and readable in a
//     `log stream` or a sysdiagnose without the user's data;
//   * after `failuresBeforeReport` failures in a row, one Sentry event with
//     the reason, the HTTP status and the route, and nothing else: no
//     breadcrumbs, no user, no message text of ours. At most one a day per
//     install (the daily mark is in UserDefaults), because the project shares
//     a monthly quota with another app.
//
// The reasons are a closed set (`Reason`). `UploadOutcomeTests` walks every
// one of them through the log and the reporter.

import Foundation
import os

/// Same subsystem and category as `DataRefreshManager`'s own lines, so one
/// `log stream` predicate shows both.
let uploadOutcomeLogger = Logger(subsystem: "com.clipulse", category: "DataRefresh")

public enum UploadOutcome: Equatable, Sendable {
    /// The rows reached the server: `rows` sent, `status` the 2xx it
    /// answered, `afterTokenRefresh` when the first attempt got a 401 and the
    /// retry with a refreshed token went through (59-01a).
    case uploaded(rows: Int, status: Int, afterTokenRefresh: Bool)
    /// The server answered something other than 2xx or 401 (after the
    /// `replace_daily_usage` → `upsert_daily_usage` fallback on 404).
    case rejected(status: Int)
    /// 401. `afterRetry == false`: the token could not be refreshed (no
    /// answer from the auth server), so there was nothing to retry with.
    /// `true`: the retry with a refreshed token was rejected again.
    case unauthorized(afterRetry: Bool)
    /// The upload got no answer (after `dataWithRetry`'s own retries), and
    /// not because this Mac is offline.
    case networkFailed
    /// The cloud route's health check failed, and not because this Mac is
    /// offline: nothing was read or sent.
    case serverUnreachable
    /// This Mac has no network (`isOffline`): a laptop on a train, not a
    /// fault, so it is logged and never reported.
    case offline
    /// The cloud route reads five things before it uploads, and one of them
    /// failed (`status` when it was an HTTP error): the upload is skipped.
    case cloudReadFailed(status: Int?)
    /// The refresh did not start because the previous one has not finished.
    /// `seconds` since that one started, nil when it is not known. A refresh
    /// that never returns keeps every later one here.
    case refreshInFlight(seconds: Int?)
    /// The refresh token was rejected; the app signs out, as it does when a
    /// read finds the same.
    case sessionExpired
    /// "Not now" on file: nothing on this Mac is read, so nothing is sent.
    case consentDeclined
    /// No answer on file yet (local mode while signed out).
    case consentUnanswered
    /// The scan found nothing and a log folder has no access grant (App
    /// Store build): the Overview banner asks for it.
    case folderAccessMissing
    /// The scan found nothing, with every folder accessible.
    case scanEmpty
    /// The scan found rows, but none is sent (`dailyUsageRowsToUpload`).
    case nothingToUpload
    /// Signed out or switched accounts during the refresh.
    case authorizationChanged
    /// A newer refresh replaced this one.
    case cancelled
    /// Not signed in: local mode reads, but has no account to upload to.
    case signedOut
    case demo
    /// iPhone, iPad and Watch upload nothing; the outcome is never logged.
    case notAMac

    /// The closed set of reasons. The raw values are the tokens the log line
    /// and the Sentry event carry; keep them stable, Sentry groups by them.
    public enum Reason: String, CaseIterable, Sendable {
        case uploaded
        case rejected
        case unauthorized
        case unauthorizedAfterRetry = "unauthorized_after_retry"
        case networkFailed = "network_failed"
        case serverUnreachable = "server_unreachable"
        case offline
        case cloudReadFailed = "cloud_read_failed"
        case refreshStuck = "refresh_stuck"
        case refreshInFlight = "refresh_in_flight"
        case sessionExpired = "session_expired"
        case consentDeclined = "consent_declined"
        case consentUnanswered = "consent_unanswered"
        case folderAccessMissing = "folder_access_missing"
        case scanEmpty = "scan_empty"
        case nothingToUpload = "nothing_to_upload"
        case authorizationChanged = "authorization_changed"
        case cancelled
        case signedOut = "signed_out"
        case demo
        case notAMac = "not_a_mac"
    }

    /// How an outcome counts towards "failures in a row".
    public enum Kind: Equatable, Sendable {
        /// Resets the count.
        case success
        /// Adds one.
        case failure
        /// By design or a change of state: leaves the count as it is.
        case expected
    }

    /// A refresh in flight this long is not slow, it is stuck.
    public static let stuckRefreshSeconds = 600

    public var reason: Reason {
        switch self {
        case .uploaded: return .uploaded
        case .rejected: return .rejected
        case .unauthorized(let afterRetry): return afterRetry ? .unauthorizedAfterRetry : .unauthorized
        case .networkFailed: return .networkFailed
        case .serverUnreachable: return .serverUnreachable
        case .offline: return .offline
        case .cloudReadFailed: return .cloudReadFailed
        case .refreshInFlight(let seconds):
            guard let seconds, seconds >= Self.stuckRefreshSeconds else { return .refreshInFlight }
            return .refreshStuck
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

    public var kind: Kind { reason.kind }

    /// The HTTP status the outcome carries, if any.
    public var status: Int? {
        switch self {
        case .uploaded(_, let status, _), .rejected(let status): return status
        case .unauthorized: return 401
        case .cloudReadFailed(let status): return status
        default: return nil
        }
    }

    /// Whether `error` means this Mac has no network rather than that our
    /// server could not be reached. The app's session waits for connectivity
    /// (`waitsForConnectivity`), so a Mac that is offline usually ends in
    /// `timedOut`, not `notConnectedToInternet`.
    public static func isOffline(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut,
             .dataNotAllowed, .internationalRoamingOff, .callIsActive:
            return true
        default:
            return false
        }
    }

    /// The line logged for this outcome: tokens and integers only.
    func logLine(route: UploadRoute, failuresInARow: Int) -> String {
        var fields = ["upload outcome=\(reason.rawValue)", "route=\(route.rawValue)"]
        if let status { fields.append("status=\(status)") }
        if case .uploaded(let rows, _, let afterTokenRefresh) = self {
            fields.append("rows=\(rows)")
            fields.append("token_refreshed=\(afterTokenRefresh ? 1 : 0)")
        }
        if case .refreshInFlight(let seconds) = self {
            fields.append("in_flight_s=\(seconds.map(String.init) ?? "unknown")")
        }
        fields.append("failures_in_a_row=\(failuresInARow)")
        return fields.joined(separator: " ")
    }
}

extension UploadOutcome.Reason {
    public var kind: UploadOutcome.Kind {
        switch self {
        case .uploaded:
            return .success
        case .rejected, .unauthorized, .unauthorizedAfterRetry, .networkFailed,
             .serverUnreachable, .cloudReadFailed, .refreshStuck:
            return .failure
        case .offline, .refreshInFlight, .sessionExpired, .consentDeclined, .consentUnanswered,
             .folderAccessMissing, .scanEmpty, .nothingToUpload, .authorizationChanged,
             .cancelled, .signedOut, .demo, .notAMac:
            return .expected
        }
    }
}

/// Which refresh produced the outcome (`RefreshRoute`, as a token).
public enum UploadRoute: String, Sendable {
    case cloud
    case local
    case none

    init(_ route: RefreshRoute) {
        switch route {
        case .cloud: self = .cloud
        case .localOnly: self = .local
        case .noOp: self = .none
        }
    }
}

/// What the Sentry event says. Nothing in it comes from the user's data.
struct UploadFailureReport: Equatable, Sendable {
    let reason: UploadOutcome.Reason
    let status: Int?
    let route: UploadRoute
    let failuresInARow: Int
}

/// Where repeated upload failures are reported. A protocol so the tests can
/// see every report without starting Sentry (DEBUG builds never start it).
protocol UploadReporter: Sendable {
    func reportRepeatedFailure(_ report: UploadFailureReport)
}

struct SentryUploadReporter: UploadReporter {
    /// The event's fixed name. Its message is this and the reason token, so
    /// the event carries no prose at all.
    static let eventName = "daily-usage-upload"

    func reportRepeatedFailure(_ report: UploadFailureReport) {
        SentrySDK.capture(message: "\(Self.eventName) \(report.reason.rawValue)") { scope in
            scope.setLevel(.warning)
            // Grouped by reason, a closed set, never by stack or text.
            scope.setFingerprint([Self.eventName, report.reason.rawValue])
            scope.setTag(value: report.reason.rawValue, key: "upload_reason")
            scope.setTag(value: report.status.map(String.init) ?? "none", key: "upload_status")
            scope.setTag(value: report.route.rawValue, key: "upload_route")
            scope.setTag(value: String(report.failuresInARow), key: "upload_failures_in_a_row")
            // The reason is the whole report: the network breadcrumbs of the
            // last refreshes add nothing to it.
            scope.clearBreadcrumbs()
        }
    }
}

/// Counts failures in a row, logs every outcome and reports the third failure
/// in a row, once a day at most.
@MainActor
final class UploadOutcomeTracker {
    static let failuresBeforeReport = 3
    /// The UTC day of the last report. `cli_pulse_` keeps it across a move
    /// from the App Store build to the Developer ID one
    /// (`UnsandboxedDataMigration.appOwnedKeyPrefixes`).
    static let reportedDayKey = "cli_pulse_upload_failure_reported_day"

    private let reporter: any UploadReporter
    private let defaults: UserDefaults
    private let now: () -> Date
    private let log: (String) -> Void
    private(set) var failuresInARow = 0

    init(
        reporter: any UploadReporter = SentryUploadReporter(),
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = { Date() },
        log: @escaping (String) -> Void = { uploadOutcomeLogger.notice("\($0, privacy: .public)") }
    ) {
        self.reporter = reporter
        self.defaults = defaults
        self.now = now
        self.log = log
    }

    func record(_ outcome: UploadOutcome, route: UploadRoute) {
        switch outcome.kind {
        case .success: failuresInARow = 0
        case .failure: failuresInARow += 1
        case .expected: break
        }
        log(outcome.logLine(route: route, failuresInARow: failuresInARow))

        guard outcome.kind == .failure,
              failuresInARow >= Self.failuresBeforeReport else { return }
        let today = DayKey.string(from: now(), in: DayKey.utc)
        guard defaults.string(forKey: Self.reportedDayKey) != today else { return }
        defaults.set(today, forKey: Self.reportedDayKey)
        reporter.reportRepeatedFailure(
            UploadFailureReport(
                reason: outcome.reason,
                status: outcome.status,
                route: route,
                failuresInARow: failuresInARow
            )
        )
    }
}
