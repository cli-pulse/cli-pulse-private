import Foundation
import Network

/// The one place that turns a remote-control failure into words the user
/// can act on.
///
/// Every screen in `LANRemoteScreens` used to render `"\(error)"` straight
/// into the phone's UI. In an app that ships six languages that meant
/// untranslated English at best, and at worst the literal
/// `POSIXErrorCode(rawValue: 61): Connection refused` — which names the
/// errno and not one thing the user could do about it.
///
/// Deliberately NOT behind `#if os(iOS)`. The screens that call it are,
/// and CI runs no iOS tests, so a mapper living beside them could only
/// ever be pinned by source guards. Here it is ordinary code with ordinary
/// tests that actually run — see `LANRemoteFailureTextTests`.
///
/// The detail strings are not dropped, they are just not shown: callers
/// keep them for logs. Nothing here interpolates an `Error` into its
/// result, and a test asserts that for every case.
public enum LANRemoteFailureText {

    /// Words for the user. Always localised, never an error description.
    public static func message(for error: Error) -> String {
        if let e = error as? LANSessionControlClient.ConnectError {
            return message(for: e)
        }
        if let e = error as? LANPairingSession.Failure {
            return message(for: e)
        }
        if let e = error as? SessionControlError {
            return message(for: e)
        }
        if let e = error as? LANLinkChannelError {
            return message(for: e)
        }
        if error is CancellationError {
            return L10n.remote.disconnected
        }
        if let e = error as? NWError {
            switch LANSessionControlClient.ConnectError.reason(for: e) {
            case .keyRejected: return L10n.remote.errPairingLost
            case .unreachable, .cancelled: return L10n.remote.errMacUnreachable
            case .other: return L10n.remote.errUnexpected
            }
        }
        return L10n.remote.errUnexpected
    }

    static func message(for error: LANSessionControlClient.ConnectError) -> String {
        switch error {
        case .handshakeFailed(let reason, _):
            switch reason {
            case .keyRejected: return L10n.remote.errPairingLost
            case .unreachable, .cancelled: return L10n.remote.errMacUnreachable
            case .other: return L10n.remote.errUnexpected
            }
        case .unexpectedNegotiation:
            // Not lumped in with "can't connect": the handshake SUCCEEDED
            // and produced something other than the pinned forward-secret
            // suite. That is a security signal and deserves its own words.
            return L10n.remote.errInsecureConnection
        case .timeout:
            return L10n.remote.errMacUnreachable
        }
    }

    /// The transport itself failing. This is what the terminal's fallthrough
    /// catch actually receives when Wi-Fi drops or the Mac sleeps mid-session:
    /// `LANLinkChannel` wraps every `NWConnection` failure as
    /// `receiveFailed("\(e)")`, and the type conforms to `Error, Equatable`
    /// only — no `CustomStringConvertible` — so interpolating it yields the
    /// reflected Swift form, errno and all.
    static func message(for error: LANLinkChannelError) -> String {
        switch error {
        case .closed, .sendFailed, .receiveFailed:
            // Not the generic fallback: a dropped link is a REACHABILITY
            // failure, and "check the Mac is awake" is the one useful thing
            // to say. The wrapped detail stays for logs.
            return L10n.remote.errMacUnreachable
        case .framing:
            // The bytes arrived and did not parse — a version or corruption
            // problem, not a reachability one. Saying "wake the Mac" here
            // would send the user to fix the wrong thing.
            return L10n.remote.errUnexpected
        }
    }

    static func message(for error: LANPairingSession.Failure) -> String {
        switch error {
        case .rejected:  return L10n.remote.errPairingDeclined
        case .expired:   return L10n.remote.qrExpired
        case .transport, .channelClosed: return L10n.remote.errMacUnreachable
        case .noExporter, .badExchange, .protocolViolation:
            return L10n.remote.pairingFailed
        }
    }

    static func message(for error: SessionControlError) -> String {
        switch error {
        case .localControlOff:   return L10n.remote.controlOffOnMac
        case .notControllable:   return L10n.remote.watchOnlyLink
        case .sessionNotFound:   return L10n.remote.sessionEnded
        case .approvalExpired:   return L10n.remote.approvalExpired
        case .helperNotRunning:  return L10n.remote.helperDown
        case .timeout, .disconnected: return L10n.remote.errMacUnreachable
        case .unauthenticated:   return L10n.remote.errPairingLost
        case .versionMismatch, .notImplemented:
            return L10n.remote.errMacNeedsUpdate
        case .spawnFailed, .attachFailed:
            return L10n.remote.startFailed
        case .processNotFound:
            return L10n.remote.sessionEnded
        case .processProtected, .processNotPermitted, .approvalNotAllowed:
            return L10n.remote.watchOnlyLink
        case .rateLimited, .approvalLimitReached:
            return L10n.remote.errTooFast
        // Exhaustive on purpose, with no `default`: a new case must be
        // given words here rather than silently inheriting a generic one.
        case .runtimeRestricted, .invalidResponse, .internalError,
             .approvalNotFound, .approvalAlreadyResolved,
             .approvalCapabilityInvalid:
            return L10n.remote.errUnexpected
        }
    }
}
