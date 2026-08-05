import XCTest
@testable import CLIPulseCore

// MARK: - Doubles

private final class StubStore: AnonymousTelemetryStore, @unchecked Sendable {
    var isEnabled = true
    var hasSeenDisclosure = true
    var installID = UUID(uuidString: "12345678-1234-1234-1234-123456789012")!
    var installReported = false
    var activationReported = false
}

private actor RecordingTransport: AnonymousTelemetryTransport {
    private(set) var sent: [AnonymousInstallPayload] = []
    private let failures: Int
    private var attempts = 0

    init(failFirst: Int = 0) { self.failures = failFirst }

    func send(_ payload: AnonymousInstallPayload) async throws {
        attempts += 1
        if attempts <= failures { throw URLError(.notConnectedToInternet) }
        sent.append(payload)
    }

    func payloads() -> [AnonymousInstallPayload] { sent }
}

// MARK: -

final class AnonymousInstallTelemetryTests: XCTestCase {

    private func makeSubject(
        store: StubStore,
        transport: RecordingTransport,
        channel: DistributionChannel = .devid,
        version: String = "1.45.0"
    ) -> AnonymousInstallTelemetry {
        AnonymousInstallTelemetry(
            store: store, transport: transport, channel: channel,
            rawAppVersion: version, osMajor: 15, osMinor: 1
        )
    }

    // MARK: - The gate

    /// The switch being off must mean nothing leaves the machine — not a
    /// reduced payload, not a "just the count". Off is off.
    func test_nothingIsSentWhenDisabled() async {
        let store = StubStore(); store.isEnabled = false
        let transport = RecordingTransport()
        await makeSubject(store: store, transport: transport).recordInstallIfNeeded()
        let sent = await transport.payloads()
        XCTAssertTrue(sent.isEmpty)
        XCTAssertFalse(store.installReported)
    }

    /// The default is enabled, which is only defensible because the first
    /// launch discloses it BEFORE the first send. If the disclosure has not
    /// been shown, the default must not yet apply.
    func test_nothingIsSentBeforeTheDisclosureHasBeenSeen() async {
        let store = StubStore(); store.hasSeenDisclosure = false
        XCTAssertTrue(store.isEnabled, "precondition: the switch defaults on")
        let transport = RecordingTransport()
        await makeSubject(store: store, transport: transport).recordInstallIfNeeded()
        let sent = await transport.payloads()
        XCTAssertTrue(sent.isEmpty, "enabled-by-default must not outrun the disclosure")
    }

    func test_installIsReportedOnceEvenAcrossManyLaunches() async {
        let store = StubStore()
        let transport = RecordingTransport()
        let subject = makeSubject(store: store, transport: transport)
        await subject.recordInstallIfNeeded()
        await subject.recordInstallIfNeeded()
        await subject.recordInstallIfNeeded()
        let sent = await transport.payloads()
        XCTAssertEqual(sent.count, 1)
        XCTAssertTrue(store.installReported)
    }

    /// A first launch with no network must not cost us the install. Retrying
    /// across launches is what keeps "users who happened to be online at first
    /// run" from silently becoming the population we measure.
    func test_aFailedSendIsRetriedOnTheNextLaunch() async {
        let store = StubStore()
        let transport = RecordingTransport(failFirst: 2)
        let subject = makeSubject(store: store, transport: transport)

        await subject.recordInstallIfNeeded()
        XCTAssertFalse(store.installReported, "a failure must not mark it reported")
        await subject.recordInstallIfNeeded()
        XCTAssertFalse(store.installReported)
        await subject.recordInstallIfNeeded()

        let sent = await transport.payloads()
        XCTAssertEqual(sent.count, 1, "the third attempt succeeds exactly once")
        XCTAssertTrue(store.installReported)
    }

    func test_activationIsReportedOnceAndAlsoSettlesTheInstall() async {
        let store = StubStore()
        let transport = RecordingTransport()
        let subject = makeSubject(store: store, transport: transport)

        await subject.recordFirstProviderDetectedIfNeeded()
        await subject.recordFirstProviderDetectedIfNeeded()
        await subject.recordInstallIfNeeded()

        let sent = await transport.payloads()
        XCTAssertEqual(sent.count, 1, "a first launch that immediately finds a CLI sends one row")
        XCTAssertEqual(sent.first?.providerDetected, true)
        XCTAssertTrue(store.installReported)
    }

    // MARK: - Payload

    /// The payload has no free-text field and no dictionary. This asserts the
    /// exact wire keys, so adding one becomes a deliberate act with a failing
    /// test attached rather than a quiet edit.
    func test_payloadCarriesExactlyTheFiveExpectedKeys() throws {
        let payload = AnonymousInstallPayload(
            installID: UUID(uuidString: "12345678-1234-1234-1234-123456789012")!,
            channel: .brew, appVersion: "1.45.0", osVersion: "15.1", providerDetected: true
        )
        let json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(payload)
        ) as? [String: Any]
        XCTAssertEqual(
            Set(json.map { Array($0.keys) } ?? []),
            ["p_install_id", "p_channel", "p_app_version", "p_os_version", "p_provider_detected"]
        )
        XCTAssertEqual(json?["p_install_id"] as? String, "12345678-1234-1234-1234-123456789012")
        XCTAssertEqual(json?["p_channel"] as? String, "brew")
    }

    /// A build whose version cannot be shaped into something the server accepts
    /// must send nothing rather than invent a value. A fabricated version is
    /// worse than a missing row: it would look like real data.
    func test_anUnshapeableVersionSendsNothing() async {
        let store = StubStore()
        let transport = RecordingTransport()
        await makeSubject(store: store, transport: transport, version: "nightly").recordInstallIfNeeded()
        let sent = await transport.payloads()
        XCTAssertTrue(sent.isEmpty)
        XCTAssertFalse(store.installReported)
    }

    // MARK: - Channel detection

    func test_sandboxedBuildIsTheMacAppStore() {
        XCTAssertEqual(
            DistributionChannel.detect(hasAppStoreReceipt: false, isSandboxed: true,
                                       directoryExists: { _ in true }),
            .mas,
            "a sandboxed app cannot see the Homebrew prefix; asking would give a wrong answer"
        )
    }

    func test_receiptWinsEvenWhenTheCaskroomIsPresent() {
        XCTAssertEqual(
            DistributionChannel.detect(hasAppStoreReceipt: true, isSandboxed: false,
                                       directoryExists: { _ in true }),
            .mas
        )
    }

    func test_caskroomEntryMeansHomebrew() {
        for prefix in ["/opt/homebrew", "/usr/local"] {
            XCTAssertEqual(
                DistributionChannel.detect(
                    hasAppStoreReceipt: false, isSandboxed: false,
                    directoryExists: { $0 == "\(prefix)/Caskroom/cli-pulse" }
                ),
                .brew,
                "\(prefix) (Apple silicon and Intel prefixes both count)"
            )
        }
    }

    func test_plainDirectDownloadIsDeveloperID() {
        XCTAssertEqual(
            DistributionChannel.detect(hasAppStoreReceipt: false, isSandboxed: false,
                                       directoryExists: { _ in false }),
            .devid
        )
    }

    /// Homebrew for some OTHER cask must not make us think we came from brew.
    func test_anUnrelatedCaskDoesNotCount() {
        XCTAssertEqual(
            DistributionChannel.detect(
                hasAppStoreReceipt: false, isSandboxed: false,
                directoryExists: { $0.contains("/Caskroom/") && !$0.hasSuffix("cli-pulse") }
            ),
            .devid
        )
    }

    // MARK: - Version shaping

    func test_versionShaping() {
        let shape = AnonymousTelemetryVersionShaping.self
        XCTAssertEqual(shape.sanitizedAppVersion("1.45.0"), "1.45.0")
        XCTAssertEqual(shape.sanitizedAppVersion("1.45.0-beta.2"), "1.45.0",
                       "a prerelease still reports its release line")
        XCTAssertEqual(shape.sanitizedAppVersion("2"), "2")
        XCTAssertNil(shape.sanitizedAppVersion("nightly"))
        XCTAssertNil(shape.sanitizedAppVersion(""))
        XCTAssertNil(shape.sanitizedAppVersion("v1.45.0"), "a leading v is not a number")
        XCTAssertNil(shape.sanitizedAppVersion("99999.1"), "5+ digit components are out of contract")
        XCTAssertEqual(shape.coarsenedOSVersion(major: 15, minor: 1), "15.1")
        XCTAssertEqual(shape.coarsenedOSVersion(major: 26, minor: 0), "26.0")
    }

    /// The install id must be random, not derived from the machine.
    func test_installIdsAreDistinctAcrossFreshInstalls() {
        let a = UserDefaultsAnonymousTelemetryStore(defaults: makeScratchDefaults()).installID
        let b = UserDefaultsAnonymousTelemetryStore(defaults: makeScratchDefaults()).installID
        XCTAssertNotEqual(a, b, "two fresh installs on ONE machine must not share an id")
    }

    func test_installIdIsStableWithinOneInstall() {
        let defaults = makeScratchDefaults()
        let first = UserDefaultsAnonymousTelemetryStore(defaults: defaults).installID
        let second = UserDefaultsAnonymousTelemetryStore(defaults: defaults).installID
        XCTAssertEqual(first, second)
    }

    func test_theSwitchDefaultsOnButTheDisclosureDoesNot() {
        let store = UserDefaultsAnonymousTelemetryStore(defaults: makeScratchDefaults())
        XCTAssertTrue(store.isEnabled)
        XCTAssertFalse(store.hasSeenDisclosure, "nothing may be sent until the user has been told")
    }

    private func makeScratchDefaults() -> UserDefaults {
        let suite = "anon-telemetry-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
}
