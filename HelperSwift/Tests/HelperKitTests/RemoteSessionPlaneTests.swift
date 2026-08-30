import XCTest
@testable import HelperKit

/// Phase C1 — the remote SESSION plane is retired on the helper side.
///
/// The decision under test used to be an inline `if cloudCfg.isPaired` in
/// `main.swift`, an executable target with no test bundle. That is the same
/// shape that let the Swarm tab ship "dark" and visible for thirty releases:
/// a predicate a test cannot reach is a predicate nobody has checked.
final class RemoteSessionPlaneTests: XCTestCase {

    /// The retirement itself. Paired is the case that matters — an unpaired
    /// helper never started the task anyway, so asserting only that would pass
    /// with the flag in either position.
    func test_aPairedHelperDoesNotStartTheCloudTask() {
        XCTAssertFalse(RemoteSessionPlane.isEnabled)
        XCTAssertFalse(
            RemoteSessionPlane.shouldStartCloudTask(isPaired: true),
            "a paired helper must not poll remote_helper_pull_commands once a second"
        )
    }

    /// Vacuity guard, and the negative control's anchor: with the flag flipped
    /// back to `true` this expression is what would return `true`, so the test
    /// above is testing the flag and not the pairing check.
    func test_theDecisionIsTheConjunctionItClaimsToBe() {
        XCTAssertFalse(RemoteSessionPlane.shouldStartCloudTask(isPaired: false))
        // `isEnabled && isPaired` — with isEnabled false, both inputs give
        // false; the asymmetry only appears when the flag is flipped, which is
        // exactly what the documented negative control does.
        XCTAssertEqual(
            RemoteSessionPlane.shouldStartCloudTask(isPaired: true),
            RemoteSessionPlane.isEnabled && true
        )
    }

    /// "Retired" and "unpaired" are different facts. Printing the same line for
    /// both is how a deliberate withdrawal gets read as a pairing problem —
    /// the confidently-wrong-status class this project keeps paying for.
    func test_theStartupNoticeDistinguishesRetiredFromUnpaired() {
        let paired = RemoteSessionPlane.startupNotice(isPaired: true)
        let unpaired = RemoteSessionPlane.startupNotice(isPaired: false)

        XCTAssertTrue(paired.contains("retired"))
        XCTAssertEqual(paired, unpaired, "while retired, pairing is irrelevant to the reason")
        XCTAssertTrue(paired.contains("machine controls unaffected"),
                      "an operator must not read this as machine controls going away too")
    }
}

/// `CloudShareArm` is always unattached now — the daemon never builds a
/// `RemoteAgentCloud` — so the verb it backs must say WHY correctly.
final class CloudShareArmRetirementTests: XCTestCase {

    /// An unattached arm must refuse, not crash and not hang. This was already
    /// true (it guards on `current()`), but the retirement makes the unattached
    /// path the ONLY path, so it stops being an edge case and becomes the
    /// contract.
    func test_anUnattachedArmRefusesRatherThanHanging() {
        let arm = CloudShareArm()
        let (ok, message) = arm.setShared("session-1", true)

        XCTAssertFalse(ok)
        XCTAssertFalse(message.isEmpty)
    }

    /// "Retired" and "not paired" are different facts. Reporting the second for
    /// the first sends the user to re-pair a Mac that is already paired — the
    /// confidently-wrong-status class this project keeps paying for.
    func test_theRefusalNamesTheRetirementNotPairing() {
        let (_, message) = CloudShareArm().setShared("session-1", true)

        XCTAssertTrue(message.contains("withdrawn"),
                      "expected the retirement to be named; got: \(message)")
        XCTAssertFalse(message.contains("not paired"),
                       "blaming pairing for a retirement sends the user to fix the wrong thing")
    }

    /// `unshareAllBlocking` on an unattached arm must return immediately. It is
    /// wired to the local-control OFF switch, and a wedged 10-second wait there
    /// would make turning the feature off feel broken.
    func test_unshareAllReturnsImmediatelyWhenUnattached() {
        let start = Date()
        CloudShareArm().unshareAllBlocking(timeout: 10)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0,
                          "an unattached arm must not wait on a semaphore that nothing will signal")
    }
}
