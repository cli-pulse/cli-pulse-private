#if os(macOS)
import XCTest
@testable import CLIPulseCore

/// 1.63.1 — one slow Machine-tab poll must not blank the tab.
///
/// The owner saw "Can't reach the helper. Machine health needs it running."
/// flash on and off on a busy Mac while the helper was up the whole time: a
/// single reply over the client's budget mapped to `.unreachable`, and the
/// view dropped its snapshot on that first failure.
final class MachineSnapshotFailureGraceTests: XCTestCase {

    func testUnreachableIsToleratedTwiceWhileASnapshotIsShown() {
        var grace = MachineSnapshotFailureGrace()
        XCTAssertFalse(grace.recordFailure(.unreachable, hasSnapshot: true), "first slow poll keeps the snapshot")
        XCTAssertFalse(grace.recordFailure(.unreachable, hasSnapshot: true), "second keeps it too")
        XCTAssertTrue(grace.recordFailure(.unreachable, hasSnapshot: true), "third in a row shows the message")
        XCTAssertTrue(grace.recordFailure(.unreachable, hasSnapshot: true), "and it stays shown")
    }

    func testSuccessResetsTheCount() {
        var grace = MachineSnapshotFailureGrace()
        _ = grace.recordFailure(.unreachable, hasSnapshot: true)
        _ = grace.recordFailure(.unreachable, hasSnapshot: true)
        grace.recordSuccess()
        XCTAssertEqual(grace.consecutiveFailures, 0)
        XCTAssertFalse(grace.recordFailure(.unreachable, hasSnapshot: true), "a success starts the count again")
    }

    /// Nothing on screen yet: there is nothing to keep, so the reason shows at
    /// once, as before 1.63.1.
    func testFirstLoadFailureShowsAtOnce() {
        var grace = MachineSnapshotFailureGrace()
        XCTAssertTrue(grace.recordFailure(.unreachable, hasSnapshot: false))
    }

    /// These are answers from the helper, not outages; waiting would only
    /// delay a true message.
    func testDefinitiveReasonsShowAtOnce() {
        var a = MachineSnapshotFailureGrace()
        XCTAssertTrue(a.recordFailure(.unsupportedByHelper, hasSnapshot: true))
        var b = MachineSnapshotFailureGrace()
        XCTAssertTrue(b.recordFailure(.unauthenticated, hasSnapshot: true))
    }

    func testToleranceIsTwoPolls() {
        XCTAssertEqual(MachineSnapshotFailureGrace.toleratedUnreachablePolls, 2)
    }

    /// The view must actually go through the grace: a guard that is defined
    /// but never consulted would pass every test above.
    func testMachineHealthViewConsultsTheGrace() throws {
        let src = try String(contentsOf: Self.sourceFile("MachineHealthView.swift"), encoding: .utf8)
        XCTAssertTrue(src.contains("MachineSnapshotFailureGrace()"), "refreshLoop no longer creates the grace")
        XCTAssertTrue(src.contains("grace.recordFailure("), "refreshLoop no longer asks the grace before blanking the tab")
        XCTAssertTrue(src.contains("grace.recordSuccess()"), "refreshLoop no longer resets the grace on success")
    }

    private static func sourceFile(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // CLIPulseCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // CLIPulseCore
            .appendingPathComponent("Sources/CLIPulseCore/\(name)")
    }

    /// And the client gives the RPC the longer budget.
    func testMachineSnapshotUsesTheLongerReplyBudget() throws {
        let src = try String(contentsOf: Self.sourceFile("LocalSessionControlClient.swift"), encoding: .utf8)
        XCTAssertTrue(
            src.contains(#"send(method: "get_machine_snapshot", params: [:], timeoutOverride: 10)"#),
            "getMachineSnapshot is back on the default 5 s budget, which the collection's own measured 2.8-5.9 s straddles"
        )
    }
}
#endif
