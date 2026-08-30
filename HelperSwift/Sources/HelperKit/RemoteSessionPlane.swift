import Foundation

/// Whether the helper participates in the remote **session** plane.
///
/// The session plane is: pull queued commands for a managed CLI session, stream
/// terminal output back, and relay tool-permission approvals. It is retired.
///
/// WHY
/// ---
/// Measured against production on 2026-08-30:
///
///   remote_sessions               4   all the owner's own, last 2026-07-16
///   remote_session_commands       0   pending rows are never swept — a true never
///   remote_permission_requests    0
///   app_push_jobs                 0   no retention at all: the durable zero
///
/// So no non-owner has ever started a session, no command has ever been queued,
/// and the approval path — the entire safety story — has never fired once.
///
/// It could not have. Every client filters candidate targets on
/// `type == "Mac"` while the app registers Macs as `"macOS"`: 70 of the 73
/// paired Macs are invisible before the first network call. Behind that door
/// are four more unbuilt rooms (a `helper_version` frozen at `1.0.0` that
/// doubles as the capability gate, a 10-second approval TTL with no registered
/// notification category, Android FCM tokens the push path never reads, and no
/// configuration that is both live and private).
///
/// Meanwhile Anthropic and OpenAI both ship this natively and free, for exactly
/// the two providers all four `remote_sessions` rows used.
///
/// WHAT THIS DOES NOT RETIRE
/// -------------------------
/// **Machine controls** — fan target, low-power mode, keep-awake from the phone
/// (`migrate_v0.66_machine_mobile`). Those WORK and have been used: 5 rows in
/// `machine_commands`, all `done`, picked up within ~0.3 s.
///
/// They share the `remote_control_enabled` user setting, and they share the
/// word "remote", but they do not share this code path. Machine commands go
/// `RemoteMachineExecutor` → `LocalSessionControlClient.pullMachineCommands()`
/// over the UDS socket, driven from the app — never through the helper's cloud
/// task. That is why retiring the session plane here is safe, and it is the
/// reason this flag is named for the session plane rather than for "remote
/// control".
///
/// KEPT AS A FLAG RATHER THAN DELETED
/// ----------------------------------
/// Code removal and behaviour change are two reversible steps, not one. This
/// changes behaviour; the source deletion is separate, and reviewing 18k
/// deleted lines and a live-traffic change in the same diff would mean
/// reviewing neither.
public enum RemoteSessionPlane {
    /// `false` — the helper does not start its cloud task.
    ///
    /// Flipping this back to `true` restores the previous behaviour exactly,
    /// which is the point of shipping the retirement this way first.
    public static let isEnabled = false

    /// Whether the daemon should start its cloud task at all.
    ///
    /// The decision lives HERE rather than inline in `main.swift`, because
    /// `main.swift` is an executable target with no test bundle — the same gap
    /// that let the Swarm tab ship "dark" and visible for thirty releases. A
    /// predicate a test cannot reach is a predicate nobody has checked.
    public static func shouldStartCloudTask(isPaired: Bool) -> Bool {
        isEnabled && isPaired
    }

    /// Why the cloud task is not running, for an operator reading the log.
    /// "Retired" and "unpaired" are different facts and must not print the
    /// same line — confusing them is how a real outage gets read as a config
    /// problem.
    public static func startupNotice(isPaired: Bool) -> String {
        if !isEnabled {
            return "cloud sync retired (remote sessions withdrawn; machine controls unaffected)"
        }
        return isPaired ? "cloud sync active" : "unpaired — cloud sync skipped"
    }
}
