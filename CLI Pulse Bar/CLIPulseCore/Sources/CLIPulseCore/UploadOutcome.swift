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
//   * after `failuresBeforeReport` failures in a row, one Sentry event. The
//     SDK gives it the envelope every event of ours has (the stack trace of
//     the calling thread, debug images, device, OS and app context, and its
//     random installation ID as `user.id`). What this code adds is only the
//     reason, the HTTP status, the route and the failure count as tags, the
//     reason as the fingerprint and in the message, and no breadcrumbs: no
//     user of ours and no text of ours. `SentryUploadReporter.configure` is
//     the whole of it, pinned by `SentryUploadReporterScopeTests`. At most
//     one a day per install (the daily mark is in UserDefaults), to keep
//     Sentry quota use bounded.
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
    /// The upload failed without an answer (after `dataWithRetry`'s own
    /// retries), for a reason other than the two below.
    case networkFailed
    /// The cloud route's health check failed, for a reason other than the
    /// two below: nothing was read or sent.
    case serverUnreachable
    /// The system says this Mac has no network (`networkOutcome`): a laptop
    /// on a train, not a fault, so it is logged and never reported.
    case offline
    /// A request timed out or lost its connection (`networkOutcome`). That
    /// is a Mac without a network as often as a server that did not answer,
    /// and the error cannot tell which, so the reason claims neither and is
    /// never reported.
    case noAnswer
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
        case noAnswer = "no_answer"
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
        /// The rows reached the server. Resets the count.
        case success
        /// The refresh ran to its end and had nothing to send, by design (no
        /// scan, "Not now", signed out, Demo). It did not fail, so the row of
        /// failures ends here: resets the count. Without this, a Mac that
        /// never uploads (no provider found) would collect three failures
        /// over weeks of clean refreshes and report them as "in a row".
        case finished
        /// Adds one.
        case failure
        /// The refresh did not run to its end, or the state changed under it
        /// (no network, another refresh in flight, replaced, signed out or
        /// expired mid-refresh): it says nothing either way, so the count
        /// stays as it is.
        case inconclusive
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
        case .noAnswer: return .noAnswer
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

    /// What `error` says about the network, when it says anything: nil
    /// leaves the caller's own reason (`networkFailed`, `serverUnreachable`,
    /// `cloudReadFailed`).
    ///
    /// Only the codes with which the system says there is no network are
    /// `offline`. `timedOut` and `networkConnectionLost` are `noAnswer`: the
    /// app's session waits for connectivity (`waitsForConnectivity`, 15 s a
    /// request, 30 s a resource), so a Mac with no network ends in
    /// `timedOut`, and so does a server that accepts the connection and never
    /// answers. A pooler or load balancer that drops the connection ends in
    /// `networkConnectionLost`, like a Wi-Fi that drops. Calling either
    /// "offline" would claim a cause the error cannot tell apart.
    public static func networkOutcome(_ error: Error) -> UploadOutcome? {
        guard let urlError = error as? URLError else { return nil }
        switch urlError.code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive:
            return .offline
        case .timedOut, .networkConnectionLost:
            return .noAnswer
        default:
            return nil
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
        case .consentDeclined, .consentUnanswered, .folderAccessMissing, .scanEmpty,
             .nothingToUpload, .signedOut, .demo:
            return .finished
        case .rejected, .unauthorized, .unauthorizedAfterRetry, .networkFailed,
             .serverUnreachable, .cloudReadFailed, .refreshStuck:
            return .failure
        // `notAMac` is never recorded (iPhone, iPad and Watch upload nothing).
        case .offline, .noAnswer, .refreshInFlight, .sessionExpired, .authorizationChanged,
             .cancelled, .notAMac:
            return .inconclusive
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
        SentrySDK.capture(message: Self.message(for: report)) { scope in
            Self.configure(scope, for: report)
        }
    }

    static func message(for report: UploadFailureReport) -> String {
        "\(eventName) \(report.reason.rawValue)"
    }

    /// Everything this event adds to the SDK's standard envelope. sentry-cocoa
    /// hands `capture(message:block:)` a copy of the current scope, so this
    /// changes the one event only (crash reports keep their breadcrumbs).
    /// PRIVACY.md describes exactly this; `SentryUploadReporterScopeTests`
    /// pins it.
    static func configure(_ scope: Scope, for report: UploadFailureReport) {
        scope.setLevel(.warning)
        // Grouped by reason, a closed set, never by stack or text.
        scope.setFingerprint([eventName, report.reason.rawValue])
        scope.setTag(value: report.reason.rawValue, key: "upload_reason")
        scope.setTag(value: report.status.map(String.init) ?? "none", key: "upload_status")
        scope.setTag(value: report.route.rawValue, key: "upload_route")
        scope.setTag(value: String(report.failuresInARow), key: "upload_failures_in_a_row")
        // The reason is the whole report: the network breadcrumbs of the
        // last refreshes add nothing to it.
        scope.clearBreadcrumbs()
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
    /// 1.60: what Settings › General shows as "Last cloud upload".
    let statusStore: CloudUploadStatusStore
    private(set) var failuresInARow = 0

    /// `statusStore`: the shared one with the standard defaults (the app),
    /// else one on `defaults` (a test's own suite).
    init(
        reporter: any UploadReporter = SentryUploadReporter(),
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = { Date() },
        log: @escaping (String) -> Void = { uploadOutcomeLogger.notice("\($0, privacy: .public)") },
        statusStore: CloudUploadStatusStore? = nil
    ) {
        self.reporter = reporter
        self.defaults = defaults
        self.now = now
        self.log = log
        self.statusStore = statusStore
            ?? (defaults === UserDefaults.standard ? .shared : CloudUploadStatusStore(defaults: defaults))
    }

    func record(_ outcome: UploadOutcome, route: UploadRoute) {
        statusStore.record(outcome, at: now())
        switch outcome.kind {
        case .success, .finished: failuresInARow = 0
        case .failure: failuresInARow += 1
        case .inconclusive: break
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
