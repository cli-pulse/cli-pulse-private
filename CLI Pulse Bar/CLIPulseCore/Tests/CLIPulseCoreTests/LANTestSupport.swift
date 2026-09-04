import XCTest
@testable import CLIPulseCore

/// Shared scripted `SessionEventStreaming` for the LAN test suites. Every
/// control method XCTFails: M0 is read-only, and reaching one of them
/// from any test is a boundary breach, not a stub gap.

class FakeStreamingBackend: SessionEventStreaming, @unchecked Sendable {
    let lock = NSLock()
    var helperReachable = true
    var localControl = true
    var sessions: [SessionControlSummary] = [
        SessionControlSummary(id: "s1", provider: "claude", clientLabel: "proj", status: "running"),
    ]
    var tail = Data("$ echo hi\nhi\n".utf8)
    var continuations: [AsyncThrowingStream<LocalSessionEvent, Error>.Continuation] = []
    var localControlChecks = 0

    func hello() async throws -> SessionControlHello {
        guard helperReachable else { throw SessionControlError.helperNotRunning }
        return SessionControlHello(protocolVersion: 1, supportedMethods: [],
                                   capabilities: .iter2bLocal, helperVersion: "1.30.0",
                                   implementation: "swift-bundled")
    }
    func startManagedSession(provider: String, clientLabel: String?, cwdBasename: String?, cwdHmac: String?) async throws -> SessionControlStartResult {
        XCTFail("M0 must never reach startManagedSession"); throw SessionControlError.notImplemented
    }
    func listSessions() async throws -> [SessionControlSummary] {
        guard helperReachable else { throw SessionControlError.helperNotRunning }
        return sessions
    }
    func stopSession(sessionId: String) async throws {
        XCTFail("M0 must never reach stopSession"); throw SessionControlError.notImplemented
    }
    func sendInput(sessionId: String, payload: String) async throws {
        XCTFail("M0 must never reach sendInput"); throw SessionControlError.notImplemented
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

