import Foundation
import Network

/// Remote-control M2a (Tailnet) — reaching a paired Mac by address instead
/// of by Bonjour discovery.
///
/// ── Why this is small ──
/// The Mac's listener was never Wi-Fi-only. Nothing constrains its
/// interfaces (`LANTransportSecurity.parameters` sets only
/// `includePeerToPeer = false`, which disables AWDL), so a paired phone on
/// a tailnet or VPN could already complete a handshake — if it knew where
/// to knock. Two things were missing, and both are here: a port that
/// survives a relaunch, and a way to say which address to show and to type.
///
/// ── Why this needs no new security argument ──
/// Authentication is unchanged: TLS-PSK admits only a phone holding a
/// paired key, and M1's binding proof still decides control. Typing the
/// wrong host does not leak anything — the handshake simply fails, which is
/// the outcome the plan's threat table already predicts. Nothing here opens
/// a port that was closed; it makes an address usable.
public enum LANDirectAddress {

    /// The port the Mac tries first, so a printed address stays valid
    /// across relaunches. Chosen in the IANA dynamic range and not a
    /// registered service.
    public static let defaultPort: UInt16 = 51_000

    public struct Parsed: Equatable, Sendable {
        public let host: String
        public let port: UInt16

        /// What the user sees and what round-trips through `parse`.
        /// IPv6 is bracketed so the port separator is unambiguous.
        public var displayString: String {
            host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
        }

        public var endpoint: NWEndpoint {
            .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .init(integerLiteral: 51_000))
        }
    }

    public enum ParseError: Error, Equatable {
        case empty
        case malformed(String)
        case badPort(String)
    }

    /// Parse what a person typed or pasted: `host`, `host:port`,
    /// `[v6]:port`, a bare IPv6, optionally with our own URL scheme in
    /// front. Deliberately strict — a value that parses must produce an
    /// endpoint worth attempting, so a mistake surfaces as "that is not an
    /// address" and not as a confusing TLS failure later.
    public static func parse(_ raw: String) throws -> Parsed {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { throw ParseError.empty }
        for scheme in ["clipulse://", "http://", "https://"] where s.lowercased().hasPrefix(scheme) {
            s = String(s.dropFirst(scheme.count))
        }
        guard !s.contains("/"), !s.contains(" ") else { throw ParseError.malformed(raw) }

        var host = s
        var port = defaultPort

        if s.hasPrefix("[") {                       // [v6] or [v6]:port
            guard let close = s.firstIndex(of: "]") else { throw ParseError.malformed(raw) }
            host = String(s[s.index(after: s.startIndex)..<close])
            let rest = String(s[s.index(after: close)...])
            if !rest.isEmpty {
                guard rest.hasPrefix(":") else { throw ParseError.malformed(raw) }
                port = try parsePort(String(rest.dropFirst()), raw)
            }
        } else if s.filter({ $0 == ":" }).count > 1 {
            host = s                                 // bare IPv6: no port possible
        } else if let colon = s.lastIndex(of: ":") {
            host = String(s[s.startIndex..<colon])
            port = try parsePort(String(s[s.index(after: colon)...]), raw)
        }

        guard !host.isEmpty, host.allSatisfy({ $0.isLetter || $0.isNumber || ".:-_".contains($0) }) else {
            throw ParseError.malformed(raw)
        }
        return Parsed(host: host, port: port)
    }

    private static func parsePort(_ s: String, _ raw: String) throws -> UInt16 {
        guard let n = Int(s), (1...65_535).contains(n) else { throw ParseError.badPort(raw) }
        return UInt16(n)
    }

    // MARK: - Which address to show on the Mac

    public struct InterfaceAddress: Equatable, Sendable {
        public let interface: String
        public let address: String
        public init(interface: String, address: String) {
            self.interface = interface
            self.address = address
        }
    }

    public enum Kind: Equatable, Sendable {
        /// Tailscale's ranges — reachable from anywhere on the tailnet.
        case tailnet
        /// RFC 1918 — reachable on the same network only.
        case lan
    }

    public struct Candidate: Equatable, Sendable {
        public let address: String
        public let kind: Kind
    }

    /// The address worth printing: a tailnet one if there is one, else a
    /// private LAN one. Loopback, link-local and PUBLIC addresses are never
    /// offered — advertising a public address would invite exposing the
    /// listener to the internet, which this feature does not ask for.
    /// Pure, so the interface walk stays out of the tests.
    public static func preferredAddress(from addrs: [InterfaceAddress]) -> Candidate? {
        let classified = addrs.compactMap { a -> Candidate? in
            classify(a.address).map { Candidate(address: a.address, kind: $0) }
        }
        return classified.first { $0.kind == .tailnet } ?? classified.first { $0.kind == .lan }
    }

    static func classify(_ address: String) -> Kind? {
        let a = address.lowercased()
        // Tailscale IPv6 ULA prefix.
        if a.hasPrefix("fd7a:115c:a1e0") { return .tailnet }
        if a.contains(":") { return nil }   // other IPv6: not offered

        let parts = a.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return nil }
        // Tailscale CGNAT 100.64.0.0/10 — exactly 100.64…100.127.
        if parts[0] == 100, (64...127).contains(parts[1]) { return .tailnet }
        if parts[0] == 10 { return .lan }
        if parts[0] == 172, (16...31).contains(parts[1]) { return .lan }
        if parts[0] == 192, parts[1] == 168 { return .lan }
        return nil   // loopback, link-local, public: not offered
    }

    /// The Mac's current addresses. Uses `getifaddrs`; separated from
    /// `preferredAddress` so the choice is testable without real hardware.
    public static func localInterfaceAddresses() -> [InterfaceAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var out: [InterfaceAddress] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = ptr.pointee.ifa_addr else { continue }
            let family = sa.pointee.sa_family
            guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { continue }
            guard (ptr.pointee.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &buf, socklen_t(buf.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            var host = String(cString: buf)
            if let pct = host.firstIndex(of: "%") { host = String(host[host.startIndex..<pct]) }
            out.append(InterfaceAddress(interface: String(cString: ptr.pointee.ifa_name), address: host))
        }
        return out
    }
}

/// The listener port, remembered so a printed address survives a relaunch.
/// M0/M1 took whatever port the system handed out, which changed on every
/// launch — fine for Bonjour, useless for an address a user typed once.
public enum LANListenerPort {
    public static let defaultsKey = "cli_pulse_lan_listener_port"

    /// A remembered port, or nil when there is none or it is not one we
    /// would ever have chosen. A stored 0 would mean "any port" and would
    /// silently invalidate the address the user was shown.
    public static func remembered(in defaults: UserDefaults = .standard) -> UInt16? {
        let raw = defaults.integer(forKey: defaultsKey)
        guard (1024...65_535).contains(raw) else { return nil }
        return UInt16(raw)
    }

    public static func remember(_ port: Int, in defaults: UserDefaults = .standard) {
        guard (1024...65_535).contains(port) else {
            defaults.removeObject(forKey: defaultsKey)
            return
        }
        defaults.set(port, forKey: defaultsKey)
    }
}


/// Where a phone last reached a given Mac when Bonjour could not find it.
/// Phone-side only, one entry per paired Mac, in UserDefaults — it is a
/// convenience, not a credential: the PSK still decides whether the
/// connection is possible at all.
public enum LANPeerAddressStore {
    static func key(_ peerID: String) -> String { "cli_pulse_lan_addr_" + peerID }

    public static func address(for peerID: String, in defaults: UserDefaults = .standard) -> LANDirectAddress.Parsed? {
        guard let raw = defaults.string(forKey: key(peerID)) else { return nil }
        return try? LANDirectAddress.parse(raw)
    }

    public static func save(_ address: LANDirectAddress.Parsed, for peerID: String, in defaults: UserDefaults = .standard) {
        defaults.set(address.displayString, forKey: key(peerID))
    }

    public static func remove(for peerID: String, in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(peerID))
    }
}
