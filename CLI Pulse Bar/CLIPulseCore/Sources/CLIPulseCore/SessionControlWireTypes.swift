import Foundation

// Session-control wire vocabulary — the types that describe what the
// helper says, independent of who is listening.
//
// WHY THIS FILE EXISTS (v1.53, remote-control M0). These declarations
// lived inside `LocalSessionControlClient.swift`, whose every line is
// wrapped in `#if os(macOS)` because the UDS client itself is macOS-only.
// That gate was correct while the Mac app was the only consumer. It is
// not correct any more: the LAN transport lets an iPhone consume the
// SAME event stream, relayed by the Mac app, so the phone needs to
// decode the same frames.
//
// They are a pure MOVE — not a rewrite. `PendingApproval`,
// `ApprovalDecision` and `LocalSessionEvent` are unchanged, and both
// `decode(from:)` implementations are pure `[String: Any]` transforms
// with no platform surface. Keeping one decoder rather than a second
// iOS copy is the point: two decoders of one wire format drift, and the
// drift shows up as a phone that silently misreads a frame the Mac reads
// correctly.
//
// The companion protocol vocabulary (`SessionControlClient`,
// `SessionControlHello`, `SessionControlSummary`, `SessionControlError`,
// `SessionControlErrorMapping`) already lives ungated in
// `SessionControlClient.swift` — this file finishes that job for the
// event surface.

/// Phase 3 Iter 2B: structured local approval row. Backed by the
/// helper's `ApprovalRegistry` and surfaced to the UI through both
/// `subscribe_events` (push) and `get_pending_approvals` (snapshot).
///
/// **Security state.** This row drives the inline Approve / Reject
/// controls in the macOS Sessions tab. It is created exclusively by
/// `hook_create_approval` on the helper's UDS surface (which requires
/// the per-session capability token); PTY output text NEVER produces
/// one. The macOS UI MUST gate the Approve / Reject buttons on the
/// presence of a `PendingApproval` for the row's session — never on a
/// regex / string match against `output_delta` payloads.
public struct PendingApproval: Sendable, Equatable, Codable, Identifiable {
    public let approvalId: String
    public let sessionId: String
    public let type: String
    public let title: String
    public let summary: String
    public let toolMetadata: [String: String]   // simplified: stringified scalars
    public let status: String                   // pending | approved | rejected | expired | cancelled
    public let createdAt: Date
    public let expiresAt: Date?

    public var id: String { approvalId }

    public init(
        approvalId: String,
        sessionId: String,
        type: String,
        title: String,
        summary: String,
        toolMetadata: [String: String],
        status: String,
        createdAt: Date,
        expiresAt: Date?
    ) {
        self.approvalId = approvalId
        self.sessionId = sessionId
        self.type = type
        self.title = title
        self.summary = summary
        self.toolMetadata = toolMetadata
        self.status = status
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    /// Decode from the helper's wire-level dict (`PendingApproval.to_dict_safe`).
    /// Returns nil on missing required fields rather than throwing — the
    /// caller treats the row as unparseable and falls through to a
    /// snapshot refresh.
    public static func decode(from raw: [String: Any]) -> PendingApproval? {
        guard
            let approvalId = raw["approval_id"] as? String,
            let sessionId = raw["session_id"] as? String,
            let status = raw["status"] as? String,
            let createdAtRaw = raw["created_at"] as? Double
        else { return nil }
        let type = (raw["type"] as? String) ?? "PermissionRequest"
        let title = (raw["title"] as? String) ?? type
        let summary = (raw["summary"] as? String) ?? ""
        var meta: [String: String] = [:]
        if let m = raw["tool_metadata"] as? [String: Any] {
            for (k, v) in m {
                if let sv = v as? String {
                    meta[k] = sv
                } else if let nv = v as? NSNumber {
                    meta[k] = nv.stringValue
                } else if let bv = v as? Bool {
                    meta[k] = bv ? "true" : "false"
                }
            }
        }
        let expiresAt: Date? = (raw["expires_at"] as? Double).map {
            Date(timeIntervalSince1970: $0)
        }
        return PendingApproval(
            approvalId: approvalId,
            sessionId: sessionId,
            type: type,
            title: title,
            summary: summary,
            toolMetadata: meta,
            status: status,
            createdAt: Date(timeIntervalSince1970: createdAtRaw),
            expiresAt: expiresAt
        )
    }
}

/// Decision the user picked. Mirrors the helper's `decide` argument.
public enum ApprovalDecision: String, Sendable, Equatable, Codable {
    case approve
    case reject
}

/// Wire-level event coming off the helper's `subscribe_events` stream.
/// Decoded by `LocalSessionControlClient.subscribeEvents`. The macOS
/// app's per-row task drains the stream and updates AppState.
///
/// Unknown event types decode as `.other(name, raw)` so a future
/// helper that adds a new event kind doesn't crash old apps.
public enum LocalSessionEvent: Sendable, Equatable {
    /// Initial snapshot frame the helper sends as the streaming ack
    /// before any live event. Lets the app catch up without a second
    /// round-trip.
    case subscribed(sessionId: String?, managedSessions: [SessionControlSummary], pendingApprovals: [PendingApproval])
    case sessionStarted(sessionId: String, provider: String, clientLabel: String?)
    case outputDelta(sessionId: String, payload: String, ts: TimeInterval)
    /// v1.30.x Phase 1b: raw (un-stripped, still redacted) terminal output —
    /// only delivered to subscribers that opted in with `raw: true` (the in-app
    /// xterm.js terminal). ANSI escapes preserved so the TUI renders.
    case outputRaw(sessionId: String, payload: String, ts: TimeInterval)
    case sessionStatus(sessionId: String, status: String)
    case sessionStopped(sessionId: String, exitCode: Int?)
    case approvalRequested(approval: PendingApproval)
    case approvalResolved(sessionId: String, approvalId: String, decision: String, status: String)
    /// Remote-control M1: the helper's delegation outcome for a session
    /// started with `claude_remote_control`.
    case sessionRemoteControl(sessionId: String, status: String, url: String?, reason: String?)
    case heartbeat(ts: TimeInterval)
    case error(code: String, message: String)
    case other(name: String, raw: [String: Any])

    public static func == (lhs: LocalSessionEvent, rhs: LocalSessionEvent) -> Bool {
        switch (lhs, rhs) {
        case (.subscribed(let a, let b, let c), .subscribed(let d, let e, let f)):
            return a == d && b == e && c == f
        case (.sessionStarted(let a, let b, let c), .sessionStarted(let d, let e, let f)):
            return a == d && b == e && c == f
        case (.outputDelta(let a, let b, _), .outputDelta(let d, let e, _)):
            return a == d && b == e
        case (.outputRaw(let a, let b, _), .outputRaw(let d, let e, _)):
            return a == d && b == e
        case (.sessionStatus(let a, let b), .sessionStatus(let c, let d)):
            return a == c && b == d
        case (.sessionStopped(let a, let b), .sessionStopped(let c, let d)):
            return a == c && b == d
        case (.approvalRequested(let a), .approvalRequested(let b)):
            return a == b
        case (.approvalResolved(let a, let b, let c, let d),
              .approvalResolved(let e, let f, let g, let h)):
            return a == e && b == f && c == g && d == h
        case (.sessionRemoteControl(let a, let b, let c, let d), .sessionRemoteControl(let e, let f, let g, let h)):
            return a == e && b == f && c == g && d == h
        case (.heartbeat, .heartbeat):
            return true
        case (.error(let a, let b), .error(let c, let d)):
            return a == c && b == d
        case (.other(let a, _), .other(let b, _)):
            return a == b
        default:
            return false
        }
    }

    /// Decode from a helper-side event dict. Returns nil for the
    /// initial-ack ok envelope shape (which is decoded separately
    /// by the streaming consumer because it's wrapped in {"ok": true,
    /// "result": {...}} rather than being a bare event).
    public static func decode(from raw: [String: Any]) -> LocalSessionEvent? {
        let name = (raw["event"] as? String) ?? ""
        let ts = (raw["ts"] as? Double) ?? Date().timeIntervalSince1970
        let sessionId = (raw["session_id"] as? String) ?? ""
        switch name {
        case "session_started":
            return .sessionStarted(
                sessionId: sessionId,
                provider: (raw["provider"] as? String) ?? "claude",
                clientLabel: raw["client_label"] as? String
            )
        case "output_delta":
            return .outputDelta(
                sessionId: sessionId,
                payload: (raw["payload"] as? String) ?? "",
                ts: ts
            )
        case "output_raw":
            return .outputRaw(
                sessionId: sessionId,
                payload: (raw["payload"] as? String) ?? "",
                ts: ts
            )
        case "session_status":
            return .sessionStatus(
                sessionId: sessionId,
                status: (raw["status"] as? String) ?? ""
            )
        case "session_stopped":
            return .sessionStopped(
                sessionId: sessionId,
                exitCode: raw["exit_code"] as? Int
            )
        case "approval_requested":
            guard let inner = raw["approval"] as? [String: Any],
                  let approval = PendingApproval.decode(from: inner) else {
                return .other(name: name, raw: raw)
            }
            return .approvalRequested(approval: approval)
        case "approval_resolved":
            return .approvalResolved(
                sessionId: sessionId,
                approvalId: (raw["approval_id"] as? String) ?? "",
                decision: (raw["decision"] as? String) ?? "",
                status: (raw["status"] as? String) ?? ""
            )
        case "session_remote_control":
            return .sessionRemoteControl(
                sessionId: sessionId,
                status: (raw["status"] as? String) ?? "",
                url: raw["url"] as? String,
                reason: raw["reason"] as? String
            )
        case "heartbeat":
            return .heartbeat(ts: ts)
        case "error":
            return .error(
                code: (raw["code"] as? String) ?? "",
                message: (raw["message"] as? String) ?? ""
            )
        case "":
            return nil
        default:
            return .other(name: name, raw: raw)
        }
    }
}
