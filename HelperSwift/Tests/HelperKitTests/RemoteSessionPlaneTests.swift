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
