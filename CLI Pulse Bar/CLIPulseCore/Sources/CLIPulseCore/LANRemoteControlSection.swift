#if os(macOS)
import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins

/// Settings card for remote control on the Mac: the on/off switch, the
/// listener's observed state, a "Pair an iPhone" button that opens the
/// QR sheet, and the paired phones with a Forget button each.
///
/// Lives in CLIPulseCore like `MachineHealthView` and `FolderAccessView`
/// so the app target needs a one-line reference and no pbxproj entry.
public struct LANRemoteControlSection: View {
    @ObservedObject private var agent: LANLinkAgent
    @State private var showPairing = false

    public init(agent: LANLinkAgent) {
        self.agent = agent
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "iphone.and.arrow.forward")
                    .font(.system(size: 11))
                    .foregroundStyle(PulseTheme.accent)
                Text("Remote Control")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                statusBadge
            }

            if let reason = LANLinkAgent.unavailabilityReason {
                Text(reason)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Toggle(isOn: Binding(get: { agent.isEnabled }, set: { agent.isEnabled = $0 })) {
                    Text("Let paired iPhones on this Wi-Fi watch sessions")
                        .font(.system(size: 11))
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                Text("Read-only in this version. Output is redacted before it leaves this Mac, the connection is encrypted with a key that only exists on the two devices, and nothing goes through a server.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if case .failed(let why) = agent.state {
                    Text(why)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if case .listening = agent.state {
                    HStack {
                        Button {
                            agent.beginPairing()
                            showPairing = true
                        } label: {
                            Label("Pair an iPhone…", systemImage: "qrcode")
                                .font(.system(size: 11))
                        }
                        .controlSize(.small)
                        Spacer()
                    }
                    .padding(.top, 2)
                }

                if !agent.peers.isEmpty {
                    Divider().padding(.vertical, 2)
                    ForEach(agent.peers) { peer in
                        HStack(spacing: 6) {
                            Image(systemName: "iphone")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Text(peer.displayName)
                                .font(.system(size: 11))
                            Text(peer.pairedAt, style: .date)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Forget") { agent.forget(peerID: peer.id) }
                                .font(.system(size: 10))
                                .controlSize(.mini)
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .sheet(isPresented: $showPairing, onDismiss: { agent.cancelPairing(); agent.dismissPairingResult() }) {
            LANPairingSheet(agent: agent, isPresented: $showPairing)
        }
        .onAppear { if agent.isEnabled { agent.start() } }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch agent.state {
        case .off:
            EmptyView()
        case .unavailable:
            Text("Unavailable").font(.system(size: 9)).foregroundStyle(.secondary)
        case .starting:
            Text("Starting…").font(.system(size: 9)).foregroundStyle(.secondary)
        case let .listening(_, peers, connections):
            HStack(spacing: 4) {
                Circle().fill(connections > 0 ? Color.green : Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
                Text(connections > 0 ? "\(connections) connected" : "\(peers) paired")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        case .failed:
            Text("Failed").font(.system(size: 9)).foregroundStyle(.red)
        }
    }
}

/// The QR + approval sheet. One pairing at a time.
struct LANPairingSheet: View {
    @ObservedObject var agent: LANLinkAgent
    @Binding var isPresented: Bool
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 14) {
            switch agent.pairing {
            case let .showingQR(url, expiresAt):
                Text("Scan with CLI Pulse on your iPhone")
                    .font(.headline)
                if let image = Self.qrImage(for: url) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 220, height: 220)
                }
                Text("Expires in \(max(0, Int(expiresAt.timeIntervalSince(now)))) s")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)

            case let .awaitingApproval(sas, peerName):
                Text("Pair with \(peerName)?")
                    .font(.headline)
                Text("Approve only if this code matches the one on the iPhone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text(sas)
                    .font(.system(size: 40, weight: .semibold, design: .monospaced))
                    .tracking(6)
                HStack(spacing: 12) {
                    Button("Decline") { agent.rejectPairing() }
                        .keyboardShortcut(.cancelAction)
                    Button("Approve") { agent.approvePairing() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }

            case let .succeeded(peerName):
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.green)
                Text("\(peerName) is paired")
                    .font(.headline)
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.defaultAction)

            case let .failed(why):
                Image(systemName: "xmark.circle")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text(why)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    Button("Close") { isPresented = false }
                    Button("Try again") { agent.beginPairing() }
                        .buttonStyle(.borderedProminent)
                }

            case .idle:
                ProgressView()
            }
        }
        .padding(24)
        .frame(width: 320)
        .onReceive(tick) { now = $0 }
    }

    static func qrImage(for string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let ci = filter.outputImage else { return nil }
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}
#endif
