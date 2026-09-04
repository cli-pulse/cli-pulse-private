import XCTest
@testable import CLIPulseCore

/// Shared scripted `SessionControlling` for the LAN test suites. Control
/// methods RECORD their arguments; a test that expects the boundary to
/// hold asserts `controlCalls` is empty. (M0's version XCTFailed on any
/// control call; M1 lets a permitted peer through, so the record is the
/// evidence either way.)
class FakeStreamingBackend: SessionControlling, @unchecked Sendable {
    let lock = NSLock()
    var helperReachable = true
    var localControl = true
    var sessions: [SessionControlSummary] = [
        SessionControlSummary(id: "s1", provider: "claude", clientLabel: "proj", status: "running"),
    ]
    var tail = Data("$ echo hi\nhi\n".utf8)
    var continuations: [AsyncThrowingStream<LocalSessionEvent, Error>.Continuation] = []
    var localControlChecks = 0
    var controlCalls: [String] = []
    var pendingApprovals: [PendingApproval] = []
    var approveError: Error?
    var startResult = SessionControlStartResult(sessionId: "new-1")
    var providerAvailability = ["claude", "gemini"]
    var claudeRemoteControl: [String: String]? = ["supported": "true", "policy": "allowed", "auth": "oauth"]
    /// Artificial latency for `listSessions` (liveness tests).
    var listDelay: TimeInterval = 0

    private func record(_ s: String) { lock.lock(); controlCalls.append(s); lock.unlock() }
    var recordedControlCalls: [String] { lock.lock(); defer { lock.unlock() }; return controlCalls }

    func hello() async throws -> SessionControlHello {
        guard helperReachable else { throw SessionControlError.helperNotRunning }
        return SessionControlHello(protocolVersion: 1, supportedMethods: [],
                                   capabilities: .iter2bLocal, providerAvailability: providerAvailability,
                                   helperVersion: "1.30.0", implementation: "swift-bundled",
                                   claudeRemoteControl: claudeRemoteControl)
    }
    func startManagedSession(provider: String, clientLabel: String?, cwdBasename: String?, cwdHmac: String?) async throws -> SessionControlStartResult {
        try await startManagedSession(provider: provider, clientLabel: clientLabel, cwd: nil, claudeRemoteControl: false)
    }
    func startManagedSession(provider: String, clientLabel: String?, cwd: String?, claudeRemoteControl: Bool) async throws -> SessionControlStartResult {
        record("start \(provider) label=\(clientLabel ?? "-") cwd=\(cwd ?? "-") rc=\(claudeRemoteControl)")
        return startResult
    }
    func listSessions() async throws -> [SessionControlSummary] {
        guard helperReachable else { throw SessionControlError.helperNotRunning }
        if listDelay > 0 { try await Task.sleep(nanoseconds: UInt64(listDelay * 1_000_000_000)) }
        return sessions
    }
    func stopSession(sessionId: String) async throws {
        record("stop \(sessionId)")
        guard sessions.contains(where: { $0.id == sessionId }) else { throw SessionControlError.sessionNotFound }
    }
    func sendInput(sessionId: String, payload: String) async throws {
        record("sendInput \(sessionId) \(payload)")
    }
    func sendInputRaw(sessionId: String, bytes: Data) async throws {
        record("input \(sessionId) \(String(decoding: bytes, as: UTF8.self))")
        guard sessions.contains(where: { $0.id == sessionId }) else { throw SessionControlError.sessionNotFound }
    }
    func resize(sessionId: String, cols: Int, rows: Int) async throws {
        record("resize \(sessionId) \(cols)x\(rows)")
    }
    func getPendingApprovals(sessionId: String?) async throws -> [PendingApproval] {
        pendingApprovals.filter { sessionId == nil || $0.sessionId == sessionId }
    }
    func approveAction(sessionId: String, approvalId: String, decision: ApprovalDecision, comment: String?) async throws {
        record("decide \(sessionId) \(approvalId) \(decision.rawValue)\(comment.map { " " + $0 } ?? "")")
        if let approveError { throw approveError }
    }
    func subscribeEvents(sessionId: String?) -> AsyncThrowingStream<LocalSessionEvent, Error> {
        AsyncThrowingStream { c in
            lock.lock(); continuations.append(c); lock.unlock()
            c.yield(.subscribed(sessionId: sessionId, managedSessions: sessions, pendingApprovals: []))
        }
    }
    func getTailSnapshot(sessionId: String, maxBytes: Int) async throws -> Data {
        guard sessions.contains(where: { $0.id == sessionId }) else { throw SessionControlError.sessionNotFound }
        return tail
    }
    func isLocalControlEnabled() async throws -> Bool {
        lock.lock(); localControlChecks += 1; let v = localControl; lock.unlock()
        return v
    }

    func push(_ e: LocalSessionEvent) {
        lock.lock(); let cs = continuations; lock.unlock()
        for c in cs { c.yield(e) }
    }
    func finishStreams() {
        lock.lock(); let cs = continuations; continuations = []; lock.unlock()
        for c in cs { c.finish() }
    }
}

extension PendingApproval {
    static func fixture(id: String = "a1", session: String = "s1", summary: String = "run tests",
                        meta: [String: String] = [:], status: String = "pending") -> PendingApproval {
        PendingApproval(approvalId: id, sessionId: session, type: "PermissionRequest", title: "Bash",
                        summary: summary, toolMetadata: meta, status: status,
                        createdAt: Date(timeIntervalSince1970: 1_700_000_000), expiresAt: Date(timeIntervalSince1970: 1_700_000_060))
    }
}
