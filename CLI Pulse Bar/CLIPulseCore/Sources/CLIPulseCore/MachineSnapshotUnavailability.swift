#if os(macOS)
import Foundation

/// v1.44 — why the Machine tab has no snapshot.
///
/// Every `getMachineSnapshot()` throw used to collapse into one message,
/// "Helper not reachable — machine health needs the CLI Pulse helper running".
/// That sentence is false for the case that actually happens in the field, and
/// it happens to every user whose socket owner is the app-bundled helper:
///
///   - `get_machine_snapshot` lives ONLY in the `.pkg` Python helper
///     (`cli_pulse_helper.py` + `machine_collector.py`, ~600 lines of sensor
///     reading). The bundled Swift helper does not implement it.
///   - So the helper answers, correctly and promptly, with
///     `unknown_method` → `.notImplemented`.
///   - The old text then told the user their helper was not running, while
///     Settings on the same screen showed "Built-in · v1.30.0 ✓" from a
///     perfectly successful `hello`. Two panes of one window contradicting each
///     other, and the one that was wrong was the one offering advice.
///
/// The advice mattered: it sent people to reinstall. Installing the `.pkg` does
/// in fact restore machine health — but by luck, because that helper has the
/// method. The stated reason ("not running") was never true, so anyone who
/// checked and found the helper running would reasonably stop there.
///
/// Same failure family as the four labels fixed in #392 and the helper status
/// in #395: never assert a cause the signal cannot establish.
public enum MachineSnapshotUnavailability: Equatable, Sendable {
    /// The helper answered and does not implement `get_machine_snapshot` —
    /// i.e. the app-bundled helper owns the socket. Reachability is fine.
    case unsupportedByHelper
    /// Nothing answered: no socket, refused, timed out, or sandbox-blocked.
    case unreachable
    /// The helper answered but rejected us.
    case unauthenticated

    public init(_ error: Error) {
        switch error as? SessionControlError {
        case .notImplemented, .versionMismatch:
            self = .unsupportedByHelper
        case .unauthenticated:
            self = .unauthenticated
        default:
            self = .unreachable
        }
    }

    public var message: String {
        switch self {
        case .unsupportedByHelper: return L10n.machine.helperLacksMachineHealth
        case .unauthenticated:     return L10n.machine.helperUnauthenticated
        case .unreachable:         return L10n.machine.helperUnavailable
        }
    }

    public var iconName: String {
        switch self {
        // Not a fault and not an outage — a capability this helper simply
        // doesn't carry. Rendering it with the same "power lost" bolt as a dead
        // socket is part of what made the old state read as breakage.
        case .unsupportedByHelper: return "puzzlepiece.extension"
        case .unauthenticated:     return "lock.circle"
        case .unreachable:         return "bolt.horizontal.circle"
        }
    }
}
#endif
