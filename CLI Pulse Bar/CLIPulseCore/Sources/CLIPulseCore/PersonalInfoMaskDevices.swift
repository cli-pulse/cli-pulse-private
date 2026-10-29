import Foundation

// 1.60 (C9): "Hide personal information" covers device names.
//
// A device's name is what its owner called it, and the defaults carry the
// owner's own name ("Jane's MacBook Pro", "Jane's iPhone"). With the switch on,
// no device's name reaches the screen:
//
//   * The account's devices (the cloud's device list: the Machine views, the
//     Watch's machine cards, a session's device, an alert's device) are
//     "Device N", numbered in the order of their ids, which does not change as
//     they sync, so a device keeps its number from one refresh to the next and
//     on every screen of one app. A name the list does not have, or that two
//     of its devices share, is "Hidden device".
//   * Remote Control's paired devices (the Macs an iPhone pairs with, the
//     iPhones a Mac lets in) are "Device N" by their place in that list, and
//     a device being paired gets the number it will have there.
//   * A managed session's label, which an iPhone sets to its own name, is
//     "<Provider> session" unless it is one of the labels the app writes
//     itself.
//
// With the switch off every name shows as before. `scripts/check_personal_info_mask.py`
// holds the views that show a device's name to these functions.

/// The number "Device N" gives a device a surface knows by its name.
public struct DeviceNameNumbers: Sendable, Equatable {
    /// No numbers: with the switch on every device is "Hidden device".
    public static let none = DeviceNameNumbers(numbersByName: [:])

    /// Name → its number.
    public let numbersByName: [String: Int]

    public init(numbersByName: [String: Int]) {
        self.numbersByName = numbersByName
    }

    /// The account's devices numbered from 1 in the order of their ids. A
    /// name two of them share says nothing about which one is meant, so it
    /// gets no number; nor does a blank one.
    public static func devices(_ devices: [(id: String, name: String)]) -> DeviceNameNumbers {
        let ordered = devices.sorted { $0.id < $1.id }
        var numbers: [String: Int] = [:]
        var shared: Set<String> = []
        for (index, device) in ordered.enumerated() {
            let name = device.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            if numbers[name] != nil { shared.insert(name) } else { numbers[name] = index + 1 }
        }
        for name in shared { numbers[name] = nil }
        return DeviceNameNumbers(numbersByName: numbers)
    }

    public static func devices(_ devices: [DeviceRecord]) -> DeviceNameNumbers {
        Self.devices(devices.map { (id: $0.id, name: $0.name) })
    }

    public static func devices(_ devices: [WatchDeviceSummary]) -> DeviceNameNumbers {
        Self.devices(devices.map { (id: $0.id, name: $0.name) })
    }

    /// The number of the device called `name`, or nil.
    public func number(forName name: String) -> Int? {
        numbersByName[name.trimmingCharacters(in: .whitespacesAndNewlines)]
    }
}

public extension PersonalInfoMask {

    // MARK: - Devices

    /// A device's name as a surface shows it, or nil when it has none: with
    /// the switch off the name, with it on "Device N" (`numbers`) or "Hidden
    /// device".
    static func deviceName(
        _ name: String?,
        numbers: DeviceNameNumbers,
        hidePersonalInfo: Bool
    ) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        guard hidePersonalInfo else { return trimmed }
        return numbers.number(forName: trimmed).map(L10n.devices.anonymous) ?? L10n.devices.hidden
    }

    /// A device in a Remote Control list, by its place there (from 0): with
    /// the switch off its name, with it on "Device N".
    static func listedDeviceName(_ name: String, position: Int, hidePersonalInfo: Bool) -> String {
        hidePersonalInfo ? L10n.devices.anonymous(position + 1) : name
    }

    /// A Remote Control peer's name, as a screen that pairs with it or lists
    /// it shows it. With the switch on it is "Device N", its place among
    /// `peers` (the paired devices, in the order they are stored); a device
    /// not paired yet gets the place it will have, the next one. Found by id
    /// when there is one, else by name (the pairing screens know the name only).
    static func pairedDeviceName(
        _ name: String,
        peerID: String?,
        hidePersonalInfo: Bool,
        peers: [LANPairing.PairedPeer]
    ) -> String {
        let position = peerID.flatMap { id in peers.firstIndex { $0.id == id } }
            ?? peers.firstIndex { $0.displayName == name }
            ?? peers.count
        return listedDeviceName(name, position: position, hidePersonalInfo: hidePersonalInfo)
    }

    #if os(iOS)
    /// The iPhone's paired Macs (`LANPairingStore`).
    static func pairedDeviceName(_ name: String, peerID: String?, hidePersonalInfo: Bool) -> String {
        pairedDeviceName(name, peerID: peerID, hidePersonalInfo: hidePersonalInfo, peers: LANPairingStore.peers())
    }
    #endif

    // MARK: - Managed sessions

    /// A managed session's title (the Mac's Sessions tab, an iPhone's Remote
    /// Control list): `ProviderDisplay.managedRowLabel` with the switch off.
    /// With it on, a label the app writes itself is still translated, a label
    /// that is the session's device's name reads "<Provider> on Device N",
    /// and any other label, such as the name an iPhone sends for itself, is
    /// "<Provider> session".
    static func managedSessionTitle(
        clientLabel: String?,
        deviceName: String?,
        provider: String,
        numbers: DeviceNameNumbers,
        hidePersonalInfo: Bool
    ) -> String {
        guard hidePersonalInfo else {
            return ProviderDisplay.managedRowLabel(clientLabel: clientLabel, deviceName: deviceName, provider: provider)
        }
        let label = clientLabel?.trimmingCharacters(in: .whitespaces) ?? ""
        let device = deviceName?.trimmingCharacters(in: .whitespaces) ?? ""
        let providerName = ProviderDisplay.displayName(for: provider)
        if label.isEmpty { return L10n.sessions.rowFallbackLabel(providerName) }
        if !device.isEmpty && label.caseInsensitiveCompare(device) == .orderedSame,
           let masked = self.deviceName(device, numbers: numbers, hidePersonalInfo: true) {
            return L10n.sessions.rowLabelOnDevice(providerName, masked)
        }
        if ProviderDisplay.isAppClientLabel(label, provider: provider) {
            return ProviderDisplay.clientLabelDisplay(label, provider: provider)
        }
        return L10n.sessions.rowFallbackLabel(providerName)
    }
}

public extension AppState {
    /// The account's devices, numbered for "Device N" (`DeviceNameNumbers.devices`).
    var deviceNameNumbers: DeviceNameNumbers { .devices(devices) }
}
