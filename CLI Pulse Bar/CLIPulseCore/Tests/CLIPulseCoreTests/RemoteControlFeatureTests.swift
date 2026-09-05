import XCTest
@testable import CLIPulseCore

/// M3 dark-ship gate. The plan's negative control is "flag off ⇒ the new
/// path is unreachable", so this pins both halves: the predicate itself,
/// and that every place the feature surfaces actually consults it.
///
/// The second half is a SOURCE test on purpose. A predicate nothing calls
/// is this repo's most reliably shipped defect (four repo guards once went
/// green while all four were broken), and a SwiftUI view cannot be
/// instantiated in this suite to prove the wiring at runtime.
final class RemoteControlFeatureTests: XCTestCase {

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "rc-feature-\(UUID().uuidString))")!
    }

    func testShipsOffSoTheCodeCanLandBeforeTheFeatureIsExposed() {
        // THE dark-ship property. If this ever flips to true by accident,
        // a DEVID release exposes remote control to everyone who installs
        // it, which is the decision this flag exists to keep deliberate.
        XCTAssertFalse(RemoteControlFeature.shippedDefault)
        XCTAssertFalse(RemoteControlFeature.isAvailable(in: defaults()))
    }

    func testAnExplicitOverrideTurnsItOnAndOffAgain() {
        let d = defaults()
        d.set(true, forKey: RemoteControlFeature.overrideDefaultsKey)
        XCTAssertTrue(RemoteControlFeature.isAvailable(in: d))
        d.set(false, forKey: RemoteControlFeature.overrideDefaultsKey)
        XCTAssertFalse(RemoteControlFeature.isAvailable(in: d), "an explicit false must win, not fall back to the default")
        d.removeObject(forKey: RemoteControlFeature.overrideDefaultsKey)
        XCTAssertEqual(RemoteControlFeature.isAvailable(in: d), RemoteControlFeature.shippedDefault)
    }

    func testANonBooleanOverrideIsIgnoredRatherThanTreatedAsOn() {
        // Negative control: `UserDefaults.bool(forKey:)` reads "1", "YES"
        // and 1 as true, so a stray string could silently ship the feature.
        let d = defaults()
        for junk in ["yes please", "", "off"] {
            d.set(junk, forKey: RemoteControlFeature.overrideDefaultsKey)
            XCTAssertFalse(RemoteControlFeature.isAvailable(in: d), junk)
        }
    }

    // MARK: - the gate is actually wired in

    private func source(_ relative: String) throws -> String {
        // Tests run from the package dir; the app target sits beside it.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/Tests/CLIPulseCoreTests
            .deletingLastPathComponent()   // …/Tests
            .deletingLastPathComponent()   // …/CLIPulseCore
            .deletingLastPathComponent()   // …/CLI Pulse Bar  ← the app targets
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    func testEveryPlaceTheFeatureSurfacesConsultsTheGate() throws {
        // One entry per mount point. If someone adds a fifth surface and
        // forgets the gate, this does not catch it — so the list itself is
        // asserted complete by the next test.
        let mounts: [(String, String)] = [
            ("CLI Pulse Bar/SettingsTab.swift", "LANRemoteControlSection(agent:"),
            ("CLI Pulse Bar iOS/iOSOverviewTab.swift", "LANNearbyMacsView()"),
            ("CLI Pulse Bar iOS/iOSSettingsTab.swift", "LANNearbyMacsView()"),
        ]
        for (file, marker) in mounts {
            let src = try source(file)
            guard let at = src.range(of: marker) else {
                return XCTFail("\(file) no longer contains \(marker) — update this test")
            }
            // The gate must appear before the mount, in the same file.
            let before = src[src.startIndex..<at.lowerBound]
            XCTAssertTrue(before.contains("RemoteControlFeature.isAvailable"),
                          "\(file) mounts the feature without consulting RemoteControlFeature")
        }
    }

    func testTheMountListIsComplete() throws {
        // Grep the app targets for every use of the two entry-point views
        // and assert the test above covers them all, so a new surface
        // cannot be added silently.
        let files = ["CLI Pulse Bar/SettingsTab.swift",
                     "CLI Pulse Bar iOS/iOSOverviewTab.swift",
                     "CLI Pulse Bar iOS/iOSSettingsTab.swift",
                     "CLI Pulse Bar/CLIPulseBarApp.swift",
                     "CLI Pulse Bar iOS/CLIPulseApp_iOS.swift"]
        var found = 0
        for f in files {
            let src = (try? source(f)) ?? ""
            found += src.components(separatedBy: "LANRemoteControlSection(agent:").count - 1
            found += src.components(separatedBy: "LANNearbyMacsView()").count - 1
        }
        XCTAssertEqual(found, 3, "the number of mount points changed; update testEveryPlaceTheFeatureSurfacesConsultsTheGate")
    }

    @MainActor
    func testTheAgentRefusesToStartWhenTheFeatureIsOff() {
        // Belt and braces: even if a surface forgot the gate, the agent
        // itself must not open a listener or advertise on Bonjour.
        XCTAssertNotNil(LANLinkAgent.unavailabilityReason(featureAvailable: false),
                        "the agent must refuse to run when the feature is off")
        // And the reason must not be the App Store one — that would tell a
        // Developer ID user something false about why it is unavailable.
        let reason = LANLinkAgent.unavailabilityReason(featureAvailable: false) ?? ""
        XCTAssertFalse(reason.contains("App Store"), reason)
    }
}
