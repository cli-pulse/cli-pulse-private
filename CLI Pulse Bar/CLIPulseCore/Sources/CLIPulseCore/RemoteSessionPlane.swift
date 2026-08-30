import Foundation

/// Whether the app offers the remote **session** plane.
///
/// MIRRORS `HelperSwift/Sources/HelperKit/RemoteSessionPlane.swift`. The two
/// live in separate SwiftPM packages that cannot import each other, so the
/// constant is duplicated — and `RemoteSessionPlaneDriftTests` reads the helper
/// source and fails if the two values disagree. A copied constant without a
/// drift gate is how a "retired" feature comes back on one side only.
///
/// WHY RETIRED
/// -----------
/// Measured against production 2026-08-30:
///
///   remote_sessions               4   all the owner's own, last 2026-07-16
///   remote_session_commands       0   pending rows are never swept — a true never
///   remote_permission_requests    0
///   app_push_jobs                 0   no retention at all: the durable zero
///
/// No non-owner ever started a session, no command was ever queued, and the
/// approval path has never fired once. It could not have: every client filters
/// candidate targets on `type == "Mac"` while the app registers `"macOS"`, so
/// 70 of the 73 paired Macs are invisible before the first network call.
///
/// WHAT THIS IS NOT
/// ----------------
/// It is **not** the `remote_control_enabled` user setting. That setting also
/// authorises **machine controls** — fan target, low-power mode, keep-awake —
/// which work and have been used (`machine_commands`: 5 rows, all `done`,
/// picked up within ~0.3 s). The server enforces the same column on
/// `remote_app_send_machine_command`, so the setting is load-bearing for a
/// live feature and must survive this retirement.
///
/// Hence two predicates rather than one, and hence the name: this is about the
/// session plane, not about "remote control", which turned out to be two
/// features wearing one switch.
public enum RemoteSessionPlane {
    /// `false` — the app offers no remote sessions, terminals or approvals.
    ///
    /// Flipping this back to `true` restores the previous behaviour exactly,
    /// gated as before on the user's `remote_control_enabled`. That is the
    /// point of retiring behind a flag before deleting the source: behaviour
    /// change and an 18k-line deletion in one diff means reviewing neither.
    public static let isEnabled = false
}
