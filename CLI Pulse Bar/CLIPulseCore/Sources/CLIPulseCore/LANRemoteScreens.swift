#if os(iOS)
import SwiftUI
import UIKit
import VisionKit
import Network

// Remote-control M0, iOS side. Four screens, all in CLIPulseCore so the
// iOS target needs one-line references and no pbxproj surgery:
//
//   LANNearbyMacsView   — browses Bonjour, lists Macs, routes to pair/sessions
//   LANPairingFlowView  — scan (or paste) → connect → compare code → done
//   LANMacSessionsView  — connected to one Mac, lists its sessions, starts/stops (M1)
//   LANNewSessionSheet  — provider, working directory, the claude.ai opt-in (M1)
//   LANTerminalScreen   — one session, xterm.js; input and approvals when the Mac allows (M1)
//
// Browsing starts when Nearby Macs APPEARS, not at launch — that is what
// triggers the local-network prompt, and a prompt before the user asked
// for anything is the notification-permission mistake (#519) again.

// MARK: - Nearby Macs

public struct LANNearbyMacsView: View {
    @StateObject private var browser = LANMacBrowser()
    @State private var peers: [LANPairing.PairedPeer] = []
    @State private var pairingTarget: LANMacBrowser.DiscoveredMac?
    @State private var showScanner = false

    public init() {}

    public var body: some View {
        List {
            if browser.state == .permissionDenied {
                Section {
                    Text(L10n.remote.localNetworkDenied)
                    Button(L10n.remote.openSettings) {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
            }

            let steady = browser.macs.filter { !$0.isPairingService }   // also used by the paired section below
            if steady.isEmpty, browser.state == .browsing {
                Section { Text(L10n.remote.noMacs).foregroundStyle(.secondary) }
            }

            ForEach(steady) { mac in
                let peer = peers.first { $0.id == mac.id }
                let pairingOpen = browser.pairingService(for: mac.id) != nil
                if let peer {
                    NavigationLink {
                        LANMacSessionsView(mac: mac, peer: peer)
                    } label: {
                        row(mac, subtitle: L10n.remote.paired, color: .green)
                    }
                } else {
                    Button {
                        pairingTarget = browser.pairingService(for: mac.id) ?? mac
                        showScanner = true
                    } label: {
                        row(mac, subtitle: pairingOpen ? L10n.remote.readyToPair : L10n.remote.notPaired,
                            color: pairingOpen ? .orange : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            if !peers.isEmpty {
                Section(L10n.remote.paired) {
                    ForEach(peers) { peer in
                        let discovered = steady.contains { $0.id == peer.id }
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Image(systemName: "desktopcomputer")
                                VStack(alignment: .leading) {
                                    Text(peer.displayName)
                                    Text(peer.pairedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(L10n.remote.forget, role: .destructive) {
                                    LANPairingStore.remove(peerID: peer.id)
                                    LANPeerAddressStore.remove(for: peer.id)
                                    peers = LANPairingStore.peers()
                                }
                                .buttonStyle(.borderless)
                            }
                            // M2a: Bonjour does not cross a tailnet, so a Mac
                            // that is reachable can still be undiscoverable.
                            // Offer the address route only when discovery
                            // failed — when it worked, it is the better path.
                            if !discovered {
                                NavigationLink {
                                    LANDirectConnectView(peer: peer)
                                } label: {
                                    Label(savedAddress(peer) ?? L10n.remote.connectByAddress,
                                          systemImage: "globe")
                                        .font(.caption)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(L10n.remote.nearbyMacs)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { pairingTarget = nil; showScanner = true } label: { Image(systemName: "qrcode.viewfinder") }
            }
        }
        .onAppear { peers = LANPairingStore.peers(); browser.start() }
        .onDisappear { browser.stop() }
        .sheet(isPresented: $showScanner, onDismiss: { peers = LANPairingStore.peers() }) {
            LANPairingFlowView(browser: browser, initialPayload: nil)
        }
    }

    private func savedAddress(_ peer: LANPairing.PairedPeer) -> String? {
        LANPeerAddressStore.address(for: peer.id)?.displayString
    }

    private func row(_ mac: LANMacBrowser.DiscoveredMac, subtitle: String, color: Color) -> some View {
        HStack {
            Image(systemName: "desktopcomputer").foregroundStyle(color)
            VStack(alignment: .leading) {
                Text(mac.name)
                Text(subtitle).font(.caption).foregroundStyle(color)
            }
            Spacer()
        }
    }
}

// MARK: - Connect by address (M2a, tailnet)

/// Reach a paired Mac that Bonjour cannot see — over Tailscale, a VPN, or
/// any route the two devices share. The address is a convenience, not a
/// credential: the same TLS-PSK handshake decides whether the connection
/// happens at all, so a wrong address fails to connect and tells the
/// stranger at that address nothing.
public struct LANDirectConnectView: View {
    let peer: LANPairing.PairedPeer
    @State private var typed: String = ""
    @State private var error: String?
    @State private var connecting = false
    @State private var client: LANSessionControlClient?
    @State private var mac: LANMacBrowser.DiscoveredMac?

    public init(peer: LANPairing.PairedPeer) { self.peer = peer }

    public var body: some View {
        Form {
            Section {
                TextField(L10n.remote.addressPlaceholder, text: $typed)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                Text(L10n.remote.addressHint).font(.footnote).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            }
            Section {
                Button {
                    connect()
                } label: {
                    HStack {
                        Text(L10n.remote.connectByAddress)
                        if connecting { Spacer(); ProgressView() }
                    }
                }
                .disabled(connecting || typed.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .navigationTitle(peer.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if typed.isEmpty, let saved = LANPeerAddressStore.address(for: peer.id) {
                typed = saved.displayString
            }
        }
        .navigationDestination(item: $mac) { m in
            if let client {
                LANMacSessionsView(mac: m, peer: peer, existingClient: client)
            }
        }
    }

    private func connect() {
        error = nil
        guard let parsed = try? LANDirectAddress.parse(typed) else {
            error = L10n.remote.addressInvalid
            return
        }
        connecting = true
        Task {
            do {
                let c = try await LANSessionControlClient.connect(toAddress: parsed, peer: peer)
                _ = try await c.hello()
                // Only remember an address that actually reached the Mac.
                LANPeerAddressStore.save(parsed, for: peer.id)
                client = c
                mac = LANMacBrowser.DiscoveredMac(
                    id: peer.id, name: peer.displayName, endpoint: parsed.endpoint,
                    protocolVersion: LANLinkProtocol.version, isPairingService: false)
            } catch {
                self.error = "\(error)"
            }
            connecting = false
        }
    }
}

// MARK: - Pairing flow

public struct LANPairingFlowView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var browser: LANMacBrowser
    let initialPayload: LANPairing.QRPayload?

    private enum Step: Equatable {
        case scanning
        case connecting
        case compare(sas: String, macName: String)
        case succeeded(macName: String)
        case failed(String)
    }
    @State private var step: Step = .scanning
    @State private var pasted = ""
    @State private var task: Task<Void, Never>?

    public init(browser: LANMacBrowser, initialPayload: LANPairing.QRPayload?) {
        self.browser = browser
        self.initialPayload = initialPayload
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                switch step {
                case .scanning:
                    Text(L10n.remote.scanHint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    if DataScannerViewController.isSupported, DataScannerViewController.isAvailable {
                        LANQRScanner { code in handleScanned(code) }
                            .frame(maxWidth: .infinity, maxHeight: 320)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .padding(.horizontal)
                    }
                    HStack {
                        TextField(L10n.remote.pasteHint, text: $pasted)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Button(L10n.remote.done) { handleScanned(pasted) }
                            .disabled(pasted.isEmpty)
                    }
                    .padding(.horizontal)

                case .connecting:
                    ProgressView(L10n.remote.connecting)

                case let .compare(sas, macName):
                    Text(macName).font(.headline)
                    Text(L10n.remote.compareCode)
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Text(sas)
                        .font(.system(size: 44, weight: .semibold, design: .monospaced))
                        .tracking(6)
                    Text(L10n.remote.approveOnMac)
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    ProgressView()

                case let .succeeded(macName):
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 56)).foregroundStyle(.green)
                    Text("\(L10n.remote.pairingSucceeded): \(macName)").font(.headline)
                    Button(L10n.remote.done) { dismiss() }.buttonStyle(.borderedProminent)

                case let .failed(why):
                    Image(systemName: "xmark.circle").font(.system(size: 56)).foregroundStyle(.secondary)
                    Text(L10n.remote.pairingFailed).font(.headline)
                    Text(why).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button(L10n.remote.done) { dismiss() }
                }
                Spacer()
            }
            .padding(.top)
            .navigationTitle(L10n.remote.pairWithMac)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.remote.cancel) { task?.cancel(); dismiss() }
                }
            }
        }
        .onAppear {
            browser.start()
            if let p = initialPayload { begin(p) }
        }
        .onDisappear { task?.cancel() }
    }

    private func handleScanned(_ code: String) {
        guard step == .scanning else { return }
        do { begin(try LANPairing.QRPayload.parse(code)) }
        catch { step = .failed("\(error)") }
    }

    private func begin(_ payload: LANPairing.QRPayload) {
        if payload.isExpired() { step = .failed(L10n.remote.qrExpired); return }
        step = .connecting
        task = Task {
            do {
                // The Mac advertises a pairing service for this QR. Wait
                // for Bonjour to surface it (it may already be there).
                var endpoint: NWEndpoint?
                for _ in 0..<100 {   // ~10 s — mDNS can take a few seconds to surface a new service
                    if let m = browser.pairingService(for: payload.deviceID) { endpoint = m.endpoint; break }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                guard let endpoint else { throw LANPairingSession.Failure.transport("Mac not found on this Wi-Fi") }
                let identity = try LANPairingStore.loadOrCreateIdentity()
                let channel = try await LANSessionControlClient.connectForPairing(to: endpoint, payload: payload)
                let peer = try await LANPairingSession.Client.pair(
                    channel: channel, identity: identity,
                    displayName: UIDevice.current.name, payload: payload,
                    onSAS: { sas in
                        Task { @MainActor in
                            // We do not know the Mac's name until the exchange
                            // reply; the client sets it into the record, so
                            // show the discovered service name meanwhile.
                            let name = browser.pairingService(for: payload.deviceID)?.name ?? "Mac"
                            step = .compare(sas: sas, macName: name)
                        }
                    })
                try LANPairingStore.save(peer)
                await MainActor.run { step = .succeeded(macName: peer.displayName) }
            } catch is CancellationError {
            } catch let e as LANPairingSession.Failure {
                let why: String
                switch e {
                case .rejected: why = "Declined on the Mac"
                case .expired: why = L10n.remote.qrExpired
                default: why = "\(e)"
                }
                await MainActor.run { step = .failed(why) }
            } catch {
                await MainActor.run { step = .failed("\(error)") }
            }
        }
    }
}

/// VisionKit QR scanner. `DataScannerViewController` is iOS 16+; the app
/// floor is 17. Unsupported on the Simulator — callers check
/// `isSupported`/`isAvailable` and offer the paste field.
struct LANQRScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ vc: DataScannerViewController, coordinator: Coordinator) {
        vc.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        private var fired = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }
        func dataScanner(_ scanner: DataScannerViewController, didAdd added: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !fired else { return }
            for item in added {
                if case let .barcode(b) = item, let s = b.payloadStringValue {
                    fired = true
                    onCode(s)
                    return
                }
            }
        }
    }
}

// MARK: - Sessions on one Mac

/// Owns the LAN link for the TRUE lifetime of `LANMacSessionsView`.
///
/// `.onDisappear` is the wrong hook for tearing a link down here, and the
/// cost was the whole remote terminal. SwiftUI fires `onDisappear` on this
/// screen when the terminal screen is PUSHED OVER it — and the pushed
/// screen was handed this very client. Closing there tore the link down
/// underneath the screen the user had just navigated into.
///
/// Measured on hardware 2026-09-06, in this order: `session.subscribe`
/// (all sessions) · `session.subscribe` (that session) · `session.tail` ·
/// `approvals.list` · then BOTH subscriptions cancelled. So the tail
/// snapshot painted and everything then went dead: the live stream
/// reported "disconnected", nothing updated again, and typing reached
/// nothing — the client had been closed out from under the screen using it.
///
/// A `@State`-held box is released when the screen is really popped, not
/// when a child is pushed on top of it, so `deinit` is the honest hook.
@MainActor
final class LANMacLinkOwner {
    var client: LANSessionControlClient?
    var eventsTask: Task<Void, Never>?

    deinit {
        // Both are synchronous and safe to call from `deinit`.
        eventsTask?.cancel()
        client?.close()
    }
}

public struct LANMacSessionsView: View {
    let mac: LANMacBrowser.DiscoveredMac
    let peer: LANPairing.PairedPeer

    @State private var client: LANSessionControlClient?
    @State private var sessions: [SessionControlSummary] = []
    @State private var hello: LANHelloInfo?
    @State private var status: String = ""
    @State private var error: String?
    @State private var pendingBySession: [String: Int] = [:]
    @State private var showNewSession = false
    @State private var linkOwner = LANMacLinkOwner()

    /// `existingClient` is the connection a direct (address) connect
    /// already established — reusing it avoids a second handshake and keeps
    /// the peer binding from the attempt the user just watched succeed.
    private let existingClient: LANSessionControlClient?

    public init(mac: LANMacBrowser.DiscoveredMac, peer: LANPairing.PairedPeer,
                existingClient: LANSessionControlClient? = nil) {
        self.mac = mac
        self.peer = peer
        self.existingClient = existingClient
    }

    private var controlAllowed: Bool { hello?.controlAllowed ?? false }

    public var body: some View {
        List {
            Section {
                HStack {
                    Circle().fill(client == nil ? Color.secondary : Color.green).frame(width: 8, height: 8)
                    Text(status)
                    Spacer()
                    if hello != nil, !controlAllowed {
                        Text(L10n.remote.readOnly).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let hello, !hello.helperReachable {
                    Text(L10n.remote.helperDown).foregroundStyle(.orange)
                }
                if let hello, !hello.controlAllowed {
                    Text(L10n.remote.watchOnlyLink).font(.footnote).foregroundStyle(.secondary)
                }
                if let hello, hello.claudeRemoteControlOfferable, hello.claudeRemoteControl?["auth"] == "none" {
                    Text(L10n.remote.claudeSignInHint).font(.footnote).foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            Section(L10n.remote.sessions) {
                if sessions.isEmpty, client != nil {
                    Text(controlAllowed ? L10n.remote.noSessionsControl : L10n.remote.noSessions)
                        .foregroundStyle(.secondary)
                }
                ForEach(sessions) { s in
                    if let client {
                        HStack {
                            NavigationLink {
                                LANTerminalScreen(client: client, session: s, controlAllowed: controlAllowed)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.clientLabel ?? s.id).lineLimit(1)
                                    Text("\(s.provider) · \(s.status)").font(.caption).foregroundStyle(.secondary)
                                    if let n = pendingBySession[s.id], n > 0 {
                                        Label("\(n) · \(L10n.remote.awaitingApproval)", systemImage: "hand.raised.fill")
                                            .font(.caption).foregroundStyle(.orange)
                                    }
                                }
                            }
                            if let rc = s.remoteControl, rc.isReady, let url = rc.url.flatMap(URL.init(string:)) {
                                Button {
                                    UIApplication.shared.open(url)
                                } label: {
                                    Image(systemName: "arrow.up.forward.app")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(L10n.remote.openOnClaude)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if controlAllowed {
                                Button(role: .destructive) {
                                    Task { await stop(s.id) }
                                } label: { Label(L10n.remote.stop, systemImage: "stop.fill") }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(peer.displayName)
        .toolbar {
            if controlAllowed, let client, let hello, hello.helperReachable {
                ToolbarItem(placement: .primaryAction) {
                    Button { showNewSession = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel(L10n.remote.newSession)
                        .sheet(isPresented: $showNewSession) {
                            LANNewSessionSheet(client: client, hello: hello, macID: peer.id) {
                                Task { await refresh() }
                            }
                        }
                }
            }
        }
        .refreshable { await refresh() }
        .task { await connect() }
    }

    private func connect() async {
        status = L10n.remote.connecting
        do {
            // `??` takes an autoclosure, which cannot be async — spell the
            // reuse out so the direct-connect path skips a second handshake.
            let c: LANSessionControlClient
            if let existingClient {
                c = existingClient
            } else {
                c = try await LANSessionControlClient.connect(to: mac.endpoint, peer: peer)
            }
            c.onDisconnect = { _ in Task { @MainActor in status = L10n.remote.disconnected; client = nil } }
            client = c
            linkOwner.client = c
            _ = try await c.hello()
            hello = c.helloInfo
            status = L10n.remote.connected
            await refresh()
            watchEvents(c)
        } catch {
            status = L10n.remote.disconnected
            self.error = "\(error)"
        }
    }

    private func refresh() async {
        // A dropped link left `client == nil`; pull-to-refresh is how the
        // user gets back, so reconnect here rather than no-op.
        guard let client else { await connect(); return }
        do {
            sessions = try await client.listSessions()
            error = nil
            if controlAllowed {
                let pending = try await client.getPendingApprovals(sessionId: nil)
                pendingBySession = Dictionary(grouping: pending, by: \.sessionId).mapValues(\.count)
            }
        } catch { self.error = "\(error)" }
    }

    private func stop(_ id: String) async {
        guard let client else { return }
        do { try await client.stopSession(sessionId: id); await refresh() }
        catch { self.error = "\(error)" }
    }

    /// No polling: the list changes when the Mac says so.
    private func watchEvents(_ c: LANSessionControlClient) {
        linkOwner.eventsTask?.cancel()
        linkOwner.eventsTask = Task {
            do {
                for try await ev in c.subscribeEvents(sessionId: nil) {
                    if Task.isCancelled { return }
                    switch ev {
                    case .sessionStarted, .sessionStopped, .sessionStatus, .sessionRemoteControl:
                        await refresh()
                    case let .approvalRequested(a):
                        pendingBySession[a.sessionId, default: 0] += 1
                    case let .approvalResolved(sid, _, _, _):
                        pendingBySession[sid] = max(0, (pendingBySession[sid] ?? 1) - 1)
                    default:
                        break
                    }
                }
            } catch {
                // The link's own disconnect handling covers this.
            }
        }
    }
}

// MARK: - New session

struct LANNewSessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let client: LANSessionControlClient
    let hello: LANHelloInfo
    let macID: String
    let onStarted: () -> Void

    @State private var provider: String
    @State private var cwd: String
    @State private var openOnClaude: Bool
    @State private var recent: [String]
    @State private var starting = false
    @State private var error: String?

    private static let optInKey = "cli_pulse_lan_claude_remote_control"
    private static func recentKey(_ macID: String) -> String { "cli_pulse_lan_recent_cwd_" + macID }

    init(client: LANSessionControlClient, hello: LANHelloInfo, macID: String, onStarted: @escaping () -> Void) {
        self.client = client
        self.hello = hello
        self.macID = macID
        self.onStarted = onStarted
        // Empty availability means the Mac advertised no spawnable CLI —
        // do NOT substitute a hardcoded trio and let Start fail; show the
        // real (empty) list and disable Start.
        _provider = State(initialValue: hello.providerAvailability.first ?? "")
        let recents = UserDefaults.standard.stringArray(forKey: Self.recentKey(macID)) ?? []
        _recent = State(initialValue: recents)
        _cwd = State(initialValue: recents.first ?? hello.home ?? "/")
        _openOnClaude = State(initialValue: UserDefaults.standard.bool(forKey: Self.optInKey))
    }

    private var providers: [String] { hello.providerAvailability }

    var body: some View {
        NavigationStack {
            Form {
                if providers.isEmpty {
                    Text(L10n.remote.noProviders).foregroundStyle(.secondary)
                } else {
                    Picker(L10n.remote.provider, selection: $provider) {
                        ForEach(providers, id: \.self) { Text(ProviderDisplay.displayName(for: $0)).tag($0) }
                    }
                }
                Section(L10n.remote.workingDirectory) {
                    TextField("/", text: $cwd)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    if !recent.isEmpty {
                        ForEach(recent, id: \.self) { path in
                            Button { cwd = path } label: {
                                Text(path).font(.system(.footnote, design: .monospaced)).lineLimit(1).truncationMode(.head)
                            }
                        }
                    }
                }
                if provider == "claude", hello.claudeRemoteControlOfferable {
                    Section {
                        Toggle(L10n.remote.alsoOpenOnClaude, isOn: $openOnClaude)
                        Text(L10n.remote.claudeTranscriptNotice).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle(L10n.remote.newSession)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.remote.cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.remote.start) { start() }
                        .disabled(starting || cwd.isEmpty || !cwd.hasPrefix("/") || providers.isEmpty)
                }
            }
        }
    }

    private func start() {
        starting = true
        error = nil
        let rc = provider == "claude" && hello.claudeRemoteControlOfferable && openOnClaude
        Task {
            do {
                _ = try await client.startManagedSession(provider: provider, clientLabel: UIDevice.current.name,
                                                         cwd: cwd, claudeRemoteControl: rc)
                var r = recent.filter { $0 != cwd }
                r.insert(cwd, at: 0)
                UserDefaults.standard.set(Array(r.prefix(5)), forKey: Self.recentKey(macID))
                UserDefaults.standard.set(openOnClaude, forKey: Self.optInKey)
                onStarted()
                dismiss()
            } catch {
                self.error = "\(L10n.remote.startFailed): \(error)"
                starting = false
            }
        }
    }
}

// MARK: - Terminal

public struct LANTerminalScreen: View {
    let client: LANSessionControlClient
    let session: SessionControlSummary
    let controlAllowed: Bool
    @State private var status: String = ""
    @State private var latencyMs: Int?
    @State private var approvals: [PendingApproval] = []
    @State private var expired: Set<String> = []
    @State private var controlRefused: String?

    public init(client: LANSessionControlClient, session: SessionControlSummary, controlAllowed: Bool = false) {
        self.client = client
        self.session = session
        self.controlAllowed = controlAllowed
    }

    private var canType: Bool { controlAllowed && controlRefused == nil }

    public var body: some View {
        VStack(spacing: 0) {
            if !approvals.isEmpty {
                LANApprovalsBanner(approvals: approvals, expired: expired, decide: decide)
            }
            LANTerminalHost(client: client, sessionID: session.id, canType: canType,
                            status: $status, latencyMs: $latencyMs,
                            onApprovalRequested: { a in
                                if !approvals.contains(where: { $0.approvalId == a.approvalId }) { approvals.append(a) }
                            },
                            onApprovalResolved: { aid, resolvedStatus in
                                if resolvedStatus == "expired" { expired.insert(aid) } else { approvals.removeAll { $0.approvalId == aid } }
                            },
                            onControlRefused: { why in controlRefused = why })
            HStack {
                Text(status).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let latencyMs { Text("\(latencyMs) ms").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                if let controlRefused {
                    Text(controlRefused).font(.caption).foregroundStyle(.orange)
                } else if !controlAllowed {
                    Text(L10n.remote.readOnly).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.bar)
        }
        .navigationTitle(session.clientLabel ?? session.id)
        .navigationBarTitleDisplayMode(.inline)
        .ignoresSafeArea(.keyboard)
        .task {
            guard controlAllowed else { return }
            approvals = (try? await client.getPendingApprovals(sessionId: session.id)) ?? []
        }
    }

    private func decide(_ a: PendingApproval, _ d: ApprovalDecision) {
        Task {
            do {
                try await client.approveAction(sessionId: a.sessionId, approvalId: a.approvalId, decision: d, comment: nil)
                approvals.removeAll { $0.approvalId == a.approvalId }
            } catch let e as SessionControlError where e == .approvalAlreadyResolved || e == .approvalExpired {
                expired.insert(a.approvalId)
            } catch {
                status = "\(error)"
            }
        }
    }
}

/// Pending approvals for the session, above the terminal. A row whose
/// approval expired says so and loses its buttons: the helper already
/// told Claude "no".
struct LANApprovalsBanner: View {
    let approvals: [PendingApproval]
    let expired: Set<String>
    let decide: (PendingApproval, ApprovalDecision) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(approvals) { a in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                        Text(a.title).font(.subheadline.weight(.semibold))
                        Spacer()
                        if let exp = a.expiresAt, !expired.contains(a.approvalId) {
                            Text(exp, style: .relative).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    if !a.summary.isEmpty {
                        Text(a.summary).font(.system(.footnote, design: .monospaced)).lineLimit(4)
                    }
                    if expired.contains(a.approvalId) {
                        Text(L10n.remote.approvalExpired).font(.footnote).foregroundStyle(.secondary)
                    } else {
                        HStack {
                            Button(L10n.remote.approve) { decide(a, .approve) }.buttonStyle(.borderedProminent)
                            Button(L10n.remote.reject, role: .destructive) { decide(a, .reject) }.buttonStyle(.bordered)
                        }
                    }
                }
                .padding(10)
                Divider()
            }
        }
        .background(Color.orange.opacity(0.08))
    }
}

/// Hosts `RemoteTerminalView`, paints the tail snapshot, then streams
/// live output. Input (M1) goes the way the Mac's own terminal sends it:
/// every keystroke is queued and one drain loop sends them FIFO, so two
/// quick keys cannot cross on the wire; resizes are last-wins. The
/// latency shown is RTT/2 of an application-level ping — two devices do
/// not share a clock, so a one-way timestamp would be a guess.
struct LANTerminalHost: UIViewRepresentable {
    let client: LANSessionControlClient
    let sessionID: String
    let canType: Bool
    @Binding var status: String
    @Binding var latencyMs: Int?
    let onApprovalRequested: (PendingApproval) -> Void
    let onApprovalResolved: (String, String) -> Void
    let onControlRefused: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(client: client, sessionID: sessionID, canType: canType,
                    setStatus: { s in Task { @MainActor in status = s } },
                    setLatency: { ms in Task { @MainActor in latencyMs = ms } },
                    onApprovalRequested: { a in Task { @MainActor in onApprovalRequested(a) } },
                    onApprovalResolved: { aid, st in Task { @MainActor in onApprovalResolved(aid, st) } },
                    onControlRefused: { why in Task { @MainActor in onControlRefused(why) } })
    }

    func makeUIView(context: Context) -> RemoteTerminalView {
        let v = RemoteTerminalView(frame: .zero)
        v.setReadOnly(!canType)
        v.delegate = context.coordinator
        context.coordinator.view = v
        context.coordinator.start()
        return v
    }

    func updateUIView(_ uiView: RemoteTerminalView, context: Context) {
        context.coordinator.canType = canType
        uiView.setReadOnly(!canType)
    }

    static func dismantleUIView(_ uiView: RemoteTerminalView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject, RemoteTerminalViewDelegate {
        let client: LANSessionControlClient
        let sessionID: String
        var canType: Bool
        let setStatus: (String) -> Void
        let setLatency: (Int?) -> Void
        let onApprovalRequested: (PendingApproval) -> Void
        let onApprovalResolved: (String, String) -> Void
        let onControlRefused: (String) -> Void
        weak var view: RemoteTerminalView?
        private var task: Task<Void, Never>?
        private var pingTask: Task<Void, Never>?
        private var paint = ReattachPaintBuffer()
        private var pendingStdin = Data()
        private var stdinDraining = false
        private var resizeTask: Task<Void, Never>?

        init(client: LANSessionControlClient, sessionID: String, canType: Bool,
             setStatus: @escaping (String) -> Void, setLatency: @escaping (Int?) -> Void,
             onApprovalRequested: @escaping (PendingApproval) -> Void,
             onApprovalResolved: @escaping (String, String) -> Void,
             onControlRefused: @escaping (String) -> Void) {
            self.client = client
            self.sessionID = sessionID
            self.canType = canType
            self.setStatus = setStatus
            self.setLatency = setLatency
            self.onApprovalRequested = onApprovalRequested
            self.onApprovalResolved = onApprovalResolved
            self.onControlRefused = onControlRefused
        }

        /// `ReattachPaintBuffer` order, verbatim from the Mac terminal:
        /// subscribe FIRST (so nothing emitted during attach is dropped),
        /// THEN fetch the snapshot, THEN release the held live chunks after
        /// it. All `paint` access hops to the main actor — the two tasks
        /// below would otherwise race on it.
        func start() {
            setStatus(L10n.remote.connecting)
            task = Task { [weak self] in
                guard let self else { return }
                let stream = client.subscribeEvents(sessionId: sessionID)

                Task { [weak self] in
                    guard let self else { return }
                    let tail = (try? await client.getTailSnapshot(sessionId: sessionID, maxBytes: 65536)) ?? Data()
                    await MainActor.run {
                        for write in self.paint.flush(afterSnapshot: tail) { self.view?.pushStdout(write) }
                    }
                    setStatus(L10n.remote.connected)
                }

                do {
                    for try await ev in stream {
                        switch ev {
                        case let .outputRaw(_, payload, _), let .outputDelta(_, payload, _):
                            let chunk = Data(payload.utf8)
                            await MainActor.run {
                                if let now = self.paint.intake(chunk) { self.view?.pushStdout(now) }
                            }
                        case .sessionStopped:
                            setStatus(L10n.remote.sessionEnded)
                        case let .approvalRequested(a):
                            onApprovalRequested(a)
                        case let .approvalResolved(_, aid, _, st):
                            onApprovalResolved(aid, st)
                        case let .other(name, _) where name == "seq_gap":
                            // Lost frames: repaint from the snapshot.
                            if let tail = try? await client.getTailSnapshot(sessionId: sessionID, maxBytes: 65536) {
                                await MainActor.run { self.view?.clear(); self.view?.pushStdout(tail) }
                            }
                        default: break
                        }
                    }
                    setStatus(L10n.remote.disconnected)
                } catch let e as SessionControlError where e == .localControlOff {
                    setStatus(L10n.remote.controlOffOnMac)
                } catch {
                    setStatus("\(L10n.remote.disconnected): \(error)")
                }
            }
            pingTask = Task { [weak self] in
                while let self, !Task.isCancelled {
                    let t0 = Date()
                    if (try? await client.hello()) != nil {
                        setLatency(Int(Date().timeIntervalSince(t0) * 1000 / 2))
                    }
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
        }

        func stop() {
            task?.cancel(); task = nil
            pingTask?.cancel(); pingTask = nil
            resizeTask?.cancel(); resizeTask = nil
        }

        func remoteTerminalViewDidBecomeReady(_ view: RemoteTerminalView) { view.setReadOnly(!canType) }

        func remoteTerminalView(_ view: RemoteTerminalView, didReceiveStdin data: String) {
            guard canType else { return }
            pendingStdin.append(Data(data.utf8))
            guard !stdinDraining else { return }
            stdinDraining = true
            Task { @MainActor [weak self] in await self?.drainStdin() }
        }

        @MainActor
        private func drainStdin() async {
            defer { stdinDraining = false }
            while !pendingStdin.isEmpty {
                let chunk = pendingStdin
                pendingStdin.removeAll(keepingCapacity: true)
                do {
                    try await client.sendInputRaw(sessionId: sessionID, bytes: chunk)
                } catch let e as SessionControlError where e == .notControllable || e == .localControlOff {
                    canType = false
                    view?.setReadOnly(true)
                    onControlRefused(e == .localControlOff ? L10n.remote.controlOffOnMac : L10n.remote.watchOnlyLink)
                    pendingStdin.removeAll()
                } catch {
                    setStatus("\(error)")
                }
            }
        }

        func remoteTerminalView(_ view: RemoteTerminalView, didResizeTo cols: Int, rows: Int) {
            guard canType else { return }
            resizeTask?.cancel()
            resizeTask = Task { [client, sessionID] in
                try? await client.resize(sessionId: sessionID, cols: cols, rows: rows)
            }
        }
    }
}
#endif
