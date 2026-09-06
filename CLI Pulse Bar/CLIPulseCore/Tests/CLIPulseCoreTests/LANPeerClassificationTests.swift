import XCTest
@testable import CLIPulseCore

/// The plan §8 latches are the ONLY evidence for deciding whether the
/// self-built remote-control transport lives — `migrate_v0.80`'s own header
/// says "if nobody leaves the LAN, the relay should never be built at all".
/// So a latch that silently fails to fire is not a telemetry nicety; it
/// biases that decision with a number that looks like an answer.
///
/// It did fail to fire. `LANLinkAgent.accept` classified the inbound peer
/// with `LANDirectAddress.classify`, which is the ADVERTISE-side allowlist:
/// it answers "may the Mac offer this address of its own?", where excluding
/// every non-Tailscale IPv6 is correct. Measuring how a phone ARRIVED is a
/// different question, and there "not offered" is not "not a LAN".
final class LANPeerClassificationTests: XCTestCase {

    // MARK: - The regression itself

    /// An iPhone reaching the Mac over Bonjour on ordinary Wi-Fi routinely
    /// arrives on one of these. Every one of them used to score nil, so
    /// `remoteTransportUsed` was never called at all.
    func test_ipv6LocalPeersCountAsLAN() {
        for a in ["fe80::1c2d:3e4f:5a6b:7c8d",   // link-local, the common case
                  "FE80::1",                      // case-insensitive
                  "fe9f::2", "fea0::3", "feb0::4",// rest of fe80::/10
                  "fd12:3456:789a::1",            // ULA
                  "fc00::1"] {                    // fc00::/7 low half
            XCTAssertEqual(LANDirectAddress.classifyPeer(a), .lan,
                           "\(a) is a private local address and must count as LAN use")
        }
    }

    /// Pins the defect: the advertise-side function still says nil for these,
    /// which is correct for ITS question. If someone ever "simplifies" the two
    /// back into one, this fails and says why.
    func test_theAdvertiseSideAllowlistStillRefusesThem_andThatIsWhyItIsNotTheClassifier() {
        for a in ["fe80::1c2d:3e4f:5a6b:7c8d", "fd12:3456:789a::1", "fc00::1"] {
            XCTAssertNil(LANDirectAddress.classify(a),
                         "the advertise-side allowlist changed meaning; \(a) must stay un-offered")
            XCTAssertNotNil(LANDirectAddress.classifyPeer(a),
                            "the two functions have been collapsed again — the latch will stop firing")
        }
    }

    // MARK: - Tailnet still wins, in both address families

    func test_tailnetIsStillTailnetAndIsNotSwallowedByTheULARule() {
        // fd7a:115c:a1e0 is inside fc00::/7, so the ULA rule would claim it if
        // the Tailscale check did not come first. That would relabel every
        // tailnet arrival as LAN and answer plan question 1 backwards.
        XCTAssertEqual(LANDirectAddress.classifyPeer("fd7a:115c:a1e0::1"), .tailnet)
        XCTAssertEqual(LANDirectAddress.classifyPeer("FD7A:115C:A1E0:AB12::9"), .tailnet)
        XCTAssertEqual(LANDirectAddress.classifyPeer("100.64.0.1"), .tailnet)
        XCTAssertEqual(LANDirectAddress.classifyPeer("100.127.255.254"), .tailnet)
    }

    func test_ipv4PrivateRangesAreUnchanged() {
        for a in ["192.168.1.117", "10.0.0.5", "172.16.0.1", "172.31.255.255"] {
            XCTAssertEqual(LANDirectAddress.classifyPeer(a), .lan, a)
        }
        XCTAssertEqual(LANDirectAddress.classifyPeer("172.15.0.1"), nil, "172.15 is public")
        XCTAssertEqual(LANDirectAddress.classifyPeer("172.32.0.1"), nil, "172.32 is public")
        XCTAssertEqual(LANDirectAddress.classifyPeer("100.63.0.1"), nil, "just below the CGNAT range")
        XCTAssertEqual(LANDirectAddress.classifyPeer("100.128.0.1"), nil, "just above the CGNAT range")
    }

    // MARK: - What must stay uncounted, and why

    /// Loopback is the owner's own iOS Simulator. Counting it would put the
    /// development rig into the fleet evidence the plan reads.
    func test_loopbackIsNotAPhoneOnANetwork() {
        XCTAssertNil(LANDirectAddress.classifyPeer("127.0.0.1"))
        XCTAssertNil(LANDirectAddress.classifyPeer("::1"))
    }

    /// A global v6 peer IS often the same Wi-Fi, but is indistinguishable
    /// from one anywhere on the internet. Guessing would write a made-up
    /// number into the one place the plan reads for a decision.
    func test_globalAddressesStayUnclassifiedRatherThanGuessed() {
        XCTAssertNil(LANDirectAddress.classifyPeer("2001:db8:85a3::8a2e:370:7334"))
        XCTAssertNil(LANDirectAddress.classifyPeer("8.8.8.8"))
    }

    func test_garbageDoesNotCrashOrGetCounted() {
        for a in ["", "not-an-address", "1.2.3", "1.2.3.4.5", "999.1.1.1", ":::"] {
            XCTAssertNil(LANDirectAddress.classifyPeer(a), a)
        }
    }

    // MARK: - The wiring, which CI cannot otherwise reach

    /// `LANLinkAgent.accept` is the only caller. A source guard because the
    /// trigger needs a real inbound `NWConnection`.
    func test_theAgentClassifiesThePeerWithTheMeasurementFunction() throws {
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let src = try String(
            contentsOf: root.appendingPathComponent("Sources/CLIPulseCore/LANLinkAgent.swift"),
            encoding: .utf8)
        XCTAssertTrue(src.contains("LANDirectAddress.classifyPeer(host)"),
                      "the latch is back on the advertise-side allowlist — IPv6 LAN arrivals stop counting")
        XCTAssertFalse(src.contains("LANDirectAddress.classify(host)"),
                       "the old call is still there")
    }
}
