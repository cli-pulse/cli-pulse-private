import Combine
import Foundation

// 1.60: "Last cloud upload" on the Mac (Settings › General › Connection).
//
// 59-01 found that a Mac could stop uploading for weeks and nothing on it
// would say so: a failed upload left a log line (`UploadOutcome`) and, after
// three in a row, a Sentry event, but nothing on screen. This keeps two
// facts from those outcomes and shows them where the connection's status
// already is: when this Mac's last upload reached the account, and whether
// the last attempt since then failed (and the HTTP status it got, if any).
//
// Only times, a reason token from a closed set and an HTTP status are kept,
// in this Mac's defaults. Nothing from the user's data.

/// The upload status as it is kept and shown.
public struct CloudUploadStatus: Equatable, Sendable {
    /// When the rows last reached the server.
    public var lastSuccess: Date?
    /// The last failed attempt, if it came after the last success.
    public var lastFailure: Failure?

    public struct Failure: Equatable, Sendable {
        public var at: Date
        public var reason: UploadOutcome.Reason
        public var status: Int?
    }

    public init(lastSuccess: Date? = nil, lastFailure: Failure? = nil) {
        self.lastSuccess = lastSuccess
        self.lastFailure = lastFailure
    }

    /// The status after `outcome`, at `now`. A success clears the failure; a
    /// failure is kept until the next success. An outcome that tried nothing
    /// (nothing to send, "Not now", signed out) or did not conclude (offline,
    /// a refresh still running, replaced) changes nothing: it says nothing
    /// about the uploads.
    public func recording(_ outcome: UploadOutcome, at now: Date) -> CloudUploadStatus {
        var next = self
        switch outcome.kind {
        case .success:
            next.lastSuccess = now
            next.lastFailure = nil
        case .failure:
            next.lastFailure = Failure(at: now, reason: outcome.reason, status: outcome.status)
        case .finished, .inconclusive:
            break
        }
        return next
    }

    // MARK: - What the row says

    /// The row's value: when the last upload reached the account ("5m ago"),
    /// or "Not yet".
    public func lastUploadText(now: Date) -> String {
        lastSuccess.map { RelativeTime.format($0, now: now) } ?? L10n.settings.lastUploadNever
    }

    /// The line under it when the last attempt failed, else nil.
    public func failureText(now: Date) -> String? {
        guard let lastFailure else { return nil }
        let when = RelativeTime.format(lastFailure.at, now: now)
        if let status = lastFailure.status {
            return L10n.settings.lastUploadFailedHTTP(status, when)
        }
        return L10n.settings.lastUploadFailed(when)
    }
}

/// Keeps `CloudUploadStatus` in this Mac's defaults and publishes it to the
/// Settings row. `UploadOutcomeTracker` records into it.
@MainActor
public final class CloudUploadStatusStore: ObservableObject {
    public static let shared = CloudUploadStatusStore()

    /// `cli_pulse_` keeps them across a move from the App Store build to the
    /// Developer ID one (`UnsandboxedDataMigration.appOwnedKeyPrefixes`).
    static let successKey = "cli_pulse_upload_last_success"
    static let failureAtKey = "cli_pulse_upload_last_failure_at"
    static let failureReasonKey = "cli_pulse_upload_last_failure_reason"
    static let failureStatusKey = "cli_pulse_upload_last_failure_status"

    @Published public private(set) var status: CloudUploadStatus
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.status = Self.load(from: defaults)
    }

    func record(_ outcome: UploadOutcome, at now: Date) {
        let next = status.recording(outcome, at: now)
        guard next != status else { return }
        status = next
        Self.save(next, to: defaults)
    }

    /// Forgets both, for the next account: a sign-out or a switch of account.
    public func reset() {
        status = CloudUploadStatus()
        Self.save(status, to: defaults)
    }

    static func load(from defaults: UserDefaults) -> CloudUploadStatus {
        var status = CloudUploadStatus()
        if let success = defaults.object(forKey: successKey) as? Double {
            status.lastSuccess = Date(timeIntervalSince1970: success)
        }
        if let at = defaults.object(forKey: failureAtKey) as? Double,
           let token = defaults.string(forKey: failureReasonKey),
           let reason = UploadOutcome.Reason(rawValue: token) {
            status.lastFailure = .init(
                at: Date(timeIntervalSince1970: at),
                reason: reason,
                status: defaults.object(forKey: failureStatusKey) as? Int)
        }
        return status
    }

    static func save(_ status: CloudUploadStatus, to defaults: UserDefaults) {
        if let success = status.lastSuccess {
            defaults.set(success.timeIntervalSince1970, forKey: successKey)
        } else {
            defaults.removeObject(forKey: successKey)
        }
        if let failure = status.lastFailure {
            defaults.set(failure.at.timeIntervalSince1970, forKey: failureAtKey)
            defaults.set(failure.reason.rawValue, forKey: failureReasonKey)
            if let code = failure.status {
                defaults.set(code, forKey: failureStatusKey)
            } else {
                defaults.removeObject(forKey: failureStatusKey)
            }
        } else {
            for key in [failureAtKey, failureReasonKey, failureStatusKey] { defaults.removeObject(forKey: key) }
        }
    }
}
