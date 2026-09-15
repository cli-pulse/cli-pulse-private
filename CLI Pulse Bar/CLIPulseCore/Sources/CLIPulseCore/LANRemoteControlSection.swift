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
    @State private var addrCopied = false

    public init(agent: LANLinkAgent) {
        self.agent = agent
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "iphone.and.arrow.forward")
                    .font(.system(size: 11))
                    .foregroundStyle(PulseTheme.accent)
                Text(L10n.remote.title)
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
                    Text(L10n.remote.allowPairedIphones)
                        .font(.system(size: 11))
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                Text(L10n.remote.macPrivacyExplainer)
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
                    // Pairing is presented INLINE, never as a sheet: this card
                    // lives in the menu-bar popover, and a sheet is a separate
                    // window — clicking it counts as clicking outside the
                    // popover, which dismisses the popover and the sheet with
                    // it. The first real run found that; nobody could reach
                    // "Copy link".
                    if case .idle = agent.pairing {
                        HStack {
                            Button {
                                agent.beginPairing()
                            } label: {
                                Label(L10n.remote.pairAnIphone, systemImage: "qrcode")
                                    .font(.system(size: 11))
                            }
                            .controlSize(.small)
                            Spacer()
                        }
                        .padding(.top, 2)
                    } else {
                        Divider().padding(.vertical, 2)
                        LANPairingInline(agent: agent)
                    }
                }

                if let addr = agent.directAddress {
                    Divider().padding(.vertical, 2)
                    HStack(spacing: 6) {
                        Image(systemName: agent.directAddressIsTailnet ? "globe" : "wifi")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        Text(L10n.remote.reachableAt).font(.system(size: 10)).foregroundStyle(.secondary)
                        Text(addr).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        Spacer()
                        Button(addrCopied ? L10n.remote.copied : L10n.remote.copy) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(addr, forType: .string)
                            addrCopied = true
                        }
                        .font(.system(size: 10)).controlSize(.mini)
                    }
                    Text(agent.directAddressIsTailnet ? L10n.remote.tailnetHint : L10n.remote.lanOnlyHint)
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
                            // Per-phone permission. Read on every control
                            // frame, so flipping it applies to the next key.
                            // `fixedSize` because the popover is narrow
                            // enough to break "Control" into "Cont rol"
                            // (seen on the owner's Mac).
                            Toggle(L10n.remote.controlToggle, isOn: Binding(
                                get: { peer.controlAllowed },
                                set: { agent.setControlAllowed(peerID: peer.id, $0) }))
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                                .font(.system(size: 10))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .help(L10n.remote.controlToggleHelp)
                            Button(L10n.remote.forget) { agent.forget(peerID: peer.id) }
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
        .onAppear { if agent.isEnabled { agent.start() } }
        // Deliberately NO cancel on disappear. This card lives in the
        // menu-bar popover, which disappears whenever the user clicks
        // anywhere else — including the app they are copying the link
        // INTO. Cancelling there killed the pairing listener between
        // "Copy link" and the phone's first look. The QR's own 60 s
        // lifetime is the cancel; reopening Settings shows the same code.
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch agent.state {
        case .off:
            EmptyView()
        case .unavailable:
            Text(L10n.remote.statusUnavailable).font(.system(size: 9)).foregroundStyle(.secondary)
        case .starting:
            Text(L10n.sessions.statusStarting).font(.system(size: 9)).foregroundStyle(.secondary)
        case let .listening(_, peers, connections):
            HStack(spacing: 4) {
                Circle().fill(connections > 0 ? Color.green : Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
                Text(connections > 0 ? L10n.remote.countConnected(connections) : L10n.remote.countPaired(peers))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        case .failed:
            Text(L10n.status.failed).font(.system(size: 9)).foregroundStyle(.red)
        }
    }
}

/// The QR / code / result, rendered inside the Settings card. One pairing
/// at a time. Compact on purpose: the popover is narrow.
struct LANPairingInline: View {
    @ObservedObject var agent: LANLinkAgent
    @State private var now = Date()
    @State private var copied = false
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch agent.pairing {
            case let .showingQR(url, expiresAt):
                Text(L10n.remote.pairQrHint)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 12) {
                    if let image = Self.qrImage(for: url) {
                        Image(nsImage: image)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 132, height: 132)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.remote.expiresInSeconds(max(0, Int(expiresAt.timeIntervalSince(now)))))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Button(copied ? L10n.remote.copied : L10n.remote.copyLink) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url, forType: .string)
                            copied = true
                        }
                        .controlSize(.small)
                        Button(L10n.remote.cancel) { agent.cancelPairing() }
                            .controlSize(.small)
                    }
                }

            case let .awaitingApproval(sas, peerName):
                Text(L10n.remote.pairApprovalPrompt(peerName))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(sas)
                    .font(.system(size: 28, weight: .semibold, design: .monospaced))
                    .tracking(4)
                HStack(spacing: 8) {
                    Button(L10n.remote.approve) { agent.approvePairing() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button(L10n.remote.decline) { agent.rejectPairing() }
                        .controlSize(.small)
                }

            case let .succeeded(peerName):
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(L10n.remote.peerIsPaired(peerName)).font(.system(size: 11))
                    Spacer()
                    Button(L10n.remote.done) { agent.dismissPairingResult() }.controlSize(.small)
                }

            case let .failed(why):
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle").foregroundStyle(.secondary)
                    Text(why).font(.system(size: 10)).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(L10n.remote.tryAgain) { agent.beginPairing() }.controlSize(.small)
                    Button(L10n.common.close) { agent.dismissPairingResult() }.controlSize(.small)
                }

            case .idle:
                EmptyView()
            }
        }
        .onReceive(tick) { now = $0 }
        .onChange(of: agent.pairing) { _ in copied = false }
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
