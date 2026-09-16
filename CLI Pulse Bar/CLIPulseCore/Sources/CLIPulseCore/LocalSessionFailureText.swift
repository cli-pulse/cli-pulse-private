import Foundation

/// User-facing text for a failure from the Mac's OWN session control — the
/// banner on the Sessions tab and the New Terminal alert.
///
/// Before this, those surfaces showed `String(describing: error)`, i.e.
/// `SessionControlError.description`: English debug text such as
/// "session not controllable from here" or "spawn failed: …", in every
/// language. `description` itself stays exactly as it is, because three other
/// things depend on it:
///   - every os_log line prints it, and logs should stay English and greppable;
///   - `LANLinkAgentSession` puts it on the LAN wire, and
///     `LANSessionControlClient` compares that wire text BY PREFIX;
///   - `SessionControlClientTests` pins its wording.
/// So this maps the case to words, and `description` is untouched.
///
/// WHY NOT `LANRemoteFailureText`
/// That type exists and has the same shape, but it is written from the
/// iPhone's point of view: "This Mac lets this iPhone watch only", "This Mac no
/// longer recognises this iPhone". Shown on the Mac about the Mac's own helper,
/// those sentences are wrong. The keys reused below are only the ones whose
/// wording is genuinely perspective-neutral; the rest are Mac-perspective keys
/// added for this.
public enum LocalSessionFailureText {

    /// Every catch site that feeds the banner receives a plain `Error`, so this
    /// takes one. Anything that is not a `SessionControlError` gets the generic
    /// line rather than its own `localizedDescription`, which for most error
    /// types here is Foundation's "The operation couldn't be completed."
    public static func message(for error: Error) -> String {
        guard let control = error as? SessionControlError else {
            return L10n.remote.errUnexpected
        }
        return message(for: control)
    }

    public static func message(for error: SessionControlError) -> String {
        switch error {
        case .helperNotRunning:
            return L10n.sessions.helperNotRunningDetail
        case .runtimeRestricted:
            return L10n.sessions.errRuntimeRestricted
        case .unauthenticated:
            return L10n.sessions.errUnauthenticated
        case .versionMismatch, .notImplemented:
            return L10n.sessions.errHelperNeedsUpdate
        case .localControlOff:
            // Names the toggle by its own localized title, so the message and
            // the switch the user has to find cannot drift apart.
            return L10n.sessions.actionHelperUnavailable(L10n.sessions.localFastPathTitle)
        case .timeout, .disconnected:
            return L10n.sessions.errHelperConnectionLost
        case .sessionNotFound:
            return L10n.remote.sessionEnded
        case .notControllable:
            return L10n.sessions.errNotControllable
        case .approvalNotFound, .approvalExpired, .approvalAlreadyResolved:
            return L10n.sessions.errApprovalGone
        case .approvalNotAllowed:
            return L10n.sessions.approvalSessionNotOwned
        case .approvalLimitReached:
            return L10n.remote.errTooFast
        case .spawnFailed, .attachFailed:
            return L10n.remote.startFailed
        case .processNotFound:
            return L10n.machine.killErrNotFound
        case .processProtected:
            return L10n.machine.killErrProtected
        case .processNotPermitted:
            return L10n.machine.killErrNotPermitted
        case .rateLimited:
            return L10n.machine.killErrRateLimited
        // The associated detail is already in os_log at every call site; it is
        // not shown, because it is unlocalized protocol text. No `default:` —
        // a new case must be given words here rather than inheriting a generic
        // line silently.
        case .invalidResponse, .internalError, .approvalCapabilityInvalid:
            return L10n.remote.errUnexpected
        }
    }
}
