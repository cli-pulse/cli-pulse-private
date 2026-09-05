import Foundation
import Network
import Combine

/// Finds Macs advertising `_clipulse._tcp` on the local network.
///
/// Platform-neutral: the Mac app could browse too (a second Mac on the
/// LAN is a valid peer in a later milestone). On iOS, browsing needs
/// `NSLocalNetworkUsageDescription` and `NSBonjourServices` in the
/// Info.plist — without the second, iOS silently returns nothing rather
/// than an error, so `state` distinguishes "browsing, none found" from
/// "the OS refused".
///
/// Start it when the user opens the screen that lists Macs, NOT at app
/// launch: the first browse is what triggers the local-network
/// permission prompt, and a prompt that appears before the user has
/// asked for anything is the notification-permission mistake (#519)
/// all over again.
@MainActor
public final class LANMacBrowser: ObservableObject {

    public struct DiscoveredMac: Identifiable, Equatable, Hashable, Sendable {
        /// The Mac's local pairing identity (`did` in TXT).
        public let id: String
        /// Bonjour service name — human-readable, chosen by the Mac.
        public let name: String
        public let endpoint: NWEndpoint
        public let protocolVersion: Int
        /// True for the short-lived pairing service a Mac advertises
        /// while its QR is on screen.
        public let isPairingService: Bool

        public init(id: String, name: String, endpoint: NWEndpoint, protocolVersion: Int, isPairingService: Bool) {
            self.id = id
            self.name = name
            self.endpoint = endpoint
            self.protocolVersion = protocolVersion
            self.isPairingService = isPairingService
        }
    }

    public enum State: Equatable, Sendable {
        case idle
        case browsing
        /// The OS declined — on iOS this is the local-network permission.
        case permissionDenied
        case failed(String)
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var macs: [DiscoveredMac] = []

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "cli-pulse.lan.browser")

    public init() {}

    public func start() {
        guard browser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = false
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: LANLinkProtocol.bonjourServiceType, domain: nil),
                          using: params)
        b.stateUpdateHandler = { [weak self] st in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch st {
                case .ready: self.state = .browsing
                case .failed(let e): self.state = Self.isPermissionDenial(e) ? .permissionDenied : .failed("\(e)")
                case .waiting(let e): self.state = Self.isPermissionDenial(e) ? .permissionDenied : .failed("\(e)")
                case .cancelled: self.state = .idle
                default: break
                }
            }
        }
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let macs = results.compactMap(Self.parse)
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            Task { @MainActor [weak self] in self?.macs = macs }
        }
        browser = b
        b.start(queue: queue)
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        macs = []
        state = .idle
    }

    /// The service for `deviceID` currently in pairing mode, if any.
    public func pairingService(for deviceID: String) -> DiscoveredMac? {
        macs.first { $0.id == deviceID && $0.isPairingService }
    }

    /// The steady service for `deviceID`, if any.
    public func steadyService(for deviceID: String) -> DiscoveredMac? {
        macs.first { $0.id == deviceID && !$0.isPairingService }
    }

    // MARK: - parsing

    static func parse(_ r: NWBrowser.Result) -> DiscoveredMac? {
        guard case let .service(name, _, _, _) = r.endpoint,
              case let .bonjour(txt) = r.metadata,
              let did = txt[LANLinkProtocol.TXTKey.deviceID], !did.isEmpty else {
            return nil
        }
        let pv = Int(txt[LANLinkProtocol.TXTKey.protocolVersion] ?? "") ?? 0
        let pairing = txt[LANLinkProtocol.TXTKey.mode] == LANLinkProtocol.TXTMode.pairing
        return DiscoveredMac(id: did, name: name, endpoint: r.endpoint,
                             protocolVersion: pv, isPairingService: pairing)
    }

    static func isPermissionDenial(_ e: NWError) -> Bool {
        // -65570 = kDNSServiceErr_PolicyDenied: the local-network prompt
        // was declined (or the plist keys are missing).
        if case let .dns(code) = e, code == -65570 { return true }
        return false
    }
}
