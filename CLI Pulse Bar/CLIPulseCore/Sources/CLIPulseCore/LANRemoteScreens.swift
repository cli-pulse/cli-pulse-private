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
//   LANMacSessionsView  — connected to one Mac, lists its sessions
//   LANTerminalScreen   — one session, watch-only, xterm.js
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

            let steady = browser.macs.filter { !$0.isPairingService }
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
                        HStack {
                            Image(systemName: "desktopcomputer")
                            VStack(alignment: .leading) {
                                Text(peer.displayName)
                                Text(peer.pairedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(L10n.remote.forget, role: .destructive) {
                                LANPairingStore.remove(peerID: peer.id)
                                peers = LANPairingStore.peers()
                            }
                            .buttonStyle(.borderless)
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
                for _ in 0..<40 {   // ~4 s
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

public struct LANMacSessionsView: View {
    let mac: LANMacBrowser.DiscoveredMac
    let peer: LANPairing.PairedPeer

    @State private var client: LANSessionControlClient?
    @State private var sessions: [SessionControlSummary] = []
    @State private var hello: LANHelloInfo?
    @State private var status: String = ""
    @State private var error: String?

    public init(mac: LANMacBrowser.DiscoveredMac, peer: LANPairing.PairedPeer) {
        self.mac = mac
        self.peer = peer
    }

    public var body: some View {
        List {
            Section {
                HStack {
                    Circle().fill(client == nil ? Color.secondary : Color.green).frame(width: 8, height: 8)
                    Text(status)
                    Spacer()
                    Text(L10n.remote.readOnly).font(.caption).foregroundStyle(.secondary)
                }
                if let hello, !hello.helperReachable {
                    Text(L10n.remote.helperDown).foregroundStyle(.orange)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            Section(L10n.remote.sessions) {
                if sessions.isEmpty, client != nil {
                    Text(L10n.remote.noSessions).foregroundStyle(.secondary)
                }
                ForEach(sessions) { s in
                    if let client {
                        NavigationLink {
                            LANTerminalScreen(client: client, session: s)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(s.clientLabel ?? s.id).lineLimit(1)
                                Text("\(s.provider) · \(s.status)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(peer.displayName)
        .refreshable { await refresh() }
        .task { await connect() }
        .onDisappear { client?.close(); client = nil }
    }

    private func connect() async {
        status = L10n.remote.connecting
        do {
            let c = try await LANSessionControlClient.connect(to: mac.endpoint, peer: peer)
            c.onDisconnect = { _ in Task { @MainActor in status = L10n.remote.disconnected; client = nil } }
            client = c
            _ = try await c.hello()
            hello = c.helloInfo
            status = L10n.remote.connected
            await refresh()
        } catch {
            status = L10n.remote.disconnected
            self.error = "\(error)"
        }
    }

    private func refresh() async {
        guard let client else { return }
        do { sessions = try await client.listSessions(); error = nil }
        catch { self.error = "\(error)" }
    }
}

// MARK: - Terminal (watch-only)

public struct LANTerminalScreen: View {
    let client: LANSessionControlClient
    let session: SessionControlSummary
    @State private var status: String = ""
    @State private var latencyMs: Int?

    public init(client: LANSessionControlClient, session: SessionControlSummary) {
        self.client = client
        self.session = session
    }

    public var body: some View {
        VStack(spacing: 0) {
            LANTerminalHost(client: client, sessionID: session.id, status: $status, latencyMs: $latencyMs)
            HStack {
                Text(status).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let latencyMs { Text("\(latencyMs) ms").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                Text(L10n.remote.readOnly).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.bar)
        }
        .navigationTitle(session.clientLabel ?? session.id)
        .navigationBarTitleDisplayMode(.inline)
        .ignoresSafeArea(.keyboard)
    }
}

/// Hosts `RemoteTerminalView`, paints the tail snapshot, then streams
/// live output. Read-only. The latency shown is RTT/2 of an
/// application-level ping — two devices do not share a clock, so a
/// one-way timestamp would be a guess.
struct LANTerminalHost: UIViewRepresentable {
    let client: LANSessionControlClient
    let sessionID: String
    @Binding var status: String
    @Binding var latencyMs: Int?

    func makeCoordinator() -> Coordinator {
        Coordinator(client: client, sessionID: sessionID,
                    setStatus: { s in Task { @MainActor in status = s } },
                    setLatency: { ms in Task { @MainActor in latencyMs = ms } })
    }

    func makeUIView(context: Context) -> RemoteTerminalView {
        let v = RemoteTerminalView(frame: .zero)
        v.setReadOnly(true)
        v.delegate = context.coordinator
        context.coordinator.view = v
        context.coordinator.start()
        return v
    }

    func updateUIView(_ uiView: RemoteTerminalView, context: Context) {}

    static func dismantleUIView(_ uiView: RemoteTerminalView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject, RemoteTerminalViewDelegate {
        let client: LANSessionControlClient
        let sessionID: String
        let setStatus: (String) -> Void
        let setLatency: (Int?) -> Void
        weak var view: RemoteTerminalView?
        private var task: Task<Void, Never>?
        private var pingTask: Task<Void, Never>?
        private var paint = ReattachPaintBuffer()

        init(client: LANSessionControlClient, sessionID: String,
             setStatus: @escaping (String) -> Void, setLatency: @escaping (Int?) -> Void) {
            self.client = client
            self.sessionID = sessionID
            self.setStatus = setStatus
            self.setLatency = setLatency
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

                // Snapshot fetch runs alongside the stream; the buffer keeps
                // the order right regardless of which finishes first.
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
                            setStatus("Session ended")
                        case let .other(name, _) where name == "seq_gap":
                            // Lost frames: repaint from the snapshot.
                            if let tail = try? await client.getTailSnapshot(sessionId: sessionID, maxBytes: 65536) {
                                await MainActor.run { self.view?.clear(); self.view?.pushStdout(tail) }
                            }
                        default: break
                        }
                    }
                    setStatus(L10n.remote.disconnected)
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
        }

        func remoteTerminalViewDidBecomeReady(_ view: RemoteTerminalView) { view.setReadOnly(true) }
        func remoteTerminalView(_ view: RemoteTerminalView, didReceiveStdin data: String) { /* read-only */ }
        func remoteTerminalView(_ view: RemoteTerminalView, didResizeTo cols: Int, rows: Int) { /* M1 */ }
    }
}
#endif
