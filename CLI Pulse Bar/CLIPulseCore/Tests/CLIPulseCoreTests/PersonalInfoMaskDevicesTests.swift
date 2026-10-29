// 1.60 (C9): "Hide personal information" covers device names.
//
// Asserted in Simplified Chinese, where a broken catalogue lookup cannot pass
// for the translation (`testTheWordsInEveryLanguage` covers the rest).

import CryptoKit
import Foundation
import XCTest
@testable import CLIPulseCore

final class PersonalInfoMaskDevicesTests: XCTestCase {

    private var saved: String?
    override func setUp() {
        super.setUp()
        saved = LocaleOverrideStore.shared.override
        LocaleOverrideStore.shared.set("zh-Hans")
    }
    override func tearDown() {
        LocaleOverrideStore.shared.set(saved)
        super.tearDown()
    }

    private static let devices: [(id: String, name: String)] = [
        (id: "c-3", name: "Jane's Mac mini"),
        (id: "a-1", name: "Jane's MacBook Pro"),
        (id: "b-2", name: "lab-server-01"),
        (id: "d-4", name: "lab-server-01"),   // two devices, one name
        (id: "e-5", name: "  "),
    ]

    func testWithTheSwitchOnADeviceIsNumberedByItsId() {
        let numbers = DeviceNameNumbers.devices(Self.devices)
        func shown(_ name: String?) -> String? {
            PersonalInfoMask.deviceName(name, numbers: numbers, hidePersonalInfo: true)
        }
        XCTAssertEqual(shown("Jane's MacBook Pro"), "设备 1")
        XCTAssertEqual(shown("Jane's Mac mini"), "设备 3")
        XCTAssertEqual(shown(" Jane's Mac mini "), "设备 3", "the name is compared trimmed")
        XCTAssertEqual(shown("lab-server-01"), "隐藏的设备", "a name two devices share says nothing about which")
        XCTAssertEqual(shown("someone-else"), "隐藏的设备", "a name the list does not have")
        XCTAssertNil(shown(""))
        XCTAssertNil(shown(nil))
    }

    func testTheSwitchOffShowsTheName() {
        let numbers = DeviceNameNumbers.devices(Self.devices)
        XCTAssertEqual(PersonalInfoMask.deviceName("Jane's MacBook Pro", numbers: numbers, hidePersonalInfo: false),
                       "Jane's MacBook Pro")
        XCTAssertEqual(PersonalInfoMask.deviceName("someone-else", numbers: .none, hidePersonalInfo: false),
                       "someone-else")
    }

    /// The list arrives newest-seen first, an order that changes as devices
    /// sync; the numbers do not.
    func testANumberDoesNotChangeWhenTheListIsReordered() {
        let shuffled = DeviceNameNumbers.devices(Self.devices.reversed())
        XCTAssertEqual(shuffled, DeviceNameNumbers.devices(Self.devices))
    }

    func testTheRecordsNumberTheSameWay() {
        func record(_ id: String, _ name: String) -> DeviceRecord {
            DeviceRecord(id: id, name: name, type: "macOS", system: "macOS", status: "Online",
                         last_sync_at: nil, helper_version: "1", current_session_count: 0,
                         cpu_usage: nil, memory_usage: nil)
        }
        let records = Self.devices.map { record($0.id, $0.name) }
        XCTAssertEqual(DeviceNameNumbers.devices(records), DeviceNameNumbers.devices(Self.devices))
        XCTAssertEqual(DeviceNameNumbers.devices(records.map(WatchDeviceSummary.init(from:))),
                       DeviceNameNumbers.devices(Self.devices), "the Watch numbers the devices it holds the same way")
    }

    // MARK: - Remote Control

    func testARemoteControlListNumbersByPlace() {
        XCTAssertEqual(PersonalInfoMask.listedDeviceName("Jane's iPhone", position: 1, hidePersonalInfo: true), "设备 2")
        XCTAssertEqual(PersonalInfoMask.listedDeviceName("Jane's iPhone", position: 1, hidePersonalInfo: false),
                       "Jane's iPhone")
    }

    func testADeviceBeingPairedGetsThePlaceItWillHave() throws {
        let peers = [try Self.peer("mac-a", "Jane's MacBook Pro"), try Self.peer("mac-b", "Jane's Mac mini")]
        XCTAssertEqual(PersonalInfoMask.pairedDeviceName("Jane's Mac mini", peerID: "mac-b", hidePersonalInfo: true, peers: peers), "设备 2")
        XCTAssertEqual(PersonalInfoMask.pairedDeviceName("Jane's Mac mini", peerID: nil, hidePersonalInfo: true, peers: peers), "设备 2",
                       "the pairing screens know the name only")
        XCTAssertEqual(PersonalInfoMask.pairedDeviceName("Jane's iMac", peerID: nil, hidePersonalInfo: true, peers: peers), "设备 3",
                       "not paired yet: the next place")
        XCTAssertEqual(PersonalInfoMask.pairedDeviceName("Jane's iMac", peerID: nil, hidePersonalInfo: false, peers: peers), "Jane's iMac")
    }

    private static func peer(_ id: String, _ name: String) throws -> LANPairing.PairedPeer {
        try LANPairing.PairedPeer(
            id: id, displayName: name, pskIdentity: "peer:\(id)",
            sessionKey: .init(size: .bits256),
            peerPublicKey: Curve25519.KeyAgreement.PrivateKey().publicKey,
            pairedAt: Date(timeIntervalSince1970: 0))
    }

    // MARK: - Managed sessions

    func testAManagedSessionLabelThatIsAnIPhonesNameIsHidden() {
        let numbers = DeviceNameNumbers.devices(Self.devices)
        func title(_ label: String?, device: String? = nil, hide: Bool = true) -> String {
            PersonalInfoMask.managedSessionTitle(
                clientLabel: label, deviceName: device, provider: "claude", numbers: numbers, hidePersonalInfo: hide)
        }
        let session = L10n.sessions.rowFallbackLabel("Claude")
        XCTAssertEqual(title("Jane's iPhone"), session, "an iPhone sends its own name as the label")
        XCTAssertEqual(title(nil), session)
        XCTAssertEqual(title("Jane's MacBook Pro", device: "Jane's MacBook Pro"),
                       L10n.sessions.rowLabelOnDevice("Claude", "设备 1"))
        XCTAssertEqual(title(ProviderDisplay.inAppTerminalClientLabel),
                       L10n.sessions.rowInAppTerminalLabel("Claude"), "the app's own labels stay, translated")
        XCTAssertEqual(title(ProviderDisplay.localStartClientLabel(for: "claude")), L10n.sessions.rowLocalLabel("Claude"))
        // Off: exactly what the row showed before.
        for (label, device) in [("Jane's iPhone", nil), ("Jane's MacBook Pro", "Jane's MacBook Pro"), ("", nil)]
            as [(String, String?)] {
            XCTAssertEqual(title(label, device: device, hide: false),
                           ProviderDisplay.managedRowLabel(clientLabel: label, deviceName: device, provider: "claude"))
        }
        XCTAssertFalse(title("Jane's iPhone").contains("Jane"))
    }

    // MARK: - The words

    func testTheWordsInEveryLanguage() {
        let expected: [String: (String, String)] = [
            "en": ("Device 2", "Hidden device"),
            "zh-Hans": ("设备 2", "隐藏的设备"),
            "zh-Hant": ("裝置 2", "隱藏的裝置"),
            "ja": ("デバイス 2", "非表示のデバイス"),
            "ko": ("기기 2", "숨겨진 기기"),
            "es": ("Dispositivo 2", "Dispositivo oculto"),
        ]
        for (language, words) in expected {
            LocaleOverrideStore.shared.set(language)
            XCTAssertEqual(L10n.devices.anonymous(2), words.0, language)
            XCTAssertEqual(L10n.devices.hidden, words.1, language)
            // The same word the app uses for a device elsewhere (the session
            // detail's "Device" field), and the same shape as "Project N".
            XCTAssertTrue(words.0.hasPrefix(L10n.detail.device), "\(language): \(words.0) vs \(L10n.detail.device)")
        }
    }
}
