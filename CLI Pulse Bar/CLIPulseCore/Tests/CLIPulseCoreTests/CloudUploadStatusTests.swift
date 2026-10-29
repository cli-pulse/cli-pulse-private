// 1.60: "Last cloud upload" on the Mac (Settings › General › Connection).
//
// Every `UploadOutcome.Reason` through the status: a success sets the time and
// clears a failure, a failure is kept until the next success, and an outcome
// that tried nothing or did not conclude changes nothing. What is kept is
// times, a reason token and an HTTP status, nothing else. The words are
// asserted in Simplified Chinese, where a broken lookup cannot pass.

import Foundation
import XCTest
@testable import CLIPulseCore

@MainActor
final class CloudUploadStatusTests: XCTestCase {

    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
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

    func testEveryReasonChangesTheStatusAsItsKindSays() {
        let earlier = CloudUploadStatus(
            lastSuccess: Self.t0.addingTimeInterval(-3600),
            lastFailure: .init(at: Self.t0.addingTimeInterval(-60), reason: .networkFailed, status: nil))
        let now = Self.t0
        for reason in UploadOutcome.Reason.allCases {
            let outcome = UploadOutcomeTests.sample(for: reason)
            let next = earlier.recording(outcome, at: now)
            switch reason.kind {
            case .success:
                XCTAssertEqual(next, CloudUploadStatus(lastSuccess: now, lastFailure: nil), "\(reason)")
            case .failure:
                XCTAssertEqual(next.lastSuccess, earlier.lastSuccess, "\(reason): the last success stands")
                XCTAssertEqual(next.lastFailure, .init(at: now, reason: reason, status: outcome.status), "\(reason)")
            case .finished, .inconclusive:
                XCTAssertEqual(next, earlier, "\(reason) tried nothing or did not conclude, so it says nothing")
            }
        }
    }

    func testTheTrackerRecordsEveryOutcomeIntoTheStatus() {
        let defaults = UploadOutcomeTests.freshDefaults()
        var clock = Self.t0
        let tracker = UploadOutcomeTracker(
            reporter: RecordingUploadReporter(), defaults: defaults, now: { clock }, log: { _ in })
        XCTAssertEqual(tracker.statusStore.status, CloudUploadStatus())

        tracker.record(.uploaded(rows: 3, status: 201, afterTokenRefresh: false), route: .cloud)
        XCTAssertEqual(tracker.statusStore.status.lastSuccess, Self.t0)
        clock = Self.t0.addingTimeInterval(120)
        tracker.record(.rejected(status: 503), route: .cloud)
        XCTAssertEqual(tracker.statusStore.status.lastFailure?.status, 503)
        clock = Self.t0.addingTimeInterval(240)
        tracker.record(.offline, route: .cloud)
        XCTAssertEqual(tracker.statusStore.status.lastFailure?.at, Self.t0.addingTimeInterval(120),
                       "being offline is not a failed attempt")

        // Kept across a relaunch: a new store on the same defaults reads it.
        XCTAssertEqual(CloudUploadStatusStore(defaults: defaults).status, tracker.statusStore.status)
    }

    func testOnlyTimesAReasonTokenAndAStatusAreKept() {
        let defaults = UploadOutcomeTests.freshDefaults()
        let store = CloudUploadStatusStore(defaults: defaults)
        store.record(.uploaded(rows: 9, status: 200, afterTokenRefresh: true), at: Self.t0)
        store.record(.cloudReadFailed(status: 500), at: Self.t0.addingTimeInterval(60))
        let kept = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("cli_pulse_upload_last") }
        XCTAssertEqual(Set(kept.keys), [
            CloudUploadStatusStore.successKey, CloudUploadStatusStore.failureAtKey,
            CloudUploadStatusStore.failureReasonKey, CloudUploadStatusStore.failureStatusKey,
        ])
        XCTAssertEqual(kept[CloudUploadStatusStore.failureReasonKey] as? String, "cloud_read_failed")
        XCTAssertEqual(kept[CloudUploadStatusStore.failureStatusKey] as? Int, 500)
        XCTAssertNotNil(kept[CloudUploadStatusStore.successKey] as? Double)

        // The next success clears the failure from the defaults too.
        store.record(.uploaded(rows: 1, status: 200, afterTokenRefresh: false), at: Self.t0.addingTimeInterval(120))
        XCTAssertNil(defaults.object(forKey: CloudUploadStatusStore.failureAtKey))
        XCTAssertNil(defaults.object(forKey: CloudUploadStatusStore.failureStatusKey))

        store.reset()
        XCTAssertEqual(CloudUploadStatusStore(defaults: defaults).status, CloudUploadStatus())
    }

    // MARK: - The words

    func testTheRowSaysWhenAndWhetherTheLastAttemptFailed() {
        let now = Self.t0
        XCTAssertEqual(CloudUploadStatus().lastUploadText(now: now), "尚未上传")
        XCTAssertNil(CloudUploadStatus().failureText(now: now))

        let uploaded = CloudUploadStatus(lastSuccess: now.addingTimeInterval(-300))
        XCTAssertEqual(uploaded.lastUploadText(now: now), "5 分钟前")
        XCTAssertNil(uploaded.failureText(now: now))

        let rejected = uploaded.recording(.rejected(status: 503), at: now.addingTimeInterval(-120))
        XCTAssertEqual(rejected.lastUploadText(now: now), "5 分钟前")
        XCTAssertEqual(rejected.failureText(now: now), "最近一次尝试失败（HTTP 503，2 分钟前）")

        let unreachable = uploaded.recording(.serverUnreachable, at: now.addingTimeInterval(-7200))
        XCTAssertEqual(unreachable.failureText(now: now), "最近一次尝试失败（2 小时前）")
    }

    func testTheWordsInEveryLanguage() {
        for language in ["en", "zh-Hans", "zh-Hant", "ja", "ko", "es"] {
            LocaleOverrideStore.shared.set(language)
            for (key, text) in [
                ("settings.last_upload", L10n.settings.lastUpload),
                ("settings.last_upload_never", L10n.settings.lastUploadNever),
                ("settings.last_upload_failed", L10n.settings.lastUploadFailed("X")),
                ("settings.last_upload_failed_http", L10n.settings.lastUploadFailedHTTP(503, "X")),
            ] {
                XCTAssertFalse(text.isEmpty, "\(language) \(key)")
                XCTAssertNotEqual(text, key, "\(language): raw key")
            }
            XCTAssertTrue(L10n.settings.lastUploadFailedHTTP(503, "X").contains("503"), language)
            XCTAssertTrue(L10n.settings.lastUploadFailedHTTP(503, "X").contains("X"), language)
            XCTAssertTrue(L10n.settings.lastUploadFailed("X").contains("X"), language)
        }
    }

    // MARK: - Where it is shown, and when it is forgotten

    private static let appRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    /// Under the connection's Status in Settings › General, signed in only.
    func testTheRowSitsUnderTheConnectionsStatus() throws {
        let general = try String(contentsOf: Self.appRoot.appendingPathComponent(
            "CLI Pulse Bar/GeneralSection.swift"), encoding: .utf8)
        let status = try XCTUnwrap(general.range(of: "Text(state.serverOnline ? L10n.settings.connected"))
        let row = try XCTUnwrap(general.range(of: "LastCloudUploadRow(store: CloudUploadStatusStore.shared)"))
        let cadence = try XCTUnwrap(general.range(of: "Text(L10n.settings.refreshCadence)"))
        XCTAssertTrue(status.upperBound < row.lowerBound && row.upperBound < cadence.lowerBound,
                      "the row is not between Status and the refresh cadence")
        XCTAssertTrue(general.contains("if state.isAuthenticated && !state.isDemoMode {\n                LastCloudUploadRow("),
                      "the row shows outside a signed-in account")
    }

    /// The status belongs to the account it was recorded for.
    func testASignOutOrAnotherAccountForgetsIt() throws {
        let auth = try String(contentsOf: Self.appRoot.appendingPathComponent(
            "CLIPulseCore/Sources/CLIPulseCore/AuthManager.swift"), encoding: .utf8)
        let signedOut = try XCTUnwrap(auth.range(of: "func applySignedOutState() {"))
        XCTAssertTrue(auth[signedOut.upperBound...].prefix(200).contains("CloudUploadStatusStore.shared.reset()"))
        XCTAssertTrue(auth.contains("if !userId.isEmpty, userId != session.userId { CloudUploadStatusStore.shared.reset() }"))
    }
}
