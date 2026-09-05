#if os(macOS)
import XCTest
@testable import CLIPulseCore

/// Found on hardware 2026-09-05 from the owner's screenshots: after
/// Forget, the peer list emptied (1 paired → 0 paired) but the green
/// "<phone> is paired" card stayed on screen — the UI kept asserting a
/// pairing that no longer existed. This repo's most frequent defect class
/// is copy outliving the feature; this is one of them.
@MainActor
final class LANForgetClearsResultTests: XCTestCase {

    private func agent() -> LANLinkAgent {
        LANLinkAgent(backend: FakeStreamingBackend(), displayName: "Test Mac")
    }

    func testForgettingThePhoneTheResultCardNamesClearsThatCard() {
        let a = agent()
        a.setPairingStateForTesting(.succeeded(peerName: "Probe iPhone"))
        a.forget(peerID: "probe-1")
        XCTAssertEqual(a.pairing, .idle, "the success card outlived the pairing it describes")
    }

    func testForgetAllAlsoClearsIt() {
        let a = agent()
        a.setPairingStateForTesting(.succeeded(peerName: "Probe iPhone"))
        a.forgetAll()
        XCTAssertEqual(a.pairing, .idle)
    }

    /// Negative control: Forget must NOT cancel a pairing that is still in
    /// flight for a DIFFERENT phone — that would make forgetting one phone
    /// silently abort another's approval.
    func testForgetLeavesAnInFlightPairingAlone() {
        let a = agent()
        a.setPairingStateForTesting(.awaitingApproval(sas: "123456", peerName: "Other iPhone"))
        a.forget(peerID: "probe-1")
        XCTAssertEqual(a.pairing, .awaitingApproval(sas: "123456", peerName: "Other iPhone"))

        a.setPairingStateForTesting(.showingQR(url: "clipulse://pair?x", expiresAt: Date(timeIntervalSince1970: 1)))
        a.forget(peerID: "probe-1")
        XCTAssertEqual(a.pairing, .showingQR(url: "clipulse://pair?x", expiresAt: Date(timeIntervalSince1970: 1)))
    }

    /// A failure message is also about a pairing attempt that is over, so
    /// Forget clears it too rather than leaving a stale red line.
    func testForgetClearsAStaleFailure() {
        let a = agent()
        a.setPairingStateForTesting(.failed("QR code expired"))
        a.forget(peerID: "probe-1")
        XCTAssertEqual(a.pairing, .idle)
    }
}
#endif
