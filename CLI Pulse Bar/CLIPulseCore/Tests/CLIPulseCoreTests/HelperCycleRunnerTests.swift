import XCTest
@testable import CLIPulseCore

/// The order of a LoginItem helper cycle (`HelperCycleRunner`). The helper
/// target has no tests; these are what fail if a question moves after the
/// read, the write or an upload it is meant to stop.
final class HelperCycleRunnerTests: XCTestCase {

    private struct UploadFailed: Error {}

    /// Everything a cycle does, in order, and the inputs it reads. The inputs
    /// can change between questions, the way the app changes them while the
    /// helper runs.
    private final class Recorder {
        var consent: LocalScanConsent?
        var account: HelperAccountRecord?
        var pairing: HelperConfig?
        var pairingReads = 0
        var events: [String] = []
        /// Runs after the collect, or after an upload step, to change an input.
        var afterCollect: (() -> Void)?
        var afterStep: [Int: () -> Void] = [:]
        var failingStep: Int?
        /// The question each upload step was handed, in order.
        var stepCycles: [LocalCollectionPolicy.HelperCycle] = []

        init(consent: LocalScanConsent?, account: HelperAccountRecord?, pairedTo userId: String?) {
            self.consent = consent
            self.account = account
            self.pairing = userId.map {
                HelperConfig(
                    deviceId: "device-\($0)", userId: $0, deviceName: "Mac",
                    helperVersion: "1.0.0", helperSecret: "secret"
                )
            }
        }

        var reads: Int { events.filter { $0 == "collect" }.count }
        var writes: Int { events.filter { $0 == "write" }.count }
        var uploads: [String] { events.filter { $0.hasPrefix("upload") } }

        func runner() -> HelperCycleRunner<String> {
            HelperCycleRunner(
                readConsent: { self.consent },
                readAccount: { self.account },
                readPairing: {
                    self.pairingReads += 1
                    return self.pairing
                },
                collect: {
                    self.events.append("collect")
                    self.afterCollect?()
                    return "collection"
                },
                writeResults: { _ in self.events.append("write") },
                uploadSteps: (0..<4).map { index -> HelperCycleRunner<String>.UploadStep in
                    return { _, config, cycle in
                        self.stepCycles.append(cycle)
                        self.events.append("upload\(index):\(config.userId)")
                        self.afterStep[index]?()
                        if self.failingStep == index { throw UploadFailed() }
                    }
                }
            )
        }
    }

    private func isSkipped(_ outcome: HelperCycleRunner<String>.Outcome) -> LocalCollectionPolicy.HelperCycle? {
        if case .skipped(let cycle) = outcome { return cycle }
        return nil
    }

    // MARK: - Nothing read

    /// "Not now", a sign-out, local mode without a yes, and no copy yet: the
    /// cycle reads nothing, writes nothing and sends nothing.
    func testACycleThatMayNotReadDoesNothing() async {
        let cases: [(LocalScanConsent?, HelperAccountRecord?)] = [
            (.declined, .signedIn(userId: "u1")),
            (.declined, nil),
            (.granted, .signedOut),
            (.undecided, .localMode),
            (nil, .signedIn(userId: "u1")),
        ]
        for (consent, account) in cases {
            let recorder = Recorder(consent: consent, account: account, pairedTo: "u1")
            let outcome = await recorder.runner().run()
            XCTAssertNotNil(isSkipped(outcome), "\(String(describing: consent)), \(String(describing: account))")
            XCTAssertEqual(recorder.events, [], "\(String(describing: consent)), \(String(describing: account))")
            XCTAssertEqual(recorder.pairingReads, 0, "a Keychain read for a cycle that reads nothing")
        }
    }

    // MARK: - An answer that changes during the cycle

    /// A "Not now" given while the collectors run: what they read is dropped,
    /// neither written for the app nor sent.
    func testNotNowWhileCollectingDropsWhatWasRead() async {
        let recorder = Recorder(consent: .granted, account: .signedIn(userId: "u1"), pairedTo: "u1")
        recorder.afterCollect = { recorder.consent = .declined }
        let outcome = await recorder.runner().run()
        guard case .dropped(.paused(.answer)) = outcome else {
            return XCTFail("expected the collection to be dropped, got \(outcome)")
        }
        XCTAssertEqual(recorder.events, ["collect"])
    }

    /// Signing out while the collectors run: dropped too.
    func testSigningOutWhileCollectingDropsWhatWasRead() async {
        let recorder = Recorder(consent: .granted, account: .signedIn(userId: "u1"), pairedTo: "u1")
        recorder.afterCollect = { recorder.account = .signedOut }
        let outcome = await recorder.runner().run()
        guard case .dropped(.paused(.signedOut)) = outcome else {
            return XCTFail("expected the collection to be dropped, got \(outcome)")
        }
        XCTAssertEqual(recorder.events, ["collect"])
    }

    /// A "Not now" between two uploads: the rest are not sent.
    func testNotNowBetweenUploadsStopsTheRest() async {
        let recorder = Recorder(consent: .undecided, account: .signedIn(userId: "u1"), pairedTo: "u1")
        recorder.afterStep[0] = { recorder.consent = .declined }
        let outcome = await recorder.runner().run()
        guard case .stopped(.paused(.answer)) = outcome else {
            return XCTFail("expected the uploads to stop, got \(outcome)")
        }
        XCTAssertEqual(recorder.events, ["collect", "write", "upload0:u1"])
    }

    /// An account switch between two uploads: the rest are not sent to the
    /// account the pairing was made for.
    func testAnAccountSwitchBetweenUploadsStopsTheRest() async {
        let recorder = Recorder(consent: .undecided, account: .signedIn(userId: "u1"), pairedTo: "u1")
        recorder.afterStep[1] = { recorder.account = .signedIn(userId: "u2") }
        let outcome = await recorder.runner().run()
        guard case .stopped(.collectLocally) = outcome else {
            return XCTFail("expected the uploads to stop, got \(outcome)")
        }
        XCTAssertEqual(recorder.uploads, ["upload0:u1", "upload1:u1"])
    }

    /// A "Not now" during the last upload: the cycle is not reported as a
    /// sync, so Settings does not say "Synced just now".
    func testNotNowAfterTheLastUploadIsNotReportedAsASync() async {
        let recorder = Recorder(consent: .undecided, account: .signedIn(userId: "u1"), pairedTo: "u1")
        recorder.afterStep[3] = { recorder.consent = .declined }
        let outcome = await recorder.runner().run()
        guard case .stopped(.paused(.answer)) = outcome else {
            return XCTFail("expected no sync to be reported, got \(outcome)")
        }
    }

    // MARK: - Reading without uploading

    /// Local mode after a yes: read and written for the app, nothing sent,
    /// and the pairing never read.
    func testLocalModeWithAYesWritesButSendsNothing() async {
        let recorder = Recorder(consent: .granted, account: .localMode, pairedTo: "u1")
        let outcome = await recorder.runner().run()
        guard case .collectedLocally = outcome else {
            return XCTFail("expected a local collection, got \(outcome)")
        }
        XCTAssertEqual(recorder.events, ["collect", "write"])
        XCTAssertEqual(recorder.pairingReads, 0)
    }

    /// Signed in as u2 with the pairing u1 left: nothing sent to u1.
    func testAnotherAccountsPairingIsNotUploadedTo() async {
        let recorder = Recorder(consent: .granted, account: .signedIn(userId: "u2"), pairedTo: "u1")
        let outcome = await recorder.runner().run()
        guard case .collectedLocally = outcome else {
            return XCTFail("expected a local collection, got \(outcome)")
        }
        XCTAssertEqual(recorder.events, ["collect", "write"])
    }

    // MARK: - Allowed

    func testAnAllowedCycleRunsEveryStepInOrder() async {
        let recorder = Recorder(consent: .undecided, account: .signedIn(userId: "u1"), pairedTo: "u1")
        let outcome = await recorder.runner().run()
        guard case .synced(let config) = outcome else {
            return XCTFail("expected a sync, got \(outcome)")
        }
        XCTAssertEqual(config.userId, "u1")
        XCTAssertEqual(
            recorder.events,
            ["collect", "write", "upload0:u1", "upload1:u1", "upload2:u1", "upload3:u1"]
        )
        // Before and after collecting; the questions before each upload reuse
        // the pairing the cycle was decided with.
        XCTAssertEqual(recorder.pairingReads, 2)
    }

    /// Each upload step is handed the question asked just before it. The
    /// heartbeat step passes its `reads` on as `hello(localScanAllowed:)`, so
    /// the helper tells `hello` it may read this Mac only from a cycle the
    /// answer and the account allowed.
    func testEachUploadStepIsHandedTheQuestionThatAllowedIt() async {
        let recorder = Recorder(consent: .granted, account: .signedIn(userId: "u1"), pairedTo: "u1")
        _ = await recorder.runner().run()
        XCTAssertEqual(recorder.stepCycles, Array(repeating: .collectAndSync, count: 4))
        XCTAssertTrue(recorder.stepCycles.allSatisfy(\.reads))

        // A cycle that may not read, or may read only for the app on this
        // Mac, never reaches a step.
        let refused: [(LocalScanConsent, HelperAccountRecord)] = [
            (.declined, .signedIn(userId: "u1")),
            (.granted, .signedOut),
            (.granted, .localMode),
            (.granted, .signedIn(userId: "u2")),
        ]
        for (consent, account) in refused {
            let other = Recorder(consent: consent, account: account, pairedTo: "u1")
            _ = await other.runner().run()
            XCTAssertEqual(other.stepCycles, [], "\(consent), \(account)")
        }
    }

    func testAFailedUploadStopsTheRest() async {
        let recorder = Recorder(consent: .granted, account: .signedIn(userId: "u1"), pairedTo: "u1")
        recorder.failingStep = 0
        let outcome = await recorder.runner().run()
        guard case .failed(let config, _) = outcome else {
            return XCTFail("expected a failure, got \(outcome)")
        }
        XCTAssertEqual(config.userId, "u1")
        XCTAssertEqual(recorder.uploads, ["upload0:u1"])
    }

    /// The question on its own, for the helper's "inputs changed" hint.
    func testAskingAloneReadsNothing() {
        let recorder = Recorder(consent: .declined, account: .signedIn(userId: "u1"), pairedTo: "u1")
        XCTAssertEqual(recorder.runner().ask(), .paused(.answer))
        XCTAssertEqual(recorder.events, [])
        XCTAssertEqual(recorder.pairingReads, 0)
    }
}
