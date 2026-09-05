import XCTest
import Network
@testable import CLIPulseCore

/// Remote-control M2a (Tailnet) — "connect by address".
///
/// The Mac's listener never was Wi-Fi-only: nothing constrains its
/// interfaces (`includePeerToPeer = false` only disables AWDL), so a
/// paired phone on a VPN could already reach it if it knew where. What was
/// missing is a durable address to type: the port changed on every launch
/// and nothing showed it. These are the pure pieces of that.
final class LANDirectAddressTests: XCTestCase {

    // MARK: - Parsing what a user types

    func testParsesHostPortAndBareHost() throws {
        let a = try LANDirectAddress.parse("100.101.102.103:51000")
        XCTAssertEqual(a.host, "100.101.102.103")
        XCTAssertEqual(a.port, 51000)
        // A bare host uses the default port so a user need not know it.
        let b = try LANDirectAddress.parse("my-mac.tail1234.ts.net")
        XCTAssertEqual(b.host, "my-mac.tail1234.ts.net")
        XCTAssertEqual(b.port, LANDirectAddress.defaultPort)
        // Whitespace and a stray scheme a user may paste.
        XCTAssertEqual(try LANDirectAddress.parse("  100.64.1.2:9  ").port, 9)
        XCTAssertEqual(try LANDirectAddress.parse("clipulse://100.64.1.2:9").host, "100.64.1.2")
    }

    func testParsesIPv6InBrackets() throws {
        let a = try LANDirectAddress.parse("[fd7a:115c:a1e0::1]:51000")
        XCTAssertEqual(a.host, "fd7a:115c:a1e0::1")
        XCTAssertEqual(a.port, 51000)
        // Bare IPv6 without brackets is ambiguous with the port separator;
        // accept it only when it cannot be read as host:port.
        XCTAssertEqual(try LANDirectAddress.parse("fd7a:115c:a1e0::1").host, "fd7a:115c:a1e0::1")
    }

    func testRefusesGarbage() {
        // Negative controls. Each must throw, not silently produce an
        // endpoint that fails later with a confusing TLS error.
        for bad in ["", "   ", ":51000", "host:", "host:0", "host:70000", "host:-1",
                    "host:abc", "a b.com:1", "[fd7a::1:51000", "http://x.com/path"] {
            XCTAssertThrowsError(try LANDirectAddress.parse(bad), bad)
        }
    }

    func testRoundTripsThroughItsDisplayForm() throws {
        for s in ["100.64.1.2:51000", "[fd7a:115c::1]:51000", "mac.ts.net:51000"] {
            XCTAssertEqual(try LANDirectAddress.parse(s).displayString, s)
        }
    }

    func testBecomesAnNWEndpoint() throws {
        let a = try LANDirectAddress.parse("100.64.1.2:51000")
        guard case let .hostPort(host, port) = a.endpoint else { return XCTFail("not hostPort") }
        XCTAssertEqual(port.rawValue, 51000)
        XCTAssertEqual("\(host)", "100.64.1.2")
    }

    // MARK: - Which of the Mac's addresses to show

    private func addr(_ s: String) -> LANDirectAddress.InterfaceAddress {
        LANDirectAddress.InterfaceAddress(interface: "en0", address: s)
    }

    func testPrefersATailscaleAddressOverALANOne() {
        // Tailscale hands out 100.64.0.0/10 (CGNAT). That is the one worth
        // showing: it is reachable from anywhere the user's tailnet is.
        let picked = LANDirectAddress.preferredAddress(from: [addr("192.168.1.50"), addr("100.101.102.103")])
        XCTAssertEqual(picked?.address, "100.101.102.103")
        XCTAssertEqual(picked?.kind, .tailnet)
    }

    func testFallsBackToPrivateLANWhenThereIsNoTailnet() {
        for lan in ["192.168.1.50", "10.0.0.7", "172.16.5.4", "172.31.255.254"] {
            let picked = LANDirectAddress.preferredAddress(from: [addr(lan)])
            XCTAssertEqual(picked?.address, lan, lan)
            XCTAssertEqual(picked?.kind, .lan, lan)
        }
    }

    func testIgnoresLoopbackLinkLocalAndPublicAddresses() {
        // Negative control: loopback and link-local are useless to a phone;
        // a public address would invite exposing the listener to the
        // internet, which this feature never asks for.
        let picked = LANDirectAddress.preferredAddress(from: [
            addr("127.0.0.1"), addr("169.254.10.1"), addr("::1"), addr("8.8.8.8"), addr("172.32.0.1"),
        ])
        XCTAssertNil(picked, "picked \(String(describing: picked))")
    }

    func testTailscaleRangeBoundariesAreExact() {
        // 100.64.0.0 – 100.127.255.255 only. 100.63.x and 100.128.x are
        // ordinary public space and must not be advertised as a tailnet.
        XCTAssertEqual(LANDirectAddress.preferredAddress(from: [addr("100.64.0.0")])?.kind, .tailnet)
        XCTAssertEqual(LANDirectAddress.preferredAddress(from: [addr("100.127.255.255")])?.kind, .tailnet)
        XCTAssertNil(LANDirectAddress.preferredAddress(from: [addr("100.63.255.255")]))
        XCTAssertNil(LANDirectAddress.preferredAddress(from: [addr("100.128.0.0")]))
    }

    func testIPv6TailscaleRangeIsRecognised() {
        // Tailscale's IPv6 ULA prefix.
        XCTAssertEqual(LANDirectAddress.preferredAddress(from: [addr("fd7a:115c:a1e0::1234")])?.kind, .tailnet)
    }

    // MARK: - A durable port

    func testRememberedPortIsReusedAndValidated() {
        let d = UserDefaults(suiteName: "lan-port-test-\(UUID().uuidString)")!
        XCTAssertNil(LANListenerPort.remembered(in: d), "nothing remembered yet")
        LANListenerPort.remember(51000, in: d)
        XCTAssertEqual(LANListenerPort.remembered(in: d), 51000)
        // Out-of-range or privileged values are not honoured: a stored 0
        // would silently mean "any port" and break the printed address.
        for bad in [0, 80, 1023, 65536, -1] {
            LANListenerPort.remember(bad, in: d)
            XCTAssertNil(LANListenerPort.remembered(in: d), "\(bad)")
        }
    }

    // MARK: - Per-peer saved address

    func testSavedAddressRoundTripsAndOnlyKeepsWhatParses() {
        let d = UserDefaults(suiteName: "lan-addr-test-\(UUID().uuidString)")!
        XCTAssertNil(LANPeerAddressStore.address(for: "p1", in: d))
        let a = try! LANDirectAddress.parse("100.101.102.103:51000")
        LANPeerAddressStore.save(a, for: "p1", in: d)
        XCTAssertEqual(LANPeerAddressStore.address(for: "p1", in: d), a)
        // A value that no longer parses reads back as nothing rather than
        // as a half-usable endpoint.
        d.set("not an address", forKey: LANPeerAddressStore.key("p1"))
        XCTAssertNil(LANPeerAddressStore.address(for: "p1", in: d))
        LANPeerAddressStore.save(a, for: "p1", in: d)
        LANPeerAddressStore.remove(for: "p1", in: d)
        XCTAssertNil(LANPeerAddressStore.address(for: "p1", in: d))
    }

    func testAddressesAreKeyedPerPeer() {
        let d = UserDefaults(suiteName: "lan-addr-test2-\(UUID().uuidString)")!
        LANPeerAddressStore.save(try! LANDirectAddress.parse("10.0.0.1:1"), for: "a", in: d)
        LANPeerAddressStore.save(try! LANDirectAddress.parse("10.0.0.2:2"), for: "b", in: d)
        XCTAssertEqual(LANPeerAddressStore.address(for: "a", in: d)?.port, 1)
        XCTAssertEqual(LANPeerAddressStore.address(for: "b", in: d)?.port, 2)
        LANPeerAddressStore.remove(for: "a", in: d)
        XCTAssertNil(LANPeerAddressStore.address(for: "a", in: d))
        XCTAssertNotNil(LANPeerAddressStore.address(for: "b", in: d), "removing one peer must not clear another")
    }

    func testDefaultPortIsInTheDynamicRangeAndStable() {
        // The printed address is only durable if this constant is. If it
        // ever changes, every address a user wrote down goes stale.
        XCTAssertEqual(LANDirectAddress.defaultPort, 51_000)
        XCTAssertTrue((49_152...65_535).contains(Int(LANDirectAddress.defaultPort)))
    }
}
